# CLAUDE.md -- AI Assistant Guide for Python_vs_Windows

This file is the orientation document for AI assistants (Claude, Codex, Copilot, etc.)
working in this repository. It summarizes structure, workflows, and conventions.

**Do not duplicate content from these authoritative sources -- reference them instead:**
- **[README.md](./README.md)** -- Product requirements, Prime Directive specification, CI contract
- **[AGENTS.md](./AGENTS.md)** -- Agent iteration rules, scope policy, style rules, sanity checks
- **[CONTRIBUTING.md](./CONTRIBUTING.md)** -- Fork/branch/PR workflow and iteration priorities

**Supplemental context loaded automatically by Claude Code:**
@docs/agent-ndjson.md
@docs/agent-interconnect.md
@docs/agent-lessons-learned.md

**Reference-only, NOT auto-loaded -- read on demand, not every session:**
- `docs/agent-cold-storage.md` -- shelved ideas gated on a specific, checkable trigger.
- `docs/agent-closed-backlog.md` -- the full historical record of completed work, plus any
  Active Backlog item below that was later fully closed (see that file's own header).

**AGENT DIRECTIVE -- keep the knowledge docs current.** When a change teaches or invalidates
a lesson, update the relevant doc in the SAME commit, editing existing entries (not only
appending):
- `docs/agent-interconnect.md` -- cross-component dependencies ("touch A, must understand B").
- `docs/agent-lessons-learned.md` -- standalone hazards, rules, budgets, procedures. Most are
  batch/CMD syntax quirks and Windows shell gotchas; record those here.
- `docs/agent-ndjson.md` -- the NDJSON row registry (add/rename/remove rows here too).
- When an Active Backlog item is fully resolved, move it out of this file entirely into
  `docs/agent-closed-backlog.md`'s "Closed Active Backlog Items" section (keep its original
  number). Do not let a closed item linger here -- this file's size is a per-session cost.

---

## What This Repo Does

`run_setup.bat` is a self-contained Windows batch file that bootstraps any Python application
on a clean Windows 10+ machine with internet access. Drop it alongside `.py` files and
double-click -- it handles Miniconda, conda environments, dependency installation, and
optionally produces a PyInstaller EXE. No admin rights required for the core flow.

The target audience is beginners who have been handed Python code and want it to run.
Getting the code running takes priority over preserving constraints.

---

## Repository Map

```
run_setup.bat                  Main bootstrapper (self-contained, ~157 KB) -- the deliverable
run_tests.bat                  Static test orchestrator (calls harness.ps1)

tests/
  harness.ps1                  Core NDJSON test validator (reads test-results.ndjson)
  selftest.ps1                 Bootstrap self-tests (empty repo + stub hello_stub.py)
  selftests.ps1                Console message validation (replays bootstrap log)
  selfapps_entry.ps1           Entry selection precedence tests
  selfapps_envsmoke.ps1        Full environment verification (conda/pip/imports)
  selfapps_single.ps1          Single Python file bootstrap test
  selfapps_reqspec.ps1         Requirements specifier parsing tests (~= compatible release)
  selfapps_pandas_excel.ps1    Pandas/openpyxl heuristic tests
  selfapps_pipgap.ps1          pip gap-fill safety net (runs run_setup.bat: conda misses opencv-python, pip fills it)
  selfapps_isolation.ps1       REQ-010/REQ-011 behavioral tests (unconditional, HP_CI_SKIP_ENV=1)
  dynamic_tests.py             Python-side entry detection and version precedence tests
  test_*.py                    Python unit tests (14 files, see Testing section)

tools/
  apply_patch.py               Unified/legacy diff parser and applier (used by inline_model_fix)
  find_entry.py                REQ-002 entry-point selector (canonical source for HP_FIND_ENTRY)
  check_delimiters.py          Bracket/quote balance validator (.bat/.ps1/.py/.yml/.json)
  check_workflows_yaml.py      YAML syntax validation via PyYAML
  inline_model_fix.py          AI quick-fix orchestrator (OpenAI Responses API -- CI use only)
  sanitize_iterate_payload.py  NDJSON redaction, deduplication, truncation
  iterate_gate.ps1             Iterate gate decision logic
  ps-compileall.ps1            PowerShell syntax checker
  run_prechecks.ps1            Pre-execution validation
  diag/
    publish_index.py           GitHub Pages diagnostics site publisher
    ndjson_fail_list.py        Failing test extractor (builds model context)
    ndjson_fail_list.ps1       Legacy fail list extractor

docs/
  agent-interconnect.md        Cross-component dependency map (loaded via @ import)
  agent-lessons-learned.md     Standalone hazards/rules/quirks/procedures (loaded via @ import)
  agent-ndjson.md              NDJSON row registry by lane (loaded via @ import)
  agent-closed-backlog.md      Full historical record of completed work (NOT auto-loaded)
  agent-cold-storage.md        Shelved ideas gated on a trigger (NOT auto-loaded)
  agent-scratchlog.md          Internal working notes, freely prunable (NOT auto-loaded)
  open-questions.md            Unresolved maintainer-decision items (NOT auto-loaded)

.github/workflows/
  batch-check.yml              Main CI pipeline (3-lane Windows matrix, ~40 KB)
  codeql.yml                   CodeQL security analysis
  workflow-lint.yml            YAML/workflow lint (actionlint + PyYAML)
  pr-automerge.yml             Auto-merge handler for all non-draft same-repo PRs (blocks on 'no-automerge' label)

tools/ (continued)
  poll_public_diag.ps1         Diagnostics polling helper (moved from scripts/)
```

---

## Development Branch

Always develop on the branch specified in the session's system instructions or PR context.
Push with:
```
git push -u origin <branch-name>
```

---

## Mandatory Sanity Checks

Run this full sweep before every commit. README.md-only changes do not affect most of these
checks but still run the sweep as a baseline (it also catches an accidental non-doc diff).

```bash
python -m compileall -q . && echo "COMPILEALL OK"
python -m pyflakes . 2>&1 | head -20
python tools/check_delimiters.py run_setup.bat && echo "DELIM OK"
python -m yamllint .github/workflows/ && echo "YAMLLINT OK"
export PATH="$PATH:/root/go/bin"
actionlint -oneline .github/workflows/*.yml && echo "ACTIONLINT OK"

for f in run_setup.bat tests/harness.ps1 docs/agent-interconnect.md docs/agent-lessons-learned.md CLAUDE.md; do
  out=$(grep -nP '[^\x00-\x7F]' "$f")
  if [ -n "$out" ]; then echo "=== $f ==="; echo "$out"; fi
done
echo "ASCII SWEEP DONE"
git diff --stat origin/main

pwsh -c "
\$ErrorActionPreference = 'Stop'
\$fail = 0
Get-ChildItem /home/user/Python_vs_Windows/tests/*.ps1, /home/user/Python_vs_Windows/tools/*.ps1 | ForEach-Object {
  try { [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName, [ref]\$null, [ref]\$null) | Out-Null }
  catch { Write-Host \"PARSE FAIL: \$(\$_.FullName): \$_\"; \$fail = 1 }
}
if (\$fail -eq 0) { Write-Host 'PS PARSE SWEEP DONE - ALL CLEAN' }
"
python -m pytest /home/user/Python_vs_Windows/tests/test_*.py -q 2>&1 | tail -5
```

The ASCII sweep's file list is illustrative, not exhaustive -- extend it to cover whatever
files the current change actually touches. `actionlint`/`pwsh` install methods (if not already
present in the environment) are documented in **AGENTS.md**.

