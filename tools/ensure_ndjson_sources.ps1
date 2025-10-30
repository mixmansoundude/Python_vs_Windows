[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][AllowNull()][AllowEmptyString()][string]$Workspace,
    [AllowNull()][AllowEmptyString()][string]$StructDir,
    [AllowNull()][AllowEmptyString()][string]$DiagRoot
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
        [AllowNull()][string[]]$Roots,
        [AllowNull()][string[]]$Names
    )

    $Roots = @($Roots)
    $Names = @($Names)
    if (-not $Roots -and $script:resolvedStruct) {
        $Roots = @($script:resolvedStruct)
    }

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
        [AllowNull()][string[]]$Roots,
        [AllowNull()][string[]]$Globs
    )

    $Roots = @($Roots)
    $Globs = @($Globs)
    if (-not $Roots -and $script:resolvedStruct) {
        $Roots = @($script:resolvedStruct)
    }

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

$workspace = $null
if ([string]::IsNullOrWhiteSpace($Workspace)) {
    throw 'Workspace path is required.'
}
try {
    $workspace = Convert-Path -LiteralPath $Workspace
} catch {
    $workspace = $Workspace
}
$workspacePath = $workspace
try { $workspacePath = (Resolve-Path -LiteralPath $workspacePath -ErrorAction Stop).Path } catch {}
$structResolved = $null
if (-not [string]::IsNullOrWhiteSpace($StructDir)) {
    try {
        $structResolved = Convert-Path -LiteralPath $StructDir
    } catch {
        $structResolved = $StructDir
    }
}
$diagResolved = $null
if (-not [string]::IsNullOrWhiteSpace($DiagRoot)) {
    try {
        $diagResolved = Convert-Path -LiteralPath $DiagRoot
    } catch {
        $diagResolved = $DiagRoot
    }
}
$destTests = Join-Path -Path $workspacePath -ChildPath 'tests~test-results.ndjson'
$destCi = Join-Path -Path $workspacePath -ChildPath 'ci_test_results.ndjson'

