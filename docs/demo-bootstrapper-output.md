# Demo: what the user actually sees

**Status: living demo report, NOT an authoritative or direction-providing document.** This
walks through specific tested scenarios and shows, with real quotes pulled from actual CI runs
(never invented or paraphrased), exactly what text lands on the user's screen. Purpose: make it
easy for a human to review the actual console output, spot anything confusing or alarming, and
catch code paths that report something unexpected. Update this as code changes rather than
treating it as fixed -- if a quoted message changes, re-pull it from a fresh CI run rather than
hand-editing the quote.

**Sourcing convention used throughout:** every quoted block below is copied verbatim from a real
GitHub Actions job log (via the GitHub API), with the exact run ID, job ID, lane, and test file
cited immediately above it. Where a scenario's CI run had not yet completed as of this writing,
the section says so explicitly and shows the literal source-code string instead of a real log
excerpt -- clearly marked as **PENDING**, to be replaced once the run finishes.

**First-pass scope:** this covers the AV-Safe Build Path work from 2026-07-20/21 (Tier A Nuitka
fallback, its interaction with hidden-import auto-recovery, and the requirement-9 optimized-build
offer) -- the most recent, most user-facing-behavior-changing work at the time this doc started.
Later passes should extend it to other areas (REQ-009 provider cascade, warnfix, the REQ-018
post-execution checkpoint on its own, etc.).

**Important distinction this doc surfaced early, worth keeping in mind throughout:** the
bootstrapper writes to two different places that are easy to conflate:
- The **live console** (what a real user watching the window sees) -- everything `:log` echoes,
  plus a handful of raw tool-output lines that aren't redirected.
- **`~setup.log`** (the internal file record) -- receives everything the console does, PLUS
  extra content that's deliberately redirected away from the console (e.g. the full raw
  PyInstaller warn-file dump -- see Finding 2 below). A CI test's "bootstrap log" capture
  (`cmd /c "call run_setup.bat > log 2>&1"`) matches the CONSOLE view, not `~setup.log`. Quotes
  below are from the console-equivalent capture unless stated otherwise.

---

## Scenario 1: PyInstaller build fails, Tier A (Nuitka) fallback succeeds

**What's tested:** `self.exe.build.tiera` (`tests/selfapps_nuitka_tiera.ps1`, uv lane,
non-gating). `HP_TEST_FORCE_PYINSTALLER_FAIL=1` forces the primary build to fail deterministically;
the Nuitka fallback (`:try_nuitka_tier_a`) then runs for real -- a genuine compile, not simulated.

**Source:** run `29788624195`, job `88506013149` ("uv" lane), commit `d12a80e`. NDJSON row:
`{"lane":"uv","pass":true,"desc":"AV-Safe Build Path Tier A: real Nuitka fallback build succeeds and is used as the standalone EXE","id":"self.exe.build.tiera",...}`

**What appears on screen**, from the moment PyInstaller's build is attempted through to the
final summary:

