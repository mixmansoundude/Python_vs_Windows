# ASCII only
# selfapps_optimized_build.ps1 - proves AV-Safe Build Path requirement 9 (P1, docs/prd-av-safe-
# build-path.md): after a NORMAL, verified-successful PyInstaller build, :offer_optimized_build
# offers an elective, human-only, auto-declined-in-CI upsell to also build a Nuitka-optimized
# version. Unlike Tier A (which is free to delete-then-rebuild because the original build already
# failed), this feature must NEVER touch the already-working PyInstaller EXE unless the
# replacement is confirmed to build AND run successfully -- three scenarios prove all three
# outcomes.
#
# Scenarios (OPTBUILD_SCENARIO env var):
#   accept    - HP_TEST_OPTBUILD_ANSWER=Y, no forced failure: a REAL Nuitka build runs, is
#               verified, and is swapped into dist\<env>.exe in place of the PyInstaller build.
#               Non-gating (uv lane) like selfapps_nuitka_tiera.ps1 -- depends on a real Nuitka
#               build succeeding, which could not be verified locally.
#   forcefail - HP_TEST_OPTBUILD_ANSWER=Y + HP_TEST_FORCE_OPTBUILD_FAIL=1: the optimized build is
#               forced to fail deterministically (no real Nuitka attempt). Asserts the ORIGINAL
#               PyInstaller-built dist\<env>.exe is left completely untouched and still runs.
#   decline   - No HP_TEST_OPTBUILD_ANSWER set: falls through to the ambient HP_CI_LANE
#               auto-decline (same mechanism selfapps_postexec_checkpoint.ps1's own
#               self.checkpoint.decline scenario relies on). Asserts the prompt is shown but no
#               build is attempted at all.
#
# All three scenarios in one file/lane for simplicity, matching this repo's established pattern
# for multi-scenario tests (e.g. selfapps_pyinstaller_fail.ps1's PYI_FAIL_SCENARIO). Kept entirely
# in the uv lane (non-gating) so the 'accept' scenario's real-Nuitka-build dependency doesn't need
# separate lane wiring from its two deterministic siblings; promote once proven stable, matching
# this repo's established graduation pattern (see CLAUDE.md's "CI lane gating maturity" check).
#
# Emits: self.optbuild.offer
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

$scenario = $env:OPTBUILD_SCENARIO
if (-not $scenario) { $scenario = 'accept' }

function Write-OptBuildRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.optbuild.offer'; req = 'REQ-AV'; pass = $Pass; desc = $Desc; details = $Details })
}

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-OptBuildRow -Pass $true -Desc "AV-Safe Build Path requirement 9 ($scenario, skipped on non-Windows)" -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host'; scenario = $scenario })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-OptBuildRow -Pass $false -Desc 'AV-Safe Build Path requirement 9: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath; scenario = $scenario })
    exit 1
}

$workDir = Join-Path $here "~selftest_optbuild_$scenario"
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

Set-Content -Path (Join-Path $workDir 'app.py') -Value @'
print("optbuild-app-ok")
'@ -Encoding ASCII

$bootstrapLog = "~optbuild_${scenario}_bootstrap.log"

$prevSkipPipreqs   = if (Test-Path Env:HP_SKIP_PIPREQS)             { $env:HP_SKIP_PIPREQS }             else { $null }
$prevOptAnswer     = if (Test-Path Env:HP_TEST_OPTBUILD_ANSWER)     { $env:HP_TEST_OPTBUILD_ANSWER }     else { $null }
$prevForceOptFail  = if (Test-Path Env:HP_TEST_FORCE_OPTBUILD_FAIL) { $env:HP_TEST_FORCE_OPTBUILD_FAIL } else { $null }
$env:HP_SKIP_PIPREQS = '1'
if ($scenario -eq 'accept') {
    $env:HP_TEST_OPTBUILD_ANSWER = 'Y'
} elseif ($scenario -eq 'forcefail') {
    $env:HP_TEST_OPTBUILD_ANSWER = 'Y'
    $env:HP_TEST_FORCE_OPTBUILD_FAIL = '1'
}
# 'decline' scenario: deliberately leaves both unset, relying on the ambient HP_CI_LANE
# auto-decline the same way selfapps_postexec_checkpoint.ps1's self.checkpoint.decline does.