$searchRoots = [System.Collections.Generic.List[string]]::new()
function Add-SearchRoot {
    param(
        [System.Collections.Generic.List[string]]$List,
        [AllowNull()][string]$Candidate
    )

    if ([string]::IsNullOrWhiteSpace($Candidate)) { return }
    $exists = $false
    foreach ($existing in $List) {
        if ([string]::Equals($existing, $Candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
            $exists = $true
            break
        }
    }
    if (-not $exists) {
        $List.Add($Candidate) | Out-Null
    }
}

Add-SearchRoot -List $searchRoots -Candidate $structResolved
Add-SearchRoot -List $searchRoots -Candidate $diagResolved
Add-SearchRoot -List $searchRoots -Candidate $workspacePath
$structCopyMap = @{}
$inputsRoot = Join-Path -Path $workspacePath -ChildPath '_artifacts/iterate/inputs'
if (Test-Path -LiteralPath $inputsRoot) {
    try {
        $resolvedInputs = (Resolve-Path -LiteralPath $inputsRoot -ErrorAction Stop).Path
        Add-SearchRoot -List $searchRoots -Candidate $resolvedInputs
    } catch {
        # Professional note: keep fail-open behaviour even if Resolve-Path is denied.
    }
}
$workspaceArtifacts = Join-Path -Path $workspacePath -ChildPath '_artifacts'
if (Test-Path -LiteralPath $workspaceArtifacts) {
    try {
        $resolvedArtifacts = (Resolve-Path -LiteralPath $workspaceArtifacts -ErrorAction Stop)
        $artifactEntries = @($resolvedArtifacts)
        foreach ($artifact in $artifactEntries) {
            Add-SearchRoot -List $searchRoots -Candidate $artifact.Path
        }
        $artifactBase = if ($artifactEntries.Count -gt 0) { $artifactEntries[0].Path } else { $workspaceArtifacts }
        $batchLogs = Join-Path -Path $artifactBase -ChildPath 'batch-check'
        if (Test-Path -LiteralPath $batchLogs) {
            $resolvedBatch = Resolve-Path -LiteralPath $batchLogs -ErrorAction SilentlyContinue
            foreach ($batchEntry in @($resolvedBatch)) {
                Add-SearchRoot -List $searchRoots -Candidate $batchEntry.Path
            }
        }
    } catch {
        # derived requirement: the structured artifact unpack mirrors `_artifacts/batch-check`; even
        # if Resolve-Path fails (e.g., race with cleanup) we continue searching other roots.
    }
}
$resolvedStruct = $structResolved
if ($resolvedStruct) {
    # derived requirement: callers reported struct mirroring failing when the hashtable
    # was populated before initialization. Seed the copy map up front and keep the
    # resolved path so later diagnostics can report it.
    $structArtifacts = Join-Path -Path $resolvedStruct -ChildPath '_artifacts'
    if (Test-Path -LiteralPath $structArtifacts) {
        $resolvedStructArtifacts = Resolve-Path -LiteralPath $structArtifacts -ErrorAction SilentlyContinue
        foreach ($structArtifact in @($resolvedStructArtifacts)) {
            Add-SearchRoot -List $searchRoots -Candidate $structArtifact.Path
        }
    }
    $structCopyMap['tests~test-results.ndjson'] = Join-Path -Path $resolvedStruct -ChildPath 'tests~test-results.ndjson'
    $structCopyMap['ci_test_results.ndjson'] = Join-Path -Path $resolvedStruct -ChildPath 'ci_test_results.ndjson'
}
$runnerTemp = $env:RUNNER_TEMP
if ($runnerTemp) {
    $tempStruct = Join-Path -Path $runnerTemp -ChildPath 'struct'
    if (Test-Path -LiteralPath $tempStruct) {
        try {
            $resolvedTempStruct = (Resolve-Path -LiteralPath $tempStruct -ErrorAction Stop).Path
        } catch {
            $resolvedTempStruct = $tempStruct
        }
        if ($resolvedTempStruct) {
            Add-SearchRoot -List $searchRoots -Candidate $resolvedTempStruct
        }
    }
}
if ($diagResolved) {
    try {
        $resolvedDiag = (Resolve-Path -LiteralPath $diagResolved -ErrorAction Stop).Path
    } catch {
        $resolvedDiag = $diagResolved
    }
    Add-SearchRoot -List $searchRoots -Candidate $resolvedDiag
}

$foundSources = New-Object System.Collections.Generic.List[string]
$missingTargets = New-Object System.Collections.Generic.List[string]
$gateFound = New-Object System.Collections.Generic.List[object]
$gateMissing = New-Object System.Collections.Generic.List[string]

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
            $note = Format-SafeString "{0}:{1} (existing)" $Label $Destination
            # derived requirement: avoid PowerShell's scoped-variable parsing ("$var:") so
            # we do not reintroduce the ParserError seen when the gate executed this script.
            $foundSources.Add($note) | Out-Null
            Write-Info "Found existing $Label source at $Destination"
            $canonicalDest = $Destination
            try { $canonicalDest = (Resolve-Path -LiteralPath $Destination -ErrorAction Stop).Path } catch {}
            $copies = New-Object System.Collections.Generic.List[string]
            if (-not ($copies -contains $canonicalDest)) { $copies.Add($canonicalDest) | Out-Null }
            if ($structCopyMap.ContainsKey($Label)) {
                $structMirror = $structCopyMap[$Label]
                if ($structMirror) {
                    Ensure-DestinationDirectory -Path $structMirror
                    if (-not (Test-Path -LiteralPath $structMirror)) {
                        Write-Info "Mirroring existing $Label into struct dir $structMirror"
                        Copy-Item -LiteralPath $Destination -Destination $structMirror -Force
                    }
                    try {
                        $structResolved = (Resolve-Path -LiteralPath $structMirror -ErrorAction Stop).Path
                    } catch {
                        $structResolved = $structMirror
                    }
                    if (-not ($copies -contains $structResolved)) { $copies.Add($structResolved) | Out-Null }
                }
            }
            $gateFound.Add([ordered]@{ label = $Label; source = $canonicalDest; copies = @($copies) }) | Out-Null
            return
        }
    }

    $source = Find-ByNames -Roots $searchRoots -Names $PreferredNames
    if (-not $source) {
        $source = Find-ByGlobs -Roots $searchRoots -Globs $FallbackGlobs
    }

    if ($source) {
        $copies = New-Object System.Collections.Generic.List[string]
        $sourceResolved = $source
        try { $sourceResolved = (Resolve-Path -LiteralPath $source -ErrorAction Stop).Path } catch {}
        if ([string]::Compare($source, $Destination, $true) -ne 0) {
            Write-Info "Copying $Label source from $source to $Destination"
            Ensure-DestinationDirectory -Path $Destination
            Copy-Item -LiteralPath $source -Destination $Destination -Force
        } else {
            Write-Info "$Label source already at $Destination"
        }
        $destResolved = $Destination
        try { $destResolved = (Resolve-Path -LiteralPath $Destination -ErrorAction Stop).Path } catch {}
        if (-not ($copies -contains $destResolved)) { $copies.Add($destResolved) | Out-Null }
        if ($structCopyMap.ContainsKey($Label)) {
            $structMirror = $structCopyMap[$Label]
            if ($structMirror) {
                Ensure-DestinationDirectory -Path $structMirror
                Write-Info "Copying $Label source into struct dir $structMirror"
                Copy-Item -LiteralPath $source -Destination $structMirror -Force
                try {
                    $structResolved = (Resolve-Path -LiteralPath $structMirror -ErrorAction Stop).Path
                } catch {
                    $structResolved = $structMirror
                }
                if (-not ($copies -contains $structResolved)) { $copies.Add($structResolved) | Out-Null }
            }
        }
        # derived requirement: wrap Format-SafeString calls in parentheses when passing to
        # methods so PowerShell does not misparse the invocation (CI previously surfaced a
        # "Missing ')'" error here).
        $foundSources.Add((Format-SafeString "{0}:{1}" $Label $source)) | Out-Null
        $gateFound.Add([ordered]@{ label = $Label; source = $sourceResolved; copies = @($copies) }) | Out-Null
    } else {
        $missingTargets.Add($Label) | Out-Null
        Write-Info "No source located for $Label"
        $gateMissing.Add($Label) | Out-Null
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

if ((@($foundSources)).Count -eq 0) {
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
        $copies = New-Object System.Collections.Generic.List[string]
        $ciResolved = $destCi
        try { $ciResolved = (Resolve-Path -LiteralPath $destCi -ErrorAction Stop).Path } catch {}
        if (-not ($copies -contains $ciResolved)) { $copies.Add($ciResolved) | Out-Null }
        if ($structCopyMap.ContainsKey('ci_test_results.ndjson')) {
            $structMirror = $structCopyMap['ci_test_results.ndjson']
            if ($structMirror) {
                Ensure-DestinationDirectory -Path $structMirror
                Copy-Item -LiteralPath $destCi -Destination $structMirror -Force
                try {
                    $structResolved = (Resolve-Path -LiteralPath $structMirror -ErrorAction Stop).Path
                } catch {
                    $structResolved = $structMirror
                }
                if (-not ($copies -contains $structResolved)) { $copies.Add($structResolved) | Out-Null }
            }
        }
        $gateFound.Add([ordered]@{ label = 'ci_test_results.ndjson'; source = $ciResolved; copies = @($copies); synthesized = $true }) | Out-Null
        $missingTargets.Clear() | Out-Null
        $gateMissing.Clear() | Out-Null
    }
}

