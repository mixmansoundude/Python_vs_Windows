# Agent Cold Storage -- Python_vs_Windows

**This file is NOT auto-loaded into every session's context** (unlike
`docs/agent-lessons-learned.md` and `docs/agent-interconnect.md`, which CLAUDE.md's own
`@import` lines pull in automatically). Read it on demand: when CLAUDE.md's own pointer below
sends you here, or when you're about to propose something that might already be a deliberately-
shelved idea worth checking against first.

Moved out of `CLAUDE.md` directly (2026-07-31) specifically to reduce that file's per-session
context footprint -- CLAUDE.md is loaded in full every session, so keeping reference-only
material (ideas gated on a trigger that hasn't fired, not something any session needs to act on
by default) here instead measurably shrinks that footprint without losing the content. See
CLAUDE.md's own "Cold Storage" pointer for the one-paragraph scope summary.

---

## Cold Storage (promising ideas, deliberately shelved -- revisit only if a named trigger fires)

**Scope, and how this differs from Active Backlog and Known Findings**: an Active Backlog item is
work this repo intends to get to eventually, with no special precondition beyond bandwidth. A
Known Finding is a settled decision with genuinely no action ever planned. This section is a
third category: a real, technically-sound idea that is NOT being pursued right now, gated on one
or more SPECIFIC, checkable triggers -- not "eventually," not "never," but "only if X happens."
2026-07-26 owner instruction: park these here (rather than either of the other two sections) so
they stay visible without implying either imminent work or a closed door, and thaw one only when
its own named trigger genuinely fires -- do not speculatively build any of these ahead of that.

- **Total build-attempt budget cap across nested repair loops** (hidden-import recovery x
  DLL-bundle recovery x REQ-009 provider-cascade tiers, each with its own iteration cap that
  compounds with the others -- see CLAUDE.md's closed Active Backlog Item 45 and still-open Item 46
  discussion for the no-`HP_PY` case this overlaps with). Raised during a 2026-08-14 real Windows
  Sandbox debugging session as a theoretical concern (many PyInstaller invocations possible in the
  worst case with no single circuit breaker), not a confirmed problem -- the individual loops are
  each already capped
  and this repo's own history with them (CLAUDE.md's DLL-bundling/hidden-import interconnect
  entries) shows real, hard-won caution about touching them without strong justification. **Trigger
  to thaw**: a real CI run or user report showing the repair-loop product actually causing a
  meaningfully long hang or wasted build time, not just the theoretical worst case being
  mathematically possible.

- **Binary presence guards beyond PowerShell** (curl, findstr, robocopy, fc, reg, timeout, ping,
  more, sort, expand, tar). Only `choice.exe` and, as of the 2026-08-14 line-ending self-check
  (CLAUDE.md's former Active Backlog Item 44), `powershell` are checked for presence before use;
  every other external binary this bootstrapper depends on fails as an opaque errorlevel if absent.
  Not pursued now: all of these are core Windows components present by default on any Windows 10+
  install this bootstrapper already targets, so the realistic trigger rate is low relative to the
  PowerShell case (which has a real, known restriction mechanism -- Constrained Language Mode --
  that these do not). **Trigger to thaw**: a real user report of a missing-binary failure on one of
  these specific tools, not a speculative preemptive sweep.

- **PYSPEC-aware venv-vs-embed decision function.** `:try_venv_fallback` currently uses whatever
  ambient Python is on the machine unconditionally, with no check of whether it actually
  satisfies `PYSPEC` (the same value `~detect_python.py` already computes for uv/conda/embed).
  This means the current linear order (embed before venv) always pays embed's network cost even
  in the common case where the ambient Python already satisfies the pin and venv would have been
  strictly better (instant, no network dependency, no extra disk). The flip side also matters:
  embed is reached immediately after conda, so by the time it's attempted, uv and conda have
  already both failed -- and since all three of uv/conda/embed need network, embed is
  disproportionately likely to fail for the *same* underlying reason (see the README's REQ-009
  failure-causes table), making it a low-odds attempt in exactly the scenario where it's tried. A
  smarter design would check "does the ambient Python (if any) already satisfy PYSPEC?" and
  prefer venv when yes, falling to embed only when the ambient Python is absent or
  version-mismatched -- turning the fixed uv/conda/embed/venv/system chain into
  uv/conda/(venv-if-it-already-satisfies-PYSPEC, else embed)/system. Not pursued now: it changes
  `:try_venv_fallback`'s dispatch shape (must read `PYSPEC` before deciding, not just on
  creation), and the current fixed order is not wrong, just not optimal in either direction.
  **Trigger to thaw**: the network-correlated-embed-failure pattern this item predicts shows up
  for real, in CI or in an actual user report -- not a speculative build ahead of that evidence.
  **Re-examined 2026-07-25 per an owner request to raise confidence-to-implement wherever
  possible**: this was never actually a confidence question -- the design sketch above is sound
  and could be implemented with reasonable confidence in its own correctness. What was missing is
  evidence that it's WORTH the added complexity; raising implementation confidence doesn't
  manufacture that evidence, which is exactly why this belongs in Cold Storage rather than Active
  Backlog -- the blocker is the trigger, not readiness to build.

