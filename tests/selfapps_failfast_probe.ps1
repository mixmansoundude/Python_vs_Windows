# ASCII only
# selfapps_failfast_probe.ps1 - Slice 2b-C fail-fast probe: two untimed user-code launch points
# (:try_fast_exe, :verify_no_exe_interpreter) now dispatch to a probed launch when HP_INTERACTIVE_RUN
# is set. HP_TEST_FORCE_INTERACTIVE_PROBE=1 forces that branch under HP_CI_LANE for deterministic
# CI coverage (mirrors HP_TEST_FORCE_PICKER). Two scenarios, each its own cached-EXE fast-path run:
#
#   self.failfast.probe.fastfail - a cached EXE that fails FAST (well under the probe window) is
#     still discarded and rebuilt, exactly like the pre-existing (non-probed) behavior tested by
#     selfapps_exefastpath.ps1 -- this proves the probe dispatch does not change that outcome.
#
#   self.failfast.probe.alive - a cached EXE that is still running when the probe window elapses is
#     never discarded even if it LATER exits non-zero (it is the user's own program result, not
#     proof of a stale artifact); the bootstrap still reports the true outcome via an accurate
#     [STATUS] Run Status: FAILED line and stays HP_BOOTSTRAP_STATE=ok (a runtime bug in the user's
#     own code is not something a rebuild could fix). This is the critical decoupling fix for the
#     "silent success" gap: HP_FASTPATH_USED alone must never be read as proof of a clean run.
#
# Lane: real and conda-full only (matches selfapps_exefastpath.ps1).
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

$ndjsonIds = @('self.failfast.probe.fastfail', 'self.failfast.probe.alive')

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    foreach ($id in $ndjsonIds) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-018'
            pass    = $true
            desc    = 'Fail-fast probe test skipped on non-Windows host'
            details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
        })
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($id in $ndjsonIds) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-018'
            pass    = $false
            desc    = 'Fail-fast probe test: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    }
    exit 1
}

function Invoke-Bootstrap {
    param([string]$WorkDir, [string]$LogName)
    Push-Location -LiteralPath $WorkDir
    try {
        cmd /c "call run_setup.bat > $LogName 2>&1"
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

# --- Scenario A: fastfail -- cached EXE fails well within the probe window ---
# Reuses selfapps_exefastpath.ps1's proven failure mechanism (importlib.resources data file that
# is on disk for the interpreter but never bundled by PyInstaller, so the frozen EXE always exits
# non-zero immediately regardless of CWD) so run 1's build-smoke fails gracefully and run 2's fast
# path detects a genuinely broken cached EXE -- the only new variable is forcing the interactive
# probe branch on run 2.
$fastfailPass = $false
$fastfailDetails = [ordered]@{}
try {
    $ffDir = Join-Path $here '~selftest_failfastprobe_fastfail'
    if (Test-Path $ffDir) { Remove-Item -Recurse -Force $ffDir }
    New-Item -ItemType Directory -Force -Path $ffDir | Out-Null
    Copy-Item -Path $batchPath -Destination $ffDir -Force

    New-Item -ItemType Directory -Force -Path (Join-Path $ffDir 'mypkg') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $ffDir 'mypkg\data') | Out-Null
    Set-Content -Path (Join-Path $ffDir 'mypkg\__init__.py') -Value '' -Encoding ASCII
    Set-Content -Path (Join-Path $ffDir 'mypkg\data\info.txt') -Value 'hello-bundled-data' -Encoding ASCII
    Set-Content -Path (Join-Path $ffDir 'entry.py') -Value @'
import mypkg  # ensure PyInstaller traces and bundles the package itself
import importlib.resources as ir
print((ir.files("mypkg") / "data" / "info.txt").read_text())
'@ -Encoding ASCII

    $savedSkipPipreqsFf = $env:HP_SKIP_PIPREQS
    $savedNdjsonFf = $env:HP_NDJSON
    $savedLaneFf = $env:HP_CI_LANE
    $savedForceFf = $env:HP_TEST_FORCE_INTERACTIVE_PROBE
    $env:HP_SKIP_PIPREQS = '1'
    # Defensive: avoid the reused EXE's expected self.exe.smokerun pass=false row landing in the
    # gated NDJSON stream (mirrors selfapps_exefastpath.ps1); the fail-fast probe row is asserted
    # from the log text instead, which does not depend on HP_NDJSON.
    Remove-Item Env:HP_NDJSON -ErrorAction SilentlyContinue
    $env:HP_CI_LANE = 'test'

    $ffRun1Exit = Invoke-Bootstrap -WorkDir $ffDir -LogName '~ff_run1.log'
    $env:HP_TEST_FORCE_INTERACTIVE_PROBE = '1'
    $ffRun2Exit = Invoke-Bootstrap -WorkDir $ffDir -LogName '~ff_run2.log'

    if ($null -eq $savedSkipPipreqsFf) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $savedSkipPipreqsFf }
    if ($null -ne $savedNdjsonFf) { $env:HP_NDJSON = $savedNdjsonFf }
    if ($null -eq $savedLaneFf) { Remove-Item Env:HP_CI_LANE -ErrorAction SilentlyContinue } else { $env:HP_CI_LANE = $savedLaneFf }
    if ($null -eq $savedForceFf) { Remove-Item Env:HP_TEST_FORCE_INTERACTIVE_PROBE -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_INTERACTIVE_PROBE = $savedForceFf }

    $ffRun2LogPath = Join-Path $ffDir '~ff_run2.log'
    $ffRun2Lines = if (Test-Path $ffRun2LogPath) { Get-Content -LiteralPath $ffRun2LogPath -Encoding ASCII } else { @() }
    $ffRun2Text = $ffRun2Lines -join "`n"

    $ffLaunchedInteractive = $ffRun2Text -match [regex]::Escape('Launching your program now via the cached standalone EXE')
    $ffDiscarded = $ffRun2Text -match [regex]::Escape('discarding cached EXE and rebuilding')
    $ffNoAliveMsg = -not ($ffRun2Text -match [regex]::Escape('Fail-fast probe: still running after'))

    $fastfailPass = ($ffRun1Exit -eq 0) -and ($ffRun2Exit -eq 0) -and $ffLaunchedInteractive -and $ffDiscarded -and $ffNoAliveMsg
    $fastfailDetails = [ordered]@{
        run1Exit           = $ffRun1Exit
        run2Exit           = $ffRun2Exit
        launchedInteractive = $ffLaunchedInteractive
        discardedAndRebuilt = $ffDiscarded
        noAliveMsg          = $ffNoAliveMsg
        run2Log             = '~ff_run2.log'
    }
} catch {
    $fastfailDetails = [ordered]@{ error = $_.Exception.Message }
}