```
Tue 07/21/2026  0:16:59.09 [INFO] Building standalone executable -- this may take a minute or two...
The system cannot find the drive specified.
The system cannot find the drive specified.
Tue 07/21/2026  0:16:59.77 [TEST] HP_TEST_FORCE_PYINSTALLER_FAIL: simulating PyInstaller build failure.
Tue 07/21/2026  0:16:59.79 [INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
Tue 07/21/2026  0:18:45.56 [INFO] Fallback build succeeded: dist\_selftest_nuitka_tiera.exe was produced using the fallback build system.
Tue 07/21/2026  0:18:45.56 [DEBUG] warnfix: warn file not found
Tue 07/21/2026  0:18:45.88 [INFO] PyInstaller build artifacts cleaned up.
Tue 07/21/2026  0:18:45.88 [INFO] EXE smokerun: testing dist\_selftest_nuitka_tiera.exe
Tue 07/21/2026  0:18:45.89 [INFO] Running entry script smoke test via packaged EXE.
Tue 07/21/2026  0:18:45.90 [WARN] Verifying the built standalone EXE (PyInstaller) now: it is force-stopped after about 30 seconds even if running perfectly, so do not start real work in it yet or any unsaved work will be lost.
Tue 07/21/2026  0:18:47.26 [INFO] EXE smokerun: exited 0 (ok)
Tue 07/21/2026  0:18:47.27 [INFO] Entry smoke exit=0
Tue 07/21/2026  0:18:47.27 [STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
Tue 07/21/2026  0:18:47.29 [INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

============================================================
 SETUP COMPLETE
============================================================
 Your standalone application is ready:
   dist\_selftest_nuitka_tiera.exe

 RUNNING YOUR APP
   Double-click dist\_selftest_nuitka_tiera.exe to run it.

   STARTUP MAY BE SLOW: a one-file .exe unpacks itself each time it
   starts, so allow 10-15 seconds (longer for big libraries like
   numpy/scipy/matplotlib, or when extra packages were bundled to fix
   missing imports) before assuming it has hung.

   If the window flashes and closes instantly: that's normal if
   your program finished quickly or hit an error before printing
   anything. To see what happened, open Command Prompt, cd to
   this folder, and run:
     dist\_selftest_nuitka_tiera.exe
   This keeps the window open so you can read any messages.

   A progress indicator that updates in place may appear all at
   once instead of live when run as the .exe -- that is a stdout
   buffering difference between the .exe and the script, not an error.

 KEEP these files with your project:
   requirements.txt  -- packages your app depends on
   runtime.txt       -- Python version pin

 SAFE TO DELETE to reclaim disk space:
   .*_env\ folders   -- environment directories
   ~* files          -- tilde-prefix work files (e.g. ~setup.log)
   build\            -- PyInstaller build cache
============================================================
```

**Observation A (Finding 1 below has more detail):** the "The system cannot find the drive
specified." pair right after "Building standalone executable..." is real, on-screen text a user
would see -- confirmed harmless (see Findings), but currently unexplained.

**Observation B:** the "Verifying the built standalone EXE (PyInstaller) now" line and the
postflight briefing's "RUNNING YOUR APP" section both say "PyInstaller" / talk about `.exe`
startup unpacking generically -- nothing on screen tells the user this particular EXE was built
by the Nuitka fallback rather than PyInstaller. Not wrong (both are onefile EXEs with similar
unpack behavior), but worth a deliberate decision on whether that distinction should ever surface
to the user, or is intentionally kept invisible ("just works" either way).

---

## Scenario 2: PyInstaller build fails, Tier A fallback ALSO fails (tier exhaustion)

**What's tested:** `self.exe.build.xfail` (`tests/selfapps_pyinstaller_fail.ps1`, real/conda-full
lanes, gating). Two sub-scenarios share one NDJSON row id: `execfail` (the PyInstaller build
command itself fails) and `output_vanish` (PyInstaller succeeds, then the output EXE vanishes
immediately -- simulating AV-style post-creation removal). Both additionally force
`HP_TEST_FORCE_NUITKA_FAIL=1` so the fallback also fails, proving genuine tier exhaustion rather
than being saved by a real Nuitka success.

**Source:** run `29788624195`, job `88506013028` ("real" lane), commit `d12a80e`. NDJSON rows:
`{"lane":"real","id":"self.exe.build.xfail","details":{...,"scenario":"execfail","xfailPass":true,"statusState":"error",...}}`
and the `output_vanish` sibling, both `"pass":true`.

### 2a. `execfail` -- the PyInstaller build command itself fails

