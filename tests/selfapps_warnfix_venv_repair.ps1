# ASCII only
# selfapps_warnfix_venv_repair.ps1 - Regression test for CLAUDE.md Active Backlog Item 36:
# the warnfix repair-install dispatch previously had ONLY uv/conda branches, so under
# venv/embed/system it silently no-opped -- installed nothing -- while still logging
# "[REPAIR] missing modules detected; installing and rebuilding." and "[REPAIR] rebuild
# complete after warnfix." as if it had worked. run_setup.bat now has venv/embed branches
# (plain "%HP_PY%" -m pip install %%M, mirroring the MAIN dependency-install dispatch's
# own venv/embed pip pathway) plus a system-mode no-op with an honest log line. This test
# forces venv mode specifically (embed is exercised only via a real python.org download,
# too network-heavy for a dedicated regression test here) and asserts the missing module
# is GENUINELY installed, not just that the EXE eventually builds.
#
# derived requirement: HP_OFFLINE_MODE=1 + HP_TEST_FORCE_CONDA_FAIL=1 in a FRESH scratch
# directory is the established technique (see self.venv.fallback in
# selfapps_ux_hardening.ps1, and docs/agent-interconnect.md's "HP_UV_BIN locality"
# section) for deterministically forcing venv-mode fallback: a fresh directory has no
# cached ~uv_bin so uv is unavailable, HP_OFFLINE_MODE blocks a fresh uv download, and
# HP_TEST_FORCE_CONDA_FAIL forces conda to fail too -- the provider chain falls through
# uv -> conda -> embed -> venv, and embed is a private, checksummed python.org download
# this test does not force (HP_TEST_FORCE_EMBED_REAL is not set), so venv is the first
# tier actually reachable.
#
# Lane: uv (non-gating for first landing -- matches this repo's established graduation
# pattern for a new PowerShell scenario not yet proven stable across several real runs).
# Skips in conda-full (HP_FORCE_CONDA_ONLY=1 blocks all non-conda fallbacks unconditionally).
#
# Emits: self.exe.warnfix.venv_repair
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

$rowId = 'self.exe.warnfix.venv_repair'

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = $rowId
        req     = 'REQ-007'
        pass    = $true
        desc    = 'Warnfix repair-install under venv mode genuinely installs the missing module (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

# conda-full lane skip: HP_FORCE_CONDA_ONLY=1 blocks embed/venv/system fallback
# unconditionally, so venv mode is unreachable there regardless of what this test forces.
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = $rowId
        req     = 'REQ-007'
        pass    = $true
        desc    = 'Warnfix repair-install under venv mode genuinely installs the missing module (skipped: HP_FORCE_CONDA_ONLY blocks venv fallback)'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-prohibits-venv-fallback' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = $rowId
        req     = 'REQ-007'
        pass    = $false
        desc    = 'Warnfix venv-repair: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_warnfix_venv_repair'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# derived requirement: xlrd is not covered by any heuristic (same choice as
# selfapps_warnfix.ps1's own real_warnfix scenario) -- no requirements.txt is created,
# so there is nothing for prep_requirements to pre-install. warnfix must fire to install
# xlrd, and it must do so via the new venv-mode branch, not silently no-op.
$appCode = @'
import xlrd
import os as _os
import sys as _sys
_ = xlrd.__version__
assert callable(xlrd.open_workbook), 'xlrd.open_workbook not accessible'
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~warnfix_venv_token.txt'), 'w') as _f:
    _f.write('warnfix-venv-repair-ok\n')
print('xlrd ok')
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$savedCondaFail = $env:HP_TEST_FORCE_CONDA_FAIL
$savedOffline   = $env:HP_OFFLINE_MODE
$savedSkipPR    = $env:HP_SKIP_PIPREQS
$savedSkipAP    = $env:HP_SKIP_AUTOPEP_DISCOVERY
$savedLane      = $env:HP_CI_LANE
$env:HP_TEST_FORCE_CONDA_FAIL   = '1'
$env:HP_OFFLINE_MODE            = '1'
$env:HP_SKIP_PIPREQS            = '1'
# derived requirement: HP_SKIP_AUTOPEP_DISCOVERY=1 for the same reason
# selfapps_warnfix.ps1 sets it -- without it, REQ-005.12's autopep723-check discovery
# (uv lane, default-on) would statically discover xlrd from the stub app's own import
# and merge it into requirements.txt before warnfix ever gets a chance to fire, defeating
# this test's whole "isolate the warnfix repair path" premise.
$env:HP_SKIP_AUTOPEP_DISCOVERY  = '1'
$env:HP_CI_LANE                 = 'test'

