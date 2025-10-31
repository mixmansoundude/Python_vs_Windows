[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$StructDir,
    [string]$DiagRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Never put a colon right after a PowerShell variable in double-quoted strings;
# prefer -f or $($var)—and don’t mismatch placeholder counts. CI previously
# failed parsing "$value:" so we keep the reminder near the helpers.

function Write-Info {
    param([string]$Message)
    Write-Host ("[ensure-ndjson] {0}" -f $Message)
}

function Resolve-OptionalPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        return (Convert-Path -LiteralPath $Path)
    } catch {
        return $Path
    }
}

function Get-CanonicalPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $null
    }

    try {
        return (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        return $Path
    }
}

function Ensure-DestinationDirectory {
    param([string]$Path)

    $dir = Split-Path -Path $Path -Parent
    if ([string]::IsNullOrWhiteSpace($dir)) {
        return
    }

    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$ws = if ($Workspace) { Resolve-OptionalPath $Workspace } else { $null }
if (-not $ws) {
    throw 'Workspace path is required.'
}

$struct = if ($StructDir) { Resolve-OptionalPath $StructDir } else { $null }
$diag = if ($DiagRoot) { Resolve-OptionalPath $DiagRoot } else { $null }

$searchCandidates = @(
    $ws,
    (if ($ws) { Join-Path -Path $ws -ChildPath '_artifacts' }),
    (if ($ws) { Join-Path -Path $ws -ChildPath '_artifacts/iterate' }),
    (if ($ws) { Join-Path -Path $ws -ChildPath '_artifacts/iterate/inputs' }),
    $struct,
    $diag
) | Where-Object { $_ }

# derived requirement: CI run 18957425807-1 wrote NDJSON beneath
# _artifacts/iterate/inputs, so we must probe the workspace mirrors before
# falling back to struct/diag roots to avoid declaring the gate missing.
$searchRoots = @($searchCandidates | Select-Object -Unique)
$requiredNames = @('tests~test-results.ndjson', 'ci_test_results.ndjson')
$destinations = @{}
foreach ($name in $requiredNames) {
    $destinations[$name] = Join-Path -Path $ws -ChildPath $name
}

$foundMap = @{}
$searchedReport = New-Object System.Collections.Generic.List[string]

foreach ($root in @($searchRoots)) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }

    if (Test-Path -LiteralPath $root) {
        $reportRoot = Get-CanonicalPath $root
        if (-not $reportRoot) { $reportRoot = $root }
        $searchedReport.Add($reportRoot) | Out-Null

        try {
            $candidates = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ndjson' -ErrorAction Stop
        } catch {
            # derived requirement: prefer successful enumeration even if a subdirectory disappears mid-search.
            $candidates = Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ndjson' -ErrorAction SilentlyContinue
        }

        foreach ($candidate in @($candidates)) {
            if (-not $candidate) { continue }
            $leaf = $candidate.Name
            if (-not ($requiredNames -contains $leaf)) { continue }
            if ($foundMap.ContainsKey($leaf)) { continue }
            $foundMap[$leaf] = Get-CanonicalPath $candidate.FullName
        }
    } else {
        $searchedReport.Add("$root (missing)") | Out-Null
    }
}

$foundPairs = New-Object System.Collections.Generic.List[string]
$missingList = New-Object System.Collections.Generic.List[string]
$gateFound = New-Object System.Collections.Generic.List[object]
$gateMissing = New-Object System.Collections.Generic.List[string]
$sourcesDetail = New-Object System.Collections.Generic.List[object]