```
Tue 07/21/2026  0:09:58.94 [INFO] Building standalone executable -- this may take a minute or two...
Tue 07/21/2026  0:09:59.76 [TEST] HP_TEST_FORCE_PYINSTALLER_FAIL: simulating PyInstaller build failure.
Tue 07/21/2026  0:09:59.78 [INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
Tue 07/21/2026  0:09:59.80 [TEST] HP_TEST_FORCE_NUITKA_FAIL: simulating fallback build failure.
Tue 07/21/2026  0:09:59.81 [ERROR] PyInstaller execution failed.
Tue 07/21/2026  0:09:59.83 [DEBUG] warnfix: warn file not found
Tue 07/21/2026  0:10:00.16 [INFO] PyInstaller build artifacts cleaned up.
Tue 07/21/2026  0:10:00.17 [WARN] EXE smokerun: dist\_selftest_pyi_fail_execfail.exe not found; skipping
Tue 07/21/2026  0:10:00.18 [INFO] Running entry script smoke test via uv interpreter.
Tue 07/21/2026  0:10:00.23 [INFO] Entry smoke exit=0
Tue 07/21/2026  0:10:00.24 [STATUS] Run Status: SUCCESS (Exit Code: 0)

Tue 07/21/2026  0:10:00.26 [INFO] REQ-018: post-execution checkpoint (interpreter): declined (run footprint stays at one execution).
```

**This is the single most important behavior to flag for review, even though it is intentional
and already documented** (CLAUDE.md's "User-code exit-code semantics are already correctly
isolated from bootstrapper status" Known Finding): when BOTH the PyInstaller build AND the Nuitka
fallback fail outright, the bootstrapper does not stop. It falls through to running the entry
script directly via the interpreter, and if that trivial script runs cleanly, the FINAL line the
user sees is `[STATUS] Run Status: SUCCESS (Exit Code: 0)` -- with no EXE ever having been
produced. The internal `~bootstrap.status.json` correctly records `state=error` (confirmed by
the NDJSON row's `"statusState":"error"`), so this is not silently swallowed at the machine-
readable level, but a real user watching only the console would see "SUCCESS" as the last thing
printed for a run where EXE packaging completely failed. Worth a team discussion on whether the
console-visible wording should distinguish "your code ran fine via the interpreter, but we could
not produce a double-clickable EXE" from a true clean-EXE success -- right now both print
identically.

### 2b. `output_vanish` -- PyInstaller succeeds, then the EXE disappears immediately

```
Tue 07/21/2026  0:10:08.90 [INFO] Building standalone executable -- this may take a minute or two...
The system cannot find the drive specified.
The system cannot find the drive specified.
Tue 07/21/2026  0:10:18.38 [TEST] HP_TEST_FORCE_OUTPUT_VANISH: deleting freshly-built EXE to simulate post-creation removal.
Tue 07/21/2026  0:10:18.40 [INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
Tue 07/21/2026  0:10:18.42 [TEST] HP_TEST_FORCE_NUITKA_FAIL: simulating fallback build failure.
Tue 07/21/2026  0:10:18.43 [ERROR] PyInstaller did not produce dist\_selftest_pyi_fail_output_vanish.exe
Tue 07/21/2026  0:10:18.45 [DEBUG] warnfix: warn file found
Tue 07/21/2026  0:10:18.46 [INFO] warnfix: Platform-specific modules in the list above are expected on Windows: posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, _frozen_importlib_external. These will be filtered out automatically.
Tue 07/21/2026  0:10:18.78 [INFO] PyInstaller build artifacts cleaned up.
Tue 07/21/2026  0:10:18.79 [WARN] EXE smokerun: dist\_selftest_pyi_fail_output_vanish.exe not found; skipping
Tue 07/21/2026  0:10:18.80 [INFO] Running entry script smoke test via uv interpreter.
Tue 07/21/2026  0:10:18.85 [INFO] Entry smoke exit=0
Tue 07/21/2026  0:10:18.86 [STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
Tue 07/21/2026  0:10:18.88 [INFO] REQ-018: post-execution checkpoint (interpreter): declined (run footprint stays at one execution).
```

**Notable line:** `warnfix: Platform-specific modules in the list above are expected on Windows:
posix, fcntl, grp, ...` -- this says "in the list above" but, per the console/`~setup.log` split
noted at the top of this doc, the actual list it refers to (the raw PyInstaller warn-file dump,
"missing module named 'collections.abc' - imported by...", etc.) is NOT printed to the console at
all -- it only exists in `~setup.log`. A user watching just the console sees this "above" claim
with no list actually above it on their screen. See Finding 2.

---

## Scenario 3: Tier A + hidden-import auto-recovery skip guard -- CONFIRMED (real run, log not dumped)

**What's tested:** `self.exe.tiera.hidden_skip` (`tests/selfapps_nuitka_tiera_hidden_skip.ps1`, uv
lane, non-gating). Forces Tier A to trigger and succeed for real, then has the stub app fabricate
a `ModuleNotFoundError: No module named 'nuitka'` on stderr and exit 1 -- deliberately
constructing the exact signature that used to (before this fix) trigger an incorrect PyInstaller
rebuild attempt against a Nuitka-built EXE.

**Source:** commit `933bd81` (folded into `c84b20e`); confirmed in real CI run `29829724937`, uv
lane, job `88632292427`. Real, verbatim NDJSON row from that job's log:
```
{"id":"self.exe.tiera.hidden_skip","req":"REQ-AV","details":{"log":"~nuitka_tiera_hidden_skip_bootstrap.log","exeExists":true,"successLogged":true,"smokerunNonzeroLogged":true,"skipGuardLogged":true,"attemptLogged":true,"bootstrapExit":0,"statusState":"ok","appStdoutFound":true,"noRepairRebuild":true},"lane":"uv","pass":true,"desc":"AV-Safe Build Path Tier A: hidden-import auto-recovery correctly skips (never rebuilds via PyInstaller) against a Nuitka-built EXE"}
```
**Caveat on this section's sourcing:** because this scenario PASSED, the test script (matching
this suite's established pattern) never dumps the full bootstrap log to the CI console -- only a
failing scenario's log gets echoed for debugging (see Scenario 4a below, which failed on this same
run and DOES have a full console dump). So the exact literal console text below is reconstructed
from `run_setup.bat`'s source as of this commit, not copied from a console dump -- but
`skipGuardLogged:true` and `noRepairRebuild:true` in the real row above are the test's own
regex-verified confirmation that these exact strings were present (and the repair line was absent)
in the real `~nuitka_tiera_hidden_skip_bootstrap.log` file on that run.

