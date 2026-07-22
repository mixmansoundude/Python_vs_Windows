# ASCII only
# selfapps_autopep_discovery.ps1 - Test REQ-005.12 (Tier 1, docs/plan-autopep723-two-tier.md):
# autopep723 check discovery augmentation of the Default Path's own pipreqs-based discovery.
#
# Single scenario, deterministic: HP_SKIP_PIPREQS=1 so pipreqs never runs and requirements.txt
# has no other source -- isolates Tier 1's own contribution cleanly (no confound with pipreqs
# also finding the same package). The stub app imports requests; with pipreqs skipped and no
# requirements.txt/pyproject.toml present, the ONLY way requests ends up installed is via
# :after_pipreqs_run's new autopep723-check-and-merge block (run_setup.bat ~line 1294) writing
# it into requirements.txt before the dependency-install phase runs. A full build+run proves the
# merged dependency was both written AND actually installed -- not just present in a log line.
#
# Asserts:
#   - requirements.autopep.txt (autopep723 check's raw output) was created and mentions requests.
#   - The REQ-005.12 success log line appears in the bootstrap log.
#   - The merged requirements.txt contains requests.
#   - The app actually built and ran successfully (proves requests was installed, not just
#     written to a file that never got fed to the installer).
#
# Lane: uv only (wired non-gating in batch-check.yml, matching selfapps_pvw_quickstart.ps1's
# single-lane gate -- no HP_FORCE_CONDA_ONLY skip logic needed since the workflow gate already
# guarantees this only runs where HP_ENV_MODE resolves to uv).
#
# Emits: self.autopep_discovery.merge
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

function Write-AutopepRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.autopep_discovery.merge'; req = 'REQ-005.12'; pass = $Pass; desc = $Desc; details = $Details })
}

# Non-Windows skip (matches this suite's convention).
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-AutopepRow -Pass $true -Desc 'autopep723 discovery merge (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AutopepRow -Pass $false -Desc 'autopep723 discovery merge: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

$workDir = Join-Path $here '~selftest_autopep_discovery'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

$appPath = Join-Path $workDir 'app.py'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($appPath, "import requests`nprint('smoke-ok')`n", $utf8NoBom)

$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'

$bootstrapLog = '~autopep_discovery_bootstrap.log'
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

    $autopepOutPath = Join-Path $workDir 'requirements.autopep.txt'
    $autopepOutText = if (Test-Path -LiteralPath $autopepOutPath) { Get-Content -LiteralPath $autopepOutPath -Raw } else { $null }
    $autopepFound = $null -ne $autopepOutText -and $autopepOutText -match 'requests'

    $reqsPath = Join-Path $workDir 'requirements.txt'
    $reqsText = if (Test-Path -LiteralPath $reqsPath) { Get-Content -LiteralPath $reqsPath -Raw } else { $null }
    $reqsHasRequests = $null -ne $reqsText -and $reqsText -match 'requests'

    $mergeLogFound = $logText -match 'REQ-005\.12: autopep723 discovery merge complete\.'

    $runOutPath = Join-Path $workDir '~run.out.txt'
    $runOutText = if (Test-Path -LiteralPath $runOutPath) { Get-Content -LiteralPath $runOutPath -Raw } else { '' }
    $appRan = $runOutText -match 'smoke-ok'

    $pass = $autopepFound -and $mergeLogFound -and $reqsHasRequests -and $appRan
    $details = [ordered]@{
        exitCode         = $exitCode
        autopepOutExists = $null -ne $autopepOutText
        autopepFound     = [bool]$autopepFound
        mergeLogFound    = [bool]$mergeLogFound
        reqsHasRequests  = [bool]$reqsHasRequests
        appRan           = [bool]$appRan
    }
    Write-AutopepRow -Pass $pass -Desc 'autopep723 discovery merge populates requirements.txt and the app builds/runs from it alone' -Details $details
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
}

if (-not $pass) { exit 1 }
exit 0
