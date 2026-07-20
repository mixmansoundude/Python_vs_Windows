# ASCII only
# selfapps_pyinstaller_fail.ps1 - XFAIL test: PyInstaller BUILD ITSELF fails (distinct from
# selfapps_exefail.ps1, which tests a successfully-built EXE crashing at runtime).
#
# Regression test for a real bug found 2026-07-20 while scoping the AV-Safe Build Path PRD's
# requirement-1 failure-simulation tests (docs/prd-av-safe-build-path.md): when the PyInstaller
# build command itself failed (nonzero exit, or never produced dist\<env>.exe), :die only
# returns from its own `call` frame -- it does not halt the process -- and nothing downstream
# re-checked the outcome. The bootstrapper silently fell back to running the raw entry via the
# interpreter, then :after_cascade_decision unconditionally overwrote ~bootstrap.status.json
# back to state=ok and the process exited 0, masking the build failure the user explicitly
# consented to (HP_BUILD_OK). Fixed by setting HP_BOOTSTRAP_STATE=error at the PyInstaller
# build call site, mirroring the existing preflight-failure precedent in :run_entry_smoke.
#
# Two scenarios via PYI_FAIL_SCENARIO env var (research Finding 2,
# docs/prd-av-safe-build-path.md): "execfail" forces the build command itself to fail
# (HP_TEST_FORCE_PYINSTALLER_FAIL=1); "output_vanish" lets a real build succeed, then deletes
# dist\<env>.exe immediately after (HP_TEST_FORCE_OUTPUT_VANISH=1) to simulate AV-style
# post-creation removal as a distinct trigger condition from the build command failing outright.
#
# Asserts (both scenarios): the bootstrap process exits non-zero, the final
# ~bootstrap.status.json reads state=error (not silently overwritten back to ok), and the
# correct [ERROR] message appears in the log.
#
# This also directly satisfies requirement 1's first fixture from the AV-Safe Build Path PRD
# ("a generic PyInstaller build failure... confirmed [to fail] against the current (pre-fallback)
# codebase in the expected way, confirmed before any fallback code is written") -- "the expected
# way" is now a clean, correctly-reported failure, not the masked-success bug this test guards.
#
# Lane: real and conda-full only (matches selfapps_exefail.ps1 and siblings).
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

$scenario = $env:PYI_FAIL_SCENARIO
if (-not $scenario) { $scenario = 'execfail' }

function Write-PyiFailRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.exe.build.xfail'; req = 'REQ-003'; pass = $Pass; desc = $Desc; details = $Details })
}

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-PyiFailRow -Pass $true -Desc "PyInstaller build XFAIL ($scenario, skipped on non-Windows)" -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host'; scenario = $scenario })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-PyiFailRow -Pass $false -Desc 'PyInstaller build XFAIL: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath; scenario = $scenario })
    exit 1
}

$workDir = Join-Path $here "~selftest_pyi_fail_$scenario"
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

Set-Content -Path (Join-Path $workDir 'app.py') -Value @'
print("should-not-matter")
'@ -Encoding ASCII

$bootstrapLog = "~pyi_fail_${scenario}_bootstrap.log"

$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevForceExecfail = if (Test-Path Env:HP_TEST_FORCE_PYINSTALLER_FAIL) { $env:HP_TEST_FORCE_PYINSTALLER_FAIL } else { $null }
$prevForceVanish = if (Test-Path Env:HP_TEST_FORCE_OUTPUT_VANISH) { $env:HP_TEST_FORCE_OUTPUT_VANISH } else { $null }
$env:HP_SKIP_PIPREQS = '1'
if ($scenario -eq 'execfail') {
    $env:HP_TEST_FORCE_PYINSTALLER_FAIL = '1'
} else {
    $env:HP_TEST_FORCE_OUTPUT_VANISH = '1'
}

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

    $expectedMsg = if ($scenario -eq 'execfail') { 'PyInstaller execution failed' } else { 'PyInstaller did not produce dist' }
    $expectedMsgFound = $combined -match [regex]::Escape($expectedMsg)
    $testHookFired = $combined -match [regex]::Escape('HP_TEST_FORCE')

    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusText = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw } else { $null }
    $statusState = $null
    if ($statusText) {
        try { $statusState = ($statusText | ConvertFrom-Json).state } catch { $statusState = $null }
    }

    # xfailPass: the test hook fired, the correct [ERROR] message was logged, the bootstrap
    # process exited non-zero, AND the final status.json genuinely says "error" -- not silently
    # overwritten back to "ok" by :after_cascade_decision (the exact bug this test guards).
    $xfailPass = $testHookFired -and $expectedMsgFound -and ($runExit -ne 0) -and ($statusState -eq 'error')

    Write-PyiFailRow -Pass $xfailPass -Desc "PyInstaller build XFAIL ($scenario): build failure correctly reported, not masked as success" -Details ([ordered]@{
        scenario          = $scenario
        bootstrapExit     = $runExit
        testHookFired     = [bool]$testHookFired
        expectedMsgFound  = [bool]$expectedMsgFound
        statusState       = $statusState
        xfailPass         = $xfailPass
        log               = $bootstrapLog
    })
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevForceExecfail) { Remove-Item Env:HP_TEST_FORCE_PYINSTALLER_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PYINSTALLER_FAIL = $prevForceExecfail }
    if ($null -eq $prevForceVanish) { Remove-Item Env:HP_TEST_FORCE_OUTPUT_VANISH -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_OUTPUT_VANISH = $prevForceVanish }
}

if (-not $xfailPass) { exit 1 }
exit 0
