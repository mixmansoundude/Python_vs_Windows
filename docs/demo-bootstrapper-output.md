# Demo: what the user actually sees

**Status: living demo report, NOT an authoritative or direction-providing document.** This walks
through specific tested scenarios and shows exactly what text lands on the user's screen. Purpose:
let a human review the actual console output, spot anything confusing or alarming, and catch code
paths that report something unexpected. **This doc reflects the LATEST state of the code only --
it is not a history of how things changed.** When a message's wording changes, replace the quote
in place; don't keep the old one around for context. Ongoing investigation notes, dead ends, and
day-to-day refinement-pass checks belong in `docs/agent-scratchlog.md` (internal working notes),
not here. Unresolved design questions belong in `docs/open-questions.md`, not here.

**Sourcing convention:** every quoted block is either copied verbatim from a real GitHub Actions
job log (cited with run ID, job ID, lane, and test file) or, where noted, taken directly from
`run_setup.bat`'s current source because no CI run has exercised that exact wording yet -- always
labeled explicitly which case applies, never presented as a real capture when it isn't.

**Scope so far:** covers the AV-Safe Build Path work (Tier A Nuitka fallback, its interaction
with hidden-import auto-recovery, and the requirement-9 optimized-build offer) -- the most recent,
most user-facing-behavior-changing area at the time this doc started. Extend to other areas
(REQ-009 provider cascade, warnfix, the REQ-018 post-execution checkpoint on its own, etc.) as
they're reviewed.

**Console vs. `~setup.log`:** the bootstrapper writes to two different places that are easy to
conflate:
- The **live console** (what a real user watching the window sees) -- everything `:log` echoes,
  plus a handful of raw tool-output lines that aren't redirected.
- **`~setup.log`** (the internal file record) -- receives everything the console does, PLUS extra
  content deliberately redirected away from the console (e.g. the full raw PyInstaller warn-file
  dump). A CI test's "bootstrap log" capture (`cmd /c "call run_setup.bat > log 2>&1"`) matches the
  CONSOLE view, not `~setup.log`. Quotes below are from the console-equivalent capture unless
  stated otherwise.

---

## Scenario 1: PyInstaller build fails, Tier A (Nuitka) fallback succeeds

**What's tested:** `self.exe.build.tiera` (`tests/selfapps_nuitka_tiera.ps1`, uv lane,
non-gating). `HP_TEST_FORCE_PYINSTALLER_FAIL=1` forces the primary build to fail deterministically;
the Nuitka fallback (`:try_nuitka_tier_a`) then runs for real -- a genuine compile, not simulated.

**What appears on screen**, from the moment PyInstaller's build is attempted through to the final
summary. Sourced from real CI (run `29788624195`, job `88506013149`), with the "(PyInstaller)"
verification line and the drive-message reassurance line updated to reflect a wording fix made
after that run -- not yet re-confirmed against a fresh CI capture:

