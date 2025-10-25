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

function Resolve-Candidate {
    param(
        [string]$Root,
        [string]$Relative
    )

    if ([string]::IsNullOrWhiteSpace($Relative)) {
        return $null
    }

    if ([System.IO.Path]::IsPathRooted($Relative)) {
        if (Test-Path -LiteralPath $Relative) {
            return (Resolve-Path -LiteralPath $Relative).Path
        }
        return $null
    }

    if ([string]::IsNullOrWhiteSpace($Root)) {
        return $null
    }

    $combined = Join-Path -Path $Root -ChildPath $Relative
    if (Test-Path -LiteralPath $combined) {
        return (Resolve-Path -LiteralPath $combined).Path
    }

    return $null
}

function Find-ByNames {
    param(
        [string[]]$Roots,
        [string[]]$Names
    )

    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($name in $Names) {
            $candidate = Resolve-Candidate -Root $root -Relative $name
            if ($candidate) { return $candidate }
        }
    }

    return $null
}

function Find-ByGlobs {
    param(
        [string[]]$Roots,
        [string[]]$Globs
    )

    foreach ($root in $Roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        foreach ($glob in $Globs) {
            try {
                $match = Get-ChildItem -LiteralPath $root -Filter $glob -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
            } catch {
                $match = $null
            }
            if ($match) {
                try {
                    return (Resolve-Path -LiteralPath $match.FullName).Path
                } catch {
                    return $match.FullName
                }
            }
        }
    }

    return $null
}

function Ensure-DestinationDirectory {
    param([string]$Path)

    $dir = Split-Path -Path $Path -Parent
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
}

$workspacePath = (Resolve-Path -LiteralPath $Workspace).Path
$destTests = Join-Path -Path $workspacePath -ChildPath 'tests~test-results.ndjson'
$destCi = Join-Path -Path $workspacePath -ChildPath 'ci_test_results.ndjson'

$searchRoots = @($workspacePath)
if (-not [string]::IsNullOrWhiteSpace($StructDir)) {
    try {
        $resolvedStruct = (Resolve-Path -LiteralPath $StructDir -ErrorAction Stop).Path
        $searchRoots += $resolvedStruct
    } catch {
        # keep search robust even if struct dir is unavailable
    }
}
if (-not [string]::IsNullOrWhiteSpace($DiagRoot)) {
    try {
        $resolvedDiag = (Resolve-Path -LiteralPath $DiagRoot -ErrorAction Stop).Path
        $searchRoots += $resolvedDiag
    } catch {
    }
}
$searchRoots = $searchRoots | Sort-Object -Unique

$foundSources = New-Object System.Collections.Generic.List[string]
$missingTargets = New-Object System.Collections.Generic.List[string]

function Sync-Target {
    param(
        [string]$Label,
        [string]$Destination,
        [string[]]$PreferredNames,
        [string[]]$FallbackGlobs
    )

    if (Test-Path -LiteralPath $Destination) {
        $size = (Get-Item -LiteralPath $Destination).Length
        if ($size -gt 0) {
            $foundSources.Add("$Label:$Destination (existing)") | Out-Null
            Write-Info "Found existing $Label source at $Destination"
            return
        }
    }

    $source = Find-ByNames -Roots $searchRoots -Names $PreferredNames
    if (-not $source) {
        $source = Find-ByGlobs -Roots $searchRoots -Globs $FallbackGlobs
    }

    if ($source) {
        if ([string]::Compare($source, $Destination, $true) -ne 0) {
            Write-Info "Copying $Label source from $source to $Destination"
            Ensure-DestinationDirectory -Path $Destination
            Copy-Item -LiteralPath $source -Destination $Destination -Force
        } else {
            Write-Info "$Label source already at $Destination"
        }
        $foundSources.Add("$Label:$source") | Out-Null
    } else {
        $missingTargets.Add($Label) | Out-Null
        Write-Info "No source located for $Label"
    }
}

Sync-Target -Label 'tests~test-results.ndjson' -Destination $destTests -PreferredNames @(
    'tests\~test-results.ndjson',
    'tests/~test-results.ndjson',
    'tests~test-results.ndjson',
    '~test-results.ndjson'
) -FallbackGlobs @('~test-results.ndjson')

Sync-Target -Label 'ci_test_results.ndjson' -Destination $destCi -PreferredNames @(
    'ci_test_results.ndjson',
    'tests~test-results.ndjson',
    'tests\ci_test_results.ndjson',
    'tests/ci_test_results.ndjson'
) -FallbackGlobs @('ci_test_results.ndjson', '*test-results.ndjson')

if ($foundSources.Count -eq 0) {
    # derived requirement: gate needs a minimal NDJSON row even when artifacts are sparse.
    # Use first_failure.json if available to synthesize a placeholder record.
    $firstFailure = Find-ByGlobs -Roots $searchRoots -Globs @('first_failure.json')
    if ($firstFailure) {
        try {
            $json = Get-Content -LiteralPath $firstFailure -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        } catch {
            $json = $null
        }
        $id = 'synth.first_failure'
        $desc = 'synthesized from first_failure.json'
        $sourceHint = $firstFailure
        if ($json) {
            if ($json.id) { $id = [string]$json.id }
            elseif ($json.name) { $id = [string]$json.name }
            if ($json.desc) { $desc = [string]$json.desc }
            elseif ($json.description) { $desc = [string]$json.description }
            elseif ($json.message) { $desc = [string]$json.message }
            if ($json.source) { $sourceHint = [string]$json.source }
            elseif ($json.file) { $sourceHint = [string]$json.file }
            elseif ($json.path) { $sourceHint = [string]$json.path }
        }
        $payload = [ordered]@{
            id = $id
            pass = $false
            desc = $desc
            details = [ordered]@{ source = $sourceHint }
        }
        Ensure-DestinationDirectory -Path $destCi
        ($payload | ConvertTo-Json -Compress) | Set-Content -LiteralPath $destCi -Encoding Ascii
        $foundSources.Add("synth:$destCi") | Out-Null
        Write-Info "Synthesized ci_test_results.ndjson from $firstFailure"
        $missingTargets.Clear() | Out-Null
    }
}

$envPath = $env:GITHUB_ENV
if ($envPath) {
    $foundValue = if ($foundSources.Count -gt 0) { 'true' } else { 'false' }
    Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_FOUND=$foundValue"
    if ($foundSources.Count -gt 0) {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_SOURCE=$([string]::Join(';', $foundSources))"
    } else {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_SOURCE="
    }
    if ($missingTargets.Count -gt 0) {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_MISSING=$([string]::Join(';', $missingTargets))"
    } else {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_MISSING="
    }
}
