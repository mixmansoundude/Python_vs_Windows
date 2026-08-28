# ASCII only
# selfapps_die_emit_fallthrough.ps1 - Regression coverage for CLAUDE.md Active Backlog Item 46
# Bucket A Batches 2, 3, and 4/5 (docs/plan-die-fatal-remediation.md's "Batch Roadmap" -- the full
# 20-site trace and batch grouping). :die uses "exit /b" (a subroutine return, not a process
# halt -- see docs/agent-lessons-learned.md's ":die" entry), so a caller with no goto/halt after
# "call :die" simply continues. This file covers four of the sites the full trace found genuinely
# needed a goto -- each reached via a new, narrow test hook rather than a real disk failure:
#
# New hook: HP_TEST_FORCE_EMIT_FAIL=<VARNAME> (run_setup.bat, :emit_from_base64) deterministically
# fails ONE specific embedded-helper write (matched against the subroutine's own %VAR% argument,
# e.g. HP_CONDARC or HP_FIND_ENTRY) without touching any other payload emitted in the same run --
# simulates the disk-write/AV-lock class of failure every call site of this shared subroutine can
# hit, without needing a genuinely broken filesystem.
#
# Four scenarios (DIE_EMIT_SCENARIO env var):
#
# - "missing_python" (Batch 2, :conda_create_done, the NON-cascade path -- distinct from
#   selfapps_cascade_conda_create_fail.ps1's own "missing_python" scenario, which is specifically
#   a REQ-009 cascade RE-ENTRY where HP_CASCADE_SAVED_PY is defined and routes through
#   :cascade_conda_create_failed instead, never reaching this site at all): HP_FORCE_CONDA_ONLY=1,
#   no cascade env vars, drives a REAL, successful conda create, then HP_TEST_FORCE_CONDA_MISSING_
#   PYTHON=1 deletes the python.exe that create just produced (same established technique as the
#   cascade test's own sibling scenario). Before this fix, the fall-through continued through
#   :conda_create_done's REST of its body -- writing .condarc and logging the misleading
#   "[BOOT] ... Selected Python provider: Conda (Portable)." success line -- even though HP_PY was
#   already known broken. The fix (goto :after_env_mode_selection right after the first call :die)
#   skips both. Unlike the other three scenarios below, this one does NOT set HP_SKIP_ENTRY_SMOKE/
#   HP_SKIP_EXE_SMOKERUN -- the whole point is to let :run_entry_smoke actually run so Item 45's
#   own "if not exist %HP_PY%" guard (CLAUDE.md Active Backlog Item 45, already proven by
#   selfapps_entrysmoke_no_interpreter.ps1 for a DIFFERENT trigger) gets a chance to catch the
#   broken interpreter and confirms no PyInstaller build is attempted against it.
#
# - "condarc" (Batch 4, the same :conda_create_done subroutine's own .condarc-staging step,
#   right after the "missing_python" site above): HP_FORCE_CONDA_ONLY=1 drives a REAL,
#   successful conda create (python.exe genuinely produced) so :conda_create_done reaches its own
#   normal .condarc-staging step. HP_TEST_FORCE_EMIT_FAIL=HP_CONDARC fails that staging; before
#   this fix, the fall-through then attempted `copy /y "~condarc" ...` (doomed, since the source
#   was never staged), triggering a SECOND, redundant call :die ("Could not write ...\.condarc")
#   AND still logging the misleading "[BOOT] ... Selected Python provider: Conda (Portable)."
#   success line right after. The fix (goto :after_env_mode_selection right after the first
#   call :die) skips both. Asserts the cascade message and the misleading success line are both
#   absent, HP_PY was genuinely valid throughout (proving this is NOT the same failure class as
#   Item 46's earlier "python.exe missing" fix), and ~bootstrap.status.json still reads
#   state=error (the correct, honest report -- :die's own centralized HP_BOOTSTRAP_STATE=error set
#   is not undone by the graceful continuation downstream).
#
# - "ci_skip_entry" (Batch 5, :ci_skip_entry): HP_CI_SKIP_ENV=1 takes the cheap, no-conda/no-uv system-
#   Python path. HP_TEST_FORCE_EMIT_FAIL=HP_FIND_ENTRY fails :ci_skip_entry's own ~find_entry.py
#   staging; before this fix, the fall-through continued into :update_find_entry_abs /
#   :verify_find_entry_helper, which -- since the helper file was never staged -- ALSO failed and
#   triggered a second, redundant call :die ("find_entry helper syntax error"). The fix (goto
#   :after_env_bootstrap) skips that. Near-zero real-world exposure (HP_CI_SKIP_ENV is test-
#   infrastructure-only, never set by a real user or the default bootstrap path) -- covered here
#   for completeness, not urgency.
#   Known, pre-existing, NOT fixed by this change: :after_env_skip (the label
#   :after_env_bootstrap routes to under HP_CI_SKIP_ENV) calls
#   `call :write_status ok 0 %PYCOUNT%` unconditionally -- it does not read HP_BOOTSTRAP_STATE, so
#   this scenario's own status file reads state=ok even though a real call :die fired earlier in
#   the same run. This is NOT a regression from this fix (the OLD, unfixed fall-through already
#   reached this same unconditional-ok write further downstream, just after more wasted work) --
#   flagged here so a future reader does not mistake it for something this change broke. Asserted
#   as the known, unchanged behavior rather than silently ignored.
#
# - "determine_entry" (Batch 3, :after_env_mode_selection): HP_FORCE_CONDA_ONLY=1 (same real-create cost as
#   "condarc"). :determine_entry runs TWICE in a normal bootstrap -- once early inside
#   :after_env_mode_selection, once again inside :after_env_bootstrap --
#   both via the identical ~find_entry.py staging call, so HP_TEST_FORCE_EMIT_FAIL=HP_FIND_ENTRY
#   fails BOTH invocations identically. Before this fix, the first failure's fall-through ran the
#   ENTIRE intervening dependency-install/pipreqs/warnfix/pyvisa block (real work, not just a
#   redundant message) before reaching the second :determine_entry call and reproducing the
#   identical failure. The fix (goto :after_env_bootstrap right after the first call :die) skips
#   that block outright; the second call still runs and still dies (same message text at both
#   sites, so this asserts an exact COUNT of 2 rather than distinguishing which site fired), then
#   falls through to the ALREADY-benign "if HP_ENTRY=="" skip packaging" branch confirmed safe by
#   the full trace (docs/plan-die-fatal-remediation.md Finding 3) -- run still completes,
#   state=ok. The key assertion is the ABSENCE of a dependency-install-phase marker that would
#   only appear if the skipped block had actually run.
#
# "condarc"/"ci_skip_entry"/"determine_entry" (NOT "missing_python", see above) set
# HP_SKIP_ENTRY_SMOKE=1 / HP_SKIP_EXE_SMOKERUN=1 (REQ-012) -- those three are about the setup-flow
# fall-through behavior itself, not a full PyInstaller build/run cycle, which entry detection and
# dependency resolution do not depend on either way.
#
# Lane: conda-full only for "missing_python"/"condarc"/"determine_entry" (real conda create
# needed, gated on steps.conda_avail.outputs.available == 'true' matching the other 28+
# conda-full-only self-tests); any lane for "ci_skip_entry" (no conda/uv dependency at all).
# Gating from first landing -- deterministic, self-contained (own HP_FORCE_CONDA_ONLY=1 /
# HP_CI_SKIP_ENV=1 as appropriate), same reasoning as selfapps_entrysmoke_no_interpreter.ps1's own
# precedent.
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