```
Tue 07/21/2026 ... [INFO] Building standalone executable -- this may take a minute or two...
Tue 07/21/2026 ... [TEST] HP_TEST_FORCE_PYINSTALLER_FAIL: simulating PyInstaller build failure.
Tue 07/21/2026 ... [INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
Tue 07/21/2026 ... [INFO] Fallback build succeeded: dist\<env>.exe was produced using the fallback build system.
Tue 07/21/2026 ... [INFO] EXE smokerun: testing dist\<env>.exe
Tue 07/21/2026 ... [WARN] EXE smokerun: exited 1 (non-zero)
Tue 07/21/2026 ... [INFO][HIDDEN_IMPORT] Skipping --hidden-import auto-recovery: dist\<env>.exe was built via the fallback build system (Nuitka), which uses a different missing-import mechanism than PyInstaller's --hidden-import flag.
```

**What this proves, now confirmed:** the OLD behavior (before this session's fix) would have
printed `[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=nuitka; rebuilding EXE (iter 1/3)` at this
point and attempted a PyInstaller rebuild against a Nuitka-built EXE. The real CI row's
`noRepairRebuild:true` confirms that line never appeared and the skip guard fired instead.

---

## Scenario 4: Requirement 9 -- elective "want an optimized build too?" offer -- 4a CONFIRMED, 4b/4c still pending

**What's tested:** `self.optbuild.offer` (`tests/selfapps_optimized_build.ps1`, uv lane,
non-gating), three scenarios sharing one row id.