$bootstrapLog = '~warnfix_venv_repair_bootstrap.log'
Push-Location -LiteralPath $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    $env:HP_TEST_FORCE_CONDA_FAIL   = $savedCondaFail
    $env:HP_OFFLINE_MODE            = $savedOffline
    $env:HP_SKIP_PIPREQS            = $savedSkipPR
    $env:HP_SKIP_AUTOPEP_DISCOVERY  = $savedSkipAP
    $env:HP_CI_LANE                 = $savedLane
    Pop-Location
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# derived requirement: confirm venv mode was GENUINELY selected -- without this, a false
# pass could hide behind conda/embed unexpectedly succeeding instead (which would prove
# nothing about the venv-specific branch this test exists to cover).
$venvProviderLog = $combined -match [regex]::Escape('[BOOT] REQ-009: Selected Python provider: Local venv (fallback).')

$warnInstallFired = $combined -match [regex]::Escape('[REPAIR] missing modules detected; installing and rebuilding.')
$warnRebuildFired = $combined -match [regex]::Escape('[REPAIR] rebuild complete after warnfix.')
# derived requirement: this is the actual Item 36 assertion -- "the module actually gets
# installed (not just that the EXE eventually builds)". Before the fix, this line was NEVER
# emitted under venv mode (the dispatch matched neither the uv nor the conda branch), even
# though the rebuild-complete line above still fired unconditionally.
$installedXlrd    = $combined -match [regex]::Escape('[INFO] Installed: xlrd')
$repairFailed     = $combined -match [regex]::Escape('[WARN] Repair failed:')

$envLeaf  = Split-Path $workDir -Leaf
$envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_warnfix_venv_repair' }
$distDir  = Join-Path $workDir 'dist'
$exePath  = Join-Path $distDir "$envName.exe"
$exeExists = Test-Path -LiteralPath $exePath
$exeExit   = -1
$tokenPath = Join-Path $distDir '~warnfix_venv_token.txt'
$tokenFound = $false

if ($exeExists) {
    try {
        Push-Location -LiteralPath $distDir
        try {
            cmd /c "`"$exePath`"" *> '~warnfix_venv_repair_exe.log'
            $exeExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $tokenFound = Test-Path -LiteralPath $tokenPath
    } catch {
        $exeExit = -1
    }
}

$exeLogPath    = Join-Path $distDir '~warnfix_venv_repair_exe.log'
$exeLogContent = if (Test-Path $exeLogPath) { Get-Content -LiteralPath $exeLogPath -Raw -Encoding ASCII } else { '' }
$infraError    = $exeLogContent -match 'Failed to parse|uv error|pip error'

$pass = $venvProviderLog -and $warnInstallFired -and $warnRebuildFired -and $installedXlrd -and (-not $repairFailed) -and $exeExists -and ($exeExit -eq 0) -and $tokenFound -and (-not $infraError)

Write-NdjsonRow ([ordered]@{
    id      = $rowId
    req     = 'REQ-007'
    pass    = $pass
    desc    = 'Warnfix repair-install under venv mode genuinely installs the missing module (CLAUDE.md Item 36)'
    details = [ordered]@{
        exitCode         = $runExit
        venvProviderLog  = $venvProviderLog
        warnInstallFired = $warnInstallFired
        warnRebuildFired = $warnRebuildFired
        installedXlrd    = $installedXlrd
        repairFailed     = $repairFailed
        exeExists        = $exeExists
        exeExit          = $exeExit
        tokenFound       = $tokenFound
        infraError       = $infraError
        exePath          = $exePath
    }
})

if (-not $pass) { exit 1 }
exit 0
