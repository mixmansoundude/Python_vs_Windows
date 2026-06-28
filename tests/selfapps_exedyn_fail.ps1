# ASCII only
# selfapps_exedyn_fail.ps1 - XFAIL test: dynamic import of a NON-INSTALLED module.
# entry.py uses __import__() on a module that is absent from the environment, so
# PyInstaller cannot bundle it AND the Slice 2 --hidden-import recovery correctly
# DECLINES (its find_spec gate sees the module is not installed) -- the EXE therefore
# fails gracefully. This is the unrecoverable counterpart to selfapps_hidden_import.ps1,
# which dynamically imports an INSTALLED module and IS auto-recovered. Test passes
# (xfail) when smokerun reports failure AND recovery did not fire.
#
# Lane: real and conda-full only.
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

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.smokerun.exedyn.xfail'
        req     = 'REQ-003'
        pass    = $true
        desc    = 'EXE smokerun XFAIL: dynamic import not bundled exits non-zero (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.smokerun.exedyn.xfail'
        req     = 'REQ-003'
        pass    = $false
        desc    = 'EXE smokerun XFAIL: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_exedyn_fail'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# derived requirement: entry.py uses __import__() on a module that is NOT installed.
# PyInstaller cannot see the dynamic import (so it is not bundled and not in the warn
# file), and because the module is genuinely absent the Slice 2 recovery find_spec gate
# declines to add a --hidden-import -- the EXE fails at runtime with ModuleNotFoundError.
# HP_SKIP_PIPREQS=1 keeps pipreqs from attempting any network lookup; no requirements.txt
# is provided so the module stays uninstalled.
Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
module_name = "absent_dynmod_xyz"
mod = __import__(module_name)
print("dynamic import ok")
'@ -Encoding ASCII

$bootstrapLog = '~exedyn_bootstrap.log'

$prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'

Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    if ($null -eq $prev) {
        Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PIPREQS = $prev
    }
    Pop-Location
}

$logPath  = Join-Path $workDir $bootstrapLog
$setupLog = Join-Path $workDir '~setup.log'
$logLines = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupTxt = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined = ($logLines -join "`n") + "`n" + $setupTxt

# derived requirement: exact log phrases from :run_exe_smokerun in run_setup.bat.
# XFAIL: smokerun fires and reports a non-zero exit (expected failure) -> pass.
# XPASS: smokerun fires and reports exit 0 (unexpected success) -> fail.
$smokerunFiredPhrase = 'EXE smokerun: exited'
$smokerunPassPhrase  = 'EXE smokerun: exited 0 (ok)'

$smokerunFired  = $combined -match [regex]::Escape($smokerunFiredPhrase)
$smokerunPassed = $combined -match [regex]::Escape($smokerunPassPhrase)

# Recovery must have DECLINED (the module is not installed) -- no rebuild attempted.
$recoveryDeclined = -not ($combined -match [regex]::Escape('[REPAIR][HIDDEN_IMPORT] Adding'))
# xfailPass: smokerun fired, did NOT report exit 0, and recovery declined.
$xfailPass = $smokerunFired -and (-not $smokerunPassed) -and $recoveryDeclined

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.smokerun.exedyn.xfail'
    req     = 'REQ-003'
    pass    = $xfailPass
    desc    = 'EXE smokerun XFAIL: dynamic import not bundled causes non-zero exit (expected failure)'
    details = [ordered]@{
        bootstrapExit  = $runExit
        smokerunFired  = $smokerunFired
        smokerunPassed   = $smokerunPassed
        recoveryDeclined = $recoveryDeclined
        xfailPass        = $xfailPass
        log              = $bootstrapLog
    }
})

if (-not $xfailPass) { exit 1 }
exit 0
