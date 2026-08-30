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

Run `tools/run_sanity_sweep.sh [extra-file ...]` before every commit -- compileall, pyflakes,
`check_delimiters.py .` (whole repo), `check_crlf.py`, yamllint, actionlint, an ASCII sweep,
`git diff --stat`, a PowerShell AST parse of every `tests/`/`tools/` `.ps1` file, and
`pytest tests/test_*.py`, with a clear per-check pass/fail summary. Extra args extend the ASCII
sweep's default file list (illustrative, not exhaustive -- add whatever the current change
touches). README.md-only changes still run it as a baseline (catches an accidental non-doc
diff). It does not auto-install missing tools (`pwsh`/`actionlint`/`yamllint`/`pyflakes`) --
see AGENTS.md's "Style and robustness" section for install steps, and its "Recurring tooling"
section for what the sweep does and does not do. The script itself is the single source of
truth for exactly what runs; do not hand-copy its steps elsewhere.

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
| Never use `$IsWindows` in a `.ps1` file -- use `[System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT` | `$IsWindows` is undefined (reads `$null`/falsy) under Windows PowerShell 5.1, silently skipping real Windows execution -- fixed one file at a time across 4+ PRs before `tools/check_delimiters.py` (run repo-wide by the sanity sweep's "DELIMITER CHECK" step) started catching it mechanically; see `docs/agent-lessons-learned.md` |

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
python tools/check_delimiters.py .            # all supported files

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
  be blocked.** Goal: for every lane/row that is genuinely real (not a placeholder) and
  demonstrably non-flaky, make it capable of turning CI red for real, so "CI is green" stops being
  a partial truth for any lane or row this repo ships.

  **Known inventory to work through (re-derive against current state at slice time)**: non-gating
  lanes -- `cache`, `justme-test`, `uv`, `contract-uv`, `contract-uv-fail`, `uv-dl-fallback` (the
  last three are explicitly load-bearing as non-gating, since they simulate failure/contract
  scenarios that intentionally diverge from a normal run -- re-verify that reasoning still holds
  before excluding them, don't just carry the text forward); `ndjson-registry-check` (a separate
  advisory doc/code/log sync job, needs several more clean-PASS runs before even considering
  gating); inert/never-fired NDJSON rows with zero real-CI observation confirmed via
  `docs/agent-ndjson.md` -- `self.dll_bundle.recover` (see Item 37), `self.failfast.probe`,
  `self.exe.smokerun` (audit for others, these three are only the confirmed set); the real
  interactive `set /p` prompts and `pause`/`HP_INTERACTIVE_RUN`'s natural un-forced state, neither
  ever exercised in any CI configuration at all (lower priority -- already mitigated via forced-
  branch tests, just not the ambient real-user condition).

  **Non-negotiable constraint: the diagnostics-site-publish job must never be blocked or skipped
  by this work.** `publish_diag`'s `if: ${{ always() }}` / `needs: [selftest, selftest-gate,
  model-quick-fix]` guard already covers this -- any change to the job graph as part of this item
  must re-verify that `needs:` list still covers the right jobs and `if: always()` still applies,
  empirically (not just by reading the YAML) the first time `selftest-gate` actually goes red in
  practice.

  **"Gating" is a GitHub branch-protection setting, not a YAML edit.** This repo's actual merge
  gate is GitHub's native required-status-checks list on the default branch's protection rule
  (`pr-automerge.yml` delegates entirely to it, no custom required-check logic lives in this repo's
  own workflow code). Removing a job's `continue-on-error: true` is a necessary prerequisite but
  NOT sufficient -- someone with repo-admin access must also add the check's exact name to that
  list. Each slice's real deliverable is prove-readiness-then-flag-for-the-branch-protection-
  change (or make it directly, if the acting agent has that access) -- a YAML edit alone is never
  "done."

  **Aggregate-check mechanism: implemented and now the primary path for closing the required-
  checks maintenance treadmill (most lanes drifted non-gating simply because they were added AFTER
  the original required-checks list was set and never retrofitted in, not by deliberate policy).**
  `selftest-gate` ("Aggregate self-test verdicts") already downloads and aggregates every one of
  the 8 matrix lanes' `lane_verdict.json` files unconditionally via `tools/aggregate_selftest_
  verdicts.ps1`, comparing the SET of expected lane IDs against the SET of observed ones -- a
  missing, unexpected, or duplicate lane counts as `has_failures=true` on its own, independent of
  the overall job's own `success`/`failure` result (this fail-closed precondition was itself a
  real fix: the original mechanism only caught a TOTAL absence of verdict files, missing a single
  lane's silently-missing upload as long as the rest landed). Confirmed via
  `tests/test_aggregate_selftest_verdicts.ps1`'s fixtures (8 scenarios covering missing/
  unexpected/duplicate lanes, malformed JSON, and a missing `has_failures` field, none of which
  depend on a real Windows host) and several consecutive green real `real`-lane runs.

  **Actual gating step implemented 2026-08-30 (maintainer added the matching branch-protection
  required check the same day): a new "Enforce aggregate self-test verdict" step `exit 1`s when
  `steps.aggregate.outputs.has_failures == 'true'`**, mirroring the identical, already-proven
  "Enforce NDJSON failures for gated lanes" per-lane pattern. Re-verified first that
  `contract-uv`/`contract-uv-fail`/`uv-dl-fallback`'s own simulated-failure scenarios report a
  clean (non-`has_failures`) verdict on every real run observed to date, so gating on the
  aggregate does not turn them into permanent false blockers. Added ALONGSIDE the existing
  per-lane `real`/`conda-full` required checks, not replacing them -- collapsing to one aggregate
  check would lose today's per-lane visibility in the PR checks UI, and a bug in `selftest-gate`
  itself would otherwise remove the only signal. Consolidate down to just the aggregate check
  later, once its own reliability is separately proven across more runs.

  **Process discipline for every future slice in this item**: (1) one lane/row at a time --
  confirm the mechanism is genuinely real and non-flaky, let the full 8-lane matrix run to
  completion several consecutive times before treating it as proven, only then take the gating
  step; (2) no shortcuts on "let CI run to completion" -- a partial or cancelled run never counts.
  `docs/agent-ndjson.md`'s own notes on each currently-inert row already diagnose why it's inert;
  `docs/agent-closed-backlog.md`'s Item 19 entry is relevant prior art for the `cache` lane's own
  non-gating history.

- **Item 37: `self.dll_bundle.recover`'s visibility fix is confirmed via real CI (PR #452); its
  promotion out of `continue-on-error` (or the whole `cache` lane's) remains open, tracked as an
  Item 35 slice, not implemented independently.** The DLL-bundling repair loop's own NDJSON row
  previously never fired in any real CI run at all -- `selfapps_layered_e2e.ps1`'s sub-bootstrap
  ran with `HP_NDJSON` unset. Fixed by setting `HP_NDJSON` there (pointed at the same shared
  `~test-results.ndjson` the test's own rows already use, restored in `finally`) and diffing the
  file before/after to record, as an informational `details` field on `self.layered_e2e.chain`
  (deliberately NOT folded into that test's own pass/fail, so a wiring hiccup can't turn an
  already-proven test red). Confirmed via a real published diagnostics artifact: the row fired
  TWICE with `state:"repaired"` in one run. One confirmed run is not yet the "several consecutive
  runs" Item 35's process requires before considering promotion -- that decision is a live next
  step for a future loop.

- **Item 42: console verbosity (lever 1) is CLOSED (2026-08-24); the two fresh-build Y/N prompts
  (lever 2) remain open, tracked in `docs/open-questions.md`.** Two independent, separately-
  implementable levers, deliberately not conflated: (1) tier `:log`'s console output so a beginner
  isn't shown `[DEBUG]`/`[TRACE]` noise alongside genuinely actionable `[WARN]`/`[ERROR]` text; (2)
  reduce/reword the two elective Y/N prompts every successful fresh interactive build shows (the
  post-execution checkpoint, and the optimized-build upsell whose failure hint references "Visual
  Studio Build Tools" -- meaningless to the target audience).

  **Lever 1, shipped**: `:log` now suppresses `[DEBUG]`/`[TRACE]`/`[INSTALL]` from the LIVE console
  by default (a substring-slice check inside `:log` itself, not `findstr`/piping -- message text
  can legally contain `&`); `[INFO]`/`[BOOT]`/`[WARN]`/`[ERROR]`/`[STATUS]`/`[REPAIR]`/`[HINT]`
  stay visible (`[STATUS]` is the "did my code work" readout; `[REPAIR]` explains why a build is
  taking longer without looking stuck; `[HINT]` is the most actionable post-failure text in the
  file). `~setup.log` is untouched -- suppression is console-only. New opt-in `HP_VERBOSE_CONSOLE=1`
  restores all three suppressed tags (REQ-019-compliant additive opt-in), documented in README.md.
  A companion `[INFO] Installing dependencies -- this may take a few minutes...` progress line was
  added for what was previously the single longest silent stretch in a fresh build (no prior
  `[INFO]`-tier line existed for the dependency-install phase at all).
  Four test dependencies on the OLD console-redirected-capture behavior were found and fixed in the
  same change (`tests/selfapps_pvw_overrides.ps1`'s two `PVW_WORKSPACE` scenarios,
  `tests/selftest.ps1`'s `self.stub.conda_perpkg`/`self.stub.conda_retry`) -- the last one caught
  only by a real CI failure after an initial grep-for-brackets sweep missed it, since its own
  assertion matches a bracket-free phrase. A follow-up exhaustive sweep (every real `[DEBUG]`/
  `[TRACE]`/`[INSTALL]` message body grepped bracket-free against the full `tests/` tree) confirmed
  no fifth dependency remains -- the correct methodology for this class of check going forward is
  searching by message body, not by tag string. New regression coverage:
  `tests/selfapps_console_tiering.ps1` (`self.console.tiering`, `uv` lane, non-gating).

  **Lever 2, still open** -- this is user-facing copy and interaction-flow work needing a
  maintainer call (reword only vs. also combine the two prompts into one), not a unilaterally-
  correct technical fix like lever 1 was. See `docs/open-questions.md`'s open item for the two
  concrete sub-questions still needing an answer before this can move.

- **Item 46: `:die`'s `exit /b` lets most call sites continue executing afterward, producing
  repeated `pause` prompts and further doomed work instead of a single clear stop -- batched,
  proven-shape-at-a-time remediation, NOT a small slice.** See `docs/agent-lessons-learned.md`'s
  `:die` entry for the core mechanism (execution continues past `call :die`; `HP_BOOTSTRAP_STATE`
  is set at the source so the status file stays honest regardless).

  **Maintainer decision (2026-08-21)**: continue the current approach -- goto-based stopgaps to the
  nearest safe sink, batched by proven shape across several PRs -- rather than a global `HP_FATAL`
  flag or converting `:die` itself to a genuinely process-halting `exit` (drop `/b`). The latter is
  a plausible SEPARATE future effort once the batch inventory shrinks further, not folded into this
  ongoing work -- see `docs/plan-die-fatal-remediation.md` for the full batch trace/risk
  classification and `docs/agent-lessons-learned.md`'s `:die` entry for the one existing test
  contract (`tests/selfapps_entrysmoke_no_interpreter.ps1:171`) that change would need to update
  deliberately.

  Two non-pausing treatments exist for different shapes of `:die` site: `:warn_build_incomplete`
  (a genuinely NOT-doomed case -- real verification work still follows) and a straight `goto` to
  the nearest safe re-entry point (a genuinely doomed chain, where nothing useful follows). Not
  every `:die` site qualifies for either -- classify doomed-vs-not-doomed before converting a new
  one.

  **Status**: Bucket B (3 PyInstaller-build-failure sites -> `:warn_build_incomplete`) and Bucket A
  Batches 1/2/3/5 plus one Batch-4 site are merged (PR #468 and a same-session follow-on). **Still
  open**: Batch 6 (`:tci_both_failed`'s two failure sites, inside `:try_conda_install` -- needs a
  new caller-side coordination flag rather than a drop-in `goto` since they sit inside a `call`ed
  subroutine with their own `goto :eof`; deliberately deferred, since Batch 1's own fix already
  shrunk its remaining value to "one fewer redundant pause in an already-rare scenario"); the rest
  of Batch 4 (6 sites, individually traced and reclassified as falling through into benign,
  silently-degraded continuations rather than a redundant-`:die` cascade -- not fixed); and
  candidate (c), converting `:die` to a genuine halt, deferred per the maintainer decision above. A
  known, unfixed, near-zero-exposure quirk surfaced along the way: `:after_env_skip` writes
  `state=ok` unconditionally regardless of an earlier `call :die` in the same run
  (`HP_CI_SKIP_ENV` is test-infrastructure-only). Full detail:
  `docs/plan-die-fatal-remediation.md`'s "Implementation Status" section.

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
