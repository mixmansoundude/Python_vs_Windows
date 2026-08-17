# Demo: what the user actually sees

**Status: living demo report, NOT an authoritative or direction-providing document.** This walks
through specific tested scenarios and shows exactly what text lands on the user's screen. Purpose:
let a human review the actual console output, spot anything confusing or alarming, and catch code
paths that report something unexpected. **This doc reflects the LATEST state of the code only --
it is not a history of how things changed.** When a message's wording changes, replace the quote
in place; don't keep the old one around for context. Ongoing investigation notes, dead ends, and
day-to-day refinement-pass checks belong in `docs/agent-scratchlog.md` (internal working notes),
not here. Unresolved design questions belong in `docs/open-questions.md`, not here.

**House style, stated once here rather than repeated per-scenario:** this doc describes CURRENT
behavior, not a changelog of how it got that way. Avoid narrating this document's own revision
history inside scenario prose (phrasing like "not yet re-confirmed against a fresh capture," "the
earlier scan of this scenario quoted only X," or hedging a quote as "the CURRENT shipped wording"
as if some other wording still mattered) -- that's bookkeeping for whoever edits this file next,
not something a reader trying to understand the bootstrapper needs. Likewise, don't cite this
repo's own internal backlog-item numbers or "Active Backlog item N" bookkeeping as part of the
user-facing description; point to `docs/agent-lessons-learned.md` /
`docs/agent-interconnect.md` / `docs/agent-closed-backlog.md` directly instead if a pointer is
genuinely useful. **A real historical GOTCHA is a different thing and stays welcome** -- a bug that
shaped current behavior, worth knowing so a reader doesn't rediscover it the hard way, is exactly
the kind of content this doc wants (see Scenario 29, Scenario 39 for two kept in full). The
distinction is between explaining what the reader is looking at right now versus narrating how
this document itself was assembled. When a mechanism is genuinely covered by README.md or
`run_setup.bat`'s own source/comments, cite those first -- they're the product-facing docs a reader
of this file is more likely to already be looking at; reach for the internal `docs/agent-*.md`
engineering docs only for detail that has no README/source equivalent (implementation-level
CMD/PowerShell quirks, cross-component interconnects, and similar maintainer-facing reasoning).

**House rule -- minimum context per scenario:** every scenario (each numbered "Scenario N" or
equivalent standalone walkthrough entry) shows at least 5 distinct user-visible-output quotes
(lines drawn from the actual bootstrapper console/log output shown in the fenced blocks below it),
not counting input/output *file* contents (`.py`, `.toml`, `requirements.txt`, etc.) or raw
NDJSON/status-file dumps shown only as supporting evidence. A scenario this thin on real quotes
usually means not enough was captured to give a reader real context -- add more before considering
it done, even if the mechanism itself is fully explained in prose.

**House rule -- no internal-only text in a user-visible quote:** a fenced block presented as "what
the user sees" must never contain something a real end user, double-clicking `run_setup.bat` with
no environment variables set, would not actually see on their own screen -- this includes literal
`[TEST]` tags, `HP_TEST_FORCE_*`/other env-var names, "simulating"/"for this test" phrasing, or any
other CI-test-harness-only artifact. When a real capture's own trigger was a test hook, say so in
the surrounding PROSE (never inside the quoted block itself), and either omit the corresponding
line entirely (if the real mechanism is silent at that point) or replace it with the genuine
real-user-equivalent line, extrapolated from `run_setup.bat`'s own source and clearly labeled
`[Extrapolated Branch]` if it isn't independently confirmed by a different real capture.

**Sourcing convention:** every quoted block carries one explicit provenance label -- REAL CI
CAPTURE (copied verbatim from a real GitHub Actions job log, cited with run ID, job ID, lane, and
test file), a source excerpt (taken directly from `run_setup.bat`'s current source because no CI
run has exercised that exact wording yet), or, for the composite walkthroughs in Part VII,
`[Extrapolated Branch]` (assembled by splicing several independently-real fragments together, each
already cited in its own originating scenario). A source excerpt or a composite splice is never
described as a job log or presented as a single real capture.

**Scope:** grouped by feature area, ordered roughly the way a real user would actually encounter
each area -- the default happy path and its immediate variations first, narrower and more advanced
topics last -- rather than the order each was originally reviewed. Nine Parts total; see the table
of contents for the full current list. Extend with a new Part as new feature areas get reviewed,
rather than growing any existing Part indefinitely.

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