- **AV-Safe Build Path Tier B (reprovisioned pinned-3.12 environment).** Full PRD at
  `docs/prd-av-safe-build-path.md`; Tier A (real Nuitka fallback build in the existing
  environment) and requirement 9 (the elective "optimized build?" upsell) are both SHIPPED --
  see their own dedicated Closed Backlog entries -- and remain the complete, working AV-quarantine
  mitigation this repo ships today. Tier B was the PRD's second tier: a reprovisioned environment
  pinned to Python 3.12 specifically to route around Nuitka's MinGW64 backend not supporting
  Python 3.13+ (Finding 1 in the PRD, last re-confirmed unresolved as of Nuitka 4.1.2 in the
  2026-07-20 downtime re-check). Building it means a second provider-chain traversal, a
  pinned-version environment, and the stale-PATH/`VIRTUAL_ENV` hazard research Finding 6 already
  flagged -- real complexity with no user-observed need yet (the PRD itself notes it as
  preemptive, "no real user report yet, a documented industry-wide problem").
  **Trigger to thaw, two and only two conditions**: (a) the owner personally hits a real
  PyInstaller AV-quarantine failure that Tier A does not already resolve, giving the reprovision
  complexity a concrete justification instead of a speculative one; or (b) Nuitka's own upstream
  MinGW64 backend gains Python 3.13+ support, which would remove the entire reason Tier B needs a
  narrow version pin in the first place -- at that point Tier B's whole design would need
  re-evaluating (it might not need a pin at all anymore), not just a version bump. Condition (b)
  is exactly what the "Next-pin probe concept" section (under Periodic Maintenance Checks) already
  tracks quarterly for any future pin justified by one specific, checkable fact -- re-check that
  same fact each scan (Nuitka's MinGW64 Python-version support), not a generic "try a newer
  Nuitka" probe. If either condition fires, read the PRD's own "Notes from Claude" section before
  restarting Tier B -- it has the original reasoning plus a deliberately blunt writeup of why
  Tier B's narrow, well-justified 3.12 pin should **never** be generalized into a
  bootstrapper-wide "stay a version or two behind latest" default (this repo has no telemetry or
  auto-update mechanism, so any such pin freezes permanently into every already-distributed copy
  of `run_setup.bat`). Requirements 6 (loop avoidance) and 8 (connectivity check before Tier B)
  depend on Tier B existing and thaw with it, for the same reason.

- **pipreqs internalization (clean-room AST-based scanner + mapping table, replacing pipreqs as
  the primary dependency-discovery tool).** pipreqs (bndr/pipreqs) is stagnant (maintenance-only,
  looking for maintainers) but not at risk of disappearing from PyPI outright -- PyPI does not
  delete established packages. The real risk the community cites is future-Python bitrot (an AST
  parser silently failing on new syntax), which this repo has already pre-empted twice over: the
  0.4.13 pin (see "pipreqs pin rationale" above) avoids 0.5.0's `<3.13` Requires-Python ceiling,
  and the warnfix build-time safety net (see "Dependency Discovery Fallback: warnfix" above) means
  the bootstrap **never hard-fails** even if pipreqs is 100% unavailable -- confirmed by
  `self.stub.pipreqs_version_fail` (Closed Backlog), which forces pipreqs's own install to fail via
  `HP_PIPREQS_VERSION=99.99.99` (already an env-overridable variable, no code change needed to
  trigger this) and proves the bootstrap still reaches a working, fully-run EXE via warnfix alone.
  It is technically feasible and roughly the size a 3rd-party estimate suggested (a few hundred
  lines + a small mapping table), but it duplicates a safety net that already works and is tested,
  and is its own nontrivial project (matching pipreqs's accumulated edge-case handling: encoding
  fallback, syntax-error tolerance, stdlib filtering).
  **Trigger to thaw**: a real user run (not just CI) hits a pipreqs failure the warnfix safety net
  doesn't cleanly cover, OR pipreqs is genuinely removed from PyPI, OR the quarterly "next-pin
  probe" (Periodic Maintenance Checks, "pipreqs ecosystem status") finds pipreqs's own
  Requires-Python ceiling has moved in a way that reopens the future-Python-bitrot risk this
  section exists to track. A one-off CI observation is not enough on its own -- this needs a
  signal from how the tool behaves for a real user, or a concrete ecosystem change.
  **When it is eventually undertaken**: write a **clean-room** scanner rather than copying
  pipreqs's actual source or mapping file (pipreqs is MIT-licensed; copying it verbatim would
  require carrying its copyright notice -- a clean-room reimplementation sidesteps this entirely,
  though crediting pipreqs by name/link as prior art in a code comment is a fair courtesy). Seed
  the mapping table by extending this repo's own already-license-clear `tools/parse_warn.py`
  `TRANSLATIONS` dict rather than importing external mapping databases (showmereqs/FawltyDeps/
  marimo/Grayskull all carry their own licenses needing separate audit, and none of those tables
  have been vetted against this repo's actual needs). Use `sys.stdlib_module_names` with a
  `try/except ImportError` guard per the existing "Embedded-helper Python baseline" convention
  (it's a 3.10+ feature; must degrade gracefully on an older ambient interpreter on the
  venv/system fallback tiers). Do not chase alternative tools as a wholesale replacement: `pigar`
  was correctly ruled out elsewhere (its wheel bundles an ~40 MB SQLite package database, a
  non-starter for a single-file bootstrapper).

- **Conda native-DLL bundling repair loop (CLAUDE.md Active Backlog Item 24) -- THAWED 2026-08-04,
  no longer cold-storaged.** The owner explicitly brought this forward the same day (see
  `docs/prd-conda-native-dll-bundling.md`'s now-updated Finding 1/6 and Confidence Assessment for
  the research completed since the original draft). Active implementation is now tracked directly
  under CLAUDE.md's Active Backlog Item 24, not here -- this entry is kept only as a historical
  record of the original shelve-and-thaw-trigger reasoning; see Item 24 itself for current status.

- **Blinter in the sanity sweep, scoped to a vetted rule subset.** Investigated 2026-08-04 --
  current evidence (false-positive detail, rule counts) lives in AGENTS.md's own Blinter entry;
  not duplicated here to avoid drift between the two. Proposal: a scoped, per-rule-audited
  `blinter.ini` allowlist, mirroring how the sanity sweep already scopes markdownlint to MD029
  only, rather than running Blinter's full default rule set. **Trigger to thaw**: someone does
  the actual per-rule audit described in AGENTS.md and confirms a scoped allowlist produces ZERO
  findings against the current, already-clean `run_setup.bat`. Not worth doing speculatively
  ahead of that audit.

- **PSScriptAnalyzer in the sanity sweep, scoped to a vetted rule subset.** Investigated
  2026-08-04 -- current evidence (finding counts, which rules fire against this repo's own
  deliberate conventions) lives in AGENTS.md's own PSScriptAnalyzer entry, which also corrects a
  stale "PSGallery blocked by proxy" note this same investigation disproved; not duplicated here
  to avoid drift. Proposal: a `PSScriptAnalyzerSettings.psd1` excluding the rules AGENTS.md
  identifies as firing against established repo conventions, wired into
  `tools/run_sanity_sweep.sh`. Somewhat more promising than Blinter (per AGENTS.md, a smaller
  false-positive surface concentrated in fewer rules), but the same principle applies. **Trigger
  to thaw**: someone builds that settings file, confirms a full sweep against the current codebase
  comes back clean. Not worth doing speculatively ahead of that audit.

- **Force UTF-8 console encoding for the user's own launched process (`PYTHONUTF8=1` /
  `PYTHONIOENCODING=utf-8`).** Found via a 2026-08-08 third-party-analysis pass (a generic
  50-scenario "getting Python running on Windows" guide, cross-checked against this repo's own
  coverage): confirmed via grep that `run_setup.bat` sets neither `PYTHONUTF8` nor
  `PYTHONIOENCODING` anywhere, so a script printing non-ASCII text (accented characters, emoji, a
  degree symbol) can still hit `UnicodeEncodeError` or print garbled text under Windows' legacy
  console code page, exactly as it would for a fully manual setup -- one of the few genuinely
  common beginner gotchas this bootstrapper does nothing for today, despite otherwise
  systematically removing PATH/interpreter/dependency friction. Proposal: set
  `PYTHONUTF8=1` (Python 3.7+, forces UTF-8 mode process-wide) on every launch of the user's own
  code (build verification, EXE smoke run, direct interpreter run) -- a single environment
  variable at each launch site, no `run_setup.bat` architecture change. **Trigger to thaw**: a
  dedicated investigation confirming this has no unwanted side effect on any existing test's
  output-matching assertions (several tests grep captured stdout/stderr for exact strings; UTF-8
  mode is very unlikely to change ASCII-only output but this needs verifying, not assuming,
  before touching every user-code launch site in the file) and confirming it doesn't change
  behavior for a script that already explicitly manages its own encoding.