**`tools/run_sanity_sweep.sh` runs this exact block as one command** (`tools/run_sanity_sweep.sh
[extra-file ...]`, extra args extend the ASCII sweep's file list), with a clear per-check
pass/fail summary instead of scrolling raw tool output -- prefer it over copy-pasting the block
above by hand. See AGENTS.md's "Recurring tooling" section for what it does and does not do
(it does not auto-install missing tools).

---

## Key Conventions

Full rules in **AGENTS.md**. The most critical:

| Rule | Why it matters |
|------|---------------|
| ASCII only -- no emojis, curly quotes, em-dashes | Batch/cmd parsing breaks on non-ASCII |
| `.bat/.ps1` use CRLF; everything else LF | Controlled by `.gitattributes` -- do NOT edit manually |
| `--override-channels -c conda-forge` on all installs | Prevents defaults channel contamination |
| Tilde-prefix temp files (`~setup.log`, etc.) | Easy to gitignore; survive crashes |
| Avoid `EnableDelayedExpansion`; if needed, wrap tightly | Parent shells with `/V:ON` cause collisions |
| `call "%CONDA_BAT%" ...` for all conda invocations | Keeps parent batch running after conda |
| No PSGallery downloads in CI | Proxy blocks it; use syntax-only validation |
| Tag non-obvious constraints: `# derived requirement: <why>` | Prevents future regression on subtle fixes |

---

## run_setup.bat Rules

This is the deliverable. Treat changes carefully.

1. **Self-contained**: no committed helper files; all helpers are base64-encoded inside
   the batch file under `:define_helper_payloads`. To refresh a helper with a canonical
   `tools/` source, use `python tools/sync_payload.py HP_VARNAME tools/the_file.py` -- do not
   hand-roll the encode/splice/write sequence (see docs/agent-lessons-learned.md's "Embedded
   Helper Update Workflow" and the near-miss that motivated automating it).

   Current embedded payloads (in addition to legacy `HP_FAST_CHECK`):

   | Payload | Decodes to | Purpose | Canonical source |
   |---------|-----------|---------|-------------------|
   | `HP_DEP_CHECK` | `~dep_check.py` | Compares pipreqs output against `~environment.lock.txt`; exits 0 (skip) or 1 (install needed) | `tools/dep_check.py` |
   | `HP_ENV_STATE` | `~env_state.py` | Reads/writes `~env.state.json` to cache conda env validity across runs | `tools/env_state.py` |
   | `HP_PYPROJ_DEPS` | `~pyproj_deps.py` | Parses `pyproject.toml` `[project].dependencies`, one dep/line; exit 0/1/2 = ok/not-found/malformed TOML; feeds the layered dep resolution block | `tools/pyproj_deps.py` |
   | `HP_PREP_REQUIREMENTS` | `~prep_requirements.py` | Applies REQ-005.8 heuristic dep-augmentation rules; strips pip extras (`[excel]`) before name lookup | `tools/prep_requirements.py` |
   | `HP_COLLECT_SUBMODULES` | `~collect_submodules.py` | Pre-build `--collect-submodules=PKG` flags for curated dynamic-import packages (sklearn/matplotlib/scipy/plotly), double-gated on used-by-source AND installed-in-interpreter so a fat global env never bloats a lean app's EXE | `tools/collect_submodules.py` |
   | `HP_HIDDEN_IMPORT_SCAN` | `~hidden_import_scan.py` | Slice 2 `--hidden-import` auto-recovery target selection for `:hidden_import_recover`; strict `ModuleNotFoundError` + installed-in-build-interpreter gate (a typo or `ImportError: cannot import name` costs zero rebuilds); capped at 3 rebuilds | `tools/hidden_import_scan.py` |
   | `HP_DLL_PCT_SANITIZE` | `~dll_pct_sanitize.ps1` | Strips `%`/`^` from env var values for `:log`'s UNQUOTED-echo safety in the native-DLL bundling loop; emitted as a real `.ps1` (invoked via `-File`) so cmd.exe's own tokenizer never parses its body -- see `docs/agent-lessons-learned.md`'s ":log echoes UNQUOTED" entry for why the earlier inline `-Command` version needed three separate fixes | `tools/dll_pct_sanitize.ps1` |

   Each payload's canonical `tools/` source has a `PayloadSync` unit test asserting
   byte-equality between the embedded base64 and the source file (see the Testing section
   below for which test file covers which payload).

2. **Delimiter-check after every edit**:
   ```bash
   python tools/check_delimiters.py run_setup.bat
   ```

3. **Three code paths exist** (cache / real / conda-full lanes) -- test all three after
   significant changes by checking CI results across all lanes.

4. **Bootstrap status contract**: every run writes `~bootstrap.status.json`:
   ```json
   {"state":"ok|no_python_files|error","exitCode":0,"pyFiles":0}
   ```
   CI harnesses and `tests/selftest.ps1` read this. See README.md for full contract.

---

## CI Overview

Three test lanes run in parallel on Windows Server runners:

| Lane | Purpose | Gated? |
|------|---------|--------|
| `cache` | Reuses cached Miniconda | No (continue-on-error) |
| `real` | Fresh Miniconda download (authoritative) | Yes |
| `conda-full` | Forces conda-only, no venv/system fallbacks | Yes |

The `real` and `conda-full` lanes gate PR merges. `cache` is informational.

Key outputs: `tests/~test-results.ndjson` (machine-readable), `~bootstrap.status.json`,
`bootstrap.log`, `~setup.log`.

**Auto-patcher**: only `tools/inline_model_fix.py` via the "Model quick-fix (inline)" job
in `batch-check.yml`. No other agent or job may commit auto-fixes. See AGENTS.md.

**Diagnostics site**: https://mixmansoundude.github.io/Python_vs_Windows/

### CI Pipeline Architecture (key facts for debugging)

**CI job step ordering (within each lane job):**
1. Selfapps scripts run (each appends rows to both NDJSON files).
2. Artifacts are uploaded (NDJSON snapshot of selfapps rows).
3. "Verdict from NDJSON" CI step reads pre-harness selfapps rows (has_failures verdict).
4. Dynamic tests run.
5. `run_tests.bat` runs `tests/harness.ps1` (reads and deletes `tests/~test-results.ndjson`,
   writes harness static check rows back to the same file).
6. `tests/selftest.ps1` runs the bootstrapper self-tests (empty repo + stub).

**selftest.ps1 vs selftests.ps1:**
- `selftest.ps1` -- runs run_setup.bat on a real (empty) app directory, validates
  `~bootstrap.status.json` was written, exercises the stub fast-path and dep-check flows.
- `selftests.ps1` -- replays a captured bootstrap log and validates console message
  patterns (does NOT re-run run_setup.bat). Different scope; name similarity is a trap.

**HP_CI_SKIP_ENV=1 mode:**
- Causes run_setup.bat to skip conda env creation entirely and use system Python.
- The `:ci_skip_entry` subroutine (lines ~1090-1196) handles this path.
- Only `selfapps_isolation.ps1` exercises this path directly.
- Exit code from this path is 0 on success (`:after_env_skip` calls `:write_status ok 0`
  then `exit /b 0`). The known "exit 255" artifact in `selfapps_single.ps1` referred to
  PowerShell `$LASTEXITCODE` drift, not the batch exit code itself.

See `@docs/agent-ndjson.md` for the complete NDJSON row registry by lane.
See `@docs/agent-interconnect.md` for the uv-first provider interconnectedness map.

---

## Testing

### Python unit tests (cross-platform, run locally)
```bash
python -m pytest tests/test_*.py -v
```

Test files and what they cover:

| File | Covers |
|------|--------|
| `test_apply_patch.py` | Unified/legacy diff parsing and application |
| `test_entry_selection.py` | Entry file precedence (main > app > run > cli > __main__) |
| `test_find_entry.py` | find_entry.py selection matrix: substantive `__main__` detection, alphabetical fallback (REQ-002), HP_FIND_ENTRY base64 sync |
| `test_entry_single.py` | Single Python file bootstrap (Windows only, skipped on Linux) |
| `test_inline_model_fix_decision.py` | Model quick-fix decision logic |
| `test_ndjson_fail_list.py` | Fail list extraction from NDJSON artifacts |
| `test_poll_public_diag_logging.py` | Diagnostics polling and logging |
| `test_ps_colon_scan.py` | PowerShell scoped variable detection ($var:) |
| `test_check_delimiters_import.py` | Delimiter checker import guard |
| `test_fast_check_pattern.py` | HP_FAST_CHECK infra-dir exclusion regex ($infraPattern) |
| `test_heuristics.py` | Heuristic dep-augmentation rules (REQ-005: all 6 rules, extras syntax, capitalization, kill-switch, idempotency) |
| `test_parse_warn.py` | PyInstaller warn-file translation table (REQ-007: 5.x and 6.x formats, all TRANSLATIONS entries) |
| `test_publish_index_regex.py` | Regex patterns in diagnostics publisher |
| `test_sanitize_iterate_payload.py` | NDJSON redaction and deduplication |
| `test_collect_submodules.py` | `--collect-submodules` double-gate (used AND installed), adversarial import-scan cases, AST-failure regex fallback, HP_COLLECT_SUBMODULES payload sync |
| `test_hidden_import_scan.py` | `--hidden-import` auto-recovery strictness (ModuleNotFoundError + installed only), typo/ImportError/circular-import non-triggers, tried-list loop guard, HP_HIDDEN_IMPORT_SCAN payload sync |
| `test_check_ndjson_registry.py` | NDJSON registry cross-check: brace expansion, all four code emission patterns, log-file parsing, pass/fail end-to-end paths |

### Static harness (Windows-only, requires PowerShell)
```batch
run_tests.bat
```
Runs `tests/harness.ps1` which validates NDJSON output structure and counts pass/fail.

### Dynamic tests (run automatically by CI)
Triggered when `~bootstrap.status.json` reports `state=ok`. Runs `tests/dynamic_tests.bat`
or `tests/dynamic_tests.py` if present. See README.md section Dynamic test rules.

### Adding new tests
- Python unit tests: `tests/test_<topic>.py`
- PowerShell scenario tests: `tests/selfapps_<scenario>.ps1`
- Wire new PS scenarios into `tests/harness.ps1` (NDJSON rows) and `batch-check.yml` job steps.

---

## Tools Directory

The `tools/` folder holds standalone helpers for CI and development. Add new helpers here
rather than embedding non-trivial logic inline in `.yml`, `.bat`, or `.ps1` files.

```bash
# Validate delimiter balance
python tools/check_delimiters.py run_setup.bat
python tools/check_delimiters.py run          # all supported files

# Validate YAML workflows
python tools/check_workflows_yaml.py

# Apply a patch (dry-run first)
python tools/apply_patch.py patch.diff --dry-run
python tools/apply_patch.py patch.diff
```

`tools/inline_model_fix.py` is called by CI only. It stages context, calls the OpenAI
Responses API, extracts a fenced diff, and applies it via `tools/apply_patch.py`.

---

## Common Pitfalls

- **Batch special characters**: `&`, `%`, `^`, `!`, `~` in variable values require quoting
  or escaping. `%` in particular must be doubled (`%%`) inside `for` loops.
- **`pipreqs` misses runtime deps**: static analysis cannot see plugin-style imports like
  `pandas.read_excel` needing `openpyxl`. See README.md section Dependency strategy.
- **PowerShell `-or` / `-and`**: outside a conditional, these are parsed as parameter names
  and produce cryptic "parameter name 'or'" errors. `check_delimiters.py` flags these.
- **YAML multi-line `run:` blocks with PowerShell**: indentation and quote nesting interact.
  Test modified YAML with actionlint before committing.
- **Line endings**: if you edit `.bat` or `.ps1` files with a LF-only editor, git corrects
  them on commit per `.gitattributes`, but local execution may fail before the commit.
- **conda defaults channel**: any conda command without `--override-channels -c conda-forge`
  risks pulling from defaults, which violates the repo policy.
- **Tilde-prefixed files in gitignore**: `~setup.log`, `~bootstrap.status.json`, etc. are
  never committed. Do not remove the tilde prefix.
- **Extra packages after requirements.txt edits**: packages removed from requirements.txt
  are NOT uninstalled from the conda env (harmless, documented). Only affects the lock/state
  fast paths.

---

## Dependency Strategy (summary)

`pipreqs` is discovery only. `requirements.txt` is a hint, not authority. conda-forge is
truth. See README.md section Dependency strategy for the full explanation including the PIL/pillow
and cv2/opencv mapping limitation.

---

## Dependency Discovery: pipreqs pin rationale (as of 2026-06-18)

**pipreqs is pinned to 0.4.13, NOT 0.5.0 -- do not "upgrade" this pin.** 0.5.0 hard-caps
`Requires-Python <3.13` (via its Jupyter-scanning `ipython==8.12.3` dependency), which would
silently disable pipreqs entirely on this bootstrapper's always-latest-conda-forge-Python target
and fall every run back to warnfix; 0.4.13 has no upper Python cap and runs fine on 3.14. The
only feature lost by staying on 0.4.13 is `.ipynb` scanning, already non-functional on latest
Python since 0.5.0 can't run there anyway. Full version-comparison rationale in
`docs/agent-closed-backlog.md`'s "Dependency Strategy Rationale" reference section. The
`pipreqs.flags` CI gate validates invocation flags only, not the pinned version -- it does not
authorize changing 0.4.13; the setup log line `[INFO] pipreqs <ver> installed successfully`
confirms pipreqs is active on a given run.

## Dependency Discovery: pipreqs invocation (bootstrap determinism)

**pipreqs is invoked via `python -m pipreqs.pipreqs`, NOT the console script.** Deterministic
(no PATH/activation dependency) and safe only because pipreqs is permanently version-pinned
(0.4.13), making its internal module structure stable by contract -- the exact tradeoff this
repo's Bootstrap Architecture Principles (below) codify generally. See `run_setup.bat`'s own
invocation comment (search `python -m pipreqs.pipreqs`) for the in-code pointer, and
`docs/agent-closed-backlog.md`'s "Dependency Strategy Rationale" reference section for the full
constraints/comparison writeup.

## Dependency Discovery Fallback: warnfix (secondary safety net)

If pipreqs install ever fails (e.g., a future Python drops a stdlib API pipreqs needs, or docopt/yarg
cannot build), the bootstrapper still falls back to `warnfix`:
1. PyInstaller builds the EXE (static analysis finds many imports)
2. Read the `warn` file (list of modules PyInstaller couldn't find)
3. Parse warn file via `parse_warn.py`: extract top-level, delayed, and conditional imports
4. Filter modules warnfix must never install as an application dependency: a generic
   `if mod.startswith("_"): continue` rule drops leading-underscore internals by name pattern
   alone; the `SKIP` frozenset additionally covers packaging/import-machinery internals
   (`pkg_resources`, `distutils`, `setuptools`, `importlib`+submodules), `collections` (+`.abc`),
   Unix-only platform modules absent on Windows, and Python-2-only stdlib shims (`cStringIO`,
   `StringIO`) that still surface via real packages' own Python 2/3 compat code. Every `SKIP`
   entry is covered automatically by
   `tests/test_parse_warn.py::ParseWarnFileEdgeCasesTest::test_every_skip_entry_filtered_in_realistic_warn_line`
   -- no separate test needed per addition. Full per-group rationale and the real CI evidence
   (`self.layered_e2e.chain`) that motivated the Unix-platform and Python-2-shim groups in
   `docs/agent-closed-backlog.md`'s "Dependency Strategy Rationale" reference section.
5. Install detected missing packages via conda or pip
6. Rebuild EXE
7. Retry interpreter smoke test

**Warnfix coverage:** Warnfix detects and handles:
- [x] Top-level imports (e.g., `import colorama`)
- [x] Delayed imports (e.g., `def load(): import requests`)
- [x] Conditional imports (e.g., `if sys.platform == 'win32': import winreg`)
- [ ] Optional/try-except imports (intentionally skipped, guarded by try-except)
- [ ] Dynamic imports (e.g., `importlib.import_module(name)`)

**User recommendation:** For Python 3.13+ or to avoid fallback latency, provide explicit dependencies:
- **Option 1:** Add `requirements.txt` (comma-separated or newline-separated, any format pip understands)
- **Option 2:** Add `pyproject.toml` with `[project]` section and `dependencies` field (PEP 508 format)
- **Option 3:** Add PEP 723 inline metadata: `# /// script` block at the top of your `.py` file (Python 3.11+)

See README.md section Dependency strategy for full details.

---

## Bootstrap Architecture Principles

This system prioritizes **deterministic execution during bootstrap** over packaging purity --
these six principles govern tool invocation, dependency handling, and error handling in
`run_setup.bat` (the pipreqs invocation strategy above is the canonical worked example):

1. **Bootstrap reliability > API correctness.** A feature depending on "maybe PATH is set" or
   "activation might work" is invalid for bootstrap paths -- determinism is non-negotiable.
2. **Never depend on console scripts during bootstrap** (`pipreqs`, `pytest`, etc. all require
   `Scripts/` on PATH and activation state neither is guaranteed) -- use explicit interpreter
   paths or direct Python APIs instead.
3. **All execution must be interpreter-anchored**: every tool invocation roots in an explicit
   Python executable path (`%HP_PY%` or `%CONDA_PREFIX%\python.exe`), never PATH/activation.
4. **Pinned dependencies are assumed stable** -- for a version-frozen tool (pipreqs 0.4.13),
   relying on its internal module structure as stable by contract is an acceptable coupling.
5. **Bootstrap must fail fast and explicitly** -- no silent fallbacks unless explicitly logged.
6. **Non-obvious decisions must be self-documenting** (e.g. `python -m pipreqs.pipreqs` instead
   of `pipreqs`) so a future maintainer isn't tempted to "fix" it incorrectly.

---

## Iteration Loop Rules

See **AGENTS.md** section Iteration Contract for the full policy. Key points:

1. Freeze scope for the current loop -- new requirements go to backlog.
2. Fix CI first (pipeline/config), then test errors, then test assertions, then product code.
3. After going green, verify no false positives.
4. Implement exactly ONE missing feature slice per loop.
5. Add exactly ONE missing test per loop.

---

## Active Backlog

Items deferred to future loops. This list is for genuine future work -- a decision already made,
a fact confirmed with no action needed, or a recurring/periodic check belongs in
`docs/agent-closed-backlog.md`'s "Known Findings" section, `docs/agent-lessons-learned.md`, or
"Periodic Maintenance Checks" below instead; a promising idea deliberately shelved pending a
specific, named trigger belongs in "Cold Storage" below instead of here (see that section's own
scope note for the distinction from this one). Item numbers are informal labels for
cross-referencing within a session or PR, not a guaranteed-unique ID scheme -- pick anything that
looks free in the list below when filing a new item; do not cross-check it against
`docs/agent-closed-backlog.md`'s history first, and do not renumber an item if it later turns out
to coincidentally repeat an older, already-closed item's number. (Owner decision 2026-07-31, see
`docs/agent-closed-backlog.md`'s Known Findings section: the earlier renumber-on-collision
convention was more rigor than a plain-text backlog needs -- a real uniqueness guarantee belongs
in an actual issue tracker, e.g. GitHub Issues, not a hand-maintained numbering scheme here.)
Once an item is fully resolved it is removed from here entirely and archived (keeping its
original number) in `docs/agent-closed-backlog.md`, which is why the numbering below does not
start at 1 and has gaps. **If this list is currently empty, state that explicitly in large bold
text (see below) rather than leaving the section silently blank** -- an empty section with no
marker is easy to mistake for a rendering glitch or an accidental deletion; an explicit statement
is not.

All items below stem from a 2026-08-09 Opus 5 release-readiness deep dive of `run_setup.bat`'s
default (zero-flag, double-click) Prime Directive path, scoped to the most common real user runs
-- first run and every repeat run -- with findings cross-checked against real CI evidence and this
repo's own docs before filing (see chat history for the full report). Overall verdict from that
review: **yes, with caveats** -- the golden path is confirmed working end-to-end on current `main`,
none of the findings below are recent regressions (all pre-date the last several weeks of merges),
but several represent real gaps worth closing before calling the path fully release-ready.

- **Item 35: systematically promote non-gating CI lanes/checks and inert NDJSON rows to real
  gating status -- EXTREME CAUTION, one lane/row per slice, diagnostics-site publish must never
  be blocked.** Prompted by the same review, which found several genuinely "false green"
  situations: a lane reporting no failures because it's non-gating (so a real regression there
  cannot block a PR), or an NDJSON row that is REGISTERED but structurally never fires in any real
  CI configuration (indistinguishable from "always passes" when it has in fact never run at all).
  Goal: audit every candidate, and for each one that is genuinely real (not a placeholder) and
  demonstrably non-flaky, make it capable of turning CI red for real -- so "CI is green" stops
  being a partial truth for any lane or row this repo currently ships.

  **Known inventory to work through (starting point, not exhaustive -- re-derive against current
  state at slice time):**
  - Non-gating lanes (currently `continue-on-error` at the job level, per CLAUDE.md's CI Overview
    and Periodic Maintenance Checks' "CI lane gating maturity" section): `cache`, `justme-test`,
    `uv`, `contract-uv`, `contract-uv-fail`, `uv-dl-fallback`.
  - `contract-uv`/`contract-uv-fail`/`uv-dl-fallback` are documented as "explicitly load-bearing,
    not provisional" for staying non-gating -- **re-verify this reasoning still holds
    structurally (they simulate failure/contract scenarios that intentionally diverge from a
    normal run) before excluding them; do not just carry the existing text forward without
    re-checking it.**
  - `ndjson-registry-check`: a separate advisory job (not a matrix lane), `continue-on-error:
    true`, "needs several more real-CI runs at clean PASS before even considering gating" per the
    same section.
  - Inert/never-fired NDJSON rows (structurally never observed in any real CI artifact, confirmed
    via `docs/agent-ndjson.md`'s own notes and the review's independent check against a real run's
    cache/conda-full snapshots): `self.dll_bundle.recover` (6 of 7 outcome states have zero
    runtime coverage; see Item 37 below for the dedicated item), `self.failfast.probe` (bare row,
    distinct from its `.fastfail`/`.alive` siblings), `self.exe.smokerun`. Audit for others --
    these three are the ones already confirmed, not necessarily the complete set.
  - The `set /p` prompt lines (real interactive prompts a genuine double-click user reads) never
    execute in any CI configuration at all -- `docs/demo-bootstrapper-output.md` Scenario 5
    already labels this `[Extrapolated Branch]` honestly. Not a "lane" to promote, but the same
    underlying problem: no CI signal exists for this text today. Consider whether a scripted-stdin
    test (mirroring `tests/selfapps_interactive_stdin.ps1`'s existing pattern for the EXE's own
    live-tee output) could exercise the prompt WORDING itself, even if "did a human read this and
    understand it" stays out of scope.
  - The double-click trigger's own interactivity signals (`HP_INTERACTIVE_RUN`) are never in their
    natural, un-forced state in any gating-lane run -- every gating lane sets `HP_CI_LANE`, which
    clears `HP_INTERACTIVE_RUN` via `:compute_interactive_run`. The interactive branches ARE
    covered, but only via `HP_TEST_FORCE_INTERACTIVE_PROBE`/`HP_TEST_CHECKPOINT_ANSWER`-style
    forcing, never the ambient real-user condition. Lower priority (already mitigated, not
    unmitigated) but worth a line in whatever audit doc this work produces.
  - `pause` at `:success` (`if not defined HP_CI_LANE`) -- the terminal-retention behavior every
    real double-click user experiences -- is never exercised in CI either. Same category as above.

  **Non-negotiable constraint: the diagnostics-site-publish job must never be blocked or skipped
  by this work.** The `publish_diag` job (`.github/workflows/batch-check.yml`, "Publish
  diagnostics to Pages") already guards against this deliberately: `if: ${{ always() }}` at the
  job level, with `needs: [selftest, selftest-gate, model-quick-fix]` -- the `always()` override
  means it runs regardless of those jobs' pass/fail conclusion, not just on success (confirmed by
  reading the job directly). **Any change to the job graph as part of this item (new required
  jobs, restructured lanes, a lane split into its own job) must re-verify `publish_diag`'s
  `needs:` list still covers the right jobs and that `if: always()` still applies** -- a change
  that silently narrows this guard would be the exact "false green masks a real gap" failure mode
  this item exists to close, just inverted (diagnostics visibility breaking instead of a real
  regression going unblocked).

  **Reducing the required-checks maintenance burden -- a genuine aggregation point already
  exists, unused (verified against `.github/workflows/batch-check.yml` source 2026-08-10).** The
  owner's actual root-cause observation: most lanes drifted non-gating not by deliberate policy
  but because they were added AFTER the original required-status-checks list was set on branch
  protection and never retrofitted in -- so promoting lanes one at a time (this item's own
  process) still leaves a standing maintenance task ("did we remember to add lane N's check name
  to branch protection") for every future lane too. The owner asked whether ONE step could be set
  as the sole required check so this stops recurring. `ndjson-registry-check` is NOT the right
  candidate: it's a doc/code/log SYNC checker (does `docs/agent-ndjson.md`'s row registry match
  what the code emits and what a real log shows), not a test-pass/fail aggregator -- even at a
  clean, stable PASS it answers "is the documentation accurate," not "did any test fail."

  The right existing piece is the `selftest-gate` job (display name "Aggregate self-test
  verdicts", `needs: [selftest]`, `if: always()`, `batch-check.yml` ~line 3312). It ALREADY
  downloads a `lane_verdict.json` from EVERY one of the 8 matrix lanes unconditionally (the
  "Upload iterate gate verdict" step at ~line 1295 has no `matrix.mode` restriction) and
  aggregates them into one `has_failures` output -- `true` if ANY lane's own "Verdict from
  NDJSON" step (~line 1206) found a `pass:false` row, a `status:failed` row, or a
  `bootstrap.state`/`self.bootstrap.state` outside the allowed-states list. This is a real,
  already-built, all-8-lanes aggregation mechanism, not something that needs inventing --
  **but its missing-artifact fallback is coarser than that sentence implies: re-verified directly
  against the "Aggregate verdicts" step's own source, it only sets `has_failures=true` for a
  missing-artifact reason when the downloaded set is EMPTY ACROSS ALL LANES (`-not $files`) AND
  the overall matrix job's own result wasn't `success` -- there is no PER-LANE check.** If 7 of 8
  lanes' `lane_verdict.json` files land fine and exactly one lane's upload silently fails while
  that lane's own job conclusion still happens to read `success`, the aggregation loop only ever
  sees the 7 present files and never notices the missing 8th -- `has_failures` can read `false`
  with zero evidence from that lane. See the fail-closed caveat below; this gap must be fixed
  before this mechanism is trustworthy as a required check, not just before it's convenient.

  **The gap: `selftest-gate`'s own job never fails when `has_failures=true`.** Today that output
  is consumed ONLY by `model-quick-fix`'s auto-patch trigger steps (the
  `needs['selftest-gate'].outputs.has_failures == 'true'` conditions at ~lines
  3538/3544/3554/3560/3592/3690/3764) -- never by anything that would make `selftest-gate`'s own
  check conclusion "failure." Contrast with the two currently-required lanes (`real`/
  `conda-full`): each already has its own per-lane hard gate, the "Enforce NDJSON failures for
  gated lanes" step (~line 1256, `exit 1` when THAT lane's own `has_failures=='true'`), which is
  what actually makes those two matrix-job instances report failure today -- the same underlying
  "Verdict from NDJSON" data `selftest-gate` already aggregates, just enforced separately
  per-lane instead of once in aggregate.

  **Concrete fix, sized as its own Item 35 slice**: add a step to `selftest-gate` mirroring the
  exact 3-line pattern already proven at line 1256-1261 (`if has_failures=='true': echo "...";
  exit 1`), reading `steps.aggregate.outputs.has_failures` instead of a single lane's own output.
  Once that step exists and has soaked (full-matrix runs, several consecutive, per process rule 1
  below), "Aggregate self-test verdicts" becomes a job whose OWN conclusion is failure whenever
  ANY lane -- gated or not -- reports a real test failure, and adding just that one check name to
  branch protection's required-status-checks list would transitively cover every present AND
  future lane without a further branch-protection edit per lane added. A genuine answer to the
  maintenance-treadmill problem, not just a rephrasing of "add more required checks."

  **Caveats before flipping this on -- still governed by the process discipline below, do not
  skip them just because the mechanism itself is simple:**
  1. Recommend ADDING "Aggregate self-test verdicts" as a required check ALONGSIDE the current
     per-lane `real`/`conda-full` required checks at first, not replacing them -- collapsing to
     one aggregate check loses today's per-lane visibility in the PR checks UI (one red X instead
     of "real failed, conda-full passed"), and keeping both means a bug in `selftest-gate` itself
     (e.g. its artifact-download step failing) doesn't remove your only signal. Consolidate down
     to just the aggregate check later, once ITS OWN reliability is separately proven.
  2. `contract-uv`/`contract-uv-fail`/`uv-dl-fallback` simulate FAILURE/download-fallback
     scenarios on purpose (already flagged above as needing re-verification before excluding from
     gating) -- before this aggregate check goes live, explicitly re-confirm each of those lanes'
     own selfapps tests reports `pass:true` for a correctly-handled SIMULATED failure (the row
     asserts "did the fallback recover," not "did the simulated failure not happen") -- otherwise
     this aggregate check would make those three intentionally-adversarial lanes into permanent,
     incorrect PR blockers the moment their simulated condition fires, which is every run.
  3. Re-verify the `publish_diag` `needs: [selftest, selftest-gate, model-quick-fix]` /
     `if: always()` guard (see above) is unaffected the first time `selftest-gate` actually goes
     red in practice, not just by reading the YAML -- `if: always()` should make this a non-issue
     structurally, but confirm it empirically once, since this item exists precisely because
     "should be fine by reading the YAML" has been wrong before in this repo.
  4. Same one-slice-at-a-time, full-matrix-to-completion discipline as every other candidate in
     this item -- do not treat "the mechanism is simple" as license to skip the soak period.
  5. **Precondition, not optional polish: fix `selftest-gate`'s missing-artifact fallback to fail
     CLOSED per lane before adding the `exit 1` step above, or the new step inherits an existing
     blind spot.** Per the corrected mechanism description above, today's aggregation only treats
     a TOTAL absence of verdict files (zero lanes reporting) as a failure signal -- a single
     lane's `lane_verdict.json` silently missing (upload glitch, artifact-service hiccup, a step
     skipped for a reason that doesn't also flip that lane's own job conclusion to failure) is
     invisible as long as at least one other lane's artifact is present. **A raw file-count
     comparison is not sufficient either** -- each artifact's name already encodes its lane
     (`selftest-verdict-${{ matrix.mode }}` at the upload site; the aggregation step's own
     `lane_verdict.json` also stamps `lane = '${{ matrix.mode }}'` at write time), so an
     unexpected or duplicate artifact landing alongside a genuinely missing lane could still make
     the total COUNT match the expected lane count while one real lane's evidence is absent. Fix:
     compare the SET of expected lane IDs (the matrix's own `mode` list) against the SET of
     observed lane IDs (read from each downloaded `lane_verdict.json`'s own `lane` field, or the
     artifact/subdirectory name) and treat any expected ID that's missing -- or any
     unexpected/duplicate ID present -- as `has_failures=true`, regardless of what
     `needs.selftest.result` reports for the run as a whole. Add test coverage for all three
     shapes (a missing lane, an unexpected extra lane, a duplicate lane) before trusting the fix
     -- this is exactly the kind of gap Item 35 exists to close, and shipping the aggregate-gate
     promotion without closing it first would just relocate a false-green risk instead of
     removing one.

  **Process discipline -- read this before touching anything:**
  1. **One lane or row per slice.** Do not attempt a blanket "flip everything to gating" change.
     Each slice: (a) confirm the underlying mechanism is genuinely real and demonstrably
     non-flaky (a stable-history check, not a hopeful one), (b) let the full 8-lane matrix run to
     completion in full at least several consecutive times with the change in place before
     treating it as proven, (c) only then take the actual gating step.
  2. **"Gating" is a GitHub branch-protection setting, not a YAML edit.** This repo's actual merge
     gate is GitHub's native "required status checks" on the default branch's protection rule
     (confirmed by reading `.github/workflows/pr-automerge.yml`: it only calls
     `enablePullRequestAutoMerge`/checks `pr.mergeable`, both of which delegate entirely to
     GitHub's own branch-protection evaluation -- no custom required-check logic lives in this
     repo's own workflow code). Removing a job's `continue-on-error: true` in `batch-check.yml` is
     a NECESSARY prerequisite (so the job's own conclusion actually reports failure instead of
     always succeeding) but is NOT SUFFICIENT on its own -- someone with repo admin access must
     also add the check's exact name to the branch protection rule's required-status-checks list
     for it to actually block a merge. Each slice's real deliverable is: prove readiness, then
     flag explicitly for the owner to make that branch-protection change (or make it directly if
     the acting agent has that access) -- do not report a slice "done" after only the YAML edit.
  3. **No shortcuts on the "let CI run to completion" requirement.** Do not merge, promote, or
     declare a slice validated based on a partial run, a cancelled run, or "the lanes that matter
     looked fine so far." Wait for the full matrix.
  4. Cross-references: `docs/agent-ndjson.md`'s own notes on
     `self.dll_bundle.recover`/`self.failfast.probe`/`self.exe.smokerun` already diagnose WHY each
     is inert -- read those before assuming a fix; the mechanism is documented even though the fix
     and the gating decision are not. `docs/agent-closed-backlog.md`'s Item 19 entry (cache-lane
     self-healing) is relevant prior art specifically for the `cache` lane's own non-gating
     history.

- **Item 36: warnfix repair install is a silent no-op under venv/embed/system, and reports false
  success.** Confirmed via direct source read and matches an already-flagged-but-never-filed gap
  in `docs/agent-interconnect.md` ("Standalone Python-download tier" section): *"the warnfix
  REPAIR-install branch only has two cases -- `if "%HP_ENV_MODE%"=="uv"` and `else if defined
  CONDA_BAT` -- with NO plain-pip fallback for any other mode... Worth a dedicated future fix...
  its own backlog item."* That backlog item was never actually created until now -- a real defect
  sat fully diagnosed and un-tracked for weeks.

  **Mechanism**: the warnfix repair-install dispatch inside `:run_entry_smoke`'s
  `HP_WARNFIX_NEEDED` block has exactly two branches and no catch-all. Under venv, embed, or
  system mode, `HP_ENV_MODE` isn't `uv` and `CONDA_BAT` is undefined, so neither branch matches --
  yet the loop still logs `[REPAIR] missing modules detected; installing and rebuilding.`,
  installs nothing, rebuilds an unchanged EXE, and logs `[REPAIR] rebuild complete after
  warnfix.` as if it worked. Worse: since no module install was even attempted,
  `~warnfix_repair_failed.flag` is never created, so `:warnfix_cascade_detect`'s own recovery gate
  (`if exist flag AND unresolved`) never fires either -- the ONE mechanism designed to recover
  from exactly this situation (cascading to the next provider tier) is silently defeated by the
  same gap.

  **Realistic scenario**: a locked-down corporate machine reaches the embed tier (uv venv fails,
  conda download fails, cascades to embed). The user's script needs `openpyxl` via
  `pandas.read_excel` -- precisely the runtime-only import pipreqs can't see and warnfix exists to
  catch. Warnfix "installs" nothing, claims success, the EXE builds, the smoke run fails with
  `ModuleNotFoundError: openpyxl`, and the user sees "SETUP COMPLETE -- WITH A CAVEAT" with no hint
  that a repair step silently did nothing.

  **High-level fix**: add a plain-pip catch-all branch (`else ("%HP_PY%" -m pip install %%M)`) to
  the repair-install dispatch, mirroring the SAME three-mode pip pathway (`venv`/`embed`/`system`
  all already use `"%HP_PY%" -m pip install -r requirements.txt` in the main, non-repair
  dependency-install dispatch a few hundred lines earlier) -- both venv and embed have a working
  pip already; this is not a new capability, just wiring an existing one into a second call site
  that was missed. Also verify `~warnfix_repair_failed.flag` is set correctly on a genuine failure
  in this new branch, so the cascade-recovery gate becomes reachable for this failure class too.

  **Coverage gap to close in the same slice**: all five `selfapps_warnfix.ps1` scenarios run on
  `real`/`conda-full`, both of which land in the `uv` or `CONDA_BAT` branch -- the broken branch is
  unreachable from every existing warnfix test. Add a scenario that forces venv or embed mode with
  a warnfix-triggering missing import, asserting the module actually gets installed (not just that
  the EXE eventually builds).

- **Item 37: `:dll_bundle_recover`'s own regression coverage is entirely non-gating, on the
  newest code on the golden path.** Confirmed against `.github/workflows/batch-check.yml`,
  `tests/harness.ps1`, and `docs/agent-ndjson.md`. This is a specific, concrete instance of Item
  35's own scope -- filed separately since it names an exact fix, but implement it as one of Item
  35's slices, not independently.

  The DLL-bundling repair loop (CLAUDE.md's former Items 24/28/29,
  `docs/prd-conda-native-dll-bundling.md`) shipped 2026-08-07/08 -- the youngest subroutine on the
  default fresh-build path, called unconditionally from `:run_entry_smoke` on every build plus a
  second pass from `:run_exe_smokerun`. Its coverage:
  - `self.dll_bundle.recover` (7 outcome states) is emitted behind `if not defined HP_NDJSON exit
    /b 0`. `docs/agent-ndjson.md` already documents that the one test exercising it
    (`tests/selfapps_layered_e2e.ps1`) runs its sub-bootstrap from a bare scratch directory with
    `HP_NDJSON` unset -- so the row is NEVER actually written in any real CI run. Confirmed
    independently against a real run's NDJSON snapshot: no `dll`-prefixed id present.
  - `batch.dll_bundle.ndjson`/`batch.dll_bundle.second_pass` (`tests/harness.ps1`) are static
    source-text regex checks -- they prove the label and all 7 call sites exist, not that the
    behavior is correct at runtime.
  - The only genuine runtime exercise, `self.layered_e2e.chain`, covers exactly 1 of the 7 states
    (`repaired`, via a real `pygrib`/`eccodes.dll` trigger) and runs on the `cache` lane only --
    non-gating twice over (the lane itself is `continue-on-error` at the job level, AND the step
    itself carries its own `continue-on-error: true`).

  **Consequence**: a regression in the newest, most recently-landed golden-path subroutine cannot
  block a PR today -- it would have to be caught by a human reading a non-gating lane's log. Fix
  (cheapest first): set `HP_NDJSON` for `selfapps_layered_e2e.ps1`'s own sub-bootstrap so
  `self.dll_bundle.recover`'s `repaired` row actually fires and becomes queryable; then, once
  proven stable, promote that one step (or the whole `cache` lane, depending on what Item 35's own
  audit concludes) via Item 35's process.

- **Item 38: the same EXE is verified from two different working directories across run 1 vs.
  every later run, so a CWD-relative-path app can flip its verdict between two consecutive
  double-clicks.** Confirmed reasoned-from-source; the CWD split itself is already documented as
  deliberate in `docs/agent-interconnect.md`: *"CWD is preserved per call site: both
  `:try_fast_exe` and `:verify_no_exe_interpreter` run from the app root (no `pushd dist`), unlike
  `:run_exe_smokerun`'s `pushd dist`... re-verify that test if these CWDs are ever unified."* The
  MECHANISM was known; this specific consequence (a verdict flip a beginner would misread as "it
  fixed itself") was not previously spelled out.

  **Mechanism**: `:run_exe_smokerun` (the first-run build verification) runs `pushd dist` first,
  so CWD = `dist\` during that verification. `:try_fast_exe`/`:try_fast_exe_probe` (every later
  run's fast path) runs with CWD = the app root. For a program that opens a data file by relative
  path -- a beginner-common pattern -- run 1 and run 2 can disagree about whether the program even
  works, with zero code change in between.

  **Realistic scenario**: `report.py` does `open("config.json")`, with `config.json` sitting next
  to the script. Run 1: CWD = `dist\`, the file isn't there, EXE exits non-zero,
  `:exe_smokerun_hints` fires `[HINT][DATA_FILE] Consider adding: --add-data config.json;.`, panel
  reads "SETUP COMPLETE -- WITH A CAVEAT". Run 2: same binary, CWD = app root, file IS found, exit
  0, panel reads clean "SETUP COMPLETE". The user's natural conclusion -- "it fixed itself" -- is
  suspect: per Microsoft's own `ShellExecute`/`CreateProcess` documentation, a launch with no
  explicit working directory supplied defaults to the target EXE's own containing folder as CWD
  -- which for `dist\<env>.exe` is `dist\`, the SAME CWD as run 1, so the program would still be
  broken for that default launch path. This is NOT a universal fact, though: Explorer CAN be
  handed an explicit working directory (e.g. a shortcut's own "Start in" field), which would
  override the default -- and no CI lane launches via an actual double-click or shortcut either
  way, so the real-launch consequence described here is reasoned from documented Windows
  behavior, not confirmed against a genuine double-click. The hint compounds the problem for the
  common (no-override) case regardless:
  `--add-data` places the file inside `_MEIPASS` (the onefile extraction dir), which does not
  satisfy a CWD-relative `open()` at all -- the one actionable instruction the tool gives doesn't
  fix the actual problem.

  **Fix options to weigh in this item's own loop** (not pre-decided): (a) unify both verification
  points to the same CWD (which one is "more correct" needs its own thought -- `dist\` matches a
  real double-clicked EXE's default CWD, so verifying from the app root may be the actually-wrong
  choice, not `dist\`); (b) if unification isn't safe (re-verify `selfapps_exedata_fail.ps1`'s own
  xfail check, which is explicitly load-bearing on the current `pushd dist` behavior per the
  interconnect doc's own note), at minimum fix `:exe_smokerun_hints`' `--add-data` suggestion to
  be honest about onefile CWD semantics instead of recommending something that won't work.

  **Coverage gap to close in the same slice**: no test asserts what run 2 reports for a
  CWD-sensitive app. `selfapps_exedata_fail.ps1` invokes `run_setup.bat` exactly once. Add a
  second-run assertion for the same app.

- **Item 39: the EXE fast path's freshness check is mtime-only, so timestamp-preserving delivery
  (a ZIP, an xcopy) can silently run stale code with no signal to the user.** Confirmed
  reasoned-from-source.

  **Mechanism**: `:try_fast_exe`'s freshness test (`HP_FAST_CHECK` payload, `~fast_check.ps1`) is
  `if ($exeTime -ge $latest) { 'fresh' }` over `*.py` mtimes only. A `fresh` verdict short-circuits
  the ENTIRE run straight to `:success` -- no dependency resolution, no rebuild, no
  re-verification. Two exposures: (a) ZIP extraction, `xcopy`, and `robocopy` all commonly
  preserve the archive's original mtime, so an updated script whose authored timestamp predates
  the last build is classified `fresh` and the OLD EXE runs; (b) non-`.py` inputs aren't consulted
  at all -- `requirements.txt`, `pyproject.toml`, `runtime.txt` are outside the scan, so a
  dependency or Python-version change with no `.py` edit is invisible to the freshness check.

  **Realistic scenario**: a colleague emails a fixed `analysis.py` inside a ZIP built last
  Tuesday. The user extracts it over the existing folder (mtime = last Tuesday), double-clicks,
  sees "Fast path: skipping PyInstaller rebuild", and the program runs with the OLD logic --
  nothing in the console indicates a stale artifact was preferred over their new file. README
  documents the mechanism accurately but not this failure mode; the "delete `dist\<env>.exe`"
  escape hatch only appears in the ambiguous-note panel, not the normal success panel.

  **High-level fix to weigh**: add a cheap content-hash (not just mtime) check for at minimum the
  entry file, and/or fold `requirements.txt`/`pyproject.toml`/`runtime.txt` into the freshness
  scan the same way `.py` files already are. Needs its own design pass on cost (a hash read is
  cheap; is it cheap enough to keep the fast path meaningfully fast) before implementing.

  **Coverage gap to close in the same slice**: no scenario backdates a source file's mtime below
  the EXE's to test this. Add one.

- **Item 40: dead comparison in the `HP_SCRIPT_ROOT` trailing-backslash guard always evaluates
  true, so every derived path carries a doubled separator.** CONFIRMED directly against source and
  against a real CI log line.

  **Mechanism**: the guard, immediately after `set "HP_SCRIPT_ROOT=%~dp0"`, reads `if not
  "%HP_SCRIPT_ROOT:~-1%"=="\\" set "HP_SCRIPT_ROOT=%HP_SCRIPT_ROOT%\"`. The left side is a
  ONE-character substring (`:~-1`); the right side, `"\\"`, is a TWO-character literal (cmd.exe's
  `if` does no backslash-escaping, so `\\` really is two backslashes, not an escaped one). A
  one-character string can never equal a two-character string, so the condition is always true,
  and the backslash is always appended -- including when `%~dp0` already ends in one (which it
  always does, by Windows convention). A sibling guard elsewhere in the file uses the correct
  one-character `"\"` form, which is strong evidence this is a typo, not intent.

  **Confirmed reaching console output** in a real CI log (run 31323118721, real lane):
  `Interpreter: D:\a\...\tests\~envsmoke\\.uv_env\Scripts\python.exe` -- note the doubled
  backslash before `.uv_env`.

  **Severity: low/cosmetic** -- Windows collapses repeated separators in most path-consuming
  APIs, and the same CI run confirms `HP_UV_BIN`/`HP_UV_ENV_PATH`/`HP_LOCK_DIR`/`HP_EMBED_DIR` all
  still resolve correctly despite this. But it is dead code with no test catching it, and it does
  visibly surface as `\\` in console output a beginner reads.

  **Fix**: change the right-hand literal from `"\\"` to `"\"`, matching the sibling guard's
  already-correct form. Trivial, one-character fix; add a static test (or extend
  `check_delimiters.py`/a dedicated unit test) asserting `HP_SCRIPT_ROOT` never contains `\\`.

- **Item 41: a working GUI app is force-killed at the 30s build-verification deadline and
  reported with a caveat, with no messaging calibrated for that specific, correctly-behaving
  case.** Confirmed reasoned-from-source, with the kill-on-silence RULE confirmed by real CI
  capture of `:warn_user_code_launch`'s own message text.

  **Mechanism**: the activity-aware kill (`~exe_smokerun.ps1`, `$sawOutput` gate -- see
  `docs/agent-interconnect.md`'s "Activity-aware EXE-smoke kill" section for the full, deliberate
  design history) only kills a process that has produced ZERO bytes of stdout/stderr within 30
  seconds -- exactly the intended behavior for a genuinely hung process. A tkinter/PyQt app with a
  `mainloop()` and no console output is, however, ALSO exactly that shape while behaving perfectly
  correctly. It gets killed, `HP_EXE_EXIT=-1`, `[STATUS] Run Status: TIMED OUT`, and the postflight
  panel reads "SETUP COMPLETE -- WITH A CAVEAT."

  **Realistic scenario**: a student is handed a tkinter grade calculator. Setup runs, a window
  appears, they start typing into it -- 30 seconds later Windows kills it mid-entry. The caveat
  panel then says "we couldn't fully verify it runs as a standalone program," with nothing
  anywhere explaining "GUI apps produce no console output, so we can't auto-verify them -- this is
  normal and does not mean something is wrong." `:warn_user_code_launch` DOES warn beforehand that
  a silent process will be force-stopped after ~30s, so this is disclosed, not hidden -- but the
  disclosure and the caveat panel are both worded for a console-program mental model, and GUI-first
  beginners are a real slice of the target audience.

  **High-level fix**: detect (or simply always emit, cheaply) a GUI-app-aware variant of the
  caveat message specifically for the `TIMED OUT` + zero-stdout-observed case -- something like
  "your program may be a GUI app with its own window; that's expected to produce no console
  output, and this caveat does not necessarily mean anything is wrong" -- distinguishing this case
  from a genuine crash/hang in the panel text itself, not just in the pre-launch warning.

- **Item 42: console output is verbose across all log levels, and every fresh build ends with two
  unexplained Y/N prompts -- both plausibly overwhelming for the actual target audience
  (beginners with no setup experience).** Confirmed reasoned-from-source and CI capture. New; not
  found in Cold Storage or elsewhere during verification.

  **Mechanism, part 1**: `:log` echoes every line to console unconditionally -- `[INFO]`,
  `[DEBUG]`, `[TRACE]`, `[BOOT]`, each timestamped -- with no tiering. A first run shows lines
  like `[DEBUG] pipreqs (direct) rc=0 size=9` and `[TRACE] dep source selected: pipreqs` alongside
  genuinely actionable `[WARN]`/`[ERROR]` text, all visually equal weight.

  **Mechanism, part 2**: every successful interactive FRESH build (not the repeat-run fast path,
  which is correctly prompt-free, and not a CI/non-interactive run, which auto-declines both
  without ever truly waiting on input) asks two Y/N questions before the final panel: the post-execution
  checkpoint ("Run again via the interpreter now?") and the optimized-build upsell ("Want to
  build an optimized version too?"). For someone told to double-click one file, "build an
  optimized version" has no discoverable right answer, and accepting starts a multi-minute Nuitka
  build whose own failure hint references Visual Studio Build Tools -- a term with zero meaning to
  the target audience.

  **High-level fix to weigh** (two independent, separately-implementable levers -- do not conflate
  them into one change):
  1. Tier the console view: keep full detail in `~setup.log` (already happens), but only echo
     INFO/BOOT/WARN/ERROR-class lines to the LIVE console by default, suppressing DEBUG/TRACE from
     the interactive view (a verbose opt-in flag could restore them for diagnosis). No loss of
     diagnostic capability, since the full log is unaffected.
  2. Reduce/reword the two fresh-build prompts: consider combining them into a single, clearly-
     optional ask, and/or defaulting to plain, jargon-free language that makes "this is optional,
     skip if unsure" the obvious reading rather than requiring domain knowledge to answer
     confidently.

  Needs its own design pass -- this item deliberately does not pre-decide the exact
  wording/mechanism, only names the problem and the two levers.

  **Mitigation step for lever 1, specifically -- audit tag coverage before suppressing anything
  (partially done already, verified via source 2026-08-10; the rest is this item's own
  precondition, not yet done).** `run_setup.bat` uses 10 distinct `:log`/`echo` tags, not the 4
  lever 1's own wording names: `[INFO]` (208 uses), `[WARN]` (142), `[ERROR]` (55), `[STATUS]`
  (16), `[DEBUG]` (9), `[TRACE]` (8), `[REPAIR]` (8), `[BOOT]` (7), `[HINT]` (5), `[INSTALL]` (4)
  -- counted directly from source. Only two long-running phases currently have a harness assertion
  proving a progress line precedes the slow operation (`batch.progress.conda_create`,
  `batch.progress.pyi_build`, `tests/harness.ps1`) -- both confirmed `[INFO]`-tier
  (`[INFO] Creating Python environment` before `conda ... create`; `[INFO] Building standalone
  executable` before the PyInstaller call), so both stay visible under lever 1's proposed
  INFO/BOOT/WARN/ERROR tier and tiering would not reintroduce a "looks stuck" gap for either.
  **But the actual dependency-install calls do NOT have an equivalent `[INFO]`-tier progress
  line**: `conda install`/`pip install -r requirements.txt`/`uv pip install` (`run_setup.bat`'s
  dependency-install dispatch, the straight-line block immediately after `:dep_check_done`) are
  preceded only by `[TRACE] dep install phase: start` and
  `[INSTALL]`-tagged lines (`[INSTALL] conda bulk from ~reqs_conda.txt`, etc.) -- `[INSTALL]` is a
  real, distinct tag lever 1's own "INFO/BOOT/WARN/ERROR" wording never accounts for, and
  `[STATUS]`/`[REPAIR]`/`[HINT]` are unaddressed by that wording too. **Goal before implementing
  lever 1**: explicitly classify every one of the 10 tags above as visible-by-default or
  suppressed-by-default (don't leave `[INSTALL]`/`[STATUS]`/`[REPAIR]`/`[HINT]` to an implicit
  default), and specifically confirm the dependency-install phase -- the one long-running step
  with no `batch.progress.*`-style harness assertion today -- keeps a visible progress line under
  whatever tiering ships, so suppressing TRACE doesn't silently remove the only "something is
  happening" signal for what is plausibly the single longest silent stretch in a fresh build.

- **Item 43: "No Python files detected" fires (accurately, per the documented top-level-only
  contract) for a subfolder-only project layout, but the message asserts something the user can
  plainly see is false, with no actionable next step.** Confirmed reasoned-from-source; distinct
  from the already-shipped Item 32 fix (`.py.txt` hidden-extension hint), which solves a
  DIFFERENT cause of the same message.

  **Mechanism**: both the Python-file COUNT (`:count_python`, `dir /b /a-d *.py`) and the entry
  SELECTOR (`find_entry.py`, `os.listdir(".")`) are top-level-only by design -- this matches the
  documented "drop `run_setup.bat` alongside your `.py` files" contract, so it is not itself a
  contract violation. But a user who unzips a project laid out as `src/main.py` + `README` and
  drops `run_setup.bat` at the root gets `Python file count: 0` -> `"No Python files detected;
  skipping environment bootstrap"` -> `state=no_python_files` -> pause -> exit 0. The message
  reads as "there are no Python files here," which the user can visually disprove by looking one
  folder down -- the only follow-up hint offered (the `.py.txt` tip from Item 32) doesn't apply to
  this cause at all.

  **High-level fix**: add a companion check (mirroring `:check_hidden_ext_hint`'s existing
  pattern) that does a genuinely depth-1-only probe when the top-level count is zero -- NOT `dir
  /s /b *.py` (that flag is fully recursive across every descendant directory, not bounded to one
  level; using it would need extra filtering to enforce depth 1, or would falsely match a `.py`
  file buried many folders down). A `for /d %%D in (*) do` loop checking each immediate
  subdirectory for `.py` files directly inside it (`dir /b "%%D\*.py"`, no `/s`) is a real,
  correctly-bounded one-level-deep scan. If `.py` files ARE found one level down, print a specific
  hint: "we only look in this exact folder -- move
  `run_setup.bat` next to your scripts, or move your scripts up into this folder" instead of (or
  alongside) the generic zero-files message.

Items 44-52 below stem from a 2026-08-14 real Windows Sandbox debugging session (two independent
external AI reviews plus direct verification against current source by the acting agent) chasing a
garbled first run (repeated pauses, a PyInstaller build loop with no environment behind it, some
files written and others not). The root cause (Item 44) turned out to be file corruption from the
download method, not the runtime environment; the other items were either incidentally surfaced
while tracing the false leads before that root cause was confirmed, or corroborated an
already-tracked item (Item 40's dead trailing-backslash comparison -- independently re-derived by
the same session, no new information, not re-filed). Each item below was checked against current
source directly, not taken on the reviews' word alone; where a claim could not be confirmed this
way (no live Windows execution available here), that is noted explicitly rather than stated as fact.

- **Item 44: the Prime-Directive download path serves `run_setup.bat` with broken (LF-only) line
  endings, and cmd.exe's goto/call silently misbehaves on the result.** Confirmed directly: a raw
  download (GitHub's "Raw" button, or a `raw.githubusercontent.com` link) is 447,375 bytes with
  zero CRLF pairs; the same file via a real `git clone` checkout is 452,917 bytes with 5,542 CRLF
  pairs -- a delta of exactly one byte per line, matching `.gitattributes`'s own model exactly:
  `* text=auto eol=lf` normalizes the STORED blob to LF regardless of the `*.bat text eol=crlf`
  override, and that override only affects checkout-time conversion, never the blob GitHub serves
  raw. Every natural "just get me the file" path a beginner would take (the Raw button, a
  raw.githubusercontent.com link found via search) hands them a corrupted copy; only `git clone`
  (or any path that performs a real checkout) gets it right today.

  **Consequence, confirmed against the real symptom triad from the sandbox session**: cmd.exe
  resolves `goto`/`call` by relocating to a byte offset associated with the target label; an
  LF-only copy of a ~4700-line file with 129 labels drifts that offset by one byte per line
  crossed, compounding with each jump. This produces exactly what was observed: a `goto`/`call`
  landing on the wrong spot ("the system cannot find the batch label specified" for a label that
  genuinely exists), a `%HP_PY%`-dependent line executing before `HP_PY` was ever assigned because
  an earlier gating block was skipped by the drift (`'""' is not recognized as an internal or
  external command`), and a run that partially completes -- early, purely-sequential code runs
  fine, everything past the first mis-resolved jump does not. No CI lane can catch this: every CI
  checkout goes through `actions/checkout`, which always applies `.gitattributes`'s `eol=crlf`
  conversion, so the broken artifact only ever exists in what a real user downloads, never in what
  CI tests.

  **Mitigated this session, not fully fixed**: `run_setup.bat` now self-checks its own line endings
  as literally the first thing it does (before any other `goto`/`call` in the file, so the check
  itself stays reliable even on a corrupted copy -- see the new block right after `setlocal` at the
  top of the file), and fails fast with a clear, actionable message instead of a silent, partial,
  undiagnosable run. This does not fix the distribution channel itself -- a user can still land on
  a raw link and get the broken file; the check only turns that into a loud, fixable failure instead
  of the multi-hour debugging session that surfaced this item. See `docs/open-questions.md` for the
  maintainer decision on whether/how to fix distribution itself (pro/con on the `.gitattributes`
  options), and README.md's new TL;DR bullet recommending `git clone` in the meantime.

  **Known gap, deliberately not closed in the same slice: the new self-check has no CI coverage of
  its own, in explicit tension with AGENTS.md's stated rule that every branch added to
  `run_setup.bat` must have a CI test.** Flagged by both external reviews on the PR that shipped
  this item (Codex, citing AGENTS.md directly) -- a normal Actions checkout only ever exercises the
  CRLF happy path (`actions/checkout` always applies `.gitattributes`'s `eol=crlf` conversion, same
  reason no CI lane could catch the original bug), so a future quoting/errorlevel regression in any
  of its three branches -- PowerShell absent from PATH entirely, PowerShell present but the check's
  own invocation fails (`errorlevel 2`), or a genuine LF-only copy of the file -- could silently
  break or remove the check with nothing in CI to notice. Needs a dedicated `HP_TEST_*` hook
  (matching this repo's established pattern, e.g. `HP_TEST_FORCE_UV_FAIL`) that deterministically
  forces each of the three, plus an NDJSON row asserting the emitted message and exit code for each.
  Deliberately
  deferred rather than built inline: real test-authoring scope (a new selfapps scenario, workflow
  wiring, NDJSON registry update), not a small slice on top of the fix that was already in flight.

- **Item 45: gate the build/warnfix/repair block on `HP_PY` actually existing, so a failed
  env-create cannot cascade into a doomed PyInstaller build plus multiple repair-loop attempts with
  no interpreter behind any of them.** Deliberately scoped narrow -- this is the small, isolated
  first bite; Item 46 below is the larger, NOT-small structural issue this is a partial mitigation
  for, and the two should not be conflated into one change.

  **Mechanism**: `:die` returns via `exit /b` rather than halting the process (see
  `docs/agent-lessons-learned.md`'s `:die` entry), so a genuine env-create failure can fall through
  into `:run_entry_smoke` and attempt a full PyInstaller build, warnfix repair round, DLL-bundle
  recovery, and hidden-import recovery (each with their own iteration budgets) against an `HP_PY`
  that points at a python.exe that does not exist. Every one of those steps is guaranteed to fail
  or no-op uselessly in this state; none of it does the user any good, and each failure inside the
  loop is itself a `call :die` site that may pause again.

  **Fix**: a single `if not exist "%HP_PY%" (...)` guard at the top of the build/warnfix/repair
  block, skipping straight to whatever the existing no-interpreter failure path already is (or a
  new one, if none currently exists cleanly for this exact state) instead of attempting any of it.
  Small, isolated, and directly kills the "PyInstaller loops while no env/dep work happened"
  symptom without touching `:die`'s own 24+ call sites.

- **Item 46: `:die`'s `exit /b` lets most of its ~31 call sites continue executing afterward,
  producing repeated `pause` prompts and further doomed work instead of a single clear stop. NOT a
  small slice -- needs its own careful, dedicated scoping pass before touching it.** Matches this
  repo's own already-documented mechanism (`docs/agent-lessons-learned.md`'s `:die` entry: "a
  caller with no halt/goto after `call :die` simply continues... `HP_BOOTSTRAP_STATE=error` [was
  already fixed at the source so the status file stays honest], but nothing stops execution").

  **Consequence, confirmed against the real sandbox session**: a chain like
  `:conda_create_failed -> call :die (pause #1) -> falls through to :conda_create_done -> HP_PY set
  to a python.exe that does not exist -> if not exist (call :die, pause #2) -> falls through ->
  more code using the broken HP_PY -> call :die (pause #3) -> ...` produces exactly the "hit pause
  several times" symptom reported, each pause looking like a fresh, unrelated failure rather than
  one root cause cascading.

  **Candidate fix shapes, not yet chosen between**: (a) a global `HP_FATAL` flag set by `:die`,
  checked via `if defined HP_FATAL goto :fatal_exit` after every one of the ~24 continuing call
  sites; (b) change what `:die` itself does on exit (e.g. a real process-halting `exit`, not
  `exit /b`) for the cases where it is known to be called from the top-level call stack rather than
  a nested subroutine -- riskier, since the top-level-vs-nested distinction is not always obvious
  from a given call site, and a bare `exit` closes the console window immediately for a
  double-click user with no chance to read the message first (see the existing `pause`-before-exit
  convention this file already relies on); (c) do nothing beyond Item 45's narrower mitigation for
  now, since it already kills the specific worst compounding case (repeated build/repair attempts)
  even without touching `:die` itself. Given the number of call sites and `:die`'s central,
  load-bearing role throughout the file, treat this as EXTREME CAUTION on the same order as the
  DLL-bundling/hidden-import repair loops elsewhere in this backlog -- one incremental slice at a
  time, not a single sweeping change across all 31 sites.

- **Item 47: no PowerShell capability preflight beyond bare presence.** The new line-ending
  self-check (Item 44's mitigation) added a `where powershell` presence guard as its own
  precondition, but that only proves PowerShell exists on PATH, not that it can actually do the
  things this bootstrapper needs -- `:emit_from_base64` (used to write every embedded `~*.py`/
  `~*.ps1` helper to disk) needs `[Convert]::FromBase64String` + `[IO.File]::WriteAllBytes`, and
  `~failfast_probe.ps1`/`~exe_smokerun.ps1` need `New-Object System.Diagnostics.ProcessStartInfo`
  -- all of which a locked-down corporate image (AppLocker/WDAC/Constrained Language Mode) can
  block even with PowerShell itself present and on PATH. This was the leading hypothesis in the
  sandbox debugging session before the real root cause (Item 44) was confirmed; ruled out for THAT
  specific sandbox (confirmed `FullLanguage`, `EMIT OK`, `PSI OK` via direct probing) but not a
  dead concern in general -- a genuinely CLM-restricted machine would still hit this today with no
  clear diagnostic, just the same opaque "Could not write ~x" pattern the sandbox session initially
  (incorrectly, for that session) suspected.

  **Fix**: run the FromBase64String + WriteAllBytes + `New-Object ProcessStartInfo` triple once,
  early (after Item 44's line-ending check, before `:define_helper_payloads`), and fail with a
  plain-language message naming Constrained Language Mode specifically if it fails, rather than
  letting the failure surface piecemeal as five-plus separate "Could not write ~x" messages later.

- **Item 48: no writable-CWD preflight; `:merge_git_config` writes `.gitignore`/`.gitattributes`
  into the app folder before any guard checks the folder is actually writable.** Small, isolated.
  `:merge_git_config` (called near the top of the file, before `:acquire_lock`) is the first thing in the file
  that writes to the app directory itself, and its own write failures are not checked. Fix: a
  cheap `type nul > "~wtest.tmp"` + errorlevel check, with a named message pointing at the folder,
  placed before `:merge_git_config`'s own call site (right after Item 44's line-ending check is a
  natural spot, since both are "can this even run here at all" preconditions).

- **Item 49: `:lock_is_stale`'s indeterminate PowerShell result is silently treated as "fresh"
  (lock held by a live instance), producing a false "another instance of this setup appears to be
  running" message instead of a graceful continue.** CONFIRMED directly against current source
  (`run_setup.bat`'s `:lock_is_stale` subroutine). The subroutine's own contract comment is explicit:
  `exit/b 0 = stale (caller should evict); exit/b 1 = fresh (still held by a live instance)` -- but
  the only branch that explicitly sets `HP_LOCK_STALE_RESULT` to a recognized value is the
  `'stale'` case; an empty/unexpected PowerShell result (e.g. a transient PowerShell hiccup, not
  necessarily anything wrong with the lock itself) falls through to whatever the default trailing
  statement is, which -- per the subroutine's own documented two-value contract and no visible
  third branch -- reads as "fresh," sending a real user to the "another instance is running,
  delete ~bootstrap.lock" message for a condition that has nothing to do with a concurrent run.

  **Fix**: distinguish "explicitly fresh" from "indeterminate" (anything not exactly `'stale'` or
  `'fresh'`), and treat indeterminate the same as the already-graceful "could not acquire lock
  after evicting" path a few lines below (`[WARN] ... continuing without it.`) rather than as a
  hard block.

- **Item 50: `:cndf_prompt_loop` (the REQ-013 connectivity-check retry prompt) lacks the CI-safe
  auto-decline pattern every sibling consent gate in this file already uses.** CONFIRMED directly
  against current source (`run_setup.bat`'s `:cndf_prompt_loop` label). Every other consent gate in this file
  follows the documented 3-4 branch template (`docs/agent-lessons-learned.md`'s "CI-safe
  interactive gates" entry: echo the prompt unconditionally, then an `HP_TEST_*_ANSWER` override,
  then an `HP_CI_LANE`/`NOINPUT`/`HP_NONINTERACTIVE` auto-decline, then a real interactive
  `set /p`) -- `:cndf_prompt_loop` is a bare `set /p HP_CONN_CHOICE=...` with no such branch at
  all. `set /p` against a genuinely closed/EOF stdin (a fully detached CI job) returns empty and
  the existing empty-input handling already defaults to offline gracefully -- but against a real,
  open, interactive console with nobody present to answer (an unattended real machine where a
  human started the bootstrapper, network drops mid-run, and they are not watching), it blocks
  waiting for Y/N indefinitely, unlike every sibling gate.

  **Fix**: add the same `HP_TEST_*_ANSWER` / `HP_CI_LANE`/`NOINPUT`/`HP_NONINTERACTIVE` branches
  this file's other consent gates already use, defaulting to whichever of retry/offline is safer
  unattended (offline, matching the existing empty-input default two lines below).

- **Item 51: `HP_PIPREQS_RC`'s errorlevel capture, in the direct (non-staging) pipreqs path, has
  an intervening `set` command between the pipreqs invocation and the `%errorlevel%` read --
  PLAUSIBLE, NOT CONFIRMED, needs a live-cmd.exe check before acting.** Current source, right after
  the direct pipreqs invocation, at the `:pipreqs_direct_done` label:

  ```
  "%HP_PY%" -m pipreqs.pipreqs ... > "%HP_PIPREQS_DIRECT_LOG%" 2>&1
  :pipreqs_direct_done
  set "HP_PIPREQS_LAST_LOG=%HP_PIPREQS_DIRECT_LOG%"
  set "HP_PIPREQS_RC=%errorlevel%"
  ```

  If a plain successful `set` resets `%errorlevel%` to 0 (contested even in general cmd.exe
  folklore, and this repo's own `docs/agent-lessons-learned.md` explicitly warns against trusting
  static reasoning about cmd.exe semantics without a live test -- three separate past incidents in
  this exact file were each "fixed" wrong before a live-cmd.exe fixture caught the real behavior),
  `HP_PIPREQS_RC` would always read "0" regardless of pipreqs's real exit code, silently
  misclassifying a genuine pipreqs crash. Notably, the SIBLING staging-path capture, a little
  further down in the same block right after the staging pipreqs invocation, captures
  `%errorlevel%` on the very next line with no intervening command --
  suggesting this might already be a known-avoided hazard elsewhere in the same file, making the
  direct-path instance look like an inconsistency worth resolving even before the exact mechanism
  is confirmed.

  **Fix, low-risk regardless of the exact mechanism**: move the `HP_PIPREQS_RC` capture to
  immediately follow the pipreqs invocation (before the `HP_PIPREQS_LAST_LOG` set), matching the
  already-used safe pattern at the staging call site. Costs nothing even if the hazard turns out
  not to be real. **Verification needed before or alongside the fix**: a small live-Windows-CI
  fixture confirming whether `set "VAR=literal"` does or does not reset `%errorlevel%`, following
  this repo's own established "trust the live test over reasoning" methodology.

- **Item 52: `tools/pyproj_deps.py`'s exit code 1 is overloaded between its intentional
  "no `[project].dependencies` found" contract and a catch-all for any genuinely unexpected
  exception, making a real bug in that script indistinguishable from the normal case.** CONFIRMED
  directly against `tools/pyproj_deps.py` source and `run_setup.bat`'s own consumption of it, in
  the pyproject.toml dependency-extraction block (`if exist "pyproject.toml" (...)`, the block that
  calls `:emit_from_base64 "~pyproj_deps.py" HP_PYPROJ_DEPS`). The documented contract (exit
  0/1/2 = ok/not-found/malformed-TOML) is
  correct and intentional -- `run_setup.bat`'s silent no-op on exit 1 is CORRECT for the
  "not-found" case, not a bug (an earlier external review of this same code mischaracterized this
  as "swallowing a standard exception," which is not accurate -- exit 1 for "not found" is by
  design). The real, narrower gap: `pyproj_deps.py`'s own top-level `except Exception:
  sys.exit(1)` catch-all means a genuinely unexpected exception ALSO exits 1, so
  `run_setup.bat`'s `if errorlevel 1 ( if errorlevel 2 (...) )` structure -- which only logs a
  WARN for errorlevel >= 2 -- silently treats a real crash exactly like the benign "nothing to do
  here" case. Low severity (the script is small and stable; this would only bite if a future
  Python version or TOML edge case triggers an unhandled exception somewhere not already caught by
  the script's own narrower `except` blocks) and low priority given that. Fix, if picked up:
  either a distinct exit code for the top-level catch-all (e.g. 3), or an unconditional low-tier
  log line (not a WARN) on any errorlevel 1 so the fact is at least visible in `~setup.log` for a
  future debugging session, without changing user-facing behavior.

## Cold Storage (promising ideas, deliberately shelved -- revisit only if a named trigger fires)

Moved to `docs/agent-cold-storage.md` (2026-07-31, to reduce this file's per-session context
footprint -- see that file's own header for why). Real, technically-sound ideas that are NOT
being pursued right now, each gated on a specific, checkable trigger -- not "eventually," not
"never," but "only if X happens." Check that file before proposing something that might already
be a deliberately-shelved idea, and before assuming a gap is unnoticed rather than intentionally
parked.

## Periodic Maintenance Checks (recurring, quarterly)

This section is for checks that need to be **repeated on a schedule** because they track
externally-moving state (GitHub's own ecosystem, CI lane maturity, upstream project health) --
not one-time backlog items. Each entry keeps only the *most recent* scan's date, findings, and
going-forward notes; overwrite in place rather than appending a history.

**Directive: re-run this checklist and update every entry below every 3 months** (calendar
quarters -- Jan/Apr/Jul/Oct). Quarterly comfortably covers GitHub's own deprecation cadence
(Actions runner/Node-version changes are typically announced 6-12 months ahead) without letting
findings go stale for a full year. This is the standard mechanism for scheduled recurring
maintenance in this repo -- prefer adding a new dated entry here over inventing a new backlog
item for something that will need re-checking indefinitely. A quarterly Claude Code Remote
trigger ("Python_vs_Windows quarterly maintenance scan", cron `0 9 1 1,4,7,10 *`, fires a fresh
session each time) pokes a session to run this checklist and open a docs-only PR with the
update; if that trigger is ever missing or misfiring, recreate it with the same name/cadence
rather than relying on manual memory.

### GitHub Actions / CI health (action pins, deprecations, lint)

- **Last scanned**: 2026-07-07.
- **Findings**: all action pins across `.github/workflows/*.yml` are on their latest majors
  (`checkout@v5`, `cache@v5`, `upload-artifact@v6`, `download-artifact@v6`, `github-script@v8`,
  `codeql-action@v3`, `configure-pages@v6`, `upload-pages-artifact@v5`, `deploy-pages@v5`) --
  nothing to bump. Two informational, non-actionable GitHub-runner-side/action-internal notices
  observed in CI logs, neither with any fix available on this repo's side: (1) "Node.js 20 is
  deprecated... forced to run on Node.js 24" against `download-artifact@v6` (already latest --
  upstream runner behavior); (2) a Node `[DEP0040] DeprecationWarning: The punycode module is
  deprecated` emitted from inside `actions/deploy-pages@v5`'s own bundled JS during the "Publish
  diagnostics to Pages" job -- originates inside the action's own execution, not this repo's
  code, and resolves whenever the action's maintainers update their bundled dependencies.
  `actionlint` and `yamllint` both clean. `.github/dependabot.yml` now exists (`github-actions`
  ecosystem, weekly schedule) -- see Closed Backlog.
- **Going forward**: confirm Dependabot is actually opening PRs against the `github-actions`
  ecosystem (not just present but inert) at the next scan.

### Persisted CI run-page warnings

- **Last scanned**: 2026-07-06.
- **Findings**: reviewed the latest completed runs (through run #1523); no warnings recur across
  multiple runs beyond the Node.js-20-deprecation notice already covered above.
- **Going forward**: look for anything recurring across several runs, not one-off transient
  network blips (e.g. the `conda.anaconda.org` 403 already tracked separately as the
  conda-create transient-retry gap above).

### CI lane gating maturity

- **Last scanned**: 2026-07-08 (added `ndjson-registry-check` to the watch list; see below).
- **Findings**: only `real` and `conda-full` gate PR merges; `cache`, `justme-test`, `uv`,
  `contract-uv`, `contract-uv-fail`, `uv-dl-fallback` are deliberately non-gating (see AGENTS.md
  policy and this file's Closed-Backlog history for why each was made so) -- not a bug. The
  `ndjson-registry-check` job (a separate advisory job, not a matrix lane) is also
  `continue-on-error: true` -- as of run #1555 it shows a clean PASS in real CI for the first
  time after its Python-source-scanning gap closed (see Closed Backlog), but is being watched
  for soak time before any gating discussion, same as the two lanes below.
- **Going forward**: `uv` and `justme-test` are the two most mature/stable of the six non-gating
  lanes -- re-assess each scan whether either has soaked long enough (no flakiness, no
  lane-specific caveats left) to graduate to gating. Leave `contract-uv`/`contract-uv-fail`/
  `uv-dl-fallback` non-gating indefinitely (their non-gating status is explicitly load-bearing,
  not provisional). `ndjson-registry-check` needs several more real-CI runs at clean PASS before
  even considering gating -- one green run is not a trend.

### CI wall-clock duration (conda-full lane growth)

This tracks a genuine periodic-reassessment concern, not a one-time backlog item -- moved here
2026-07-25 from Active Backlog (it was originally filed as a backlog item, but "worth periodic
reassessment, no action planned" is exactly what this section exists for, and letting it grow
stale as a single never-closed backlog entry was the wrong home for it).

**What this tracks and why it matters**: `conda-full` (the lane that forces every dependency
install through real conda, no fallbacks -- the slowest of the 8 matrix lanes, since conda's own
dependency solver is materially slower than pip/uv) is the dominant single contributor to overall
CI wall-clock time, which grew from ~20 min to ~1.5h historically. Since all 8 matrix lanes run in
parallel, the WHOLE workflow's wall-clock is bounded by whichever lane is slowest -- almost always
`conda-full` -- so this lane's own growth directly sets how long every contributor waits for a PR
to go green. This matters for development velocity (a slower feedback loop costs real time on
every single PR), not correctness -- nothing about the lane itself is broken.

- **Last scanned**: 2026-07-25. Pulled created/updated timestamps for the 18 most recent
  successful full-workflow runs on this branch via the GitHub API (`workflow_runs` list) --
  overall wall-clock ranged 85-110 minutes, averaging ~92 minutes, consistent with the original
  ~80 min observation and not showing runaway growth since. No single-lane breakdown gathered yet
  (would need per-job, not per-run, timestamps to isolate `conda-full` specifically from the
  other 7 lanes running alongside it).
- **Findings**: likely accumulated feature/test-scenario growth over time (more selftest scripts
  each doing a real `conda create`/`conda install`), not a regression traceable to any single
  change -- no evidence of a single fixable root cause has surfaced across multiple scans.
- **Going forward**: re-check the same 18-run wall-clock sample each scan; flag if the average
  climbs meaningfully above ~92 minutes (would suggest either unchecked growth or an actual
  regression, not just noise) rather than plateauing. If a real investigation is ever warranted,
  it needs per-job (not per-run) timestamps to isolate `conda-full`'s own duration from the other
  7 lanes -- not yet gathered, since no action has been planned either way.

### pipreqs ecosystem status

- **Last scanned**: 2026-07-04.
- **Findings**: pipreqs (bndr/pipreqs) still stagnant/maintenance-only as of this scan; no new
  PyPI release since 0.5.0; still correctly pinned to 0.4.13 here (see "pipreqs pin rationale"
  above); `self.stub.pipreqs_version_fail` (Closed Backlog) confirms the warnfix safety net
  covers total pipreqs unavailability regardless of the exact failure mode.
- **Going forward**: check whether pipreqs has a new maintainer/release that changes the
  `<3.13` Requires-Python situation, or whether it's been removed from PyPI (extremely unlikely)
  -- revisit the internalization decision above if either happens.
- **Next-pin probe** (add to each scan going forward, see "Next-pin probe concept" below for the
  general idea this instantiates): under the CURRENT latest target Python (not an old ambient
  one -- this matters, see the concept note), run an unpinned `pip install pipreqs` (or
  `pip index versions pipreqs`) and check whether the resolved version is still 0.4.13. If a
  newer version resolves cleanly, pipreqs's own `Requires-Python` ceiling has moved -- open a
  dedicated loop to re-evaluate the pin (do not bump it inline during a routine scan; re-pinning
  needs its own verification pass, mirroring how the original 0.4.13 pin was chosen).

### Embed version table (REQ-009 Tier 5, `tools/embed_pyver_check.py`)

- **Last scanned**: 2026-07-10 (entry added this scan; first run of this specific check).
- **Findings**: `EMBED_PYTHON_TABLE` currently spans 3.10 through 3.14 (`LATEST_MINOR="3.14"`,
  `FLOOR_MINOR="3.10"`), pinned to patches 3.10.11 / 3.11.9 / 3.12.10 / 3.13.14 / 3.14.6 with
  embedded SHA256 checksums, last refreshed 2026-07-09 per the file's own header comment. The
  `"3.14"` entry's patch/sha256 must stay in sync with `HP_EMBED_LATEST_PATCH`/
  `HP_EMBED_LATEST_SHA256` in `run_setup.bat`; `tests/test_embed_tier.py`'s
  `BatchPythonConsistency` test enforces this automatically on every CI run, so a stale
  cross-reference is caught in CI, not just at scan time. No CPython 3.15 has shipped yet as of
  this scan (3.14 remains current stable), so the table's ceiling is still accurate.
- **Going forward**: each scan, check python.org for (a) a new CPython minor release --
  add a table entry and bump `LATEST_MINOR`/`HP_EMBED_LATEST_PATCH`/`HP_EMBED_LATEST_SHA256`
  together (re-run `test_embed_tier.py` to confirm the sync); (b) any of the pinned patch
  versions reaching end-of-life within their minor line -- bump to the latest patch of that
  minor (embedded zips are patch-specific, not auto-updating); (c) whether `FLOOR_MINOR="3.10"`
  should advance -- python.org's own supported-versions page lists five actively-supported
  minors at any time, so the floor should track five minors behind latest, not stay fixed at
  3.10 indefinitely. Re-verify each new/changed table entry's SHA256 against a fresh direct
  download before committing, per this tier's original design principle (embedded checksums are
  computed once at pin-time and independently verified, never trusted from a third-party
  checksum file fetched over the same network path as the download itself).
- **Next-pin probe**: this table's own quarterly refresh (checking python.org for a new minor)
  already covers this on the "does a new version exist" axis. If REQ-AV's Tier B (shelved in Cold
  Storage, not dropped -- see `docs/agent-cold-storage.md`'s Tier B entry for why and what
  restarts it; PRD at `docs/prd-av-safe-build-path.md`) ever ships its own Python-3.12 pin for
  Nuitka/MinGW64 compatibility,
  add a matching probe here: periodically check whether Nuitka's MinGW64 backend has resumed
  Python 3.13+ support upstream, since that specific fact (not a general "try a newer version
  and see") is what the 3.12 pin depends on -- see that PRD's "Notes from Claude" section for why
  a pin justified by one specific, checkable fact should be revisited by re-checking that exact
  fact, not by a generic version-bump probe.

### Next-pin probe concept (general pattern, applies to any future pin)

Both entries above now include a "next-pin probe": a periodic, mechanical check of whether the
CURRENT constraint behind an existing pin still holds, run against the environment the pin would
actually need to work in (not a stale or convenient stand-in). This section names the pattern
explicitly so a future pin (anywhere in this repo) gets the same treatment by default rather than
each one inventing its own ad hoc check.

**The pattern**: for any pin `X` justified by "we can't use the newer version of `X` because of
constraint `C`", the probe is: periodically attempt to use the newer version of `X` under the
exact conditions `C` describes, and treat an unexpected *success* as the signal to open a
re-pinning loop (this mirrors this repo's own `xfail`/XPASS vocabulary already used for the
hidden-import-recovery tests -- an "expected failure that starts passing" is exactly the
maintenance signal this pattern is built around). Two worked examples above: pipreqs 0.4.13
(constraint: `Requires-Python <3.13` on 0.5.0+) probes by trying an unpinned `pip install
pipreqs` under the bootstrapper's actual current-latest target Python, not an arbitrarily older
one -- probing under an old Python would trivially "succeed" without proving anything about
whether the REAL constraint (0.5.0 vs. this bootstrapper's actual target) has resolved.

**Why this is maintenance-checklist work, not a CI lane**: a probe that is *expected* to fail
under normal conditions and treated as informational-only when it does doesn't fit this repo's
gating model (`real`/`conda-full` block merges; even the non-gating lanes exist to catch real
regressions, not to track upstream ecosystem state). It also doesn't need to run on every push --
upstream constraints like a `Requires-Python` ceiling or a compiler compatibility gap change on
the timescale of months, not commits. It belongs exactly where the two entries above already put
it: as a scripted or semi-scripted step inside the existing quarterly "Periodic Maintenance
Checks" cadence (the same Claude Code Remote trigger already described at the top of this
section), not a new lane in `batch-check.yml`.

**Not implemented as a standalone script yet.** Both entries above describe the probe in words;
neither has a dedicated `tools/check_next_pins.py`-style script yet. That's a reasonable, small,
self-contained next loop if someone wants to reduce the quarterly scan from "a human runs `pip
install pipreqs` by hand and reads the result" to "a script prints a one-line PASS/FLAG verdict
for each tracked pin" -- worth doing, not urgent, and deliberately not built speculatively ahead
of a second or third pin actually needing it.

## Known Findings (diagnosed, no action warranted)

Moved to `docs/agent-closed-backlog.md` (2026-08-09, Active Backlog Item 34 Loop 2). Real
investigations that concluded "no action needed" or "considered and rejected, with reasoning" --
this section's own scope is verbatim that file's stated purpose (read on demand, not every
session), so it doesn't belong in the always-loaded file. Check that file's "Known Findings"
section before re-investigating something that might already have a documented, closed answer.

## Closed Backlog

Moved to `docs/agent-closed-backlog.md` (2026-07-31, to reduce this file's per-session context
footprint -- that section alone was over 60% of this file's total length). It holds the full
historical record of completed feature/fix work (what shipped, why, and the design reasoning
behind it) plus any Active Backlog item that was later fully closed (each keeps its original
item number for stable cross-reference -- this is why Active Backlog above does not start at 1).
Read it on demand: when you need the resolution history behind a specific PR or item cited by
number, or when investigating something that "feels like it was already done."
