# ASCII only
# selfapps_entrysmoke_no_interpreter.ps1 - Regression coverage for CLAUDE.md Active Backlog
# Item 45: gate the build/warnfix/repair block on HP_PY actually existing, so a failed
# env-create cannot cascade into a doomed PyInstaller build (plus warnfix/DLL-bundle/hidden-
# import repair attempts) with no real interpreter behind any of it.
#
# :die uses "exit /b" (a subroutine return, not a process halt -- see docs/agent-lessons-
# learned.md's ":die" entry), so a caller with no goto/halt after "call :die" simply continues.
# A genuine (not HP_TEST_FORCE_CONDA_FAIL-bypassed) FIRST-ATTEMPT conda-create failure exercises
# a path that was never directly tested before this item.
#
# CLAUDE.md Active Backlog Item 46 (Bucket A, slice 1, closed): :conda_create_failed used to
# fall through :die into :conda_create_done, which unconditionally set HP_PY to the conda env's
# expected (but never-produced) python.exe path, then its own "if not exist %HP_PY%" guard
# called :handle_conda_failure A SECOND TIME -- not just wasted CPU, a real user would have seen
# the embed/venv attempts and the REQ-014 system-Python consent prompt replay a second time
# right after already answering them once. Fixed with a goto straight to
# :after_env_mode_selection (matching the already-shipped :hp_test_conda_fail sibling), so
# :conda_create_done's body is skipped entirely on this path -- the old, redundant
# "[ERROR] python.exe missing from conda environment." message this test used to assert is now
# provably absent (see secondHandleCallAvoided below). This does NOT reduce the bootstrap to a
# single pause for a real interactive user -- :after_env_mode_selection's own "if not defined
# HP_PY" check has the identical non-halting shape and is what now reports the terminal failure
# (see the honest-message assertions below), tracked as a separate, not-yet-addressed follow-up
# slice in CLAUDE.md's Item 46 entry.
#
# This is a genuinely different call path than either of selfapps_cascade_conda_create_fail.
# ps1's two scenarios (both are REQ-009 cascade RE-ENTRIES, where HP_CASCADE_SAVED_PY is
# defined and routes through :cascade_conda_create_failed instead -- HP_PY is never touched by
# :conda_create_done on that path at all) and self.embed.fallback.decline in
# selfapps_ux_hardening.ps1 (which forces conda to fail via the HP_TEST_FORCE_CONDA_FAIL bypass,
# never reaching :conda_create_done's own HP_PY-setting line either). This is the one scenario
# that reaches :conda_create_done with a HP_PY that is defined but does not exist on disk.
#
# HP_FORCE_CONDA_ONLY=1 makes :handle_conda_failure a no-op on both calls (embed/venv/system
# fallback attempts are all skipped for this lane by design), so total tier exhaustion is
# reached deterministically without needing embed/venv/system-specific forced-failure hooks.
# HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL=1 forces the REAL conda create/retry code path to fail
# both attempts deterministically (matching Item 23's own established convention that the
# HP_TEST_FORCE_CONDA_FAIL bypass is not sufficient evidence for this class of gap -- see
# selfapps_cascade_conda_create_fail.ps1's own header comment).
#
# Asserts the actual Item 45 guard: no PyInstaller build is ever attempted ("Building standalone
# executable" absent), the honest "No Python interpreter is available" message appears (proving
# HP_NO_INTERPRETER was set -- either by :after_env_mode_selection's own interpreter smoke test,
# or by this item's new direct guard at the top of :run_entry_smoke, whichever fires first), the
# old fabricated "syntax error" message is absent (CLAUDE.md former Active Backlog item 14's own
# regression -- see selfapps_ux_hardening.ps1's self.embed.fallback.decline for the sibling
# assertion), and ~bootstrap.status.json reads state=error with a graceful (exit 0) process exit
# (this repo's established "graceful stop" contract -- see selfapps_conda_bothfail.ps1's sibling
# reasoning).
#
# Lane: conda-full only, gated on steps.conda_avail.outputs.available == 'true' (same gate 28+
# other conda-full-only self-tests already use) -- guarantees real Miniconda is already present
# (HP_FORCE_CONDA_ONLY=1 makes this test's own conda create attempt the FIRST thing reached, so
# it needs CONDA_BAT to already exist rather than triggering a fresh Miniconda download itself).
# Deterministic (no real network dependency for the create failure itself) and self-contained
# (own HP_FORCE_CONDA_ONLY=1 override, matching selfapps_pipgap.ps1's own established pattern),
# so gating from first landing.
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

# derived requirement: $IsWindows is undefined (reads as $null) under Windows PowerShell 5.1 --
# only introduced in PowerShell 6+. [System.Environment]::OSVersion.Platform works on both.
$platform = [System.Environment]::OSVersion.Platform.ToString()
if ($platform -ne 'Win32NT') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entrysmoke.no_interpreter_guard'
        req     = 'CLAUDE.md-Item-45'
        pass    = $true
        desc    = 'Entry-smoke no-interpreter guard (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entrysmoke.no_interpreter_guard'
        req     = 'CLAUDE.md-Item-45'
        pass    = $false
        desc    = 'Entry-smoke no-interpreter guard: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_entrysmoke_no_interpreter'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force