**Source:** commit `c84b20e`; CI run `29829724937`, uv lane, job `88632292427`. **Important
finding from this run, not just a status update:** only the `accept` scenario's CI step actually
executed. It failed (see below -- a genuine test-script bug, not a `run_setup.bat` bug), and
because no step in this job uses `if: always()`, every subsequent step -- including the
`forcefail` and `decline` scenario steps -- was silently skipped entirely. This is the same,
already-documented gap tracked as `CLAUDE.md` Active Backlog item 7 ("CI job steps in
`batch-check.yml` don't use `if: always()`..."), now observed for a second real time. So 4b/4c
below remain genuinely unconfirmed -- not because the run hasn't finished, but because those
steps never ran at all this time. They'll get filled in on a future clean run.

### 4a. `accept` -- user says yes, a real optimized build succeeds and is swapped in -- CONFIRMED

This is a real, verbatim console dump from job `88632292427`
(`~selftest_optbuild_accept\~optbuild_accept_bootstrap.log`), reproduced exactly (only the
mid-run `[INFO]`/route-finding lines between "Entry selected" and "Building standalone
executable" are omitted with `...` for brevity -- nothing altered):

```
Tue 07/21/2026 12:46:19.52 [INFO] Building standalone executable -- this may take a minute or two...
The system cannot find the drive specified.
The system cannot find the drive specified.
Tue 07/21/2026 12:46:27.09 [INFO] PyInstaller produced dist\_selftest_optbuild_accept.exe
Tue 07/21/2026 12:46:27.10 [INFO] warnfix: Platform-specific modules in the list above are expected on Windows: posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, _frozen_importlib_external. These will be filtered out automatically.
Tue 07/21/2026 12:46:27.37 [INFO] PyInstaller build artifacts cleaned up.
Tue 07/21/2026 12:46:27.37 [INFO] EXE smokerun: testing dist\_selftest_optbuild_accept.exe
Tue 07/21/2026 12:46:27.38 [INFO] Running entry script smoke test via packaged EXE.
Tue 07/21/2026 12:46:27.39 [WARN] Verifying the built standalone EXE (PyInstaller) now: it is force-stopped after about 30 seconds even if running perfectly, so do not start real work in it yet or any unsaved work will be lost.
Tue 07/21/2026 12:46:28.68 [INFO] EXE smokerun: exited 0 (ok)
Tue 07/21/2026 12:46:28.68 [INFO] Entry smoke exit=0
Tue 07/21/2026 12:46:28.69 [STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
Tue 07/21/2026 12:46:28.71 [INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
Tue 07/21/2026 12:46:28.72 [INFO] Optimized build: accepted; building now (this may take a minute or two).
Tue 07/21/2026 12:46:48.88 [INFO] Optimized build succeeded and verified: dist\_selftest_optbuild_accept.exe now uses the fallback build system.
```

**Note on the `Y/N` prompt text and CI's echo-only behavior:** the interactive `  Build the
optimized version now? [Y/N]` line is echoed unconditionally by design (same pattern as
`:run_postexec_checkpoint` -- see `docs/agent-interconnect.md`), but it did not appear literally
in this particular captured log; only the accept/decline resolution lines did. This is consistent
with the rest of this file's captures (CI answers via `HP_TEST_OPTBUILD_ANSWER`, not `set /p`) --
worth a closer look in a future pass to confirm the prompt text itself does reach the console on a
real interactive run, not just its resolution.

**Real bug this run surfaced, not in `run_setup.bat` -- in the test script itself:** the NDJSON
row for this scenario read `"pass":false` with `"appStillRuns":false`, despite every other field
(`successLogged`, `acceptedLogged`, `tmpExeGone`, `exeExists`) being `true` and the log above
plainly showing the optimized build succeeded, verified, and swapped in correctly.
Root cause: `tests/selfapps_optimized_build.ps1` re-executed the swapped-in EXE via PowerShell's
`& "$envName.exe"` (a bare relative filename) from inside the `dist\` directory --
but unlike `cmd.exe`, PowerShell's `&` operator does not implicitly search the current directory
for an executable without a `.\` prefix or a PATH entry, so the call threw and was silently
swallowed by the surrounding `catch { $appStillRuns = $false }`. Fixed (this session, not yet
re-verified in CI) by switching to `cmd /c "` + backtick-escaped-quote + `$envName.exe` + ..." +
`"` (i.e. `cmd /c "\"$envName.exe\""`), matching the established pattern already used in
`tests/selfapps_collect.ps1`. `run_setup.bat`'s own behavior was correct throughout -- this was a
test-authoring bug, not a product bug.

### 4b. `forcefail` -- accepted, but the build fails; original EXE is left untouched [PENDING -- step never ran this CI run, see above]

```
*** Your app is ready. ***
*** Want to build an optimized version too? ... ***
[INFO] Optimized build: accepted; building now (this may take a minute or two).
[TEST] HP_TEST_FORCE_OPTBUILD_FAIL: simulating optimized-build failure.
```

(No further message prints in this path today -- the subroutine cleans up the temp file and
returns silently after the forced-fail log line. Worth checking once real CI confirms whether
that silence reads as "did nothing happen?" to a real user, versus the more explicit "your app is
still ready to use as-is" wording used on the REAL failure branches below it.)

### 4c. `decline` -- default/CI path, prompt shown but nothing built [PENDING -- step never ran this CI run, see above]

```
*** Your app is ready. ***
*** Want to build an optimized version too? ... ***
[INFO] Optimized build: declined.
```

### Reactive-only failure hint (both Tier A and requirement 9's real-build-failure paths) [PENDING -- no real build failure observed yet in either scenario]

```
[WARN] Optimized build did not complete; your app is still ready to use as-is.
[WARN] Hint: if you have Visual Studio 2022 (or newer) with the 'Desktop development with C++' workload installed, this should use it automatically -- no extra setup needed. If not, installing the free Visual Studio Build Tools with that workload can help.
```

---

## Refinement pass log

Small, targeted checks run against the shipped code while waiting on CI, logged here as they
happen rather than only reporting the end state. These are verification passes (did the new code
break something already relied on), not new scenarios with their own screen output.

**2026-07-21, requirement 9 vs. the existing checkpoint test -- checked, no interference.**
`:offer_optimized_build` fires immediately after `:run_postexec_checkpoint` on every successful
build, so `tests/selfapps_postexec_checkpoint.ps1` (`self.checkpoint.accept`/`.decline`) now runs
with a second prompt-and-decline sequence tacked on right after its own. Traced both scenarios by
hand against the actual regexes that test uses:
- `self.checkpoint.accept` sets `HP_TEST_CHECKPOINT_ANSWER=Y` but not `HP_TEST_OPTBUILD_ANSWER`,
  so `:offer_optimized_build` hits its own `HP_CI_LANE` auto-decline branch (the test sets
  `HP_CI_LANE=test`) and never runs a build -- no extra `Entry smoke exit=0` line, so the
  `$accRunCount -ge 2` assertion is unaffected. The test's `$accAccepted` regex
  (`'post-execution checkpoint \((exe|interpreter)\): accepted; running a second time...'`) only
  matches `:run_postexec_checkpoint`'s own log line, which `:offer_optimized_build`'s
  `[INFO] Optimized build: accepted; building now...` text does not resemble.
- `self.checkpoint.decline`'s `$decRunCount -eq 1` assertion holds for the same reason (the new
  prompt's decline path runs nothing).
- The static check in `tests/harness.ps1` (`batch.postexec.checkpoint`) counts occurrences of the
  literal string `call :run_postexec_checkpoint` (`$cpCallCount -ge 3`) -- the new
  `call :offer_optimized_build` line does not match that string, so the count is unaffected.

**2026-07-21, NDJSON registry check -- ran locally, clean.** `python tools/check_ndjson_registry.py`
against the working tree (both new test files' rows included): `Doc-registered IDs: 268 ... PASS:
no doc/code registry mismatches found.` Confirms `self.exe.tiera.hidden_skip` and
`self.optbuild.offer` are both correctly documented in `docs/agent-ndjson.md` and correctly
discovered by the scanner's PowerShell-source scan -- no silent registry drift introduced by this
session's additions.

**2026-07-21, first real CI run (`29829724937`) -- hidden-import skip guard fully confirmed;
requirement 9's `accept` scenario failed on a test-script bug, `forcefail`/`decline` never ran.**
See Scenario 3 and Scenario 4 above for the confirmed quotes and full detail. Two things worth
calling out here specifically since they're about the demo-doc process itself, not the feature:
- The `accept` scenario's failure was in `tests/selfapps_optimized_build.ps1`, not in
  `run_setup.bat` -- a PowerShell `&`-operator-vs-bare-relative-filename resolution difference
  from `cmd.exe` (see Scenario 4a for the full explanation). Fixed locally (`cmd /c` instead of
  `&`, matching `selfapps_collect.ps1`'s established pattern); full local sanity sweep re-run
  clean (`compileall`, `pyflakes`, PS AST parse, `pytest` all pass); not yet re-verified in CI as
  of this doc update.
- Because `accept` failed and no step in the uv-lane job uses `if: always()`, the `forcefail` and
  `decline` CI steps never executed at all -- not "pending," genuinely skipped. This is a second,
  independent real-world instance of the exact gap `CLAUDE.md`'s Active Backlog item 7 already
  documents (first observed while landing PR #368). Not fixed here, consistent with that item's
  own stated reasoning (the real fix touches ~50 existing step definitions and deserves its own
  reviewed pass, not a drive-by fix bundled into unrelated feature work) -- but it's now been
  observed twice in real CI, which is worth noting as it strengthens the case for eventually
  doing that hardening pass.

---

## Findings worth a second look

1. **"The system cannot find the drive specified." prints twice, on-screen, right before every
   PyInstaller build starts -- confirmed pre-existing and harmless, not introduced by this
   session's work, but not explained to the user.** Occurs 97 times in the `real` lane job log and
   81 times in the `uv` lane job log for the SAME CI run (`29788624195`) -- far too common to be
   Tier-A-specific; it precedes essentially every "Building standalone executable..." line,
   success or failure alike. An existing test (`self.env.smoke.conda`/`self.prime.bootstrap` in
   `tests/selfapps_envsmoke.ps1`) already explicitly whitelists it:
   `"unexpectedSystemErrorLine":"The system cannot find the drive specified.","unexpectedSystemErrorIgnored":"drive-specified-nonfatal"`.
   Root cause not chased down here (likely some PyInstaller-internal drive/cache probe on the
   GitHub Actions Windows runner's particular drive layout), but since it's already known-benign
   and already silently tolerated by tests, it may be worth either suppressing it at the source
   (redirect that specific subprocess's stderr) or adding one reassuring line so a real user
   doesn't mistake it for an error. Low priority, cosmetic only.

2. **The raw PyInstaller warn-file dump never reaches the live console -- confirmed directly by
   comparing the console-capture group against the `~setup.log` dump group for the SAME test
   run.** `type "build\<env>\warn-<env>.txt" >> "%LOG%"` in `run_setup.bat` redirects the warn
   file's content straight into `~setup.log`, bypassing the console entirely. The very next line,
   `[INFO] warnfix: Platform-specific modules in the list above are expected on Windows: ...`,
   DOES print to the console and says "in the list above" -- but for a user watching only the
   console (not opening `~setup.log`), there is no list above it. This isn't a functional bug
   (the filtering logic itself works correctly, confirmed by Scenario 2b passing), just a
   messaging inconsistency between what's promised on-screen and what's actually visible there.

3. **Total EXE-packaging failure (PyInstaller AND Tier A both exhausted) still ends with
   `[STATUS] Run Status: SUCCESS`** if the entry script itself runs cleanly via the interpreter
   fallback -- see Scenario 2a's callout. Intentional, already-documented design (packaging
   failure is tracked separately from user-code outcome, per CLAUDE.md's Known Finding), but
   worth keeping in view: the ONLY on-screen signal that packaging failed is the earlier
   `[ERROR] PyInstaller execution failed.` line a few seconds before -- there's no summary at the
   very end reminding the user "by the way, no .exe was produced; here's why."

4. **Nothing on screen distinguishes a Nuitka-fallback-built EXE from a normal PyInstaller-built
   one** -- see Scenario 1's Observation B. The postflight briefing's language ("PyInstaller
   build cache" in the SAFE-TO-DELETE section, "Verifying the built standalone EXE (PyInstaller)
   now" during smoke-test) is generic and technically slightly inaccurate when Tier A or
   requirement 9's optimized build produced the file instead. Not necessarily wrong to keep
   invisible (the PRD's own framing is "it just works, don't make the user care which tool built
   it"), but worth a deliberate yes/no rather than an accidental omission.
