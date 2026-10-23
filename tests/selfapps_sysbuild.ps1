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

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
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

# Runs the bootstrapper in a fresh folder with the fallback chain forced to system Python (offline so no uv; conda+venv
# forced to fail), the REQ-014 run consent accepted to ENTER system mode, and the REQ-007 build consent declined. A
# builder choice, when given, is set as PVW_BUILDER for that one run. Returns the console/log text.
function Invoke-SysBuildRun {
    param([string]$Name, [string]$Builder)
    $dir = Join-Path $here $Name
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $dir -Force
    Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value 'print("hello from system python")' -Encoding Ascii
    $saved = @{
        off  = $env:HP_OFFLINE_MODE;          cf = $env:HP_TEST_FORCE_CONDA_FAIL
        vf   = $env:HP_TEST_FORCE_VENV_FAIL;   sc = $env:HP_TEST_SYSCON_ANSWER
        sb   = $env:HP_TEST_SYSBUILD_ANSWER;   ln = $env:HP_CI_LANE
        pb   = $env:PVW_BUILDER
    }
    $env:HP_OFFLINE_MODE          = '1'
    $env:HP_TEST_FORCE_CONDA_FAIL = '1'
    $env:HP_TEST_FORCE_VENV_FAIL  = '1'
    $env:HP_TEST_SYSCON_ANSWER    = 'Y'
    $env:HP_TEST_SYSBUILD_ANSWER  = 'N'
    $env:HP_CI_LANE               = 'test'
    if ($Builder) { $env:PVW_BUILDER = $Builder } else { Remove-Item Env:PVW_BUILDER -ErrorAction SilentlyContinue }
    $runLog = Join-Path $dir '~sysbuild_test.log'
    Push-Location -LiteralPath $dir
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
        if ($null -eq $saved.pb) { Remove-Item Env:PVW_BUILDER             -ErrorAction SilentlyContinue } else { $env:PVW_BUILDER             = $saved.pb }
    }
    $text = if (Test-Path -LiteralPath $runLog) { Get-Content -LiteralPath $runLog -Raw -Encoding Ascii } else { '' }
    return [pscustomobject]@{ Dir = $dir; Text = $text }
}

$run = Invoke-SysBuildRun -Name '~selftest_sysbuild' -Builder ''
$workDir = $run.Dir
$txt = $run.Text

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

# PVW_BUILDER=nuitka (Item 71): the system-Python build then installs Nuitka, not PyInstaller, so the question that asks
# for consent must name the tool it is about to install (CodeRabbit on PR 499). The run proves its own precondition
# (the override was logged and the prompt was reached and declined) so the row cannot pass on a run that never asked.
$runN = Invoke-SysBuildRun -Name '~selftest_sysbuild_nuitka' -Builder 'nuitka'
$txtN = $runN.Text
$overrideSeen = $txtN -match [regex]::Escape('Using super-user override for PVW_BUILDER: nuitka')
$declinedN    = $txtN -match [regex]::Escape('[INFO] REQ-007: system-Python EXE build consent: declined.')
$namesNuitka  = $txtN -match [regex]::Escape('installs Nuitka into your system Python')
$namesPyi     = $txtN -match [regex]::Escape('installs PyInstaller into your system Python')
$noExeN       = -not (Test-Path -LiteralPath (Join-Path $runN.Dir 'dist'))
$passN = $overrideSeen -and $declinedN -and $namesNuitka -and (-not $namesPyi) -and $noExeN
Write-NdjsonRow ([ordered]@{
    id      = 'self.sysbuild.nuitka_prompt'
    req     = 'REQ-007'
    pass    = $passN
    desc    = 'REQ-007: with PVW_BUILDER=nuitka the system-Python build consent prompt names Nuitka, not PyInstaller'
    details = [ordered]@{ overrideSeen = $overrideSeen; declinedN = $declinedN; namesNuitka = $namesNuitka; namesPyi = $namesPyi; noExeN = $noExeN }
})

if (-not ($pass -and $passN)) { exit 1 }
exit 0
