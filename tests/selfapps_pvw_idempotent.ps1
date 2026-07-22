# ASCII only
# selfapps_pvw_idempotent.ps1 - Test REQ-005.13 (Tier 2, docs/plan-autopep723-two-tier.md):
# HP_PVW_KNOWN_IDEMPOTENT execute-mode dependency discovery.
#
# Single scenario, deterministic: HP_SKIP_PIPREQS=1 (test-level isolation only, same technique
# as selfapps_autopep_discovery.ps1 -- this is NOT how Tier 2 behaves by default; pipreqs runs
# normally alongside Tier 2 in production, this flag just isolates Tier 2's own contribution
# for this test) so pipreqs never runs and requirements.txt has no other source. The stub app
# imports requests; with pipreqs skipped and no requirements.txt/pyproject.toml present, the
# ONLY way requests ends up installed is via HP_PVW_KNOWN_IDEMPOTENT actually running the entry
# via uvx autopep723 and persisting what it needed.
#
# Asserts:
#   - The REQ-005.13 success log line appears in the bootstrap log.
#   - The stub app's own print() output appears directly in the bootstrap log -- proving the
#     execute-mode discovery run's stdout was genuinely inherited/passed through live, not
#     captured/suppressed (the specific design point this tier's helper exists to preserve).
#   - The merged requirements.txt contains requests.
#   - The app actually built and ran successfully afterward (proves requests was installed via
#     Tier 2's persist step, not just discovered).
#
# Lane: uv only (wired non-gating in batch-check.yml). Non-gating.
#
# Emits: self.pvw_idempotent.discovery
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

function Write-NdjsonRow {
    param([hashtable]$Row)
    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

function Write-IdempotentRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.pvw_idempotent.discovery'; req = 'REQ-005.13'; pass = $Pass; desc = $Desc; details = $Details })
}

# Non-Windows skip (matches this suite's convention).
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-IdempotentRow -Pass $true -Desc 'HP_PVW_KNOWN_IDEMPOTENT execute-mode discovery (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-IdempotentRow -Pass $false -Desc 'HP_PVW_KNOWN_IDEMPOTENT execute-mode discovery: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

$workDir = Join-Path $here '~selftest_pvw_idempotent'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

$appPath = Join-Path $workDir 'app.py'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($appPath, "import requests`nprint('t2-idempotent-ok')`n", $utf8NoBom)

$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevKnownIdempotent = if (Test-Path Env:HP_PVW_KNOWN_IDEMPOTENT) { $env:HP_PVW_KNOWN_IDEMPOTENT } else { $null }
$env:HP_SKIP_PIPREQS = '1'
$env:HP_PVW_KNOWN_IDEMPOTENT = '1'

$bootstrapLog = '~pvw_idempotent_bootstrap.log'
try {
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $logPath = Join-Path $workDir $bootstrapLog
    $logText = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw } else { '' }

    $discoveryLogFound = $logText -match 'REQ-005\.13: execute-mode discovery run succeeded'
    $stdoutPassthroughFound = $logText -match 't2-idempotent-ok'

    $reqsPath = Join-Path $workDir 'requirements.txt'
    $reqsText = if (Test-Path -LiteralPath $reqsPath) { Get-Content -LiteralPath $reqsPath -Raw } else { $null }
    $reqsHasRequests = $null -ne $reqsText -and $reqsText -match 'requests'

    $runOutPath = Join-Path $workDir '~run.out.txt'
    $runOutText = if (Test-Path -LiteralPath $runOutPath) { Get-Content -LiteralPath $runOutPath -Raw } else { '' }
    $appRan = $runOutText -match 't2-idempotent-ok'

    $pass = $discoveryLogFound -and $stdoutPassthroughFound -and $reqsHasRequests -and $appRan
    $details = [ordered]@{
        exitCode              = $exitCode
        discoveryLogFound     = [bool]$discoveryLogFound
        stdoutPassthroughFound = [bool]$stdoutPassthroughFound
        reqsHasRequests       = [bool]$reqsHasRequests
        appRan                = [bool]$appRan
    }
    Write-IdempotentRow -Pass $pass -Desc 'HP_PVW_KNOWN_IDEMPOTENT runs the entry live, persists what it needed, and the app builds/runs from it alone' -Details $details
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevKnownIdempotent) { Remove-Item Env:HP_PVW_KNOWN_IDEMPOTENT -ErrorAction SilentlyContinue } else { $env:HP_PVW_KNOWN_IDEMPOTENT = $prevKnownIdempotent }
}

if (-not $pass) { exit 1 }
exit 0
