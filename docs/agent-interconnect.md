# Agent Interconnectedness Map -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-interconnect.md`
import in CLAUDE.md. It documents the non-obvious cross-component dependencies that
future agents must understand to avoid re-introducing known failures.

Standalone hazards, rules, budgets, and procedures (batch/CMD quirks, the CMD `set` line
limit, the embedded-helper workflow, the ambient-Python lesson, etc.) live in
`docs/agent-lessons-learned.md`.

**Categorization principle:** interconnect = a dependency between two or more components
such that changing one requires understanding the other ("touch A, must understand B"). A
standalone discovered fact, hazard, budget, or procedure belongs in
`docs/agent-lessons-learned.md` instead.

**AGENT DIRECTIVE: When you discover a new interconnect or correct an existing one, update
this file immediately in the SAME commit (edit existing entries, do not only append). Keep
`docs/agent-lessons-learned.md` current too. The map must stay accurate.**

**This file is not human-facing prose -- it is loaded into every agent session via CLAUDE.md's
`@` import.** Every entry below is distilled to CURRENT-STATE facts: the rule, the mechanism, the
variable/subroutine relationship a future edit must respect. The "how we found this out" -- which
review round caught it, which fix attempt was wrong first, exact commit/run IDs -- lives in
`docs/agent-closed-backlog.md`'s "Interconnect Narrative Archive" section (read on demand). Do not
re-inflate an entry with discovery narrative when editing it; add the rule here and, if the
provenance is worth keeping, a compressed note there instead.

---

## `:define_helper_payloads` must be `call`ed before ANY subroutine using an `HP_*` payload

Every `HP_*` payload variable (~30 as of this writing) is `set` inside `:define_helper_payloads`'s
own body. `:emit_from_base64`, the shared decoder every payload consumer calls, reads the payload
via `Get-Item Env:$varName` -- if the caller's `set` line hasn't executed yet, this returns nothing
and `:emit_from_base64` silently `exit 1`s WITHOUT writing the target file, so the caller's own
`powershell -File "<target>.ps1"` fails with `The argument '<target>.ps1' ... does not exist.`