- **Corporate-proxy / SSL-MITM diagnostic messaging.** Same 2026-08-08 pass: confirmed via grep
  that `run_setup.bat` has no `HTTP_PROXY`/`HTTPS_PROXY` detection or messaging anywhere (the
  underlying tools -- curl, PowerShell, pip, conda, uv -- already pick up system/env proxy
  settings the same way a manual setup would, so this is about diagnostic messaging on failure,
  not new proxy-traversal capability this bootstrapper doesn't have). REQ-013's connectivity
  check already distinguishes "genuinely offline" from other failure modes; a corporate MITM
  proxy with a self-signed root CA would currently surface as a generic SSL/connection failure
  with no hint toward the actual cause. **Trigger to thaw**: lower confidence than the two items
  above that a reliable, low-false-positive detection signal exists (a corporate proxy failure
  and a genuine network outage can look identical from a single failed request) -- needs a
  dedicated investigation into what signal (if any) reliably distinguishes the two before
  proposing a specific fix, not implemented speculatively ahead of that.

- **Payload headroom, then one shared TOML reader for pyproject and PEP 723** (and a shared
  fence finder for the extractor and `strip_pep723_block`). Filed 2026-10-09 with CLAUDE.md
  Item 79; evidence in `docs/plan-toml-reading-hygiene.md`. The pyproject fallback walker and
  `pep723_extract.py` are near-identical, but together they are 10.5 KB of source against a
  ceiling of about 6.1 KB per payload line, so a merge needs headroom FIRST (a deflate mode in
  `:emit_from_base64`, or stripping comments at `tools/sync_payload.py` time, opt-in per
  payload). Four payloads are within 460 chars of the 8191 limit today (`HP_PYPROJ_DEPS` 198,
  `HP_PREP_REQUIREMENTS` 304, `HP_PEP723_WRITEBACK` 333, `HP_COLLECT_SUBMODULES` 459). **Trigger
  to thaw**: a payload edit lands under 100 chars of margin (Item 79 slice 2 may be the first),
  or a third TOML consumer appears. Do not merge parsers before headroom exists.
- **PEP 723 `requires-python` as a Python-version input** (new feature). Filed 2026-10-09 with
  Item 79. It needs the entry script known before the environment is created, which today is
  decided after it, and `uv add --script` itself writes `requires-python = ">=<running
  python>"`, so honouring it recreates the exact write-back pin problem documented for
  `runtime.txt`. It is a REQ-004 precedence decision, not an implementation detail. **Trigger to
  thaw**: a field report of a script header with an upper bound running on a too-new Python;
  a maintainer decision on precedence (add it to `docs/open-questions.md` then) comes first.
- **Nuitka static unpack folder (`--onefile-tempdir-spec`) on the two Nuitka builds.** Item 72 follow-up, closed
  2026-10-24 (record in `docs/agent-closed-backlog.md`). Later launches of a Nuitka `--onefile` EXE are about 3.7
  times faster with a static folder on a hosted runner, and it may remove the field's per-launch Defender scan of a
  fresh unpack (unmeasured). It was NOT adopted because, with the folder cold, a simultaneous launch can exit 2 with
  `failed to open ... for writing` (one of three on run `40043297712`, Nuitka 4.3.1; two on `40066145187`; none of nine
  on `40084563527`, so it is intermittent), which would show a beginner an error after a double-click during a first
  unpack, and a new build over a running old one fails every time. **Trigger to thaw**: the uv-lane row `self.nuitka.cachesafety`
  reports `adoptable` true in several consecutive runs (three clean cold rounds and a clean update-while-running
  scenario), and only that. A Nuitka release note saying cold or concurrent onefile launches are serialized is a reason
  to read the next rows, not a trigger: it says nothing about replacing a build whose old copy is still running.
  Then rebuild the shape the
  closed-backlog entry describes (per-app token, fail open, folder named in words in the log, README Known
  Limitations saying the folder lives in the user's profile and stays after the app is deleted) and delete the guard
  in `tests/test_nuitka_cachesafety.py`'s `RunSetupStaysFlagFree`. Do not re-adopt on the 3.7x number alone.

- **Safer "does it work" probes before, or instead of, starting the program: an import check, the folder's
  own unit tests, an audit-hook dry run.** Raised by the maintainer 2026-11-01 as an idea for when the todo
  list is empty; analysed from the repo 2026-11-06; nothing built. The question: can the bootstrapper learn
  whether a program works without running all of it, for a script that may be risky to run?

  **What exists today** (each fact checked 2026-11-06). `run_setup.bat` has no unittest or pytest call and no
  test discovery. The only check that runs none of the user's code is REQ-021's in-memory compile
  (`tools/preflight_check.py`). Three more facts bear on this idea:
  - pipreqs is told to ignore `tests` (`HP_PIPREQS_IGNORE`), and `dep_merge.py` reads only
    `[project].dependencies`, so a test-only dependency (pytest, a mocking library) is never found or
    installed. A pytest-style folder would need pytest installed first.
  - `tools/find_entry.py` has no notion of test files. A folder with a library `calc.py` (no `__main__`
    guard) and a `test_calc.py` that ends in `if __name__ == "__main__": unittest.main()` selects
    `test_calc.py` as the entry (exit 0, rule 3 of REQ-002), so today the bootstrapper would build and
    verify an EXE of the test runner. With a third unguarded file the alphabetical fallback picks `calc.py`
    instead. Tests become the program only by accident of that rule. Not filed as a bug: no field report.
  - Nothing checks, before a run, that the entry's imports resolve. `runtime_module_scan.py` reads stderr
    after a run; `collect_submodules.py` calls `find_spec` only for a curated list and
    `hidden_import_scan.py` only for names an error already named.

  **The probes, from least to most of the user's code executed** (they stack; each answers a different
  question):
  1. Compile in memory. Shipped (REQ-021).
  2. Import resolution without importing. Parse the entry and its sibling modules with `ast`, then
     `importlib.util.find_spec` every top-level import in the selected interpreter. Runs no user code and
     needs one small stdlib helper (Python 3.9 grammar). It would name a missing module before the EXE build
     and before any start, the failure behind Item 65. It cannot see a module a library loads by a computed
     name, and pipreqs plus the installs already cover most of what it would find, so its honest value is the
     residue the dependency scan missed.
  3. The folder's own unit tests (the idea as asked; details below).
  4. A dry run under an audit hook: `sys.addaudithook` plus `runpy.run_path`, stopping at the first file
     write, network call or subprocess. A sketch run on toy scripts 2026-11-06: a pure script finished, a
     write attempt stopped at `open for write`, a network attempt at `socket.getaddrinfo`, a missing module
     raised normally. Two lessons from the sketch: the hook must not open a file itself (it recursed, and the
     script's own `except Exception` swallowed the RecursionError and carried on), and it should end the
     process with `os._exit` after writing to stderr, because a raised exception can be caught. Limits, and
     the reason it stays an idea: Python's documentation says audit hooks are not a sandbox; native code (a
     VISA or serial driver loaded through `ctypes`, a C extension) does its own I/O unseen, and driving
     instruments is the case README REQ-018's goal worries about most; a script that writes a log file in its
     first line stops at once and shows little; a GUI main loop or `input()` needs a time limit and closed
     standard input.
  5. The real run. Shipped (REQ-018).

  **Unit tests as the probe: feasibility.**
  - Detection is easy: `test_*.py` or `*_test.py`, a `tests` folder, `conftest.py`, `pytest.ini`,
    `[tool.pytest.ini_options]`, `tox.ini`; unittest versus pytest style from the imports.
    `python -B -m unittest discover` needs nothing installed. pytest needs an install and a consent question
    of the REQ-018.14 kind.
  - Importing runs top-level code. Checked on a toy folder: a flat script with no `__main__` guard ran its
    whole body (and wrote its file) when a test imported it; a guarded script's `main()` did not run. So the
    probe is safe for structured code and not for the flat script a beginner is handed, which is the audience
    README line 20 states ("not for maintaining production repositories"). Folders handed to beginners
    rarely carry tests, and the ones that do are the least likely to need the probe. Honest usefulness: low
    for the stated audience, real for a developer who wants a smoke check.
  - The probe changes the folder: `unittest discover` left a `__pycache__` behind (REQ-021.5 wants the folder
    unchanged), so run it with `-B` or `PYTHONDONTWRITEBYTECODE=1`.
  - Reading the outcome: unittest exited 5 for "no tests ran" on the 3.13 tried (older interpreters were not
    checked), and pytest documents exit 5 for "none collected". Count the `Ran N tests` line rather than
    trusting a zero exit.
  - Timeout: neither tool has one. The three bounded-launch helpers (`~failfast_probe.ps1`,
    `~exe_smokerun.ps1`, `~exe_hint_rerun.ps1`) each encode a different kill rule, so a test run would be a
    fourth decision, not a reuse; a test that opens a window or waits for hardware is the hang they exist for.
  - What a pass proves: the author's tests pass in the freshly built environment. It says nothing about the
    frozen EXE (hidden imports, DLLs, data files), which is why REQ-018.5 verifies the EXE and why
    `:hidden_import_recover` and `:dll_bundle_recover` exist. A test run could come before the EXE
    verification, or replace the interpreter run in `:verify_no_exe_interpreter`; it cannot replace the EXE
    run, and it is no substitute for the failing-EXE re-runs of Items 96 and 97, because a test under the
    interpreter cannot reproduce a failure that exists only in the frozen bundle.
  - What a failure proves: little. A stale test fails in a correct environment and the user cannot fix it, so
    the result must be a note and never a stop (getting the code running comes first).
  - Tests are not guaranteed idempotent either (an integration test that touches a database or an
    instrument), so the REQ-018.2 consent logic applies to them as it does to the program.

  **Fit with the README, and the decisions it needs first.** REQ-018.1 allows at most one start "through one
  launch method" and REQ-018.2 requires consent before "a run through the other launch method", so a test run
  added on top is a second launch method and needs a question like the other elective offers (declined without
  waiting in a non-interactive run, REQ-018.9; no question when `HP_PVW_KNOWN_IDEMPOTENT` is set, REQ-005.13,
  which already means the user said repeats are safe). If it ran INSTEAD of the verification run for folders
  that have tests, REQ-018.5 (verify the build by running the EXE once) would not hold for those folders. The
  maintainer would have to decide whether a test run counts as the single start, and whether the dry run of
  probe 4 counts as a start at all (it executes user code with the effects stopped). Both go to
  `docs/open-questions.md`, one at a time, before any code. Probes 1 and 2 execute nothing, so they sit next to
  REQ-021 (static pre-flight) and need no consent.

  **If thawed, build order.** Probe 2 first: smallest, safest, no consent, and the red CI scenario is easy (an
  entry that imports a module that is not installed must be named before the build and before any start).
  The unit-test offer only if a field report shows it is wanted. Probe 4 last, and only as an opt-in `PVW_`
  setting, because it looks like a sandbox and is not one. **Trigger to thaw**: a field report in which the
  single automatic start of a program did harm, or the user refused to start it, and a check that runs nothing
  would have said it would fail; or a report of a folder with a test suite where the test file was chosen as
  the entry or the verification run was the wrong signal. A wish for another kind of check, with no such
  report, is not a trigger.

- **Pull the useful pieces out of the bootstrapper so they work in other projects (a "PVW toolbelt").** Raised
  by the maintainer 2026-11-01, analysed 2026-11-06, nothing built. Goal: ad hoc use, and more formal use (a
  CI job, a lab PC, another repository's setup script), of the parts of `run_setup.bat` that are worth having
  alone, WITHOUT the provider tiers (uv, conda, embed, venv, system) or the installer builder (PyInstaller,
  Nuitka, the repair loops). The model is README's "PVW QuickStart (Super-User Fast Path)": one job, ONE
  fallback, byte-safe file handling, nothing destroyed without a backup, tested against the real tools, and
  honest about the one thing not tested (`docs/plan-pvw-quickstart.md`).

  **Starting position: what already carries over** (checked 2026-11-06).
  - No `tools/*.py` file that is also an embedded payload imports a third-party package. They are command
    line programs with documented exit codes, written to run on whatever interpreter a fallback tier hands
    over; all 21 Python payloads parse under Python 3.9 grammar today, but only 6 test files pin that
    (`feature_version=(3, 9)`: dep_merge, last_error_line, pep723_extract, pipreqs_precheck,
    preflight_check, runtime_module_scan).
  - `run_setup.bat` carries 29 base64 payload lines (21 Python, 8 PowerShell). Each is named by a unit test,
    and 29 test files hold a `PayloadSync` class that fails when the embedded copy differs from its `tools/`
    source. Those tests run in the local sanity sweep (`tools/run_sanity_sweep.sh`, step PYTEST, runs
    `pytest tests/test_*.py`, all 68 files) and in CI: the step "Self-test: Python unit tests (pytest
    cross-platform)" in `.github/workflows/batch-check.yml` runs every `tests/test_*.py` except three, in all 8
    lanes, and writes row `self.pytest.unit`, which the aggregate gate holds a merge on. Two older steps run
    `test_parse_warn.py` and `test_heuristics.py` on their own as well.
  - Gaps to know before promising anything to outside users. (a) The CI unit tests run on whatever Python
    the Windows runner image provides (the workflow has no `setup-python` step), not on the uv-managed latest
    or an old ambient interpreter that the helpers meet in the field. (b) The three left out are
    `test_entry_selection.py` and `test_entry_single.py` (their scenarios run as steps of their own) and
    `test_poll_public_diag_logging.py`, which runs only in the local sweep. (c) No Linux job runs unit tests
    (the Linux jobs are crlf-check, ndjson-registry-check, model-quick-fix and the Pages publish). (d) Nothing
    embedded in `run_setup.bat` runs tests on the user's machine. (e) README's payload inventory paragraph
    still counts 21 payloads (it says it was re-audited 2026-07-25); it is the README owner's to refresh.

  **Candidate pieces, by cost of extraction** (value = what it does that uv and pip do not).
  - Ready now, no code change (stdlib only, own unit tests, stable command line): `find_entry.py` (REQ-002
    entry choice: folder in, one line out, exit 3 means ambiguous), `preflight_check.py` (in-memory compile,
    exit 0/1/3), `detect_python.py` (`runtime.txt` and `requires-python` to one constraint, plus a `~=` aware
    PEP 440 translator), `pyproj_deps.py` and `pep723_extract.py` (declared dependencies from `pyproject.toml`
    or a PEP 723 header, checked against tomllib, CRLF and the layout `uv add --script` writes),
    `runtime_module_scan.py` (stderr to missing module to package name).
  - Needs a thin front door (a fixed-name file contract that the batch honors today): `dep_merge.py` merges
    requirements.txt, pyproject and the header, keeps the user's later edits, and ranks only for a conflict
    (README REQ-005.1, Item 89). It reads fixed tilde names in the current folder plus a record of the last
    good run, so a standalone "what does this folder need" command is about 40 lines that run `pyproj_deps`,
    `pep723_extract` and `dep_merge` in order and print the list. This is the strongest candidate: neither uv
    nor pip reads all three sources. `prep_requirements.py` (known gaps such as pandas needing openpyxl for
    Excel) and the pipreqs UTF-8 staging (`pipreqs_precheck.py`) belong to the same command as an optional scan
    step; pipreqs stays pinned at 0.4.13.
  - Needs writing, not extracting: an environment command. The knowledge sits in `run_setup.bat` in the
    `HP_UV_URL` / `HP_UV_FALLBACK_URL` download and the uv block that ends at `:uv_venv_fail`
    (`UV_PYTHON_PREFERENCE=only-managed`, `uv venv --seed --python`, the `import pip` reuse check, the
    malformed-`pyproject.toml` retry through `uv run --no-project python -m venv`, quoting of a version range).
    It costs the most because it is cmd syntax today. ONE fallback would be uv, then `python -m venv`; no
    conda, no embed.
  - Leave behind: the provider cascade and its consent gates, every PyInstaller and Nuitka step and repair
    loop, the post-flight panels, the lock and status files, git config merging.

  **Ways to ship them.**
  1. Publish the helpers as they are, as single files beside `run_setup.bat` on the Pages site (the publish job
     already copies `run_setup.bat` there after a line-ending check), each with a `# /// script` header that has
     no dependencies and `requires-python = ">=3.9"`, run by `uv run x.py` or `python x.py`, plus a SHA256 list.
     No new code. README gets a table of command, exit codes and the files each one writes.
  2. One `pvw.py` front door with subcommands (`entry`, `check`, `pyver`, `deps`, `missing`) generated from the
     `tools/` sources by a sync script, the way `tools/sync_payload.py` fills the batch, with a test that the
     committed file equals a fresh generation. Easy to hand to someone; costs a second embedding mechanism,
     and `pep723_extract.py`, `pyproj_deps.py` and `preflight_check.py` are flat scripts that exit at top
     level (no importable function), so the front door would run them with `runpy` or a subprocess unless
     they were reshaped.
  3. QuickStart-style paste recipes in the README. Fine for a one-job piece; the QuickStart's own one-liner is
     about 2 KB of PowerShell, and a recipe cannot carry a Python helper without embedding it as base64 the way
     the batch does.
  Order if thawed: 1; then 2 only if people ask for the same combination; 3 only for the environment command.

  **Tradeoffs to settle first.**
  - Today a helper's command line can change freely, because the batch and the helper ship together and
    `PayloadSync` forces them to match. Publishing a piece is a compatibility promise (arguments, exit codes,
    file names). A few helpers carry a `__version__` already; a published piece needs one, and a breaking
    change needs a new name. Publish few pieces.
  - The repository is meant to keep running without an AI agent in the critical path (the maintainer's goal,
    recorded 2026-10-31 in CLAUDE.md's GitHub Actions maintenance entry), so a few plain, unit-tested pieces
    beat a framework.
    Every published piece would need the Python 3.9 grammar test that only 6 helpers have, a "tested with"
    line naming real tool versions, and the one thing not tested, which is the QuickStart's own habit.
  - Do not start from version pinning or lock files: the maintainer said on 2026-10-23, in chat, that pinning
    and a clean-room scanner are not wanted now (the scanner is shelved in the pipreqs entry above; the
    pinning answer is not recorded elsewhere in the repository).
  - The repository is MIT licensed (`LICENSE`), so another project may already copy a helper; the open
    question is support, not rights.

  **Trigger to thaw**: a second real use of a piece outside this repository (the maintainer or another person
  copies a helper by hand into another project, or asks for one), or a report that a pasted QuickStart-style
  recipe was wanted for something the helpers already do. Until then the helpers can be copied from `tools/`
  as they are.
