[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [AllowNull()][AllowEmptyString()][string]$StructDir,
    [AllowNull()][AllowEmptyString()][string]$DiagRoot
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

$ws = Resolve-OptionalPath $Workspace
if (-not $ws) {
    throw 'Workspace path is required.'
}

$struct = Resolve-OptionalPath $StructDir
$diag = Resolve-OptionalPath $DiagRoot

$destinations = @{
    'tests~test-results.ndjson' = Join-Path -Path $ws -ChildPath 'tests~test-results.ndjson'
    'ci_test_results.ndjson'    = Join-Path -Path $ws -ChildPath 'ci_test_results.ndjson'
}

$searchRoots = @($struct, $diag) | Where-Object { $_ } | Select-Object -Unique
$searchedReport = New-Object System.Collections.Generic.List[string]

$requiredNames = @('tests~test-results.ndjson', 'ci_test_results.ndjson')
$foundMap = @{}

foreach ($root in @($searchRoots)) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }

    $reportRoot = $root
    if (Test-Path -LiteralPath $root) {
        $canonicalRoot = Get-CanonicalPath $root
        if ($canonicalRoot) { $reportRoot = $canonicalRoot }
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

$foundSources = New-Object System.Collections.Generic.List[string]
$missingTargets = New-Object System.Collections.Generic.List[string]
$gateFound = New-Object System.Collections.Generic.List[object]
$gateMissing = New-Object System.Collections.Generic.List[string]
$sourcesDetail = New-Object System.Collections.Generic.List[object]

foreach ($name in $requiredNames) {
    $dest = $destinations[$name]
    if (-not $foundMap.ContainsKey($name) -and (Test-Path -LiteralPath $dest)) {
        $foundMap[$name] = Get-CanonicalPath $dest
    }

    $source = $null
    if ($foundMap.ContainsKey($name)) {
        $source = $foundMap[$name]
    }

    if ([string]::IsNullOrWhiteSpace($source)) {
        $missingTargets.Add($name) | Out-Null
        $gateMissing.Add($name) | Out-Null
        continue
    }

    Ensure-DestinationDirectory -Path $dest

    $sourceResolved = Get-CanonicalPath $source
    $destResolved = Get-CanonicalPath $dest

    if (-not ($sourceResolved -and $destResolved -and [string]::Equals($sourceResolved, $destResolved, [System.StringComparison]::OrdinalIgnoreCase))) {
        # derived requirement: copy into the workspace mirror even if the producer lives under struct/diag roots.
        Copy-Item -LiteralPath $source -Destination $dest -Force
        $destResolved = Get-CanonicalPath $dest
    }

    $copies = New-Object System.Collections.Generic.List[string]
    if ($destResolved) {
        $copies.Add($destResolved) | Out-Null
    }

    if ($struct) {
        $structDest = Join-Path -Path $struct -ChildPath $name
        Ensure-DestinationDirectory -Path $structDest
        $structResolved = Get-CanonicalPath $structDest
        if (-not ($structResolved -and $sourceResolved -and [string]::Equals($sourceResolved, $structResolved, [System.StringComparison]::OrdinalIgnoreCase))) {
            Copy-Item -LiteralPath $source -Destination $structDest -Force
            $structResolved = Get-CanonicalPath $structDest
        }
        if ($structResolved -and -not ($copies -contains $structResolved)) {
            $copies.Add($structResolved) | Out-Null
        }
    }

    $sourceForEnv = if ($sourceResolved) { $sourceResolved } else { $source }
    $foundSources.Add(('{0}:{1}' -f $name, $sourceForEnv)) | Out-Null
    $gateFound.Add([ordered]@{ label = $name; source = $sourceForEnv; copies = @($copies) }) | Out-Null
    $sourcesDetail.Add([ordered]@{ label = $name; path = $sourceForEnv; destinations = @($copies) }) | Out-Null

    Write-Info ("Located {0} at {1}" -f $name, $sourceForEnv)
}

if ((@($foundSources)).Count -lt $requiredNames.Count) {
    $preview = @($searchedReport | Select-Object -Unique)
    if ($preview.Count -gt 12) {
        $preview = $preview[0..11] + '...'
    }
    $joined = if ($preview.Count -gt 0) { [string]::Join(', ', $preview) } else { '<none>' }
    # derived requirement: Gate diagnostics regressed without an explicit search trace when both NDJSON files were absent.
    Write-Info ("searched roots: {0}" -f $joined)
}

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
    $foundCount = (@($foundSources)).Count
    Add-Content -LiteralPath $envPath -Value ('GATE_NDJSON_FOUND={0}' -f ($(if ($foundCount -eq $requiredNames.Count) { 'true' } else { 'false' })))
    if ($foundCount -gt 0) {
        Add-Content -LiteralPath $envPath -Value ('GATE_NDJSON_SOURCE={0}' -f ([string]::Join(';', $foundSources)))
    } else {
        Add-Content -LiteralPath $envPath -Value 'GATE_NDJSON_SOURCE='
    }
    if ((@($missingTargets)).Count -gt 0) {
        Add-Content -LiteralPath $envPath -Value ('GATE_NDJSON_MISSING={0}' -f ([string]::Join(';', $missingTargets)))
    } else {
        Add-Content -LiteralPath $envPath -Value 'GATE_NDJSON_MISSING='
    }
}