$scenario = $env:DIE_EMIT_SCENARIO
if (-not $scenario) { $scenario = 'missing_python' }

# derived requirement: matches selfapps_pyinstaller_fail.ps1's own established multi-scenario
# precedent (docs/agent-ndjson.md: "Three scenarios... all emitting the same row id") -- ONE
# shared, LITERAL id at every Write-NdjsonRow call site, with details.scenario as the
# discriminator. Avoids the pitfall docs/agent-lessons-learned.md documents: a per-scenario id
# computed into a shared variable (e.g. "id = $rowId") never matches
# tools/check_ndjson_registry.py's static "id = '...'" regex, so the registry checker would
# misreport this row as never emitted.

# derived requirement: $IsWindows is undefined (reads as $null) under Windows PowerShell 5.1 --
# only introduced in PowerShell 6+. [System.Environment]::OSVersion.Platform works on both.
$platform = [System.Environment]::OSVersion.Platform.ToString()
if ($platform -ne 'Win32NT') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.die_emit_fallthrough'
        req     = 'CLAUDE.md-Item-46-BucketA'
        pass    = $true
        desc    = "die-emit-fallthrough $scenario (skipped on non-Windows)"
        details = [ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.die_emit_fallthrough'
        req     = 'CLAUDE.md-Item-46-BucketA'
        pass    = $false
        desc    = "die-emit-fallthrough ${scenario}: run_setup.bat not found"
        details = [ordered]@{ scenario = $scenario; error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here "~selftest_die_emit_$scenario"
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force
Set-Content -Path (Join-Path $workDir 'app.py') -Value 'print("should-not-matter")' -Encoding ASCII

$bootstrapLog = "~die_emit_${scenario}_bootstrap.log"

$saved = @{}
function Save-EnvVar([string]$name) {
    $saved[$name] = if (Test-Path "Env:$name") { (Get-Item "Env:$name").Value } else { $null }
}
function Restore-EnvVar([string]$name) {
    if ($null -eq $saved[$name]) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
    else { Set-Item "Env:$name" $saved[$name] }
}

$envVars = @('HP_FORCE_CONDA_ONLY', 'HP_CI_SKIP_ENV', 'HP_TEST_FORCE_EMIT_FAIL', 'HP_TEST_FORCE_CONDA_MISSING_PYTHON', 'HP_SKIP_PIPREQS', 'HP_SKIP_ENTRY_SMOKE', 'HP_SKIP_EXE_SMOKERUN')
foreach ($v in $envVars) { Save-EnvVar $v }

switch ($scenario) {
    'missing_python' {
        $env:HP_FORCE_CONDA_ONLY = '1'
        $env:HP_TEST_FORCE_CONDA_MISSING_PYTHON = '1'
        # Deliberately NOT setting HP_SKIP_ENTRY_SMOKE/HP_SKIP_EXE_SMOKERUN here -- see this
        # file's own header comment on why this one scenario needs the real entry-smoke path.
    }
    'condarc' {
        $env:HP_FORCE_CONDA_ONLY = '1'
        $env:HP_TEST_FORCE_EMIT_FAIL = 'HP_CONDARC'
        $env:HP_SKIP_ENTRY_SMOKE = '1'
        $env:HP_SKIP_EXE_SMOKERUN = '1'
    }
    'ci_skip_entry' {
        $env:HP_CI_SKIP_ENV = '1'
        $env:HP_TEST_FORCE_EMIT_FAIL = 'HP_FIND_ENTRY'
        $env:HP_SKIP_ENTRY_SMOKE = '1'
        $env:HP_SKIP_EXE_SMOKERUN = '1'
    }
    'determine_entry' {
        $env:HP_FORCE_CONDA_ONLY = '1'
        $env:HP_TEST_FORCE_EMIT_FAIL = 'HP_FIND_ENTRY'
        $env:HP_SKIP_ENTRY_SMOKE = '1'
        $env:HP_SKIP_EXE_SMOKERUN = '1'
    }
    default {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.die_emit_fallthrough'
            req     = 'CLAUDE.md-Item-46-BucketA'
            pass    = $false
            desc    = "die-emit-fallthrough: unknown DIE_EMIT_SCENARIO '$scenario'"
            details = [ordered]@{ scenario = $scenario; error = "unknown scenario: $scenario" }
        })
        exit 1
    }
}
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
    foreach ($v in $envVars) { Restore-EnvVar $v }
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logText   = if (Test-Path -LiteralPath $logPath)  { Get-Content -LiteralPath $logPath  -Raw -Encoding ASCII } else { '' }
$setupText = if (Test-Path -LiteralPath $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = $logText + "`n" + $setupText

$statusPath = Join-Path $workDir '~bootstrap.status.json'
$statusState = $null
if (Test-Path -LiteralPath $statusPath) {
    try { $statusState = (Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { }
}

$pass = $false
$details = [ordered]@{}

switch ($scenario) {
    'missing_python' {
        # :handle_conda_failure logs the message once via :log before attempting any fallback,
        # then :die echoes the SAME text a second time -- exactly 2 is expected (matches the
        # counting technique selfapps_cascade_conda_create_fail.ps1's own sibling scenario uses);
        # this alone does not distinguish pre- from post-fix (the fix runs AFTER :die already
        # echoed), so the real proof is the misleading success line's absence below.
        # derived requirement: count against $setupText alone, not $combined -- every :log line
        # is written to BOTH the console (captured in $logText) AND ~setup.log, so counting
        # against $combined silently doubles every occurrence (caught via a real CI failure:
        # dieMsgCount read 4, not 2, on the very first run).
        $dieMsgCount = ([regex]::Matches($setupText, [regex]::Escape('[ERROR] python.exe missing from conda environment.'))).Count
        $dieFiredTwice = ($dieMsgCount -eq 2)
        $misleadingMsgFound = $combined -match [regex]::Escape('[BOOT] REQ-009: Selected Python provider: Conda (Portable).')
        # Item 45's own guard (already proven by selfapps_entrysmoke_no_interpreter.ps1 for a
        # different trigger) must still catch the broken-but-defined HP_PY here and refuse the
        # doomed build.
        $noBuildAttempt = -not ($combined -match [regex]::Escape('Building standalone executable'))
        $honestNoInterpreterMsg = $combined -match [regex]::Escape('No Python interpreter is available')
        $pass = $dieFiredTwice -and (-not $misleadingMsgFound) -and $noBuildAttempt -and $honestNoInterpreterMsg -and ($statusState -eq 'error')
        $details = [ordered]@{
            scenario               = $scenario
            dieMsgCount             = $dieMsgCount
            dieFiredTwice           = [bool]$dieFiredTwice
            misleadingMsgFound      = [bool]$misleadingMsgFound
            noBuildAttempt          = [bool]$noBuildAttempt
            honestNoInterpreterMsg  = [bool]$honestNoInterpreterMsg
            statusState             = $statusState
            bootstrapExit           = $runExit
            log                     = $bootstrapLog
        }
    }
    'condarc' {
        $hookFired      = $combined -match [regex]::Escape('HP_TEST_FORCE_EMIT_FAIL=HP_CONDARC: simulating embedded helper write failure')
        $dieMsgFound    = $combined -match [regex]::Escape('[ERROR] Could not stage ~condarc')
        $cascadeMsgFound = $combined -match 'Could not write [^\r\n]*\.condarc'
        $misleadingMsgFound = $combined -match [regex]::Escape('[BOOT] REQ-009: Selected Python provider: Conda (Portable).')
        $pass = $hookFired -and $dieMsgFound -and (-not $cascadeMsgFound) -and (-not $misleadingMsgFound) -and ($statusState -eq 'error')
        $details = [ordered]@{
            scenario            = $scenario
            hookFired           = [bool]$hookFired
            dieMsgFound         = [bool]$dieMsgFound
            cascadeMsgFound     = [bool]$cascadeMsgFound
            misleadingMsgFound  = [bool]$misleadingMsgFound
            statusState         = $statusState
            bootstrapExit       = $runExit
            log                 = $bootstrapLog
        }
    }
    'ci_skip_entry' {
        $hookFired      = $combined -match [regex]::Escape('HP_TEST_FORCE_EMIT_FAIL=HP_FIND_ENTRY: simulating embedded helper write failure')
        $dieMsgFound    = $combined -match [regex]::Escape('[ERROR] CI skip: entry helper staging failed')
        $cascadeMsgFound = $combined -match [regex]::Escape('[ERROR] find_entry helper syntax error')
        # Known pre-existing quirk (see this file's own header comment): :after_env_skip writes
        # state=ok unconditionally regardless of an earlier call :die in the same run -- asserted
        # as the known, unchanged behavior, not a regression from this fix.
        $pass = $hookFired -and $dieMsgFound -and (-not $cascadeMsgFound) -and ($statusState -eq 'ok')
        $details = [ordered]@{
            scenario        = $scenario
            hookFired       = [bool]$hookFired
            dieMsgFound     = [bool]$dieMsgFound
            cascadeMsgFound = [bool]$cascadeMsgFound
            statusState     = $statusState
            bootstrapExit   = $runExit
            log             = $bootstrapLog
        }
    }
    'determine_entry' {
        $dieMsgCount = ([regex]::Matches($setupText, [regex]::Escape('[ERROR] Could not determine entry point'))).Count
        # Both call sites share identical message text (by design, same underlying failure) --
        # exactly 2 proves the mechanism reached BOTH :determine_entry invocations, not more
        # (a goto loop) and not fewer (the second call silently skipped too). Counted against
        # $setupText alone, not $combined -- see the identical note in the missing_python block.
        $bothSitesReached = ($dieMsgCount -eq 2)
        # The intervening dependency-install/pipreqs/warnfix block must NOT have run -- this
        # marker only appears once dependency installation actually begins.
        $depPhaseSkipped = -not ($combined -match [regex]::Escape('[TRACE] dep install phase: start'))
        $pass = $bothSitesReached -and $depPhaseSkipped -and ($statusState -eq 'ok')
        $details = [ordered]@{
            scenario          = $scenario
            dieMsgCount       = $dieMsgCount
            bothSitesReached  = [bool]$bothSitesReached
            depPhaseSkipped   = [bool]$depPhaseSkipped
            statusState       = $statusState
            bootstrapExit     = $runExit
            log               = $bootstrapLog
        }
    }
}

Write-Host "=== self.die_emit_fallthrough ($scenario) evidence ==="
Write-Host ($details | ConvertTo-Json -Compress)
Write-Host "pass=$pass"
Write-Host "=== end self.die_emit_fallthrough ($scenario) evidence ==="

Write-NdjsonRow ([ordered]@{
    id      = 'self.die_emit_fallthrough'
    req     = 'CLAUDE.md-Item-46-BucketA'
    pass    = [bool]$pass
    desc    = "die-emit-fallthrough ${scenario}: redundant call :die cascade avoided via goto"
    details = $details
})

if (-not $pass) { exit 1 }
exit 0