foreach ($name in $requiredNames) {
    $sourcePath = $null
    if ($foundMap.ContainsKey($name)) {
        $sourcePath = $foundMap[$name]
    }

    if (-not $sourcePath) {
        $existing = $destinations[$name]
        if (Test-Path -LiteralPath $existing) {
            # derived requirement: retain workspace copies so downstream consumers that mirrored
            # before this helper ran still find the NDJSON payload.
            $sourcePath = Get-CanonicalPath $existing
        }
    }

    if (-not $sourcePath) {
        $missingList.Add($name) | Out-Null
        $gateMissing.Add($name) | Out-Null
        continue
    }

    $sourceCanonical = Get-CanonicalPath $sourcePath
    if (-not $sourceCanonical) { $sourceCanonical = $sourcePath }

    $destinationsList = New-Object System.Collections.Generic.List[string]

    $workspaceTarget = $destinations[$name]
    Ensure-DestinationDirectory -Path $workspaceTarget
    $workspaceCanonical = Get-CanonicalPath $workspaceTarget
    if (-not ($workspaceCanonical -and [string]::Equals($workspaceCanonical, $sourceCanonical, [System.StringComparison]::OrdinalIgnoreCase))) {
        Copy-Item -LiteralPath $sourcePath -Destination $workspaceTarget -Force
        $workspaceCanonical = Get-CanonicalPath $workspaceTarget
    }
    if ($workspaceCanonical) {
        $destinationsList.Add($workspaceCanonical) | Out-Null
    }

    if ($struct) {
        $structTarget = Join-Path -Path $struct -ChildPath $name
        Ensure-DestinationDirectory -Path $structTarget
        $structCanonical = Get-CanonicalPath $structTarget
        if (-not ($structCanonical -and [string]::Equals($structCanonical, $sourceCanonical, [System.StringComparison]::OrdinalIgnoreCase))) {
            # derived requirement: keep the struct mirror in sync so diagnostics bundles expose the raw NDJSON.
            Copy-Item -LiteralPath $sourcePath -Destination $structTarget -Force
            $structCanonical = Get-CanonicalPath $structTarget
        }
        if ($structCanonical -and -not ($destinationsList -contains $structCanonical)) {
            $destinationsList.Add($structCanonical) | Out-Null
        }
    }

    $foundPairs.Add(('{0}:{1}' -f $name, $sourceCanonical)) | Out-Null
    $gateFound.Add([ordered]@{ label = $name; source = $sourceCanonical; copies = @($destinationsList) }) | Out-Null
    $sourcesDetail.Add([ordered]@{ label = $name; path = $sourceCanonical; destinations = @($destinationsList) }) | Out-Null

    Write-Info ("Located {0} at {1}" -f $name, $sourceCanonical)
}

$preview = @($searchedReport | Select-Object -Unique)
if ($preview.Count -gt 12) {
    $preview = $preview[0..11] + '...'
}
$joined = if ($preview.Count -gt 0) { [string]::Join(', ', $preview) } else { '<none>' }
Write-Info ("searched roots: {0}" -f $joined)

$iterateRoot = Join-Path -Path $ws -ChildPath '_artifacts/iterate'
try {
    New-Item -ItemType Directory -Path $iterateRoot -Force | Out-Null
} catch {
    # derived requirement: keep fail-open semantics so env exports continue even if the artifact tree is read-only.
}

$gatePayload = [ordered]@{
    stage = 'ensure-ndjson-sources'
    proceed = $true
    sources = @($sourcesDetail)
    missing_inputs = @($gateMissing)
    found_inputs = @($gateFound)
    searched_roots = @($searchedReport | Select-Object -Unique)
}
if ($struct) {
    $gatePayload.struct_dir = $struct
}

$gatePath = Join-Path -Path $iterateRoot -ChildPath 'iterate_gate.json'
$gatePayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $gatePath -Encoding UTF8

$envPath = $env:GITHUB_ENV
if ($envPath) {
    $foundCount = $foundPairs.Count
    Add-Content -LiteralPath $envPath -Value ('GATE_NDJSON_FOUND={0}' -f ($(if ($foundCount -eq $requiredNames.Count) { 'true' } else { 'false' })))
    if ($foundCount -gt 0) {
        Add-Content -LiteralPath $envPath -Value ('GATE_NDJSON_SOURCE={0}' -f ([string]::Join(';', $foundPairs)))
    } else {
        Add-Content -LiteralPath $envPath -Value 'GATE_NDJSON_SOURCE='
    }
    if ($missingList.Count -gt 0) {
        Add-Content -LiteralPath $envPath -Value ('GATE_NDJSON_MISSING={0}' -f ([string]::Join(';', $missingList)))
    } else {
        Add-Content -LiteralPath $envPath -Value 'GATE_NDJSON_MISSING='
    }
}
