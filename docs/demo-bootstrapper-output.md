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

**Scope:** two parts, grouped by feature area and roughly in the order each was reviewed. Part I
covers the AV-Safe Build Path work (Tier A Nuitka fallback, its interaction with hidden-import
auto-recovery, and the requirement-9 optimized-build offer). Part II covers the CLI-interactivity
plan (`docs/plan-cli-interactive-verification.md`): live-tee verification, argv passthrough
(REQ-026), and honest ambiguous-exit messaging (REQ-027). Extend with a new Part as new feature
areas get reviewed, rather than growing either existing Part indefinitely.

**Console vs. `~setup.log`:** the bootstrapper writes to two different places that are easy to
conflate:
- The **live console** (what a real user watching the window sees) -- everything `:log` echoes,
  plus a handful of raw tool-output lines that aren't redirected.
- **`~setup.log`** (the internal file record) -- receives everything the console does, PLUS extra
  content deliberately redirected away from the console (e.g. the full raw PyInstaller warn-file
  dump). A CI test's "bootstrap log" capture (`cmd /c "call run_setup.bat > log 2>&1"`) matches the
  CONSOLE view, not `~setup.log`. Quotes below are from the console-equivalent capture unless
  stated otherwise.

## Table of contents

- [Part I: AV-Safe Build Path (Nuitka fallback)](#part-i-av-safe-build-path-nuitka-fallback)
  - [Scenario 1: PyInstaller build fails, Tier A (Nuitka) fallback succeeds](#scenario-1-pyinstaller-build-fails-tier-a-nuitka-fallback-succeeds)
  - [Scenario 2: PyInstaller build fails, Tier A fallback ALSO fails (tier exhaustion)](#scenario-2-pyinstaller-build-fails-tier-a-fallback-also-fails-tier-exhaustion)
    - [2a. `execfail`](#2a-execfail----the-pyinstaller-build-command-itself-fails)
    - [2b. `output_vanish`](#2b-output_vanish----pyinstaller-succeeds-then-the-exe-disappears-immediately)
  - [Scenario 3: Tier A + hidden-import auto-recovery skip guard](#scenario-3-tier-a-hidden-import-auto-recovery-skip-guard)
  - [Scenario 4: Requirement 9 -- elective "want an optimized build too?" offer](#scenario-4-requirement-9----elective-want-an-optimized-build-too-offer)
    - [4a. `accept`](#4a-accept----a-real-optimized-build-succeeds-and-is-swapped-in)
    - [4b. `forcefail`](#4b-forcefail----accepted-but-the-build-fails-original-exe-is-left-untouched)
    - [4c. `swapfail`](#4c-swapfail----verified-build-but-the-final-swap-step-fails-original-exe-is-left-untouched)
    - [4d. `decline`](#4d-decline----defaultci-path-prompt-shown-but-nothing-built)
    - [Reactive-only failure hint](#reactive-only-failure-hint-both-tier-a-and-requirement-9s-real-build-failure-paths)
- [Part II: CLI interactivity, argv passthrough & honest messaging](#part-ii-cli-interactivity-argv-passthrough-honest-messaging)
  - [Scenario 5: Interactive verification -- live-tee, activity-aware kill, and the quit-prompt hint](#scenario-5-interactive-verification----live-tee-activity-aware-kill-and-the-quit-prompt-hint)
  - [Scenario 6: Argv passthrough (REQ-026) -- launch arguments through the bootstrapper](#scenario-6-argv-passthrough-req-026----launch-arguments-through-the-bootstrapper)
  - [Scenario 7: Honest ambiguous-exit messaging (REQ-027)](#scenario-7-honest-ambiguous-exit-messaging-req-027)
    - [7a. No-EXE path, interpreter also failed](#7a-no-exe-path-interpreter-also-failed)
    - [7b. Cached-EXE fast path, kept despite a non-zero exit](#7b-cached-exe-fast-path-kept-despite-a-non-zero-exit)
- [Part III: Default double-click happy path (uv-first, fresh machine, zero flags)](#part-iii-default-double-click-happy-path-uv-first-fresh-machine-zero-flags)
  - [Scenario 8: Pre-flight guards, lock acquisition, and entry detection on a clean run](#scenario-8-pre-flight-guards-lock-acquisition-and-entry-detection-on-a-clean-run)
  - [Scenario 9: Provider acquisition and dependency install (uv-first)](#scenario-9-provider-acquisition-and-dependency-install-uv-first)
  - [Scenario 10: Build, verify, and the final status panel](#scenario-10-build-verify-and-the-final-status-panel)
  - [Scenario 11: The two elective prompts a real user faces after every successful run](#scenario-11-the-two-elective-prompts-a-real-user-faces-after-every-successful-run)

---

## Part I: AV-Safe Build Path (Nuitka fallback)

### Scenario 1: PyInstaller build fails, Tier A (Nuitka) fallback succeeds

**What's tested:** `self.exe.build.tiera` (`tests/selfapps_nuitka_tiera.ps1`, uv lane,
non-gating). `HP_TEST_FORCE_PYINSTALLER_FAIL=1` forces the primary build to fail deterministically;
the Nuitka fallback (`:try_nuitka_tier_a`) then runs for real -- a genuine compile, not simulated.

**What appears on screen**, from the moment PyInstaller's build is attempted through to the final
summary. Sourced from real CI (run `29788624195`, job `88506013149`), with the "(fallback build
system)" verification line and the drive-message reassurance line as originally captured, but the
"Verifying the built standalone EXE" line and the "Does your program need launch arguments"
paragraph both updated in place to the CURRENT shipped wording (`docs/plan-cli-interactive-
verification.md` requirement 3's activity-aware kill, and REQ-026's argv passthrough -- both
landed after this specific run) -- **not yet re-confirmed against a fresh CI capture that includes
either addition**:

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
[WARN] Verifying the built standalone EXE (fallback build system) now: if it stays completely silent for about 30 seconds it will be force-stopped, but any output (including a prompt waiting on your input) keeps it running as long as needed. If your program is interactive, try answering its prompts through to its own quit/exit option now so we can confirm it exits cleanly. Either way, do not start real work in it yet or any unsaved work will be lost.
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

   Does your program need launch arguments (e.g. --input file.csv)? Run
   this bootstrapper again with them added after the entry file, e.g.
     run_setup.bat "<entry.py>" --input file.csv
   and they will be forwarded to your program during THIS setup run
   (up to 8 extra arguments). This does not change how a plain
   double-click of dist\<env>.exe launches it afterward -- for that,
   make a Windows shortcut to the .exe and add the arguments to its
   Target field, or launch it yourself from a Command Prompt.

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
PyInstaller's. See Scenario 6 for the argv-passthrough paragraph's own dedicated writeup.

---

### Scenario 2: PyInstaller build fails, Tier A fallback ALSO fails (tier exhaustion)

**What's tested:** `self.exe.build.xfail` (`tests/selfapps_pyinstaller_fail.ps1`, real/conda-full
lanes, gating). Three sub-scenarios share one NDJSON row id: `execfail` (the PyInstaller build
command itself fails), `output_vanish` (PyInstaller succeeds, then the output EXE vanishes
immediately -- simulating AV-style post-creation removal), and `execfail_runtimefail` (packaging
fails AND the interpreter fallback that runs next ALSO exits non-zero -- see Scenario 7a for that
one's console text, since it's really a REQ-027 demo). The first two additionally force
`HP_TEST_FORCE_NUITKA_FAIL=1` so the fallback also fails, proving genuine tier exhaustion.

#### 2a. `execfail` -- the PyInstaller build command itself fails

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

When BOTH the PyInstaller build and the Nuitka fallback fail outright but the interpreter
fallback's own run exits 0 (this trivial stub script does), the final line is
`[STATUS] Run Status: SUCCESS (Exit Code: 0)` and the postflight panel is the plain
"YOUR CODE RAN -- BUT NO STANDALONE .EXE WAS PRODUCED" variant -- see Scenario 7a for the
DIFFERENT (honest, "we can't confirm") panel this same tier-exhaustion path now shows when the
interpreter run ALSO fails, which is the REQ-027 fix that closed the gap this section used to flag
as an open question.

#### 2b. `output_vanish` -- PyInstaller succeeds, then the EXE disappears immediately

Real CI capture, same run/job as 2a:

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

### Scenario 3: Tier A + hidden-import auto-recovery skip guard

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

### Scenario 4: Requirement 9 -- elective "want an optimized build too?" offer

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

#### 4a. `accept` -- a real optimized build succeeds and is swapped in

Real, verbatim console dump (`~selftest_optbuild_accept\~optbuild_accept_bootstrap.log`), with the
"Verifying the built standalone EXE" line updated in place to the CURRENT shipped wording
(requirement 3's activity-aware kill plus the quit-prompt hint, both landed after this capture) --
**not yet re-confirmed against a fresh CI capture**:

```
[INFO] Building standalone executable -- this may take a minute or two...
The system cannot find the drive specified.
The system cannot find the drive specified.
[INFO] PyInstaller produced dist\<env>.exe
[INFO] warnfix: Platform-specific modules in the list above are expected on Windows: posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, _frozen_importlib_external. These will be filtered out automatically.
[INFO] PyInstaller build artifacts cleaned up.
[INFO] EXE smokerun: testing dist\<env>.exe
[INFO] Running entry script smoke test via packaged EXE.
[WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent for about 30 seconds it will be force-stopped, but any output (including a prompt waiting on your input) keeps it running as long as needed. If your program is interactive, try answering its prompts through to its own quit/exit option now so we can confirm it exits cleanly. Either way, do not start real work in it yet or any unsaved work will be lost.
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
there.

**The interactive `Build the optimized version now? [Y/N]` prompt line is echoed unconditionally
by design** (same pattern as `:run_postexec_checkpoint`), but does not appear literally in any
CI capture -- CI answers via the `HP_TEST_OPTBUILD_ANSWER` env-var override, not the interactive
`set /p` path, so only the resolution lines (`accepted`/`declined`) show up in these logs. This is
expected (CI is non-interactive by design), not a gap.

#### 4b. `forcefail` -- accepted, but the build fails; original EXE is left untouched

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

#### 4c. `swapfail` -- verified build, but the final swap step fails; original EXE is left untouched

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

#### 4d. `decline` -- default/CI path, prompt shown but nothing built

Real, verbatim console dump (`~selftest_optbuild_decline\~optbuild_decline_bootstrap.log`):

```
*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: declined.
```

#### Reactive-only failure hint (both Tier A and requirement 9's real-build-failure paths)

Fires only on a GENUINE Nuitka compiler failure (not the `forcefail` test hook, which bypasses it
entirely). No CI run to date has exercised a real Nuitka compiler failure, so this is sourced from
`run_setup.bat` rather than a console capture:

```
[WARN] Optimized build did not complete; your app is still ready to use as-is.
[WARN] Hint: if you have Visual Studio 2022 (or newer) with the 'Desktop development with C++' workload installed, this should use it automatically -- no extra setup needed. If not, installing the free Visual Studio Build Tools with that workload can help.
```

---

## Part II: CLI interactivity, argv passthrough & honest messaging

Covers `docs/plan-cli-interactive-verification.md` (P0/P1/P2, all shipped): the live-tee
verification redesign that lets an interactive `input()`-driven program's prompts actually reach
the console, the activity-aware 30-second kill, argv passthrough (REQ-026), and the honest
ambiguous-exit messaging panels (REQ-027).

### Scenario 5: Interactive verification -- live-tee, activity-aware kill, and the quit-prompt hint

**What changed, in one sentence:** before this plan, `:run_exe_smokerun`'s verification launch
force-killed at a hard 30 seconds regardless of output, and captured stdout/stderr only to a file
(never live to the console) -- so a program correctly waiting on its first `input()` prompt looked
identical to a genuinely hung one, and the user watching the window saw nothing until the process
either finished or got killed.

**What's tested (the plumbing):** `self.interactive.stdin.roundtrip`
(`tests/selfapps_interactive_stdin.ps1`, uv lane, non-gating) builds a real PyInstaller EXE from a
multi-round `input()`-driven stub app and pipes a scripted answer sequence into `cmd.exe`'s own
stdin, exercising the full `cmd.exe -> :run_exe_smokerun -> ~exe_smokerun.ps1 -> the built EXE`
chain and asserting each answer lands in the right round via ordering checks on the captured log
-- it proves the plumbing doesn't drop or reorder stdin/stdout, not a live human's own typing
timing (which can't be automated).

**The WARN line a user sees right before the verification launch**, current shipped wording
(source: `run_setup.bat`, `:warn_user_code_launch` -- not a console capture, since CI answers
scripted stdin rather than a human watching the window; Scenario 1 and Scenario 4a above both show
this exact line in situ):

```
[WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent for about 30 seconds it will be force-stopped, but any output (including a prompt waiting on your input) keeps it running as long as needed. If your program is interactive, try answering its prompts through to its own quit/exit option now so we can confirm it exits cleanly. Either way, do not start real work in it yet or any unsaved work will be lost.
```

Three things this one line is doing:
1. **States the actual kill rule truthfully**: the 30-second cap is a classification checkpoint,
   not an unconditional deadline -- `Kill()` only fires if the process has stayed COMPLETELY
   silent that whole time. Any output (including a bare prompt with no trailing newline, the exact
   shape of Python's own `input("...")`) switches to an unbounded wait.
2. **Actively guides the user toward a clean result**: driving an interactive program to its own
   quit/exit option during this pass turns an otherwise-ambiguous exit into a genuine, confirmed
   `[STATUS] Run Status: SUCCESS` -- this directly reduces how often a real user ever sees either
   of Scenario 7's ambiguous-exit panels.
3. **Still warns it's a throwaway pass, not the user's real, saveable session** -- this verification
   EXE is never reused; only the file it's already tested is kept for later double-clicks.

The `hidden_import` recovery loop's own separate, narrower verification check (see
`docs/agent-interconnect.md`'s "Activity-aware EXE-smoke kill" section) deliberately keeps the
OLDER, unconditional 30-second wording -- it's a bounded repair-verification check on an
already-built EXE, not the user's primary run, so it never got the interactive-friendly rewrite.

### Scenario 6: Argv passthrough (REQ-026) -- launch arguments through the bootstrapper

Extra arguments after the entry file on `run_setup.bat`'s own command line (up to 8) are forwarded
verbatim to the target program at every real launch site -- the cached-EXE fast path, the fresh EXE
verification, the no-EXE interpreter run, and the post-execution checkpoint's elective second run.
This is a documented, opt-in escape hatch (no detection or heuristics involved) for a program that
needs `--flag value`-style launch arguments to run correctly, on top of this bootstrapper's usual
zero-argument double-click flow.

**The postflight guidance a user sees after a successful EXE build** (Scenario 1's full panel
above shows this in context):

```
   Does your program need launch arguments (e.g. --input file.csv)? Run
   this bootstrapper again with them added after the entry file, e.g.
     run_setup.bat "<entry.py>" --input file.csv
   and they will be forwarded to your program during THIS setup run
   (up to 8 extra arguments). This does not change how a plain
   double-click of dist\<env>.exe launches it afterward -- for that,
   make a Windows shortcut to the .exe and add the arguments to its
   Target field, or launch it yourself from a Command Prompt.
```

**The equivalent guidance on the no-EXE path** (direct-interpreter-invocation form, part of
Scenario 7a's panel below):

```
   Need launch arguments? Add them directly after that command, e.g.
     "<python>" "<entry.py>" --input file.csv
```

Both are additive to the launch commands already shown in each panel, not a separate prompt --
matching this bootstrapper's general rule that env-var/CLI flags only ever add an opt-in path or
suppress an optional step, never gate a behavior the Prime Directive needs (see CLAUDE.md's
`[REQ-019]`).

### Scenario 7: Honest ambiguous-exit messaging (REQ-027)

Both panels below fire only when a verification run ends AMBIGUOUSLY -- the program exited with an
error, and no automatic repair (`--hidden-import` auto-recovery, the REQ-009 dependency-resolution
cascade) fixed it. Neither panel claims to know WHY: a bug in the program's own code, something
this bootstrapper missed, or an unresolved dependency are all indistinguishable from here, and both
panels say so plainly rather than guessing. This is messaging only -- `~bootstrap.status.json`
semantics, the process exit code, and consent-gate behavior are all unchanged.

Both are new enough (shipped, then refined once more for wording, entirely within this same
session) that no CI run has yet produced a console capture including the current wording -- both
quotes below are sourced directly from `run_setup.bat`, not a job log.

#### 7a. No-EXE path, interpreter also failed

Fires when BOTH PyInstaller and the Nuitka fallback fail to package the app outright, AND the
interpreter fallback that runs next (the only way left to run the program at all) also exits
non-zero -- the scenario Scenario 2a's own `execfail` sub-case would hit if its trivial stub script
didn't happen to exit cleanly. Source: `:print_no_exe_briefing`'s `:noexe_caveat` branch,
`run_setup.bat`:

```
============================================================
 NO STANDALONE .EXE -- AND WE CAN'T CONFIRM YOUR CODE RAN CLEANLY
============================================================
 We could not package your app into a double-clickable .exe
 (see the ERROR message above for why). We also just ran it
 directly via the prepared Python environment, and it exited
 with an error (see the [STATUS] line above) -- so we can't
 tell whether that's a bug in the Python code we tried to run
 or something this bootstrapper missed. Your environment and
 dependencies ARE still installed correctly; run it yourself
 below to see the full output.

 RUNNING YOUR APP (without an .exe) -- the most direct option
   "<python>" "<entry.py>"
   Need launch arguments? Add them directly after that command, e.g.
     "<python>" "<entry.py>" --input file.csv

 Want to try different arguments through the bootstrapper itself
 instead? Your already-installed environment is reused either
 way; it will just attempt the .exe build again too:
   run_setup.bat "<entry.py>" arg1 arg2

 KEEP these files with your project:
   requirements.txt  -- packages your app depends on
   runtime.txt       -- Python version pin

 SAFE TO DELETE to reclaim disk space:
   .*_env\ folders   -- environment directories
   ~* files          -- tilde-prefix work files (e.g. ~setup.log)
============================================================
```

The direct-run command stays the visually primary option (matches this panel's own established
preference for running the program directly over going back through the bootstrapper); the
bootstrapper-rerun mention is deliberately secondary and uses the real entry filename (`%HP_ENTRY%`
is reliably set by this point in the pipeline -- unlike Scenario 7b below).

When the interpreter run instead exits CLEANLY (the common case, and what Scenario 2a's own capture
shows), this panel's header and opening paragraph read differently -- plain "YOUR CODE RAN -- BUT
NO STANDALONE .EXE WAS PRODUCED", with no claim of an unconfirmed run -- but the rest of the panel
(launch commands, KEEP/SAFE TO DELETE lists) is identical either way.

#### 7b. Cached-EXE fast path, kept despite a non-zero exit

Fires when the fail-fast probe classifies a REUSED `dist\<env>.exe` (the top-of-file fast path,
before any provider/entry-file logic runs) as alive/healthy -- so it's kept, never
discarded-and-rebuilt -- and it later exits non-zero. Before this fix, this exact case had no
postflight signal at all beyond one `[WARN]` log line buried among other console output. Source:
`:print_fastpath_ambiguous_note`, `run_setup.bat`:

```
============================================================
 SETUP COMPLETE -- BUT WE CAN'T CONFIRM YOUR LAST RUN WORKED
============================================================
 Your existing standalone application was reused (dist\<env>.exe),
 and it exited with an error just now (see the [STATUS] line
 above) -- so we can't tell whether that's a bug in the Python
 code we tried to run, or something else. Your environment and
 dependencies ARE still installed correctly.

 RUNNING YOUR APP
   Double-click dist\<env>.exe to run it, or run it from a
   Command Prompt to see the full output.

 WANT TO TRY AGAIN? You do not have to start over from scratch --
   just run this bootstrapper again the same way you did before;
   your already-installed environment and built .exe are reused.

 WANT A FRESH BUILD instead (re-checks all dependencies from scratch)?
   Delete dist\<env>.exe and run this bootstrapper again.
============================================================
```

This panel is a PLAIN INFORMATIONAL PRINT, never a consent gate -- the cached-EXE fast path is
deliberately zero-friction for prompts (see `docs/agent-interconnect.md`'s "Fast path = ZERO
friction" design requirement), and this doesn't violate that since it never asks a question.

**No entry filename appears anywhere in this panel, unlike 7a's rerun mention -- deliberately.**
`HP_ENTRY` is not set yet at the point the top-of-file fast path runs (it fires before
`:determine_entry` ever executes, since the cached EXE is self-contained and doesn't need the
original source filename to relaunch), so naming one here would show blank or stale text. The two
rerun options are worded to distinguish a genuinely different tradeoff instead: rerunning WITHOUT
deleting the EXE reuses it (via the same fast path that got the user here) with no promise about
whether it's actually faster overall, while deleting it first forces a full, slower, from-scratch
dependency check.

---

## Part III: Default double-click happy path (uv-first, fresh machine, zero flags)

**Scope note:** Parts I and II each document one feature area's edge cases. This Part documents
the OTHER thing this doc has never shown: what a completely ordinary run looks like end to end --
one `.py` file, no test hooks, no prior state, no flags, uv reachable (the REQ-009 default,
`uv -> conda -> embed -> venv -> system`). This is what the large majority of real users actually
see. Evidence is pulled from a recent fully-green run (`30328748330`, commit `5872028`, all lanes
green) rather than any single dedicated "happy path" test -- no such test exists as one file, so
each piece below is sourced from whichever real, non-`HP_CI_SKIP_ENV` sub-bootstrap in that run
exercises it most faithfully (mainly `tests/selfapps_envsmoke.ps1`'s real env-smoke sub-bootstrap
and `tests/selftest.ps1`'s stub-app fast path), cited individually per item.

**A structural caveat that applies to every scenario in this Part, stated once here instead of
repeated per-scenario:** every CI lane sets `HP_CI_LANE` at the job level (`batch-check.yml`),
which silently auto-declines every consent prompt in the file the instant it's reached, with no
wait. A genuine double-click has none of `HP_CI_LANE`/`NOINPUT`/`HP_NONINTERACTIVE` set, so any
prompt this Part encounters would, for a real user, actually pause and wait for a keypress (or,
for the one genuinely timed gate, wait up to its timeout) instead of resolving instantly. Scenario
11 below covers this distinction in detail for the two prompts that fire on this exact happy path;
it applies identically to every other consent gate documented elsewhere in this file.

### Scenario 8: Pre-flight guards, lock acquisition, and entry detection on a clean run

**What's tested:** no single dedicated test asserts the CLEAN (non-firing) pass of these checks --
`docs/agent-ndjson.md` only registers rows for the *firing* branches (`self.warn.onedrive`,
`self.warn.longpath`, `self.warn.sysdir`, `self.stub.lock_held_decline`, etc.). The evidence below
is the incidental byproduct of `tests/selfapps_envsmoke.ps1`'s full, real bootstrap, which captures
every byte of console output via `cmd /c .\run_setup.bat > '~envsmoke_bootstrap.log'`.

**Source:** REAL CI CAPTURE, run `30328748330`, `tests/~envsmoke/~envsmoke_bootstrap.log`
(published diagnostics site), identical across all 6 lanes checked (`real`, `uv`, `conda-full`,
`justme-test`, `contract-uv`, `contract-uv-fail`):

```
[WARN] UNC paths not supported
Tue 07/28/2026  4:29:43.96 [INFO] REQ-015: Appending standard ignores to .gitignore.
```

**The very first console line is an unexplained anomaly, not a mistake in this doc.** `[WARN] UNC
paths not supported` (`run_setup.bat:57-58`) fired on 6/6 checked lanes against an entirely
ordinary local CI checkout path (`D:\a\Python_vs_Windows\Python_vs_Windows\tests\~envsmoke\`) --
not a UNC path. The companion, independent UNC-prefix check two lines below (`if
"%HP_SCRIPT_LAUNCH_DIR:~0,2%"=="\\"`, which prints the much louder `*** WARNING: UNC/network
paths detected...` banner) never fires in the same logs, so whatever produces this WARN is not
"the whole path is UNC" -- root cause unconfirmed. See CLAUDE.md Active Backlog item 8 for the
full trace and why this wasn't chased further in this documentation-only pass. **Whether this also
fires for a genuine end-user double-click on an ordinary local folder is unknown** -- flagged here
rather than silently omitted, since a real user seeing an unexplained "UNC paths not supported"
warning on their very first line of output (on a completely normal local folder) would reasonably
be confused by it.

Between that line and `REQ-015`, nothing else prints -- `HP_APP_ARGS` capture (REQ-026, pure
variable assignment), the workspace-path-exists check, `cd /d`, and `HP_SCRIPT_ROOT` construction
(`run_setup.bat:34-79`) are all silent by design on a clean pass.

**The four REQ-025-family pre-flight guards (path-length, OneDrive, system-directory, disk-space --
`run_setup.bat:103-178`) are completely silent unless they fire.** Confirmed by both the absence
of any related text anywhere in the captured log, AND by reading the source: none of the four has
an `else` branch that prints a success/clean message -- each is a bare `if (...) ( echo/log ... )`
with nothing on the false path. A real user on an ordinary setup (short path, not under OneDrive,
not under `Windows`/`Program Files`, plenty of free disk) sees zero output from any of these four
checks.

**`:acquire_lock` (`run_setup.bat:4368-4404`) is equally silent on an uncontended acquire.** The
`mkdir "%HP_LOCK_DIR%"` call succeeds immediately (no prior lock directory), jumps straight to
`:lock_acquired`, writes a transient `~bootstrap.lock\owner.txt` marker (a file, not console
output), and returns -- every `echo`/`:log` call inside `:acquire_lock` lives inside the
"another instance is already running" branch, only reached on a genuine `mkdir` failure. The lock
directory (and its `owner.txt`) is gone again by the time the run completes (`:release_lock`,
called from both `:die` and `:success`, is equally silent).

**Entry detection for the common single-`.py`-file case** (`:determine_entry` ->
`tools/find_entry.py` -> `:record_chosen_entry`, `run_setup.bat:2549-2711`) produces exactly one
line, sourced from `tests/~envsmoke/~setup.log` (same run, real `run_setup.bat:1768` production
call site -- not the separate `HP_CI_SKIP_ENV`-only `:ci_skip_entry` implementation that
`tests/selfapps_entry.ps1`/`selfapps_single.ps1` exercise, which looks textually similar but is a
different code path):

```
Chosen entry: app.py
```

This is identical whether the sole `.py` file has a preferred name (`main.py`/`app.py`/`run.py`/
`cli.py`) or an arbitrary one (`tools/find_entry.py`'s `len(files) == 1` branch handles both the
same way, with zero stderr diagnostics either way) -- the interactive picker
(`:pick_entry_interactive`) is only ever reached when more than one `.py` file is ambiguous, which
this scenario deliberately doesn't have. `:determine_entry` actually runs twice in a normal
bootstrap (once early, for PEP 723/autopep723 discovery purposes at `run_setup.bat:1033`, and once
again at line 1768 for the real entry-selection that produces this console line) -- only the
second call's result is what a user sees echoed.

---

### Scenario 9: Provider acquisition and dependency install (uv-first)

**What's tested:** `tests/selfapps_envsmoke.ps1`'s real sub-bootstrap (`self.env.smoke.*` rows),
uv-first lane, against a stub `app.py` that genuinely does `import colorama` -- a real, if small,
dependency, chosen deliberately over a zero-dependency stub so the dependency-discovery/install
machinery actually has something to do.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` ("real" lane),
`tests/~envsmoke/~envsmoke_bootstrap.log` (what a real user's terminal shows) and
`tests/~envsmoke/~setup.log` (internal detail file, receives everything the console does PLUS
extra content this repo deliberately never puts on-screen -- see this doc's own "Console vs.
`~setup.log`" note at the top). Both are cited below, labeled.

**IMPORTANT: this exact CI run's job-level "Bootstrap environment (run_setup.bat)" step is NOT
representative evidence for this scenario** -- that step runs `run_setup.bat` against the
bootstrapper repo's OWN root (no loose `.py` files there), so it takes the `no_python_files`
graceful-exit path and produces nothing relevant. The genuinely representative evidence is the
"Self-test: real env smoke (CI-only)" step's own inner sub-bootstrap, which runs
`run_setup.bat` for real against a scratch app directory (matches CLAUDE.md's own documented
finding for Active Backlog item 15/`conda_avail`'s history -- the same distinction applies here).

**uv acquisition** (console, first-ever run, no cached `~uv_bin` -- every fresh CI scratch dir
starts this way, matching a real user's first-ever double-click):

```
[INFO] uv: UV_PYTHON_PREFERENCE=only-managed (orchestration uses managed Python).
[INFO] uv: downloading to ~uv_bin...
[INFO] Downloading uv from https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip...
[INFO] uv: acquired at ~uv_bin\uv.exe
[INFO] uv-first: Miniconda download skipped.
```

(`~setup.log`-only, never shown on-screen: curl's own progress-bar text between the "downloading"
and "acquired" lines, plus uv's own managed-CPython fetch triggered by the version-detection call
-- `Downloading cpython-3.14.6-windows-x86_64-none (download) (21.5MiB)` /
`Downloaded cpython-3.14.6-windows-x86_64-none (download)`. On a REPEAT run with `~uv_bin` already
populated, `run_setup.bat:537`'s cached-binary branch instead logs `[INFO] uv: cached binary found
at ~uv_bin\uv.exe` -- not independently captured here since every CI scratch dir is fresh; see
Part IV/Pass 2 for the dedicated repeat-run treatment.)

**uv venv creation** (console, no pre-existing version pin -- this app has neither `runtime.txt`
nor a `pyproject.toml` constraint):

```
[INFO] uv: creating venv at .uv_env...
[INFO] uv: venv created at .uv_env
[INFO] HP_ENV_MODE=uv
[BOOT] REQ-009: Selected Python provider: UV.
[INFO] runtime.txt written: python-3.14.6
```

A version-constrained app (e.g. `pyproject.toml` with `requires-python = ">=3.9"`) instead logs
`[INFO] uv: creating venv at .uv_env with Python 3.9 or newer...` -- confirmed via a second real
capture in the same run (`tests/~pyproject_prec/~pyproject_prec_bootstrap.log`), an exact pin like
`python==3.11` templates to `...with Python 3.11...` per the `HP_UV_PY_DISP` derivation at
`run_setup.bat:817-824` (not independently captured, but the template is a literal source string,
not inferred). `~setup.log`-only detail: uv's own raw venv output (`Using CPython 3.14.6`,
`Creating virtual environment with seed packages at: .uv_env`, a `Failed to hardlink files;
falling back to full copy` warning, `+ pip==26.1.2`, `Activate with: .uv_env\Scripts\activate`) --
none of this reaches the console.

**Dependency discovery** -- pipreqs and the REQ-005.12 `autopep723 check` Tier 1 merge running
TOGETHER, genuine production behavior (no `HP_SKIP_PIPREQS` test-isolation flag involved, unlike
the dedicated `selfapps_autopep_discovery.ps1`/`selfapps_pvw_idempotent.ps1` tests that deliberately
isolate one mechanism from the other):

```
[INFO] pipreqs 0.4.13 installed successfully; using it for dependency discovery.
[INFO] pipreqs (direct) command: pipreqs . --force --mode compat --savepath "...\requirements.auto.txt" --ignore ".git,.github,.venv,venv,env,.uv_env,build,dist,__pycache__,tests"
*** [WARN] Dependencies were auto-detected (pipreqs)
*** [WARN] Auto-detection may be incomplete or incorrect
*** [INFO] Consider adding requirements.txt or PEP 723 metadata for reliability
[INFO] REQ-005.5: dependency source diff computed -- ~pipreqs.diff.txt
[INFO] REQ-005.12: autopep723 discovery merge complete.
```

**A real quirk worth flagging so it isn't misread**: the bootstrap log around this point also shows
`DEP_FINAL_COUNT=0` even though `colorama` is a genuine, real dependency that gets installed a few
steps later -- this count is taken BEFORE `requirements.auto.txt` is copied into `requirements.txt`
a few lines further down (`run_setup.bat:1330-1358`), so `DEP_FINAL_COUNT=0` here does not mean
"pipreqs found nothing"; it's a pre-existing ordering quirk in the log sequence, not a bug in this
run. `~setup.log`-only (pipreqs's raw output is redirected to a SEPARATE file entirely,
`~pipreqs_direct.log`, not even `~setup.log` -- a real user never sees any of the following):
```
WARNING: Import named "colorama" not found locally. Trying to resolve it at the PyPI server.
WARNING: Import named "colorama" was resolved to "colorama:0.4.6" package (https://pypi.org/project/colorama/).
Please, verify manually the final list of requirements.txt to avoid possible dependency confusions.
INFO: Successfully saved requirements file in ...\requirements.auto.txt
```
plus a handful of cosmetic `SyntaxWarning` lines from pipreqs 0.4.13's own bundled `docopt`/`yarg`
dependencies. `~setup.log` also shows the autopep723 merge's own uvx tool-bootstrap noise
(`Installed 1 package in 26ms`) and its own result line, `no-op: all autopep723 dependencies
already present` -- because pipreqs already found `colorama` first, autopep723's own independent
discovery of the same import is redundant here, a real working example of this repo's "augment,
never replace" design for the two mechanisms.

**Dependency install:**

```
[INFO] UV_USED=1
[INFO] DEP_INSTALLED_CAPTURED=1
[INFO] Environment snapshot written: ~environment.lock.txt
[INFO] REQ-005.11: PEP 723 header write-back succeeded via uv add --script.
```

`~setup.log`-only (`uv pip install --python ... -r requirements.txt`'s own raw output, never on
console): `Using Python 3.14.6 environment at: .uv_env`, `Resolved 1 package in 257ms`, `Prepared
1 package in 43ms`, `Installed 1 package in 15ms`, ` + colorama==0.4.6`. The real
`~environment.lock.txt` (uv mode copies the pip-freeze output here) contains more than just
`colorama` -- it also lists pipreqs's OWN transitive dependencies (`certifi`, `charset-normalizer`,
`docopt`, `idna`, `pipreqs`, `requests`, `urllib3`, `yarg`), because in `HP_ENV_MODE=uv`, pipreqs
is installed via `uv pip install --python "%HP_PY%"` into the SAME venv as the target app
(`run_setup.bat:1105`), not an isolated tool venv. This is genuine, expected production behavior
-- a real user's `.uv_env` always ends up with pipreqs's own dependency footprint mixed in
alongside their actual dependencies, not a CI artifact.

---

### Scenario 10: Build, verify, and the final status panel

**What's tested:** `self.stub.fastpath` (`tests/selftest.ps1`, real lane), a genuine first-run
(non-cached) build of a trivial one-line stub app (`hello_stub.py` = `print("hello-from-stub")`).
Chosen over Scenario 9's `colorama`-importing app for this piece specifically because it produces
a single, fully self-consistent, real capture spanning build through the final status panel with
zero staleness caveats -- strictly better evidence than the similar block quoted in Scenario 1
(Part I), which has two lines marked "not yet re-confirmed against a fresh capture."

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` ("real" lane),
`tests/~selftest_stub/~stub_bootstrap.log`:

```
Tue 07/28/2026  4:55:47.55 [INFO] Building standalone executable -- this may take a minute or two...
Tue 07/28/2026  4:55:47.55 [INFO] (A stray one-line Windows message about a missing drive may appear next -- that is a known side effect from an unrelated background process, unrelated to your app; safe to ignore.)
The system cannot find the drive specified.
The system cannot find the drive specified.
Tue 07/28/2026  4:55:58.01 [INFO] PyInstaller produced dist\_selftest_stub.exe
Tue 07/28/2026  4:55:58.02 [DEBUG] warnfix: warn file found
Tue 07/28/2026  4:55:58.02 [INFO] warnfix: some modules could not be automatically bundled (full list in ~warnfile.txt / ~setup.log); modules such as posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, and _frozen_importlib_external are expected on Windows and are filtered out automatically.
Tue 07/28/2026  4:55:58.39 [INFO] PyInstaller build artifacts cleaned up.
Tue 07/28/2026  4:55:58.40 [INFO] EXE smokerun: testing dist\_selftest_stub.exe
Tue 07/28/2026  4:55:58.41 [INFO] Running entry script smoke test via packaged EXE.
Tue 07/28/2026  4:55:58.43 [WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent for about 30 seconds it will be force-stopped, but any output (including a prompt waiting on your input) keeps it running as long as needed. If your program is interactive, try answering its prompts through to its own quit/exit option now so we can confirm it exits cleanly. Either way, do not start real work in it yet or any unsaved work will be lost.
[INFO] Process ID 6076. If it seems stuck: Task Manager > Details tab > find this PID > End Task (this window stays open).
hello-from-stub
Tue 07/28/2026  4:55:59.87 [INFO] EXE smokerun: exited 0 (ok)
Tue 07/28/2026  4:55:59.88 [INFO] Entry smoke exit=0
Tue 07/28/2026  4:55:59.88 [STATUS] Run Status: SUCCESS (Exit Code: 0)
```

Build took ~10.5s wall-clock here (this run has effectively zero dependencies, so it's near the
fast end of what's possible). This run's PyInstaller build DID trigger the warnfix path (`warn
file found` -- expected, since even a bare stub still needs the platform-module filter pass) but
needed no repair install, so the informational filter messaging is present but purely
informational -- the "no warnfix repair needed" success case this doc previously had no example
of. `hello-from-stub` is the stub program's OWN real stdout, live-teed via
`tools/exe_smokerun.ps1`'s chunk-based `ReadAsync` reader (see Scenario 5's fuller writeup of that
mechanism) -- landing exactly between the PID line and the "exited 0" line, precisely where a real
user's own program output appears. The `[INFO] Process ID <n>. If it seems stuck: Task Manager >
Details tab...` line is the already-shipped stuck-program recovery aid (`tools/exe_smokerun.ps1`,
see `docs/agent-interconnect.md`'s "Process-ID display for stuck-program recovery" section) --
confirmed here as a genuine, working console line, not just source text.

Immediately following (elective prompts, both auto-declined by CI -- see Scenario 11 below for
what a real user experiences here instead) and then the final panel:

```
*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
Tue 07/28/2026  4:55:59.91 [INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
Tue 07/28/2026  4:55:59.94 [INFO] Optimized build: declined.

============================================================
 SETUP COMPLETE
============================================================
 Your standalone application is ready:
   dist\_selftest_stub.exe

 RUNNING YOUR APP
   Double-click dist\_selftest_stub.exe to run it.

   STARTUP MAY BE SLOW: a one-file .exe unpacks itself each time it
   starts, so allow 10-15 seconds (longer for big libraries like
   numpy/scipy/matplotlib, or when extra packages were bundled to fix
   missing imports) before assuming it has hung.

   If the window flashes and closes instantly: that's normal if
   your program finished quickly or hit an error before printing
   anything. To see what happened, open Command Prompt, cd to
   this folder, and run:
     dist\_selftest_stub.exe
   This keeps the window open so you can read any messages.

   A progress indicator that updates in place may appear all at
   once instead of live when run as the .exe -- that is a stdout
   buffering difference between the .exe and the script, not an error.

   Does your program need launch arguments (e.g. --input file.csv)? Run
   this bootstrapper again with them added after the entry file, e.g.
     run_setup.bat "hello_stub.py" --input file.csv
   and they will be forwarded to your program during THIS setup run
   (up to 8 extra arguments). This does not change how a plain
   double-click of dist\_selftest_stub.exe launches it afterward -- for that,
   make a Windows shortcut to the .exe and add the arguments to its
   Target field, or launch it yourself from a Command Prompt.

 KEEP these files with your project:
   requirements.txt  -- packages your app depends on
   runtime.txt       -- Python version pin

 SAFE TO DELETE to reclaim disk space:
   .*_env\ folders   -- environment directories
   ~* files          -- tilde-prefix work files (e.g. ~setup.log)
   build\            -- PyInstaller build cache
============================================================

Tue 07/28/2026  4:56:00.03 [INFO] REQ-016: Post-flight briefing printed.
```

The companion `tests/~selftest_stub/~bootstrap.status.json` reads:

```json
{"state":"ok","exitCode":0,"pyFiles":1}
```

`exitCode` here means "did the bootstrapper's own env/build lifecycle succeed" (a hardcoded `0`
written unconditionally at the success label), NOT the user program's own exit code -- that's
separately surfaced via the console's `[STATUS] Run Status: SUCCESS (Exit Code: 0)` line above.
Both happen to be 0 in this clean run, so the distinction isn't visible here, but it's worth
knowing they're two independent things (see CLAUDE.md's "User-code exit-code semantics" Known
Finding).

---

### Scenario 11: The two elective prompts a real user faces after every successful run

**What's tested:** the framing text of both prompts is confirmed via real CI capture (they're
unconditionally echoed even when CI auto-declines); the actual `[Y/N]` question lines themselves
are never visible in ANY CI log, by construction -- they live inside the branch of an `if/elif`
chain that CI's `HP_CI_LANE` auto-decline always short-circuits past, even in tests that force an
accept via an `HP_TEST_*_ANSWER` override (the override branch assigns the answer variable
directly, bypassing the real `set /p` prompt entirely). Both are therefore genuinely
**`[Extrapolated Branch]`** for the exact prompt-line wording specifically, cited from source, even
though the surrounding framing text is a real capture.

**Source:** framing lines are REAL CI CAPTURE (run `30328748330`, job `90179708091`, "real" lane,
same log as Scenario 10 above); the two `set /p` prompt lines themselves are
`[Extrapolated Branch]`, `run_setup.bat:2847` and `:2923`.

Right after a normal successful verification run (Scenario 10's tail), a real double-click user
sees:

```
*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
  Run again via the interpreter now? [Y/N] █
```
(cursor sits after `[Y/N] `, waiting indefinitely -- `run_setup.bat:2847`,
`:run_postexec_checkpoint`, an UNBOUNDED `set /p`, no timeout of any kind). Any answer other than
a leading `Y`/`y` -- including just pressing Enter -- resolves to decline. If accepted, the entry
program runs a second time via the interpreter (not the packaged EXE) as a diagnostic; if declined,
the bootstrap immediately continues to the second prompt:

```
*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
  Build the optimized version now? [Y/N] █
```
(same shape -- `run_setup.bat:2923`, `:offer_optimized_build`, also an unbounded `set /p`, also
defaults to decline on anything but a leading Y). Both prompts genuinely fire on essentially every
successful default run (the checkpoint is called after every clean verification; the optimized-
build offer only skips if the AV-Safe-Build-Path Tier A Nuitka fallback already ran, or the
verification itself failed) -- **this is not an edge case, it's what most real users see twice in
a row at the very end of an otherwise fully successful first run.**

**CI cannot show either question line, ever, structurally -- not just "doesn't currently show
them."** Both prompts follow this repo's own established CI-safe-gate pattern (see
`docs/agent-interconnect.md`'s "CI-safe interactive gates" section): echo the framing
unconditionally, THEN branch on `HP_TEST_*_ANSWER` override / `HP_CI_LANE` auto-decline / real
`set /p`. Because the actual question text lives inside the `set /p` call itself (not a separate
unconditional `echo`), and CI always takes one of the first two branches, no CI log -- gating or
non-gating, auto-decline or forced-accept -- can ever contain the literal `"  Run again via the
interpreter now? [Y/N] "` or `"  Build the optimized version now? [Y/N] "` text. This is a genuine
blind spot in what CI evidence alone can show about this bootstrapper's real user-facing behavior,
worth keeping in mind when reading any other scenario in this file that involves a `set /p`-based
consent gate.

**For contrast, briefly (full treatment is Pass 4/adversarial-recovery territory, not this
Part):** not every consent gate in this file shares the "blocks forever" shape. The REQ-009
provider-cascade gate (`:cascade_consent_gate`, only reached if a build succeeds but a dependency
repair genuinely fails) is the one gate that's genuinely TIMED for a real user -- `choice /C YN /N
/T 30 /D N`, defaulting to decline after 30 seconds with no answer, so it structurally cannot hang
forever even for a truly unattended user. The REQ-014 system-Python consent gate
(`:system_python_consent_gate`, only reached as the absolute last-resort Tier 4) is unbounded like
the two documented above, but its full question text (unusually, including the actual `[y/n]`
wording) IS an unconditional `echo` rather than living inside `set /p` -- so, unlike this
scenario's two prompts, CI logs genuinely do show the complete question for that one, e.g.
`Proceed with System Python? (Global pollution risk) [y/n]: y to accept, n to decline.` (REAL CI
CAPTURE, same run, job `90179708091`) -- only its own terse follow-up `"Your choice [y/n]: "` line
is hidden the same way. Neither of these two gates fires on this Part's happy path; both are
documented fully in Pass 4.
