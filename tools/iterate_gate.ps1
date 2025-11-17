[CmdletBinding()]
param(
    [string]$Workspace = $env:GITHUB_WORKSPACE,
    [string]$ArtifactsRoot,
    [string]$OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Warn {
    param([string]$Message)
    Write-Host "WARN  iterate_gate: $Message"
}

function Write-Info {
    param([string]$Message)
    Write-Host "INFO  iterate_gate: $Message"
}

if ([string]::IsNullOrWhiteSpace($Workspace)) {
    throw "Workspace path is required so the gate stays within the checkout."
}

try {
    $workspaceRoot = (Resolve-Path -LiteralPath $Workspace -ErrorAction Stop).Path
} catch {
    throw "Workspace '$Workspace' could not be resolved."
}

if (-not (Test-Path -LiteralPath $workspaceRoot)) {
    throw "Workspace root '$workspaceRoot' does not exist."
}

if ([string]::IsNullOrWhiteSpace($ArtifactsRoot)) {
    $ArtifactsRoot = Join-Path -Path $workspaceRoot -ChildPath '_artifacts'
}

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path -Path $workspaceRoot -ChildPath '_artifacts/iterate'
}

function Test-InWorkspace {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }
    return $full.StartsWith($workspaceRoot, [System.StringComparison]::OrdinalIgnoreCase)
}

function New-Directory {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

New-Directory -Path $ArtifactsRoot
New-Directory -Path $OutDir

$requiredFiles = @('tests~test-results.ndjson', 'ci_test_results.ndjson')
$checkedPatterns = New-Object System.Collections.Generic.List[string]
$missing = New-Object System.Collections.Generic.List[string]
$found = [ordered]@{}
$failListPath = $null
$failEntries = @()

function Find-FailList {
    param([string]$Workspace)

    $candidates = New-Object System.Collections.Generic.List[string]
    $diagEnv = $env:DIAG
    if (-not [string]::IsNullOrWhiteSpace($diagEnv)) { $candidates.Add($diagEnv) | Out-Null }
    $runnerTemp = $env:RUNNER_TEMP
    if (-not [string]::IsNullOrWhiteSpace($runnerTemp)) { $candidates.Add($runnerTemp) | Out-Null }
    foreach ($suffix in @('diag', '_mirrors', '.')) {
        $candidates.Add((Join-Path -Path $Workspace -ChildPath $suffix)) | Out-Null
    }

    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        try {
            $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        } catch {
            continue
        }
        if (-not $seen.Add($resolved)) { continue }
        $direct = Join-Path -Path $resolved -ChildPath 'batchcheck_failing.txt'
        if (Test-Path -LiteralPath $direct) { return $direct }
        try {
            $probe = Get-ChildItem -LiteralPath $resolved -Filter 'batchcheck_failing.txt' -File -Recurse -ErrorAction Stop | Select-Object -First 1
            if ($probe -and $probe.FullName) { return $probe.FullName }
        } catch {
            continue
        }
    }
    return $null
}

