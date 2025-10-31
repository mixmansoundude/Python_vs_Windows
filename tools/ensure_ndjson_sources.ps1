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

$ws = $null
if ($Workspace) {
    try {
        $ws = Convert-Path -LiteralPath $Workspace
    } catch {
        # derived requirement: Convert-Path can throw for transient runner paths;
        # prefer to keep the original string so the helper can still probe.
        $ws = $Workspace
    }
}
if (-not $ws) {
    throw 'Workspace path is required.'
}

$struct = $null
if ($StructDir) {
    try {
        $struct = Convert-Path -LiteralPath $StructDir
    } catch {
        $struct = $StructDir
    }
}

$diag = $null
if ($DiagRoot) {
    try {
        $diag = Convert-Path -LiteralPath $DiagRoot
    } catch {
        $diag = $DiagRoot
    }
}

$artifactsRoot = if ($ws) { Join-Path -Path $ws -ChildPath '_artifacts' } else { $null }
$iterateRootCandidate = if ($artifactsRoot) { Join-Path -Path $artifactsRoot -ChildPath 'iterate' } else { $null }
$inputsRootCandidate = if ($iterateRootCandidate) { Join-Path -Path $iterateRootCandidate -ChildPath 'inputs' } else { $null }

$searchCandidates = @($ws, $artifactsRoot, $iterateRootCandidate, $inputsRootCandidate, $struct, $diag)

# derived requirement: CI run 18957425807-1 wrote NDJSON beneath
# _artifacts/iterate/inputs, so we must probe the workspace mirrors before
# falling back to struct/diag roots to avoid declaring the gate missing.
# derived requirement: keep the search list limited to existing directories so
# Convert-Path failures or missing mirrors do not spam the diagnostics log.
$searchRoots = New-Object System.Collections.Generic.List[string]
foreach ($candidate in $searchCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    $canonicalCandidate = Get-CanonicalPath $candidate
    if (-not $canonicalCandidate) { $canonicalCandidate = $candidate }
    if (-not ($searchRoots -contains $canonicalCandidate)) {
        $searchRoots.Add($canonicalCandidate) | Out-Null
    }
}
$requiredNames = @('tests~test-results.ndjson', 'ci_test_results.ndjson')
$destinations = @{}
$inputMirrors = @{}
$workspaceInputsRoot = $inputsRootCandidate
foreach ($name in $requiredNames) {
    $destinations[$name] = Join-Path -Path $ws -ChildPath $name
    if ($workspaceInputsRoot) {
        $inputMirrors[$name] = Join-Path -Path $workspaceInputsRoot -ChildPath $name
    }
}

$foundMap = @{}
$searchedReport = New-Object System.Collections.Generic.List[string]
foreach ($root in $searchRoots) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }

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
        $existing = $null
        if ($inputMirrors.ContainsKey($name)) {
            $candidate = $inputMirrors[$name]
            if (Test-Path -LiteralPath $candidate) {
                $existing = $candidate
            }
        }
        if (-not $existing) {
            $candidate = $destinations[$name]
            if (Test-Path -LiteralPath $candidate) {
                $existing = $candidate
            }
        }
        if ($existing) {
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

    $copyTargets = New-Object System.Collections.Generic.List[string]
    if ($inputMirrors.ContainsKey($name)) {
        $inputsTarget = $inputMirrors[$name]
        [void]$copyTargets.Add($inputsTarget)
    }
    $rootMirror = Join-Path -Path $ws -ChildPath $name
    if ($rootMirror) {
        [void]$copyTargets.Add($rootMirror)
    }

    foreach ($target in $copyTargets) {
        if ([string]::IsNullOrWhiteSpace($target)) { continue }
        Ensure-DestinationDirectory -Path $target
        $targetCanonical = Get-CanonicalPath $target
        if (-not ($targetCanonical -and [string]::Equals($targetCanonical, $sourceCanonical, [System.StringComparison]::OrdinalIgnoreCase))) {
            Copy-Item -LiteralPath $sourcePath -Destination $target -Force
            $targetCanonical = Get-CanonicalPath $target
        }
        if ($targetCanonical -and -not ($destinationsList -contains $targetCanonical)) {
            $destinationsList.Add($targetCanonical) | Out-Null
        }
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
    $gateFound.Add([ordered]@{ label = $name; source = $sourceCanonical; copies = $destinationsList.ToArray() }) | Out-Null
    $sourcesDetail.Add([ordered]@{ label = $name; path = $sourceCanonical; destinations = $destinationsList.ToArray() }) | Out-Null

    Write-Info ("Located {0} at {1}" -f $name, $sourceCanonical)
}

$uniqueRoots = @($searchedReport | Select-Object -Unique)
$preview = $uniqueRoots
if ($preview.Count -gt 12) {
    $preview = $preview[0..11] + '...'
}
$joined = if ($preview.Count -gt 0) { [string]::Join(', ', $preview) } else { '<none>' }
Write-Info ("searched roots: {0}" -f $joined)

$iterateRoot = if ($iterateRootCandidate) { $iterateRootCandidate } else { Join-Path -Path $ws -ChildPath '_artifacts/iterate' }
try {
    New-Item -ItemType Directory -Path $iterateRoot -Force | Out-Null
} catch {
    # derived requirement: keep fail-open semantics so env exports continue even if the artifact tree is read-only.
}

$gatePayload = [ordered]@{
    # derived requirement: diagnostics contract reads stage "iterate-gate"; keep value stable for downstream parsers.
    stage = 'iterate-gate'
    proceed = ($missingList.Count -eq 0)
    sources = $sourcesDetail.ToArray()
    missing_inputs = $gateMissing.ToArray()
    found_inputs = $gateFound.ToArray()
    searched_roots = $uniqueRoots
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