$searchedReport = @()
foreach ($root in @($searchRoots)) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $searchedReport += $root
    if ($searchedReport.Count -ge 12) { break }
}
$foundCount = (@($foundSources)).Count
if ($foundCount -eq 0) {
    $preview = if ($searchedReport.Count -gt 0) { [string]::Join(', ', $searchedReport) } else { '<none>' }
    # derived requirement: CI surfaced silent gate failures when no NDJSON files were located.
    # Log the search roots explicitly so diagnostics preserve the trail without mutating outputs.
    Write-Info ("searched roots: {0}" -f $preview)
}
$gatePayload = [ordered]@{
    stage = 'ensure-ndjson-sources'
    proceed = $true
    missing_inputs = @($gateMissing)
    found_inputs = @($gateFound)
    searched_roots = @($searchedReport)
}
if ($resolvedStruct) {
    $gatePayload.struct_dir = $resolvedStruct
}
$iterateRoot = Join-Path -Path $workspacePath -ChildPath '_artifacts/iterate'
try {
    New-Item -ItemType Directory -Path $iterateRoot -Force | Out-Null
} catch {}
$gatePath = Join-Path -Path $iterateRoot -ChildPath 'iterate_gate.json'
$gatePayload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $gatePath -Encoding UTF8

$envPath = $env:GITHUB_ENV
if ($envPath) {
    $foundValue = if ($foundCount -gt 0) { 'true' } else { 'false' }
    Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_FOUND=$foundValue"
    if ($foundCount -gt 0) {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_SOURCE=$([string]::Join(';', $foundSources))"
    } else {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_SOURCE="
    }
    if ((@($missingTargets)).Count -gt 0) {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_MISSING=$([string]::Join(';', $missingTargets))"
    } else {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_MISSING="
    }
}