try {
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $logPath  = Join-Path $workDir $bootstrapLog
    $logLines = if (Test-Path $logPath) { Get-Content -LiteralPath $logPath -Encoding ASCII } else { @() }
    $combined = $logLines -join "`n"

    $envLeaf  = Split-Path $workDir -Leaf
    $envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
    if (-not $envName) { $envName = '_env' }
    $exePath    = Join-Path $workDir "dist\$envName.exe"
    $tmpExePath = Join-Path $workDir "dist\$envName.optimized_build.exe"
    $exeExists  = Test-Path -LiteralPath $exePath
    $tmpExeGone = -not (Test-Path -LiteralPath $tmpExePath)

    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusText = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw } else { $null }
    $statusState = $null
    if ($statusText) {
        try { $statusState = ($statusText | ConvertFrom-Json).state } catch { $statusState = $null }
    }

    $promptShown = $combined -match [regex]::Escape('Want to build an optimized version too?')

    if ($scenario -eq 'accept') {
        $acceptedLogged = $combined -match [regex]::Escape('Optimized build: accepted')
        $successLogged  = $combined -match [regex]::Escape('Optimized build succeeded and verified')

        $appStillRuns = $false
        if ($exeExists) {
            try {
                Push-Location (Join-Path $workDir 'dist')
                try {
                    $out = & "$envName.exe" 2>&1
                    $appStillRuns = ($LASTEXITCODE -eq 0) -and ($out -join "`n") -match [regex]::Escape('optbuild-app-ok')
                } finally { Pop-Location }
            } catch { $appStillRuns = $false }
        }

        $pass = $promptShown -and $acceptedLogged -and $successLogged -and $exeExists -and $tmpExeGone -and $appStillRuns -and ($statusState -eq 'ok')
        Write-OptBuildRow -Pass $pass -Desc 'AV-Safe Build Path requirement 9 (accept): a real optimized build succeeds, verifies, and is swapped into place' -Details ([ordered]@{
            scenario        = $scenario
            bootstrapExit   = $runExit
            promptShown     = [bool]$promptShown
            acceptedLogged  = [bool]$acceptedLogged
            successLogged   = [bool]$successLogged
            exeExists       = [bool]$exeExists
            tmpExeGone      = [bool]$tmpExeGone
            appStillRuns    = [bool]$appStillRuns
            statusState     = $statusState
            log             = $bootstrapLog
        })
    } elseif ($scenario -eq 'forcefail') {
        $testHookFired  = $combined -match [regex]::Escape('HP_TEST_FORCE_OPTBUILD_FAIL')
        $noSuccessMsg   = -not ($combined -match [regex]::Escape('Optimized build succeeded and verified'))

        $originalStillRuns = $false
        if ($exeExists) {
            try {
                Push-Location (Join-Path $workDir 'dist')
                try {
                    $out = & "$envName.exe" 2>&1
                    $originalStillRuns = ($LASTEXITCODE -eq 0) -and ($out -join "`n") -match [regex]::Escape('optbuild-app-ok')
                } finally { Pop-Location }
            } catch { $originalStillRuns = $false }
        }

        $pass = $promptShown -and $testHookFired -and $noSuccessMsg -and $exeExists -and $tmpExeGone -and $originalStillRuns -and ($statusState -eq 'ok')
        Write-OptBuildRow -Pass $pass -Desc 'AV-Safe Build Path requirement 9 (forcefail): a failed optimized build leaves the original PyInstaller EXE completely untouched' -Details ([ordered]@{
            scenario           = $scenario
            bootstrapExit      = $runExit
            promptShown        = [bool]$promptShown
            testHookFired      = [bool]$testHookFired
            noSuccessMsg       = [bool]$noSuccessMsg
            exeExists          = [bool]$exeExists
            tmpExeGone         = [bool]$tmpExeGone
            originalStillRuns  = [bool]$originalStillRuns
            statusState        = $statusState
            log                = $bootstrapLog
        })
    } else {
        $declinedLogged = $combined -match [regex]::Escape('Optimized build: declined')
        $noBuildAttempt = -not ($combined -match [regex]::Escape('Optimized build: accepted'))

        $pass = $promptShown -and $declinedLogged -and $noBuildAttempt -and $exeExists -and $tmpExeGone -and ($statusState -eq 'ok')
        Write-OptBuildRow -Pass $pass -Desc 'AV-Safe Build Path requirement 9 (decline): default/CI path shows the prompt but never attempts a build' -Details ([ordered]@{
            scenario        = $scenario
            bootstrapExit   = $runExit
            promptShown     = [bool]$promptShown
            declinedLogged  = [bool]$declinedLogged
            noBuildAttempt  = [bool]$noBuildAttempt
            exeExists       = [bool]$exeExists
            tmpExeGone      = [bool]$tmpExeGone
            statusState     = $statusState
            log             = $bootstrapLog
        })
    }
} finally {
    if ($null -eq $prevSkipPipreqs)  { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue }             else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevOptAnswer)    { Remove-Item Env:HP_TEST_OPTBUILD_ANSWER -ErrorAction SilentlyContinue }     else { $env:HP_TEST_OPTBUILD_ANSWER = $prevOptAnswer }
    if ($null -eq $prevForceOptFail) { Remove-Item Env:HP_TEST_FORCE_OPTBUILD_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_OPTBUILD_FAIL = $prevForceOptFail }
}

if (-not $pass) { exit 1 }
exit 0