function Find-Ndjson {
    param([string]$Name)

    $results = @()
    $nestedRoot = Join-Path -Path $ArtifactsRoot -ChildPath 'batch-check'
    if (Test-Path -LiteralPath $nestedRoot) {
        $pattern = "probe:$nestedRoot/**/logs/$Name"
        $checkedPatterns.Add($pattern) | Out-Null
        try {
            $candidates = Get-ChildItem -LiteralPath $nestedRoot -Recurse -File -ErrorAction Stop |
                Where-Object { $_.Name -eq $Name -and $_.FullName -match "[\\/]+logs[\\/]" }
            foreach ($candidate in $candidates) {
                if (Test-InWorkspace $candidate.FullName) {
                    $results += $candidate.FullName
                    break
                }
            }
        } catch {
            if ($_.Exception -is [System.UnauthorizedAccessException]) {
                Write-Warn "EACCES on $nestedRoot (skipped)"
            } else {
                Write-Warn ("Failed to probe {0}: {1}" -f $nestedRoot, $_.Exception.Message)
            }
        }
    }

    if (-not $results) {
        $repoMirror = Join-Path -Path $ArtifactsRoot -ChildPath 'repo'
        if (Test-Path -LiteralPath $repoMirror) {
            $pattern = "probe:$repoMirror/**/$Name"
            $checkedPatterns.Add($pattern) | Out-Null
            try {
                $probe = Get-ChildItem -LiteralPath $repoMirror -Recurse -File -Filter $Name -ErrorAction Stop | Select-Object -First 1
                if ($probe -and (Test-InWorkspace $probe.FullName)) {
                    $results += $probe.FullName
                }
            } catch {
                if ($_.Exception -is [System.UnauthorizedAccessException]) {
                    Write-Warn "EACCES on $repoMirror (skipped)"
                } else {
                    Write-Warn ("Failed to probe {0}: {1}" -f $repoMirror, $_.Exception.Message)
                }
            }
        }
    }

    if (-not $results) {
        $pattern = "probe:$workspaceRoot/$Name"
        $checkedPatterns.Add($pattern) | Out-Null
        $rootCandidate = Join-Path -Path $workspaceRoot -ChildPath $Name
        if (Test-Path -LiteralPath $rootCandidate) {
            $results += (Resolve-Path -LiteralPath $rootCandidate).Path
        }
    }

    if (-not $results) {
        $structRoot = Join-Path -Path $workspaceRoot -ChildPath '_temp/struct'
        if (Test-Path -LiteralPath $structRoot) {
            $pattern = "probe:$structRoot/**/$Name"
            $checkedPatterns.Add($pattern) | Out-Null
            try {
                $probe = Get-ChildItem -LiteralPath $structRoot -Recurse -File -Filter $Name -ErrorAction Stop | Select-Object -First 1
                if ($probe -and (Test-InWorkspace $probe.FullName)) {
                    $results += $probe.FullName
                }
            } catch {
                if ($_.Exception -is [System.UnauthorizedAccessException]) {
                    Write-Warn "EACCES on $structRoot (skipped)"
                } else {
                    Write-Warn ("Failed to probe {0}: {1}" -f $structRoot, $_.Exception.Message)
                }
            }
        }
    }

    if ($results) {
        return ($results | Select-Object -First 1)
    }
    return $null
}

foreach ($name in $requiredFiles) {
    try {
        $hit = Find-Ndjson -Name $name
        if ($null -ne $hit -and (Test-Path -LiteralPath $hit)) {
            $found[$name] = $hit
            Write-Info "located $name at $hit"
        } else {
            $missing.Add($name) | Out-Null
            Write-Warn "$name missing after probes"
        }
    } catch {
        $missing.Add($name) | Out-Null
        Write-Warn ("Exception while probing {0}: {1}" -f $name, $_.Exception.Message)
    }
}

$failListPath = Find-FailList -Workspace $workspaceRoot
if ($failListPath) {
    Write-Info "located batchcheck_failing.txt at $failListPath"
    try {
        $failEntries = Get-Content -LiteralPath $failListPath -ErrorAction Stop | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $failEntries = $failEntries | Where-Object { $_ -and $_.ToLowerInvariant() -ne 'none' }
    } catch {
        Write-Warn ("unable to read fail list {0}: {1}" -f $failListPath, $_.Exception.Message)
        $failEntries = @()
    }
}

$hasFailingTests = ($failEntries.Count -gt 0)
$skipIterate = ($failListPath -and -not $hasFailingTests)
if ($skipIterate) {
    Write-Info "no failing tests detected; skipping iterate."
}

$gate = [ordered]@{
    stage = 'iterate-gate'
    proceed = -not $skipIterate
    has_failures = $hasFailingTests
    missing_inputs = @($missing)
    found_inputs = $found
    checked_patterns = @($checkedPatterns)
    note = if ($skipIterate) { 'Fail list reported no failing tests; iterate skipped.' } else { 'Gate is fail-open by design; iterate proceeds with warnings.' }
    failing_tests = @($failEntries)
}
if ($failListPath) { $gate.fail_list_path = $failListPath }

$gatePath = Join-Path -Path $OutDir -ChildPath 'iterate_gate.json'
$gate | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $gatePath -Encoding UTF8

Write-Info "gate summary written to $gatePath"
Write-Info (
    "summary: missing={0} found={1}" -f $missing.Count, $found.Keys.Count
)

$summaryLine = "scanned_ndjson=$($requiredFiles.Count) missing=$($missing.Count)"
Write-Info $summaryLine

# derived requirement: keep gate fail-open so diagnostics capture state without blocking iterate.