- [Part I: Default double-click happy path (uv-first, fresh machine, zero flags)](#part-i-default-double-click-happy-path-uv-first-fresh-machine-zero-flags)
  - [Scenario 1: No `.py` files at all -- the graceful `no_python_files` exit](#scenario-1-no-py-files-at-all----the-graceful-no_python_files-exit)
  - [Scenario 2: Pre-flight guards, lock acquisition, and entry detection on a clean run](#scenario-2-pre-flight-guards-lock-acquisition-and-entry-detection-on-a-clean-run)
  - [Scenario 3: Provider acquisition and dependency install (uv-first)](#scenario-3-provider-acquisition-and-dependency-install-uv-first)
  - [Scenario 4: Build, verify, and the final status panel](#scenario-4-build-verify-and-the-final-status-panel)
  - [Scenario 5: The two elective prompts a real user faces after every successful run](#scenario-5-the-two-elective-prompts-a-real-user-faces-after-every-successful-run)
- [Part II: Second run, nothing changed (repeat-run fast paths)](#part-ii-second-run-nothing-changed-repeat-run-fast-paths)
  - [Scenario 6: The EXE fast path (nothing changed at all)](#scenario-6-the-exe-fast-path-nothing-changed-at-all)
  - [Scenario 7: Source touched just enough to force a rebuild, but the environment is reused](#scenario-7-source-touched-just-enough-to-force-a-rebuild-but-the-environment-is-reused)
- [Part III: User configuration and CLI overrides](#part-iii-user-configuration-and-cli-overrides)
  - [Scenario 8: `PVW_PYTHON_EXE` / `PVW_UV_EXE` / `PVW_TARGET_PY` / `PVW_WORKSPACE`](#scenario-8-pvw_python_exe--pvw_uv_exe--pvw_target_py--pvw_workspace)
  - [Scenario 9: `PVW_CONDA_EXE` and its interaction with the conda self-heal flow](#scenario-9-pvw_conda_exe-and-its-interaction-with-the-conda-self-heal-flow)
  - [Scenario 10: Drag-and-drop / CLI entry-file override (REQ-011 same-directory rule + REQ-002 priority)](#scenario-10-drag-and-drop--cli-entry-file-override-req-011-same-directory-rule--req-002-priority)
- [Part IV: Adversarial and recovery branches](#part-iv-adversarial-and-recovery-branches)
  - [Scenario 11: Network connectivity check and transient-retry (REQ-013 + REQ-022)](#scenario-11-network-connectivity-check-and-transient-retry-req-013--req-022)
  - [Scenario 12: Corrupted-conda self-heal (detect / decline / accept)](#scenario-12-corrupted-conda-self-heal-detect--decline--accept)
  - [Scenario 13: Miniconda install chain (AllUsers -> JustMe -> both-failed)](#scenario-13-miniconda-install-chain-allusers---justme---both-failed)
  - [Scenario 14: Standalone embed-tier download (REQ-009 Tier 5) -- decline and real success](#scenario-14-standalone-embed-tier-download-req-009-tier-5----decline-and-real-success)
  - [Scenario 15: REQ-009 provider cascade -- one real run showing the FULL chain](#scenario-15-req-009-provider-cascade----one-real-run-showing-the-full-chain)
  - [Scenario 16: `--hidden-import` auto-recovery (success and exhaustion)](#scenario-16---hidden-import-auto-recovery-success-and-exhaustion)
  - [Scenario 17: Warnfix repair loop (success, and the failure that feeds the cascade)](#scenario-17-warnfix-repair-loop-success-and-the-failure-that-feeds-the-cascade)
  - [Scenario 18: Pre-flight guards actually firing](#scenario-18-pre-flight-guards-actually-firing)
  - [Scenario 19: Concurrent-instance lock contention (REQ-024)](#scenario-19-concurrent-instance-lock-contention-req-024)
- [Part V: Remaining branches (dependency source precedence, write-back, and misc)](#part-v-remaining-branches-dependency-source-precedence-write-back-and-misc)
  - [Scenario 20: Git config merge (`.gitignore`/`.gitattributes`, REQ-015)](#scenario-20-git-config-merge-gitignoregitattributes-req-015)
  - [Scenario 21: Python-version precedence (REQ-004) and dependency-source precedence (`pyproject.toml`)](#scenario-21-python-version-precedence-req-004-and-dependency-source-precedence-pyprojecttoml)
  - [Scenario 22: PEP 723 dependency write-back (REQ-005.11) -- the fresh-install trigger](#scenario-22-pep-723-dependency-write-back-req-00511----the-fresh-install-trigger)
  - [Scenario 23: `HP_PVW_KNOWN_IDEMPOTENT` execute-mode discovery (REQ-005.13)](#scenario-23-hp_pvw_known_idempotent-execute-mode-discovery-req-00513)
  - [Scenario 24: NI-VISA detection and install outcome (REQ-008)](#scenario-24-ni-visa-detection-and-install-outcome-req-008)
  - [Scenario 25: pandas/openpyxl heuristic dependency augmentation (REQ-005.8)](#scenario-25-pandasopenpyxl-heuristic-dependency-augmentation-req-0058)
  - [Scenario 26: Conda base periodic update](#scenario-26-conda-base-periodic-update)
  - [Scenario 27: REQ-014 system-Python consent -- ACCEPT](#scenario-27-req-014-system-python-consent----accept)
- [Part VI: Additional branches found in a full-file sweep](#part-vi-additional-branches-found-in-a-full-file-sweep)
  - [Scenario 28: Interactive entry picker -- multiple `.py` files, no clear winner (REQ-002)](#scenario-28-interactive-entry-picker----multiple-py-files-no-clear-winner-req-002)
  - [Scenario 29: Pre-flight syntax-error rejection (REQ-021), and a real bug it exposed](#scenario-29-pre-flight-syntax-error-rejection-req-021-and-a-real-bug-it-exposed)
  - [Scenario 30: REQ-007 system-Python build consent, and the resulting no-EXE interpreter path](#scenario-30-req-007-system-python-build-consent-and-the-resulting-no-exe-interpreter-path)
  - [Scenario 31: EXE smoke-run diagnostic hints (companion to Scenario 16)](#scenario-31-exe-smoke-run-diagnostic-hints-companion-to-scenario-16)
- [Part VII: Full startup-to-shutdown walkthroughs](#part-vii-full-startup-to-shutdown-walkthroughs)
  - [Scenario 32: Full walkthrough -- the ordinary happy path, start to shutdown](#scenario-32-full-walkthrough----the-ordinary-happy-path-start-to-shutdown)
  - [Scenario 33: Full walkthrough -- uv can't resolve a dependency, cascades to conda, which does](#scenario-33-full-walkthrough----uv-cant-resolve-a-dependency-cascades-to-conda-which-does)
  - [Scenario 34: Full walkthrough -- warnfix repair and rebuild, start to finish](#scenario-34-full-walkthrough----warnfix-repair-and-rebuild-start-to-finish)
  - [Scenario 35: Full walkthrough -- `--hidden-import` auto-recovery succeeds on the first rebuild](#scenario-35-full-walkthrough------hidden-import-auto-recovery-succeeds-on-the-first-rebuild)
  - [Scenario 36: Full walkthrough -- `HP_PVW_KNOWN_IDEMPOTENT`, with the actual input and output files](#scenario-36-full-walkthrough----hp_pvw_known_idempotent-with-the-actual-input-and-output-files)
- [Part VIII: AV-Safe Build Path (Nuitka fallback)](#part-viii-av-safe-build-path-nuitka-fallback)
  - [Scenario 37: PyInstaller build fails, Tier A (Nuitka) fallback succeeds](#scenario-37-pyinstaller-build-fails-tier-a-nuitka-fallback-succeeds)
  - [Scenario 38: PyInstaller build fails, Tier A fallback ALSO fails (tier exhaustion)](#scenario-38-pyinstaller-build-fails-tier-a-fallback-also-fails-tier-exhaustion)
    - [38a. `execfail` -- the PyInstaller build command itself fails](#38a-execfail----the-pyinstaller-build-command-itself-fails)
    - [38b. `output_vanish` -- PyInstaller succeeds, then the EXE disappears immediately](#38b-output_vanish----pyinstaller-succeeds-then-the-exe-disappears-immediately)
  - [Scenario 39: Tier A + hidden-import auto-recovery skip guard](#scenario-39-tier-a--hidden-import-auto-recovery-skip-guard)
  - [Scenario 40: Requirement 9 -- elective "want an optimized build too?" offer](#scenario-40-requirement-9----elective-want-an-optimized-build-too-offer)
    - [40a. `accept` -- a real optimized build succeeds and is swapped in](#40a-accept----a-real-optimized-build-succeeds-and-is-swapped-in)
    - [40b. `forcefail` -- accepted, but the build fails; original EXE is left untouched](#40b-forcefail----accepted-but-the-build-fails-original-exe-is-left-untouched)
    - [40c. `swapfail` -- verified build, but the final swap step fails; original EXE is left untouched](#40c-swapfail----verified-build-but-the-final-swap-step-fails-original-exe-is-left-untouched)
    - [40d. `decline` -- default/CI path, prompt shown but nothing built](#40d-decline----defaultci-path-prompt-shown-but-nothing-built)
    - [Reactive-only failure hint (both Tier A and requirement 9's real-build-failure paths)](#reactive-only-failure-hint-both-tier-a-and-requirement-9s-real-build-failure-paths)
- [Part IX: CLI interactivity, argv passthrough & honest messaging](#part-ix-cli-interactivity-argv-passthrough--honest-messaging)
  - [Scenario 41: Interactive verification -- live-tee, activity-aware kill, and the quit-prompt hint](#scenario-41-interactive-verification----live-tee-activity-aware-kill-and-the-quit-prompt-hint)
  - [Scenario 42: Argv passthrough (REQ-026) -- launch arguments through the bootstrapper](#scenario-42-argv-passthrough-req-026----launch-arguments-through-the-bootstrapper)
  - [Scenario 43: Honest ambiguous-exit messaging (REQ-027)](#scenario-43-honest-ambiguous-exit-messaging-req-027)
    - [43a. No-EXE path, interpreter also failed](#43a-no-exe-path-interpreter-also-failed)
    - [43b. Cached-EXE fast path, kept despite a non-zero exit](#43b-cached-exe-fast-path-kept-despite-a-non-zero-exit)
- [Part X: Confirmed layered multi-mechanism recovery chain (real E2E evidence)](#part-x-confirmed-layered-multi-mechanism-recovery-chain-real-e2e-evidence)
  - [Scenario 44: Full walkthrough -- cascade, warnfix, hidden-import recovery, and native-DLL bundling, all in one real run](#scenario-44-full-walkthrough----cascade-warnfix-hidden-import-recovery-and-native-dll-bundling-all-in-one-real-run)

---

## Part I: Default double-click happy path (uv-first, fresh machine, zero flags)

**Scope note:** this Part opens the document with what a completely ordinary run looks like end to
end -- one `.py` file, no test hooks, no prior state, no flags, uv reachable (the REQ-009 default,
`uv -> conda -> embed -> venv -> system`). This is what the large majority of real users actually
see; narrower/advanced feature areas (the AV-Safe Build Path's Nuitka fallback, CLI-interactivity
internals) are covered later, in Part VIII and Part IX. Evidence is pulled from a recent fully-green
run (`30328748330`, commit `5872028`, all lanes
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

### Scenario 1: No `.py` files at all -- the graceful `no_python_files` exit

**What's tested:** `self.empty_repo.msg` (`tests/selftest.ps1`, `real` lane, real, passing).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

Referenced throughout this document (e.g. Scenario 3's note that this repo's own bootstrapper
root, which has no loose `.py` files, exercises this exact path) but never shown directly: when
`PYCOUNT` (a plain `dir /b /a-d *.py` count) is zero, the bootstrapper takes the shortest path in
the entire file -- no provider selection, no dependency install, nothing network-touching at all,
skipping straight to a graceful, successful exit:

```
[INFO] Environment name: _selftest_empty
[INFO] Host OS: Microsoft Windows [Version 10.0.26100.32995]
[INFO] Host PowerShell: 5.1.26100.32995
[INFO] Python file count: 0
Python file count: 0
No Python files detected; skipping environment bootstrap.
[INFO] No Python files detected; skipping environment bootstrap.
```

(the last message genuinely appears twice, back to back, in the real captured log -- once as a
plain `echo` straight to console with no timestamp, once through `:log`'s own timestamped form
written to both console and `~setup.log`; the block above shows both, with the second line's
real timestamp prefix, e.g. `Tue 07/28/2026  4:29:15.97`, omitted here since it carries no
information beyond confirming the two lines are adjacent). `~bootstrap.status.json` reads
`{"state":"no_python_files","exitCode":0,
"pyFiles":0}` -- a real user who double-clicks the bootstrapper in an empty folder, or in the
wrong folder entirely, gets a clear, immediate, non-alarming message rather than the bootstrapper
attempting (and inevitably failing) to build an environment for nothing.

### Scenario 2: Pre-flight guards, lock acquisition, and entry detection on a clean run

**What's tested:** no single dedicated test asserts the CLEAN (non-firing) pass of these checks --
`docs/agent-ndjson.md` only registers rows for the *firing* branches (`self.warn.onedrive`,
`self.warn.longpath`, `self.warn.sysdir`, `self.stub.lock_held_decline`, etc.). The evidence below
is the incidental byproduct of `tests/selfapps_envsmoke.ps1`'s full, real bootstrap, which captures
every byte of console output via `cmd /c .\run_setup.bat > '~envsmoke_bootstrap.log'`.

**Source:** REAL CI CAPTURE, run `30328748330`, `tests/~envsmoke/~envsmoke_bootstrap.log`
(published diagnostics site), identical across all 6 lanes checked (`real`, `uv`, `conda-full`,
`justme-test`, `contract-uv`, `contract-uv-fail`):

```
Tue 07/28/2026  4:29:43.96 [INFO] REQ-015: Appending standard ignores to .gitignore.
Tue 07/28/2026  4:29:43.97 [INFO] REQ-015: Appending standard attributes to .gitattributes.
```

Before that first line, nothing prints -- `HP_APP_ARGS` capture (REQ-026, pure variable
assignment), the workspace-path-exists check, `cd /d`, `HP_SCRIPT_ROOT` construction, and the
top-of-file UNC-path check (`if "%HP_SCRIPT_LAUNCH_DIR:~0,2%"=="\\"`, which prints a much louder
`*** WARNING: UNC/network paths detected...` banner when it genuinely fires) are all silent on an
ordinary, non-UNC path. Both `.gitignore`/`.gitattributes` lines come from the same
`:merge_git_config` call (the first output-producing call after `run_setup.bat` sets up its own
log file) -- on a fresh scratch directory neither file yet has the bootstrapper's signature
comment, so both append branches fire back to back.

Immediately after that, the same real capture shows the environment-name and host-diagnostics
lines every run prints (same run, same underlying artifact -- also quoted in Scenario 6 below,
where the exact values are unchanged since they describe the same CI host, not anything specific
to a fresh vs. repeat run):

```
[INFO] Environment name: _envsmoke
[INFO] Host OS: Microsoft Windows [Version 10.0.26100.32995]
[INFO] Host PowerShell: 5.1.26100.32995
```

**The four REQ-025-family pre-flight guards (path-length, OneDrive, system-directory, disk-space --
also part of that unlabeled prologue) are completely silent unless they fire.** Confirmed by both
the absence of any related text anywhere in the captured log, AND by reading the source: none of
the four has an `else` branch that prints a success/clean message -- each is a bare `if (...) (
echo/log ... )` with nothing on the false path. A real user on an ordinary setup (short path, not
under OneDrive, not under `Windows`/`Program Files`, plenty of free disk) sees zero output from
any of these four checks.

**`:acquire_lock` is equally silent on an uncontended acquire.** The `mkdir "%HP_LOCK_DIR%"` call
succeeds immediately (no prior lock directory), jumps straight to `:lock_acquired`, writes a
transient `~bootstrap.lock\owner.txt` marker (a file, not console output), and returns -- every
`echo`/`:log` call inside `:acquire_lock` lives inside the "another instance is already running"
branch, only reached on a genuine `mkdir` failure. The lock directory (and its `owner.txt`) is
gone again by the time the run completes (`:release_lock`, called from both `:die` and `:success`,
is equally silent).

**Entry detection for the common single-`.py`-file case** (`:determine_entry` ->
`tools/find_entry.py` -> `:record_chosen_entry`) produces exactly one line, sourced from
`tests/~envsmoke/~setup.log` (same run, the real, non-`HP_CI_SKIP_ENV` `:determine_entry` call
site inside `:after_env_bootstrap` -- not the separate `HP_CI_SKIP_ENV`-only `:ci_skip_entry`
implementation that
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
bootstrap (once early, for PEP 723/autopep723 discovery purposes, well before `:after_env_bootstrap`,
and once again at the real entry-selection call site inside `:after_env_bootstrap` that produces
this console line) -- only the second call's result is what a user sees echoed.

---

### Scenario 3: Provider acquisition and dependency install (uv-first)

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
"Self-test: real env smoke (CI-only)" step's own inner sub-bootstrap, which runs `run_setup.bat`
for real against a scratch app directory instead.

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
populated, the cached-binary branch just before `:uv_acquire_download` instead logs `[INFO] uv:
cached binary found at ~uv_bin\uv.exe` -- not independently captured here since every CI scratch
dir is fresh; see this doc's repeat-run scenarios, added in a later pass, for the dedicated
treatment.)

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
`python==3.11` templates to `...with Python 3.11...` per the `HP_UV_PY_DISP` derivation just
above `:uv_venv_ready` (not independently captured, but the template is a literal source string,
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

The "pipreqs (direct) command:" line is a DISPLAY-ONLY string (`HP_PIPREQS_CMD_LOG`, built for
human readability as the CLI-equivalent form) -- the actual invocation, per this repo's own
"never depend on console scripts during bootstrap" rule, is
`"%HP_PY%" -m pipreqs.pipreqs . --force --mode compat --savepath ... --ignore ...`, never the
bare `pipreqs` command shown on screen.

**Not shown above because it doesn't apply to this run, not omitted:** since this app had no
pre-existing `requirements.txt` (`docs/agent-closed-backlog.md`'s Item 21), `requirements.txt`
was freshly copied from `requirements.auto.txt` a few lines earlier in `:after_pipreqs_run`, so the
`fc` diff genuinely finds no differences and stays file-only. When a user's own pre-existing
`requirements.txt` DOES differ from what pipreqs auto-detects, the diff is now also printed to the
console right after the line above:

```
[INFO] requirements.txt differs from the auto-detected dependency scan; details below:
***** requirements.txt
requests==2.31.0
***** requirements.auto.txt
requests==2.31.0
colorama==0.4.6
*****
```

(`[Extrapolated Branch]` -- `fc`'s own output format, not independently captured; genuine content
depends entirely on the two files' real contents).

**A real quirk worth flagging so it isn't misread**: the bootstrap log around this point also shows
`DEP_FINAL_COUNT=0` even though `colorama` is a genuine, real dependency that gets installed a few
steps later -- this count is taken BEFORE `requirements.auto.txt` is copied into `requirements.txt`
a few lines further down, still inside `:after_pipreqs_run`'s own tail, so `DEP_FINAL_COUNT=0`
here does not mean "pipreqs found nothing"; it's a pre-existing ordering quirk in the log sequence, not a bug in this
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
is installed via `uv pip install --python "%HP_PY%"` into the SAME venv as the target app (inside
the pipreqs install step, before `:pipreqs_direct_done`), not an isolated tool venv. This is
genuine, expected production behavior
-- a real user's `.uv_env` always ends up with pipreqs's own dependency footprint mixed in
alongside their actual dependencies, not a CI artifact.

---

### Scenario 4: Build, verify, and the final status panel

**What's tested:** `self.stub.fastpath` (`tests/selftest.ps1`, real lane), a genuine first-run
(non-cached) build of a trivial one-line stub app (`hello_stub.py` = `print("hello-from-stub")`).
Chosen over Scenario 3's `colorama`-importing app for this piece specifically because it produces
a single, fully self-consistent, real capture spanning build through the final status panel with
no lines needing a source-level touch-up -- unlike the similar block quoted in Scenario 37
(Part VIII), where two lines had to be patched to current wording.

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
`tools/exe_smokerun.ps1`'s chunk-based `ReadAsync` reader (see Scenario 41's fuller writeup of that
mechanism) -- landing exactly between the PID line and the "exited 0" line, precisely where a real
user's own program output appears. The `[INFO] Process ID <n>. If it seems stuck: Task Manager >
Details tab...` line is the already-shipped stuck-program recovery aid (`tools/exe_smokerun.ps1`,
see `docs/agent-interconnect.md`'s "Process-ID display for stuck-program recovery" section) --
confirmed here as a genuine, working console line, not just source text.

Immediately following (elective prompts, both auto-declined by CI -- see Scenario 5 below for
what a real user experiences here instead) and then the final panel -- with the "You can also run
it directly via the interpreter" line and its path updated in place to reflect current source
(this real capture predates the postflight briefing always showing that line; every other line
below is unmodified real capture):

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
   You can also run it directly via the interpreter at any time:
     ".uv_env\Scripts\python.exe" "hello_stub.py"

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

### Scenario 5: The two elective prompts a real user faces after every successful run

**What's tested:** the framing text of both prompts is confirmed via real CI capture (they're
unconditionally echoed even when CI auto-declines); the actual `[Y/N]` question lines themselves
are never visible in ANY CI log, by construction -- they live inside the branch of an `if/elif`
chain that CI's `HP_CI_LANE` auto-decline always short-circuits past, even in tests that force an
accept via an `HP_TEST_*_ANSWER` override (the override branch assigns the answer variable
directly, bypassing the real `set /p` prompt entirely). Both are therefore genuinely
**`[Extrapolated Branch]`** for the exact prompt-line wording specifically, cited from source, even
though the surrounding framing text is a real capture.

**Source:** framing lines are REAL CI CAPTURE (run `30328748330`, job `90179708091`, "real" lane,
same log as Scenario 4 above); the two `set /p` prompt lines themselves are
`[Extrapolated Branch]`, cited from `:run_postexec_checkpoint` and `:offer_optimized_build`
respectively.

**Relationship to README.md's `[REQ-018]` spec, since the two don't map 1:1 in an obvious way:**
`:run_postexec_checkpoint`'s own log line is explicitly tagged `REQ-018` in source (`[INFO]
REQ-018: post-execution checkpoint (...): accepted/declined...`), so it -- not a separate,
undocumented prompt -- is the shipped implementation of README's "After a build, the real run is
offered, not forced" / "Consent before any extra run" bullets. Two nuances worth flagging
explicitly rather than leaving implicit: (1) the offered rerun uses the INTERPRETER, not a second
launch of the packaged EXE -- README's "offers to launch the app untimed for real" phrasing reads
as if it means the EXE specifically, but the actual accepted-path log line says "running a second
time via the interpreter", and a companion note the same subroutine prints for the EXE call site
spells this out too ("this diagnostic run uses the interpreter, not the packaged EXE, so behavior
can differ"); (2) README's separate REQ-018 bullet about the FIRST (mandatory) verification run
being "force-stopped after a short interval even if running fine" is stale relative to the
activity-aware-kill behavior actually shipped later (see Scenario 41's fuller writeup and CLAUDE.md's
Closed Backlog "Activity-aware EXE-smoke kill" entry) -- the real WARN text quoted in Scenario 4
above says the opposite: any output at all, not just a clean exit, keeps the run alive indefinitely,
only a genuinely SILENT process gets force-stopped. Neither nuance changes what actually ships;
both are flagged here because a reader cross-checking this scenario against README's prose could
otherwise reasonably conclude something was missed.

Right after a normal successful verification run (Scenario 4's tail), a real double-click user
sees:

```
*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
  Run again via the interpreter now? [Y/N] _
```

(cursor sits after `[Y/N] `, waiting indefinitely -- `:run_postexec_checkpoint`, an UNBOUNDED
`set /p`, no timeout of any kind). Any answer other than a leading `Y`/`y` -- including just
pressing Enter -- resolves to decline. If accepted, the entry program runs a second time via the
interpreter (not the packaged EXE) as a diagnostic; if declined, the bootstrap immediately
continues to the second prompt:

```
*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
  Build the optimized version now? [Y/N] _
```

(same shape -- `:offer_optimized_build`, also an unbounded `set /p`, also defaults to decline on
anything but a leading Y). Both prompts genuinely fire on essentially every
successful default run (the checkpoint is called after every clean verification; the optimized-
build offer only skips if the AV-Safe-Build-Path Tier A Nuitka fallback already ran, or the
verification itself failed) -- **this is not an edge case, it's what most real users see twice in
a row at the very end of an otherwise fully successful first run.**

**CI cannot show either question line, ever, structurally -- not just "doesn't currently show
them."** Both prompts follow this repo's own established CI-safe-gate pattern (see
`docs/agent-interconnect.md`'s "CI-safe interactive gates" section): echo the framing
unconditionally, THEN branch on `HP_TEST_*_ANSWER` override / `HP_CI_LANE` auto-decline / real
`set /p`. Because the actual question text lives inside the `set /p` call itself (not a separate
unconditional `echo`), and CI always takes one of the first two branches, no CI log -- auto-decline
or forced-accept -- can ever contain the literal `"  Run again via the
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

---

## Part II: Second run, nothing changed (repeat-run fast paths)

**Scope note:** this Part documents the success side of running the bootstrapper a SECOND time in
the same folder with nothing changed -- same entry file, same requirements, no test flags. The
FAILURE side of one of these fast paths (a stale cached EXE that's kept and later exits non-zero)
is already documented as Scenario 43b (Part IX); this Part doesn't repeat that. Evidence again
comes from a recent clean green run (`30328748330`, commit `5872028`) rather than one single
dedicated "repeat run" test file -- `tests/selfapps_envsmoke.ps1` re-invokes `run_setup.bat` a
second time in the same scratch directory with nothing changed (the EXE fast path), and
`tests/selftest.ps1`'s stub scenario and `tests/selfapps_depcheck.ps1` go one step further --
`Run 1` (fresh bootstrap), `Run 2` (identical, EXE fast path), then deliberately touch the source
file and run a THIRD time -- exercising the "source changed just enough to force a rebuild, but
the environment itself doesn't need recreating" fast paths this Part's second scenario covers.

### Scenario 6: The EXE fast path (nothing changed at all)

**What's tested:** `self.fastpath` (`tests/selfapps_envsmoke.ps1`'s second, back-to-back
invocation of `run_setup.bat` in the same scratch directory, zero CLI arguments, nothing touched).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` ("real" lane), the console
capture of that second invocation (`~envsmoke_fastpath.log`) plus the matching block of
`~setup.log`.

**What fires FIRST, before any provider/entry/dependency logic even starts:** `:try_fast_exe` is
called immediately after environment-name derivation and the Python-file count, right at the top
of the file -- before uv acquisition, before Miniconda, before `:determine_entry`, before
anything else. It runs exactly ONE real check: compare `dist\<env>.exe`'s modification time
against the newest non-infrastructure `.py` file's modification time (via the embedded
`HP_FAST_CHECK` helper). If the EXE is newer-or-equal, the whole rest of the bootstrap short-
circuits straight to `:success`.

**Non-interactive console text (what CI captures -- this is also exactly what a real user would
see if they ran the bootstrapper non-interactively, e.g. from a script):**

```
Tue 07/28/2026  4:30:33.81 [INFO] Environment name: _envsmoke
Tue 07/28/2026  4:30:33.83 [INFO] Host OS: Microsoft Windows [Version 10.0.26100.32995]
Tue 07/28/2026  4:30:34.04 [INFO] Host PowerShell: 5.1.26100.32995
Tue 07/28/2026  4:30:34.10 [INFO] Python file count: 1
Tue 07/28/2026  4:30:34.98 [INFO] Fast path: reusing dist\_envsmoke.exe
Tue 07/28/2026  4:30:35.96 [INFO] Entry smoke exit=0
Tue 07/28/2026  4:30:35.97 [STATUS] Run Status: SUCCESS (Exit Code: 0)
Tue 07/28/2026  4:30:35.99 [INFO] Fast path: skipping PyInstaller rebuild for existing dist\_envsmoke.exe
```

No "SETUP COMPLETE" postflight banner appears -- confirmed both structurally (that dispatch is
gated on the fast path NOT having fired) and in the raw capture, which ends right after the last
line above. `~setup.log` shows one extra line between "Fast path: reusing" and "Entry smoke
exit=0" that never reaches the console (`Fast path command: "dist\_envsmoke.exe" > "~run.out.txt"
2> "~run.err.txt"`) -- a raw log-file-only write, not part of what a user actually sees.

**Interactive console text (what a genuine double-click end user sees -- differs from CI because
`HP_CI_LANE` is unset, so `:try_fast_exe` takes its OTHER branch, `:try_fast_exe_probe`, which
launches the cached EXE through the same never-kills fail-fast probe mechanism Scenario 41
documents rather than the plain redirect above).** Assembled from real, independently-confirmed
fragments (the header and PID lines are genuine captured text from a different test that forces
this same interactive branch; their pairing into a clean, fast, successful sequence is
`[Extrapolated Branch]`, grounded directly in source rather than guessed):

```
Tue 07/28/2026  4:30:33.81 [INFO] Environment name: _envsmoke
Tue 07/28/2026  4:30:33.83 [INFO] Host OS: Microsoft Windows [Version 10.0.26100.32995]
Tue 07/28/2026  4:30:34.04 [INFO] Host PowerShell: 5.1.26100.32995
Tue 07/28/2026  4:30:34.10 [INFO] Python file count: 1
Tue 07/28/2026  4:30:34.98 [INFO] Launching your program now via the cached standalone EXE (PyInstaller build): dist\_envsmoke.exe
[INFO] Process ID 7692. If it seems stuck: Task Manager > Details tab > find this PID > End Task (this window stays open).
                                                          <- the app's own live stdout/stderr tees here, if any
Tue 07/28/2026  4:30:35.96 [INFO] Entry smoke exit=0
Tue 07/28/2026  4:30:35.97 [STATUS] Run Status: SUCCESS (Exit Code: 0)
Tue 07/28/2026  4:30:35.99 [INFO] Fast path: skipping PyInstaller rebuild for existing dist\_envsmoke.exe
Press any key to continue . . .
```

The "still running after Nms, keep waiting?" WARN line that the fail-fast probe can print is
conditional on the process actually exceeding its short classification window (confirmed absent
here via real CI capture of the same forced-interactive mechanism failing fast in an unrelated
scenario) -- omitted above since "nothing changed, app still runs fine" implies a normal-speed
exit. `Press any key to continue . . .` is `cmd.exe`'s own native output from a `pause` at the
very end of the main line, gated on `HP_CI_LANE` being unset -- real end-user only, never appears
in any CI log.

**Why it's fast -- everything this run skips entirely, not just runs faster:** once `:try_fast_exe`
succeeds, the bootstrap jumps to `:success` before any of the following ever execute: the
`HP_CI_SKIP_ENV` dispatch, the entire uv acquisition block (no download, no `uv venv`, no
`UV_PYTHON_PREFERENCE` even gets set), `:select_conda_bat` and all Miniconda install/probe logic,
the env-state fast path (moot -- conda was never considered), `:conda_base_update`, the
`HP_PREP_REQUIREMENTS` heuristic dependency augmentation, `:determine_entry` (the cached EXE's
identity is trusted as-is, no REQ-002 re-selection), pipreqs entirely (no `pipreqs.install`/
`pipreqs.run`, no `requirements.auto.txt` diff), and -- the single biggest reason this is fast --
`:run_entry_smoke` never runs, meaning no `py_compile` preflight and no PyInstaller build
invocation of any kind, cached or otherwise. The reused EXE genuinely gets EXECUTED, not merely
detected -- confirmed by the real `Entry smoke exit=0`/`[STATUS]` lines above, which come from an
actual process launch.

---

### Scenario 7: Source touched just enough to force a rebuild, but the environment is reused

**What's tested:** `tests/selftest.ps1`'s stub scenario and `tests/selfapps_depcheck.ps1`, both of
which do Run 1 (fresh) -> Run 2 (Scenario 6's EXE fast path) -> touch the entry file's content
and modification time -> Run 3, which is the case documented here: the EXE fast-path timestamp
check now fails (source is newer than the cached EXE), so PyInstaller reruns and produces a new
EXE -- but the ENVIRONMENT itself (the uv venv or conda env, and already-satisfied dependencies)
is recognized as still valid and reused rather than recreated from scratch.

**Source:** REAL CI CAPTURE, run `30328748330`, jobs `90179708091` ("real" lane, uv-first) and
`90179708094` ("conda-full" lane).

**uv-first lane** (`.uv_env\Scripts\python.exe` already exists and its `import pip` canary
succeeds, so venv creation is skipped -- the gate just above `:uv_venv_ready`):

```
[INFO] uv: reusing existing .uv_env
[INFO] HP_ENV_MODE=uv
[BOOT] REQ-009: Selected Python provider: UV.
```

**conda-full lane** (`~env.state.json` is valid and the conda env's `python.exe` is present --
`:env_state_fast_path`; this mechanism is explicitly bypassed in uv mode, since it exists purely
for the conda-specific case):

```
[INFO] Env-state fast path: reusing conda env _selftest_stub.
[BOOT] REQ-009: Selected Python provider: Conda (Portable) [fast path].
```

Confirmed firing across every scratch env in that job's log (not a one-off), so this is a broadly
reliable fast path, not a narrow coincidence. `self.stub.state_skip`'s own NDJSON assertion checks
for EITHER phrase, which is why one shared test scenario validates both depending on which lane
it runs under.

**Both lanes then converge on the same dependency-install skip, immediately after dependency
discovery** (pipreqs + the Tier 1 autopep723 merge from Scenario 3 still run normally here --
neither of the two fast paths above touches dependency DISCOVERY, only environment creation):

```
[INFO] Dep-check: all pipreqs packages satisfied in lock; skipping conda install.
```

This message literally says "skipping conda install" even in uv mode -- confirmed intentional
(a shared log line covering both providers via the same `HP_DEP_SKIP` flag), not a copy-paste
bug, so don't read it as evidence the wrong provider was used. **One nuance worth flagging so it
isn't misread as a second, real install still happening:** in conda mode specifically, an
unconditional "pip gap fill from `requirements.txt`" step still runs immediately after this skip
line, even though nothing was found missing -- it's a fast, harmless no-op safety net (confirmed
completing in well under a second in the real capture), not evidence the skip failed to take
effect.

**Net effect for the user:** a rebuild triggered by an ordinary source edit is meaningfully faster
than the very first run -- no fresh uv/conda acquisition, no fresh venv/env creation, and (when
nothing about the dependency set changed) no re-running of the actual install step -- while still
producing a genuinely fresh PyInstaller build and a real verification run of the new EXE.

---

## Part III: User configuration and CLI overrides

**Scope note:** argv passthrough (extra launch arguments forwarded to the user's program, REQ-026)
is already fully covered as Scenario 42 -- cross-reference it rather than re-documenting it here.
This Part covers the remaining configuration surface: the five `PVW_*` super-user override
environment variables (distinct from `HP_TEST_*`, which are CI-only and out of scope for this
doc), and the CLI-argument/drag-and-drop entry-file override.

**All five `PVW_*` variables share one generic acknowledgment line**, printed the instant the
variable is defined, before any real detection/acquisition work runs and regardless of whether the
value ever turns out to be usable:

```
[DEBUG] Using super-user override for PVW_<NAME>: <value>
```

**A real nuance worth stating up front rather than repeating per-variable:** the source's own
header comment describes all five uniformly as bypassing auto-detection, but that's only literally
true for two of them. `PVW_UV_EXE` and `PVW_WORKSPACE` genuinely skip the corresponding
detection/creation branch outright. `PVW_PYTHON_EXE` and `PVW_TARGET_PY` do NOT skip anything --
the full normal detection logic still runs to completion (including real network/disk work), and
the override simply overwrites the *result* variable afterward. `PVW_CONDA_EXE` (Scenario 9) is
its own case again, discussed separately since it has a unique interaction with the conda
self-heal flow.

### Scenario 8: `PVW_PYTHON_EXE` / `PVW_UV_EXE` / `PVW_TARGET_PY` / `PVW_WORKSPACE`

**What's tested:** all four now have real, valid-value end-to-end CI coverage; `PVW_PYTHON_EXE` and
`PVW_WORKSPACE` also each have a real, invalid-value CI scenario (`tests/selfapps_pvw_overrides.ps1`,
`uv` lane -- confirmed passing in the same fully-green CI run this whole document's
release cycle was verified against: run `30709255610`, job `91393894838`). Neither `PVW_UV_EXE`
nor `PVW_TARGET_PY` has invalid-value coverage of its own; that half of 8b/8c below stays
`[Extrapolated Branch]`, traced from source.

**8a. `PVW_PYTHON_EXE`** overrides `HP_PY` at the shared convergence point every REQ-009 provider
path (uv, conda, embed, venv, system, and every provider-cascade re-entry) funnels into after
already selecting and setting up a working interpreter -- so it does NOT skip provider
acquisition, it only overwrites the final result:

```
[INFO] Python host: using super-user override PVW_PYTHON_EXE.
```

Real, confirmed via `tests/selfapps_pvw_overrides.ps1`'s `self.pvw.python_exe.valid` scenario
(a two-stage test: stage 1 does an ordinary uv bootstrap to materialize a real interpreter, stage 2
is a genuinely fresh scratch directory pointing `PVW_PYTHON_EXE` at stage 1's interpreter) -- the
override log line fires and the app runs successfully via the borrowed interpreter. Invalid-value
trace, confirmed by the same file's `self.pvw.python_exe.invalid` scenario (a nonexistent path): no
existence/executability check on the path itself; the first real probe is a non-fatal interpreter
smoke test (`[WARN] Interpreter smoke test failed (continuing).`) that does NOT abort the run --
every subsequent `pip install` call is similarly wrapped in a WARN-only failure handler, so the
bootstrap proceeds all the way to the PyInstaller build attempt with a broken interpreter before
finally hitting a real failure there (the pre-existing, already-documented `:die`/`state=error`
path). A bad `PVW_PYTHON_EXE` is therefore detected early (one WARN) but not treated as fatal
until several steps downstream, not at the point of misuse.

**8b. `PVW_UV_EXE`** overrides `HP_UV_EXE` and genuinely skips the entire uv download/acquire
branch (jumps straight past it):

```
[INFO] uv: using super-user override PVW_UV_EXE.
```

REAL CI CAPTURE, run `30328748330`, job `90179708086` (`contract-uv` lane),
`tests/selfapps_contract_uv.ps1`'s dedicated uv-version-forwarding scenarios (which reuse an
already-downloaded `uv.exe` via this override specifically to avoid re-downloading it for each of
several sub-bootstraps):

```
[DEBUG] Using super-user override for PVW_UV_EXE: D:\a\...\~envsmoke\~uv_bin\uv.exe
[INFO] uv: using super-user override PVW_UV_EXE.
[INFO] uv: creating venv at .uv_env with Python 3.12...
```

Invalid-value trace (`[Extrapolated Branch]`, no test forces a bad path): a broken/invalid
`PVW_UV_EXE` is fully absorbed by the existing REQ-009 provider-cascade fallback machinery -- the
uv-first Python-detection probe fails gracefully (WARN, falls toward Miniconda), and even if venv
creation is separately attempted with the same bad binary, an independent, exit-code-agnostic
on-disk check (`if not exist "...\Scripts\python.exe" goto :uv_venv_fail`) catches a binary that
misleadingly reports success without doing real work -- no crash, no silent success, clean
fall-through to conda.

**8c. `PVW_TARGET_PY`** overrides `PYSPEC` at the shared merge point both the uv-first and
conda-base detection paths converge on -- like `PVW_PYTHON_EXE`, detection still runs to
completion first:

```
[INFO] Python version: using super-user override PVW_TARGET_PY.
```

REAL CI CAPTURE, run `30328748330`, job `90179708094` (`conda-full` lane),
`tests/selfapps_pipgap.ps1` (sets this to `python=3.12` to pin conda's Python version so a
specific `opencv-python` wheel is guaranteed available for a different test purpose entirely):

```
[DEBUG] Using super-user override for PVW_TARGET_PY: python=3.12
[INFO] Python version: using super-user override PVW_TARGET_PY.
```

Invalid-value trace (`[Extrapolated Branch]`): no format validation; a garbage value becomes an
invalid conda package spec or an invalid `uv venv --python` request, surfacing as a real,
correctly-handled provider failure absorbed by the same fallback/cascade machinery as 8b --
reaching a graceful `:die` (`state=error`) only if every fallback tier is also exhausted, never an
uncontrolled crash.

**8d. `PVW_WORKSPACE`** overrides `HP_UV_ENV_PATH` (the uv venv's path) with a clean, immediate
override -- the default is assigned and instantly replaced before any use, unlike 8a/8c's
"let it run, override the result" pattern. **Scope limitation worth flagging explicitly: this
variable only takes effect in uv mode.** Conda's own environment path has no corresponding check
at all -- a conda-mode run ignores `PVW_WORKSPACE` entirely.

Uniquely among the four, **there is no dedicated confirmation log line at its actual point of
use** -- only the generic top-of-file `[DEBUG]` line, which fires purely because the variable is
defined, before it's even known whether uv mode (where this variable matters at all) will be
selected. Real, confirmed via `tests/selfapps_pvw_overrides.ps1`'s own `self.pvw.workspace.valid`
scenario:

```
[DEBUG] Using super-user override for PVW_WORKSPACE: <path>
```

with `Scripts\python.exe` genuinely present at the custom path afterward (and the default
`.uv_env` never created). Invalid-value trace, confirmed by the same test file's
`self.pvw.workspace.invalid` scenario (a path already occupied by a plain file, so uv cannot
create a venv "inside" it): no path validation up front, but the failure lands on exactly the
already-established `:uv_venv_fail` fallback chain 8b/8c also use, reaching the log line `falling
back to conda create` -- no crash, no silent success.

---

### Scenario 9: `PVW_CONDA_EXE` and its interaction with the conda self-heal flow

**What's tested:** `self.corrupt.conda.override_exit` (`tests/selftest.ps1`), self-contained by
construction (no ordering dependency on Miniconda already being installed elsewhere in the job,
unlike its sibling corrupt-conda scenarios).

**Source:** REAL CI CAPTURE, run `30328748330`, both `real` and `conda-full` lanes (`real` job `90179708091` and
`conda-full` job `90179708094`), both `pass: true`, `exitCode: 2`.

`PVW_CONDA_EXE` overrides the resolved conda batch-file path unconditionally, the instant it's
defined -- and because this happens BEFORE the "install Miniconda if missing" block, setting it
also skips the Miniconda download/install entirely:

```
[DEBUG] Using super-user override for PVW_CONDA_EXE: <path>
```

**The special interaction, and the whole reason this variable gets its own scenario:** normally,
when a health check on the resolved conda binary fails, the bootstrapper offers an interactive
Y/N self-heal prompt that (on accept) deletes and rebuilds the entire Miniconda root. When
`PVW_CONDA_EXE` is set, this self-heal path is skipped outright -- the very FIRST check in the
corruption-handling subroutine, ahead of every other check including the CI auto-decline logic --
because the bootstrapper will never auto-delete a path it doesn't own:

```
================================================================
  CORRUPTED PYTHON ENVIRONMENT DETECTED
================================================================

  The local conda installation appears to be broken.
  This can happen after a Windows update or OS migration
  (example: DLL load error 0xc000007b).

  Affected path: <MINICONDA_ROOT>

  This binary was specified via PVW_CONDA_EXE:
    <path to PVW_CONDA_EXE>

  Automatic self-healing is not available for user-managed conda.
  Please fix or replace the binary at the path above, then re-run.
```

followed by the exact error/exit sequence:

```
[ERROR] Corrupt user-managed conda (PVW_CONDA_EXE); fix manually.
```

and the process exits with code **2** -- notably, there is no Y/N prompt at all in this path, even
for a genuinely interactive real user; the override check runs before the interactivity dispatch
even has a chance to matter.

---

### Scenario 10: Drag-and-drop / CLI entry-file override (REQ-011 same-directory rule + REQ-002 priority)

**What's tested:** three real, currently-passing NDJSON rows across two test files --
`self.entry.req011.crossdir` and `self.entry.req011.sameDir` (`tests/selfapps_isolation.ps1`), and
`self.entry.override` (`tests/selfapps_ux_hardening.ps1`, which specifically proves the override
wins over auto-detection, not merely that dragging works at all).

**Source:** REAL CI CAPTURE, run `30328748330`, both `real` and `conda-full` lanes (`real` job `90179708091` and
`conda-full` job `90179708094`), all three rows `pass: true` in both.

A user can either type a `.py` filename as the first CLI argument to `run_setup.bat`, or literally
drag a `.py` file onto the `.bat` file's icon in Windows Explorer (Windows translates the drop
into the identical `%1` argument). **REQ-011's rule: the file must be in the SAME directory as
`run_setup.bat` itself**, checked twice for defense-in-depth (once as an early pre-flight check,
for instant feedback before any environment work begins, and once again inside the entry-selection
subroutine itself). A cross-directory attempt genuinely terminates the whole process (`exit /b 1`,
not merely a `call`-frame return) with:

```
[ERROR] REQ-011: Dragged files must reside in the bootstrapper root folder for environment cleanliness.
```

(This is the raw, untimestamped console line; the separately-written log-file copy is a shorter
variant without the "for environment cleanliness" clause -- a real, source-confirmed difference,
not a typo, confirmed via real CI capture: `[ERROR] REQ-011: Dragged files must reside in the
bootstrapper root folder.`)

A same-directory file succeeds and prints the filename (a historical bug that once printed this
line with an EMPTY filename -- see `docs/agent-lessons-learned.md`'s "Provider-cascade dispatch is
goto-based on purpose" entry -- is long fixed; the current, correct text is shown below):

```
*** Using drag-and-drop file: <filename>
```

**Interaction with the REQ-002 interactive entry picker: fully and structurally skipped.**
Providing a valid same-directory file makes entry selection return immediately, before the
auto-detection block (and therefore the picker, which is only ever invoked from inside that same
block) is even reached -- this is REQ-002's documented "priority 0": a co-located override always
wins over auto-detected names, and can never trigger the ambiguous-case timed picker. Confirmed
positively (not just "dragging works," but that override genuinely beats auto-detection) by
`self.entry.override`'s real capture: a scratch directory staged with BOTH `main.py` (which would
win plain auto-detection by name-priority) and `zzz_override.py`, with `zzz_override.py` passed as
the override -- the real run confirms the drag message names the override file, the entry-selected
log line names `zzz_override.py` (not `main.py`), and the override file's own distinguishing output
is what actually ran. The exact console sequence that test asserts against (`tests/
selfapps_ux_hardening.ps1` lines 1161-1164 -- a scratch directory staged with both `main.py`
containing `print("from-main")` and `zzz_override.py` containing `print("from-override")`,
launched as `run_setup.bat .\zzz_override.py`):

```
*** Using drag-and-drop file: .\zzz_override.py
[BOOT] REQ-002: Entry selected: zzz_override.py
from-override
```

The third line is the override script's own stdout, captured in `~run.out.txt` -- the test asserts
it contains `from-override` and specifically does NOT contain `from-main`, confirming the override
genuinely ran instead of the higher-name-priority file sitting right next to it.

---

## Part IV: Adversarial and recovery branches

**Scope note:** excludes `HP_TEST_*` CI-only flags as the documented subject -- they're the
mechanism a test uses to force a scenario deterministically, but the resulting console text below
is exactly what a real user hits when the same underlying condition occurs for real (a genuine
flaky connection, a genuinely corrupted conda install, a genuinely missing bundled module, and so
on). Evidence for this entire Part is pulled from run `30328748330` (commit `5872028`, all lanes
green): `real` (job `90179708091`), `conda-full` (job `90179708094`), `uv` (job `90179708109`),
`justme-test` (job `90179708103`).

### Scenario 11: Network connectivity check and transient-retry (REQ-013 + REQ-022)

**What's tested:** `self.ux.connectivity.*` rows (`tests/selfapps_ux_hardening.ps1`, real lane);
`self.stub.conda_retry`/`self.stub.conda_create_retry`/`self.stub.conda_perpkg`
(`tests/selftest.ps1`, conda-full lane). All real, all passing.

When a download genuinely fails, `:check_net_after_dl_fail` (REQ-013) pings `8.8.8.8` (2 attempts)
then, if ICMP is blocked, tries an HTTPS reachability check against `conda.anaconda.org` (2
attempts) before concluding the user is actually offline -- this doubled-attempt design exists
because a single dropped ICMP echo or a momentarily-contended connect on a busy machine is enough
to misclassify a genuinely-online host as offline (this was root-caused from a REAL CI flake, not
a hypothetical). If both checks fail, a real user sees an unbounded prompt:

```
[WARN] REQ-013: Connectivity check: no internet detected (ICMP and HTTPS check failed).
WARNING: No internet connection detected. Remote providers may fail. Retry? (Fix connection then press Y) or proceed offline (N): 
```

Pressing Enter with no answer defaults to offline; `Y` re-tries (2 more ping attempts, then 2 more
HTTPS attempts) before re-prompting on continued failure; `N` proceeds offline (`HP_OFFLINE_MODE=1`
for the rest of the run).

**Transient-retry for `conda create` and conda's bulk package install (REQ-022)** -- both use the
identical detect-and-retry-once pattern: scan the failure output for `CondaHTTPError`/`Failed to
fetch`/`timed out`/`ConnectionError`, wait 15 seconds, retry exactly once. If the retry ALSO fails,
it falls straight through to the normal (non-transient) failure/fallback chain -- this is not an
infinite-retry loop.

`conda create` retry, REAL CI CAPTURE (`tests/selftest.ps1`'s conda-full sub-bootstrap):

```
Creating Python environment '_selftest_conda_create_retry' -- this may take several minutes...
Conda environment creation failed -- possible network or repository issue. Retrying once...
[INFO] conda create: transient failure detected; retrying after 15s.
Retrying environment creation...
[INFO] runtime.txt written: python-3.14.6
[BOOT] REQ-009: Selected Python provider: Conda (Portable).
```

Bulk package install retry, REAL CI CAPTURE (same test file, a different scratch env):

```
Conda install failed -- possible network or repository issue. Retrying once...
[INSTALL] conda bulk: transient failure detected; retrying after 15s.
Retrying package installation...
```

A NON-transient bulk failure (any error text that doesn't match the transient patterns above)
skips the retry entirely and instead falls back to installing packages one at a time
(`self.stub.conda_perpkg`, REAL CI CAPTURE, `[INSTALL] conda per-pkg fallback`) -- a completely
separate recovery path from the transient-retry one, chosen based on what kind of failure
actually occurred.

---

### Scenario 12: Corrupted-conda self-heal (detect / decline / accept)

**What's tested:** `self.corrupt.conda.detect`/`.heal.decline`/`.heal.accept`
(`tests/selftest.ps1`, conda-full lane, all three real and passing). The `PVW_CONDA_EXE`-override
variant is already covered in Scenario 9 -- this scenario is the DEFAULT case, where the
bootstrapper owns the conda install and can offer to fix it.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708094` (`conda-full` lane).

When a health check on the resolved conda binary fails, the user sees:

```
================================================================
  CORRUPTED PYTHON ENVIRONMENT DETECTED
================================================================

  The local conda installation appears to be broken.
  This can happen after a Windows update or OS migration
  (example: DLL load error 0xc000007b).

  Affected path: C:\Users\Public\Documents\Miniconda3
```

followed by an unbounded `[Y/N]` prompt (`  Would you like to delete it and rebuild? [Y/N] `,
`[Extrapolated Branch]` for the exact prompt line, same reasoning as Scenario 5's two prompts --
it lives inside `set /p`, never visible in a CI log even when a test forces the accept branch via
an answer override).

**Decline** (real capture):

```
  Exiting without changes. Delete the folder above manually,
  then run this setup again.
```

logged as `[ERROR] Corrupt conda env; user declined rebuild.`, exit code 2.

**Accept** (real capture; this specific test run additionally forces the actual re-download step
to be skipped for CI-safety reasons, so the "Downloading fresh copy..." line below is
`[Extrapolated Branch]`, cited from source, while everything else is real):

```
  [INFO] Removing corrupt Miniconda installation...
  [INFO] Corrupt installation removed. Downloading fresh copy...
```

```
[INFO] Self-healing: corrupt conda evicted from C:\Users\Public\Documents\Miniconda3.
[INFO] Workspace: ...\tests\~selftest_heal_accept
[INFO] Env name: _selftest_heal_accept
[INFO] HP_ENV_MODE=conda
[INFO] Creating Python environment '_selftest_heal_accept' -- this may take several minutes...
[INFO] runtime.txt written: python-3.14.6
[BOOT] REQ-009: Selected Python provider: Conda (Portable).
```

A real user's accept path re-downloads and reinstalls Miniconda from scratch (the full
acquisition sequence from Scenario 3), then proceeds exactly as a fresh first run would.

---

### Scenario 13: Miniconda install chain (AllUsers -> JustMe -> both-failed)

**What's tested:** `conda.install.justme` (`tests/selftest.ps1`, `justme-test` lane, real,
passing) and `self.conda.bothfail` (`tests/selfapps_conda_bothfail.ps1`, `uv` lane, real,
passing).

**Source:** REAL CI CAPTURE, run `30328748330`, jobs `90179708103` (`justme-test`) and
`90179708109` (`uv`).

Miniconda install first attempts an AllUsers (machine-wide) install; if UAC rejects elevation (or
the process simply isn't elevated), it skips straight to a JustMe (per-user) install instead, no
wasted attempt. **Both the "skip, never attempted" path and a genuine post-attempt AllUsers
failure fall through to the same shared `:tci_justme` label** (`run_setup.bat`) -- the label checks
a flag set only right before the real AllUsers install attempt, so the two paths get distinct
wording instead of both unconditionally claiming AllUsers "failed." On the common non-elevated
machine (skip path, `[Extrapolated Branch]`, cited from source):

```
[INFO] Not elevated; skipping AllUsers Miniconda install.
[INFO] Miniconda AllUsers install skipped (not elevated); trying JustMe install instead.
[INFO] Miniconda installed (JustMe fallback).
```

A genuine, post-attempt AllUsers failure still gets the original WARN wording, now also carrying
the installer's own exit code and a reason token (`[Extrapolated Branch]`, cited from source --
this branch requires a real elevated process whose AllUsers installer genuinely fails, which no
current CI hook forces without also forcing the skip path):

```
[WARN] Miniconda AllUsers install failed (exitCode=1, reason=installer_failed); retrying with JustMe.
```

If the installer instead hits `:run_installer_timeout`'s own 60-minute ceiling (see that
subroutine's header comment), the exit code is a hardcoded sentinel, not the installer's real
exit code -- reported as `reason=timeout` with no fabricated `exitCode` field instead
(`[Extrapolated Branch]`, an even rarer sub-case of the one above, never observed in CI):

```
[WARN] Miniconda AllUsers install failed (reason=timeout); retrying with JustMe.
```

**If JustMe ALSO fails** (both installation options exhausted; REAL CI CAPTURE for the skip-path
lines, `[Extrapolated Branch]` for the now-corrected wording):

```
[INFO] Not elevated; skipping AllUsers Miniconda install.
[INFO] Miniconda AllUsers install skipped (not elevated); trying JustMe install instead.
[ERROR] Miniconda install failed (AllUsers skipped -- not elevated; JustMe also failed).
```

This is a genuine `:die` (`state=error`), not a graceful degrade -- with no Python interpreter
acquirable at all through conda, there's nothing left for this tier to hand back. Both installer
launches are bounded by a generous 60-minute timeout (not unbounded), based on real-world reports
of Miniconda's silent installer hanging indefinitely on some machines.

---

### Scenario 14: Standalone embed-tier download (REQ-009 Tier 5) -- decline and real success

**What's tested:** `self.embed.fallback.decline`/`self.embed.fallback.real`
(`tests/selfapps_ux_hardening.ps1`, `uv` lane, both real and passing).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708109` (`uv` lane).

When uv and conda have both failed (or been declined/exhausted), the bootstrapper tries
downloading a private, checksummed Python interpreter directly from python.org -- no consent
prompt (unlike system Python), since this is a bootstrapper-controlled, disposable extraction:

```
[WARN] Attempting embedded Python download (REQ-009 Tier 5)...
```

**Real success** (a genuine end-to-end download/verify/extract/patch/pip-bootstrap/canary/build/
run, REAL CI CAPTURE):

```
[INFO] Downloading embedded Python 3.14.6 from https://www.python.org/ftp/python/3.14.6/python-3.14.6-embed-amd64.zip...
[INFO] embed fallback: 3.14.6 extracted and verified.
```

**Tier exhaustion** (this specific tier also fails, e.g. offline -- REAL CI CAPTURE):

```
[WARN] embed fallback: offline mode; cannot download embedded Python.
```

A genuine download failure (not offline, an actual failed transfer) retries the WHOLE
download+verify cycle once before giving up. The mechanism is confirmed real via
`self.embed.dl.retry` (`tests/selfapps_ux_hardening.ps1`, `uv` lane), which forces this path
deterministically for CI purposes without touching the network -- but what a real user watching
this happen would actually see is the two real, unconditional console lines the source always
prints on a genuine transfer failure (`[Extrapolated Branch]`, built from source: the download line
already shown above, then a real `curl` failure falling through to the PowerShell fallback, both
inside the SAME attempt, before the retry line fires):

```
*** curl download failed, trying PowerShell...
[WARN] embed fallback: download failed; retrying once.
```

followed by the tier succeeding end to end on the second attempt. A checksum mismatch is treated
the same way (redownload, not just re-verify, since a mismatch can mean a truncated download
rather than a bad pin) -- that specific trigger has no dedicated test of its own, `[Extrapolated
Branch]` for that one detail.

---

### Scenario 15: REQ-009 provider cascade -- one real run showing the FULL chain

**What's tested:** `self.cascade.exec` (`tests/selfapps_cascade.ps1`, `uv` lane, real, passing).
This single test happens to exercise BOTH mid-exhaustion (uv/conda/embed all cascade past) AND
full exhaustion (system Python, the final tier, declines) in one coherent real capture -- an
unusually complete real-world illustration of this mechanism.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708109` (`uv` lane).

After a build succeeds but a dependency repair genuinely fails (Scenario 17 covers what triggers
this), the user is offered (Scenario 5's timed `:cascade_consent_gate`, up to 30s, default
decline) a chance to try the next Python provider. On acceptance, the REAL capture below shows the
cascade working through every tier in order -- each hop re-attempts the full dependency phase
under the new provider, and each hop that ALSO can't fully resolve dependencies triggers another
verification failure and another cascade offer:

```
[INFO] REQ-009: cascading provider uv to conda; re-attempting dependencies.
*** [INFO] Trying the next Python provider (conda) to resolve dependencies...
```

```
[INFO] REQ-009: cascading provider conda to embed; re-attempting dependencies.
*** [INFO] Trying the next Python provider (embed) to resolve dependencies...
```

```
[INFO] REQ-009: cascading provider embed to venv; re-attempting dependencies.
*** [INFO] Trying the next Python provider (venv) to resolve dependencies...
```

**Note the log wording says "uv to conda", never "uv -> conda"** -- deliberate: `:log` echoes
unquoted, so a literal `>` would be parsed as shell redirection and silently eat the line.

Right before each cascade offer, the elective postexec-checkpoint/optimized-build prompts from
Scenario 5 are SKIPPED (not just auto-declined) once cascade is approved -- confirmed in this
same real capture:

```
[INFO] Entry smoke exit=1
[STATUS] Run Status: FAILED (Exit Code: 1)
[INFO] REQ-009: cascade approved; skipping the post-verification offers for this build.
```

**Full exhaustion**, reached when venv ALSO can't fully resolve dependencies and the cascade
offers the absolute last resort, system Python (REQ-014's consent gate, Scenario 5's other
cross-referenced gate) -- declined here (CI auto-decline; a real interactive user sees the full
timed/untimed prompt sequence documented in Scenario 5):

```
[INFO] REQ-009: cascading provider venv to system; re-attempting dependencies.
[WARN] Attempting system Python fallback (degraded)...

*** WARNING: System Python Execution ***
*** Using global system Python may pollute shared packages. ***

Proceed with System Python? (Global pollution risk) [y/n]: y to accept, n to decline.
[INFO] REQ-014: System Python consent: user declined.
[INFO] REQ-014: System Python fallback aborted: consent not granted.
[WARN] REQ-009: cascade target system Python unavailable; keeping current build.
```

With every tier now exhausted, the bootstrapper keeps whatever build it had (venv, in this
capture) and prints the honest caveat panel (Scenario 43's REQ-027 messaging) instead of "SETUP
COMPLETE":

```
============================================================
 SETUP COMPLETE -- WITH A CAVEAT
============================================================
 We packaged your app, but couldn't fully verify it runs as a
 standalone program. Your Python environment was set up and the
 packaging step completed without a fatal error.

 RUNNING YOUR APP
   Double-click dist\_selftest_cascade_exec.exe to run it.
   You can also run it directly via the interpreter at any time:
     "<full path to>\.venv\Scripts\python.exe" "app.py"
```

**Both the caveat text and the interpreter line above are updated to reflect current source, not
the original real capture -- the rest of this panel (the exhausted-cascade log lines above it,
the header, and the file paths) is still the original evidence.** The original real capture showed
`"" "app.py"` here (a genuinely empty `HP_PY`) and the older, overclaiming "Your environment and
dependencies ARE installed correctly" wording. `:print_postflight_briefing` only prints a valid
interpreter command when `HP_PY` genuinely still points at a working interpreter at this point in
the flow -- when a declined cascade-to-system fallback tier clears its own `HP_PY` on the way out
(correct for a first-time provider chain, where nothing was working yet, but wrong once a cascade
re-entry has ALREADY produced a working build under an earlier tier), `:provider_cascade` now
saves `HP_PY` on entry and `:after_cascade_decision` restores it before falling through to this
panel, so the still-good venv interpreter path this exact panel is describing as ready to use
survives a declined later tier intact; `:print_postflight_briefing` also skips the interpreter
line entirely rather than print an empty command if `HP_PY` is ever undefined for any other
reason. The caveat wording above was separately narrowed to stop claiming dependency installation
was verified, since it isn't confirmed by this point in the flow regardless of which panel fires.
The corrected interpreter line above is therefore `[Extrapolated Branch]` (this specific fix has
not yet been re-exercised by a fresh real CI capture of this exact scenario) -- the general shape
(a `.venv\Scripts\python.exe` path, since the log lines above confirm venv was the tier actually
kept) is derived from `:try_venv_fallback`'s own `set "HP_PY=%CD%\.venv\Scripts\python.exe"` line,
not independently captured.

**Each tier is tried at most once as a cascade source** (`HP_CASCADE_TRIED_<tier>` guards),
`HP_ENV_MODE` only ever advances (`uv -> conda -> embed -> venv -> system`), so the cascade
structurally cannot loop -- it either lands on a working tier or exhausts and stops, exactly as
shown here.

---

### Scenario 16: `--hidden-import` auto-recovery (success and exhaustion)

**What's tested:** `self.exe.hidden_import` (success, `tests/selfapps_hidden_import.ps1`) and
`self.exe.hidden_import.exhaust` (`tests/selfapps_hidden_import_exhaust.ps1`), both real/conda-full
lanes, real, passing.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

When a frozen EXE fails at runtime with `ModuleNotFoundError` for a module that IS installed in
the build interpreter, the bootstrapper rebuilds with `--hidden-import=<module>` added, bounded to
3 attempts. This is strict by design -- an uninstalled module (a real missing dependency) or a
plain `ImportError` (not a missing module at all) never triggers a rebuild, since the fix is not
mechanically derivable.

**Success, one rebuild** (`self.exe.hidden_import`'s own fixture: a dynamic `importlib.import_module`
call on `colorama`, invisible to PyInstaller's static analysis, so the frozen EXE genuinely fails
its first run) -- exact sequence assembled from the log lines `tests/selfapps_hidden_import.ps1`
itself matches against (`run_setup.bat`'s own `:log` calls at the smokerun/recovery call sites).
`[Extrapolated Branch]` on the one `Adding --hidden-import=...` line specifically: the cited real
capture (run `30328748330`) predates CLAUDE.md Item 28's `--collect-submodules` pairing fix, so
that single line is traced from the CURRENT source instead of copied verbatim from that run; the
other 4 lines in this block are untouched by Item 28 and remain accurate to the original capture:

```
[WARN] EXE smokerun: exited 1 (non-zero)
[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama --collect-submodules=colorama; rebuilding EXE (iter 1/3).
[REPAIR][HIDDEN_IMPORT] EXE verified after hidden-import recovery.
[INFO] EXE smokerun: exited 0 (ok)
[INFO] Entry smoke exit=0
```

(CLAUDE.md Item 28: every `--hidden-import=X` this loop adds is now paired with
`--collect-submodules=X` on the same rebuild, so a compiled extension needing one of X's own
submodules -- invisible to PyInstaller's static scan the same way the original missing import
was -- gets a chance to be bundled in the same pass, rather than surfacing as a separate,
undiagnosable failure later.)

**Exhaustion** (three DIFFERENT modules missing across three rebuilds, still never fully
resolving -- REAL CI CAPTURE):

```
[WARN][HIDDEN_IMPORT] Auto-recovery exhausted after 3 attempts; module(s) still missing.
```

`~bootstrap.status.json` still reads `state: ok` in this case -- the user's own program repeatedly
failing to import something is not a bootstrapper failure (the environment and build lifecycle
both succeeded); see CLAUDE.md's "User-code exit-code semantics" Known Finding.

---

### Scenario 17: Warnfix repair loop (success, and the failure that feeds the cascade)

**What's tested:** `self.exe.warnfix.install`/`.pass` (success) and `.xfail` (a module install
genuinely fails), `tests/selfapps_warnfix.ps1`, real/conda-full lanes, all real, all passing.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

Unlike Scenario 16 (runs AFTER a launch fails), warnfix runs BEFORE the EXE is ever launched --
PyInstaller's own warn file lists modules it couldn't bundle statically, and the bootstrapper
tries to install and rebuild:

**Success** (real capture, a clean repair with no failures):

```
[INFO] warnfix: some modules could not be automatically bundled (full list in ~warnfile.txt / ~setup.log); modules such as posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, and _frozen_importlib_external are expected on Windows and are filtered out automatically.
[REPAIR] missing modules detected; installing and rebuilding.
[REPAIR] rebuild complete after warnfix.
```

**A module that genuinely can't be installed** (real capture -- `StringIO`, a Python-2-only
module some Python-3 code still conditionally imports, which no Python-3 environment can satisfy):

```
[REPAIR] missing modules detected; installing and rebuilding.
[WARN] Repair failed: StringIO
[WARN] One or more repair attempts failed
[REPAIR] rebuild complete after warnfix.
```

The rebuild still happens (bundling whatever WAS successfully installed), but this specific
unresolved-after-rebuild situation is exactly what feeds `HP_CASCADE_CANDIDATE` -- setting up the
provider-cascade offer documented fully in Scenario 15.

---

### Scenario 18: Pre-flight guards actually firing

**What's tested:** `self.warn.onedrive`, `self.warn.sysdir`, `self.stub.low_disk_warn`
(`tests/selftest.ps1`, real lane, all real and passing). Contrast with Scenario 2, which showed
these same four guards' CLEAN (silent) pass.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

**OneDrive** (real capture):

```
*** WARNING: Script appears to be in a OneDrive folder. File locking may cause failures.
[WARN] OneDrive path detected; file locking may cause failures.
```

**Disk space, REQ-025** (real capture -- warn-only, never a hard block, per REQ-001's rule that a
flag-detectable condition must never gate the Prime Directive). The block emits three raw `echo`
lines before the `[WARN]` line the underlying test asserts on; all four are console-visible in the
same run, so a real user sees the full four-line block below, not just the final `[WARN]`:

```
*** WARNING: Only ~0 GB free disk space detected on this drive.
*** Downloading Python/Miniconda and building your app can need several GB.
*** If setup fails partway through, freeing up disk space is a likely fix.
[WARN] REQ-025: low disk space detected (~0 GB free); continuing (warn-only).
```

**System directory guard** (the one guard that's a hard ABORT, not a warning -- exit code 1,
confirmed via a real, passing NDJSON row, though the specific console dump wasn't captured
verbatim in this run's log excerpt, so the exact banner text below is `[Extrapolated Branch]`,
cited directly from source):

```
*** ERROR: This script is located inside a Windows system folder.
*** Placing it here does not "install" it. Windows restricts writes to this location
*** without administrator rights, and this bootstrapper needs to create files right
*** next to itself to work.
*** Please move this script (and your .py files) to a normal folder -- your Desktop
*** or Documents folder both work well -- then run it again from there.
```

**Path-length guard**: this one is genuinely hard to exercise in CI, for a structural reason worth
being upfront about -- GitHub-hosted Windows runners don't have `LongPathsEnabled` by default, so
PowerShell's own `Push-Location` can fail to navigate into a scratch directory built long enough to
trigger `run_setup.bat`'s own 200-char check before the sub-bootstrap ever gets a chance to run at
all. The test's own real NDJSON row makes this concrete: `pathLen: 312` (the directory really was
built long enough), `ranBootstrap: false` (the runner itself couldn't get there), `skip: true,
reason: 'runner-cannot-navigate-long-path'` -- an honest inconclusive result, not a false pass. The
guard's own text is confirmed from source only for this doc (`[Extrapolated Branch]`):

```
*** WARNING: Script path is 312 chars. Paths near 260 chars may cause cmd.exe failures.
```

---

### Scenario 19: Concurrent-instance lock contention (REQ-024)

**What's tested:** `self.stub.lock_held_decline`/`self.stub.lock_stale_evict`
(`tests/selftest.ps1`, real lane, both real and passing).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

A user double-clicking the bootstrapper twice in quick succession (or genuinely running two
instances) hits an NTFS-atomic `mkdir`-based lock. If a second instance finds the lock genuinely
held by a live first instance:

```
***
*** Another instance of this setup appears to be running in this folder already.
*** If you are sure that is NOT the case (for example, a previous run crashed),
*** delete the "~bootstrap.lock" folder next to this script and run it again.
***
pid=<owning process id>
started=<owning process start time>
[WARN] REQ-024: setup already running (lock held, not stale); this instance is exiting.
```

exit code 1 -- the losing instance never touches the lock it doesn't own. If the lock directory
is instead STALE (left over from a crashed/killed prior run, older than the ~2 hour staleness
threshold), it's evicted automatically and the run proceeds normally with no user action needed:

```
[INFO] REQ-024: stale lock evicted (older than the staleness threshold); proceeding.
```

Staleness is deliberately age-based, not PID-liveness-based -- a dead process's PID can be
recycled by an unrelated program, so trusting PID liveness for automated eviction would be unsafe.

---

## Part V: Remaining branches (dependency source precedence, write-back, and misc)

**Scope note:** this part collects everything from the plan's 5-pass checklist that didn't fit
naturally into Parts I-IV: dependency and Python-version source precedence, the two write-back
mechanisms (`runtime.txt`, PEP 723 headers), the optional execute-mode discovery flag, NI-VISA/
pandas per-package special-casing, the periodic conda maintenance timer, and the one REQ-014
branch (consent ACCEPT) that Part IV's Scenario 15 didn't cover (it only showed decline).

---

### Scenario 20: Git config merge (`.gitignore`/`.gitattributes`, REQ-015)

**What's tested:** `self.ux.gitignore.merge`/`.preserve`/`.idem`, `self.ux.gitattributes.merge`
(`tests/selfapps_ux_hardening.ps1`, `real` lane, all real and passing).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

On a fresh checkout with no `.gitignore`/`.gitattributes` at all, `:merge_git_config` (`run_setup.bat`)
idempotently appends a standard block to each, guarded by an `findstr` signature check
(`# Automated Python Bootstrapper Standard Ignores` / `...Attributes`) so a second run is a clean
no-op rather than a duplicate append:

```
[INFO] REQ-015: Appending standard ignores to .gitignore.
[INFO] REQ-015: Appending standard attributes to .gitattributes.
```

This is the first thing `run_setup.bat` prints to the console (`:merge_git_config` runs before the
environment-name/host-diagnostics block Scenario 2 covers, though several earlier steps -- the
UNC-path check among them -- are silent on an ordinary path; see Scenario 2 for the full list) --
the same real capture continues immediately with:

```
[INFO] Environment name: _envsmoke
[INFO] Host OS: Microsoft Windows [Version 10.0.26100.32995]
[INFO] Host PowerShell: 5.1.26100.32995
```

On the idempotent second run, BOTH `.gitignore`/`.gitattributes` lines above are absent entirely --
`findstr`'s signature check short-circuits straight past each `call :log` line
(`if not errorlevel 1 goto :mgc_gi_done` / `:mgc_ga_done`) before it can fire, so this step
contributes zero console output on a repeat run. `self.ux.gitignore.idem` confirms this by
counting the signature's occurrences in the file (`sigCount:1`, not by scanning for an absent log
line), which is why the idempotent case has no console excerpt of its own here.

The appended `.gitignore` block (verbatim from source):

```
# Automated Python Bootstrapper Standard Ignores
.*_env/
.venv/
.uv/
.cache/
.conda/
dist/
build/
*~
~*
```

and `.gitattributes`:

```
# Automated Python Bootstrapper Attributes
*.bat -text
*.cmd -text
*.exe binary
```

Real evidence confirms all three properties the tests assert: the signature is appended
(`self.ux.gitignore.merge`), any PRE-EXISTING content in the file (e.g. a user's own `node_modules/`
line) survives the merge untouched (`self.ux.gitignore.preserve`, `nodeModulesFound:true`), and
running the bootstrapper a second time does not duplicate the signature (`self.ux.gitignore.idem`,
`sigCount:1`). This runs unconditionally on every bootstrap invocation, independent of provider or
entry-file state -- it is one of the first things `run_setup.bat` does after the pre-flight guards.

---

### Scenario 21: Python-version precedence (REQ-004) and dependency-source precedence (`pyproject.toml`)

**What's tested:** `pyproject.precedence.detect`/`.writeback` (`tests/selfapps_pyproject_precedence.ps1`,
both real and passing) and `pyproject.dep.detect`/`.noproj` (same file). `pyproject.precedence.detect`
ran in the `conda-full` lane in this capture (the `real` lane's own copy of the row emits
`skip=true, reason=conda-not-installed-uv-first` since it happens to call `Get-CondaBatPath`, per
`docs/agent-interconnect.md`'s skip-pattern convention for this test file); `pyproject.dep.*` and
`.writeback` ran in `real`.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708094` (`conda-full`) for the version
tiers, job `90179708091` (`real`) for the dependency-source precedence.

These are two genuinely SEPARATE precedence systems that happen to both read `pyproject.toml` and
are easy to conflate -- worth documenting distinctly.

**REQ-004 (Python VERSION precedence, three tiers)**: Tier 1 `runtime.txt` beats Tier 2
`pyproject.toml`'s `[project].requires-python` beats Tier 3 "let the selected provider pick latest,
then write `runtime.txt` back." These two NDJSON rows deliberately test two DIFFERENT things in two
DIFFERENT scratch directories with two DIFFERENT constraints, not one continuous flow -- worth
being precise about, since the test file's own comments explain why: `.detect` calls
`~detect_python.py` directly (no bootstrap, no environment ever created) against a tight
`requires-python = ">=3.10,<3.11"` (real source, `tests/selfapps_pyproject_precedence.ps1`):

```toml
[project]
requires-python = ">=3.10,<3.11"
```

to check Tier 2's parse/forward precision in isolation; `.writeback` runs the FULL bootstrapper
against a deliberately loose `requires-python = ">=3.9"` in a separate directory (real source, same
test file):

```toml
[project]
requires-python = ">=3.9"
```

("so conda picks a cached Python version and avoids a slow resolver round-trip for Python 3.10
packages," per the test's own comment) to check Tier 3's write-back end to end.

`.detect`'s real NDJSON output confirms Tier 2's parse/forward is exact: `output":"python>=3.10,<3.11"`.
`.writeback`'s real capture shows Tier 3 firing (since `runtime.txt` didn't pre-exist there either):

```
[INFO] runtime.txt written: python-3.14.6
```

(real capture; `pyproject.precedence.writeback`'s own NDJSON row confirms `runtimeVersion:
python-3.14.6` and `versionSatisfied:true` against ITS OWN, looser `>=3.9` constraint -- 3.14.6
satisfies `>=3.9` comfortably. It does NOT satisfy the OTHER test's `<3.10,<3.11` constraint, but
that constraint was never used for this environment; the two tests are independent, and this
document originally conflated them into one implied sequence before being corrected.) Malformed
`pyproject.toml` TOML degrades gracefully rather than aborting the whole precedence chain -- real
input source (`tests/selftest.ps1`, `self.pyproject.malformed`), a missing closing bracket on the
section header:

```toml
[project
name = "malformed-app"
```

produces this real capture:

```
*** [WARN] pyproject.toml could not be parsed as valid TOML; falling back to requirements.txt or pipreqs.
```

logged compactly too: `[WARN] pyproject.toml TOML parse error; falling back.` -- the bootstrap then
proceeds via Tier 3 (provider picks latest) exactly as if `pyproject.toml` had never existed.

**Dependency-SOURCE precedence (a different mechanism, REQ-004/REQ-005.1 rows, unrelated to Python
version)**: when `pyproject.toml` declares a real `[project].dependencies` array, it takes priority
over any `requirements.txt` present -- this is decided independently of the version-tier logic
above and can fire even when `runtime.txt` already exists. Real input source (same test file):

```toml
[project]
name = "myapp"
dependencies = [
    "requests>=2.28",
    "colorama",
]
```

Real capture:

```
*** [INFO] pyproject.toml [project].dependencies found; overrides requirements.txt
[INFO] pyproject.toml [project].dependencies detected
[INFO] DEP_SOURCE=pyproject
```

`~pyproj_deps.py` (`HP_PYPROJ_DEPS`) is the helper that extracts the array; real NDJSON detail from
`pyproject.dep.detect` shows it parsing a real two-line array (`"output":"requests>=2.28\r\ncolorama"`,
`exitCode:0`). When `pyproject.toml` has no `[project]` section at all, the helper exits 1 with no
output rather than a false match (`pyproject.dep.noproj`, `exitCode:1, outExists:false`) -- the
bootstrapper then falls through to `requirements.txt`/pipreqs as usual.

---

### Scenario 22: PEP 723 dependency write-back (REQ-005.11) -- the fresh-install trigger

**What's tested:** `self.pep723.writeback.fresh`/`.skipflag` (`tests/selfapps_pep723_writeback.ps1`,
`real` lane, both real and passing).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

**Input, `app.py` (real source, `tests/selfapps_pep723_writeback.ps1`'s default `fresh` scenario --
no existing PEP 723 header, no `requirements.txt`):**

```python
import requests
print('hi')
```

After a genuinely fresh, fully-successful `HP_ENV_MODE=uv` dependency install (see Part I,
Scenario 3), `:pep723_writeback` promotes the resolved dependency set into the entry file's own
PEP 723 header via `uv add --script`, so the pin travels with the user's source file rather than
staying only in `requirements.txt`/the lock file. The three lines immediately before it are the
same real capture already shown in Scenario 3 (dependency install completing, the pip-freeze
snapshot, the environment-lock snapshot) -- `:pep723_writeback fresh` is called right at
`:lock_done`, immediately after the last of those three:

```
[INFO] UV_USED=1
[INFO] DEP_INSTALLED_CAPTURED=1
[INFO] Environment snapshot written: ~environment.lock.txt
[INFO] REQ-005.11: PEP 723 header write-back succeeded via uv add --script.
```

**Output, `app.py` (same file, now carrying the written-back header)** -- this test's own
assertions confirm the block markers, a `requires-python` line, and `requests` are all present, but
don't assert exact formatting beyond that; the precise shape shown is the same one Scenario 36
already establishes and cites in full (`docs/agent-lessons-learned.md`'s "`uv add --script` / PEP
723 empirical behavior" section) -- `[Extrapolated Branch]` for the exact layout:

```python
# /// script
# requires-python = ">=3.14"
# dependencies = [
#     "requests",
# ]
# ///

import requests
print('hi')
```

When there is nothing to write (a stdlib-only app, no third-party packages resolved), the
subroutine correctly no-ops rather than writing an empty/misleading header -- also a REAL capture:

```
[INFO] REQ-005.11: PEP 723 write-back skipped (no packages to write).
```

This is `HP_ENV_MODE=uv`-only (v1 scope, see `docs/agent-interconnect.md`) and best-effort -- it
does not block the run: any failure (malformed existing header not cleanly repairable, a file lock, non-UTF-8 source)
logs a `[WARN]` and the bootstrap continues unaffected; `HP_SKIP_PEP723_WRITEBACK=1` suppresses it
outright per REQ-019 (a genuine opt-OUT flag, not a gate). The warnfix-triggered SECOND write-back
call (after a successful repair round) is functionally identical and not separately captured here
-- same subroutine, same two possible outcomes, triggered from a different call site.

---

### Scenario 23: `HP_PVW_KNOWN_IDEMPOTENT` execute-mode discovery (REQ-005.13)

**What's tested:** `self.pvw_idempotent.discovery` (`tests/selfapps_pvw_idempotent.ps1`, `uv` lane,
real and passing).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708109` (`uv` lane).

This is an opt-in super-user flag (not part of the default happy path -- Part I never sets it):
when defined, `run_setup.bat` skips straight to actually RUNNING the entry file live via
`uvx autopep723 <entry>` for dependency discovery, before pipreqs or any static analysis even
starts. `:pvw_known_idempotent_run` is gated on an EARLY, silent entry-determination pass that
runs right after the Python provider is selected -- `run_setup.bat` determines the entry file
TWICE: once here, quietly, just to populate `HP_ENTRY` for this and a couple of other early-stage
checks, and once again much later, after the entire dependency-install phase, which is the pass
that actually announces itself on screen (the "Chosen entry: ..." moment Scenario 2 covers). So
this discovery run fires right after the provider line below, well BEFORE the entry is ever
announced on screen. Real capture, `self.pvw_idempotent.discovery`, including the entry script's
own live stdout passed straight through mid-run (real NDJSON detail confirms
`stdoutPassthroughFound:true, appRan:true` -- not captured or suppressed, the exact design point
`tools/pvw_known_idempotent.py` exists to preserve):

```
[BOOT] REQ-009: Selected Python provider: UV.
[INFO] REQ-005.13: HP_PVW_KNOWN_IDEMPOTENT set; running entry via uvx autopep723 for execute-mode discovery.
t2-idempotent-ok
[INFO] REQ-005.13: execute-mode discovery run succeeded (RAN:persisted).
```

(`t2-idempotent-ok` is this specific stub's own `print()` output -- see Scenario 36 for the exact
`app.py` source that produces it, and for the file-content side of this same real test.)

Whatever dependency the run needed (`requests`, in this real capture: `reqsHasRequests:true`) is
persisted back into the PEP 723 header via `uv add --script`, then re-extracted into
`requirements.txt` so the rest of the pipeline (pipreqs, Tier 1 autopep723 merge, the actual
install) sees it too. Deliberately ADDITIVE, not a replacement for pipreqs -- pipreqs and Tier 1's
own `autopep723 check` merge still run normally afterward to catch anything a single execution
path didn't happen to exercise. Only once that entire dependency-install phase finishes does the
bootstrapper reach the LATER, canonical entry announcement:

```
Chosen entry: app.py
[BOOT] REQ-002: Entry selected: app.py
```

---

### Scenario 24: NI-VISA detection and install outcome (REQ-008)

**What's tested:** `pyvisa.detect`/`.nivisa.branch`/`.nivisa.outcome`/`.nivisa.reason`/`.nivisa.disabled`
(`tests/selfapps_pyvisa.ps1`, `real`/`conda-full` lanes, all real and passing).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real`) and job `90179708094`
(`conda-full`) -- both lanes captured a genuine NI-VISA install ATTEMPT in this run (not just the
"not required" skip), which is a more complete illustration than what an earlier pass in this
document assumed was CI's only available evidence.

When `pyvisa`/`visa` is detected as an import, the bootstrapper attempts a real NI-VISA driver
install (downloads the online bootstrapper installer via curl, PE-validates it, then launches it
under a bounded timeout):

```
[INFO] Detected pyvisa/visa import; NI-VISA install may be required.
[VISA] download method: curl
[VISA] installer file size: 6769400 bytes
[VISA] installer PE check: PE_OK
[INFO] Launching NI-VISA installer (timeout ceiling: 5400000 ms).
[VISA] installer exit code: -125202
[VISA] post-check waiting; retry 1/3 (installer_rc=-125202)
[VISA] post-check waiting; retry 2/3 (installer_rc=-125202)
[VISA] install_failed (post_check_timeout) installer_rc=-125202
```

This matches CLAUDE.md's already-documented Known Finding ("NI-VISA real install fails fast in CI")
in shape and mechanism exactly -- a genuine, PE-valid installer download that exits fast and
unattended-incompatible on a CI runner -- though the SPECIFIC installer exit code observed here
(`-125202`) differs from that finding's originally-cited `-125083`. Consistent with the finding's
own framing (an online bootstrapper installer failing an unattended install, not a fixed/stable
error code), not a new discrepancy worth a separate backlog entry. The bootstrap proceeds
gracefully regardless -- a failed NI-VISA install is never treated as a bootstrap failure, only
logged and surfaced; the user's own program still builds and runs.

Real evidence confirms the OTHER outcome branch too, via a dedicated `HP_SKIP_NIVISA=1` scenario in
the same test file: `[VISA] skipped (not_required)`, with `skippedDisabled:true,
noInstallAttempt:true` -- the flag suppresses the install attempt outright even when pyvisa IS
detected, per REQ-019's suppression-only convention.

---

### Scenario 25: pandas/openpyxl heuristic dependency augmentation (REQ-005.8)

**What's tested:** `pandas_excel.translate`/`.conda.install`/`.conda.install.req006`/`.runtime`,
`self.pandas.openpyxl.install`/`.import` (`tests/selfapps_pandas_excel.ps1`, `conda-full` lane, all
real and passing) -- plus a genuinely SEPARATE test that happens to exercise the same heuristic in
a different scratch directory, `self.exe.warnfix.real` (`tests/selfapps_warnfix.ps1`'s `real`
scenario, `conda-full` lane, also real and passing, `desc: "Heuristic pre-installed openpyxl via
pandas heuristic; EXE succeeded"`).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708094` (`conda-full` lane).

**Input, `app.py` and `requirements.txt` (real source, `tests/selfapps_pandas_excel.ps1`):**

```python
import pandas as pd

df = pd.DataFrame({"a": [1, 2]})
df.to_excel("out.xlsx")
```

```
pandas
```

`~prep_requirements.py` (`HP_PREP_REQUIREMENTS`) applies a small set of heuristic rules that inject
a commonly-needed-but-undeclared package when its "parent" package is present -- pandas's
`pd.read_excel()`/`to_excel()` need `openpyxl`/`xlsxwriter`, but pipreqs' static analysis has no
way to see that a lazily-imported optional engine is actually required at runtime. Real capture
from `tests/~pandas_excel/`'s own scratch directory:

```
[HEURISTIC] pandas->xlsxwriter
```

The console line is deliberately a compact tag -- the two package names themselves are appended to
the conda install spec list, then genuinely resolved by conda's own solver a few lines later in the
same run. That solve output reaches `~setup.log` only, never the console (the `conda install` call
this heuristic feeds is redirected via `>> "%LOG%"`, matching this doc's "Console vs. `~setup.log`"
convention noted at the top):

```
openpyxl conda-forge/win-64::openpyxl-3.1.5-py314hccc76fc_3
xlsxwriter conda-forge/noarch::xlsxwriter-3.2.9-pyhd8ed1ab_0
```

Both package names are recorded in `~pandas_excel`'s own `requirements.txt`/`~reqs_conda.txt`/
`~reqs_pip.txt` (dependency-source files, not installation targets); conda is what actually
installs them into the selected environment, per the solver output quoted above. The claim that
`openpyxl` ends up genuinely bundled and importable in a frozen EXE is confirmed by the SIBLING
`self.exe.warnfix.real` test's OWN independent scratch directory (`tests/~selftest_warnfix_real/`,
a different app that also exercises the pandas heuristic, per its own NDJSON `desc` text quoted
above) rather than by `~pandas_excel`'s own PyInstaller warn-file -- its EXE's PyInstaller warn
file shows only expected, harmless optional-dependency lines for the bundled `openpyxl`: `missing
module named PIL - imported by openpyxl.drawing.image (optional)`, not a real gap. This is
`HP_ENV_MODE=conda`-lane-only coverage per this test file's own CI wiring (see
`docs/agent-interconnect.md`'s
"selfapps_pandas_excel.ps1" note) -- the SAME heuristic logic also runs for uv/venv/embed/system
providers via `requirements.txt` write-back (CLAUDE.md's own "Deep research pass" Closed Backlog
entry on this exact fix), just not captured here since this test is conda-only by design.

That claim is directly confirmed by `self.exe.warnfix.real`'s own real bootstrap console capture from
the SAME CI run (`tests/~selftest_warnfix_real/~warnfix_real_bootstrap.log`) -- a full `run_setup.bat`
run whose `requirements.txt` declares only `pandas` (triggering the identical heuristic rule shown
above), while the app's own source imports `openpyxl` directly and writes `out.xlsx` via
`openpyxl.Workbook()` rather than through pandas -- deliberately isolating the heuristic-provisioned
package as the only thing under test. This run reaches an actual build and EXE smoke test:

```
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] PyInstaller produced dist\_selftest_warnfix_real.exe
[INFO] EXE smokerun: testing dist\_selftest_warnfix_real.exe
wrote out.xlsx
[INFO] EXE smokerun: exited 0 (ok)
[STATUS] Run Status: SUCCESS (Exit Code: 0)
```

`wrote out.xlsx` is the app's own `print()` output, reached only after `openpyxl.Workbook().save()`
succeeds inside the frozen EXE -- direct, unambiguous proof the heuristic-installed `openpyxl` was
genuinely bundled and usable at runtime, not just resolved by conda's solver. This same real run
separately hit unrelated warnfix repair failures (`multiprocessing`, `pyimod02_importers`, `vms_lib`,
`java`, `win32pdh` -- none are real installable packages, a PyInstaller warn-scan false-positive class
distinct from this heuristic) and a declined REQ-009 cascade prompt; neither affected the pandas/
openpyxl outcome, since `openpyxl` was already correctly provisioned by the heuristic before the
build ever started.

---

### Scenario 26: Conda base periodic update

**What's tested:** `self.conda.base.update` (`tests/selfapps_conda_update.ps1`) -- **NOT currently
wired into any CI lane** (per `docs/agent-ndjson.md`'s own explicit note: the `HP_TEST_CONDA_UPDATE`
injection flag was removed because it upgrades conda to a solver version that cascades failures
across the rest of the `conda-full` job). Only the "skipped" branch below has real CI evidence.

**Source (skipped branch):** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane,
appears identically across every fresh scratch-dir bootstrap in the run).

`:conda_base_update` runs `conda update -n base` on a timer (30-day threshold, seeded from
`~conda.lastupdate` on first install) whenever `HP_ENV_MODE=conda`. On a genuinely first-ever
install (the common case in a fresh CI scratch dir, and for most real first-time users), it
correctly skips rather than updating a base that was just installed moments ago:

```
[INFO] Conda base update: skipped (first install).
```

**`[Extrapolated Branch]`** -- the two other real-world branches are not exercised by any current
CI run (the only flag that could force the update path is deliberately disabled, per the note
above), but each is an exact, deterministic literal string straight from source, not an
approximation. The far more common case for a REPEAT run within the 30-day window -- most real
projects, re-bootstrapped many times during ordinary development -- is a second kind of skip, one
that genuinely checks `~conda.lastupdate`'s timestamp rather than assuming a fresh install:

```
[INFO] Conda base update: skipped (last update < 30 days ago).
```

Once that timestamp finally IS more than 30 days old, `:cbu_run` fires for real:

```
[INFO] Conda base update: running (>=30 days since last update or no record).
[INFO] Conda base update complete.
```

Between those two lines, `conda update -n base --all --override-channels -c conda-forge -y` runs
with its output redirected straight to `~setup.log` (`>> "%LOG%" 2>&1`) -- conda's own real
update-solve output (package list, versions, download progress) never reaches the console, matching
this doc's "Console vs. `~setup.log`" convention. If the update itself fails (a nonzero exit from
that command), the second line is this instead -- the bootstrap is never blocked by a failed base
update either way:

```
[WARN] Conda base update failed; continuing.
```

The update-firing branch realistically only fires for a long-lived, repeatedly-reused project
folder well past its 30-day mark -- not the fresh-checkout scenarios this document otherwise
captures -- and is correctly out of scope for a dedicated CI test: a forced-update test previously
broke conda's own solver in shared CI runners, an accepted, documented tradeoff
(`docs/agent-ndjson.md`'s "conda-full lane rows" section).

---

### Scenario 27: REQ-014 system-Python consent -- ACCEPT

**What's tested:** `self.ux.system.gate.accept` (`tests/selfapps_ux_hardening.ps1`, `real` lane,
real and passing). Part IV's Scenario 15 already showed the DECLINE branch of this same gate (as
the terminal step of a full provider-cascade exhaustion); this scenario completes the pair.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

When every other REQ-009 provider tier has failed or been declined, the system-Python tier is
still reached by any default, no-flag run -- it is gated solely by the REQ-014 consent prompt,
never by an env-var the user would need to set. The prompt text itself (`:system_python_consent_gate`,
`run_setup.bat`) is echoed unconditionally, even on CI's auto-decline path, so it is exact, literal
source text, not a reconstruction:

```
*** WARNING: System Python Execution ***
*** Using global system Python may pollute shared packages. ***

Proceed with System Python? (Global pollution risk) [y/n]: y to accept, n to decline.
```

On ACCEPT, the bootstrapper proceeds to use whatever Python is already on the machine, unmanaged
and unisolated:

```
[INFO] REQ-014: System Python consent: user accepted.
[INFO] System fallback using C:\hostedtoolcache\windows\Python\3.12.10\x64\python.exe
[BOOT] REQ-009: Selected Python provider: System Python (degraded).
```

`~bootstrap.status.json` still reports `state` as the degraded-but-successful `degraded_env` value
(real NDJSON detail: `"state":"degraded_env","exitCode":0`) -- accepting this tier is a genuine,
if suboptimal, path to a working run, not a failure. This is the ONLY REQ-009 tier gated by an
explicit human consent prompt rather than an automatic fallback, precisely because it is the one
tier that touches the user's real, shared Python environment instead of a private/disposable one.

---

## Part VI: Additional branches found in a full-file sweep

**Scope note:** after the original 5-pass plan completed, a systematic label-by-label sweep of
every one of `run_setup.bat`'s 164 `:label`s (cross-checked against everything already written in
every other Part of this file) turned up four genuine, user-observable gaps -- three straightforward
missing scenarios, and one previously-undocumented, real bug in the bootstrapper's own error messaging,
found via real CI evidence and confirmed against source before being written up. Everything else
checked in the sweep (roughly 150 of the 164 labels) was either already covered, internal
control-flow plumbing with no independently observable behavior of its own (e.g. `:pfb_runapp`,
`:mgc_gi_done`), or a narrow edge case not worth a dedicated scenario (e.g. `:cascade_consent_no_
choice_exe`, reached only on a Windows image stripped of `choice.exe`).

- [Scenario 28: Interactive entry picker -- multiple `.py` files, no clear winner (REQ-002)](#scenario-28-interactive-entry-picker----multiple-py-files-no-clear-winner-req-002)
- [Scenario 29: Pre-flight syntax-error rejection (REQ-021), and a real bug it exposed](#scenario-29-pre-flight-syntax-error-rejection-req-021-and-a-real-bug-it-exposed)
- [Scenario 30: REQ-007 system-Python build consent, and the resulting no-EXE interpreter path](#scenario-30-req-007-system-python-build-consent-and-the-resulting-no-exe-interpreter-path)
- [Scenario 31: EXE smoke-run diagnostic hints (companion to Scenario 16)](#scenario-31-exe-smoke-run-diagnostic-hints-companion-to-scenario-16)

---

### Scenario 28: Interactive entry picker -- multiple `.py` files, no clear winner (REQ-002)

**What's tested:** `self.entry.picker` (`tests/selfapps_entry_picker.ps1`, `conda-full` lane, real,
passing).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708094` (`conda-full` lane).

Part I's happy path covers the common single-`.py`-file case; this covers REQ-002's OTHER real
end-user scenario: a folder with several `.py` files where none is named `main.py`/`app.py`/
`run.py`/`cli.py` and none has a substantive `if __name__ == "__main__":` block (`:determine_entry`'s
own priority ladder, in `tools/find_entry.py`, exhausts every tier and falls back to
`find_entry.py`'s own `AMBIGUOUS_RC` (3) alphabetical pick). Only THEN does `:pick_entry_interactive`
show a real, timed menu:

```
Multiple Python files detected -- no clear entry point, so please choose one to run:
  [1] a_app.py
  [2] b_app.py

  Tip: to skip this question next time, do any one of these:
    1. Drag a .py file onto run_setup.bat -- drop it on the batch file icon to run
       that file directly. It must be in this same folder.
    2. Rename your main script to one of: main.py, app.py, run.py, or cli.py.
    3. Give exactly one script an  if __name__ == "__main__":  block.
  If you do nothing, the alphabetically-first file is used: a_app.py

Type a number 1-2, or wait 30s for the default [1]:
```

(the real capture's own timeout is shrunk to 2s via `HP_TEST_FORCE_PICKER`, the same CI-determinism
technique already used for the timed cascade prompt in Scenario 5/21 -- the default, real-user
window is 30 seconds, per `HP_PICK_T` in source, shown above as written). A real, non-interactive
CI run also can't feed `choice.exe` an actual keystroke, so the captured log shows one extra,
CI-only artifact line right after the prompt (`ERROR: The file is either empty or does not contain
the valid choices.`) before falling through to the timeout default -- a real interactive user typing
a number, or simply waiting, never sees that line. Either way, the resolution is logged:

```
[INFO] REQ-002: Picker entry selected: a_app.py
```

If MORE than 9 candidate files exist, the picker's own numbered menu is skipped entirely (no menu
can address more than the `123456789` `choice /C` charset) and the alphabetical pick is kept, logged
as `[INFO] REQ-002: <N> candidates exceed picker limit; keeping <file> (alphabetical).`. The same
three-item Tip list shown above (drag-and-drop, a preferred filename, or a `__main__` block) still
prints right after that log line -- worded "to avoid the alphabetical fallback next time" here,
since no question was actually asked to skip -- because it's exactly the guidance a user who just
hit a >9-file folder needs most to avoid landing here again; this used to be silently skipped along
with the rest of the menu, fixed in the same pass that wrote this scenario. `[Extrapolated Branch]`
for the exact console text, cited from `:pick_entry_interactive` -- the branch itself is now
covered by `self.entry.picker.overflow` (`tests/selfapps_entry_picker.ps1`, `conda-full` lane,
registered in `docs/agent-ndjson.md`), which stages 10 candidate files and asserts the overflow log
line, the Tip guidance, and the alphabetical default all fire correctly; that test only dumps a
full console log to CI on failure, so the exact text below is still not an independently captured
console dump.

---

### Scenario 29: Pre-flight syntax-error rejection (REQ-021), and a real bug it exposed

**What's tested:** `self.preflight.syntax` (`tests/selfapps_preflight.ps1`, `real` lane, real,
passing) for the ordinary case -- its `$pass` gate enforces the REQ-021 message firing, the real
`SyntaxError` detail appearing, `state: error`, and no PyInstaller-build-crash text; "no EXE was
produced" is separately computed and recorded (`noExe` in the row's own `details`, confirmed
`true` in the real capture below) but is NOT itself part of the pass/fail gate. A SEPARATE,
unrelated real capture (`self.embed.fallback.decline`, `tests/selfapps_ux_hardening.ps1`)
accidentally also reaches this code path under total provider exhaustion, which is what exposed
the bug documented below.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

**The ordinary case**: before ever attempting a doomed PyInstaller build, `:preflight_compile`
byte-compiles the entry file with the SAME parser the interpreter itself uses (`py_compile`,
zero false positives), reporting a genuine `SyntaxError` clearly and stopping before the build:

```
*** [ERROR] REQ-021: Your Python program has a syntax error and cannot run. ***
*** File: "app.py" ***
```

followed by the real Python compiler's own traceback (captured to `~preflight.err.txt`, echoed to
both console and log) and a closing `*** Fix the syntax error shown above, then run this batch
again. ***`. `~bootstrap.status.json` correctly reads `state: error`; the dependency install and
environment creation that ran BEFORE this check are left intact (nothing is torn down), so a fixed
file on the next run reuses them.

**A real bug, found via this exact sweep, confirmed against a real, unrelated capture (not
fabricated for this scenario), and fixed.** The capture below is historical, from before the fix,
kept unedited as a real, timestamped log. `:preflight_compile` used to invoke `"%HP_PY%" -m
py_compile "%HP_ENTRY%"` with no check that `HP_PY` was actually a valid, non-empty interpreter
path first. On TOTAL REQ-009 provider-tier exhaustion (every tier fails or is declined),
`:after_env_mode_selection`'s own `HP_PY`-resolved guard
(`call :die "[ERROR] Active Python interpreter not resolved."`) does NOT actually halt the
pipeline -- per this repo's own long-documented `:die` semantics, `exit /b` inside `:die` only
returns from `:die`'s own call frame, so execution fell through and continued for another ~15 log
lines with an EMPTY `HP_PY`, all the way to `:preflight_compile`. There, `"" -m py_compile
"app.py"` was not a Python invocation at all -- it was cmd.exe trying to execute a program
literally named `""`, which produces a CMD.EXE ERROR, not a Python traceback. Because
`:preflight_compile` treated ANY nonzero exit as "syntax error," it reported this as if the user's
own code were broken. Real capture, from a test that deliberately force-fails uv (offline), conda,
the embed tier, and venv, and declines the REQ-014 system-Python prompt
(`tests/~selftest_embed_decline/`'s own sub-bootstrap):

```
[ERROR] Active Python interpreter not resolved.
Interpreter:
[WARN] Interpreter smoke test failed (continuing).
```

**`[Extrapolated Branch]`** for what happens between those lines and the misleading block below --
traced from source, not an independently preserved capture. `run_setup.bat` genuinely keeps
executing -- pipreqs's own install attempt, the dependency-install step, and the pyvisa detection
check are none of them gated on `HP_NO_INTERPRETER` (confirmed by reading each call site directly;
that flag was only ever checked by the fix's own new `:preflight_compile` guard), so each one
genuinely runs against the empty `HP_PY` before the entry is finally selected and preflight fires.
Their own exact console text from this specific historical run was not separately preserved
alongside the two blocks quoted here (only the excerpts a maintainer captured while diagnosing the
bug at the time
survived) -- each would have produced its own `cmd.exe`-level "not recognized" error or install
failure, the same general shape as the two blocks already shown, rather than silently vanishing.

```
*** [ERROR] REQ-021: Your Python program has a syntax error and cannot run. ***
*** File: "app.py" ***
'""' is not recognized as an internal or external command,
operable program or batch file.

*** Fix the syntax error shown above, then run this batch again. ***
```

That last block was genuinely misleading: `app.py` may have had no syntax problem whatsoever -- the
real cause, printed several screens earlier, was that no Python interpreter was ever found. A real
user was realistically reachable here for genuine (not test-only) reasons: README's own REQ-009
table already notes that falling through three-plus provider tiers in one run is "almost always one
shared root cause" (no internet, a full disk, or a locked-down managed image), and a user hitting
exactly that plus declining the REQ-014 system-Python consent prompt would reach this identical
path. The status FILE was never affected (`state: error` was always written correctly, since
`:die`'s own state-set already happened before the fall-through) -- only the human-readable console
narrative misdirected a user who read just the last error rather than scrolling back.

**Fixed**: `:after_env_mode_selection`'s guard now also sets `HP_NO_INTERPRETER=1` before calling
`:die` (the call-frame-only-return fall-through itself is left as-is -- a deeper refactor of that
mechanism was judged out of scope for this fix). `:preflight_compile` checks this flag first and,
if set, reports the real cause instead of running `py_compile` against an empty interpreter path:

```
*** [ERROR] No Python interpreter is available; your program was not run or built. ***
*** This is not a syntax error -- the Python interpreter itself could not be used. ***
*** Either every automatic Python-acquisition method -- uv, conda, a fresh download, ***
*** or a local virtual environment -- failed, usually from no internet connection, a ***
*** full disk, or a locked-down managed machine image -- or a PVW_PYTHON_EXE override ***
*** points at a path that does not run. Scroll up in this window for the specific reason. ***
```

(The message text was later reworded during implementation to avoid a literal `(...)` pair split
across two `echo` lines inside the same parenthesized `if` block -- cmd.exe's block parser counts
parens in echo text too, so a `(` on one line and its `)` on the next silently mis-closed the
block and broke every CI lane reaching this branch in the same run. See
`docs/agent-lessons-learned.md`'s batch-syntax-quirks section for the full trace.)

This also skips the doomed PyInstaller build attempt entirely (`:run_entry_smoke`'s existing
`HP_PREFLIGHT_FAILED` check already short-circuits the build, unchanged by this fix), not just the
misleading message.

---

### Scenario 30: REQ-007 system-Python build consent, and the resulting no-EXE interpreter path

**What's tested:** `self.sysbuild.decline` (`tests/selfapps_sysbuild.ps1`, `real` lane, real,
passing) -- its `$pass` gate enforces that the REQ-007 prompt text appears, the decline is
logged, packaging is skipped with a logged reason, and no EXE exists afterward. The REQ-014
"use system Python at all" accept step that gets this test INTO system-Python mode in the first
place is the same mechanism Scenario 27's own `self.ux.system.gate.accept` test covers
independently, not re-asserted here. The interpreter-smoke success/status lines quoted below
(`Entry smoke exit=0`, `[STATUS] Run Status: SUCCESS`) are genuinely present in this same real
captured log but are NOT part of this test's own `$pass` gate -- shown here as observed fact from
the real capture, not as something this specific test independently verifies.

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane),
`tests/~selftest_sysbuild/`'s own sub-bootstrap -- ONE coherent, continuous real capture covering
the full journey below.

Scenario 27 showed REQ-014's "use system Python at all?" consent being accepted. That is not the
only consent gate on this tier: once system Python is actually selected as the provider, a SECOND,
independent consent gate (`:system_build_consent_gate`, REQ-007) asks separately about installing
PyInstaller into that same system Python to build a standalone EXE -- distinct from REQ-014, and
reachable only in `HP_ENV_MODE=system` mode (every other provider tier gets no such prompt, since
none of them touch a shared, uncontrolled Python installation):

```
*** The standalone EXE build installs PyInstaller into your system Python. ***
*** This is the same PyInstaller build used for every provider -- not a special path -- and ***
*** its footprint is small and self-contained (it does not pin common libraries), so it is ***
*** unlikely to conflict with your existing packages. ***
```

CI auto-declines (same CI-safe pattern as every other consent gate in this file: `HP_TEST_
SYSBUILD_ANSWER` override checked first, then `HP_CI_LANE` auto-decline, then a real, unbounded
`set /p` for an interactive user). On decline, dependency install and environment setup are left
completely intact -- only the PyInstaller packaging step is skipped:

```
[INFO] REQ-007: system-Python EXE build consent: declined.
[INFO] REQ-007: system-Python EXE build not consented; skipping PyInstaller packaging. The environment and dependencies are installed; run the app directly via the prepared Python.
```

With no EXE ever attempted, `:verify_no_exe_interpreter` becomes the sole verification run (this is
also the general no-EXE path reached whenever `dist\<env>.exe` doesn't exist for any reason -- a
declined build here, or PyInstaller being entirely unavailable elsewhere -- not specific to this
consent gate):

```
[INFO] Running entry script smoke test via system interpreter.
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)
[INFO] REQ-018: post-execution checkpoint (interpreter): declined (run footprint stays at one execution).
```

The postflight briefing that follows is `:print_no_exe_briefing` (Part V/CLAUDE.md's REQ-027 P2
work already documents its honest-messaging design and its `HP_NOEXE_VERIFY_FAILED`-gated caveat
variant) rather than the EXE-focused `:print_postflight_briefing` -- distinct panels for a
genuinely distinct outcome (no packaged deliverable exists, but the app runs fine via the prepared
interpreter).

---

### Scenario 31: EXE smoke-run diagnostic hints (companion to Scenario 16)

**What's tested:** the `[HINT]` mechanism fires as a byproduct of `selfapps_exedata_fail.ps1`
(`DATA_FILE` hint) and `selfapps_exedyn_fail.ps1`/`selfapps_hidden_import_exhaust.ps1`-family tests
(`HIDDEN_IMPORT` hint), both real/conda-full lanes, real, passing (the hint lines are a bonus
diagnostic these tests emit, not the tests' own primary assertion target).

**Source:** REAL CI CAPTURE, run `30328748330`, job `90179708091` (`real` lane).

Scenario 16 covers `--hidden-import` auto-recovery reaching its 3-attempt cap without resolving. In
that same failure family -- any EXE that still fails at runtime AFTER hidden-import recovery has
been tried (or was never applicable, e.g. a genuinely missing DATA file, not a missing module) --
`:exe_smokerun_hints` re-runs the EXE briefly (no timeout needed; these failures exit immediately)
purely to pattern-match its stderr and offer a targeted, actionable hint. Two real captures, from
two different xfail scenarios:

**A missing bundled data file** (real capture, `FileNotFoundError`):

```
[HINT][DATA_FILE] Missing data file detected: C:\Users\RUNNER~1\AppData\Local\Temp\_MEI41642\mypkg\data\info.txt
[HINT][DATA_FILE] Consider adding: --add-data C:\Users\RUNNER~1\AppData\Local\Temp\_MEI41642\mypkg\data\info.txt;.
[HINT][RUNTIME_MISMATCH] Standalone EXE behavior differs from the Python runtime (possible PyInstaller packaging issue in the EXE, not your environment or dependencies)
```

**A missing module hidden-import recovery couldn't resolve** (real capture, `ModuleNotFoundError`):

```
[HINT][HIDDEN_IMPORT] Hidden import likely missing: absent_dynmod_xyz
[HINT][HIDDEN_IMPORT] Consider adding: --hidden-import=absent_dynmod_xyz
[HINT][RUNTIME_MISMATCH] Standalone EXE behavior differs from the Python runtime (possible PyInstaller packaging issue in the EXE, not your environment or dependencies)
```

Both hint types are logged via `:log` (console AND `~setup.log`), so a real user hitting either
failure sees them directly -- not buried in a diagnostic-only file. The `RUNTIME_MISMATCH` hint is
a universal closing line, not specific to the `DATA_FILE` branch -- both real captures above show
it: every path through `:exe_smokerun_hints` (data-file match, module-not-found match, or neither)
falls straight through to it with no `goto`/`exit` skipping it in between, so it always fires
alongside whichever more specific hint (if any) matched, as a general reminder that a frozen EXE's
behavior can differ from the interpreter's for packaging reasons unrelated to environment or
dependencies. A separate, optional machine-readable form exists too (`HINT_JSON=1`, an
undocumented-in-README super-user flag that additionally prints each hint as a compact JSON object
via PowerShell) -- not independently captured in this run.

---

## Part VII: Full startup-to-shutdown walkthroughs

**Scope note:** every scenario elsewhere in this file is deliberately narrow -- one feature area,
excerpted to the lines that illustrate it. This Part does the opposite: five composite panels that
show a run from its first console line to its last, so a reader can see the actual SHAPE of a
complete bootstrap without jumping between sections. None of these is sourced from one single,
continuous CI capture (no test in this repo is designed to produce that) -- each is assembled from
real fragments already individually cited elsewhere in this file, spliced into one continuous flow
and labeled where the splice itself (not any individual line) is `[Extrapolated Branch]`. Cross-
reference the originating scenario for that fragment's own detailed sourcing rather than re-deriving
it here.

### Scenario 32: Full walkthrough -- the ordinary happy path, start to shutdown

Splices Scenario 2's pre-flight/entry-detection evidence and Scenario 3's provider/dependency
evidence (both from the `colorama`-importing stub app) with Scenario 4's own single, fully
self-consistent, zero-staleness real capture (the `hello_stub.py` trivial app, chosen there
specifically because it already spans build through the final status panel with no gaps). All three
are real CI captures from the same run (`30328748330`, job `90179708091`, "real" lane) -- just two
different scratch apps within that run, since no single test in this repo builds one app all the
way from a cold uv download through a `hello_stub`-style trivial verification. The splice point
(where the `colorama` app's pre-build evidence hands off to the `hello_stub` app's build-onward
evidence) is `[Extrapolated Branch]` -- the two are structurally identical at that point (both are
first-ever runs, no cached state, uv-first), but were never the same process.

**Input, `app.py` (the `colorama` app -- real source, `tests/selfapps_envsmoke.ps1`, drives every
line below up through `[INFO] REQ-005.11: PEP 723 header write-back succeeded`):**

```python
import colorama  # Prime Directive: proves pipreqs scanned app.py, conda installed it
import os as _os
import sys as _sys

# Write token to a sidecar file. stdout-based approaches (print, os.write) are
# unreliable through cmd.exe redirects on some Windows Python distributions due
# to CRT file-descriptor/HANDLE mismatch (see history in selfapps_envsmoke.ps1).
# File I/O uses Win32 CreateFile/WriteFile directly - no stdout involved.
# Use sys.argv[0] so normal Python runs write next to app.py while PyInstaller
# --onefile runs write next to the EXE instead of the transient _MEI temp tree.
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~smoke_token.txt'), 'w') as _f:
    _f.write('smoke-ok\n')
```

No `requirements.txt`, `runtime.txt`, or `pyproject.toml` -- just this file and `run_setup.bat`.
This app writes its proof-of-life to a sidecar file rather than stdout (the comment explains why:
a CRT file-descriptor quirk on some Windows Python distributions), which is why the build-onward
half of this walkthrough switches to a second, genuinely different real capture below instead of
continuing this same app's own evidence.

**Input, `hello_stub.py` (a second, different real app -- `tests/selftest.ps1` -- takes over as the
entry from `[INFO] Building standalone executable` onward; see the splice-honesty note above):**

```python
print("hello-from-stub")
```

```
[INFO] REQ-015: Appending standard ignores to .gitignore.
[INFO] REQ-015: Appending standard attributes to .gitattributes.
Chosen entry: app.py
[INFO] uv: UV_PYTHON_PREFERENCE=only-managed (orchestration uses managed Python).
[INFO] uv: downloading to ~uv_bin...
[INFO] Downloading uv from https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip...
[INFO] uv: acquired at ~uv_bin\uv.exe
[INFO] uv-first: Miniconda download skipped.
[INFO] uv: creating venv at .uv_env...
[INFO] uv: venv created at .uv_env
[INFO] HP_ENV_MODE=uv
[BOOT] REQ-009: Selected Python provider: UV.
[INFO] runtime.txt written: python-3.14.6
[INFO] pipreqs 0.4.13 installed successfully; using it for dependency discovery.
*** [WARN] Dependencies were auto-detected (pipreqs)
*** [WARN] Auto-detection may be incomplete or incorrect
*** [INFO] Consider adding requirements.txt or PEP 723 metadata for reliability
[INFO] REQ-005.5: dependency source diff computed -- ~pipreqs.diff.txt
[INFO] REQ-005.12: autopep723 discovery merge complete.
[INFO] UV_USED=1
[INFO] DEP_INSTALLED_CAPTURED=1
[INFO] Environment snapshot written: ~environment.lock.txt
[INFO] REQ-005.11: PEP 723 header write-back succeeded via uv add --script.
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] (A stray one-line Windows message about a missing drive may appear next -- that is a known side effect from an unrelated background process, unrelated to your app; safe to ignore.)
The system cannot find the drive specified.
The system cannot find the drive specified.
[INFO] PyInstaller produced dist\<env>.exe
[DEBUG] warnfix: warn file found
[INFO] warnfix: some modules could not be automatically bundled (full list in ~warnfile.txt / ~setup.log); modules such as posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, and _frozen_importlib_external are expected on Windows and are filtered out automatically.
[INFO] PyInstaller build artifacts cleaned up.
[INFO] EXE smokerun: testing dist\<env>.exe
[INFO] Running entry script smoke test via packaged EXE.
[WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent for about 30 seconds it will be force-stopped, but any output (including a prompt waiting on your input) keeps it running as long as needed. If your program is interactive, try answering its prompts through to its own quit/exit option now so we can confirm it exits cleanly. Either way, do not start real work in it yet or any unsaved work will be lost.
[INFO] Process ID 6076. If it seems stuck: Task Manager > Details tab > find this PID > End Task (this window stays open).
hello-from-stub
[INFO] EXE smokerun: exited 0 (ok)
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
  Run again via the interpreter now? [Y/N] _
```

(the checkpoint prompt line itself is `[Extrapolated Branch]`, same reasoning as Scenario 5 -- it
lives inside an unbounded `set /p`, never visible in a CI log). Declining it (real capture, back to
`hello_stub.py`'s own evidence, timestamps dropped for readability elsewhere in this panel but shown
here to make clear this reconnects to a real, timestamped log), then the optimized-build offer, then
the final panel:

```
[INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: declined.

============================================================
 SETUP COMPLETE
============================================================
 Your standalone application is ready:
   dist\<env>.exe

 RUNNING YOUR APP
   Double-click dist\<env>.exe to run it.
   You can also run it directly via the interpreter at any time:
     ".uv_env\Scripts\python.exe" "hello_stub.py"

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
     run_setup.bat "hello_stub.py" --input file.csv
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

[INFO] REQ-016: Post-flight briefing printed.
```

Real capture (`tests/~selftest_stub/~stub_bootstrap.log`, same run as Scenario 4, `_selftest_stub`/
`hello_stub.py` genericized to `<env>`/kept as `hello_stub.py` respectively, matching the real
capture's own entry filename in the launch-args example line). See Scenario 5 for what accepting
either elective prompt does instead of the decline path shown here.

**Output, `~bootstrap.status.json` (unchanged from Scenario 4's own real capture of the same run):**

```json
{"state":"ok","exitCode":0,"pyFiles":1}
```

### Scenario 33: Full walkthrough -- uv can't resolve a dependency, cascades to conda, which does

**Honesty note up front:** this exact narrow case -- uv fails specifically at DEPENDENCY
RESOLUTION (not environment creation), cascades exactly once, and conda succeeds -- has no single
real capture in this repo's CI history to point to. Scenario 15's own real capture (the fullest
cascade evidence this repo has) walks uv through every tier to full exhaustion in one run, which is
genuinely a harder case to hit than "cascades once and the next tier just works." The pieces below
are real, individually cited fragments; the SPLICE connecting "uv cascades to conda" into "conda
then succeeds and the run completes" is `[Extrapolated Branch]`, reusing this doc's own
already-verified building blocks (the provider-selection log line and the generic build/verify/
complete tail, both provider-agnostic in their wording) rather than inventing new text.

Real trigger (Scenario 15, same wording, same reasoning about why it says "uv to conda" not
"uv -> conda"):

```
[WARN] Repair failed: <package>
[WARN] One or more repair attempts failed
[REPAIR] rebuild complete after warnfix.
[INFO] Entry smoke exit=1
[STATUS] Run Status: FAILED (Exit Code: 1)
[INFO] REQ-009: cascade approved; skipping the post-verification offers for this build.
[INFO] REQ-009: cascading provider uv to conda; re-attempting dependencies.
*** [INFO] Trying the next Python provider (conda) to resolve dependencies...
```

**No real input `app.py` to show here, unlike Scenario 32/34/35/36** -- the narrow case this
scenario illustrates (a package genuinely resolvable via conda-forge but not uv/pip) has no real
test app of its own in this repo; Scenario 15's own real trigger app (`import fake_pkg_cascade_xyz`,
a package name that doesn't exist ANYWHERE) is deliberately unresolvable by every tier alike, which
drives that scenario's full-exhaustion case instead -- it cannot illustrate conda succeeding where
uv failed. **Scenario 44 now provides exactly that real evidence, and considerably more of it**:
`tests/selfapps_layered_e2e.ps1` (`cache` lane, non-gating) uses `pygrib` as its own cascade
trigger (a package with zero Windows wheels on PyPI, but a real conda-forge win-64 build), and its
real captured output shows uv failing, the cascade firing exactly once, and conda succeeding --
plus three further repair mechanisms (warnfix, `--hidden-import` recovery, and native-DLL
bundling) all handing off to each other in the same real run. PyInstaller not discovering
`pygrib`'s native `eccodes.dll` dependency on its own is a real, confirmed-fixed case too: a
dedicated repair loop (`:dll_bundle_recover`) reacts to PyInstaller's own build-time "Library not
found: could not resolve 'X.dll'" warning, confirms the named DLL actually exists under the conda
env's `Library\bin` before acting, and rebuilds with an explicit `--add-binary` flag bundling it
in -- see `docs/agent-interconnect.md`'s "Conda native-DLL bundling repair loop" section for the
full mechanism trace, and Scenario 44 for the real console output showing it fire. This scenario's
own uv-to-conda cascade illustration below remains useful on its own as the simplest possible
version of the mechanism, uncomplicated by the deeper gaps Scenario 44 goes on to expose.

`:cascade_acquire_conda` downloads and installs Miniconda on demand at this point if it wasn't
already on disk (uv-first runs skip Miniconda entirely until something actually needs it -- see
`docs/agent-interconnect.md`'s "uv-First Provider Architecture"), then re-enters the same
dependency-install machinery Scenario 3 already documents in full, just under
`HP_ENV_MODE=conda` this time (`[Extrapolated Branch]` for this specific re-entry's own console
text, though every individual line reused below is independently real elsewhere in this file --
including the "pipreqs (direct) command:" line's own display-only caveat, noted in full there):

```
[BOOT] REQ-009: Selected Python provider: Conda (Portable).
Creating Python environment '<env>' -- this may take several minutes...
[INFO] runtime.txt written: python-3.14.6
[INFO] pipreqs 0.4.13 installed successfully; using it for dependency discovery.
[INFO] pipreqs (direct) command: pipreqs . --force --mode compat --savepath "...\requirements.auto.txt" --ignore ".git,.github,.venv,venv,env,.uv_env,build,dist,__pycache__,tests"
[INFO] DEP_INSTALLED_CAPTURED=1
[INFO] Environment snapshot written: ~environment.lock.txt
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] PyInstaller produced dist\<env>.exe
[INFO] EXE smokerun: testing dist\<env>.exe
[WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent for about 30 seconds it will be force-stopped, but any output (including a prompt waiting on your input) keeps it running as long as needed. If your program is interactive, try answering its prompts through to its own quit/exit option now so we can confirm it exits cleanly. Either way, do not start real work in it yet or any unsaved work will be lost.
[INFO] EXE smokerun: exited 0 (ok)
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
  Run again via the interpreter now? [Y/N] _
```

Declining (same provider-agnostic building blocks as Scenario 32's own ending, `[Extrapolated
Branch]` for this specific re-entry, not a separate real capture) reaches the same final panel:

```
[INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: declined.

============================================================
 SETUP COMPLETE
============================================================
 Your standalone application is ready:
   dist\<env>.exe

 RUNNING YOUR APP
   Double-click dist\<env>.exe to run it.
   You can also run it directly via the interpreter at any time:
     "<python>" "<entry.py>"

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

[INFO] REQ-016: Post-flight briefing printed.
```

The mechanism-level reason conda has a genuine, above-average chance of resolving what uv couldn't
-- a real, different package index with pre-built native-extension wheels, not just a fresh attempt
at the same resolution -- is covered in `docs/agent-interconnect.md`'s "Cascade signal reliability"
section; that section is also why later cascade hops (embed/venv/system) carry comparatively less
of this same justification.

### Scenario 34: Full walkthrough -- warnfix repair and rebuild, start to finish

Splices Scenario 17's real repair-loop fragments with the generic build-start/verify/complete text
already verified real elsewhere in this file (Scenario 4). The connecting tissue (that these two
fragments belong to the same run) is `[Extrapolated Branch]`; every individual line is independently
a real capture cited in its own originating scenario.

**Input, `app.py` (real source, `tests/selfapps_warnfix.ps1`'s default `pass` scenario -- the exact
app that produces the repair-loop capture below):**

```python
import openpyxl
import os as _os
import sys as _sys

wb = openpyxl.Workbook()
wb.active['A1'] = 'warnfix-ok'
wb.save('out.xlsx')
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~warnfix_token.txt'), 'w') as _f:
    _f.write('warnfix-ok\n')
print('wrote out.xlsx')
```

**Test-isolation note, same distinction Scenario 23/36 already make for a different mechanism:**
this specific test sets `HP_SKIP_PIPREQS=1` so `openpyxl` is guaranteed absent when PyInstaller
first runs, isolating warnfix as the sole repair path for this test's own assertions -- production
behavior (pipreqs enabled, no flags) would normally have pipreqs discover and pre-install
`openpyxl` from this same `import openpyxl` line, so warnfix would have nothing to do. Warnfix's
real, unflagged trigger case is a package pipreqs's static scan genuinely cannot see (e.g. a
`pandas.read_excel('legacy.xls')` call, which needs `xlrd` as an invisible runtime engine, never a
direct import pipreqs's AST scan would catch) -- not yet captured in this file with its own
dedicated real test; see `docs/agent-closed-backlog.md`'s Item 22.

**Two lines below (`[INFO] Attempting to install: openpyxl` / `[INFO] Installed: openpyxl`)
updated to reflect current source -- `docs/agent-closed-backlog.md`'s Item 21 added them to the
per-module warnfix repair loop after this capture was originally taken, so install attempts are no
longer silent on success; everything else in this panel is the original, unmodified capture:**

```
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] PyInstaller produced dist\<env>.exe
[DEBUG] warnfix: warn file found
[INFO] warnfix: some modules could not be automatically bundled (full list in ~warnfile.txt / ~setup.log); modules such as posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, and _frozen_importlib_external are expected on Windows and are filtered out automatically.
[REPAIR] missing modules detected; installing and rebuilding.
[INFO] Attempting to install: openpyxl
[INFO] Installed: openpyxl
[REPAIR] rebuild complete after warnfix.
[INFO] PyInstaller build artifacts cleaned up.
[INFO] EXE smokerun: testing dist\<env>.exe
[WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent for about 30 seconds it will be force-stopped, but any output (including a prompt waiting on your input) keeps it running as long as needed. If your program is interactive, try answering its prompts through to its own quit/exit option now so we can confirm it exits cleanly. Either way, do not start real work in it yet or any unsaved work will be lost.
[INFO] EXE smokerun: exited 0 (ok)
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
  Run again via the interpreter now? [Y/N] _
```

Declining (same provider-agnostic building blocks as Scenario 32's own ending) reaches the same
final panel:

```
[INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: declined.

============================================================
 SETUP COMPLETE
============================================================
 Your standalone application is ready:
   dist\<env>.exe

 RUNNING YOUR APP
   Double-click dist\<env>.exe to run it.
   You can also run it directly via the interpreter at any time:
     ".uv_env\Scripts\python.exe" "app.py"

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
     run_setup.bat "app.py" --input file.csv
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

[INFO] REQ-016: Post-flight briefing printed.
```

Note what does NOT appear here: no second "[INFO] Building standalone executable" banner precedes
the repair rebuild -- `[REPAIR] rebuild complete after warnfix.` covers the whole re-invocation,
PyInstaller's own build noise from that second pass is not separately re-echoed. The failure
variant of this same loop (a module that genuinely can't be installed, e.g. `StringIO`) is already
documented in Scenario 17 -- that variant still reaches `[REPAIR] rebuild complete after warnfix.`
(bundling whatever DID install) and is what actually feeds the provider cascade Scenario 33 above
walks through.

### Scenario 35: Full walkthrough -- `--hidden-import` auto-recovery succeeds on the first rebuild

**Honesty note:** Scenario 16 documents this mechanism's EXHAUSTION path with a real captured line;
the one-shot SUCCESS path's exact rebuild line has never been independently console-dumped in this
file, only confirmed present via `self.exe.hidden_import`'s own passing NDJSON row (the same
"test passes, so no full log was dumped" situation Scenario 39 already documents for a different
mechanism) and via the exact line format quoted from source at Scenario 39 (a different context --
Tier A's hidden-import SKIP guard -- but quoting the identical `[REPAIR][HIDDEN_IMPORT]` line
PyInstaller's own recovery path would have printed). This whole console panel is therefore
`[Extrapolated Branch]`, built from source, not a stitch of independently-real fragments the way
Scenario 32/33/34 above are -- but the input files below ARE real, unflagged source (no test
isolation flag involved; pipreqs runs normally here).

**Input, `requirements.txt` and `app.py` (real source, `tests/selfapps_hidden_import.ps1` --
`colorama` is genuinely installed, but imported only via a runtime string, so PyInstaller's static
analysis cannot see the reference and never bundles it):**

```
colorama
```

```python
import importlib
import os as _os
import sys as _sys
_mod = importlib.import_module('colorama')
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~hidden_token.txt'), 'w') as _f:
    _f.write('hidden-ok\n')
print('colorama via importlib ok:', _mod.__name__)
```

```
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] PyInstaller produced dist\<env>.exe
[INFO] PyInstaller build artifacts cleaned up.
[INFO] EXE smokerun: testing dist\<env>.exe
[WARN] Verifying the built standalone EXE (PyInstaller) now: if it stays completely silent for about 30 seconds it will be force-stopped, but any output (including a prompt waiting on your input) keeps it running as long as needed. If your program is interactive, try answering its prompts through to its own quit/exit option now so we can confirm it exits cleanly. Either way, do not start real work in it yet or any unsaved work will be lost.
[WARN] EXE smokerun: exited 1 (non-zero)
[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama --collect-submodules=colorama; rebuilding EXE (iter 1/3).
[INFO] PyInstaller produced dist\<env>.exe
[INFO] EXE smokerun: testing dist\<env>.exe
[INFO] EXE smokerun: exited 0 (ok)
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
  Run again via the interpreter now? [Y/N] _
```

Declining (same provider-agnostic building blocks as Scenario 32's own ending, still
`[Extrapolated Branch]` here since the whole panel is) reaches the same final panel:

```
[INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: declined.

============================================================
 SETUP COMPLETE
============================================================
 Your standalone application is ready:
   dist\<env>.exe

 RUNNING YOUR APP
   Double-click dist\<env>.exe to run it.
   You can also run it directly via the interpreter at any time:
     ".uv_env\Scripts\python.exe" "app.py"

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
     run_setup.bat "app.py" --input file.csv
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

[INFO] REQ-016: Post-flight briefing printed.
```

The gate that makes this rebuild worth attempting at all -- the failure must be a real
`ModuleNotFoundError` (not a bare `ImportError`) for a module that IS installed in the build
interpreter, and the EXE must have been built by PyInstaller, not Tier A's Nuitka fallback -- is
covered in full in `docs/agent-lessons-learned.md`'s "--hidden-import auto-recovery must stay
STRICT" entry; Scenario 16 covers the case where three rebuilds still don't resolve it.

### Scenario 36: Full walkthrough -- `HP_PVW_KNOWN_IDEMPOTENT`, with the actual input and output files

Scenario 23 already covers this flag's console output; this walkthrough adds what that scenario
doesn't show: the actual file contents a user would see before and after. Source: the real,
deterministic stub app `tests/selfapps_pvw_idempotent.ps1` stages for `self.pvw_idempotent.discovery`
(`uv` lane, real, passing) -- quoted directly from the test's own source, not a CI console dump, but
these are the literal bytes that test writes and asserts against.

**Input, `app.py` (the user's only file, before running the bootstrapper at all):**

```python
import requests
print('t2-idempotent-ok')
```

No `requirements.txt`, no `pyproject.toml`, no PEP 723 header -- genuinely nothing else in the
folder besides `run_setup.bat` and this one file (the test isolates pipreqs via `HP_SKIP_PIPREQS=1`
specifically so this is the ONLY way `requests` can end up discovered -- see Scenario 23's own
production-vs-test-isolation note for why that flag is test-only, never how this feature runs for a
real user).

**Console output** (real, `self.pvw_idempotent.discovery`'s own capture, already fully quoted in
Scenario 23 -- repeated here only for continuity with the file changes below):

```
[BOOT] REQ-009: Selected Python provider: UV.
[INFO] REQ-005.13: HP_PVW_KNOWN_IDEMPOTENT set; running entry via uvx autopep723 for execute-mode discovery.
t2-idempotent-ok
[INFO] REQ-005.13: execute-mode discovery run succeeded (RAN:persisted).
```

(`t2-idempotent-ok` is the app's own live stdout, inherited straight through the discovery run --
real NDJSON detail confirms `stdoutPassthroughFound:true`, the exact design point
`tools/pvw_known_idempotent.py` exists to preserve; see `docs/agent-interconnect.md`.) See
Scenario 23 for why this discovery run fires right after provider selection, well before the
entry file is ever announced on screen -- not right after, despite the file changes shown below
happening in the same early pass. That later announcement, from the SAME real capture, comes only
after the entire dependency-install phase finishes:

```
Chosen entry: app.py
[BOOT] REQ-002: Entry selected: app.py
```

**Output, `app.py` (same file, now carrying a PEP 723 header `uv add --script` wrote in place):**
this is the STANDARD shape `uv add --script` is documented to produce (see
`docs/agent-lessons-learned.md`'s "`uv add --script` / PEP 723 empirical behavior" section) --
`[Extrapolated Branch]` for the exact formatting shown, since this specific test doesn't assert
byte-for-byte header content, only that the resulting `requirements.txt` (below) ends up containing
`requests`:

```python
# /// script
# dependencies = [
#     "requests",
# ]
# ///

import requests
print('t2-idempotent-ok')
```

**Output, `requirements.txt` (newly created -- did not exist before this run):** re-extracted from
the header above via the same `:extract_pep723_requirements` subroutine the pre-existing-header case
already uses (see `docs/agent-interconnect.md`'s "HP_PVW_KNOWN_IDEMPOTENT execute-mode discovery"
section for why re-extraction, not the header alone, is what feeds the rest of the pipeline). Real,
directly confirmed: the test's own assertion is `$reqsText -match 'requests'` against this exact
file:

```
requests
```

Production behavior (unlike this test's isolated setup) does NOT stop here -- pipreqs and the
Tier 1 `autopep723 check` merge (Scenario 3) both still run normally afterward, additively layering
on top of whatever this execute-mode pass already found, in case anything conditionally-imported
didn't execute during this one discovery run.

## Part VIII: AV-Safe Build Path (Nuitka fallback)

### Scenario 37: PyInstaller build fails, Tier A (Nuitka) fallback succeeds

**What's tested:** `self.exe.build.tiera` (`tests/selfapps_nuitka_tiera.ps1`, uv lane).
`HP_TEST_FORCE_PYINSTALLER_FAIL=1` forces the primary build to fail deterministically;
the Nuitka fallback (`:try_nuitka_tier_a`) then runs for real -- a genuine compile, not simulated.

**What appears on screen**, from the moment PyInstaller's build is attempted through to the final
summary -- a mix of real CI capture and lines updated to reflect current source, not a single
uniform capture. Real CI capture (run `29788624195`, job `88506013149`): the
"(fallback build system)" verification line and the drive-message reassurance line, exactly as
captured. Updated to reflect current source (`docs/plan-cli-interactive-verification.md`
requirement 3's activity-aware kill, REQ-026's argv passthrough, and `docs/agent-closed-backlog.md`'s
Item 20 postflight briefing change, all of which shipped after this specific run): the "Verifying the
built standalone EXE" line, the "You can also run it directly via the interpreter" line, and the
"Does your program need launch arguments" paragraph. Every other line below is real capture,
unmodified:

```
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] (A stray one-line Windows message about a missing drive may appear next -- that is a known side effect from an unrelated background process, unrelated to your app; safe to ignore.)
The system cannot find the drive specified.
The system cannot find the drive specified.
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
```

**The real trigger of this capture was a CI test hook, not shown above** -- a genuine PyInstaller
build failure at that exact point is completely silent (its own error output goes only to the log
file, never the console); the "Standard build did not complete" line is the first thing a real user
would see, with nothing printed before it. Continuing:

```
============================================================
 SETUP COMPLETE
============================================================
 Your standalone application is ready:
   dist\<env>.exe

 RUNNING YOUR APP
   Double-click dist\<env>.exe to run it.
   You can also run it directly via the interpreter at any time:
     "<python>" "<entry.py>"

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
PyInstaller's. See Scenario 42 for the argv-passthrough paragraph's own dedicated writeup.

---

### Scenario 38: PyInstaller build fails, Tier A fallback ALSO fails (tier exhaustion)

**What's tested:** `self.exe.build.xfail` (`tests/selfapps_pyinstaller_fail.ps1`, real/conda-full
lanes). Three sub-scenarios share one NDJSON row id: `execfail` (the PyInstaller build
command itself fails), `output_vanish` (PyInstaller succeeds, then the output EXE vanishes
immediately -- simulating AV-style post-creation removal), and `execfail_runtimefail` (packaging
fails AND the interpreter fallback that runs next ALSO exits non-zero -- see Scenario 43a for that
one's console text, since it's really a REQ-027 demo). The first two additionally force
`HP_TEST_FORCE_NUITKA_FAIL=1` so the fallback also fails, proving genuine tier exhaustion.

#### 38a. `execfail` -- the PyInstaller build command itself fails

Real CI capture, run `29788624195`, job `88506013028` ("real" lane), with the `[WARN]`-prefixed
message line (CLAUDE.md Active Backlog Item 46, Bucket B -- this call site now routes through
:warn_build_incomplete instead of :die, since every build tool has already failed but the run
itself is not doomed, real verification work still follows) spliced in verbatim from
`run_setup.bat`'s current literal source -- the rest of the block is unmodified real console
output. **This scenario is triggered by two CI test hooks (forcing both the PyInstaller build
and the Nuitka fallback to fail), but a real user hitting the same genuine failure sees nothing
at either trigger point** -- both PyInstaller's and Nuitka's own error output go only to the log
file, never the console:

```
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
[WARN] PyInstaller execution failed; will verify your code directly via Python instead. reason=test_forced_fail
[DEBUG] warnfix: warn file not found
[INFO] PyInstaller build artifacts cleaned up.
[WARN] EXE smokerun: dist\<env>.exe not found; skipping
[INFO] Running entry script smoke test via uv interpreter.
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

[INFO] REQ-018: post-execution checkpoint (interpreter): declined (run footprint stays at one execution).
```

The `reason=test_forced_fail` token (CLAUDE.md Item 33) reflects the actual trigger here -- this
scenario reaches `:warn_build_incomplete` via the `HP_TEST_FORCE_PYINSTALLER_FAIL` test hook,
never a genuine PyInstaller error. A real, unforced build failure would instead read
`reason=build_error` --
`[Extrapolated Branch]`, since no deterministic CI hook forces a genuine nonzero PyInstaller exit
(the same "real trigger, no CI hook" situation as Tier A's own Nuitka compiler-failure hint, Part
VIII above).

When BOTH the PyInstaller build and the Nuitka fallback fail outright but the interpreter
fallback's own run exits 0 (this trivial stub script does), the final line is
`[STATUS] Run Status: SUCCESS (Exit Code: 0)` and the postflight panel is the plain
"YOUR CODE RAN -- BUT NO STANDALONE .EXE WAS PRODUCED" variant -- see Scenario 43a for the
different, honest "we can't confirm" panel this same tier-exhaustion path shows instead when the
interpreter run ALSO fails.

#### 38b. `output_vanish` -- PyInstaller succeeds, then the EXE disappears immediately

Real CI capture, same run/job as 38a, with the same post-capture `reason=` splice described
there. **Unlike the test hooks elsewhere in this file, the
underlying trigger here stands in for a real external event, not a purely internal simulation** --
a real user could hit this exact same gap if antivirus software or a file indexer deletes the
freshly-built EXE in the instant right after PyInstaller creates it. Neither the deletion itself
nor the forced Nuitka failure prints anything on a real user's screen -- there's no bootstrapper
code path that announces either one, so both are omitted below (see 38a's note for the general
"a build-tool failure at this point is silent" rule):

```
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
[WARN] PyInstaller did not produce dist\<env>.exe; will verify your code directly via Python instead. reason=missing_output
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

### Scenario 39: Tier A + hidden-import auto-recovery skip guard

**What's tested:** `self.exe.tiera.hidden_skip` (`tests/selfapps_nuitka_tiera_hidden_skip.ps1`, uv
lane). Forces Tier A to trigger and succeed for real, then has the stub app fabricate
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
[INFO] Standard build did not complete; attempting a fallback build (this may take a minute or two).
[INFO] Fallback build succeeded: dist\<env>.exe was produced using the fallback build system.
[INFO] EXE smokerun: testing dist\<env>.exe
[WARN] EXE smokerun: exited 1 (non-zero)
[INFO][HIDDEN_IMPORT] Skipping --hidden-import auto-recovery: dist\<env>.exe was built via the fallback build system (Nuitka), which uses a different missing-import mechanism than PyInstaller's --hidden-import flag.
```

Without this guard, `run_setup.bat` would instead print
`[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=nuitka --collect-submodules=nuitka; rebuilding EXE (iter 1/3).`
here and attempt a PyInstaller rebuild against a Nuitka-built EXE.

---

### Scenario 40: Requirement 9 -- elective "want an optimized build too?" offer

**What's tested:** `self.optbuild.offer` (`tests/selfapps_optimized_build.ps1`, uv lane),
four scenarios sharing one row id.

**Source:** confirmed in real CI run `29877805447`, uv lane, job `88792048278`, all four scenarios
passing:

```
{"lane":"uv","details":{"log":"~optbuild_accept_bootstrap.log","statusState":"ok","scenario":"accept","successLogged":true,"promptShown":true,"tmpExeGone":true,"exeExists":true,"bootstrapExit":0,"acceptedLogged":true,"appStillRuns":true},"desc":"AV-Safe Build Path requirement 9 (accept): a real optimized build succeeds, verifies, and is swapped into place","req":"REQ-AV","id":"self.optbuild.offer","pass":true}
{"req":"REQ-AV","lane":"uv","desc":"AV-Safe Build Path requirement 9 (forcefail): a failed optimized build leaves the original PyInstaller EXE completely untouched","id":"self.optbuild.offer","details":{"originalStillRuns":true,"bootstrapExit":0,"log":"~optbuild_forcefail_bootstrap.log","tmpExeGone":true,"promptShown":true,"exeExists":true,"testHookFired":true,"scenario":"forcefail","statusState":"ok","noSuccessMsg":true},"pass":true}
{"req":"REQ-AV","id":"self.optbuild.offer","lane":"uv","pass":true,"details":{"bootstrapExit":0,"acceptedLogged":true,"originalStillRuns":true,"log":"~optbuild_swapfail_bootstrap.log","promptShown":true,"exeExists":true,"tmpExeGone":true,"scenario":"swapfail","statusState":"ok","noSuccessMsg":true,"swapFailLogged":true},"desc":"AV-Safe Build Path requirement 9 (swapfail): a verified optimized build whose final swap fails leaves the original PyInstaller EXE completely untouched and cleans up the leftover temp file"}
{"desc":"AV-Safe Build Path requirement 9 (decline): default/CI path shows the prompt but never attempts a build","lane":"uv","details":{"statusState":"ok","noBuildAttempt":true,"tmpExeGone":true,"scenario":"decline","log":"~optbuild_decline_bootstrap.log","bootstrapExit":0,"exeExists":true,"declinedLogged":true,"promptShown":true},"req":"REQ-AV","id":"self.optbuild.offer","pass":true}
```

#### 40a. `accept` -- a real optimized build succeeds and is swapped in

Real CI capture (`~selftest_optbuild_accept\~optbuild_accept_bootstrap.log`) with one line updated
in place to reflect current source: the "Verifying the built standalone EXE" line now shows
requirement 3's activity-aware kill plus the quit-prompt hint, both of which shipped after this
capture -- every other line below is exactly as captured:

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

The "warnfix: Platform-specific modules..." line above is this specific capture's own pre-existing
wording (not updated, unlike the line noted above); current wording for that same line is shown in
Scenario 34.

**The interactive `Build the optimized version now? [Y/N]` prompt line is echoed unconditionally
by design** (same pattern as `:run_postexec_checkpoint`), but does not appear literally in any
CI capture -- CI answers via the `HP_TEST_OPTBUILD_ANSWER` env-var override, not the interactive
`set /p` path, so only the resolution lines (`accepted`/`declined`) show up in these logs. This is
expected (CI is non-interactive by design), not a gap.

#### 40b. `forcefail` -- accepted, but the build fails; original EXE is left untouched

Triggered by a CI test hook (`HP_TEST_FORCE_OPTBUILD_FAIL`) forcing the build itself to fail, but
unlike the silent build failures elsewhere in this Part, a REAL failure here is NOT silent -- every
genuine failure branch in `:offer_optimized_build` (tool-install failure, build-did-not-complete,
missing output, verification failure, swap failure) logs its own `[WARN] ...; your app is still
ready to use as-is.` line before reaching the post-flight briefing. What a real user sees (the
`[WARN]` line is `[Extrapolated Branch]`, from source -- the exact wording depends on which of the
five failure branches fired; the rest of this capture is real,
`~selftest_optbuild_forcefail\~optbuild_forcefail_bootstrap.log`):

```
*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: accepted; building now (this may take a minute or two).
[WARN] Optimized build did not complete; your app is still ready to use as-is.
[INFO] REQ-016: Post-flight briefing printed.
```

#### 40c. `swapfail` -- verified build, but the final swap step fails; original EXE is left untouched

Regression test for a real bug: the swap-verification check used to test the DESTINATION file
(which already exists before the move, success or failure alike) instead of the SOURCE (which
should be gone only on success) -- a genuinely failed swap would have been silently misreported
as success. Fixed; console text (expected from source, not yet dumped in a CI console capture
since this scenario has passed on every run so far):

```
*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: accepted; building now (this may take a minute or two).
[WARN] Optimized build verified successfully but could not be swapped into place; your app is still ready to use as-is.
```

#### 40d. `decline` -- default/CI path, prompt shown but nothing built

Real, verbatim console dump (`~selftest_optbuild_decline\~optbuild_decline_bootstrap.log`):

```
*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: declined.
[INFO] REQ-016: Post-flight briefing printed.
```

#### Reactive-only failure hint (both Tier A and requirement 9's real-build-failure paths)

Fires on either of two genuine failure conditions -- a real Nuitka compiler failure, or Nuitka
reporting success while never actually producing `dist\<env>.exe` -- and never on the
`forcefail`/`HP_TEST_FORCE_NUITKA_FAIL` test hooks, which bypass it entirely. No CI run to date has
exercised either genuine failure, so this is sourced from `run_setup.bat` rather than a console
capture -- both call sites below are this exact deterministic literal text, not an approximation.

**Tier A (`:try_nuitka_tier_a`)** -- the AV-Safe Build Path fallback that runs when the ORIGINAL
PyInstaller build has already failed. A genuine Nuitka failure here means every build tool tried
has now failed:

```
[WARN] Fallback build did not complete successfully.
[WARN] Hint: if you have Visual Studio 2022 (or newer) with the 'Desktop development with C++' workload installed, this fallback should use it automatically -- no extra setup needed. If not, installing the free Visual Studio Build Tools with that workload can help this fallback succeed.
```

A second, distinct trigger inside the same subroutine -- Nuitka reports success but never actually
produces `dist\<env>.exe` -- gets the identical hint after a different first line:

```
[WARN] Fallback build finished but did not produce dist\<env>.exe.
```

**Requirement 9 (`:offer_optimized_build`)** -- a much lower-stakes case: PyInstaller already
succeeded and the user's app is already working; this only fires if the user explicitly opted into
building an OPTIONAL, faster/more-reliable Nuitka version on top of an already-working build:

```
[WARN] Optimized build did not complete; your app is still ready to use as-is.
[WARN] Hint: if you have Visual Studio 2022 (or newer) with the 'Desktop development with C++' workload installed, this should use it automatically -- no extra setup needed. If not, installing the free Visual Studio Build Tools with that workload can help.
```

---

## Part IX: CLI interactivity, argv passthrough & honest messaging

Covers `docs/plan-cli-interactive-verification.md` (P0/P1/P2, all shipped): the live-tee
verification redesign that lets an interactive `input()`-driven program's prompts actually reach
the console, the activity-aware 30-second kill, argv passthrough (REQ-026), and the honest
ambiguous-exit messaging panels (REQ-027).

### Scenario 41: Interactive verification -- live-tee, activity-aware kill, and the quit-prompt hint

**What changed, in one sentence:** before this plan, `:run_exe_smokerun`'s verification launch
force-killed at a hard 30 seconds regardless of output, and captured stdout/stderr only to a file
(never live to the console) -- so a program correctly waiting on its first `input()` prompt looked
identical to a genuinely hung one, and the user watching the window saw nothing until the process
either finished or got killed.

**What's tested (the plumbing):** `self.interactive.stdin.roundtrip`
(`tests/selfapps_interactive_stdin.ps1`, uv lane) builds a real PyInstaller EXE from a
multi-round `input()`-driven stub app and pipes a scripted answer sequence into `cmd.exe`'s own
stdin, exercising the full `cmd.exe -> :run_exe_smokerun -> ~exe_smokerun.ps1 -> the built EXE`
chain and asserting each answer lands in the right round via ordering checks on the captured log
-- it proves the plumbing doesn't drop or reorder stdin/stdout, not a live human's own typing
timing (which can't be automated).

**The WARN line a user sees right before the verification launch**, current shipped wording
(source: `run_setup.bat`, `:warn_user_code_launch` -- not a console capture, since CI answers
scripted stdin rather than a human watching the window; Scenario 40a above shows this exact line in
situ too, though there it is the one line explicitly edited into that capture to match current
source, not part of that scenario's own real-captured text; Scenario 37 shows the same line's
"(fallback build system)" variant instead of "(PyInstaller)"):

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
   of Scenario 43's ambiguous-exit panels.
3. **Still warns it's a throwaway pass, not the user's real, saveable session** -- this verification
   EXE is never reused; only the file it's already tested is kept for later double-clicks.

**Two more real lines belong to the SAME live-tee mechanism** and are already confirmed as genuine,
working console output (not just source text) in an earlier real capture -- run `30328748330`, job
`90179708091` ("real" lane), `tests/~selftest_stub/~stub_bootstrap.log`:

```
[INFO] Process ID 6076. If it seems stuck: Task Manager > Details tab > find this PID > End Task (this window stays open).
hello-from-stub
```

The PID line is `tools/exe_smokerun.ps1`'s own stuck-program recovery aid (see
`docs/agent-interconnect.md`'s "Process-ID display for stuck-program recovery" section), printed
right after the verification process starts. `hello-from-stub` is that real run's own stub
program's live stdout, teed through the SAME chunk-based `ReadAsync` reader landing exactly between
the PID line and the eventual `EXE smokerun: exited 0 (ok)` line -- precisely where a real user's
own program output appears, live, as it happens, not buffered until the process exits.

The `hidden_import` recovery loop's own separate, narrower verification check (see README.md's
"Verifying a fresh build is activity-aware and announced" bullet, which calls this exact exception
out directly) deliberately keeps the OLDER, unconditional 30-second wording -- it's a bounded
repair-verification check on an already-built EXE, not the user's primary run, so it never got the
interactive-friendly rewrite. Same subroutine (`:warn_user_code_launch`), same PyInstaller-vs-Nuitka
variant split, but a genuinely different, still-unconditional message (the `hidden_import`-site
branch's own literal source text):

```
[WARN] Verifying the built standalone EXE (fallback build system) now: it is force-stopped after about 30 seconds even if running perfectly, so do not start real work in it yet or any unsaved work will be lost.
[WARN] Verifying the built standalone EXE (PyInstaller) now: it is force-stopped after about 30 seconds even if running perfectly, so do not start real work in it yet or any unsaved work will be lost.
```

Note what's missing compared to the main-run wording above: no mention of output extending the
wait, no guidance toward the program's own quit/exit option -- a real interactive program hitting
this check during hidden-import recovery is still force-stopped at 30 seconds flat, output or not.

### Scenario 42: Argv passthrough (REQ-026) -- launch arguments through the bootstrapper

Extra arguments after the entry file on `run_setup.bat`'s own command line (up to 8) are forwarded
verbatim to the target program at every real launch site -- the cached-EXE fast path, the fresh EXE
verification, the no-EXE interpreter run, and the post-execution checkpoint's elective second run.
This is a documented, opt-in escape hatch (no detection or heuristics involved) for a program that
needs `--flag value`-style launch arguments to run correctly, on top of this bootstrapper's usual
zero-argument double-click flow.

**The postflight guidance a user sees after a successful EXE build** (Scenario 37's full panel
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
Scenario 43a's panel below):

```
   Need launch arguments? Add them directly after that command, e.g.
     "<python>" "<entry.py>" --input file.csv
```

Both are additive to the launch commands already shown in each panel, not a separate prompt --
matching this bootstrapper's general rule that env-var/CLI flags only ever add an opt-in path or
suppress an optional step, never gate a behavior the Prime Directive needs (see CLAUDE.md's
`[REQ-019]`).

### Scenario 43: Honest ambiguous-exit messaging (REQ-027)

Both panels below fire only when a verification run ends AMBIGUOUSLY -- the program exited with an
error, and no automatic repair (`--hidden-import` auto-recovery, the REQ-009 dependency-resolution
cascade) fixed it. Neither panel claims to know WHY: a bug in the program's own code, something
this bootstrapper missed, or an unresolved dependency are all indistinguishable from here, and both
panels say so plainly rather than guessing. This is messaging only -- `~bootstrap.status.json`
semantics, the process exit code, and consent-gate behavior are all unchanged.

Both are new enough (shipped, then refined once more for wording, entirely within this same
session) that no CI run has yet produced a console capture including the current wording -- both
quotes below are sourced directly from `run_setup.bat`, not a job log.

#### 43a. No-EXE path, interpreter also failed

Fires when BOTH PyInstaller and the Nuitka fallback fail to package the app outright, AND the
interpreter fallback that runs next (the only way left to run the program at all) also exits
non-zero -- the scenario Scenario 38a's own `execfail` sub-case would hit if its trivial stub script
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
is reliably set by this point in the pipeline -- unlike Scenario 43b below).

When the interpreter run instead exits CLEANLY (the common case, and what Scenario 38a's own capture
shows), this panel's header and opening paragraph read differently -- plain "YOUR CODE RAN -- BUT
NO STANDALONE .EXE WAS PRODUCED", with no claim of an unconfirmed run -- but the rest of the panel
(launch commands, KEEP/SAFE TO DELETE lists) is identical either way.

#### 43b. Cached-EXE fast path, kept despite a non-zero exit

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
deliberately zero-friction for prompts (see README.md's "Fast path is the user's run
(frictionless)" bullet), and this doesn't violate that since it never asks a question.

**No entry filename appears anywhere in this panel, unlike 7a's rerun mention -- deliberately.**
`HP_ENTRY` is not set yet at the point the top-of-file fast path runs (it fires before
`:determine_entry` ever executes, since the cached EXE is self-contained and doesn't need the
original source filename to relaunch), so naming one here would show blank or stale text. The two
rerun options are worded to distinguish a genuinely different tradeoff instead: rerunning WITHOUT
deleting the EXE reuses it (via the same fast path that got the user here) with no promise about
whether it's actually faster overall, while deleting it first forces a full, slower, from-scratch
dependency check.

---

## Part X: Confirmed layered multi-mechanism recovery chain (real E2E evidence)

### Scenario 44: Full walkthrough -- cascade, warnfix, hidden-import recovery, and native-DLL bundling, all in one real run

**What's tested:** `self.layered_e2e.chain` (`tests/selfapps_layered_e2e.ps1`, `cache` lane,
non-gating). A single real app whose three declared dependencies (`pygrib`, `xlrd`, `colorama`)
happen to trigger four separate, independently-documented repair mechanisms (Scenarios 15, 17, 16,
and the native-DLL bundling loop covered in `docs/agent-interconnect.md`) back to back in one
continuous run, with no test-only failure injection anywhere in the chain -- every failure below is
a genuine consequence of what these three packages actually need on Windows.

**Source:** REAL CI CAPTURE, run `31264219121`, job `93119869344` (`cache` lane).

The run starts under uv (the default first provider), installs cleanly detected dependencies, then
hits its first real gap -- `pygrib` has no Windows wheel on PyPI:

```
[BOOT] REQ-009: Selected Python provider: UV.
[INFO] runtime.txt written: python-3.14.7
[INFO] pipreqs 0.4.13 installed successfully; using it for dependency discovery.
[WARN] uv pip install -r requirements.txt failed; some packages may be missing.
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] PyInstaller produced dist\_selftest_layered_e2e.exe
[INFO] warnfix: some modules could not be automatically bundled (full list in ~warnfile.txt / ~setup.log); modules such as posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, and _frozen_importlib_external are expected on Windows and are filtered out automatically; cStringIO and StringIO (Python-2-only compatibility shims some packages still reference) are filtered out automatically too.
[REPAIR] missing modules detected; installing and rebuilding.
[INFO] Attempting to install: xlrd
[INFO] Installed: xlrd
[INFO] Attempting to install: pygrib
[WARN] Repair failed: pygrib
[WARN] One or more repair attempts failed
[INFO] Rebuilding standalone executable after warnfix -- this may take a minute or two...
[REPAIR] rebuild complete after warnfix.
```

Warnfix (Scenario 17) genuinely fixed `xlrd` in the same round it genuinely failed on `pygrib` --
both outcomes are real, not staged. With one dependency still unresolved under uv, the cascade
(Scenario 15) offers, and is accepted -- but the CURRENT (still uv-built) EXE is verified once more
before the cascade actually switches providers, and it fails exactly as expected on the package
warnfix never resolved:

```
[WARN] REQ-009: warnfix left modules unresolved under provider uv.
[INFO] REQ-009: cascade candidate detected.

*** Some dependencies could not be installed under the current Python provider. ***

[INFO] REQ-009: cascade consent: accepted.
[INFO] REQ-009: cascade approved; will re-attempt under the next provider tier.
[INFO] EXE smokerun: testing dist\_selftest_layered_e2e.exe
ModuleNotFoundError: No module named 'pygrib'
[WARN] EXE smokerun: exited 1 (non-zero)
[HINT][HIDDEN_IMPORT] Hidden import likely missing: pygrib
[INFO] Entry smoke exit=1
[STATUS] Run Status: FAILED (Exit Code: 1)
[INFO] REQ-009: cascading provider uv to conda; re-attempting dependencies.
*** [INFO] Trying the next Python provider (conda) to resolve dependencies...
```

That `[HINT][HIDDEN_IMPORT]` line is the always-on diagnostic hint (`:exe_smokerun_hints`), not the
strict `--hidden-import` auto-recovery loop (Scenario 16) actually firing -- `pygrib` was never
successfully installed under uv (the warnfix repair attempt for it genuinely failed, above), and
that loop's own gate requires the target module to be genuinely installed in the build interpreter
before it will act (see "--hidden-import auto-recovery must stay STRICT" in
`docs/agent-lessons-learned.md`). It correctly declines here and lets the cascade handle it instead.

Conda-forge genuinely has a real Windows build of `pygrib` uv/PyPI don't -- the second dependency
install succeeds cleanly this time, and the bootstrapper rebuilds. But `pygrib`'s conda build
depends on a native library (`eccodes.dll`) that PyInstaller's own static analysis bundles the
compiled Python extension for, without ever discovering the separate DLL it links against -- the
native-DLL bundling loop reacts to PyInstaller's own build-time warning about this, catching it
BEFORE the rebuilt EXE is ever run for the first time under conda:

```
[BOOT] REQ-009: Selected Python provider: Conda (Portable).
[INFO] runtime.txt written: python-3.14.6
[INFO] pipreqs 0.4.13 installed successfully; using it for dependency discovery.
[INFO] Building standalone executable -- this may take a minute or two...
[INFO] PyInstaller produced dist\_selftest_layered_e2e.exe
[INFO] warnfix: some modules could not be automatically bundled (full list in ~warnfile.txt / ~setup.log); modules such as posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, and _frozen_importlib_external are expected on Windows and are filtered out automatically; cStringIO and StringIO (Python-2-only compatibility shims some packages still reference) are filtered out automatically too.
[REPAIR][DLL_BUNDLE] Bundling native DLL dependency: eccodes.dll (found at C:\Users\Public\Documents\Miniconda3\envs\_selftest_layered_e2e\Library\bin\eccodes.dll); rebuilding EXE (iter 1/3).
[REPAIR][DLL_BUNDLE] Native-DLL bundling complete (1 DLL(s) added); EXE will be re-verified next.
```

Bundling the DLL fixes `pygrib`'s own loading problem, but the FIRST time this rebuilt EXE actually
runs under conda, it exposes a SECOND, deeper gap: `pygrib`'s own compiled extension needs `numpy`,
invisible to PyInstaller's static scan the same way `pygrib` itself was under uv -- `--hidden-import`
auto-recovery (Scenario 16) reacts, and while fixing that, one of `pygrib`'s OWN submodules (pulled
in by the fix's own `--collect-submodules` pairing) turns out to need `pyproj`, which needs a SECOND
native DLL (`proj_9.dll`) never checked before this exact rebuild -- the bootstrapper's repair loops
hand off to each other across three more rounds, each a real, unstaged rebuild:

```
[INFO] EXE smokerun: testing dist\_selftest_layered_e2e.exe
ModuleNotFoundError: No module named 'numpy'
[WARN] EXE smokerun: exited 1 (non-zero)
[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=numpy --collect-submodules=numpy; rebuilding EXE (iter 1/3).
[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=pyproj --collect-submodules=pyproj; rebuilding EXE (iter 2/3).
[REPAIR][DLL_BUNDLE] Bundling native DLL dependency: proj_9.dll (found at C:\Users\Public\Documents\Miniconda3\envs\_selftest_layered_e2e\Library\bin\proj_9.dll); rebuilding EXE (iter 1/3).
[REPAIR][DLL_BUNDLE] Native-DLL bundling complete (1 DLL(s) added); EXE will be re-verified next.
[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama --collect-submodules=colorama; rebuilding EXE (iter 1/3).
[REPAIR][HIDDEN_IMPORT] EXE verified after hidden-import recovery.
```

That last line -- `colorama` -- is the third declared dependency, imported only via
`importlib.import_module` in this app's own source, so it was never visible to PyInstaller's
static analysis until the `pyproj`/DLL fix let the app get far enough to actually hit that import.
With every gap now resolved, the EXE finally verifies clean and the run completes normally:

```
[INFO] EXE smokerun: exited 0 (ok)
[INFO] Entry smoke exit=0
[STATUS] Run Status: SUCCESS (Exit Code: 0)

*** Verification finished -- see the Run Status above. ***
*** You can run your program again now via the interpreter as an extra diagnostic check. ***
[INFO] REQ-018: post-execution checkpoint (exe): declined (run footprint stays at one execution).

*** Your app is ready. ***
*** Want to build an optimized version too? It takes a bit longer to build right now, ***
*** but it starts up more reliably on Windows and runs faster once it is built. ***
[INFO] Optimized build: declined.

============================================================
 SETUP COMPLETE
============================================================
 Your standalone application is ready:
   dist\_selftest_layered_e2e.exe

 RUNNING YOUR APP
   Double-click dist\_selftest_layered_e2e.exe to run it.
   You can also run it directly via the interpreter at any time:
     "C:\Users\Public\Documents\Miniconda3\envs\_selftest_layered_e2e\python.exe" "app.py"
```

**Why this run matters beyond any single mechanism**: every other scenario in this document proves
ONE repair mechanism works in isolation. This is the only real capture in this repo's CI history
showing all four -- provider cascade, warnfix, `--hidden-import` recovery, and native-DLL
bundling -- genuinely handing off to each other within a single bootstrap run, each one's own fix
exposing the next real gap underneath it, exactly the way a beginner's own unpredictable dependency
tree could in practice. A user hitting this exact chain would see roughly nine total rebuild
attempts across two Python providers over about ten minutes of unattended waiting, then a normal
"SETUP COMPLETE" panel with no indication anything unusual happened -- everything above the final
panel is diagnostic detail this document surfaces for review, not something a real user needs to
read or understand.

---
