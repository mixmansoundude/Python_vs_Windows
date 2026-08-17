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
# CLAUDE.md Active Backlog Item 46 (Bucket B, closed): all three call sites now route through
# :warn_build_incomplete instead of :die -- by the time any of them is reached, every build tool
# (PyInstaller AND the Nuitka fallback) has already failed, but the run is not doomed (the
# interpreter-fallback verification below still genuinely runs and still genuinely decides
# success/failure), so :die's mid-run pause and premature lock release were both wrong here.
# :warn_build_incomplete still sets HP_BOOTSTRAP_STATE=error, so every assertion below is
# unchanged -- only the message's [WARN]/[ERROR] prefix and the pause/lock-release timing
# changed, neither of which this test's own assertions inspect (CI never pauses at :die either
# way, since HP_CI_LANE is always set).
#
# Three scenarios via PYI_FAIL_SCENARIO env var (research Finding 2,
# docs/prd-av-safe-build-path.md): "execfail" forces the build command itself to fail
# (HP_TEST_FORCE_PYINSTALLER_FAIL=1); "output_vanish" lets a real build succeed, then deletes
# dist\<env>.exe immediately after (HP_TEST_FORCE_OUTPUT_VANISH=1) to simulate AV-style
# post-creation removal as a distinct trigger condition from the build command failing outright;
# "execfail_runtimefail" (added for [REQ-027] P2 honest messaging) is "execfail" PLUS a stub app
# that ALSO exits non-zero when run via the interpreter fallback, exercising the compound
# failure the other two scenarios' clean-exiting stub app never reaches.
#
# Asserts (all scenarios): the final ~bootstrap.status.json reads state=error (not silently
# overwritten back to ok), the correct failure message (now [WARN]-prefixed, see the Bucket B
# note above -- the assertion itself matches the message substring and reason= token only, not
# the prefix) appears in the log, and (docs/open-questions.md item 1) the dedicated
# :print_no_exe_briefing panel is shown. For "execfail"/
# "output_vanish", the stub app runs cleanly via the interpreter fallback despite total packaging
# failure, so the final console [STATUS] line alone would otherwise read identically to a real
# success -- the plain (non-caveat) panel text is asserted. For "execfail_runtimefail", the
# interpreter fallback ALSO exits non-zero -- [REQ-027]'s HP_NOEXE_VERIFY_FAILED-gated caveat
# panel text is asserted instead, confirming the panel no longer claims "your code ran
# successfully" when it did not (a real, pre-existing dishonest claim this closes). Does NOT
# assert a non-zero process exit code -- :success's own `exit /b 0` runs unconditionally
# regardless of HP_BOOTSTRAP_STATE, matching this repo's established "graceful stop" contract
# for this class of failure (see selfapps_preflight.ps1's sibling test, which likewise never
# checks exit code).
#
# This also directly satisfies requirement 1's first fixture from the AV-Safe Build Path PRD
# ("a generic PyInstaller build failure... confirmed [to fail] against the current (pre-fallback)
# codebase in the expected way, confirmed before any fallback code is written") -- "the expected
# way" is now a clean, correctly-reported failure, not the masked-success bug this test guards.
#
# Also sets HP_TEST_FORCE_NUITKA_FAIL=1 (requirements 2-4, Tier A, shipped after this test was
# first written): once :try_nuitka_tier_a existed, a real Nuitka build against the trivial stub
# app below would likely succeed for real on a Windows CI runner with MSVC available, silently
# turning this "everything fails, report error correctly" test into a fallback-success case --
# a different scenario with its own test (self.exe.build.tiera). Forcing the fallback to also
# fail keeps this test's original scope: tier EXHAUSTION still reaches a correctly-reported error.
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

if ($scenario -eq 'execfail_runtimefail') {
    Set-Content -Path (Join-Path $workDir 'app.py') -Value @'
import sys
print("i-tried-but-failed")
sys.exit(3)
'@ -Encoding ASCII
} else {
    Set-Content -Path (Join-Path $workDir 'app.py') -Value @'
print("should-not-matter")
'@ -Encoding ASCII
}

$bootstrapLog = "~pyi_fail_${scenario}_bootstrap.log"

