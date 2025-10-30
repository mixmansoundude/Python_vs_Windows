[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Workspace,
    [string]$StructDir,
    [string]$DiagRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Never put a colon right after a PowerShell variable in double-quoted strings;
# prefer -f or $($var)—and don’t mismatch placeholder counts. The gate once
# failed parsing "$value:" so we centralize the reminder near the helpers.

function Format-SafeString {
    param(
        [Parameter(Mandatory=$true)][string]$Template,
        [Parameter(ValueFromRemainingArguments=$true)][object[]]$Args
    )

    try {
        return [string]::Format($Template, $Args)
    } catch {
        $joined = if ($Args -and $Args.Count -gt 0) { [string]::Join(' | ', $Args) } else { '<no-args>' }
        Write-Info ("Format fallback engaged for template {0}" -f $Template)
        return "$Template :: $joined"
    }
}

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

$structDestRoot = $null
if (-not [string]::IsNullOrWhiteSpace($StructDir)) {
    try {
        $structDestRoot = (Resolve-Path -LiteralPath $StructDir -ErrorAction Stop).Path
    } catch {
        $structDestRoot = $StructDir
    }
    if ($structDestRoot) {
        $searchRoots += $structDestRoot
        $structArtifacts = Join-Path -Path $structDestRoot -ChildPath '_artifacts'
        if (Test-Path -LiteralPath $structArtifacts) {
            try {
                $searchRoots += (Resolve-Path -LiteralPath $structArtifacts -ErrorAction Stop).Path
            } catch {
                $searchRoots += $structArtifacts
            }
        }
    }
}

if ($env:RUNNER_TEMP) {
    $runnerStructCandidate = Join-Path -Path $env:RUNNER_TEMP -ChildPath 'struct'
    if (Test-Path -LiteralPath $runnerStructCandidate) {
        try {
            $resolvedRunnerStruct = (Resolve-Path -LiteralPath $runnerStructCandidate -ErrorAction Stop).Path
        } catch {
            $resolvedRunnerStruct = $runnerStructCandidate
        }
        if ($resolvedRunnerStruct) {
            $searchRoots = @($resolvedRunnerStruct) + $searchRoots
        }
    }
}

$inputsRoot = Join-Path -Path $workspacePath -ChildPath '_artifacts/iterate/inputs'
if (Test-Path -LiteralPath $inputsRoot) {
    try {
        $resolvedInputs = (Resolve-Path -LiteralPath $inputsRoot -ErrorAction Stop).Path
        $searchRoots += $resolvedInputs
    } catch {
        # Professional note: keep fail-open behaviour even if Resolve-Path is denied.
    }
}
$workspaceArtifacts = Join-Path -Path $workspacePath -ChildPath '_artifacts'
if (Test-Path -LiteralPath $workspaceArtifacts) {
    try {
        $resolvedArtifacts = (Resolve-Path -LiteralPath $workspaceArtifacts -ErrorAction Stop).Path
        $searchRoots += $resolvedArtifacts
        $batchLogs = Join-Path -Path $resolvedArtifacts -ChildPath 'batch-check'
        if (Test-Path -LiteralPath $batchLogs) {
            $searchRoots += (Resolve-Path -LiteralPath $batchLogs -ErrorAction SilentlyContinue)
        }
    } catch {
        # derived requirement: the structured artifact unpack mirrors `_artifacts/batch-check`; even
        # if Resolve-Path fails (e.g., race with cleanup) we continue searching other roots.
    }
}
if (-not [string]::IsNullOrWhiteSpace($StructDir)) {
    # struct dir already handled above; retain fallback for diag traversal when the
    # caller passed a relative path that Resolve-Path could not normalize earlier.
    if (-not $structDestRoot) {
        $searchRoots += $StructDir
    }
}
if (-not [string]::IsNullOrWhiteSpace($DiagRoot)) {
    try {
        $resolvedDiag = (Resolve-Path -LiteralPath $DiagRoot -ErrorAction Stop).Path
        $searchRoots += $resolvedDiag
    } catch {
    }
}
$searchRoots = $searchRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique

$foundSources = New-Object System.Collections.Generic.List[string]
$missingTargets = New-Object System.Collections.Generic.List[string]
$gateFoundRecords = New-Object System.Collections.Generic.List[object]

function Sync-Target {
    param(
        [string]$Label,
        [string]$Destination,
        [string[]]$PreferredNames,
        [string[]]$FallbackGlobs
    )

    $structTarget = $null
    if ($structDestRoot) {
        $structTarget = Join-Path -Path $structDestRoot -ChildPath $Label
    }

    if (Test-Path -LiteralPath $Destination) {
        $item = Get-Item -LiteralPath $Destination -ErrorAction SilentlyContinue
        if ($item -and $item.Length -gt 0) {
            $existing = (Resolve-Path -LiteralPath $Destination -ErrorAction SilentlyContinue)
            $existingPath = if ($existing) { $existing.Path } else { $Destination }
            $foundSources.Add((Format-SafeString "{0}:{1} (existing)" $Label $existingPath)) | Out-Null
            Write-Info "Found existing $Label source at $Destination"
            if ($structTarget) {
                try {
                    Ensure-DestinationDirectory -Path $structTarget
                    Copy-Item -LiteralPath $Destination -Destination $structTarget -Force
                } catch {
                    Write-Info "Struct mirror failed for $Label: $($_.Exception.Message)"
                }
            }
            $record = [ordered]@{
                label     = $Label
                source    = $existingPath
                workspace = $Destination
            }
            if ($structTarget) { $record.struct = $structTarget }
            $gateFoundRecords.Add([pscustomobject]$record) | Out-Null
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
            try {
                Copy-Item -LiteralPath $source -Destination $Destination -Force
            } catch {
                Write-Info "Copy to workspace failed for $Label: $($_.Exception.Message)"
            }
        } else {
            Write-Info "$Label source already at $Destination"
        }

        $structMirror = $null
        if ($structTarget) {
            Ensure-DestinationDirectory -Path $structTarget
            if ([string]::Compare($source, $structTarget, $true) -ne 0) {
                Write-Info "Mirroring $Label source to struct directory: $structTarget"
                try {
                    Copy-Item -LiteralPath $source -Destination $structTarget -Force
                    $structMirror = $structTarget
                } catch {
                    Write-Info "Struct mirror failed for $Label: $($_.Exception.Message)"
                }
            } else {
                $structMirror = $structTarget
            }
        }

        $foundSources.Add((Format-SafeString "{0}:{1}" $Label $source)) | Out-Null
        $record = [ordered]@{
            label     = $Label
            source    = $source
            workspace = $Destination
        }
        if ($structMirror) { $record.struct = $structMirror }
        $gateFoundRecords.Add([pscustomobject]$record) | Out-Null
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
        $foundSources.Add((Format-SafeString "{0}:{1}" 'synth' $destCi)) | Out-Null
        Write-Info "Synthesized ci_test_results.ndjson from $firstFailure"
        $missingTargets.Clear() | Out-Null
        $synthStruct = $null
        if ($structDestRoot) {
            $synthStruct = Join-Path -Path $structDestRoot -ChildPath 'ci_test_results.ndjson'
            try {
                Ensure-DestinationDirectory -Path $synthStruct
                Copy-Item -LiteralPath $destCi -Destination $synthStruct -Force
            } catch {
                Write-Info "Struct mirror failed for synth ci_test_results.ndjson: $($_.Exception.Message)"
                $synthStruct = $null
            }
        }
        $record = [ordered]@{
            label     = 'ci_test_results.ndjson'
            source    = $destCi
            workspace = $destCi
        }
        if ($synthStruct) { $record.struct = $synthStruct }
        $gateFoundRecords.Add([pscustomobject]$record) | Out-Null
    }
}

$envPath = $env:GITHUB_ENV
if ($envPath) {
    $foundValue = if (($missingTargets.Count -eq 0) -and ($foundSources.Count -gt 0)) { 'true' } else { 'false' }
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

$gateDir = Join-Path -Path $workspacePath -ChildPath '_artifacts/iterate'
New-Item -ItemType Directory -Force -Path $gateDir | Out-Null
$searchedSnapshot = @($searchRoots | Select-Object -First 12)
$gateData = [ordered]@{
    stage           = 'ensure-ndjson-sources'
    proceed         = $true
    has_failures    = ($missingTargets.Count -gt 0)
    missing_inputs  = @($missingTargets)
    sources         = @($gateFoundRecords)
    searched_roots  = $searchedSnapshot
}
if ($missingTargets.Count -gt 0) {
    $gateData.note = 'NDJSON sources missing after recursive search.'
} else {
    $gateData.note = 'NDJSON sources copied to workspace/struct directories.'
}
$gatePath = Join-Path -Path $gateDir -ChildPath 'iterate_gate.json'
$gateJson = $gateData | ConvertTo-Json -Depth 6
$gateJson | Set-Content -LiteralPath $gatePath -Encoding UTF8
Write-Info "iterate_gate.json written to $gatePath"