Set-Content -Path (Join-Path $workDir 'app.py') -Value 'print("should-not-run")' -Encoding ASCII

$bootstrapLog = '~entrysmoke_no_interpreter_bootstrap.log'

$prevForceCondaOnly = if (Test-Path Env:HP_FORCE_CONDA_ONLY) { $env:HP_FORCE_CONDA_ONLY } else { $null }
$prevCcBothFail     = if (Test-Path Env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL) { $env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL } else { $null }
$prevSkipPipreqs    = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_FORCE_CONDA_ONLY = '1'
$env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL = '1'
$env:HP_SKIP_PIPREQS = '1'

try {
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} finally {
    if ($null -eq $prevForceCondaOnly) { Remove-Item Env:HP_FORCE_CONDA_ONLY -ErrorAction SilentlyContinue } else { $env:HP_FORCE_CONDA_ONLY = $prevForceCondaOnly }
    if ($null -eq $prevCcBothFail)     { Remove-Item Env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL = $prevCcBothFail }
    if ($null -eq $prevSkipPipreqs)    { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logText   = if (Test-Path -LiteralPath $logPath)  { Get-Content -LiteralPath $logPath  -Raw -Encoding ASCII } else { '' }
$setupText = if (Test-Path -LiteralPath $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = $logText + "`n" + $setupText

$initialAttemptFailed = $combined -match [regex]::Escape('CondaHTTPError: HTTP 000 CONNECTION FAILED (simulated)')
$retryAlsoFailed      = $combined -match [regex]::Escape('conda create: retry after transient failure also failed')

# Item 46 Bucket A slice 1: the old, redundant ":conda_create_done"-specific message must no
# longer appear at all -- proving the new goto skipped that whole block, instead of merely
# reaching it a second time. "Active Python interpreter not resolved." (from
# :after_env_mode_selection's own "if not defined HP_PY" check) is the new site that reports the
# terminal failure instead -- see this file's own header comment for why that site is a
# still-open follow-up, not itself fixed by this slice.
$secondHandleCallAvoided = -not ($combined -match [regex]::Escape('[ERROR] python.exe missing from conda environment.'))
$reachedNewSite          = $combined -match [regex]::Escape('[ERROR] Active Python interpreter not resolved.')

# The actual Item 45 guard: the honest no-interpreter message fires, the old fabricated
# syntax-error message never fires, and -- the key assertion -- no PyInstaller build is ever
# attempted against the broken interpreter.
$honestNoInterpreterMsg = $combined -match [regex]::Escape('No Python interpreter is available')
$noFakeSyntaxErr        = -not ($combined -match [regex]::Escape('Your Python program has a syntax error'))
$noBuildAttempt         = -not ($combined -match [regex]::Escape('Building standalone executable'))

$statusPath = Join-Path $workDir '~bootstrap.status.json'
$statusState = $null
$statusExit  = $null
if (Test-Path -LiteralPath $statusPath) {
    try {
        $status = Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json
        $statusState = $status.state
        $statusExit  = $status.exitCode
    } catch { }
}

$pass = $initialAttemptFailed -and $retryAlsoFailed -and $secondHandleCallAvoided -and $reachedNewSite -and
        $honestNoInterpreterMsg -and $noFakeSyntaxErr -and $noBuildAttempt -and
        ($statusState -eq 'error') -and ($runExit -eq 0)

Write-Host "=== self.entrysmoke.no_interpreter_guard evidence ==="
Write-Host ("initialAttemptFailed={0} retryAlsoFailed={1} secondHandleCallAvoided={2} reachedNewSite={3} honestNoInterpreterMsg={4} noFakeSyntaxErr={5} noBuildAttempt={6} statusState={7} statusExit={8} runExit={9} pass={10}" -f `
    $initialAttemptFailed, $retryAlsoFailed, $secondHandleCallAvoided, $reachedNewSite, $honestNoInterpreterMsg, $noFakeSyntaxErr, $noBuildAttempt, $statusState, $statusExit, $runExit, $pass)
Write-Host "=== end self.entrysmoke.no_interpreter_guard evidence ==="

Write-NdjsonRow ([ordered]@{
    id      = 'self.entrysmoke.no_interpreter_guard'
    req     = 'CLAUDE.md-Item-45'
    pass    = [bool]$pass
    desc    = 'a genuine first-attempt conda-create failure (all fallback tiers exhausted via HP_FORCE_CONDA_ONLY) never reaches the PyInstaller build/warnfix/repair block, never redundantly retries the exhausted fallback chain a second time (Item 46 Bucket A slice 1), and reports the honest no-interpreter cause'
    details = [ordered]@{
        initialAttemptFailed     = [bool]$initialAttemptFailed
        retryAlsoFailed          = [bool]$retryAlsoFailed
        secondHandleCallAvoided  = [bool]$secondHandleCallAvoided
        reachedNewSite           = [bool]$reachedNewSite
        honestNoInterpreterMsg   = [bool]$honestNoInterpreterMsg
        noFakeSyntaxErr          = [bool]$noFakeSyntaxErr
        noBuildAttempt           = [bool]$noBuildAttempt
        statusState              = $statusState
        statusExit              = $statusExit
        runExit                 = $runExit
        log                     = $bootstrapLog
    }
})

if (-not $pass) { exit 1 }
exit 0