$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevForceExecfail = if (Test-Path Env:HP_TEST_FORCE_PYINSTALLER_FAIL) { $env:HP_TEST_FORCE_PYINSTALLER_FAIL } else { $null }
$prevForceVanish = if (Test-Path Env:HP_TEST_FORCE_OUTPUT_VANISH) { $env:HP_TEST_FORCE_OUTPUT_VANISH } else { $null }
$prevForceNuitkaFail = if (Test-Path Env:HP_TEST_FORCE_NUITKA_FAIL) { $env:HP_TEST_FORCE_NUITKA_FAIL } else { $null }
$env:HP_SKIP_PIPREQS = '1'
$env:HP_TEST_FORCE_NUITKA_FAIL = '1'
if ($scenario -eq 'execfail' -or $scenario -eq 'execfail_runtimefail') {
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

    $expectedMsg = if ($scenario -eq 'execfail' -or $scenario -eq 'execfail_runtimefail') { 'PyInstaller execution failed' } else { 'PyInstaller did not produce dist' }
    $expectedMsgFound = $combined -match [regex]::Escape($expectedMsg)
    $testHookFired = $combined -match [regex]::Escape('HP_TEST_FORCE')
    # CLAUDE.md Item 33: both scenarios here reach the :die call via HP_TEST_FORCE_PYINSTALLER_FAIL
    # or HP_TEST_FORCE_OUTPUT_VANISH, never a genuine nonzero PyInstaller exit (reason=build_error
    # is real code but not exercised by any deterministic CI hook -- same "extrapolated, not tested"
    # status as a real Nuitka compiler failure elsewhere in this repo).
    $expectedReason = if ($scenario -eq 'execfail' -or $scenario -eq 'execfail_runtimefail') { 'reason=test_forced_fail' } else { 'reason=missing_output' }
    # derived requirement: match the reason token on the SAME log line as $expectedMsg, not
    # anywhere in the combined log -- this scenario also forces the Nuitka fallback to fail, so a
    # whole-log match could in principle be satisfied by an unrelated line rather than genuinely
    # proving the PyInstaller [ERROR] line itself carries the right token.
    $expectedFailureLines = @($logLines | Where-Object { $_ -match [regex]::Escape($expectedMsg) })
    $expectedReasonFound = [bool]($expectedFailureLines | Where-Object { $_ -match [regex]::Escape($expectedReason) } | Select-Object -First 1)
    # docs/open-questions.md item 1: when packaging fails outright but the interpreter fallback
    # still runs cleanly, :print_no_exe_briefing (run_setup.bat) prints a dedicated panel instead
    # of leaving the bare "[STATUS] Run Status: SUCCESS" line as the only thing the user sees.
    # [REQ-027] P2 honest messaging: "execfail_runtimefail" makes the interpreter fallback ALSO
    # fail, so the panel must show the HP_NOEXE_VERIFY_FAILED-gated caveat text instead of the
    # plain "your code ran successfully" text the other two scenarios still correctly expect.
    $noExeBriefingFound = if ($scenario -eq 'execfail_runtimefail') {
        $combined -match [regex]::Escape("NO STANDALONE .EXE -- AND WE CAN'T CONFIRM YOUR CODE RAN CLEANLY")
    } else {
        $combined -match [regex]::Escape('YOUR CODE RAN -- BUT NO STANDALONE .EXE WAS PRODUCED')
    }

    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusText = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw } else { $null }
    $statusState = $null
    if ($statusText) {
        try { $statusState = ($statusText | ConvertFrom-Json).state } catch { $statusState = $null }
    }

    # xfailPass: the test hook fired, the correct [ERROR] message was logged, and the final
    # status.json genuinely says "error" -- not silently overwritten back to "ok" by
    # :after_cascade_decision (the exact bug this test guards). bootstrapExit is captured for
    # diagnostics only and is deliberately NOT part of the pass condition: :success's own
    # `exit /b 0` runs unconditionally regardless of HP_BOOTSTRAP_STATE (this repo's established
    # "graceful stop" contract for this class of failure -- see selfapps_preflight.ps1's own
    # $pass condition, the sibling test for the pre-existing HP_BOOTSTRAP_STATE=error precedent,
    # which likewise never checks the process exit code).
    $xfailPass = $testHookFired -and $expectedMsgFound -and $expectedReasonFound -and ($statusState -eq 'error') -and $noExeBriefingFound

    Write-PyiFailRow -Pass $xfailPass -Desc "PyInstaller build XFAIL ($scenario): build failure correctly reported, not masked as success" -Details ([ordered]@{
        scenario             = $scenario
        bootstrapExit        = $runExit
        testHookFired        = [bool]$testHookFired
        expectedMsgFound     = [bool]$expectedMsgFound
        expectedReasonFound  = [bool]$expectedReasonFound
        statusState          = $statusState
        noExeBriefingFound   = [bool]$noExeBriefingFound
        xfailPass            = $xfailPass
        log                  = $bootstrapLog
    })
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevForceExecfail) { Remove-Item Env:HP_TEST_FORCE_PYINSTALLER_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PYINSTALLER_FAIL = $prevForceExecfail }
    if ($null -eq $prevForceVanish) { Remove-Item Env:HP_TEST_FORCE_OUTPUT_VANISH -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_OUTPUT_VANISH = $prevForceVanish }
    if ($null -eq $prevForceNuitkaFail) { Remove-Item Env:HP_TEST_FORCE_NUITKA_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_NUITKA_FAIL = $prevForceNuitkaFail }
}

if (-not $xfailPass) { exit 1 }
exit 0