```
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] (A stray one-line Windows message about a missing drive may appear next -- that is a known side effect from an unrelated background process, unrelated to your app; safe to ignore.)
The system cannot find the drive specified.
The system cannot find the drive specified.
[TEST] HP_TEST_FORCE_PYINSTALLER_FAIL: simulating PyInstaller build failure.
[INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
[INFO] Fallback build succeeded: dist\<env>.exe was produced using the fallback build system.
[DEBUG] warnfix: warn file not found
[INFO] PyInstaller build artifacts cleaned up.
[INFO] EXE smokerun: testing dist\<env>.exe
[INFO] Running entry script smoke test via packaged EXE.
[WARN] Verifying the built standalone EXE (fallback build system) now: it is force-stopped after about 30 seconds even if running perfectly, so do not start real work in it yet or any unsaved work will be lost.
[INFO] EXE smokerun: exited 0 (ok)
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
[INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

============================================================
 SETUP COMPLETE
============================================================
 Your standalone application is ready:
   dist\<env>.exe

 RUNNING YOUR APP
   Double-click dist\<env>.exe to run it.

   STARTUP MAY BE SLOW: a one-file .exe unpacks itself each time it
   starts, so allow 10-15 seconds (longer for big libraries like
   numpy/scipy/matplotlib, or when extra packages were bundled to fix
   missing imports) before assuming it has hung.

   If the window flashes and closes instantly: that's normal if
   your program finished quickly or hit an error before printing
   anything. To see what happened, open Command Prompt, cd to
   this folder, and run:
     dist\<env>.exe
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

The "Verifying the built standalone EXE" line now correctly says "(fallback build system)"
instead of a hardcoded "(PyInstaller)" when the EXE being verified was actually Nuitka-built
(`:warn_user_code_launch` branches on `HP_NUITKA_FALLBACK_USED`). The postflight briefing's
"PyInstaller build cache" line is left as-is -- Nuitka never creates a `build\<env>\` folder of
its own (its `--remove-output` flag cleans up its own intermediates), so that line stays literally
true regardless of which tool actually built the current EXE: if a `build\` folder exists, it's
PyInstaller's.

---

## Scenario 2: PyInstaller build fails, Tier A fallback ALSO fails (tier exhaustion)

**What's tested:** `self.exe.build.xfail` (`tests/selfapps_pyinstaller_fail.ps1`, real/conda-full
lanes, gating). Two sub-scenarios share one NDJSON row id: `execfail` (the PyInstaller build
command itself fails) and `output_vanish` (PyInstaller succeeds, then the output EXE vanishes
immediately -- simulating AV-style post-creation removal). Both additionally force
`HP_TEST_FORCE_NUITKA_FAIL=1` so the fallback also fails, proving genuine tier exhaustion.

### 2a. `execfail` -- the PyInstaller build command itself fails

Real CI capture, run `29788624195`, job `88506013028` ("real" lane):

```
[INFO] Building standalone executable -- this may take a minute or two...
[TEST] HP_TEST_FORCE_PYINSTALLER_FAIL: simulating PyInstaller build failure.
[INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
[TEST] HP_TEST_FORCE_NUITKA_FAIL: simulating fallback build failure.
[ERROR] PyInstaller execution failed.
[DEBUG] warnfix: warn file not found
[INFO] PyInstaller build artifacts cleaned up.
[WARN] EXE smokerun: dist\<env>.exe not found; skipping
[INFO] Running entry script smoke test via uv interpreter.
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

[INFO] REQ-018: post-execution checkpoint (interpreter): declined (run footprint stays at one execution).
```

When BOTH the PyInstaller build and the Nuitka fallback fail outright, the bootstrapper does not
stop -- it falls through to running the entry script directly via the interpreter, and since that
trivial script runs cleanly, the final line is `[STATUS] Run Status: SUCCESS (Exit Code: 0)` --
identical wording to a genuine clean-EXE success, with no on-screen summary reminding the user
that no `.exe` was produced. This is intentional, documented design (see CLAUDE.md's Known
Finding on user-code exit-code semantics); whether the final wording should change is tracked as
an open question -- see `docs/open-questions.md` item 1.

### 2b. `output_vanish` -- PyInstaller succeeds, then the EXE disappears immediately

Real CI capture, same run/job as 2a, with the warnfix message updated to reflect a wording fix
made after this run (removes a stale "in the list above" reference, since the raw warn-file dump
that phrase pointed at only ever went to `~setup.log`, never the console) -- not yet re-confirmed
against a fresh CI capture:

```
[INFO] Building standalone executable -- this may take a minute or two...
[TEST] HP_TEST_FORCE_OUTPUT_VANISH: deleting freshly-built EXE to simulate post-creation removal.
[INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
[TEST] HP_TEST_FORCE_NUITKA_FAIL: simulating fallback build failure.
[ERROR] PyInstaller did not produce dist\<env>.exe
[DEBUG] warnfix: warn file found
[INFO] warnfix: some modules could not be automatically bundled (full list in ~warnfile.txt / ~setup.log); modules such as posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, and _frozen_importlib_external are expected on Windows and are filtered out automatically.
[INFO] PyInstaller build artifacts cleaned up.
[WARN] EXE smokerun: dist\<env>.exe not found; skipping
[INFO] Running entry script smoke test via uv interpreter.
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
[INFO] REQ-018: post-execution checkpoint (interpreter): declined (run footprint stays at one execution).
```

---

## Scenario 3: Tier A + hidden-import auto-recovery skip guard

**What's tested:** `self.exe.tiera.hidden_skip` (`tests/selfapps_nuitka_tiera_hidden_skip.ps1`, uv
lane, non-gating). Forces Tier A to trigger and succeed for real, then has the stub app fabricate
a `ModuleNotFoundError: No module named 'nuitka'` on stderr and exit 1 -- the exact signature that
used to (before this fix) trigger an incorrect PyInstaller rebuild attempt against a Nuitka-built
EXE.

**Source:** confirmed in real CI run `29877805447`, uv lane, job `88792048278`:
```
{"details":{"appStdoutFound":true,"noRepairRebuild":true,"successLogged":true,"skipGuardLogged":true,"exeExists":true,"statusState":"ok","bootstrapExit":0,"smokerunNonzeroLogged":true,"attemptLogged":true,"log":"~nuitka_tiera_hidden_skip_bootstrap.log"},"req":"REQ-AV","pass":true,"desc":"AV-Safe Build Path Tier A: hidden-import auto-recovery correctly skips (never rebuilds via PyInstaller) against a Nuitka-built EXE","id":"self.exe.tiera.hidden_skip","lane":"uv"}
```
The test only dumps a full console log to CI when a scenario fails; since this one passes, the
exact console text below is reconstructed from `run_setup.bat`'s source rather than copied from a
console dump -- the NDJSON row's `skipGuardLogged`/`noRepairRebuild` fields are the test's own
regex-verified confirmation that these exact lines were present/absent in the real captured log:

```
[INFO] Building standalone executable -- this may take a minute or two...
[TEST] HP_TEST_FORCE_PYINSTALLER_FAIL: simulating PyInstaller build failure.
[INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
[INFO] Fallback build succeeded: dist\<env>.exe was produced using the fallback build system.
[INFO] EXE smokerun: testing dist\<env>.exe
[WARN] EXE smokerun: exited 1 (non-zero)
[INFO][HIDDEN_IMPORT] Skipping --hidden-import auto-recovery: dist\<env>.exe was built via the fallback build system (Nuitka), which uses a different missing-import mechanism than PyInstaller's --hidden-import flag.
```

Without this guard, the OLD behavior would have printed
`[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=nuitka; rebuilding EXE (iter 1/3)` here and
attempted a PyInstaller rebuild against a Nuitka-built EXE.

---

## Scenario 4: Requirement 9 -- elective "want an optimized build too?" offer

**What's tested:** `self.optbuild.offer` (`tests/selfapps_optimized_build.ps1`, uv lane,
non-gating), four scenarios sharing one row id.

**Source:** confirmed in real CI run `29877805447`, uv lane, job `88792048278`, all four scenarios
passing:
```
{"lane":"uv","details":{"log":"~optbuild_accept_bootstrap.log","statusState":"ok","scenario":"accept","successLogged":true,"promptShown":true,"tmpExeGone":true,"exeExists":true,"bootstrapExit":0,"acceptedLogged":true,"appStillRuns":true},"desc":"AV-Safe Build Path requirement 9 (accept): a real optimized build succeeds, verifies, and is swapped into place","req":"REQ-AV","id":"self.optbuild.offer","pass":true}
{"req":"REQ-AV","lane":"uv","desc":"AV-Safe Build Path requirement 9 (forcefail): a failed optimized build leaves the original PyInstaller EXE completely untouched","id":"self.optbuild.offer","details":{"originalStillRuns":true,"bootstrapExit":0,"log":"~optbuild_forcefail_bootstrap.log","tmpExeGone":true,"promptShown":true,"exeExists":true,"testHookFired":true,"scenario":"forcefail","statusState":"ok","noSuccessMsg":true},"pass":true}
{"req":"REQ-AV","id":"self.optbuild.offer","lane":"uv","pass":true,"details":{"bootstrapExit":0,"acceptedLogged":true,"originalStillRuns":true,"log":"~optbuild_swapfail_bootstrap.log","promptShown":true,"exeExists":true,"tmpExeGone":true,"scenario":"swapfail","statusState":"ok","noSuccessMsg":true,"swapFailLogged":true},"desc":"AV-Safe Build Path requirement 9 (swapfail): a verified optimized build whose final swap fails leaves the original PyInstaller EXE completely untouched and cleans up the leftover temp file"}
{"desc":"AV-Safe Build Path requirement 9 (decline): default/CI path shows the prompt but never attempts a build","lane":"uv","details":{"statusState":"ok","noBuildAttempt":true,"tmpExeGone":true,"scenario":"decline","log":"~optbuild_decline_bootstrap.log","bootstrapExit":0,"exeExists":true,"declinedLogged":true,"promptShown":true},"req":"REQ-AV","id":"self.optbuild.offer","pass":true}
```

### 4a. `accept` -- a real optimized build succeeds and is swapped in

Real, verbatim console dump (`~selftest_optbuild_accept\~optbuild_accept_bootstrap.log`):

```
[INFO] Building standalone executable -- this may take a minute or two...
The system cannot find the drive specified.
The system cannot find the drive specified.
[INFO] PyInstaller produced dist\<env>.exe
[INFO] warnfix: Platform-specific modules in the list above are expected on Windows: posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, _frozen_importlib_external. These will be filtered out automatically.
[INFO] PyInstaller build artifacts cleaned up.
[INFO] EXE smokerun: testing dist\<env>.exe
[INFO] Running entry script smoke test via packaged EXE.
[WARN] Verifying the built standalone EXE (PyInstaller) now: it is force-stopped after about 30 seconds even if running perfectly, so do not start real work in it yet or any unsaved work will be lost.
[INFO] EXE smokerun: exited 0 (ok)
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
[INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: accepted; building now (this may take a minute or two).
[INFO] Optimized build succeeded and verified: dist\<env>.exe now uses the fallback build system.
```

Note the "warnfix: Platform-specific modules..." line above still shows the OLD wording (this
capture predates the messaging fix described in Scenario 2b) -- the NEW wording is the one shown
there; re-pull this capture once a fresh CI run exercises this path again.

**The interactive `Build the optimized version now? [Y/N]` prompt line is echoed unconditionally
by design** (same pattern as `:run_postexec_checkpoint`), but does not appear literally in any
CI capture -- CI answers via the `HP_TEST_OPTBUILD_ANSWER` env-var override, not the interactive
`set /p` path, so only the resolution lines (`accepted`/`declined`) show up in these logs. This is
expected (CI is non-interactive by design), not a gap.

### 4b. `forcefail` -- accepted, but the build fails; original EXE is left untouched

Real, verbatim console dump (`~selftest_optbuild_forcefail\~optbuild_forcefail_bootstrap.log`):

```
*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: accepted; building now (this may take a minute or two).
[TEST] HP_TEST_FORCE_OPTBUILD_FAIL: simulating optimized-build failure.
[INFO] REQ-016: Post-flight briefing printed.
```

No further message prints between the forced-fail log line and the (unrelated, always-present)
post-flight briefing -- the subroutine cleans up the temp file and returns silently. This is a
narrower silence than the wording used on a REAL build-failure branch (which explicitly says
"your app is still ready to use as-is" -- see the reactive hint below); a forced-test-hook failure
and a genuine build failure currently give the user different amounts of reassurance for what is,
from their perspective, the same outcome.

### 4c. `swapfail` -- verified build, but the final swap step fails; original EXE is left untouched

Regression test for a real bug: the swap-verification check used to test the DESTINATION file
(which already exists before the move, success or failure alike) instead of the SOURCE (which
should be gone only on success) -- a genuinely failed swap would have been silently misreported
as success. Fixed; console text (expected from source, not yet dumped in a CI console capture
since this scenario has passed on every run so far):

```
*** Your app is ready. ***
*** Want to build an optimized version too? ... ***
[INFO] Optimized build: accepted; building now (this may take a minute or two).
[WARN] Optimized build verified successfully but could not be swapped into place; your app is still ready to use as-is.
```

### 4d. `decline` -- default/CI path, prompt shown but nothing built

Real, verbatim console dump (`~selftest_optbuild_decline\~optbuild_decline_bootstrap.log`):

```
*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: declined.
```

### Reactive-only failure hint (both Tier A and requirement 9's real-build-failure paths)

Fires only on a GENUINE Nuitka compiler failure (not the `forcefail` test hook, which bypasses it
entirely). No CI run to date has exercised a real Nuitka compiler failure, so this is sourced from
`run_setup.bat` rather than a console capture:

```
[WARN] Optimized build did not complete; your app is still ready to use as-is.
[WARN] Hint: if you have Visual Studio 2022 (or newer) with the 'Desktop development with C++' workload installed, this should use it automatically -- no extra setup needed. If not, installing the free Visual Studio Build Tools with that workload can help.
```
