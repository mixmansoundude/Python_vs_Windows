# ASCII only
# selfapps_exedyn_fail.ps1 - XFAIL test: EXE smokerun expected to fail when entry.py
# uses a dynamic import (__import__) that PyInstaller cannot detect statically. Bootstrap
# completes (exitCode=0) but the built EXE exits non-zero at runtime. Test passes (xfail)
# when smokerun reports failure. Test fails (xpass) if smokerun unexpectedly reports exit 0.
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

# derived requirement: entry.py uses __import__() to load colorama dynamically.
# pipreqs static analysis cannot detect __import__() calls, so colorama is absent
# from requirements.auto.txt. requirements.txt names colorama explicitly so conda
# installs it into the env (Python run succeeds), but PyInstaller does not bundle
# it (dynamic import hidden from static analysis) causing the EXE to exit non-zero.
Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
module_name = "colorama"
mod = __import__(module_name)
print("dynamic import ok")
'@ -Encoding ASCII

Set-Content -Path (Join-Path $workDir 'requirements.txt') -Value 'colorama' -Encoding ASCII

$bootstrapLog = '~exedyn_bootstrap.log'

Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
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

# xfailPass: smokerun fired AND did NOT report exit 0
$xfailPass = $smokerunFired -and (-not $smokerunPassed)

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.smokerun.exedyn.xfail'
    req     = 'REQ-003'
    pass    = $xfailPass
    desc    = 'EXE smokerun XFAIL: dynamic import not bundled causes non-zero exit (expected failure)'
    details = [ordered]@{
        bootstrapExit  = $runExit
        smokerunFired  = $smokerunFired
        smokerunPassed = $smokerunPassed
        xfailPass      = $xfailPass
        log            = $bootstrapLog
    }
})

if (-not $xfailPass) { exit 1 }
exit 0
