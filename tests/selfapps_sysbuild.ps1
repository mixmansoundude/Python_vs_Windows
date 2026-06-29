# ASCII only
# selfapps_sysbuild.ps1 - REQ-007 provider-independent build: system-Python build consent gate.
# In a default no-flag run with uv/conda/venv all forced to fail, accepting the REQ-014 run
# consent routes into the Tier 4 system provider. The EXE build is now ATTEMPTED under system
# Python too (provider-independent), but only behind a separate consent because it installs
# PyInstaller into the user's system interpreter. This test declines that build consent
# (HP_TEST_SYSBUILD_ANSWER=N) and asserts the gate fires, the build is skipped with a logged
# reason, and no EXE is produced -- offline-safe and deterministic (no network build attempted).
#
# Lane: non-conda-full (HP_FORCE_CONDA_ONLY=1 suppresses the system tier).
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

if (-not $IsWindows) {
    Write-NdjsonRow ([ordered]@{
        id = 'self.sysbuild.decline'; req = 'REQ-007'; pass = $true
        desc = 'system-Python build consent decline (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

# conda-full suppresses the system tier; nothing to exercise there.
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id = 'self.sysbuild.decline'; req = 'REQ-007'; pass = $true
        desc = 'system-Python build consent decline'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-blocks-system-tier' }
    })
    exit 0
}

$workDir = Join-Path $here '~selftest_sysbuild'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $workDir -Force
Set-Content -LiteralPath (Join-Path $workDir 'app.py') -Value 'print("hello from system python")' -Encoding Ascii

# Force the fallback chain to system Python (offline so no uv; conda+venv forced to fail),
# accept the REQ-014 run consent to ENTER system mode, then DECLINE the REQ-007 build consent.
$saved = @{
    off  = $env:HP_OFFLINE_MODE;          cf = $env:HP_TEST_FORCE_CONDA_FAIL
    vf   = $env:HP_TEST_FORCE_VENV_FAIL;   sc = $env:HP_TEST_SYSCON_ANSWER
    sb   = $env:HP_TEST_SYSBUILD_ANSWER;   ln = $env:HP_CI_LANE
}
$env:HP_OFFLINE_MODE          = '1'
$env:HP_TEST_FORCE_CONDA_FAIL = '1'
$env:HP_TEST_FORCE_VENV_FAIL  = '1'
$env:HP_TEST_SYSCON_ANSWER    = 'Y'
$env:HP_TEST_SYSBUILD_ANSWER  = 'N'
$env:HP_CI_LANE               = 'test'
$log = Join-Path $workDir '~sysbuild_test.log'
Push-Location -LiteralPath $workDir
try {
    cmd /c "run_setup.bat > ~sysbuild_test.log 2>&1"
} finally {
    Pop-Location
    $env:HP_OFFLINE_MODE          = $saved.off
    $env:HP_TEST_FORCE_CONDA_FAIL = $saved.cf
    $env:HP_TEST_FORCE_VENV_FAIL  = $saved.vf
    $env:HP_CI_LANE               = $saved.ln
    if ($null -eq $saved.sc) { Remove-Item Env:HP_TEST_SYSCON_ANSWER   -ErrorAction SilentlyContinue } else { $env:HP_TEST_SYSCON_ANSWER   = $saved.sc }
    if ($null -eq $saved.sb) { Remove-Item Env:HP_TEST_SYSBUILD_ANSWER -ErrorAction SilentlyContinue } else { $env:HP_TEST_SYSBUILD_ANSWER = $saved.sb }
}

$txt = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw -Encoding Ascii } else { '' }

# Assertions: the build consent prompt was shown, it was declined, the build was skipped with a
# logged reason, and no EXE was produced. (The app still runs via the interpreter smoke.)
$promptShown = $txt -match [regex]::Escape('installs PyInstaller into your system Python')
$declineLog  = $txt -match [regex]::Escape('[INFO] REQ-007: system-Python EXE build consent: declined.')
$skipLog     = $txt -match [regex]::Escape('system-Python EXE build not consented; skipping PyInstaller packaging')
$noExe       = -not (Test-Path -LiteralPath (Join-Path $workDir 'dist'))

$pass = $promptShown -and $declineLog -and $skipLog -and $noExe
Write-NdjsonRow ([ordered]@{
    id      = 'self.sysbuild.decline'
    req     = 'REQ-007'
    pass    = $pass
    desc    = 'REQ-007: system-Python EXE build is consent-gated; decline skips the build with a logged reason and no EXE'
    details = [ordered]@{ promptShown = $promptShown; declineLog = $declineLog; skipLog = $skipLog; noExe = $noExe }
})

if (-not $pass) { exit 1 }
exit 0
