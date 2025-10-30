[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$StructDir,
    [string]$DiagRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info {
    param([string]$Message)
    Write-Host "[ensure-ndjson] $Message"
}

function Resolve-Safe {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        return $null
    }
}

$workspacePath = Resolve-Safe $Workspace
if (-not $workspacePath) {
    throw "Workspace path '$Workspace' could not be resolved."
}

$structPath = $null
if ($StructDir) {
    $structPath = Resolve-Safe $StructDir
    if (-not $structPath) {
        New-Item -ItemType Directory -Path $StructDir -Force | Out-Null
        $structPath = Resolve-Safe $StructDir
    }
}
if (-not $structPath) {
    $structPath = Join-Path -Path $workspacePath -ChildPath '_temp/struct'
    New-Item -ItemType Directory -Path $structPath -Force | Out-Null
}

$searchRoots = New-Object System.Collections.Generic.List[string]
$runnerStruct = $null
if ($env:RUNNER_TEMP) {
    $candidate = Join-Path -Path $env:RUNNER_TEMP -ChildPath 'struct'
    $resolvedCandidate = Resolve-Safe $candidate
    if ($resolvedCandidate) { $searchRoots.Add($resolvedCandidate) | Out-Null }
}
if ($structPath) { $searchRoots.Add($structPath) | Out-Null }
$searchRoots = $searchRoots | Sort-Object -Unique
Write-Info ("search roots: {0}" -f ([string]::Join(', ', $searchRoots)))
if (-not $searchRoots -or $searchRoots.Count -eq 0) {
    Write-Info 'No search roots available for NDJSON discovery.'
}

$targets = @(
    [pscustomobject]@{ Label = 'tests~test-results.ndjson'; Name = '~test-results.ndjson'; Destination = Join-Path $structPath 'tests~test-results.ndjson' },
    [pscustomobject]@{ Label = 'ci_test_results.ndjson'; Name = 'ci_test_results.ndjson'; Destination = Join-Path $structPath 'ci_test_results.ndjson' }
)

$foundSources = New-Object System.Collections.Generic.List[pscustomobject]
$missingLabels = New-Object System.Collections.Generic.List[string]

foreach ($target in $targets) {
    $located = $null
    foreach ($root in $searchRoots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        try {
            $candidate = Get-ChildItem -LiteralPath $root -Filter $target.Name -Recurse -File -ErrorAction Stop | Select-Object -First 1
        } catch {
            $candidate = $null
        }
        if ($candidate) {
            $located = $candidate.FullName
            break
        }
    }

    if ($located) {
        Write-Info ("located {0} at {1}" -f $target.Label, $located)
        $destination = $target.Destination
        $destDir = Split-Path -Path $destination -Parent
        if (-not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        Copy-Item -LiteralPath $located -Destination $destination -Force
        $foundSources.Add([pscustomobject]@{ label = $target.Label; source = $located; destination = $destination }) | Out-Null
    } else {
        Write-Info ("missing {0}" -f $target.Label)
        $missingLabels.Add($target.Label) | Out-Null
    }
}

$envPath = $env:GITHUB_ENV
if ($envPath) {
    $foundValue = if ($foundSources.Count -gt 0) { 'true' } else { 'false' }
    Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_FOUND=$foundValue"
    if ($foundSources.Count -gt 0) {
        $sourceValue = ($foundSources | ForEach-Object { '{0}:{1}' -f $_.label, $_.source }) -join ';'
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_SOURCE=$sourceValue"
    } else {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_SOURCE="
    }
    if ($missingLabels.Count -gt 0) {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_MISSING=$($missingLabels -join ';')"
    } else {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_MISSING="
    }
}

$gateDir = Join-Path -Path $workspacePath -ChildPath '_artifacts/iterate'
if (-not (Test-Path -LiteralPath $gateDir)) {
    New-Item -ItemType Directory -Path $gateDir -Force | Out-Null
}
$gatePayload = [ordered]@{
    stage = 'ensure_ndjson_sources'
    found = @($foundSources | ForEach-Object { [ordered]@{ label = $_.label; source = $_.source; destination = $_.destination } })
    missing = @($missingLabels)
    searched_roots = @($searchRoots)
}
$gatePath = Join-Path -Path $gateDir -ChildPath 'iterate_gate.json'
$gatePayload | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $gatePath -Encoding UTF8
Write-Info ("iterate_gate.json updated at {0}" -f $gatePath)

if ($missingLabels.Count -gt 0) {
    Write-Info ("searched roots: {0}" -f ([string]::Join(', ', $searchRoots)))
}