Write-NdjsonRow ([ordered]@{
    id      = 'self.failfast.probe.fastfail'
    req     = 'REQ-018'
    pass    = $fastfailPass
    desc    = 'Fail-fast probe: a cached EXE that fails within the probe window is still discarded and rebuilt'
    details = $fastfailDetails
})

# --- Scenario B: alive -- cached EXE is still running when the probe window elapses, then later
# exits non-zero. The critical assertion is the decoupling fix: the cached EXE must NOT be
# discarded, and the bootstrap must NOT silently report full success -- it must log the real
# outcome and keep HP_BOOTSTRAP_STATE=ok (env/build genuinely succeeded; a runtime bug in the
# user's own code is not proof of a stale artifact and not something a rebuild would fix).
$alivePass = $false
$aliveDetails = [ordered]@{}
try {
    $alDir = Join-Path $here '~selftest_failfastprobe_alive'
    if (Test-Path $alDir) { Remove-Item -Recurse -Force $alDir }
    New-Item -ItemType Directory -Force -Path $alDir | Out-Null
    Copy-Item -Path $batchPath -Destination $alDir -Force

    # Behaves differently per invocation via an inherited env var read at RUNTIME (not baked in
    # at PyInstaller build time), so the SAME frozen EXE binary built on run 1 (clean, fast exit)
    # can be driven into the ALIVE_AT_PROBE state on run 2 without a rebuild in between.
    Set-Content -Path (Join-Path $alDir 'entry.py') -Value @'
import os
import sys
import time

if os.environ.get("HP_TEST_APP_SHOULD_FAIL") == "1":
    time.sleep(6)
    sys.exit(7)
print("smoke-ok")
sys.exit(0)
'@ -Encoding ASCII

    $savedSkipPipreqsAl = $env:HP_SKIP_PIPREQS
    $savedLaneAl = $env:HP_CI_LANE
    $savedForceAl = $env:HP_TEST_FORCE_INTERACTIVE_PROBE
    $savedProbeMsAl = $env:HP_FAILFAST_PROBE_MS
    $savedShouldFailAl = $env:HP_TEST_APP_SHOULD_FAIL
    $env:HP_SKIP_PIPREQS = '1'
    $env:HP_CI_LANE = 'test'
    # A short probe window with generous margin against the 6s sleep above avoids CI-runner-load
    # flakiness in either direction (misclassifying a slow-starting-but-fast-exiting run as alive,
    # or the reverse).
    $env:HP_FAILFAST_PROBE_MS = '1000'

    $env:HP_TEST_APP_SHOULD_FAIL = '0'
    $alRun1Exit = Invoke-Bootstrap -WorkDir $alDir -LogName '~al_run1.log'

    $env:HP_TEST_FORCE_INTERACTIVE_PROBE = '1'
    $env:HP_TEST_APP_SHOULD_FAIL = '1'
    $alRun2Exit = Invoke-Bootstrap -WorkDir $alDir -LogName '~al_run2.log'

    if ($null -eq $savedSkipPipreqsAl) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $savedSkipPipreqsAl }
    if ($null -eq $savedLaneAl) { Remove-Item Env:HP_CI_LANE -ErrorAction SilentlyContinue } else { $env:HP_CI_LANE = $savedLaneAl }
    if ($null -eq $savedForceAl) { Remove-Item Env:HP_TEST_FORCE_INTERACTIVE_PROBE -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_INTERACTIVE_PROBE = $savedForceAl }
    if ($null -eq $savedProbeMsAl) { Remove-Item Env:HP_FAILFAST_PROBE_MS -ErrorAction SilentlyContinue } else { $env:HP_FAILFAST_PROBE_MS = $savedProbeMsAl }
    if ($null -eq $savedShouldFailAl) { Remove-Item Env:HP_TEST_APP_SHOULD_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_APP_SHOULD_FAIL = $savedShouldFailAl }

    $alRun2LogPath = Join-Path $alDir '~al_run2.log'
    $alRun2Lines = if (Test-Path $alRun2LogPath) { Get-Content -LiteralPath $alRun2LogPath -Encoding ASCII } else { @() }
    $alRun2Text = $alRun2Lines -join "`n"
    $alStatusPath = Join-Path $alDir '~bootstrap.status.json'
    $alStatusState = $null
    if (Test-Path $alStatusPath) {
        try { $alStatusState = (Get-Content -LiteralPath $alStatusPath -Raw | ConvertFrom-Json).state } catch { $alStatusState = $null }
    }
    $alExePath = Join-Path $alDir 'dist\env.exe'
    # ENVNAME normalizes to the workdir folder name; fall back to a wildcard lookup so this does
    # not depend on guessing run_setup.bat's exact sanitization for this particular folder name.
    $alExeCandidates = @(Get-ChildItem -Path (Join-Path $alDir 'dist') -Filter '*.exe' -ErrorAction SilentlyContinue)

    $alLaunchedInteractive = $alRun2Text -match [regex]::Escape('Launching your program now via the cached standalone EXE')
    $alAliveMsg = $alRun2Text -match [regex]::Escape('Fail-fast probe: still running after')
    $alStatusFailed = $alRun2Text -match [regex]::Escape('Run Status: FAILED (Exit Code: 7)')
    $alNotDiscarded = -not ($alRun2Text -match [regex]::Escape('discarding cached EXE and rebuilding'))
    $alExeStillPresent = $alExeCandidates.Count -gt 0
    $alBootstrapStayedOk = ($alStatusState -eq 'ok')

    $alivePass = ($alRun1Exit -eq 0) -and ($alRun2Exit -eq 0) -and $alLaunchedInteractive -and $alAliveMsg -and $alStatusFailed -and $alNotDiscarded -and $alExeStillPresent -and $alBootstrapStayedOk
    $aliveDetails = [ordered]@{
        run1Exit             = $alRun1Exit
        run2Exit             = $alRun2Exit
        launchedInteractive  = $alLaunchedInteractive
        aliveMsgLogged       = $alAliveMsg
        statusFailedLogged   = $alStatusFailed
        notDiscarded         = $alNotDiscarded
        exeStillPresent      = $alExeStillPresent
        bootstrapState       = $alStatusState
        run2Log              = '~al_run2.log'
    }
} catch {
    $aliveDetails = [ordered]@{ error = $_.Exception.Message }
}

Write-NdjsonRow ([ordered]@{
    id      = 'self.failfast.probe.alive'
    req     = 'REQ-018'
    pass    = $alivePass
    desc    = 'Fail-fast probe: a cached EXE still running past the probe window is never discarded, even if it later exits non-zero; the bootstrap reports the true outcome and stays state=ok'
    details = $aliveDetails
})

if (-not ($fastfailPass -and $alivePass)) { exit 1 }
exit 0
