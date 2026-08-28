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
  check_crlf.py                 CRLF byte-uniformity checker/fixer for .bat/.cmd files (--fix mode)
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
python tools/check_crlf.py && echo "CRLF OK"
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
  \$errs = \$null
  try { [System.Management.Automation.Language.Parser]::ParseFile(\$_.FullName, [ref]\$null, [ref]\$errs) | Out-Null }
  catch { Write-Host \"PARSE FAIL: \$(\$_.FullName): \$_\"; \$fail = 1; return }
  if (\$errs.Count -gt 0) {
    Write-Host \"PARSE FAIL: \$(\$_.FullName):\"
    \$errs | ForEach-Object { Write-Host \"  \$_\" }
    \$fail = 1
  }
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
| `.bat/.cmd` use CRLF (byte-uniform, `-text`); `.ps1` uses CRLF (normalized `eol=crlf`); everything else LF | Controlled by `.gitattributes` -- do NOT edit manually. `.bat/.cmd` are enforced by `tools/check_crlf.py` (sanity sweep + gating CI), not by git normalization -- see `docs/agent-lessons-learned.md`'s ".bat files: -text, not eol=crlf" entry |
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
   | `HP_MIGRATE_GITATTRIBUTES` | `~migrate_gitattributes.ps1` | Item 60: replaces a pre-existing `.gitattributes`' stale `*.bat eol=crlf`/`*.cmd eol=crlf` lines with `-text`, in place, EXACT-line-match only so unrelated/user-hand-edited content is never touched; called unconditionally from `:merge_git_config` regardless of whether the append block ran or was skipped | `tools/migrate_gitattributes.ps1` |

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
| `test_check_crlf.py` | CRLF byte-uniformity checker/fixer (detection, safe-write --fix, CLI check/fix modes) |
| `test_fast_check_pattern.py` | HP_FAST_CHECK infra-dir exclusion regex ($infraPattern) |
| `test_heuristics.py` | Heuristic dep-augmentation rules (REQ-005: all 6 rules, extras syntax, capitalization, kill-switch, idempotency) |
| `test_parse_warn.py` | PyInstaller warn-file translation table (REQ-007: 5.x and 6.x formats, all TRANSLATIONS entries) |
| `test_publish_index_regex.py` | Regex patterns in diagnostics publisher |
| `test_sanitize_iterate_payload.py` | NDJSON redaction and deduplication |
| `test_collect_submodules.py` | `--collect-submodules` double-gate (used AND installed), adversarial import-scan cases, AST-failure regex fallback, HP_COLLECT_SUBMODULES payload sync |
| `test_hidden_import_scan.py` | `--hidden-import` auto-recovery strictness (ModuleNotFoundError + installed only), typo/ImportError/circular-import non-triggers, tried-list loop guard, HP_HIDDEN_IMPORT_SCAN payload sync |
| `test_check_ndjson_registry.py` | NDJSON registry cross-check: brace expansion, all four code emission patterns, log-file parsing, pass/fail end-to-end paths |
| `test_migrate_gitattributes.py` | Item 60: exact-match-only `.gitattributes` migration (fresh, idempotent, missing-file, asymmetric, already-fixed, near-miss-partial-text cases), HP_MIGRATE_GITATTRIBUTES payload sync |

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

**House rule: a blocked item needs a registered, traceable question, not just prose.** If an
item's remaining work is blocked on the maintainer's own decision, access, or input -- not on
further agent implementation -- it must have a corresponding entry in `docs/open-questions.md`
naming exactly what decision/access is needed, added in the SAME commit that identifies the item
as blocked. Describing the blocker only in this file's own prose is not enough: `docs/open-questions.md`
is the one place designed to be scanned for "what does the agent need from you"
without reading the whole backlog, and a blocker that exists only here is easy for both the
maintainer and a future agent to lose track of. Once the maintainer answers, remove the question
doc entry and fold the outcome into wherever it belongs (this file, the interconnect/lessons-
learned docs, etc.) -- see `docs/open-questions.md`'s own header for that half of the convention.
Conversely, an item with genuinely nothing left to implement -- a standing procedure now proven
working, a decision already made and acted on, a fact confirmed with no action needed -- does not
belong here at all regardless of whether it once looked open; close it out per the general rule
two paragraphs up, and if it documents a reusable procedure, give that procedure a permanent home
(`docs/agent-lessons-learned.md`, an existing process section) rather than leaving it implied only
by a now-closed backlog entry.

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

     **Implemented, NOT YET CONFIRMED via a real CI run.** The aggregation logic was extracted
     from `selftest-gate`'s inline "Aggregate verdicts" step into `tools/aggregate_selftest_
     verdicts.ps1` (mirroring `tools/ci_cache_selfheal.ps1`'s own extraction, Item 19), which now
     compares the SET of expected lane IDs (hardcoded to match the matrix's own 8-mode `include:`
     list, alongside its two pre-existing duplications there) against the SET of observed lane
     IDs (each verdict record's own `lane` field, falling back to the containing artifact
     directory's name when absent) and flags any missing, unexpected, or duplicate lane as
     `has_failures=true` -- independent of `needs.selftest.result`, closing the exact blind spot
     described above. A new regression test, `tests/test_aggregate_selftest_verdicts.ps1`
     (wired into `real`, a GATING lane, mirroring `test_ci_cache_selfheal.ps1`'s own precedent),
     exercises all three required shapes plus three more (a genuine per-lane failure still
     detected, the original healthy case, and the "zero files with a `success` fallback" case
     that proves the new check no longer depends on the fallback result at all) against fixture
     directories built to mimic `actions/download-artifact@v6`'s own output layout -- verified
     directly with a local `pwsh` run before ever reaching real CI (this script has no Windows-
     specific dependency, unlike its `ci_cache_selfheal.ps1` sibling, so local verification on a
     non-Windows sandbox was actually possible here). Still open: confirm the new gating test
     passes on the real `real`-lane run, and re-verify `selftest-gate`'s own "Append gate summary"
     step still renders correctly with the report's new `lane_check` section. The actual
     `exit 1`-on-`has_failures` step for `selftest-gate` itself (the change that makes this job's
     own conclusion fail for real) is a SEPARATE, not-yet-taken next step -- this slice is scoped
     to the precondition only, per the item's own "one lane or row per slice" discipline.

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

  **Cheapest-first fix implemented AND CONFIRMED via real CI (PR #452, merge commit `f50ccd6`,
  `cache`-lane run `32561652643`).** `selfapps_layered_e2e.ps1` now sets `HP_NDJSON` for its own
  sub-bootstrap (pointing at the same shared `~test-results.ndjson` its own `Write-NdjsonRow`
  already writes to, restored in its `finally` block) and diffs that file before/after to record,
  as informational `details` fields on its own `self.layered_e2e.chain` row, whether a
  `self.dll_bundle.recover` row with `state:"repaired"` actually appeared -- deliberately NOT
  folded into `chainPass`/`mech4Pass` itself, so a wiring issue in the NDJSON emission
  specifically cannot turn this already-proven, closely-watched test red on its own first run
  under the new wiring. See `docs/agent-ndjson.md`'s corresponding entry for the full mechanism.
  **Confirmed by pulling the real published diagnostics artifact directly** (`tests/
  ~test-results.ndjson` from the `cache`-lane job of that run): `self.dll_bundle.recover` fired
  TWICE with `state:"repaired"` in the same run (`eccodes.dll` and `impi.dll`, both `iteration:1`,
  `provider:"conda"`), and `self.layered_e2e.chain`'s own `details` show
  `dllBundleRowSeen:true, dllBundleRowRepaired:true` alongside every other mechanism passing
  (`mech1Pass`-`mech4Pass` all `true`, `exePass:true`, `statusState:"ok"`, `runExit:0`). This is
  the row's first-ever real-CI observation, confirming it after ONE run -- not yet the "several
  consecutive runs" Item 35's own process discipline requires before considering promotion (moving
  this step, or the whole `cache` lane, out of `continue-on-error`). That promotion decision
  remains a live next step for a FUTURE loop, not taken here.

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
  `:exe_smokerun_hints` fires. Run 2: same binary, CWD = app root, file IS found, exit
  0, panel reads clean "SETUP COMPLETE". The user's natural conclusion -- "it fixed itself" -- is
  suspect: per Microsoft's own `ShellExecute`/`CreateProcess` documentation, a launch with no
  explicit working directory supplied defaults to the target EXE's own containing folder as CWD
  -- which for `dist\<env>.exe` is `dist\`, the SAME CWD as run 1, so the program would still be
  broken for that default launch path. This is NOT a universal fact, though: Explorer CAN be
  handed an explicit working directory (e.g. a shortcut's own "Start in" field), which would
  override the default -- and no CI lane launches via an actual double-click or shortcut either
  way, so the real-launch consequence described here is reasoned from documented Windows
  behavior, not confirmed against a genuine double-click.

  **Fix options to weigh for the CWD mismatch itself** (still not pre-decided): (a) unify both
  verification points to the same CWD (which one is "more correct" needs its own thought --
  `dist\` matches a real double-clicked EXE's default CWD, so verifying from the app root may be
  the actually-wrong choice, not `dist\`); (b) leave the two CWDs as-is (re-verify
  `selfapps_exedata_fail.ps1`'s own xfail check, which is explicitly load-bearing on the current
  `pushd dist` behavior per the interconnect doc's own note, before ever changing this).

  **The hint-honesty half of option (b) is CLOSED 2026-08-23, independently of the CWD-mismatch
  design decision above.** The hint previously compounded the problem for the common (no-override)
  case: `--add-data` places the file inside `_MEIPASS` (the onefile extraction dir), which does
  not satisfy a CWD-relative `open()` at all, yet the hint unconditionally suggested it regardless
  of which kind of missing-file path was detected. Fixed by branching on whether the captured
  missing-file path itself is already under a genuine `_MEIxxxxxx` folder (PyInstaller's own
  onefile extraction-dir naming): when it is, `--add-data` genuinely is the fix and the original
  advice is unchanged; when it is a bare/CWD-relative path (the `report.py`/`config.json` scenario
  above), the hint now says `--add-data` will not fix it and suggests placing a copy next to the
  built `.exe` instead, or reading it via a path relative to the script's own file. This is
  independent of, and does not presuppose an answer to, the (a)-vs-(b) CWD-unification question
  above -- the advice is honest either way that question is eventually resolved.

  **First-shipped version used a plain `findstr /i "_MEI"` substring match -- a real false-positive
  bug found by CodeRabbit's review of this same PR, fixed before landing.** A coincidental filename
  containing `_MEI` anywhere (e.g. `config_MEI.json`) or a user-named folder called `_MEI` with no
  digits (e.g. `C:\work\_MEI\data.txt`) would both wrongly match, misclassifying a genuine
  CWD-relative failure as a bundled-resource one and giving the (still-wrong, for that case)
  `--add-data` advice. Fixed by matching via PowerShell instead of `findstr`, anchored to the real
  `_MEIxxxxxx` path-component shape (a path separator, then `_MEI`, then digits, then a path
  separator) so a bare substring can never match; the value is read from the environment at
  PowerShell runtime rather than substituted into the `-Command` text, so there is no cmd.exe
  metacharacter risk either. Verified directly against both of CodeRabbit's own example strings
  plus the real captured `_MEI41642` extraction path (`docs/demo-bootstrapper-output.md`'s
  Scenario 31) via a standalone `pwsh` script before landing -- all five cases classify correctly.
  Regression coverage: `tests/selfapps_exedata_fail.ps1` (`self.exe.smokerun.exedata.xfail`,
  real/conda-full lanes) gained a second scenario (`EXEDATA_SCENARIO=mei_substring`, a stub app
  opening `config_MEI99.json` -- CodeRabbit's own example shape) alongside the original `plain`
  scenario (`config.json`), both asserting the honest wording fires and the corresponding
  unconditional `--add-data` suggestion does not.

  **Third scenario added same PR, closing a coverage gap CodeRabbit's review separately flagged:
  neither scenario above ever exercises the OTHER branch (a genuine `_MEIxxxxxx` path, where
  `--add-data` remains the correct, unchanged advice) -- nothing in the suite did, before this.**
  `EXEDATA_SCENARIO=mei_genuine`'s stub app reads a file joined from `sys._MEIPASS` (PyInstaller's
  own real, randomly-named onefile extraction directory at runtime), never bundled via
  `--add-data`, so the failure genuinely surfaces a path rooted under a real `_MEIxxxxxx` folder.
  Since the exact directory name is random per run, the test asserts the stable parts instead
  (the `--add-data` advice text, the filename it names, and a genuine `_MEI<suffix>` path segment
  actually present in the captured log) rather than the full line verbatim.

  **Real bug this new scenario caught on its first real CI run, fixed same PR: the extraction
  suffix is NOT always decimal digits.** The regex shipped as `_MEI[0-9]+` (digits only), matching
  the one reference capture then available (`_MEI41642`, all-decimal). The `mei_genuine` scenario's
  own first real run captured `_MEI00001a4c2` and `_MEI00001ee42` -- both containing hex letters --
  so `[0-9]+` never matched, and the fix wrongly gave the CWD-relative advice for a genuine
  extraction path (the exact failure mode this whole fix exists to prevent, just inverted). Widened
  to `_MEI[^\\/]+` (any nonempty run of non-separator characters): the structural bounding (a real
  path separator immediately before AND after `_MEI<suffix>`) is what actually distinguishes a
  genuine extraction-directory component from a coincidental substring or a no-suffix folder name,
  not the exact character class of the suffix -- verified via a standalone `pwsh` script against
  all prior cases plus both newly-captured hex examples before landing.

  **Still open, NOT part of this fix**: the CWD-mismatch verdict-flip itself (options a/b above)
  remains undecided, and the coverage gap this item originally named -- no test asserts what run 2
  reports for a CWD-sensitive app, since `selfapps_exedata_fail.ps1` invokes `run_setup.bat`
  exactly once -- is still open. Add a second-run assertion for the same app once the CWD question
  itself is resolved.

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
  **Dependency-install progress line: CLOSED 2026-08-23.** The dependency-install calls (`conda
  install`/`pip install -r requirements.txt`/`uv pip install`, `run_setup.bat`'s dependency-install
  dispatch, the straight-line block immediately after `:dep_check_done`) previously had no
  `[INFO]`-tier progress line at all -- only `[TRACE] dep install phase: start` and `[INSTALL]`-
  tagged lines (`[INSTALL] conda bulk from ~reqs_conda.txt`, etc.), for what is plausibly the
  single longest silent stretch in a fresh build. Fixed by adding `[INFO] Installing dependencies
  -- this may take a few minutes...` as the first statement inside the `if exist "requirements.txt"
  (...)` block, firing unconditionally whenever real install work follows (including the always-run
  pip gap-fill safety net, so it fires even on the dep-check fast-skip path where conda/uv's own
  bulk install is skipped but pip's verify-and-fill call still runs) -- mirrors the existing
  `batch.progress.conda_create`/`batch.progress.pyi_build` precedent exactly. New harness assertion
  `batch.progress.dep_install` (`tests/harness.ps1`) proves the message precedes the first real
  install-phase work, same ordering-check shape as its two siblings.
  **Tag classification: CLOSED 2026-08-23.** Lever 1's own wording only ever named 4 of the 10
  tags (`INFO`/`BOOT`/`WARN`/`ERROR` = visible); `[STATUS]`/`[REPAIR]`/`[HINT]`/`[INSTALL]` were
  the remaining 4 left unclassified (`[DEBUG]`/`[TRACE]` were already implied suppressed by the
  "suppressing DEBUG/TRACE" line above). Read every real call site for each (re-counted from
  source 2026-08-23: `[INFO]` 216, `[WARN]` 151, `[ERROR]` 57, `[STATUS]` 16, `[DEBUG]` 9,
  `[TRACE]` 9, `[REPAIR]` 8, `[BOOT]` 7, `[HINT]` 6, `[INSTALL]` 5 -- counts drift upward release
  over release as features land; re-count before trusting these for a future slice) and classified
  by what each tag is actually FOR, not just its name:
  - **`[STATUS]`** -- the `Run Status: SUCCESS/FAILED/TIMED OUT` readout (`:smokerun_ndjson` and
    its two siblings) is arguably the single most important line in the whole run for a beginner
    user -- did MY code work. **Visible.**
  - **`[REPAIR]`** -- warnfix/DLL-bundling/hidden-import auto-recovery activity
    (`[REPAIR] missing modules detected; installing and rebuilding.`,
    `[REPAIR][DLL_BUNDLE] Bundling native DLL dependency: ...`, etc.) explains why a build is
    taking longer than expected and that the bootstrapper is actively fixing something, not stuck.
    **Visible.**
  - **`[HINT]`** -- the post-failure `:exe_smokerun_hints` guidance (`Missing data file
    detected: ...`, `Consider adding: --hidden-import=...`) is the most directly actionable text
    in the entire file for a user staring at a failure. **Visible.**
  - **`[INSTALL]`** -- terse routing breadcrumbs for WHICH install path was taken (`conda bulk
    from ~reqs_conda.txt`, `conda per-pkg fallback`, `pip gap fill from requirements.txt`) sit
    strictly BENEATH the `[INFO] Installing dependencies -- this may take a few minutes...` line
    the dependency-install-progress-line fix above already made visible -- that INFO line is
    already the "something is happening" signal for this phase, so `[INSTALL]`'s own mechanism
    detail is redundant for a live user and reads like `[TRACE]`'s own shape
    (`run_setup.bat`'s own header comment at the `[INFO] Installing dependencies` call site
    already anticipated this: "only `[TRACE]`/`[INSTALL]` lines, which a future console-tiering
    change (lever 1) could suppress by default"). **Suppressed** (same tier as `DEBUG`/`TRACE`).

  Final tier: **visible by default** -- `INFO`, `BOOT`, `WARN`, `ERROR`, `STATUS`, `REPAIR`,
  `HINT` (7 tags). **Suppressed by default** -- `DEBUG`, `TRACE`, `INSTALL` (3 tags), restorable
  via an opt-in verbose flag per lever 1's own original design.

  **Real blast-radius finding from this audit, for whoever implements lever 1 next**: grepped
  every test for a `[DEBUG]`/`[TRACE]`/`[INSTALL]` assertion to check what actually depends on
  today's unconditional console echo (as opposed to the untouched-by-tiering `~setup.log`, or a
  STATIC source-text scan like `tests/harness.ps1`'s `batch.progress.dep_install`, neither of
  which tiering affects). Two real hits, one false alarm:
  - `tests/selfapps_pipgap.ps1` reads `[INSTALL]` lines from `~setup.log` specifically (its own
    header comment says so) -- unaffected by suppressing `[INSTALL]` from the LIVE console, since
    the full log is untouched by design. Not a blocker.
  - `tests/selfapps_pvw_overrides.ps1`'s `$wsDebugLogFound` (`self.pvw.workspace.valid`) DOES read
    `[DEBUG] Using super-user override for PVW_WORKSPACE:` from `~ws_bootstrap.log` -- the
    CONSOLE-redirected capture (`cmd /c "run_setup.bat > ~ws_bootstrap.log 2>&1"`), not
    `~setup.log`. Suppressing `[DEBUG]` from console echo would silently break this assertion.
    **Must be updated (read `~setup.log` instead, or in addition) in the same change that
    implements lever 1's console suppression**, or this test goes red the moment tiering ships.
  - No other test file references `[DEBUG]`/`[TRACE]`/`[INSTALL]` at all (confirmed via a
    repo-wide grep across `tests/`) -- so this one test is the ENTIRE known blast radius, not an
    example of a larger pattern still to be found. Re-grep before implementing, since new tests
    land between this audit and whenever lever 1 is actually built.

  **Lever 1 mechanism: CLOSED 2026-08-24.** `:log` now suppresses `[DEBUG]`/`[TRACE]`/`[INSTALL]`
  from the LIVE console by default via a single suppress-list check inside `:log` itself (a plain
  `if not defined HP_VERBOSE_CONSOLE (if "%MSG:~0,N%"=="[TAG]" set "HP_LOG_SUPPRESS=1")` block per
  tag, using `%VAR:~start,len%` substring slicing rather than `findstr`/piping -- see
  `docs/agent-lessons-learned.md`'s "Quote a variable before piping it into findstr" entry for why
  a subprocess pipe on `MSG` would be hazardous here, since message text can legally contain `&`).
  `~setup.log` is untouched -- `:log`'s own `>> "%LOG%" echo ...` line still fires unconditionally
  regardless of suppression. New opt-in flag `HP_VERBOSE_CONSOLE=1` restores all three tags to the
  console (REQ-019-compliant: a pure additive opt-in, never gates a Prime-Directive-required
  behavior), documented in README.md's Advanced Environment Variables table. None of the file's
  425 `call :log` call sites were touched -- only `:log`'s own body changed, so the blast radius
  this precondition audit was worried about never materialized at the call-site level.

  Both real dependencies the precondition audit found were fixed in the same change:
  `tests/selfapps_pvw_overrides.ps1`'s `$wsDebugLogFound`/`$wsInvalidDebugLogFound` (both the
  valid- and invalid-value `PVW_WORKSPACE` scenarios, not just the one the audit named) now read
  `~setup.log` instead of the console-redirected capture. **A fresh re-grep (per the audit's own
  "re-grep before implementing" instruction) found a THIRD dependency the original audit had
  missed** -- `tests/selftest.ps1`'s `self.stub.conda_perpkg` scenario read the bracket-free
  `conda per-pkg fallback` phrase (an `[INSTALL]`-tagged line) from its own console-redirected
  capture too; fixed the same way (switched to `~setup.log`). Confirms the audit's own caution was
  warranted: a test landed between the 2026-08-23 audit and this 2026-08-24 implementation that
  the audit could not have seen.

  **A FOURTH dependency was missed by that same re-grep and was caught only by a real CI failure**
  (`self.stub.conda_retry`, `contract-uv` lane, non-gating but still investigated per this
  session's own drive-to-green posture on a PR it opened): the re-grep searched for the literal
  bracketed tag strings (`\[DEBUG\]|\[TRACE\]|\[INSTALL\]`), which finds a test only when the
  test's OWN assertion text still contains the bracket -- but `self.stub.conda_retry` matches the
  bracket-free phrase `'*conda bulk: transient failure detected*'` (the exact same
  `-like`-treats-`[INSTALL]`-as-a-wildcard workaround already documented for `self.stub.
  conda_perpkg`), so the bracket-only search never surfaced it. Fixed the same way (`~setup.log`
  instead of the console-redirected capture). **Closed by a proper fix, not a workaround**: a
  follow-up EXHAUSTIVE sweep -- every one of the 21 real `[DEBUG]`/`[TRACE]`/`[INSTALL]` message
  bodies in `run_setup.bat` (extracted directly via `grep -oE 'call :log "\[(DEBUG|TRACE|INSTALL)
  \][^"]*"'`), each grepped bracket-free against the full `tests/` tree -- confirmed no fifth
  dependency remains. This is the correct methodology for this class of check going forward:
  search by MESSAGE BODY, not by TAG STRING, since a test's own `-like` wildcard workaround
  routinely strips the tag from its own match pattern.

  New regression coverage: `tests/selfapps_console_tiering.ps1` (`self.console.tiering`, `uv`
  lane, non-gating first landing) runs two scenarios (`default`/`verbose`) proving the suppression
  and the opt-in restoration both work against a real bootstrap, not just that the source code
  exists -- see `docs/agent-ndjson.md`'s own entry for the full mechanism and placement reasoning.

  Lever 2 (the two Y/N prompts) is fully separate and remains untouched -- still open, its own
  future slice.

Items 45-52 below stem from a 2026-08-14 real Windows Sandbox debugging session (two independent
external AI reviews plus direct verification against current source by the acting agent) chasing a
garbled first run (repeated pauses, a PyInstaller build loop with no environment behind it, some
files written and others not). The root cause (Item 44) turned out to be file corruption from the
download method, not the runtime environment; the other items were either incidentally surfaced
while tracing the false leads before that root cause was confirmed, or corroborated an
already-tracked item (Item 40's dead trailing-backslash comparison -- independently re-derived by
the same session, no new information, not re-filed). Each item below was checked against current
source directly, not taken on the reviews' word alone; where a claim could not be confirmed this
way (no live Windows execution available here), that is noted explicitly rather than stated as fact.

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
  one root cause cascading. **Item 45 (closed) already prevents this specific chain from reaching a
  third pause** -- the `if not exist "%HP_PY%"` guard it added to `:run_entry_smoke` means a broken
  `HP_PY` surviving past `:conda_create_done`'s own second `:die` call can no longer also trigger
  the doomed PyInstaller build/warnfix/repair block's own `:die` sites afterward. The first two
  pauses in that chain (both inside the conda-create-failure handling itself, before
  `:after_env_mode_selection` is ever reached) are UNCHANGED by Item 45 and remain open scope here.

  **Bucket B (closed 2026-08-17): the 3 PyInstaller-build-failure `:die` sites
  (`reason=test_forced_fail`/`build_error`/`missing_output`) migrated to a new, non-pausing sibling
  subroutine, `:warn_build_incomplete`.** These are a genuinely different, NOT-doomed case from the
  chain above: by the time any of them is reached, both PyInstaller and the Nuitka fallback have
  already failed, but the environment/dependencies are still valid and the interpreter-fallback
  verification a few hundred lines below still genuinely runs and still genuinely decides
  success/failure -- pausing here (before that verification even happens) misleadingly looks like
  the terminal state when real work is still ahead. `:warn_build_incomplete` (defined right after
  `:die` in `run_setup.bat`) still sets `HP_BOOTSTRAP_STATE=error` (so the eventual final report
  stays honest, matching `selfapps_pyinstaller_fail.ps1`'s unchanged `state=='error'` assertions),
  but skips `:die`'s pause, premature `:release_lock`, and premature `:write_status` -- see
  `docs/agent-lessons-learned.md`'s `:die` entry for the full mechanism. The vestigial, now-doubly-
  redundant `set "HP_BOOTSTRAP_STATE=error"` lines that used to follow each `call :die` at these 3
  sites were removed in the same change (the subroutine itself sets it). Not every `:die` site
  qualifies for this treatment -- only ones where genuinely useful, outcome-determining work still
  follows; the two conda-create-failure pauses in the "Consequence" chain above are NOT one of
  these (nothing useful follows a totally-exhausted provider chain with no valid interpreter at
  all), so they remain candidates for Bucket A's `HP_FATAL` mechanism instead, not this pattern.

  **Bucket A slice 1 (closed 2026-08-17): `:conda_create_failed`'s own `call :die` now `goto`s
  straight to `:after_env_mode_selection` instead of falling through into `:conda_create_done`'s
  body.** Targeted, not a general `HP_FATAL` mechanism -- reuses a pattern the file already
  shipped and already tests (`:hp_test_conda_fail`, the `HP_TEST_FORCE_CONDA_FAIL` bypass sibling
  a few thousand lines below `:conda_create_failed`, has carried the identical `goto` since before
  this fix). **The actual bug this closes is more concrete than "an extra pause": without the
  `goto`, falling through into `:conda_create_done` unconditionally sets `HP_PY` to a path that
  provably does not exist, and that block's own `if not exist` guard then calls
  `:handle_conda_failure` A SECOND TIME -- not just wasted CPU, but a real user re-watching the
  embed/venv fallback attempts and being asked the REQ-014 system-Python consent prompt again
  right after already answering it once.** Regression test: `self.entrysmoke.no_interpreter_guard`
  (`tests/selfapps_entrysmoke_no_interpreter.ps1`, already-gating from Item 45) extended to assert
  the old, now-dead `:conda_create_done`-specific message ("python.exe missing from conda
  environment") is genuinely absent, proving that block is skipped entirely.

  **Important finding from implementing this slice, corrects an earlier assumption in this same
  entry: this does NOT by itself reduce the "Consequence" chain above to a single pause.**
  `:after_env_mode_selection`'s own `if not defined HP_PY` check (a few dozen lines below that
  label) has the IDENTICAL non-halting `:die` shape, and is exactly what the new `goto` now
  reaches (since `HP_PY` was never set this run) -- so a real interactive user hitting total
  first-attempt tier exhaustion still sees two pauses today, just at a different second call site
  than before (`:after_env_mode_selection`'s check, not `:conda_create_done`'s). That check is a
  separate, not-yet-addressed follow-up slice -- finding a safe `goto` target for it needs its own
  careful trace (a large block of dependency-resolution/pipreqs/heuristics code sits between it
  and `:run_entry_smoke`, none of it needed when there's no interpreter, but not yet verified safe
  to skip wholesale).

  **Bucket A decision (made 2026-08-21, maintainer call -- see `docs/plan-die-fatal-remediation.md`'s
  "Batch Roadmap" section for the full reasoning and `docs/agent-lessons-learned.md`'s `:die` entry
  for the choreography this decision preserves): continue (a) as a deliberate STOPGAP, batched by
  proven shape rather than one site per PR; (c) (change `:die` itself to halt the process, `exit`
  not `exit /b`) is the likely eventual target for a SEPARATE, later, dedicated effort once the
  batches below shrink the remaining inventory -- not folded into the ongoing batch work. (b) (a
  global `HP_FATAL` flag) remains a candidate for that later effort too but is not preferred over
  (c) per the plan doc's own blast-radius-vs-structural-simplicity tradeoff writeup.** All 20
  remaining sites (27 total minus the 7 already safe -- 2 with slice 1's own `goto`, 5 inside
  `:conda_binary_corrupt`'s self-contained `exit /b` chain) are now individually traced and grouped
  into 6 batches by shape and risk (`docs/plan-die-fatal-remediation.md`'s Finding 3), landing in
  this order:
  - **Batch 1 (next up): the conda-acquisition-probe chain, 5 sites** (`conda.bat not found after
    bootstrap`, `'conda'`/`'python'`/`'python -V'` not-found-on-PATH, `Conda not found at:`) --
    same proven shape as slice 1, can currently stack 4-5 redundant `[ERROR]`/pause pairs for one
    root cause before reaching the real sink; existing test `tests/selfapps_conda_bothfail.ps1`
    already reaches this exact chain via its `:try_conda_install`-failure setup, so no new test
    hook is needed, only new assertions.
  - **Batch 2**: `:conda_create_done`'s "python.exe missing" check (1 site) -- fixes a genuinely
    misleading "[BOOT] ... Selected Python provider: Conda (Portable)." success-sounding message
    that currently prints right after an `[ERROR]` was already reported.
  - **Batch 4/5**: 7 embedded-helper-write-failure sites plus 2 CI-only-exposure sites -- low risk,
    low urgency, mechanical once each is individually traced.
  - **Batch 3**: the `:determine_entry` double-call (the first `call :die "[ERROR] Could not
    determine entry point"` site, inside `:after_env_mode_selection`) -- `:determine_entry` runs
    TWICE per normal bootstrap; falling through here wastes the entire
    dependency-install/pipreqs/warnfix block (far more intervening work than Batch 1) before
    reproducing the same failure at the second call site. MEDIUM risk (a real behavior change, not
    just a redundant-pause removal) -- lands on its own, later.
  - **Batch 6**: `:tci_both_failed`'s own two failure sites (inside `:try_conda_install`) -- MEDIUM
    risk, needs a new caller-side coordination flag (not a drop-in goto, since these sites already
    sit inside a `call`ed subroutine with their own `goto :eof`); deliberately deferred until after
    Batch 1 lands, since Batch 1's own fix already shrinks this site's fall-through blast radius as
    a side effect.
  - **The "Active Python interpreter not resolved" sink** (inside `:after_env_mode_selection`,
    every other batch's `goto` routes toward it) stays deferred indefinitely -- already
    Item-45-backstopped for the one dangerous consequence, a fix here would only trim harmless
    wasted work.
  Same EXTREME CAUTION discipline as every other high-risk change in this file: one batch lands at
  a time, full 8-lane matrix CI proof to completion before the next batch starts, no blanket sweep
  across every remaining site in one PR.

  **Batch 1 merged 2026-08-28 (PR #468). Batches 2/3/5 and one site of Batch 4 landed as a
  follow-on PR stacked on Batch 1, same session.** Batch 4's scope corrected from 7 sites to 1
  (the `Could not stage ~condarc` site only -- the other 6 traced individually and found to fall
  through into benign, silently-degraded continuations, not a redundant-`:die` cascade;
  reclassified alongside the "Active Python interpreter not resolved" sink, not fixed). Batch 6
  traced further (a second `:try_conda_install` call site found inside `:cascade_acquire_conda`)
  and remains deferred -- Batch 1's own fix already shrinks its residual value to "one fewer
  redundant pause in an already-rare scenario." New shared test hook
  `HP_TEST_FORCE_EMIT_FAIL=<VARNAME>` added to `:emit_from_base64` itself. New test file
  `tests/selfapps_die_emit_fallthrough.ps1` (4 scenarios:
  `missing_python`/`condarc`/`ci_skip_entry`/`determine_entry`) also surfaced a genuine, pre-
  existing, unfixed quirk: `:after_env_skip` writes `state=ok` unconditionally regardless of an
  earlier `call :die` in the same run (near-zero exposure, `HP_CI_SKIP_ENV` is test-infrastructure-
  only). Full detail: `docs/plan-die-fatal-remediation.md`'s "Implementation Status" section.

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