A subroutine's `:label` position in the file is IRRELEVANT -- only the RUNTIME ORDER of `call`
statements in the main flow matters. `call :define_helper_payloads` runs as one of the first two
things the main flow does (immediately before `call :merge_git_config`), specifically because
`:merge_git_config` is called earlier than almost everything else and now uses a payload
(`HP_MIGRATE_GITATTRIBUTES`, Item 60). **Before adding a new early `call` to the main flow, or
wiring a new payload into an already-early-called subroutine, verify `:define_helper_payloads` is
still called before it.** No automated test guards this ordering (`*.PayloadSync` tests only prove
byte-equality of the embedded base64, not reachability-in-time) -- a dedicated ordering guard is a
plausible future addition. (History: `docs/agent-closed-backlog.md`, CLAUDE.md Item 60 / PR #455.)

---

## Pre-flight syntax check (`:preflight_compile`, REQ-021) is a fail-open emitted helper

`:preflight_compile` emits `~preflight_check.py` (`HP_PREFLIGHT_CHECK`, `tools/preflight_check.py`) and runs
it on `%HP_ENTRY%` via `%HP_PY%`. **Exit 1 is the only code that reports a syntax error and sets
`HP_PREFLIGHT_FAILED`**; exit 0 continues; any other code, or a helper that could not be written
(`HP_TEST_FORCE_EMIT_FAIL=HP_PREFLIGHT_CHECK` simulates it), logs a `[WARN] REQ-021:` line and continues
(`:preflight_undecided`, `:preflight_no_helper`), so a broken check can never stop a program that may be valid
(REQ-021.4). The helper compiles in memory and writes nothing, which is what keeps `__pycache__` out of the
picture (REQ-021.5); do not go back to `py_compile`/`compileall`, which write a `.pyc` and exit 1 when they
cannot (Item 83). Coupled by exact strings: `Your Python program has a syntax error` and `REQ-021: entry failed`
(`self.preflight.syntax`, `self.preflight.pycache.*`), and the call site line `"%HP_PY%" "~preflight_check.py"
"%HP_ENTRY%"` plus the comment text `REQ-021: static pre-flight -- check the entry syntax` (`batch.preflight.compile`
in `tests/harness.ps1`, `BatchCallSite` in `tests/test_preflight_check.py`). The call to `:define_helper_payloads`
(see the first section) already precedes this subroutine.

**A second caller of the same helper: `:verify_find_entry_helper`** (checks the bootstrapper's own
`~find_entry.py` before entry selection) emits `~preflight_check.py` itself and runs it on the helper. It used to
run `py_compile` too, so an unwritable `__pycache__` failed it and the run stopped with `Could not determine entry
point` before `:preflight_compile` was ever reached (found by `self.preflight.pycache.unwritable`, whose row reports
`entryNotFound`/`helperCheckFailed`). Any new check of a file in the app folder must go through this helper, never
`py_compile`. Same fail-open rule as the entry check (REQ-021.4): exit 0 verifies the helper, exit 1 is a real syntax error
in it, and anything else (or a checker that could not be written) logs `[WARN] REQ-021: the find_entry syntax
check could not run` and goes on. The `helper.find_entry.syntax` row says which happened with `details.checked`
(`false` = not verified), so a pass never hides an unchecked helper. The exit code is copied to `HP_HELPER_RC`
at top level first (`if errorlevel N` is signed, so a negative code would read as 0).
The `HP_CI_SKIP_ENV` path still runs one `py_compile` on `~find_entry.py` and discards the result.

---

## `run_tests.bat`, the "Run tests (run_tests.bat)" CI step and the two NDJSON snapshots (Item 84)

**Touch the order of the `batch-check.yml` steps around "Upload CI NDJSON" / "Run tests", `run_tests.bat`, or what
`harness.ps1`/`selftest.ps1` write, must understand all of it.** Two different NDJSON files are read by CI:
- **Pre-harness snapshot** (`ci_test_results-selftest-<lane>-...` artifact, "Verdict from NDJSON", "Enforce
  NDJSON failures for gated lanes", `lane_verdict.json`, the aggregate gate): everything the `selfapps_*.ps1` workflow
  steps and `selftests.ps1` wrote before `run_tests.bat`. `harness.ps1` deletes `tests\~test-results.ndjson` and rewrites
  it, which is why the verdict steps must stay above "Run tests".
- **Post-harness file** (`tests\~test-results.ndjson`, collected in the `test-logs-selftest-<lane>-...` artifact under
  `tests/`): the harness's `batch.*` rows plus whatever `selftest.ps1` and `selftests.ps1` append. It is read by "Gate on
  NDJSON results" (`core.setFailed` on any `pass:false`) and the iterate gate. The `batch.*` and `selftest.ps1` rows
  are NOT in the pre-harness artifact; to read one, open the `test-logs` artifact.
- **The aggregate gate is real (Item 35 criterion C6).** `selftest-gate`'s step "Enforce aggregate self-test verdict"
  has no `continue-on-error`: a `pass:false` row in the pre-harness snapshot of any of the eight lanes, or a missing,
  unexpected or duplicate lane, fails the "Aggregate self-test verdicts" check (a required check). `model-quick-fix` and
  `publish_diag` keep `if: ${{ always() }}`, so the iterate gate and the Pages publish still run when it fails
  (run `40123300274`, with a throwaway red row in `contract-uv-fail`: the aggregate job failed at that step and the
  Pages publish still succeeded). Only the pre-harness rows count there; the
  post-harness `batch.*` and self-test rows are gated per lane by "Gate on NDJSON results". A row that records a
  finding writes `pass:true` plus a `details` flag, because `pass:false` is the row-level failure signal the verdict
  reads (a missing, unexpected or duplicate lane fails it separately).
  `tests/test_aggregate_gate.py` pins the step, the lane list (equal to the matrix) and the `always()` jobs; do not
  put `continue-on-error` back on the step, and re-prove with a throwaway red row if the job graph around it changes.
  **The NDJSON registry check gates through the same check** (Item 35 registry slice): `tests/test_check_ndjson_registry.py::
  test_repo_rows_and_registry_agree` runs `tools/check_ndjson_registry.py` over the real repository inside `self.pytest.unit`
  (pre-harness, every lane), so an emitted row with no `docs/agent-ndjson.md` entry, or an entry with no emission site,
  turns the aggregate check red; the `ndjson-registry-check` job has no `continue-on-error` either, but it is not a required
  status check, which is why the unit test exists. Add the registry line in the same commit as the row.
  A run cancelled by a newer push also ends with this check red on the superseded commit (its cancelled lanes wrote no
  verdict, so the aggregator fails closed); only the check on the current head counts.
- **A row exists only if its script ran, and an absent row cannot be red.** `run_tests.bat` therefore runs `selftest.ps1`
  and `selftests.ps1` even when the harness failed (it used to skip both, hiding every self-test row behind one red
  `batch.*` row), deletes their old summary files first, and counts a script that exits 0 without writing its summary
  (`tests\~selftest-summary.txt`, `tests\~selftests-summary.txt`) as a failure. A summary that cannot be deleted
  (another program holds it open) is a failure too, printed as `Could not remove the old ...`: an older file left in
  place would otherwise vouch for a run that wrote nothing. A new section added to `run_tests.bat` needs the same
  parts: always run, clear the old summary and check it is gone, fail when it is not rewritten.
- **The step's exit code is `run_tests.bat`'s.** The step used to exit 0 whenever the repo root status said
  `no_python_files` (true in every lane), which made the `exit` statements added to `selftest.ps1` and `harness.ps1`
  invisible to the job; only red rows were caught, by the Gate step. `tests/test_run_tests_step.py` pins `exit $rc`.
- Regression: `tests/selfapps_runtests_contract.ps1` runs a copy of the real `run_tests.bat` against stub scripts
  (`self.runtests.*`, every lane; the locked-summary row holds the old file open with `FileShare.Read`). The script
  must end with its own `exit 1` (a row is red) or `exit 0`: its last scenario runs a copy that exits 1 by design, and
  the pwsh step appends `exit $LASTEXITCODE`, so a script that just stops fails the step with every row green
  (`tests/test_run_tests_step.py::ContractScriptSetsItsOwnExitCode`). The red-lane behavior (the step "Run tests"
  fails, the uploads, the Gate step, the aggregate and the Pages publish still run, and the post-harness file still
  holds the self-test rows) was shown once with a deliberately red harness row on PR #496, run `38990735137`.

---

## Conda transient-failure phrases (Item 93): two `findstr` lines, one harness that cuts the code out of the batch

**Touch either `findstr /i /c:"..."` line (`:conda_create_check_transient` for REQ-022.1, `:conda_bulk_install` for REQ-005.2),
the labels around them, or what the blocks read, must understand the others.** Each site searches its own temp file
(`~conda_create.tmp`, `~conda_bulk.tmp`) for `CondaHTTPError`, `Failed to fetch`, `timed out`, `ConnectionError` and, since Item 93,
`Server Error` (the `requests` wording for a 5xx that conda's sharded repodata path prints unwrapped; a 404 says `Client Error`
and is not retried). The two lists must stay equal; `tests/test_conda_transient_terms.py` fails when they drift and checks both
against real conda text with findstr's rules (case blind, literal, OR). A phrase added here is a retried failure, so it must
name a failure that waiting can fix.
- `tests/selfapps_conda_transient.ps1` (`self.conda.retry5xx.*`, real and justme-test lanes) tests the REAL code without
  Miniconda or a network: it cuts `:conda_bulk_install` (up to `:try_nuitka_tier_a`) and the create flow from
  `:conda_create_check_transient` (up to `:conda_create_failed`) out of `run_setup.bat`, wraps each in a driver, and runs it
  with cmd.exe against a stub `conda.bat` that prints a chosen text and counts its calls. Moving or renaming those four labels, or
  making a block use a variable or label the driver does not define (`EXTERNAL_LABELS` and `KNOWN_VARIABLES` in the unit test),
  fails the unit test with a message that names the script to update. The driver's `:log` only appends to a file, so a changed
  log wording is matched by the row (`transient failure detected; retrying after 15s`, `retry after transient failure also failed`).
- The test hooks `HP_TEST_FORCE_CONDA_NETWORK_FAIL` and `HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL` still write the CondaHTTPError
  text themselves (`self.stub.conda_retry`, `self.stub.conda_create_retry` in `tests/selftest.ps1`); they prove the retry
  flow end to end, the harness above proves what the detection recognises.

---

## `.github/dependabot.yml`, `tests/test_dependabot_config.py` and the `no-automerge` label (Item 90 follow-up)

**Touch the file, the test's name lists, or `pr-automerge.yml`'s label handling, must understand the others.** Dependabot
validates the file against a schema with no extra properties: one unknown option (the old `open-pull-request-limit`)
gets the whole file rejected, with an error only in a check run on a pull request that touches the file. The test reads
the file as text (no YAML library in the pytest step) and holds its keys to lists copied from Dependabot's options
reference; a new option the file needs goes into the lists in the same change. The file sets `labels: ["no-automerge"]`
because `pr-automerge.yml` arms auto-merge for every same-repo pull request without that label (a Dependabot-triggered
run has neither PAT secret, so its `GITHUB_TOKEN` step applies; unproven until a first pull request exists). Deleting the
label from the file is the switch that lets Dependabot's pull requests merge themselves; the maintainer decided
(2026-10-31) to keep the label while a session reads the runs of the first few Dependabot pull requests, then to delete it
(the repository is meant to run without an AI agent in the critical path, CLAUDE.md's GitHub Actions entry).

---

## Requirement tags on rows: four readers must agree on the format

**Touch the `req` tag format, a README shall id, or any reader below, must understand the others.** A row's `req`
value is a literal in the test script (`req = 'REQ-009, REQ-018.27'`, a `-Tag @{ req = '...' }` hashtable, or a switch
entry's hashtable) and is written to the NDJSON row verbatim. It names one requirement (`REQ-018`, `REQ-018.27`,
`REQ-005.1.17`) or several separated by commas. The readers: `tests/test_req_trace.py` (each part must be a known
number or a sub-id the README contains, any depth), `tests/test_req_shall_trace.py` (each numbered README shall must be
named by some part, or listed in `UNTRACED_SHALLS`), `tools/req_trace_table.py` (the plan doc's status table; a row
counts under each part) and `tools/req_coverage.py` (`req_coverage.json`; each part gets the row's outcome). A new
reader must split on commas. The scan is static text: `req = $variable`, a `-Req` parameter or a map such as
`$reqOf` is invisible to all four, so the tag stays a literal at the row's call site (a helper that writes rows takes a
`[hashtable]$Tag` parameter, see `Write-DmRow` in `tests/selfapps_dep_merge_later.ps1`), and a comment must not
contain the `req = '...'` shape, which would count as a tag. The README ids themselves are not moved or reused (AGENTS.md).

---

## Concurrent-instance lock (REQ-024) touches every exit path

The lock (`:acquire_lock`/`:lock_is_stale`/`:release_lock`) is released only at `:die` and
`:success`, not at every one of the file's ~100 `exit /b` sites. **Correctness is age-based
staleness, not proven release-path coverage** -- CMD has no `finally`/`trap`, so depending on
proving every exit path releases the lock is the wrong shape (Ctrl+C, a kill, power loss all
bypass any release hook regardless). The `:die`/`:success` hooks are an optimization (avoid a
stale lock for up to ~2h after an ordinary run), not the guarantee. Both are confirmed universal
funnels for the normal flow: every `call`-based consent-gate decline returns up its call chain and
continues rather than terminating directly, and the EXE fast path's early-success shortcut also
funnels through `:success`. The few pre-label `exit /b 1` sites (workspace-path-invalid guards, near
top of file) execute before the lock is acquired, so need no release call.

**`tools/audit_batch_exit_paths.py`** (not wired into CI, run by hand) inventories every label/
call/exit site and whether each label is ever `call`ed -- deliberately not a full paren-aware CFG
proof (a `called=False` result is "a hint, not proof" per its own docstring; a true parenthesized-
`if`-block-aware CFG parser was assessed as disproportionate effort). Starting point for a future
exit-path audit, not a final answer.

**Rule for a new top-level (non-`call`ed) `exit /b` site**: if reachable with an empty call stack
AND is a routine exit a real user could hit often (not a crash), add `call :release_lock` before
it -- same as `:die`/`:success` -- so a repeated-decline pattern doesn't leave stale locks.

---

## `:emit_from_base64`'s test-injection hook covers every future payload automatically

`HP_TEST_FORCE_EMIT_FAIL=<VARNAME>` (checked first, before the real PowerShell write): if defined
and equal to the CALL's own `%VAR%` argument, logs `[TEST]` and `exit /b 1` immediately, simulating
a genuine disk-write/AV-lock failure for that ONE payload without touching any other payload
emitted in the same run. REQ-019-compliant (absence changes nothing). Any future new embedded
helper automatically inherits this same test-injection capability with zero extra wiring.

---

## AV-Safe Build Path Tier A (`:try_nuitka_tier_a`) and hidden-import auto-recovery

**Touch either subroutine, must understand the other.** `:try_nuitka_tier_a` (Nuitka fallback when
PyInstaller's build fails) sets `HP_NUITKA_FALLBACK_USED=1` on success, and `dist\<env>.exe`
becomes a Nuitka-produced binary. `:hidden_import_recover`'s repair action is PyInstaller-specific
(`--hidden-import=X`), which does not apply to a Nuitka-built EXE. **Rule: any subroutine that can
build `dist\<env>.exe` via something other than PyInstaller must set an analogous marker, and
`:hidden_import_recover` (plus any sibling repair loop) must check it and skip (not attempt-and-
fail) when set.** Both `:hidden_import_recover` and `:dll_bundle_recover` (below) carry this guard
today, right after their own early-return checks. The warnfix-triggered rebuild (a second
PyInstaller rebuild call site) clears `HP_NUITKA_FALLBACK_USED` on its own success, since it always
uses PyInstaller -- if the EXE it just replaced was Nuitka-built, the flag must reflect the new
reality or the guard above would wrongly keep skipping repair.

**`:hidden_import_recover` pairs `--collect-submodules=X` with every `--hidden-import=X` it adds**
(accumulator `HP_PYI_HID_COLLECT`, mirrors `HP_PYI_HIDDEN_IMPORTS`'s accumulate-then-inject shape).
A `--hidden-import=X` target alone only guarantees PyInstaller follows what `X`'s own `__init__.py`
statically imports -- not every real submodule under `X/`, which a compiled C extension elsewhere
in the app can still need. Broader than strictly necessary but structurally safe: `X` is already
`find_spec`-confirmed installed by `~hidden_import_scan.py`'s own strict gate (see
`docs/agent-lessons-learned.md`'s "--hidden-import auto-recovery must stay STRICT" entry -- this
change doesn't touch what triggers that gate, only what happens once it fires). The
`[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=X` log line now also appends
`--collect-submodules=X` -- every existing consumer matches it as a PREFIX/substring, so this is
non-breaking; re-verify that holds for any future change to this log line.

(History of the two "no guard existed at all" bugs that motivated this section, and the exact CI
runs that confirmed each fix: `docs/agent-closed-backlog.md`.)

---

## Conda native-DLL bundling repair loop (`:dll_bundle_recover`, CLAUDE.md Item 24) and its two siblings

**Touch any of the three PyInstaller repair loops (`:dll_bundle_recover`, `:hidden_import_recover`,
the warnfix per-module rebuild), must understand how they chain.** `:dll_bundle_recover` repairs a
DIFFERENT failure class than `:hidden_import_recover`: a conda-installed native extension's `.pyd`
depends on a shared DLL under the env's `Library\bin` (e.g. `eccodes.dll` for `pygrib`) that
PyInstaller bundles the `.pyd` for but never discovers the DLL dependency of -- a
missing-native-library failure, not a missing-Python-module one, so `:hidden_import_recover`'s
strict `ModuleNotFoundError`-only gate correctly never fires for it.

**Detects at BUILD time** (reacts to PyInstaller's own build-log warning, `WARNING: Library not
found: could not resolve 'X.dll'...`), called from `:run_entry_smoke` right before
`:run_exe_smokerun` -- one guaranteed-failing verification cycle earlier than a runtime-only design
could. `HP_LOG_SIZE_BEFORE` (a byte-offset snapshot taken right before the fresh-build attempt)
scopes the scan to THIS build's own log output, since `%LOG%` persists across runs in the same app
directory.

**Detection runs first and UNCONDITIONALLY, independent of provider/Nuitka.** `next_dll_target()`
(`tools/dll_bundle_scan.py`, `HP_DLL_BUNDLE_SCAN`) parses whatever DLL name PyInstaller's own
warning names via regex (general, not hardcoded to `eccodes.dll`) -- `locate_dll()` requires the
named DLL to actually exist under the conda env's `Library\bin` (searched recursively) before
emitting anything. The actual BUNDLING action (Requirement 3) is gated on `HP_ENV_MODE=conda` (no
`Library\bin` convention elsewhere) and on `HP_NUITKA_FALLBACK_USED` being unset (same reasoning as
the hidden-import guard above) -- but detection itself always runs and always logs, so the
caveat-panel "detected, repair skipped" state (see below) is honest in both non-actionable cases.

**Tried-list is a FILE** (`~dll_bundle_tried.txt`, appended via `type ... >>`), never inline argv --
a DLL basename can legally contain a space or a cmd.exe metacharacter, which would corrupt an
unquoted inline accumulator. `tools/dll_bundle_scan.py`'s `read_tried_file()` parses it back. `main()`
continues past a named-but-not-on-disk candidate to the next one in the same log, rather than
stalling the whole loop on one stale/irrelevant warning.

**Outcome bookkeeping, the load-bearing state variables:**
- `HP_DLL_FAILED` -- set only on a genuine rebuild failure (PyInstaller errorlevel, or a missing
  post-rebuild EXE); gates whether the "bundling complete" line/state can ever fire on a failure.
  Also sets `HP_BOOTSTRAP_STATE=error` (mirrors the warnfix-rebuild's own "conservative response to
  failure" precedent). The smoke run afterward still runs regardless (see "Single-verification
  smoke model" below).
- `HP_DLL_EXHAUSTED` -- set when a real, locatable candidate DLL is found AFTER the 3-iteration cap
  is already hit, so it is correctly reported as `exhausted` (a distinct, `pass:true` NDJSON state)
  rather than being silently discarded and misreported as a clean `repaired`.
- `HP_DLL_REPAIRED` -- reset at the very top of `:dll_bundle_recover` (before ANY early-return),
  set ONLY in the genuine "repaired" branch. This is the caller's own per-call signal for "did THIS
  call actually bundle something" -- deliberately NOT `HP_DLL_ITER` (which is reset partway through
  the subroutine and would read stale/nonzero on a second call that found nothing new).
- `HP_DLL_HINT_STATE` -- set by `:emit_dll_bundle_row` BEFORE its own `HP_NDJSON`-gated early
  return (so the postflight caveat hint works even with NDJSON disabled), survives past the
  subroutine returning (NOT cleared at `:dll_bundle_recover_exit`, unlike `HP_DLL_FAILED`/
  `HP_DLL_EXHAUSTED`), and drives `:pfb_dll_hint`'s 3-bucket wording dispatch (never-attempted /
  attempted-but-incomplete / repaired-but-something-else-still-wrong). Reset once per fresh build
  attempt, same as `HP_DEP_MAYBE_INCOMPLETE`/`HP_PYI_DLLBIND`, so a tier that never calls
  `:dll_bundle_recover` this run doesn't inherit a stale hint from an earlier cascaded-away tier.

**Cross-tier/cross-pass state-leak resets are consolidated in `:run_entry_smoke`'s init block, NOT
inside `:dll_bundle_recover`/`:hidden_import_recover` themselves.** `HP_PYI_DLLBIND` (the
accumulated `--add-binary` flags) and `HP_PYI_HIDDEN_IMPORTS`/`HP_PYI_HID_COLLECT` must each be
reset EXACTLY ONCE per fresh build attempt, not once per subroutine call -- since
`:dll_bundle_recover` now runs a SECOND time per build (see below), resetting inside the subroutine
itself would wipe an earlier pass's already-accumulated flags before a later rebuild could use
them. Every rebuild command in this build lifecycle (`:dll_bundle_recover`'s own, and
`:hidden_import_recover`'s own) must thread ALL of `%HP_PYI_EXPAT% %HP_PYI_COLLECT%
%HP_PYI_DLLBIND% %HP_PYI_HIDDEN_IMPORTS% %HP_PYI_HID_COLLECT%` -- any future repair loop added to
this lifecycle must thread its own accumulated flags through every later rebuild the same way, or
an earlier loop's fix is silently discarded by a later one's rebuild.

**`:dll_bundle_recover` runs a SECOND time per fresh build, after `:hidden_import_recover`'s own
loop finishes** (`:run_exe_smokerun`'s flow calls it again there) -- a `--collect-submodules=X`
hidden-import fix can pull a package's compiled extensions into the bundle for the FIRST time,
surfacing a native-DLL warning that never existed in any earlier build (confirmed via a real
`pyproj`/`proj_9.dll` case). If that second call actually bundles something (`HP_DLL_REPAIRED=1`),
`:hidden_import_recover` gets one more bounded pass too (gated on a matching `HP_HIDDEN_REPAIRED`
flag, same reset-at-entry-before-any-early-return shape as `HP_DLL_REPAIRED`).
`:hidden_import_recover`'s own rebuild also re-snapshots `HP_LOG_SIZE_BEFORE` immediately before
its call, narrowing each pass's own scan window to just the freshest rebuild's output. **Bounded to
exactly one extra round of each subroutine, never a further interleave** -- a case needing more
than this is its own future backlog item, not solved speculatively here. The caller's own early
`if "%HP_EXE_EXIT%"=="0" goto :smokerun_ok` (previously placed right after the FIRST
`:hidden_import_recover` call) was removed -- it could skip the entire second-pass block whenever
the first call's rebuild happened to already exit 0, defeating build-time DLL detection for exactly
the case this feature exists to catch (a smoke run passing today doesn't mean the build log has
nothing left to flag for a different code path later).

**`HP_PY_DIR` (`%~dpI`, always ends in exactly one trailing backslash) must be passed as
`HP_PY_DIR_ARG` (one extra backslash appended) when immediately followed by another quoted
argument** on `~dll_bundle_scan.py`'s own command line -- an odd trailing-backslash count before a
closing quote escapes the quote instead of closing it (see `docs/agent-lessons-learned.md`'s
"single trailing backslash" entry for the general Windows-argv rule this is one instance of).
Getting this wrong makes `locate_dll()` always report "could not locate" even when the DLL is
genuinely present, since the corrupted path fails `os.path.isdir()`.

**`HP_DLL_DETECTED`/`HP_NEXT_DLL`/`HP_NEXT_DLL_PATH` need SANITIZED copies for `:log`'s own
unquoted echo and the `call`-triggered second-expansion-pass hazard** (`_SAFE` variants, computed
by the real emitted file `tools/dll_pct_sanitize.ps1`, `HP_DLL_PCT_SANITIZE` -- NOT cmd.exe
`:search=replace` substitution, which cannot reliably strip a literal `%`/`^`; see
`docs/agent-lessons-learned.md`'s "`:log` echoes UNQUOTED" entry for the full mechanism and why
this needed three attempts to get right). Every FUNCTIONAL use of the raw value (the tried-file
byte-copy, the quoted `--add-binary` argument) is untouched -- only `:log` calls use the sanitized
copies, so tried-list dedup matching is unaffected.

Every outcome of this loop (`skipped_nuitka`/`skipped_non_conda`/`repaired`/`unlocatable`/
`exhausted`/`failed_rebuild`/`failed_missing_exe`) is emitted as NDJSON id `self.dll_bundle.recover`
via `:emit_dll_bundle_row` -- see `docs/agent-ndjson.md` for the full field schema. Any future
repair loop's outcome points need the same treatment: a `call`ed emitter subroutine plus a
registered NDJSON row.

**`self.layered_e2e.chain` (`tests/selfapps_layered_e2e.ps1`) is this loop's regression test**,
proving all 4 mechanisms (REQ-009 cascade, warnfix repair, hidden-import recovery, DLL bundling)
fire together for real via a genuine `pygrib`/`eccodes.dll`/`pyproj`/`proj_9.dll` chain --
`chainPass` confirmed `true` via real CI (PR #421, `cache`-lane run `31264219121`).

(Full bug-by-bug history -- 9+ distinct real bugs found via CodeRabbit review rounds and live CI,
each with its own wrong-first-attempt trace -- lives in `docs/agent-closed-backlog.md`'s
Interconnect Narrative Archive, filed under Items 24/25/28/29.)

---

## AV-Safe Build Path requirement 9 (`:offer_optimized_build`) -- a strictly safer sibling of Tier A

**Shares `:try_nuitka_tier_a`'s Nuitka invocation but NOT its "delete first, build second" safety
posture.** Tier A runs only after PyInstaller already failed, so deleting the old EXE first is
free. `:offer_optimized_build` (called from `:smokerun_ndjson` right after
`call :run_postexec_checkpoint exe`) runs in the OPPOSITE situation: the existing EXE already
passed verification. It builds to a distinct temp name (`%ENVNAME%.optimized_build.exe`), runs its
own internal 30s-capped verification launch against that temp file, and only on CONFIRMED
build-and-run success does `move /y` swap it over the original. Every failure branch
(`goto :optbuild_cleanup`) deletes only the temp file, leaving the original untouched.

**Post-swap verification checks whether the SOURCE (temp file) is gone, not whether the
destination exists** -- the destination (the already-working original) exists before the move
regardless of outcome, so checking it can never detect a failed swap. A same-volume FILE `move /y`
onto an existing destination is atomic (fully replaces or fully fails, source consumed only on
success) -- see `docs/agent-lessons-learned.md`'s "Windows `move` onto an existing destination"
entry for why this file-move reasoning does NOT transfer to a directory swap (the embed tier's own
`:embed_swap_retry` needed a different fix for exactly that reason).

**Gated on the SAME `HP_NUITKA_FALLBACK_USED` flag Tier A sets, for the opposite reason**: Tier A's
guard checks it to SKIP a PyInstaller-only repair against a Nuitka EXE; this subroutine checks it
to skip OFFERING THE PROMPT AT ALL when Tier A already ran (the user already has an optimized-ish
build). On its own success it also sets `HP_NUITKA_FALLBACK_USED=1`.

**Cascade re-entry can offer this prompt more than once per bootstrap** -- called from the same
site as `:run_postexec_checkpoint exe`, so each cascade tier's own verification pass re-offers both
prompts fresh (each tier is a genuinely different build).

**Nuitka auto-detects an installed Visual Studio via the registry** (confirmed against
Nuitka/Nuitka#3317) -- no Developer Command Prompt/`vcvarsall.bat` needed. The hint text
referencing Visual Studio Build Tools is REACTIVE ONLY (shown after a real Nuitka build failure),
never proactive fingerprinting.

Four test scenarios (`tests/selfapps_optimized_build.ps1`, uv lane, non-gating): `accept` (real
build+swap), `forcefail` (original untouched), `swapfail` (forced swap failure, original untouched,
temp cleaned up), `decline` (prompt shown, no build attempted).

---

## The Nuitka command lines deliberately carry no `--onefile-tempdir-spec` (Item 72 follow-up)

**Touch `:try_nuitka_tier_a` or `:offer_optimized_build`'s Nuitka command, must understand this.** A static unpack
folder makes later launches faster but breaks a launch that races another on a cold folder (see
`docs/agent-lessons-learned.md`), so both lines stay exactly `-m nuitka --onefile --assume-yes-for-downloads
--remove-output --output-dir=dist -o ...`. `tests/test_nuitka_cachesafety.py` pins that (no `onefile-tempdir-spec`,
no `:nuitka_cache_arg` anywhere in the batch) and also pins `tests/selfapps_nuitka_cachesafety.ps1`'s `$prodFlags`
to the same text, so the safety build stays the production build. `tests/selfapps_nuitka_launchcache.ps1` pins its
own `$prodFlags` the same way, so a change to the shared flag text is made in `run_setup.bat` and in both scripts
together. The test pins the whole command line (`-o "<name>" "%HP_ENTRY%" >> "%LOG%" 2>&1` after the flags), so an
option added after `--output-dir=dist` is caught too.

---

## Nuitka's "unsupported Python" answer is read from `~setup.log` between a mark and a check (Item 80)

**Touch either Nuitka command line (`:try_nuitka_tier_a`, `:offer_optimized_build`), the Visual Studio hint under it, or the
Item 80 scenarios in `tests/selfapps_pvw_builder.ps1`, must understand this.** When uv's newest CPython outran Nuitka (3.15.0
against Nuitka 4.2.2, one day in October 2026) the user saw "Fallback build did not complete successfully." followed by a hint
to install Visual Studio Build Tools, which cannot help. The two sites now say what Nuitka itself said:
- `call :nuitka_unsupported_mark` is the line directly before each command and stores, in `HP_NUI_BEFORE`, how many lines of
  `~setup.log` match `The Python version .* is not supported by Nuitka` (`:nuitka_unsupported_count`, a `for /f` over `findstr` that
  counts lines itself: no pipe, so no `^|` escaping). In the failure block `call :nuitka_unsupported_check` counts again; more
  lines than at the mark sets `HP_NUI_UNSUPPORTED=1` and logs one plain sentence, and the Visual Studio hint line is
  `if not defined HP_NUI_UNSUPPORTED call :log ...`. **The mark is the point**: `~setup.log` is appended to and only rotated past 10
  MB, so "does the log contain it" would take an earlier run's answer for this one (`nuitka_failother` seeds exactly that line).
  Without a mark nothing is claimed and the old hint shows.
- Nuitka's "only experimentally supported" warning for a brand-new Python is a different line and is not counted: that build works.
  The sentence must not repeat Nuitka's own wording, or the next run would count the bootstrapper's own line
  (`tests/test_nuitka_unsupported_hint.py` pins all of this, including that the three stub lines of the scenarios agree with the
  pattern).
- **Decided: no version table in the batch.** Pre-checking the Python against a list of what Nuitka supports would go stale the way
  the problem did (4.2.2 refused 3.15, 4.3 accepted it a day later); Nuitka answers in about a second and its answer is the source of truth.
- The scenarios put a stub `nuitka.py` next to `app.py`: `python -m nuitka` finds the current folder first, so the real command
  line runs and prints the line, with nothing compiled (the real package is still installed first). `app.py` wins entry selection
  (REQ-002), so the stub is never the program. Each of the three has its own gating step in `batch-check.yml` (real and conda-full) and
  its logs in the `test-logs` artifact; they started as child runs of the `nuitka_forcefail` step while the workflow was held, and
  `tests/test_nuitka_unsupported_hint.py` now fails if a step goes missing, stops gating or leaves the two lanes.

---

## `PVW_BUILDER` (Item 71): the build-tool choice touches four sites in two build paths

**Touch the build block, `:try_nuitka_tier_a`, `:offer_optimized_build` or `:try_fast_exe`, must understand
the others.** `PVW_BUILDER=auto|pyinstaller|nuitka|both` is a super-user override (README REQ-019: absent
or `auto` is today's behavior; nothing a Prime Directive run needs depends on it). It is parsed once near
the other `PVW_` overrides into `HP_BUILDER` (lowercase, default `auto`). The raw value is compared with
`set PVW_BUILDER| findstr /x /l /i /c:"PVW_BUILDER=<choice>"` (the `PVW_PROVIDER` pattern, plus `/i` so any case is
accepted), so cmd never parses it and **no line may expand `%PVW_BUILDER%`** (a unit test forbids it); only the
normalized `HP_BUILDER` is ever expanded. An unrecognized value is logged once as `PVW_BUILDER is not one of ...;
using auto.` and is NOT echoed (`:log` echoes unquoted and the text is whatever the user typed). Where each choice acts:
- `pyinstaller`: `:try_nuitka_tier_a` returns 1 at its top (before it installs Nuitka), so all three call
  sites report the PyInstaller failure exactly as they report a failed fallback, and
  `:offer_optimized_build` returns before its prompt, so the offer is never shown.
- **Stale EXE**: `:try_nuitka_tier_a` deletes `dist\<env>.exe` as its FIRST statement, before the pyinstaller guard,
  the forced-failure hook and the Nuitka install. Any earlier return would otherwise leave an EXE from an earlier run
  for `:run_exe_smokerun` to start as this build, while the log says the code is verified through Python (the
  `:verify_no_exe_interpreter` skip is keyed on the file existing). A new early return in that subroutine must come
  after the delete. Rows: `self.builder.override` scenarios `nuitka_stale` and `pyinstaller_nofallback` (both seed a
  copy of `hostname.exe` at the EXE path: a real program that exits 0, so a wrongly started stale EXE looks like a
  passing build; a first version seeded a text file and left the step running for over ten minutes, see Item 87).
- `nuitka`: the build block in `:run_entry_smoke` skips the `pip install pyinstaller` step (one `if` chain with
  the uv and pip variants; it logs `PyInstaller is not installed for this run`), takes a branch ahead of the
  forced-PyInstaller-failure hook, never runs PyInstaller, deletes a stale PyInstaller warn file (otherwise warnfix could rebuild over
  the Nuitka EXE with PyInstaller), calls `:try_nuitka_tier_a`, and on failure reports
  `reason=builder_nuitka` through `:warn_build_incomplete`. On success it sets
  `HP_NUITKA_FALLBACK_USED` and `HP_FRESH_BUILD_OK` like Tier A, so the Nuitka-only repair-loop guards apply.
  **The delete is not the guard**: it can fail (another program holds the file open) and `~parse_warn.py` reads
  `build\<env>\warn-<env>.txt` by path, so the warnfix repair, which ends in a PyInstaller rebuild, is switched off for the
  nuitka choice where its dispatch flag is decided: `if /I "%HP_BUILDER%"=="nuitka" set "HP_WARNFIX_NEEDED="` between the
  `for /f` scan of `~missing_modules.txt` and `if defined HP_WARNFIX_NEEDED (`, on its own line (a second `if` on the
  dispatch's else-if line would capture the later else branches), with an `[INFO] PVW_BUILDER=nuitka: the warnfix repair is
  skipped` line first. Row: `self.builder.override` scenario `nuitka_warnfile` (the test holds the warn file open with
  `FileShare.Read` and requires that log line, which is only written when the surviving file was read and named a module).
- `both`: PyInstaller builds and verifies as usual, then `:offer_optimized_build` skips the question
  (`goto :optbuild_both`; the override is the consent, same reasoning as `HP_PVW_KNOWN_IDEMPOTENT`, and the
  log line says the program starts once more for up to 30 seconds; README REQ-018.35 and REQ-018.36 state both, the
  maintainer's answer of 2026-10-24, so a change to either needs the README shalls changed with it) and continues into the unchanged
  build-to-temp, verify, swap-on-success path, so a verified EXE is never replaced by an unverified one. It is
  skipped, with a log line, when the verification run did not exit 0.
- System-Python consent: `:system_build_consent_gate` words its question by `HP_BUILDER` (`goto :sbcg_nuitka_text`
  for `nuitka`, which installs Nuitka and not PyInstaller). The default wording stays byte-identical because
  `self.sysbuild.decline` matches it; `self.sysbuild.nuitka_prompt` proves the nuitka wording and that
  PyInstaller is not named.
- Fast path: a fresh cached EXE is still reused whatever the choice; `:try_fast_exe` logs that no build ran
  and that deleting `dist\<env>.exe` builds again. No builder record is kept, so changing the choice does
  not by itself trigger a rebuild.
`tests/selfapps_pvw_builder.ps1` covers it (row `self.builder.override`); `tests/test_builder_override.py`
pins the order of the guards (the fallback guard before the Nuitka install, the offer guards before the
prompt). The default order (PyInstaller first, Nuitka as fallback or elective upgrade) is deliberately
unchanged until Tier B matures (`docs/prd-av-safe-build-path.md`).

---

## Standalone Python-download tier (REQ-009 Tier 5 by naming; executed 3rd in provider order)

**Provider chain: `uv -> conda -> embed -> venv -> system`** (embed sits right after conda, not
last-resort) -- conda and embed both front-load acquisition of a fresh/pinned interpreter; venv/
system wrap whatever's ambient and stay the true last resort (system is absolute final, gated
solely by the REQ-014 consent prompt). Both dispatch mechanisms encode this order:
`:handle_conda_failure` (linear initial fallback) and `:provider_cascade` (goto-based re-entrant
post-warnfix cascade -- see below).

**Mental model: embed behaves like `venv`, not `system`.** Both venv and embed are fully isolated
and bootstrapper-installable (safe to `pip install` into freely); system is shared/minimally-
invasive (installs consent-gated). Wherever code branches system out to a restricted/no-op path,
embed should NOT be excluded the same way.

**Two-stage PowerShell/Python split, not a single script** -- this tier runs before the
bootstrapper has secured any interpreter of its own, so per-request version-table logic cannot live
in Python until SOME interpreter exists on disk (the one this tier itself is extracting).
1. **PowerShell stage** (`tools/embed_extract.ps1`, `HP_EMBED_EXTRACT`) -- checksum verification
   (`[System.Security.Cryptography.SHA256]`, not `Get-FileHash` -- see
   `docs/agent-lessons-learned.md`'s "prefer raw .NET types" entry for why Utility-module cmdlets
   are unsafe in this invocation shape), extraction, and the `._pth` patch (uncomment
   `#import site`, regex `(?m)^#import site\r?$` to survive CRLF). Zero per-request branching.
2. **Python stage** (`tools/embed_pyver_check.py`, `HP_EMBED_PYVER_CHECK`) -- runs under the
   freshly extracted interpreter, reuses the SAME `PYSPEC` value `~detect_python.py` computes.
   **`PYSPEC` can still be empty when the tier is reached**: the main flow computes it only after
   `conda.bat` exists, so a run with neither uv nor Miniconda (the case README REQ-009 gives for this
   tier) arrives here without it and used to ignore `runtime.txt`/`pyproject.toml` silently (found by
   `self.embed.version.*`, PR #507). `:try_embed_fallback` therefore runs `~detect_python.py` under the
   fresh interpreter right after the extraction line when `PYSPEC` is undefined (`PVW_TARGET_PY` wins
   first) and logs a content-free `a Python version request was found in this folder.` line; the value
   itself is never logged (it can hold `<` and `>`). **A range picks the newest table minor it allows**
   (`pick_minor`), not the first number in the spec: `>=3.10,<4.0` stays on the newest minor, `<3.13`
   gets 3.12, and a spec no table minor allows falls back to the floor or the newest minor with the WARN.
   `EMBED_PYTHON_TABLE` maps minor -> `(patch, sha256)` for 3.10-3.15 (6 entries,
   matching python.org's currently-supported non-EOL minors, refreshed quarterly -- see CLAUDE.md's
   "Embed version table" periodic check). The `LATEST_MINOR` entry's patch/sha256 (now `"3.15"`) MUST match the
   batch-side `HP_EMBED_LATEST_PATCH`/`HP_EMBED_LATEST_SHA256` exactly --
   `tests/test_embed_tier.py`'s `BatchPythonConsistency` test enforces this.
3. **Windows self-file-lock**: the Python stage runs FROM `HP_EMBED_DIR` itself, so a version-swap
   extraction happens into a SIBLING staging directory (`HP_EMBED_DIR` + `_swap`); the actual swap
   (`rd /s /q` old + `move /y` new-into-place) happens in the BATCH caller, only after the Python
   process has fully exited and released its locks.
4. **`:embed_swap_retry` gates `move` on `rd` having genuinely cleared the destination first**
   (`if exist "%HP_EMBED_DIR%" goto :embed_swap_rd_failed`, skip `move` entirely) -- a directory
   `move` onto a still-existing destination silently NESTS the source inside it rather than failing
   cleanly, so a post-hoc "does it exist now" check cannot detect a failed `rd`. Covered end to end by
   `tests/selfapps_embed_version.ps1` (`self.embed.version.swap`/`.floor`/`.ceiling`/`.range`, real lane,
   gating): the program must really run under the requested minor, with exactly one `python3NN.dll`, no
   `~embed_python_swap` left and nothing nested, because a failed swap is silent by design (helper exit 1,
   the batch keeps the interpreter it has).

**Version selection is a small pinned table, never a live python.org scrape** (same "deterministic
execution > dynamic resolution" principle as the pipreqs 0.4.13 pin). Integrity via embedded SHA256
computed once at pin-time, never fetched over the same network path as the download.

**Offline-mode test-flag exception touches two call sites**: `HP_TEST_FORCE_EMBED_REAL=1` punches a
hole through `HP_OFFLINE_MODE=1` at both `:try_embed_fallback`'s own check AND
`:download_get_pip` (reused from REQ-023b) via an intermediate `HP_GETPIP_SKIP_OFFLINE` OR
variable. A future third test flag needing `:download_get_pip`'s real download must extend both.

**Call sites** (all four wired to `embed`): `:handle_conda_failure` (initial chain, right after
conda), `:provider_cascade`'s dispatch (`:cascade_from_conda` targets `:try_embed_fallback`,
`HP_CASCADE_TRIED_EMBED` guard; `:cascade_from_embed` targets `:try_venv_fallback`), the new
`:try_embed_fallback` subroutine itself (on success: `HP_ENV_MODE=embed`, `HP_PY=<extracted
pythonXY.exe>`, `HP_BOOTSTRAP_STATE=embed_env`, leaves `HP_SKIP_PIPREQS` UNSET like venv), and the
dependency-install dispatch in `:after_env_mode_selection` (an explicit `embed` branch was added
before the system-only catch-all, or embed would silently get zero installed deps).

**Warnfix's repair-install dispatch has explicit `venv`/`embed` branches** (each a plain
`"%HP_PY%" -m pip install %%M`) plus a `system`-mode catch-all that stays a no-op but now logs
`[WARN] System fallback: skipping warnfix repair installation.` -- previously venv/embed/system all
silently no-opped while still logging as if the repair succeeded (CLAUDE.md's former Item 36).
The conda test is decided once into `HP_REPAIR_CONDA` before the chain (`HP_ENV_MODE=conda` and
`CONDA_BAT` defined) and the chain tests that flag: a second `if` nested inside the else-if chain captures
every later `else`, so the venv, embed and system branches were silently skipped outside conda mode until
2026-10-11 (see `docs/agent-lessons-learned.md`). Regression:
`tests/selfapps_warnfix_venv_repair.ps1` (uv lane, non-gating) proves the venv branch genuinely installs,
not just that the EXE eventually builds, and `tests/selfapps_cascade.ps1` reports `repairWithoutAttempt`
(a `[REPAIR]` marker with no `Attempting to install:` line) for the embed tier.

---

## uv-First Provider Architecture

### Provider selection flow

```
HP_FORCE_CONDA_ONLY=1 -> always go through Miniconda; uv never tried as primary
HP_TEST_FORCE_UV_FAIL=1 -> fires before the cached-uv check; uv never used
HP_UV_PROVIDING_PYTHON=1 -> set when uv successfully detects Python; gates Miniconda skip
```

When `HP_UV_PROVIDING_PYTHON=1`: Miniconda is not downloaded/installed; `CONDA_BAT` is never set;
all conda-dependent paths (including the corruption check) are bypassed.

### Provider cascade execution re-enters env-create (REQ-009/REQ-005.10 slice 3)

`:provider_cascade` (reached via `if defined HP_CASCADE_APPROVED goto :provider_cascade`) reuses
the existing env-create paths rather than reimplementing them:
- `uv -> conda`: `HP_ENV_MODE=conda`, `ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%`,
  `goto :try_conda_create`. `:cascade_acquire_conda` downloads+installs Miniconda on demand if the
  uv-first run skipped it.
- `conda -> embed`, `embed -> venv`, `venv -> system`: each `call`s the matching `:try_*_fallback`
  then `goto :after_env_mode_selection`. System is reached in any run (only gate: the REQ-014
  consent prompt; CI auto-declines via `HP_CI_LANE` unless `HP_TEST_SYSCON_ANSWER=Y`). System has
  no cascade target of its own -- terminal.

**No-loop guarantee**: each tier is marked `HP_CASCADE_TRIED_<tier>` on first use as a cascade
source; `HP_ENV_MODE` only ever advances (uv->conda->embed->venv->system). A new provider or
reordering must add a matching guard and keep the order monotonic.

**`:after_env_mode_selection` must stay safe to re-enter** (recomputes REQ/DEP_SOURCE/entry/
pyproject state from scratch every time) -- the EXE fast path is NOT re-run on cascade, and
`:run_entry_smoke`'s rebuild-skip is gated on `HP_FASTPATH_USED` (unset on a fresh build), so the
next tier genuinely rebuilds. Any new first-run-only state added here must be made idempotent.

**`runtime.txt` write-back (REQ-004) can poison a cascade re-entry with an unsatisfiable exact
pin.** Write-back fires the moment ANY provider's env setup succeeds, writing the EXACT patch
version that provider reports and reassigning `PYSPEC` to match. Since `:after_env_mode_selection`
recomputes `PYSPEC` fresh on every cascade tier, a LATER provider's own env-create call can receive
an EARLIER provider's exact patch pin verbatim (e.g. uv's `python-3.14.7` forwarded to
`conda create ... python=3.14.7` when conda-forge's own release cadence never shipped that exact
patch) -- confirmed as the real cause of a cascade dead-end via real CI (CLAUDE.md Item 24).
**Fix**: `HP_PYSPEC_WRITEBACK` (set at all 3 write-back sites) signals "the in-memory `PYSPEC` is
now write-back-derived, do not forward it across a cascade." `HP_PYSPEC_ORIGINAL` (snapshotted
immediately before each write-back reassignment) preserves a genuine user-authored pyproject/PEP
723 range so it still reaches a cascade target's solver, rather than unconditionally dropping to
"no constraint." `:try_conda_create` computes `HP_CONDA_PYSPEC_USE` (`%PYSPEC%` normally,
`%HP_PYSPEC_ORIGINAL%` when `HP_PYSPEC_WRITEBACK` is defined) and MUST use it quoted
(`"%HP_CONDA_PYSPEC_USE%"`) at both `conda create` call sites -- a PEP 440 range containing live
`<`/`>` corrupts an unquoted cmd.exe command line. Base drop-to-unconstrained behavior confirmed
via real CI (`self.layered_e2e.chain`'s `pinDropped:true`); the `HP_PYSPEC_ORIGINAL`
range-preservation path itself remains unconfirmed by a real range-constrained cascade run.

**Embed's own PYSPEC-driven version lookup is NOT (yet) given the same treatment** -- its table
lookup already degrades gracefully (falls back to oldest/newest with a WARN) rather than hard-
failing on an unresolvable exact pin the way conda's solver does. Revisit only if a real run shows
this actually misbehaving for embed specifically.

### Genuine (non-cascade) conda-create exhaustion also falls through `:conda_create_done`

Distinct from the cascade re-entry above (`HP_CASCADE_SAVED_PY` undefined here): a GENUINE FIRST
ATTEMPT where `:handle_conda_failure`'s entire embed/venv/system chain has already been tried and
failed. `:conda_create_failed`'s `call :die` now `goto`s straight to `:after_env_mode_selection`
instead of falling through into `:conda_create_done`'s body (which used to unconditionally set
`HP_PY` to a never-created path, re-detect that, and call `:handle_conda_failure` A SECOND TIME --
replaying the embed/venv attempts and the REQ-014 consent prompt twice for one real user).

**Does NOT reduce total pause count to one.** `:after_env_mode_selection` has its OWN
`if not defined HP_PY (...)` check a few dozen lines below its label, which now fires instead
(`HP_PY` is genuinely undefined post-fix) -- the fix relocates pause #2 to an already-precedented
site, it does not eliminate it. A further slice targeting that check is the natural next step if
reducing to one pause is ever pursued.

### Batch 1 (Item 46 Bucket A): the conda-acquisition-probe chain collapses the same way

Sibling fix, one step earlier in the acquisition flow: 5 chained sites (`conda.bat not found after
bootstrap`, `where conda`/`where python`/`python -V` not-found, `Conda not found at:`) all shared
one root cause and could previously stack 4-5 back-to-back `[ERROR]`/pause pairs before finally
reaching `:try_conda_create` and dying there too. Each of the 5 `call :die` lines now also
`goto :after_env_mode_selection`. **Same limitation as above** -- collapses worst-case 5-6 stacked
pauses down to 2 (the first specific site, plus the same `:after_env_mode_selection` sink), not 1.
`:try_conda_install`'s own two failure sites (`:tci_both_failed`, Batch 6, not yet fixed) fall
through INTO this chain's own top as their caller resumes -- Batch 1 already shrinks Batch 6's
remaining blast radius as a side effect (confirmed via `tests/selfapps_conda_bothfail.ps1`). A
second, independent `:try_conda_install` call site (`:cascade_acquire_conda`, the REQ-009 cascade's
own on-demand Miniconda acquisition) does NOT re-enter this chain at all -- its own fall-through
proceeds fairly directly to a conda-create attempt that already `goto`s correctly.

### A future `:die`-halts-the-process change must respect one specific existing test contract

Two INDEPENDENT "exit code" signals exist: the real OS-level process exit code (currently always 0
for nearly every `:die` site, since most fall through to `:success`'s unconditional `exit /b 0`)
and the self-reported `exitCode` JSON field in `~bootstrap.status.json` (from `:write_status`'s
`%RC%` argument, entirely independent of the first). A hypothetical future change making `:die`
itself halt the process (drop `/b`) would start reflecting `%RC%` in the real exit code for the
first time. A full sweep (2026-08-18) found exactly ONE currently-gating test that hard-asserts the
OLD always-0 behavior as its own pass condition:
`tests/selfapps_entrysmoke_no_interpreter.ps1:171`, `($statusState -eq 'error') -and ($runExit -eq
0)`. Every other similarly-shaped assertion pairs with a success/recovery scenario where `:die` is
never reached, so is unaffected. **Anyone implementing this change must update this one test's
contract deliberately** (or justify exempting it) rather than discover the breakage via a red CI
run -- and re-sweep for any NEW such assertion added since 2026-08-18. Note: `:die` already
`pause`s before its `exit /b`, so the commonly-cited risk ("closes the console before a real user
reads the message") does not actually apply to converting it to a bare `exit` -- the pause already
runs first on the real-interactive-user path.

### uv uses managed-only CPython (`UV_PYTHON_PREFERENCE=only-managed`)

Set at the top of the uv acquisition block; every uv command in the process inherits it, so uv
never selects an ambient/system/conda interpreter. A user `runtime.txt`/`pyproject.toml` constraint
is still forwarded via `uv venv --python X.Y`. See `docs/agent-lessons-learned.md`'s "Ambient
Python path leakage" entry for why this exists and the companion "target modern, degrade
gracefully" rule for embedded helpers.

### Lanes and their conda state

| Lane | HP_FORCE_CONDA_ONLY | uv used | Miniconda installed | CONDA_BAT set |
|------|---------------------|---------|---------------------|---------------|
| conda-full | 1 | no | yes | yes |
| real | not set | yes (uv-first) | no | no |
| cache | not set | yes (uv-first) | maybe (cached) | maybe |
| justme-test | not set | no (HP_TEST_FORCE_UV_FAIL=1) | via JustMe | yes |
| contract-uv | not set | yes (forced) | no | no |
| uv-dl-fallback | not set | yes (forces primary URL fail, fallback used) | no | no |

### Test files that assume conda is present -- `skip=true` pattern required

Only 3 files call `Get-CondaBatPath` directly and need the guard: `selfapps_reqspec.ps1`,
`selfapps_pyproject_precedence.ps1`, `selftest.ps1` (its `self.corrupt.conda.*` rows),
`selfapps_pandas_excel.ps1` (all 6 rows). All emit `skip=true` when `HP_FORCE_CONDA_ONLY != '1'`
and conda is absent, and real failures when `HP_FORCE_CONDA_ONLY == '1'`. Every other selfapps file
either runs the full bootstrapper (uv/conda split handled internally) or is restricted to
`conda-full` by CI wiring alone (`selfapps_skiphooks.ps1`, `selfapps_pandas_excel.ps1`) rather than
needing its own guard. Template:

```powershell
if ($env:HP_FORCE_CONDA_ONLY -ne '1') {
    $myPass = $true
    $myDetails.skip = $true
    $myDetails.reason = 'conda-not-installed-uv-first'
} else {
    $myDetails.reason = "conda python missing: $condaPython"
}
```

### EXE fast path vs env-state fast path vs uv venv reuse

| Fast path | Trigger | Log line | Lane |
|-----------|---------|----------|------|
| EXE fast path (`:try_fast_exe`) | `dist\<ENVNAME>.exe` exists AND hash check = "fresh" | `Fast path: reusing ...` (non-interactive) or the interactive launch line | All lanes |
| Env-state fast path (`:env_state_fast_path`) | `~env.state.json` valid, conda env python.exe present | `Env-state fast path: reusing conda env ...` | conda mode only |
| uv venv reuse | `.uv_env\Scripts\python.exe` exists AND `import pip` succeeds | `uv: reusing existing .uv_env` | uv mode only |

**Critical order**: EXE fast path runs at the top of the file, BEFORE provider selection -- if it
fires, uv/conda logic is never reached. The env-state check and uv venv reuse only matter on a
first run or when sources changed.

**`HP_FAST_CHECK`'s freshness signal is content-hash, not mtime** (CLAUDE.md's former Item 39):
`:try_fast_exe` compares a stored `~fast_check.hash.txt` against a composite SHA256 over the
non-infra `*.py` files plus `requirements.txt`/`pyproject.toml`/`runtime.txt`. The write side is
`:write_fast_hash` (a separate subroutine, called from `:success`), gated on `HP_FRESH_BUILD_OK`
-- NOT `HP_FASTPATH_USED` (a corrected bug: `HP_FASTPATH_USED` being unset only proves the fast
path wasn't taken, not that a build succeeded; a skipped/failed rebuild leaving a STALE EXE in
place would otherwise get paired with the CURRENT (changed) source hash, making the next run
wrongly trust the stale EXE). `HP_FRESH_BUILD_OK` is reset once per fresh build attempt and set
ONLY in the genuine build-success branches (PyInstaller clean, or Tier A after PyInstaller failed).
A later repair-loop rebuild (`:hidden_import_recover`/`:dll_bundle_recover`) failing does NOT need
to unset it -- those repair bundling issues, not source content, so the initial successful build in
the same run still genuinely reflects the current source. Both the read (`:try_fast_exe`) and write
(`:write_fast_hash`) call sites share one script (`tools/fast_check.ps1`, mode-dispatched), so a
change to file enumeration/hashing logic stays in sync automatically; only a change to the CALL
SITES themselves risks drift.

### `~dependency_source.txt`: the dependency-source record (Item 76)

`:success` writes `dependency_source=<DEP_SOURCE>` to `~dependency_source.txt` (tilde: it is
bootstrapper-internal, and the standard ignores' `~*` keeps it out of the user's git history) unless
`DEP_SOURCE` is still the `unknown` sentinel. Three CI points collect it by exact name (the test-logs
upload, `publish_diag`'s file list, and its copy pair in `batch-check.yml`);
`tests/test_dependency_source_file.py` fails if the writer and any of those drift apart, and
`self.litter.appfolder` (`selftest.ps1`, every lane) fails on any other non-tilde file the
bootstrapper leaves in the app folder, and also requires the stub entry and the tilde record in the
listing so an empty or wrong listing cannot pass. A copy named `dependency_source.txt` left by an older version
stays where it is; nothing deletes it.

**The litter row found two more non-tilde writers on its first run, both fixed with it** (run `38984687670`,
`litter` lists them): the bootstrapper's own CI marker `.ci_bootstrap_marker` (written at the top of every run,
read by `tests/harness.ps1` and written by three `batch-check.yml` steps) is now `~ci_bootstrap_marker`, and the
uv lane's autopep723 raw output `requirements.autopep.txt` is now `~requirements.autopep.txt`
(`tests/selfapps_autopep_discovery.ps1` reads it; `tools/autopep_merge.py` takes the path as an argument, its
default name is only for direct testing). Any new top-level file the bootstrapper writes needs a tilde, or a name
the user is meant to keep in the row's allow-list.

**`:try_fast_exe` runs twice per stale-EXE run, so its "not reusing" notice lives at the first call
site only** (Item 68). The top-of-file call and the one in `:run_entry_smoke`'s build gate both get an
empty `HP_FASTPATH_TOKEN` for a stale EXE. The `[INFO] Fast path: not reusing ...` line is printed right
after the first call, keyed on `HP_FAST_EXE_PATH` defined (set only when `dist\<env>.exe` exists, so a
first build prints nothing) and `HP_FASTPATH_USED` unset; putting it inside `:try_fast_exe` would print
it twice. `self.wording.rebuild_notice` reads it.

**`DEP_SOURCE` is a sentinel, not an unset flag.** It is initialized to `unknown` at the top of the file
and later set to `requirements.txt`, `pyproject`, `pep723`, `pvw_idempotent` or `pipreqs`. Any gate must
test `"%DEP_SOURCE%"=="unknown"`; `if not defined DEP_SOURCE` is never true (it hid the pipreqs
auto-detect warning until Item 68). `:success` writes `~dependency_source.txt` only when the value is not
`unknown`, so a fast-path or no-source run leaves the previous run's file alone (Item 76).

### `~dependency_installed.txt`: pip freeze output and its consumers

Written after install via `pip freeze` (uv: `uv pip freeze --python "%HP_PY%"`; conda/venv:
`"%HP_PY%" -m pip freeze`). Consumed by `selfapps_pipgap.ps1` (opencv-python check) and copied to
`~environment.lock.txt` in uv mode (the dep-check cache key `~dep_check.py` reads).

### Warnfix install + uv mode

Warnfix's per-module repair loop uses `uv pip install --python "%HP_PY%" %%M` under
`HP_ENV_MODE=uv`, `conda install -y -n "%ENVNAME%"` under conda -- `selfapps_warnfix.ps1` needs no
guard, the bootstrapper handles the split internally.

### autopep723 discovery merge (REQ-005.12, Tier 1)

`:after_pipreqs_run` is inserted immediately after the REQ-005.5 diff-computation log line and
immediately before the dep-check fast-path reset -- re-verify this block still sits between those
two neighbors on any future edit (depends on `requirements.txt` already being finalized by pipreqs,
and must run before `HP_DEP_SKIP`/`HP_DEP_RESULT`/`HP_UV_INSTALL_OK` reset for the fast path).
v1-scoped to `HP_ENV_MODE=uv` only, silently a no-op elsewhere (`HP_UVX_EXE`, derived from
`HP_UV_EXE` not `HP_UV_BIN` -- matters under the `PVW_UV_EXE` override, which never populates
`HP_UV_BIN`). Writes to `requirements.txt` (not `requirements.auto.txt`), so the unconditional pip
gap-fill step picks up anything Tier 1 adds regardless of dep-check fast-path state. Purely
additive merge (`tools/autopep_merge.py`, never removes/reorders existing content) -- a failure
here is non-fatal, the pipreqs-derived `requirements.txt` from earlier in the flow is already
usable. **The merge skips the program's own module and package names** (Item 88): autopep723 lists a
sibling `.py` file or folder as a third-party import, and one name PyPI does not know makes the single
atomic `uv pip install -r requirements.txt` install nothing at all (pandas, openpyxl and the rest were
left out and the EXE verification run exited 1). `local_names()` walks the whole tree below the folder that holds
`requirements.txt` (nested names count, like pipreqs), normalizes like PEP 503 and skips the same folders pipreqs ignores; its `IGNORE_DIRS`
must stay equal to `HP_PIPREQS_IGNORE` in `run_setup.bat` and to `SKIP` in `tools/pipreqs_precheck.py`
(`test_ignored_folders_equal_the_pipreqs_ignore_list` pins the first pair). Skipped names go to the setup
log as `skipped local: a,b` (the helper's stdout is appended to `%LOG%`). Regression:
`self.realapp.local_modules` (`tests/selfapps_realapp_pandas_excel.ps1`, real lane, gating).

### `HP_PVW_KNOWN_IDEMPOTENT` execute-mode discovery (REQ-005.13, Tier 2) hooks in earlier than Tier 1

`:pvw_known_idempotent_run` is called right after `:determine_entry` returns, BEFORE the
pyproject.toml/PEP 723/pipreqs block even begins -- Tier 2's premise is "skip static discovery, use
execution instead." `HP_UVX_EXE` is recomputed independently here (Tier 2's gate is earlier in the
file than Tier 1's, so it can't reuse Tier 1's copy). `uv add --script` only updates the PEP 723
header, not `requirements.txt` -- `:extract_pep723_requirements` is reused to re-extract the
just-updated header afterward. That subroutine runs the embedded `~pep723_extract.py`
(`HP_PEP723_EXTRACT`, Item 62) via `%HP_PY%`, so it needs `HP_PY` and a prior
`:define_helper_payloads`; it must accept the exact layout `uv add --script` writes (indented
items, trailing commas, CRLF), because this feature's own write-back is what produces the header
the next run reads back. Deliberately does NOT set `HP_SKIP_PIPREQS` in production (additive
layering: Tier 2 anchors `requirements.txt`, pipreqs/Tier 1 still get their normal chance
afterward). `tools/pvw_known_idempotent.py`'s `run_script()` leaves the child's stdio fully
inherited (no `capture_output`) and prints its own `RAN:`/`ERROR:` marker to **stderr**, never
stdout, so the user's live script output is never swallowed -- and is bounded by a 120s timeout
(this is a genuine execution of the user's entry script, not a smoke test). Double-execution under
this flag (once here, once later during the real EXE build's verification) is intentional, not a
REQ-018 gap -- the flag's own name is the user's consent. Never gates the lane: any nonzero outcome
just logs `[WARN]` and returns 0.

### PEP 723 write-back (REQ-005.11)

`:pep723_writeback` is v1-scoped to `HP_ENV_MODE=uv` only, called from two sites: `:lock_done`
(fresh-install trigger, `call :pep723_writeback fresh`) and inside the warnfix repair block
(`call :pep723_writeback warnfix`, between the rebuild-complete log line and
`:warnfix_cascade_detect` -- safe from the parse-time-expansion trap because it passes a literal
argument and reads files via runtime `if exist` inside its own call frame). `HP_UV_INSTALL_OK` is
reset in `:after_env_mode_selection`'s existing reset block (same re-entrancy reasoning as
`HP_DEP_SKIP`) and set to 1 in exactly two places: genuine install success, and the
lock-already-satisfied short-circuit. Packages-file staging is a plain `copy` (not a re-derivation)
to `~pep723_pkgs.txt` -- "all-or-nothing per round," since neither trigger point can know which
subset of a failed bulk install actually succeeded. Does not touch venv/conda/embed/system modes at
all -- a future extension needs an `HP_UV_INSTALL_OK`-equivalent per provider plus a matching scope
relaxation in this subroutine's own first line.

**The helper's reason for a failure reaches the setup log through stderr** (Item 73). The batch call is
`"%HP_PY%" "~pep723_writeback.py" ... > "~pep723_result.txt" 2>> "%LOG%"`: stdout is the one result line
(`OK:`/`SKIP:`/`ERROR:`), stderr is appended to `~setup.log`. `tools/pep723_writeback.py` writes the last
five non-blank lines of a failed uv call's stderr there (each cut to 200 ASCII characters, prefixed `uv: `),
for the first call and the strip-and-retry call alike; a successful call logs nothing, because uv can warn
at exit 0 (astral-sh/uv#15956). Never route that text through `:log` (it can hold `<>|&%^`). The helper has
one test hook, `HP_TEST_PEP723_UV_ERR` (treated as uv exiting 1 with that stderr, no uv call), because no
public package installs but cannot be added to a header; `tests/selfapps_pep723_uverr.ps1` (real lane,
gating) is its only user. The payload line is far under the 8191 limit (about 800 characters of margin).

### Dep-check + uv mode lock file interconnection

`dep_check.py` runs for both `HP_ENV_MODE=conda` and `HP_ENV_MODE=uv` (skipped for venv/system --
no lock written, no skip check). `~environment.lock.txt` is the cache key either way (conda: `conda
list --export`; uv: copy of `~dependency_installed.txt`). `HP_DEP_SKIP` is honored in uv mode too.
**The dep-check compares NAMES only** (`requirements.auto.txt` against the lock), so an edited pin or a package added since
the last run can read "all satisfied". `:dep_merge_inputs` therefore sets `HP_DM_CHANGED` when any list, or an include or
option line of `requirements.txt` (`-r`, `-e`, `--index-url`, kept as written), differs from its record, and the dep-check
result `skip` is ignored then (log line `the dependency lists changed since the last run`). The content of a file that a
`-r` line names is not tracked, only the line. A new skip or cache keyed on names alone must honor the same flag.

### Dependency lists merged (`:dep_merge_inputs`, `tools/dep_merge.py`, Item 89)

**Touch the requirements.txt detection, the pyproject helper call, the PEP 723 extraction, the dep-check, the PEP 723
write-back, `:success` or the three list copies below, must understand this.** README REQ-005.1 (merged inputs, rank only
for a conflict). The old behavior was winner takes all (`copy /y` of the highest ranked list over `requirements.txt`).
- **Flow**: requirements.txt is detected as before; the pyproject helper writes `~requirements.pyproject.txt` and keeps
  `HP_PYPROJ_ACTIVE` set (it used to copy the list over `requirements.txt` and clear the flag); the PEP 723 extractor
  writes `%PEP723_REQ%` and `PEP723_ACTIVE`. `:dep_merge_inputs` (called once, right after the extraction and before the
  pipreqs block) counts the inputs. Two or more, or one with records from an earlier run, go to `~dep_merge.py`
  (`HP_DEP_MERGE`, run via `%HP_PY%`, which may be an old interpreter, so its grammar is 3.9-safe); the helper writes the merged
  `requirements.txt` (temp file plus `os.replace`), `~dep_merge.report.txt` (shown with `type`, never `:log`: specs
  hold `<>|&%^`), `~dep_merge.removed.txt` (names to remove from a header we wrote) and `~dep_merge.changed.txt` (a list
  differs from its record). One input and no records: nothing to merge, the old single-list copy (`:dm_single`). Any helper
  failure: `:dm_fallback` warns and uses the highest ranked list alone (exactly the old behavior), the run goes on.
- **Records**: `~dep_base.requirements.txt`, `~dep_base.pyproject.txt`, `~dep_base.pep723.txt`, written by
  `:dep_merge_snapshot` from `:success` (before `:release_lock`) only when the install fully succeeded
  (`HP_DM_INSTALL_FAILED` is set at every install failure site), the state is not `error`, the provider is not system, and
  the header, if we wrote it before, was brought up to date this run (`HP_DM_HAD_HDR_BASE` / `HP_DM_HDR_WRITTEN`). A header
  the user wrote has no record, so it is only ever added to. `pyproject.toml` is never rewritten, so its record only tells
  what the user removed from it. No record: a cold run (union). The records are tilde files, so the litter row ignores them.
- **Rank and "fresh"**: a list entry is fresh when it is new or its normalized spec differs from the record. For one package
  the fresh entries decide (the user's change beats an older pin), otherwise all entries compete by rank header > pyproject
  > requirements.txt, and a bare name never beats a constrained entry. A removal vote (name in a record, gone from a list)
  removes the package everywhere unless pyproject.toml or a fresh entry still lists it (then it stays, with a message).
  The snapshot of `requirements.txt` is taken as the merge wrote it, but `uv add --script` then adds a lower bound to a bare
  name in the header (`toolz` to `toolz>=1.2.0`, uv 0.11), so the first unchanged run after a bare entry was written finds
  nothing fresh, ranks the header's bounded entry above the bare one and rewrites `requirements.txt` once. A test that judges
  an unchanged run byte for byte (`self.depmerge.later.stable`) therefore runs one settling run first.
- **Header removal**: `uv add --script` cannot remove, so `:pep723_writeback` (trigger `fresh`, on `OK:` and on
  `SKIP:no_packages`) calls `:dep_merge_header_remove`, one `uv remove --script` per name; a failure keeps the old
  records so the next run retries. `SKIP:no_packages` is what the helper answers when the merged list names nothing to
  add, for example after the user removed the last package or left only a `-r other.txt` directive; it runs after the
  same `HP_UV_INSTALL_OK` gate as `OK:`, so a failed install still removes nothing (`self.depmerge.later.delete_last`).
  Every other `SKIP:`/`ERROR:` answer leaves the header and the old records alone.
- **Coupled strings**: the report lines `Dependency lists merged`, `Conflict for`, `Removed`, `was removed from ... still lists
  it, so it stays`, the INFO `Dependency lists recorded for the next run`, the WARN `could not be merged` are matched by
  `self.depsource.*`, `self.pep723.pyproject.merge` and `self.depmerge.later.*`; the old `found; overrides requirements.txt`
  wording is gone (`tests/test_dep_merge.py` pins it). Payload margin 560 characters.
- **Not changed on purpose**: the fast path (an unchanged folder never reaches the merge), REQ-004 version precedence, and the
  pipreqs fallback (only when nothing is declared). **Item 91**: the Item 65 runtime-install offer appends its package to
  `requirements.txt` for every dependency source; `:dep_merge_snapshot` records the file as it stands at `:success`, appended
  line included, so the next run's merge keeps it as an ordinary entry.

### `HP_TEST_FORCE_UV_FAIL` / `HP_TEST_CORRUPT_UV` interaction

`HP_TEST_FORCE_UV_FAIL=1` fires BEFORE the cached-uv check where `HP_TEST_CORRUPT_UV` fires -- if
both are set, FORCE_UV_FAIL wins. `tests/selftest.ps1`'s corrupt-uv sub-bootstrap
saves/clears/restores `HP_TEST_FORCE_UV_FAIL` so its own branch is reachable in all lanes.

### Malformed `pyproject.toml` + uv venv failure (uv-first lanes)

`uv venv` reads `pyproject.toml` for `requires-python` even without `--python`, so malformed TOML
makes it exit non-zero BEFORE `HP_PYPROJ_DEPS` (which reads the same file via regex, not a TOML
parser, and exits 0/empty on malformed TOML) ever gets a chance to detect and warn. Fix:
`:uv_venv_fail`, when `HP_UV_PROVIDING_PYTHON=1`, retries via `uv run --no-project python -m venv
.uv_env` (bypasses project discovery entirely -- `UV_NO_CONFIG=1` does NOT help, since
`[project]` metadata is still read regardless; only `--no-project` truly bypasses it). On success,
`HP_PYPROJ_DEPS` then naturally detects the malformed TOML on its own normal pass. Regex fallback:
`re.search(r'^\[project\s*$', txt, re.MULTILINE)` (must not assume `tomllib` -- see the embedded-
helper baseline in `docs/agent-lessons-learned.md`).

### Three TOML readers, one oracle (Item 79)

**Touch any of them, must understand the others and `tests/test_toml_oracle.py`.** `tools/pyproj_deps.py`
(`HP_PYPROJ_DEPS`, `[project].dependencies`: tomllib when the target interpreter has it, else a char walker),
`tools/pep723_extract.py` (`HP_PEP723_EXTRACT`, the header's `dependencies`, walker only) and
`tools/detect_python.py` (`HP_DETECT_PY`, `[project].requires-python`: tomllib, and the old pattern search only
when tomllib is missing or the file does not parse). The two walkers carry the same `unescape` text and the same
closed-array rule, so a change to one is a change to both; the unit tests compare each with tomllib (the PEP's
own regex in `tests/toml_oracle_check.py` for the header), and `self.toml.uvcorpus` (uv lane) feeds the extractor
what real `uv add --script` writes. An unclosed array is refused, never read as a shorter list: `pyproj_deps.py`
exit 2 (the batch's "could not be parsed as valid TOML" warning, then the usual fall-through), extractor exit 1.
`detect_python.py` runs under the orchestration interpreter (uv's managed CPython or Miniconda base, so tomllib
exists); the other two run under the TARGET interpreter, which a `runtime.txt` pin can make older than 3.11, so
keep their grammar 3.9-safe. Payload margins after Item 79: `HP_PYPROJ_DEPS` 2826 characters (the source was cut
to what a maintainer needs; the reasoning is in `docs/plan-toml-reading-hygiene.md`), `HP_DETECT_PY` 520.
Dependency source priority (REQ-005.1) and the requires-python precedence (REQ-004) are not part of this work.

### `HP_FORCE_CONDA_ONLY` as a test-override pattern

Tests that specifically test CONDA BEHAVIOR set `HP_FORCE_CONDA_ONLY=1` themselves (self-contained,
works in all lanes): `selfapps_pipgap.ps1` (conda bulk fail + pip gap-fill), `selftest.ps1`'s
conda_retry/conda_perpkg blocks. Contrast with tests that merely USE conda as a side effect while
testing something else (reqspec, pyproject_precedence, pandas_excel) -- those emit `skip=true`
instead of forcing a download.

### `HP_UV_BIN` locality

`HP_UV_BIN=%HP_SCRIPT_ROOT%~uv_bin` -- rooted at the bootstrapper's OWN directory, never a
user-global/TEMP path. A test copying `run_setup.bat` into a fresh scratch dir therefore always
gets an empty `~uv_bin`, so combined with `HP_OFFLINE_MODE=1` (blocks re-download), uv is ALWAYS
unavailable in that sub-bootstrap -- this is what makes `selfapps_ux_hardening.ps1`'s fallback-chain
tests (`self.venv.fallback`, `self.ux.system.gate.real`/`.accept`, `self.entry.override`) work
correctly even in uv-first lanes. **Never** change `HP_UV_BIN` to a user-global/TEMP-based path --
it would break this isolation and make sub-bootstrap tests depend on whether the parent job already
downloaded uv. `PVW_UV_EXE` (a super-user override) would also break it, but CI never sets it.

### Lane-specific selfapps notes

- `selfapps_isolation.ps1` (`HP_CI_SKIP_ENV=1`): jumps to `:ci_skip_entry`, uses system Python,
  bypasses provider selection entirely -- lane-agnostic, safe everywhere.
- `selfapps_skiphooks.ps1`: provider-independent by design (no `Get-CondaBatPath` call); restricted
  to `conda-full` only by CI wiring, not by the test's own content.
- `selfapps_pandas_excel.ps1`: wired to `conda-full` only in CI; its own `skip=true` guard is
  defensive dead code under current wiring.

### Example apps (`tests/fixtures/examples`, Item 74): files the scenarios read, not generate

**Touch an example file, `selfapps_example_apps.ps1`, `selfapps_pandas_excel.ps1` or `tests/test_example_fixtures.py`,
must understand the others.** The four example programs are plain files a person can copy next to `run_setup.bat`
(`README.txt` in the folder says how). Two scripts read them: `selfapps_example_apps.ps1` (real lane, gating) runs
`stdlib_single`, `multifile_sibling` and `gui_exits` through the whole default path and compares the verification run's
stdout (`~run.out.txt`) with the line each script passes as `-Expect`, so changing what a fixture prints means changing
that string in the same commit (the log line `Chosen entry: <file>` carries the bare file name, not a path, so the entry
check matches a name with an optional directory in front); `selfapps_pandas_excel.ps1` (conda-full) copies `pandas_excel`'s `app.py` and
`requirements.txt`. The unit test pins each folder's exact file list (a stray file changes the `Python file count` the
scenarios assert), ASCII, in-memory compile, imports limited to stdlib / sibling files / declared packages, and the
places that read the folder, so a scenario cannot drift back to an inline copy. A new example app needs an entry in
`APPS`, a mention in `README.txt` and a reader. Not yet moved to the folder: the inline apps of other scripts, because
most are stand-ins for a failure (`selfapps_gui_timeout_hint.ps1`'s `time.sleep(600)`), not examples, and
`selfapps_single.ps1`'s `solo.py`, which that script never reaches in CI (it skips unless the repo root reports exactly
one `.py`; `self.examples.stdlib_single` runs the same program for real). `selfapps_realapp_pandas_excel.ps1` (Item 75)
writes its app inline on purpose (module names no PyPI project uses and a token file as evidence make it a test
stand-in, not an example for a beginner; decided when Item 74 closed, `docs/agent-closed-backlog.md`).

### uv Coverage Status

Covered: `self.contract.uv`/`.pyver`/`.pyver.range`/`.pyver.exactpin` (contract-uv lane -- pyver
tests both an exact pin staying pinned and a loose range resolving to latest-satisfying, not the
floor, via `HP_UV_PY_REQ`/operator-free `HP_UV_PY_DISP`), `self.uv.first.miniconda.skip`,
`self.contract.uv.fail` (contract-uv-fail), `self.uv.managed.interpreter` (all uv-first lanes),
`uv.python.preference.configured` (static), `self.dl.uv.fallback` (justme-test, passes via skip).

**Gap**: the real uv DL-fallback URL path (`HP_TEST_UV_DL_FALLBACK=1`) has no lane exercising it
without also short-circuiting before download is reached.

---

## pipreqs pre-check and UTF-8 copy scan (`:pipreqs_precheck`, Item 63 in `docs/agent-closed-backlog.md`)

**Touch the pipreqs invocation, the pre-check, the result handling, or the `pipreqs.flags` gate, must
understand the others.** pipreqs 0.4.13 opens every `.py` with the locale encoding (cp1252 on Western
Windows before Python 3.15) and aborts the whole scan at the first file it cannot decode or parse, so
`:pipreqs_precheck` runs `~pipreqs_precheck.py` (`HP_PIPREQS_PRECHECK`) first. Contract:
- **Exit 0**: every `.py` is clean UTF-8, pipreqs scans in place (the direct invocation, which now
  carries `--encoding utf-8`). **Exit 10**: something needs a UTF-8 rewrite or must be left out, so the
  helper wrote a UTF-8 copy of the tree under `%HP_PIPREQS_STAGE_ROOT%` and the subroutine ran pipreqs
  there itself, leaving its exit code in `HP_PIPREQS_STAGED_RC`. The caller's
  `if defined HP_PIPREQS_STAGED_RC goto :pipreqs_staged_done` skips the direct invocation and rejoins at
  `:pipreqs_rc_known`. **Anything else (helper failed to emit, exit 3, stage dir unusable)** leaves
  `HP_PIPREQS_STAGED_RC` undefined, so the direct in-place scan runs and a crash is reported honestly.
  `HP_PIPREQS_STAGED_RC` is reset at the top of the subroutine, so cascade re-entry cannot inherit it.
- **Stub files keep module names local**: pipreqs counts every `.py` basename and folder basename in the
  scanned tree as a local module, so a file left out of the copy is replaced by an EMPTY `.py` of the same
  name, not omitted. The copy therefore also keeps empty folders. The helper's `SKIP` set equals pipreqs'
  built-in ignore list and the `--ignore` list is passed in from `HP_PIPREQS_IGNORE`, so the helper and the
  direct invocation prune the same folders; change one list, change the other.
- **Every pipreqs invocation passes `--encoding utf-8`** (direct, UTF-8 copy, and the older robocopy
  fallback), and the `pipreqs.flags` gate in `tests/harness.ps1` requires it on the first matching
  invocation line. The gate also needs that line to start `pipreqs.pipreqs . --force --mode compat
  --savepath`, so keep new flags AFTER `--savepath <target>`.
- **Crash vs. nothing found**: pipreqs exits nonzero and leaves no output both ways.
  `:pipreqs_zero_requirements` (shared by the direct and robocopy guards) treats a
  `Traceback (most recent call last)` line in `%HP_PIPREQS_LAST_LOG%` as a crash: phase `fail`, summary
  note `(pipreqs crashed, ...)`, and the log is appended to `%LOG%` as a FILE (a traceback line can hold
  `<`/`>`, so never through `:log`). Otherwise it is the old `(zero requirements: no imports found)`
  success. The UTF-8 copy run writes its log to the same `~pipreqs_direct.log` (absolute path, because
  the run starts in the copy's folder).
- **Console vs. log**: the report `~pipreqs_precheck.txt` goes to `%LOG%` in full via `type`; only its
  `[WARN]` lines are shown on the console via `findstr /b /l /c:"[WARN]"` (use `/l`: `[WARN]` is a regex
  character class otherwise). Every file name in the report passes through the helper's `safe()` (ASCII
  letters, digits and a few punctuation marks only), which is what makes echoing it safe.
- `:pipreqs_precheck` shares `HP_PIPREQS_STAGE_ROOT`/`HP_PIPREQS_STAGE_TARGET` with the older robocopy
  staging fallback, and `:after_pipreqs_run` removes the root, so the copy never outlives the pipreqs step.
  The root is named `pipreqs_stage_<token>` (`HP_PIPREQS_STAGE_TOKEN`, two `%RANDOM%` values, set once per
  run by whichever of the two sites runs first): the scan deletes its own root before and after, so a
  fixed name let two projects bootstrapping together delete each other's copy. Anything that cleans up or
  looks for the folder must use the variable, never the old fixed name.
- **`requirements.auto.txt` is this run's output or nothing** (PR #480). `:pipreqs_clear_old_output`
  (`del /f /q`, which also removes a read-only file) runs at the top of `:pipreqs_precheck`, so an older file
  can never be mistaken for the scan's result by the `rc 0 and file exists` test at `:pipreqs_rc_known`.
  A file another program holds open survives the delete. The staged path then fails the copy-back
  (`:pipreqs_precheck_copyback_fail`: sets `HP_PIPREQS_COPYBACK_FAILED`, which the caller turns into phase
  `fail` with note `(could not write requirements.auto.txt)` at `:pipreqs_copyback_failed`) and the older
  robocopy fallback's existing copy-back failure goes through the same `:pipreqs_output_blocked`. That
  subroutine prints one console `[WARN]` naming requirements.auto.txt and sets `HP_PIPREQS_AUTO_UNTRUSTED`;
  `:after_pipreqs_run` then refuses to promote the surviving file to `requirements.txt` (otherwise the old
  list would be installed). Any new code that reads `requirements.auto.txt` after the scan must honour
  `HP_PIPREQS_AUTO_UNTRUSTED`. This is not the Item 48 write preflight: that only proves the folder accepts
  a new file, not that one existing file can be replaced.
  **The flag is also set when the delete itself fails** (`:pipreqs_clear_old_output`), because a scan that
  then crashes in every attempt never reaches a copy-back, and the survivor would otherwise pass the
  promotion guard (PR #480 review). A scan that exits 0 clears it again (`:pipreqs_rc_known`'s success block
  and the older fallback's good copy-back), since that scan wrote the file. `:after_pipreqs_run` calls
  `:pipreqs_output_blocked` just before the promotion guard so the console names the file on that path too;
  the subroutine warns once per run (`HP_PIPREQS_BLOCKED_WARNED`, reset with the other pipreqs state).
  The older robocopy fallback's log, `HP_PIPREQS_STAGE_LOG`, is an ABSOLUTE path in the app folder (Item 81):
  that scan runs after `pushd` into the copy, which `:after_pipreqs_run` deletes, so a relative name put the
  log inside the copy and a failed staging scan ended with `<log tail unavailable>` in the summary and no
  traceback in the setup log. `self.pipreqs.output.locked_crash` requires the crash reason to be visible in the
  summary or setup log. Any new log written after a `pushd` must be absolute for the same reason.
  **An absolute path is a user-chosen folder name, so `:write_pipreqs_summary` hands the summary and log paths to
  PowerShell through `$env:HP_SUMMARY_PATH`/`$env:HP_PIPREQS_FAILURE_LOG` and uses `-LiteralPath`**, never pasted into a
  single-quoted literal (a folder named `O'Brien` ends the literal early and the log tail is silently lost; a
  folder with `[` or `]` is a wildcard to `-Path`). `tests/test_pipreqs_precheck.py::SummaryWriterIsApostropheSafe`.
- Regression: `tests/selfapps_pipreqs_encoding.ps1` (`real` lane, gating, forces `PYTHONUTF8=0` because
  Python 3.15 defaults to UTF-8 mode and would hide the cp1252 read) and
  `tests/selfapps_pipreqs_output.ps1` (`real` lane, gating: read-only old output replaced, scan temp folder
  not shared, locked old output reported by name, locked old output never installed when every scan
  crashes; the lock is held with `FileShare.Read`, the crash is forced with `REQUESTS_CA_BUNDLE` pointing at
  a missing file); unit tests
  `tests/test_pipreqs_precheck.py`.

---

## One elevation test (`:detect_elevation`, Item 78) feeds the per-run log line and the Miniconda AllUsers branch

`:detect_elevation` (next to `:log`) sets `HP_ELEVATED=1` when `fsutil dirty query %systemdrive%` succeeds
and leaves it empty otherwise; `HP_TEST_NOT_ELEVATED=1` forces "not elevated" for CI. Two callers must stay in
step: the main flow logs `[INFO] Elevated: yes|no` exactly once per run (right after the Host PowerShell
line; `self.elevation.logged` counts it in the stub run's `~setup.log`), and `:try_conda_install`'s AllUsers
branch skips straight to JustMe when it is empty. Test with `if defined`/`if not defined`, never `%HP_ELEVATED%`
inside a parenthesized block. The NI-VISA failure `[WARN]` lines (`pyvisa.nivisa.warn`) are console
`call :log "[WARN] ..."` lines at the two `[VISA] install_failed` sites; the elevation line is what lets a
reader of a field log tell an elevated failure (the reported `-125202`) from a non-elevated one.

## NI-VISA scanner contract `0|1|2` and `:visa_subfolder_gate` (Item 78 slice 2)

**Touch `tools/detect_visa.py` (`HP_DETECT_VISA`), the VISA block in `:lock_done`'s tail, or the gate, must
understand the others.** The scanner prints `0` (no match), `1` (a match in the folder next to `run_setup.bat`)
or `2` (every match below a subfolder), logs up to three `[VISA] pyvisa/visa import found in: <path> (top
folder|subfolder)` lines on stderr (the batch appends stderr to `%LOG%`, so they never pass through `:log`), and
writes the first path to `~visa.where`. Every path is reduced to ASCII letters, digits and `. _ - space \`
before it is printed, because the batch echoes it unquoted in the prompt; a new output field must get the same
treatment. The batch lets both `1` and `2` through the first check, but the install step still requires
`NEED_VISA` to be exactly `1`: `:visa_subfolder_gate` is `call`ed for `2` after the `HP_SKIP_NIVISA` and
already-installed checks, sets `NEED_VISA=1` only on an explicit yes, and leaves it at `2` (logging
`[VISA] skipped (subfolder_only)`) otherwise. The gate follows the CI-safe pattern (prompt echoed first,
`HP_TEST_VISA_ANSWER`, then `HP_CI_LANE`/`NOINPUT`/`HP_NONINTERACTIVE` decline, then a 30 second `choice` that
defaults to no; `HP_TEST_FORCE_INTERACTIVE_VISA` forces the real prompt at 2 seconds). It remembers its answer
in `HP_VISA_DECISION` so a cascade re-entry does not ask twice. That variable is cleared ONCE at the top of the
file (next to the `PVW_BUILDER` parse), never inside the VISA block, which a cascade re-entry runs again: an
`HP_VISA_DECISION` inherited from the calling terminal would otherwise be taken as the user's answer and the
question never asked (`self.nivisa.subfolder.declined` runs with a stale `Y` inherited; `tests/test_detect_visa.py`
pins the single clear before the scanner). The `accepted` scenario runs last in `tests/selfapps_pyvisa_subfolder.ps1`
because it may really install NI-VISA on the runner, after which every later scenario would see `[VISA] present`.
A top-folder match (`1`) never prompts and installs exactly as before. Regression: `tests/test_detect_visa.py` and `tests/selfapps_pyvisa_subfolder.ps1`.

---

## Visual C++ runtime warning (`:warn_runtime_dll`, Item 77) reads the captured run output at three call sites

`:warn_runtime_dll` scans `~run.err.txt` and `~run.out.txt` for `DLL load failed` and warns only when
System32 also lacks `msvcp140.dll` or `vcruntime140_1.dll` (`HP_TEST_VCRT_MISSING=1` reports both missing, since CI
runners have the runtime); it never installs the runtime. It is called where a failed verification run is
reported: `:smokerun_ndjson`'s FAILED branch (EXE path), `:verify_no_exe_interpreter`'s legacy else branch,
and the line after `:run_failfast_probe interpreter` (the path a double-click user takes). Any new
verification site that writes a failed run's output to `~run.*` should call it too. Not covered on purpose:
`:try_fast_exe` (a cached EXE that fails is discarded and rebuilt, so the rebuilt run reports it) and
`:hidden_import_recover`'s diagnostic re-run. A DLL failure with another cause stays silent. Regression:
`tests/selfapps_vcruntime.ps1` (`real` lane, gating).

---

## Single-verification smoke model (REQ-018 2b-A.2)

The bootstrapper runs the user's code for MANDATORY verification exactly ONCE per invocation (the
pre-build interpreter smoke and a second EXE smoke were merged into one; an accepted post-execution
checkpoint can still launch an OPTIONAL second run). Touching this flow requires understanding
`tests/selfapps_envsmoke.ps1`/`selfapps_skiphooks.ps1`, coupled by exact log strings:

- **EXE path = primary verification** (`:run_exe_smokerun`). Emits `[INFO] Running entry script
  smoke test via packaged EXE.` and `[INFO] Entry smoke exit=%HP_EXE_EXIT%`, matching the log
  vocabulary the (now-removed) pre-build interpreter smoke used to emit, and captures EXE
  stdout/stderr to `~run.out.txt`/`~run.err.txt` at the app root. **Runs from the app root now, not
  `dist\`** (CLAUDE.md Item 38, resolved) -- the same CWD `:try_fast_exe`/
  `:verify_no_exe_interpreter` and the interpreter's own run already use, so a CWD-relative-path
  app (e.g. `open("config.json")` next to the script) can no longer disagree between a fresh build
  and a fast-path reuse. Two narrower `pushd dist` sites remain deliberately deferred
  (`:offer_optimized_build`'s internal verify, `:hidden_import_recover`'s diagnostic re-run) --
  each carries its own comment naming the deferral; no test depends on either site's CWD.
  `sys.argv[0]`-relative files (not CWD-relative) still land in `dist\` for a frozen EXE regardless
  of this fix -- an inherent EXE-vs-script difference, not something to normalize.
  If any of this vocabulary/paths changes, `harness.ps1`'s `batch.smoke.single_verify` and
  `self.env.smoke.run`/`self.prime.run`/`self.prime.bootstrap` break.
- **No-EXE path** runs the interpreter ONCE via `:verify_no_exe_interpreter`, UNTIMED on purpose
  (the interpreter run IS the user's real run there, not a throwaway) -- skipped when an EXE
  exists, the fast path ran it, or `HP_SKIP_ENTRY_SMOKE`.
- **skiphooks** (`HP_SKIP_ENTRY_SMOKE` + `HP_SKIP_EXE_SMOKERUN`): both exit before the vocab line,
  so no user code runs.
- The `~run.out.txt` capture reflects the PRE-recovery run (before hidden-import recovery); the
  fail-fast probe's own capture (below) is a separate, pre-truncated write of the same two files.

## Fail-fast probe (Slice 2b-C): shared state machine for the two untimed launch points

`:try_fast_exe` and `:verify_no_exe_interpreter` launch with no timeout in CI (unchanged). For a
real interactive user (`HP_INTERACTIVE_RUN`, or `HP_TEST_FORCE_INTERACTIVE_PROBE=1` for CI
coverage), both call `:run_failfast_probe` instead, via the emitted `~failfast_probe.ps1`
(`HP_FAILFAST_PROBE` -- an emitted file, not inline `-Command`, because the two-stage wait needs
interpolated strings). `WaitForExit(HP_FAILFAST_PROBE_MS)` (default 10000ms -- a classification
checkpoint, unrelated to the separate ~30s hard-kill cap used by `:run_exe_smokerun`/
`:hidden_import_recover`), then, if still running, a SECOND unbounded wait with no `Kill()`.

**Touch either call site, must understand the other, plus the top-of-file success gate:**
- `HP_PROBE_ARGS` is a complete, ready-to-use Arguments string (caller quotes each token;
  `~failfast_probe.ps1` assigns it VERBATIM to `ProcessStartInfo.Arguments`, no extra wrapping).
  CWD matches across all three call sites (`:try_fast_exe`, `:verify_no_exe_interpreter`,
  `:run_exe_smokerun` -- all app root, no `pushd dist`).
- `HP_SMOKE_RC` always ends up the true final exit code; `HP_PROBE_EXCEEDED=1` iff the probe window
  was crossed. `:try_fast_exe`'s discard-and-rebuild is gated on `not "0" AND not
  HP_PROBE_EXCEEDED` -- once classified alive/healthy, a LATER non-zero exit is presumed the user's
  own program outcome, never discarded.
- `HP_FASTPATH_RUN_FAILED` (true only when `HP_SMOKE_RC` is defined and non-"0") gates whether the
  top-of-file fast-path shortcut's `[STATUS]` line shows the true outcome before `goto :success` --
  `HP_BOOTSTRAP_STATE` stays `ok` regardless (a runtime bug in the user's own code isn't fixable by
  a rebuild), but the console must never silently claim success. Both `:try_fast_exe` call sites
  (top-of-file and inside `:run_entry_smoke`'s build gate) carry this guard.
- **cmd.exe parse-time-expansion hazard**: both dispatch sites use `if defined HP_INTERACTIVE_RUN
  goto :<label>_probe`, never a parenthesized if/else around a launch+`%ERRORLEVEL%`-capture
  sequence (see `docs/agent-lessons-learned.md`'s "Provider-cascade dispatch is goto-based on
  purpose" for why the parenthesized form silently freezes `%ERRORLEVEL%` to its pre-block value).
- NDJSON row `self.failfast.probe` carries `details.site` (`fastpath`/`interpreter`/`checkpoint`)
  -- not guaranteed at most once per stream, since the post-execution checkpoint can trigger it a
  second time.

### Live-echo mechanism (both `~failfast_probe.ps1` and `~exe_smokerun.ps1`)

Both helpers live-tee the child's stdout/stderr via chunk-based `StreamReader.ReadAsync(char[],
int, int)` polling (one read in flight per stream, enforcing ordering by construction),
`[Console]::Out.Write($chunk)`/`[Console]::Error.Write($chunk)` (no auto-newline -- chunks land at
arbitrary boundaries), EOF is a 0-length read. Chunk-based (not line-based `ReadLineAsync`)
specifically because Python's `input("prompt")` flushes its prompt WITHOUT a trailing newline; a
line-based reader would leave a live user staring at a blank screen until something else flushed a
line. (Full supersession history -- `Register-ObjectEvent`'s cross-thread reordering bug,
`ReadLineAsync`'s no-trailing-newline blind spot -- lives in `docs/agent-lessons-learned.md`.)

Each helper's own `"$exceeded|$exitcode"` result is written to a DEDICATED file
(`HP_PROBE_RESULT`/`HP_SMOKERUN_RESULT`), never printed as the script's own final stdout line --
capturing that via `for /f` backtick-substitution would swallow every live-teed line into the
result parse. The batch caller invokes each helper DIRECTLY (a plain top-level `powershell -File`
statement, not `for /f`-wrapped) so live output flows straight to the console, then reads the
result file via a separate `for /f` afterward.

`~exe_smokerun.ps1` (`HP_EXE_SMOKERUN`, `tools/exe_smokerun.ps1`) is NOT a reuse of
`~failfast_probe.ps1` -- it is the sole verification pass for a build never confirmed working, so
after `HP_SMOKERUN_KILL_MS` (default 30000, test-only override) it calls `$p.Kill()`, conditionally:

### Activity-aware EXE-smoke kill

`Kill()` fires ONLY if the process has produced ZERO output by the deadline -- any output (even
one chunk, even with no trailing newline) skips the kill for the rest of the run, unbounded,
mirroring the fail-fast probe's "classify once, then never kill" philosophy. "Any output" is the
proxy for "interactive input was likely received," since the parent cannot observe stdin directly
and `input(prompt)` is confirmed to flush before blocking. **Accepted trade-off**: a process that
prints once (a startup banner) and then genuinely deadlocks for an unrelated reason now hangs
indefinitely instead of being caught at 30s -- an explicit owner decision ("if interactive input
was received then extend or stop the timeout... don't change the timeout" otherwise).
`:warn_user_code_launch` takes a `main`/`hidden_import` parameter with different wording per
caller, since `:hidden_import_recover`'s own separate, still-unconditional 30s check is
deliberately NOT migrated to this activity-aware behavior.

### Process-ID display for stuck-program recovery

Both `~exe_smokerun.ps1` and `~failfast_probe.ps1` print `[INFO] Process ID $($p.Id). ... Task
Manager > Details tab > find this PID > End Task ...` right after `Start()` -- `TerminateProcess`
(what End Task calls) targets a single PID directly, unlike `Ctrl+C`/`CTRL_C_EVENT` (rejected:
broadcasts to the WHOLE console process group, would also hit `cmd.exe`/`powershell.exe`). Uses
`Write-Host` deliberately (auto-newline, never captured into the output buffers, so it can't be
mistaken for the user's own program output).

### Argv passthrough (REQ-026, P1)

`HP_APP_ARGS` is captured ONCE at the very top of `run_setup.bat` from `%2`-`%9` (never via
`shift`, since `%~1` is read directly at several later call sites) -- caps the feature at 8 extra
arguments. **`HP_PROBE_ARGS`'s contract is "caller provides a fully-quoted, ready-to-use string,
used VERBATIM"** -- NOT wrapped in an extra pair of quotes by the receiving script (a pre-existing
single-quote-wrap was correct only for one token; wrapping multiple pre-quoted tokens collapses
them into one argv element). Every assignment site must quote/re-quote per this contract:
`:try_fast_exe_probe` (`%HP_APP_ARGS%` alone, EXE is self-contained), `:verify_no_exe_probe`/
`:run_postexec_checkpoint` (`"%HP_ENTRY%"%HP_APP_ARGS%`, entry path re-quoted first). The two
direct (non-probe) legacy branches append `%HP_APP_ARGS%` as ordinary additional quoted tokens.
`tools/exe_smokerun.ps1` needed a NEW variable (`HP_SMOKERUN_ARGS`, no prior `Arguments` handling
at all), same contract.

`:log` must never interpolate `%HP_APP_ARGS%`'s content -- a user argument can legally contain
`<`/`>`/`|`/`&`. The one new log line this feature adds is content-free ("extra launch argument(s)
detected").

`:hidden_import_recover`'s own EXE re-run and the CI-only `HP_CI_SKIP_ENV=1` path deliberately do
NOT receive `HP_APP_ARGS` (a diagnostic re-run of an already-verified build; test infra with no
interactive terminal to benefit). `:offer_optimized_build`'s internal build-verify launch DOES need
it (it launches a brand-new, never-before-executed Nuitka binary) -- but reads `$env:HP_APP_ARGS`
directly in PowerShell rather than cmd.exe-substituting `%HP_APP_ARGS%` into `-Command` text, since
the value contains literal embedded double-quotes per token that would corrupt naive substitution.

### First-argument check (Item 67): runs before the fast path, hands `:determine_entry` a normalized name

**Touch the pre-flight order, the fast path, or either `:determine_entry` call site, must understand
the others.** The block after the REQ-011 check validates `%1` (empty is fine; a `*` or `?` is
rejected because `if exist` treats them as patterns; otherwise it must be an existing `.py` as typed,
or `%1.py` must exist, and neither may be a folder: `if exist` is true for a folder, so each test is paired
with `if not exist "<name>\"`, which is true only for a file) and stops with a usage message, status `error`, exit 1 and a released lock.
Order matters: REQ-011 (cross-folder) first, then this check, then `:compute_interactive_run`, then
`:try_fast_exe`. The forwarded program arguments still start at `%2` (`HP_APP_ARGS`), so a first
argument that was silently dropped used to shift every argument by one, which is what made the
cached EXE fail fast and get discarded.
- `HP_ENTRY_FILE_ARG` (not `HP_ENTRY_ARGS`, the py-launcher arguments) is the normalized name; both
  `call :determine_entry` sites (inside `:ci_skip_entry`'s caller and `:after_env_bootstrap`) pass
  it instead of `%~1`. Any new reader of the entry argument must use it, or a name typed without
  `.py` would be seen raw. The `HP_CI_SKIP_ENV` path never reads `%1` for entry selection, but the
  validation still runs there.
- Every early top-level stop that can happen after `:acquire_lock` must `call :release_lock` (the
  REQ-011 stop did not, so a rejected drag-and-drop blocked the next run in that folder for up to
  two hours; `self.entryarg.stops_release_lock`).
- Regression: `tests/selfapps_entryarg.ps1` (`real` lane, gating).

### Honest ambiguous-exit messaging (REQ-027, P2)

`:print_no_exe_briefing`'s header now dispatches on `HP_NOEXE_VERIFY_FAILED` (set in both branches
of `:verify_no_exe_interpreter` whenever `HP_SMOKE_RC` is nonzero) rather than unconditionally
claiming "your code ran successfully" -- mirrors the pre-existing `HP_EXE_VERIFY_FAILED` pattern
for the EXE path. A new `:print_fastpath_ambiguous_note` (called from
`else if defined HP_FASTPATH_RUN_FAILED`) closes the OTHER previously-silent gap: the "cached EXE
kept despite a later non-zero exit" case had NO postflight panel at all (the fast path's own
briefing dispatch is entirely skipped by design). Plain informational print, no consent gate --
points at the direct-run command and at deleting `dist\<env>.exe` for a fresh dependency check.
Neither panel asserts a root cause (real bug vs. unresolved dependency vs. something else stays
undistinguished, by design).

Rows and the exact strings they match (README REQ-027.1 to .3): `self.honest.noexe.caveat`
(`tests/selfapps_pyinstaller_fail.ps1`, `execfail_runtimefail`) matches the caveat heading, the "so we can't tell
whether that's a bug ... or something this bootstrapper missed." sentence, the absence of the success heading and
of "your code ran successfully just now", and the `[WARN] REQ-016: Post-flight briefing printed; no EXE produced,
interpreter run also unverified.` log line; `self.honest.fastpath.note` / `.outcome`
(`tests/selfapps_failfast_probe.ps1`, alive scenario) match the "SETUP COMPLETE -- BUT WE CAN'T CONFIRM" heading,
"Delete dist\<exe name> and run this bootstrapper again.", the `[WARN] REQ-016: Post-flight note printed; ...` line,
state `ok` and exit code 0. Both read the console text with whitespace flattened (the panels wrap sentences over
several `echo` lines), so a reworded or re-wrapped sentence only needs the test string updated, but a changed
heading or log line breaks the rows by design.

## Post-execution checkpoint (Slice 2b-C, second half)

`:run_postexec_checkpoint` is a **consent gate** (echo prompt unconditionally, then
`HP_TEST_CHECKPOINT_ANSWER` override, then `HP_CI_LANE` auto-decline, then interactive `set /p`) --
NOT the `HP_INTERACTIVE_RUN` silent-skip convention the fail-fast probe uses; do not conflate the
two. Called at the end of every FRESH verification run (`:smokerun_ndjson` and both branches of
`:verify_no_exe_interpreter`) -- never from `:try_fast_exe`'s reuse (would violate the fast path's
zero-friction rule even on auto-decline, since the prompt still echoes in CI). On accept, reuses
`:run_failfast_probe` (site `checkpoint`) with its OWN output files
(`~checkpoint_run.out.txt`/`.err.txt`) and explicitly saves/restores `HP_SMOKE_RC`/
`HP_PROBE_EXCEEDED` around the call so the caller's own downstream code still sees the FIRST run's
result. Cascade re-entry can offer this (and `:offer_optimized_build`'s prompt) more than once per
bootstrap -- each cascade tier is a genuinely different build.

**The four elective offers (this checkpoint, `:offer_optimized_build`, `:runtime_install_offer`, `:last_chance_offer`)
decline without waiting when `NOINPUT`, `HP_NONINTERACTIVE` or `HP_CI_LANE` is set (README REQ-018.9, Item 94b).** Each
gate has the same shape: the heading echo line, then three live `defined <SIGNAL>` lines, then the line that reads the
answer (`set /p` or `choice`), and a decline `call :log` line. `tests/selfapps_offers_noninteractive.ps1` (real lane,
gating, rows `self.offers.noinput`/`.nonint`/`.cilane` plus the no-signal control `self.offers.control`) runs each
signal alone with closed standard input and reads the heading, the absence of the prompt text and the decline line from
the console log; `tests/test_offers_noninteractive.py` pins the shape in the batch and the regexes against the real log
lines. A new elective offer needs the same gate and an entry in the script's `$specs`, or the row for that offer does
not exist. The other gates (cascade, system-build, corrupt-conda) still read only `HP_CI_LANE` (open question 2).

**Cascade approval skips BOTH elective offers, but ONLY at the `exe` call site, ONLY when the
CURRENT tier's cascade was just approved** -- asking about a build the user just opted away from
wastes real time (the optimized-build offer alone can take a minute+). **The smoke run ITSELF is
never skipped**, even then: `HP_CASCADE_APPROVED` only means the next tier will be TRIED, not that
the cascade actually reaches one (every remaining tier could still be unavailable/declined,
falling back to keeping the CURRENT build) -- so `:run_exe_smokerun` always runs; only the two
elective follow-up calls inside `:smokerun_ndjson` are conditionally wrapped.

**`:cascade_consent_gate`'s real-interactive branch uses a TIMED `choice /T` prompt** (default 30s,
mirrors `:pick_entry_interactive`'s pattern; `/D N` on timeout) instead of an unbounded `set /p` --
several sibling gates still use unbounded `set /p` and share the same "hangs unattended" property,
fixing all of them was out of scope for this pass. A companion "dependencies may be incomplete"
note (`HP_DEP_MAYBE_INCOMPLETE`, set when a cascade candidate was detected but not approved) warns
at decision time and again right before the EXE launches -- a note, never a second gate.

## Runtime missing-module scan (`:scan_runtime_missing_module`, Item 65 slice 1)

**Touch how a run's stderr is captured, or add a new place that runs the user's program, must
understand this scan.** A program can print `ModuleNotFoundError: No module named X` and exit 0 (a GUI
toolkit catches an exception raised in a callback and keeps running), so the exit code never shows it.
`:scan_runtime_missing_module <site> <stderr-file>` runs `~runtime_module_scan.py`
(`HP_RUNTIME_MODULE_SCAN`, `tools/runtime_module_scan.py`) over the stderr of the run that just finished.
- **Call sites**: `:smokerun_ndjson` (EXE verification run, `~run.err.txt`), the legacy branch of
  `:verify_no_exe_interpreter` (`~run.err.txt`), and `:run_failfast_probe` just before its cleanup (covers
  the interactive interpreter run, the post-execution checkpoint's `~checkpoint_run.err.txt`, and the
  cached-EXE probe). A new launch point that captures stderr should call it too.
- **No interpreter, no scan**: it returns at once when `HP_PY` is undefined. The cached-EXE fast path runs
  before provider selection, so it is skipped by design (README REQ-018 says so).
- **What it reports**: a top-level name from `No module named 'X'` that `find_spec` cannot find, is not in
  `sys.stdlib_module_names`, and is a plain identifier. The helper runs from the app folder, so a module file
  next to the user's script is found and not reported. A stdlib name (the embeddable Python has no tkinter)
  is a different problem and pip advice would be wrong. Names are identifiers only because `:log` and the
  reminder echo them unquoted.
- **State**: `HP_RTM_INIT` (set on the first scan of a bootstrap run, which empties
  `~runtime_missing_modules.txt`), the file itself (one name per line, so each module is reported once per
  run even if the checkpoint run repeats it), and `HP_RTM_FOUND`. `:success` prints
  `:print_runtime_missing_reminder` before `:release_lock`, which also deletes the file.
- **Which file the advice names**: `:rtm_where` sets `HP_RTM_WHERE` from `DEP_SOURCE` for both advice lines
  (the second `[WARN]` line and the closing reminder): `requirements.txt` by default, `the dependencies in
  pyproject.toml` for `pyproject`, the PEP 723 header for `pep723`. Those two outrank `requirements.txt`
  for a conflict about one package (Item 89; before it they were copied over `requirements.txt` on every run, so
  the advice would have been lost, CodeRabbit PR #487), so the advice still names the file the run reported.
  A new place that tells the user to edit a dependency file must use the same variable.
- **The scan itself is diagnostic only**: it installs nothing, edits no file and runs nothing. The install
  is slice 2, described next, and starts from this scan's state (`HP_RTM_FOUND`, the names file).
- **NDJSON**: the bootstrapper writes `self.runtime.module_missing` to `HP_NDJSON` when it is defined;
  `tests/selfapps_runtime_modnotfound.ps1` (`self.runtime.modnotfound`, real lane) points it at a private
  file and reads it back.

### Consented install of a runtime-missing package (`:runtime_install_offer`, Item 65 slice 2)

**Touch the scan's state, `:smokerun_ndjson`, either interpreter verification branch, or the PyInstaller
accumulators, must understand this.** After the scan, `:smokerun_ndjson` (site `exe`) and both branches of
`:verify_no_exe_interpreter` (site `interpreter`) call `:runtime_install_offer`. It runs at most once per
bootstrap (`HP_RTI_OFFERED`, so a cascade tier does not ask again) and never for system Python, a missing
interpreter, or a Nuitka-built EXE (`HP_NUITKA_FALLBACK_USED`, whose rebuild flags would be wrong): those log
one `[INFO] Runtime install: not offered` line and write state `not_offered`.
- **Prompt**: the CI-safe consent-gate pattern. The prompt text is echoed unconditionally, then
  `HP_TEST_RTM_ANSWER` (Y or N) wins, then `HP_CI_LANE`/`NOINPUT`/`HP_NONINTERACTIVE` resolve to no, then a
  `choice /T 30 /D N`. A bare Enter, a timeout and a missing `choice.exe` all mean no.
- **Module to package**: `~runtime_module_scan.py --packages` prints `module package` per line. The table
  (`_PIP`, one conda difference `_CONDA`) is a subset of `tools/parse_warn.py`'s `TRANSLATIONS`; a unit test
  fails when they disagree, except `cv2` (warnfix says the conda-forge name `opencv`, PyPI says
  `opencv-python`). Any other name is installed as is, which is why the prompt lists every package first.
- **Install** (`:rti_install_one`): `uv pip install --python`, `conda install --override-channels -c
  conda-forge`, or `python -m pip install`, the same dispatch the warnfix repair uses. Successes are written
  to `~runtime_install_ok.txt`; none succeeding stops with state `install_failed`. `--append` then adds each
  package to `requirements.txt` unless already declared (keeps CRLF/LF, creates the file if absent), for EVERY
  dependency source (Item 91; the `HP_RTI_EDITS` flag and the second prompt wording are gone). Before Item 89 a
  `pyproject.toml` or PEP 723 list was copied over `requirements.txt` on every run, so the append would have vanished and the
  offer edited nothing for those sources; since Item 89 the merge keeps a list's change since the last run, and the line
  lasts. The offer edits no other file: `pyproject.toml` is never rewritten and the header is only brought up to date by the
  usual write-back of a later run. Do not hand-edit TOML from batch or this helper (Item 79 is about TOML reading hygiene already).
  Rows `self.runtime.install.pyproject` / `.pep723` bootstrap the folder a second time (EXE folder deleted, answer N) and require
  the line to survive it.
- **Rebuild** (`:rti_rebuild`, site `exe` only): `--hidden-import=X --collect-submodules=X` for each installed
  module, appended to `HP_PYI_HIDDEN_IMPORTS`/`HP_PYI_HID_COLLECT`, and the command threads all five
  accumulators like every other rebuild in the lifecycle. A failure sets `HP_BOOTSTRAP_STATE=error`, clears
  `HP_FRESH_BUILD_OK` and stops (no cascade). The `.spec` and `build\` are cleaned unless the user had a spec.
- **Verification run**: the existing verification subroutine runs again with `HP_RTI_VERIFYING=1` set. While
  it is set, `:runtime_install_offer` returns at once, `:smokerun_ndjson` returns before the elective
  checkpoint and optimized-build offers and before clearing `HP_EXE_EXIT`, and the interpreter branches skip
  the checkpoint. The outer call then continues to those elective offers once, against the final build.
  `~runtime_missing_modules.txt` is moved to `.prev` first so the nested scan reports afresh; the result is
  state `verified` (nothing named), `still_missing`, or `not_verified` (`HP_RTM_SCAN_RAN` never became set,
  for example a skipped run, in which case the old names are restored for the reminder).
- **NDJSON**: `self.runtime.install` with `details.state` (`declined`, `not_offered`, `install_failed`,
  `rebuild_failed`, `verified`, `still_missing`, `not_verified`), `site`, `provider`, `depSource`, `packages`;
  `pass` is always true because a state is a finding. The verdicts live in `tests/selfapps_runtime_install.ps1`
  (`self.runtime.install.accept`/`.decline`/`.pyproject`, real lane).
- **Payload margin**: `HP_RUNTIME_MODULE_SCAN` has 354 characters left under the 8191 limit. Item 82's
  last-error-line extraction does not fit; give it its own payload or shrink this one first.
- **Not covered**: a native DLL a newly installed conda package needs is not bundled (`:dll_bundle_recover`
  does not run again), and with a `pyproject.toml` or PEP 723 dependency source the package stays installed
  in the environment and in the rebuilt EXE, but a later source change that triggers a rebuild goes back to
  building without the `--hidden-import` flags until the user adds the package to that file.

## Last-chance offer (`:last_chance_offer`, Item 82 slices 1 and 2)

**Touch how a verification run's exit code is kept, the checkpoint's result, or the cascade flag, must
understand this offer.** After a fresh uv build whose verification run ended with a real non-zero exit, ONE
untimed prompt offers W (it actually worked), C (try again with Miniconda) or N (neither, the default).
`:run_entry_smoke` calls it right after `:verify_no_exe_interpreter`, BEFORE `HP_FASTPATH_USED` is cleared a few
lines later. C only sets `HP_CASCADE_APPROVED`; the main line already reads that after `:run_entry_smoke`
returns, so `:provider_cascade` needed no change, and the conda tier's own run is judged by its own inputs.
- **Inputs, all captured where they would otherwise be lost**: `HP_LC_EXIT` and `HP_LC_SITE` (`exe` from the
  end of `:smokerun_ndjson`, just before it clears `HP_EXE_EXIT`; `interpreter` from the end of both branches of
  `:verify_no_exe_interpreter`), and `HP_LC_CKPT_RC` (the accepted checkpoint's interpreter exit, taken in
  `:run_postexec_checkpoint` before it restores the first run's `HP_SMOKE_RC`). `:run_entry_smoke` clears all three
  at the start of every attempt, and `:lc_cleanup` clears them after every call, so a cascade tier never judges its
  run by an earlier tier's numbers. A run that is skipped (`HP_SKIP_ENTRY_SMOKE`) never sets `HP_LC_EXIT`.
- **Not offered** (log line `Last chance: not offered (<reason>).` and a row, only after a failing run): exit 0
  leaves nothing at all, and exit `-1` goes to the window question below instead of this prompt. Reasons: `provider` (not uv, or `HP_CASCADE_TRIED_UV`), `cascade_approved`
  (the early prompt already approved), `runtime_install` (`HP_RTI_OFFERED`, Item 65 slice 2 already asked about this
  run), `checkpoint_ok` (the accepted checkpoint ran the interpreter and it exited 0: a packaging problem, not the
  environment).
- **Gate order** (same CI-safe pattern as the other consent gates): the prompt text is echoed first, then
  `HP_TEST_LASTCHANCE_ANSWER` (W, C or N, checked first so a test can answer even under `HP_CI_LANE`), then
  `HP_TEST_FORCE_INTERACTIVE_LASTCHANCE` (forces the real read), then `HP_CI_LANE`, `NOINPUT`, `HP_NONINTERACTIVE`
  (state `automated`, no wait), else `set /p`, untimed on purpose (the decision). Anything but W or C is N.
- **The window question (slice 2, `:lc_window`)**: exit `-1` is the smoke runner's force-stop of a silent program,
  which is what a window app looks like, and also what a failed launch or a program that exits by itself with `-1`
  reads as. The question "Did it open and work? [y/N]" is asked only on the conda tier the cascade reached
  (`HP_ENV_MODE=conda`, `HP_CASCADE_TRIED_UV`, no `HP_CASCADE_APPROVED`) AND only when `HP_EXE_KILLED_SILENT` is set.
  That flag comes from one place: `~exe_smokerun.ps1` writes `~smokerun_killed.txt` inside its `Kill()` branch (the
  only code that knows it stopped a process), and `:run_exe_smokerun` clears the file before the launch, reads it
  after (flag set, file deleted) and the flag is reset per fresh build next to `HP_EXE_TIMEDOUT_SILENT`. Never derive
  it from `HP_EXE_EXIT=-1`. Only an explicit Y records `user_confirmed` (state `window_confirmed`); a bare Enter and
  anything else is `window_declined`; an automated run asks nothing (`window_automated`, test
  override `HP_TEST_WINDOWOK_ANSWER`, forced read `HP_TEST_FORCE_INTERACTIVE_WINDOWOK`). It never starts a cascade.
  `HP_EXE_SMOKERUN` has 1093 characters of margin left (Item 87 trimmed its header comment while adding the launch guard).
- **The error line** comes from `~last_error_line.py` (`HP_LAST_ERROR_LINE`, `tools/last_error_line.py`), run via
  `%HP_PY%` on `~run.err.txt`, and is shown with `type` and appended to `%LOG%` with `type`, never through `:log`
  or an unquoted echo: it can hold `< > & | % ^`. If the helper cannot be emitted (`HP_TEST_FORCE_EMIT_FAIL=
  HP_LAST_ERROR_LINE`) or finds nothing, the prompt just omits the line (`hasLine` false in the row).
- **`~run.err.txt` after a runtime install** holds the CHECK run's stderr, which is the one to show.
- **Tests read console text AFTER the offer's heading only**: `~exe_smokerun.ps1` live-tees the EXE's stderr to the
  console before the offer, so the same words appear earlier and prove nothing (`Test-AfterOffer` in
  `tests/selfapps_lastchance.ps1`).
- **NDJSON**: `self.lastchance.offer` (`state` `worked`/`cascade`/`neither`/`automated`/`not_offered`/`window_confirmed`/
  `window_declined`/`window_automated`, `reason`,
  `site`, `provider`, `exitCode`, `passType`, `hasLine`), written only when `HP_NDJSON` is defined; verdicts live in
  `tests/selfapps_lastchance.ps1` (`self.lastchance.*`, real lane gating, `timeout`/`cascade`/`cascade_again` on the
  uv lane, non-gating). Item 66 reads the pass type to decide what to remember (see "Provider memory" below).
- The `[HINT][RUNTIME_MISMATCH]` line in `:exe_smokerun_hints` no longer says "not your environment or
  dependencies", because the offer that can follow suggests exactly that.

## Launch failures (`~launch_failed.txt`, Item 87): three helpers, one marker, one reporter

**Touch `~exe_smokerun.ps1` (`HP_EXE_SMOKERUN`), `~failfast_probe.ps1` (`HP_FAILFAST_PROBE`), `~exe_hint_rerun.ps1`
(`HP_EXE_HINT_RERUN`), `:run_exe_smokerun`, `:run_failfast_probe` or `:verify_no_exe_interpreter`, must understand
this.** A file named `dist\<env>.exe` that Windows cannot start (a text file, a zero-byte file, a cut-off copy: an
interrupted build, an antivirus stub) makes `Process.Start()` throw. The old helpers did not catch it, the process
object had no process, `-not $p.HasExited` errored and read as true, and the poll loop never ended. All three helpers now
wrap `Start()` in `try/catch`. Contract (`tests/test_unlaunchable_exe.py` drives each helper through real `pwsh` under a
25-second hard timeout, with a text, empty, cut-off and missing file):
- The helper writes `~launch_failed.txt` (the inner exception message, printable ASCII only, one line, cut at 200
  characters), prints `[WARN] The program could not be started, so it was not run.`, writes empty output files and the
  result its caller already treats as a failed run (`-1` for the smoke runner, `0|-1` for the probe: not exceeded, exit
  -1, which `:try_fast_exe` discards and rebuilds on), and returns exit code 0. It never writes
  `~smokerun_killed.txt`: a failed launch is not a stop (Item 82 slice 2). The hint re-run has no marker and writes an
  empty output file, so the hint falls through to the generic one.
- **The marker holds arbitrary .NET text**, so the batch shows and logs it only with `type` in `:report_launch_failure`
  (`type "~launch_failed.txt"` to the console and `type ... >> "%LOG%"`), never through `:log`, and deletes it.
- `:run_exe_smokerun` deletes the old marker before the launch, sets `HP_EXE_LAUNCH_FAILED` when the file exists after
  it, and tests that flag BEFORE the exit-code judgement (`goto :smokerun_launch_failed`). That branch is neither a pass
  nor a timeout: it logs one `[WARN]`, calls the reporter, deletes the stub (`del /f /q`), sets `HP_EXE_UNUSABLE` and
  `HP_EXE_VERIFY_FAILED`, clears `HP_FRESH_BUILD_OK` (no source hash may vouch for an EXE that never ran) and returns,
  skipping the elective offers, which all need an EXE that ran.
- `:verify_no_exe_interpreter` runs the program through the interpreter when `dist\<env>.exe` is gone OR
  `HP_EXE_UNUSABLE` is set (the delete can fail when another program holds the file; then the post-flight caveat is the
  honest panel). `HP_EXE_UNUSABLE` is reset per fresh build next to `HP_EXE_TIMEDOUT_SILENT`.
- `:run_failfast_probe` deletes the marker before the helper and calls `:report_launch_failure` after it, so the
  cached-EXE path, the no-EXE interpreter path and the post-execution checkpoint all print the reason. The cached-EXE
  caller needs no change: `0|-1` is already "ran and failed fast".
- Test hook `HP_TEST_CORRUPT_BUILT_EXE=1` (inside `:run_exe_smokerun`, before the launch) turns the freshly built EXE into
  a text file; absence changes nothing (README REQ-019). It is the only way a bootstrapper run reaches the smoke runner
  with a stub, because the stale-EXE paths now delete the EXE first (Item 71).
- Rows: `self.unlaunchable.smoke_stub` and `self.unlaunchable.fastpath_stub` (`tests/selfapps_unlaunchable_exe.ps1`, real
  lane, gating, 15-minute watchdog per run so a regression is a red row and not a held job). Payload margins after the
  trim: `HP_EXE_SMOKERUN` 1093, `HP_FAILFAST_PROBE` 1635, `HP_EXE_HINT_RERUN` 1875.

### Cascade signal reliability

`HP_CASCADE_CANDIDATE` requires BOTH: (A) PyInstaller's warn file still lists an unresolved import
after a repair-install-and-rebuild, and (B) at least one specific repair install command in that
same round returned nonzero. Requiring both together (not "any repair failure") is what makes a
genuine candidate uncommon. Neither signal is based on actually running the `.exe`. Investigated
whether the uv->conda hop specifically deserves a different default (conda-forge is a genuinely
different index with pre-built native-extension binaries pip on Windows often can't produce;
later hops -- embed/venv/system -- all still resolve via plain PyPI pip, so they mainly help only
for environment-specific root causes, not genuine package unavailability). **Outcome: kept
`:cascade_consent_gate` exactly as shipped** -- no code change (see
`docs/agent-closed-backlog.md`'s Known Findings for the full reasoning trace).

## Provider memory (`~provider.state.json`) and the `PVW_PROVIDER` switch (Item 66)

**Touch the uv acquisition block, `:success`, the last-chance offer's exit handling, the three `runtime.txt`
write-back sites, or `:handle_conda_failure`, must understand this.** Decided 2026-10-17 (Q11, option A). Two
features share one effect, "conda goes first and uv is not even acquired", and are placed in run order:
- **Switch validation** (`:pvw_provider_bad`/`:pvw_provider_done`) sits right after the `Python file count` log line:
  after the lock (so `:die` can release it), after `PYCOUNT` exists (so the status file is valid JSON), and BEFORE the
  cached-EXE fast path (so a bad value stops the run even when a cached EXE would have been reused; a good value is
  then ignored by the fast path, README must say so like REQ-026 does for `%1`). The value is compared with
  `set PVW_PROVIDER| findstr /x /l /c:"PVW_PROVIDER=conda"` (no space before the pipe, see lessons-learned), so cmd never parses it (quotes, `&`, `%` are harmless),
  only the exact lowercase `conda` passes, and **no line may ever expand `%PVW_PROVIDER%`** (a unit test forbids it).
  A good value sets `HP_PVW_PROVIDER_CONDA=1` and `HP_FORCE_CONDA_ONLY=1`, i.e. it reuses conda-only mode (no
  fallbacks, `:cascade_from_conda` stops, `:handle_conda_failure` returns without `HP_ENV_READY`, so the caller stops).
  It is set AFTER the CI flag's own log line so a user is not told about a "flag"; if CI already set
  `HP_FORCE_CONDA_ONLY` the switch only logs its `[DEBUG]` override line and leaves `HP_PVW_PROVIDER_CONDA` unset.
- **Memory read** (`:provider_memory_read`, one call, after the fast path and before the uv block) sets
  `HP_PM_START_CONDA=1` when `~provider.state.json` names conda and Miniconda is installed (the two `conda.bat`
  spots under `%PUBLIC%\Documents\Miniconda3`, or `PVW_CONDA_EXE`; the path is rebuilt here because the main flow
  derives it after the uv block). No interpreter exists yet, so the file is text: written with `echo`, found with
  `findstr /r /c:"provider.:.conda"` (a dot for each quote). Not read under the switch or CI conda-only mode. An
  unreadable file is ignored with a warning and KEPT; a file naming conda with no Miniconda is deleted in
  `:pm_conda_gone`, **the only place memory is cleared** (Q11: input edits and failed runs never clear it).
- **uv skips** (`:uv_skip_pvw_provider`, `:uv_skip_provider_memory`) are tested BEFORE the `PVW_UV_EXE` branch, or a
  `PVW_UV_EXE` override would bring uv back. With `HP_UV_EXE` empty the rest of the flow is the existing conda path;
  `.uv_env` is never reused (that reuse lives inside the `HP_UV_EXE` block).
- **Stale exact pin** (`:runtime_txt_writeback_release`, called when conda goes first, before `HP_RUNTIME_TXT_PREEXIST`
  is computed): each of the three write-back sites also writes `~runtime_writeback.txt` with the same `echo %PYVER%`.
  If `runtime.txt` is still byte-identical to it, nobody edited it, so it holds a provider's exact patch that conda may
  not have; both files are deleted and conda's own write-back writes a version it has. A user's `runtime.txt` never
  matches and is kept. A new `runtime.txt` write site must write the record too (a unit test counts the three).
- **Write** (`:provider_memory_write`, from `:success` before `:release_lock`) needs `HP_PM_PASS`, `HP_ENV_MODE=conda`,
  `HP_CASCADE_TRIED_UV` (conda was reached after uv was tried; a conda-first run never rewrites the file), state ok, and
  neither the switch nor CI conda-only mode. `HP_PM_PASS` is `exe_ok`/`interpreter_ok` from
  `:provider_memory_note_pass` (called by `:last_chance_offer` for a fresh exit 0, never the fast path) or
  `user_confirmed` from `:lc_window_yes`; it is reset next to `HP_LC_EXIT` at the start of every attempt and is NOT
  cleared by `:lc_cleanup` (it must live until `:success`). A plain uv pass, a failed run and a declined run write nothing.
- **Visible by design**: every run that starts from the file logs `Provider memory: starting with conda ... delete
  ~provider.state.json`, the write logs the same reset hint, and the failed forced solve logs `PVW_PROVIDER=conda is set,
  so no other provider was tried` (README REQ-009 should say a forced failure never cascades).
- **Known limits**: a memory-start run whose conda step fails follows the existing conda-failure chain (embed, venv,
  system), uv is not retried; the file is per program folder; nothing remembers `embed`/`venv`/`system`.
- Rows: `tests/selfapps_provider_memory.ps1` (`self.provider.*`; `unset`, `invalid`, `miniconda_gone`, `unreadable`,
  `fastpath` gate on `real`; `forced`, `remember`, `forced_stop` are uv-lane, non-gating because they download Miniconda,
  one into a fresh `PUBLIC`), `self.lastchance.window_*` (what is remembered after the window question), and
  `tests/test_provider_memory.py` (order and shape of the pieces).
