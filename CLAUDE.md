# CLAUDE.md -- AI Assistant Guide for Python_vs_Windows

This file is the orientation document for AI assistants (Claude, Codex, Copilot, etc.)
working in this repository. It summarizes structure, workflows, and conventions.

**Do not duplicate content from these authoritative sources -- reference them instead:**
- **[README.md](./README.md)** -- Product requirements, Prime Directive specification, CI contract
- **[AGENTS.md](./AGENTS.md)** -- Agent iteration rules, scope policy, style rules, sanity checks
- **[CONTRIBUTING.md](./CONTRIBUTING.md)** -- Fork/branch/PR workflow and iteration priorities

**Supplemental context loaded automatically by Claude Code:**
@docs/agent-interconnect.md
@docs/agent-lessons-learned.md

**Reference-only, NOT auto-loaded -- read on demand, not every session:**
- `docs/agent-ndjson.md` -- the NDJSON row registry by lane. Read it when adding/renaming/removing
  a row, or debugging why a row is missing from a CI artifact. Moved out of auto-load 2026-08-30
  (~17k tokens of pure registry content with no forward-looking guidance most sessions need).
- `docs/agent-cold-storage.md` -- shelved ideas gated on a specific, checkable trigger.
- `docs/agent-closed-backlog.md` -- the full historical record of completed work, plus any
  Active Backlog item below that was later fully closed (see that file's own header).

**AGENT DIRECTIVE -- keep the knowledge docs current.** When a change teaches or invalidates
a lesson, update the relevant doc in the SAME commit, editing existing entries (not only
appending):
- `docs/agent-interconnect.md` -- cross-component dependencies ("touch A, must understand B").
- `docs/agent-lessons-learned.md` -- standalone hazards, rules, budgets, procedures. Most are
  batch/CMD syntax quirks and Windows shell gotchas; record those here.
- `docs/agent-ndjson.md` -- the NDJSON row registry (add/rename/remove rows here too; NOT
  auto-loaded, read it on demand when touching this).
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
  selfapps_pandas_excel.ps1    Pandas/openpyxl heuristic tests (the app and requirements.txt come from fixtures/examples/pandas_excel, Item 74)
  selfapps_pipgap.ps1          pip gap-fill safety net (runs run_setup.bat: conda misses opencv-python, pip fills it)
  selfapps_pipreqs_encoding.ps1 Item 63: pipreqs scan survives unreadable files (real lane, gating; PYTHONUTF8=0)
  selfapps_pipreqs_output.ps1  Item 63 follow-up: stale/locked requirements.auto.txt never accepted, scan temp folder not shared (real lane, gating)
  selfapps_entryarg.ps1        Item 67: first argument must be an existing .py in this folder (real lane, gating)
  selfapps_runtime_modnotfound.ps1 Item 65 slice 1: a ModuleNotFoundError printed to stderr by a run that exits 0 is reported by name (real lane, gating)
  selfapps_runtime_install.ps1 Item 65 slice 2: the consented install of a package a run asked for (yes installs, adds to requirements.txt, rebuilds with --hidden-import, one check run; no changes nothing; pyproject.toml left alone) (real lane, gating)
  selfapps_honest_wording.ps1  Item 68: dependency-source warning, stale-EXE rebuild notice, pipreqs diff placeholder (real lane, gating)
  selfapps_pep723_uverr.ps1    Item 73: a failed PEP 723 write-back logs uv's reason (real lane, gating; HP_TEST_PEP723_UV_ERR hook)
  selfapps_lastchance.ps1      Item 82: the last-chance offer after a failed uv run (W worked / C Miniconda / N neither; real lane gating) and the conda-tier window question (silent-timeout, cascade and window scenarios on the uv lane, non-gating)
  selfapps_provider_memory.ps1 Item 66: the provider memory file `~provider.state.json` and the `PVW_PROVIDER=conda` switch (no-switch, invalid value, Miniconda gone, unreadable file and cached-EXE rows on the real lane, gating; forced, remember and forced-stop rows on the uv lane, non-gating because of the Miniconda download)
  selfapps_runtests_contract.ps1 Item 84: runs a copy of run_tests.bat against stub scripts (a red harness still runs the self-tests, an unwritten or unremovable summary fails the run; six rows, every lane, gating)
  selfapps_realapp_pandas_excel.ps1 Item 75: a multi-file pandas + Excel app run three times in one folder (first run, unchanged re-run, requirements.txt edit); five `self.realapp.*` rows (real lane, gating); found Item 88
  selfapps_pyvisa_subfolder.ps1 Item 78 slice 2: NI-VISA install asks before running when the import is only in a subfolder (real and conda-full lanes, gating)
  selfapps_toml_uvcorpus.ps1   Item 79: the dependencies real `uv add --script` writes (bound, extra, two markers) are read back by pep723_extract.py exactly as tomllib reads them (uv lane, non-gating: needs the network; helper tests/toml_oracle_check.py)
  selfapps_isolation.ps1       REQ-010/REQ-011 behavioral tests (unconditional, HP_CI_SKIP_ENV=1)
  selfapps_pvw_builder.ps1     Item 71: PVW_BUILDER override (invalid/pyinstaller/nuitka/both; deterministic scenarios gate, real-Nuitka ones are uv lane)
  selfapps_dep_merge_later.ps1 Item 89: what a LATER run does with the dependency lists (delete, add, pin edit, header edit, a package pyproject.toml still lists, an unchanged run); eight `self.depmerge.later.*` rows (real lane, gating; needs the uv header write-back)
  selfapps_nuitka_cachesafety.ps1 Item 72 follow-up (closed, flag NOT adopted): row self.nuitka.cachesafety measures what a static Nuitka unpack folder would break (warm and cold concurrent launches, overlap, kill mid-unpack, update while the old build runs) and records adoptable; uv lane, non-gating
  selfapps_example_apps.ps1    Item 74: three curated example apps from fixtures/examples (stdlib only, two files with a sibling import, a tkinter window that closes itself) run through the bootstrapper with no skip hook (real lane, gating)
  fixtures/examples/           Item 74: the curated example apps a person can drop next to run_setup.bat (README.txt inside); CI scenarios read these files, nothing generates them inline
  selfapps_unlaunchable_exe.ps1 Item 87: a dist\<env>.exe that Windows cannot start (text-file stub) ends the EXE verification run and the fail-fast probe instead of hanging them (real lane, gating, 15-minute watchdog per run; HP_TEST_CORRUPT_BUILT_EXE hook)
  selfapps_embed_version.ps1   REQ-009 Tier 5: the embed tier honors the Python version a program asks for (runtime.txt 3.12 is swapped in and is what the program runs under; 3.9 runs under the table floor with a WARN; 3.99 runs under the newest minor with a WARN; a pyproject.toml `>=3.11,<3.13` gets 3.12, the newest minor the range allows; four full builds, real lane, gating, 30-minute watchdog per run)
  selfapps_launch_ledger.ps1, selfapps_dep_source_matrix.ps1, selfapps_skiphooks_single.ps1, selfapps_log_rotate.ps1,
  selfapps_unicode_path.ps1, selfapps_unc.ps1, selfapps_noflag_default.ps1, selfapps_longpath_near.ps1   The gap-map scripts
                               (T1, T2, T7, T8, T9, T12; plan and row list in docs/plan-test-suite-gaps.md; real lane, gating)
  dynamic_tests.py             Python-side entry detection and version precedence tests
  test_*.py                    Python unit tests (14 files, see Testing section)

tools/
  apply_patch.py               Unified/legacy diff parser and applier (used by inline_model_fix)
  find_entry.py                REQ-002 entry-point selector (canonical source for HP_FIND_ENTRY)
  pipreqs_precheck.py          Item 63 pre-check/UTF-8 staging for pipreqs (canonical source for HP_PIPREQS_PRECHECK)
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
  agent-ndjson.md              NDJSON row registry by lane (NOT auto-loaded)
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
   | `HP_PIPREQS_PRECHECK` | `~pipreqs_precheck.py` | Item 63: reads every `.py` before pipreqs does (declared/detected encoding, then `ast.parse`); exit 0 = all clean UTF-8, scan in place; exit 10 = write a UTF-8 copy of the tree (re-encoded files, empty stubs for unreadable ones so their module names stay local) for pipreqs to scan; writes `~pipreqs_precheck.txt` (one INFO line per file capped at 100, a `[WARN]` per file left out capped at 25); every name it prints is stripped to a safe ASCII alphabet because the batch echoes it; run via `%HP_PY%` from `:pipreqs_precheck` | `tools/pipreqs_precheck.py` |
   | `HP_PREFLIGHT_CHECK` | `~preflight_check.py` | Item 83: the REQ-021 pre-flight syntax check; compiles the entry in memory with the interpreter's own parser, so it writes no `.pyc` and cannot fail on a read-only or file-shaped `__pycache__` (the old `py_compile` call did both); exit 0 valid, 1 syntax error with the interpreter's own message on stderr, anything else means it could not decide and the run continues with a `[WARN]`; run via `%HP_PY%` from `:preflight_compile` | `tools/preflight_check.py` |
   | `HP_PEP723_EXTRACT` | `~pep723_extract.py` | Item 62: extracts the `dependencies` of a PEP 723 `# /// script` block, one per line; accepts the shapes real tools write (CRLF, any `#` spacing, quote style, trailing commas, one-line or multi-line arrays), decodes TOML escapes in double-quoted items, and rejects an array with no closing bracket; a nonzero result leaves no output file (the batch subroutine deletes it); exit 0/1/3 = written/nothing usable/internal error, with a one-line reason on stdout for the setup log; run via `%HP_PY%` from `:extract_pep723_requirements` | `tools/pep723_extract.py` |
   | `HP_RUNTIME_MODULE_SCAN` | `~runtime_module_scan.py` | Item 65 slice 1: reads the stderr of a run that just finished and prints, one per line, each module it names as missing (`No module named 'X'`, top-level name) that the interpreter does not have; skips stdlib names, modules found next to the script, and anything that is not a plain identifier (the batch echoes the names unquoted); exit 0 always except 3 for an internal error; run via `%HP_PY%` from `:scan_runtime_missing_module`; slice 2 adds `--packages` (module to package, conda gets `opencv` for `cv2`) and `--append` (adds to `requirements.txt` unless already declared) for `:runtime_install_offer`, about 354 characters of room left | `tools/runtime_module_scan.py` |
   | `HP_LAST_ERROR_LINE` | `~last_error_line.py` | Item 82 slice 1: writes the last non-blank line of a failed run's stderr to a file, two spaces in front, printable ASCII kept literally (`<`, `>`, `&`, `|`, `%`, `^` included, everything else becomes `?`, cut at 200 characters), so the last-chance offer can show it with `type`; exit 0 written, 1 nothing to show, 3 internal error; run via `%HP_PY%` from `:lc_last_line` | `tools/last_error_line.py` |
   | `HP_DEP_MERGE` | `~dep_merge.py` | Item 89: merges the dependency lists of requirements.txt, pyproject.toml and a PEP 723 header (a cold run is a union, a later run keeps the user's changes since the `~dep_base.*.txt` records, the rank header > pyproject > requirements.txt settles a conflict about one package); writes the merged `requirements.txt`, `~dep_merge.report.txt`, `~dep_merge.removed.txt` and `~dep_merge.changed.txt`; exit 0 merged / 1 nothing to merge / 3 internal error (the batch then keeps the highest ranked list alone and warns); run via `%HP_PY%` from `:dep_merge_inputs`, about 560 characters of room left | `tools/dep_merge.py` |

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
| `test_pipreqs_precheck.py` | Item 63: pipreqs pre-check (U+201D file ok as UTF-8, declared-cp1252 re-encoded, no-cookie cp1252 and unparseable left out, BOM, ignore folders, staged tree contents, exit codes 0/10/3, report hygiene and caps, `--encoding utf-8` on every pipreqs invocation, HP_PIPREQS_PRECHECK payload sync) |
| `test_preflight_check.py` | Item 83: in-memory syntax check (valid file exits 0 and writes nothing, a FILE named `__pycache__` changes nothing, syntax/indentation/tab/encoding/null-byte errors exit 1 with the interpreter's wording, exit 3 when it cannot decide, user code never runs), `:preflight_compile` call-site wiring (no `py_compile`, only exit 1 reports a syntax error), Python 3.9 grammar guard, HP_PREFLIGHT_CHECK payload sync |
| `test_pep723_extract.py` | Item 62: PEP 723 dependency extraction (the layout `uv add --script` writes in LF and CRLF, hand-written layouts, one-line arrays, quote styles, comments, BOM, fence whitespace, tool-table and malformed negatives), Python 3.9 grammar guard, HP_PEP723_EXTRACT payload sync |
| `test_runtime_module_scan.py` | Item 65 slice 1: runtime missing-module scan (top-level name from a traceback, submodule, repeats, ImportError wording, cap; installed/on-path/stdlib/non-identifier names not reported; local module next to the helper; CLI exit codes; the three batch call sites and the reminder order; Python 3.9 grammar guard; HP_RUNTIME_MODULE_SCAN payload sync); slice 2: `--packages`/`--append` modes, name table equal to warnfix's, requirements editing, batch call sites of the offer |
| `test_last_error_line.py` | Item 82 slice 1: last-error-line helper (last non-blank line, CRLF and blank-tail handling, every shell operator kept, controls and non-ASCII become `?`, 200-character cut, tail-only read, exit codes 0/1/3, Python 3.9 grammar guard) and the batch wiring of `:last_chance_offer` (call site and order, each not-offered reason, gate order, prompt text before the gate, W/C/N resolution, error line shown with `type` and never through `:log`, input capture sites, per-attempt reset, reworded `RUNTIME_MISMATCH` hint, HP_LAST_ERROR_LINE payload sync) |
| `test_window_confirm.py` | Item 82 slice 2: the kill marker is cleared before the runner launches and read only from the file (never from the exit code), the window question's conditions and gate order, only an explicit yes records `user_confirmed`, the automated branch asks nothing |
| `test_provider_memory.py` | Item 66: `PVW_PROVIDER` validation (compared with `findstr /x /l` on the `set` output, no line expands the variable, runs after the file count and before the cached-EXE fast path), uv skips tested before the `PVW_UV_EXE` branch, the memory read contract (conda only, Miniconda present, never cleared by input edits), write guards (verified pass, conda after uv, state ok, no switch), the `runtime.txt` record at all three write-back sites, the failed-forced-solve hint |
| `test_req_trace.py` | Requirement traceability ratchet (docs/plan-test-suite-gaps.md T5): every README/batch requirement number has a tagged NDJSON row or a listed exemption, undocumented requirement numbers and tag typos fail; synthetic cases prove each rule can fail |
| `test_flag_inventory.py` | REQ-019 mechanical half (T6): every `HP_TEST_*` hook the batch reads is named by a test or workflow, README env-table flags exist in code, `PVW_*` overrides are documented; synthetic cases prove each rule can fail |
| `test_elevation_stdin.py` | Item 78 follow-up: the one `fsutil` call (in `:detect_elevation`) runs with `<nul`, so the elevation test cannot take the program's redirected stdin (behavior proven by `self.interactive.stdin.roundtrip`); synthetic case proves the guard can fail |
| `test_run_tests_step.py` | Item 84: the "Run tests (run_tests.bat)" CI step must end in `exit $rc` with no empty-repo mapping, and `selfapps_runtests_contract.ps1` must end with its own `exit 1` (any red row) and `exit 0`; synthetic cases prove each rule can fail |
| `test_builder_override.py` | Item 71: the PVW_BUILDER override's parse lines, the fallback guard before the Nuitka install, the nuitka branch of the build block, the offer guards before the prompt, the fast-path note and the interconnect entry (static scans) |
| `test_unlaunchable_exe.py` | Item 87: the three bounded-launch helpers (`exe_smokerun.ps1`, `failfast_probe.ps1`, `exe_hint_rerun.ps1`) run through real `pwsh` with a text, zero-byte, cut-off or missing file as the program, under a hard timeout: each returns, writes `~launch_failed.txt` (one printable-ASCII line), prints that the program could not be started and leaves the result the caller expects (`-1`, `0\|-1`, empty output); a good program leaves no marker; static pins on the batch (marker cleared before and read after the launch, the unusable EXE removed, the interpreter run that follows, the shared reporter shows the reason with `type`, the test hook before the launch) |
| `test_example_fixtures.py` | Item 74: the example apps under `tests/fixtures/examples` stay plain examples (exactly the listed files, ASCII, compile in memory, every import is stdlib, a sibling file or a declared package, README.txt names every folder) and the places that read them (`selfapps_example_apps.ps1`, `selfapps_pandas_excel.ps1`, the real-lane workflow step and its artifact paths) cannot move back inline; synthetic trees prove each rule can fail |
| `test_toml_oracle.py` | Item 79: tomllib as the oracle for the two hand-written TOML array readers: `pyproj_deps.py` (with and without tomllib, LF and CRLF) and `pep723_extract.py` (against the PEP's own regex plus tomllib in `tests/toml_oracle_check.py`) over a PEP 508 corpus (markers in both quote styles, escapes, URLs, comments); an unclosed array must be refused (exit 2 / exit 1), not read as a shorter list |
| `test_dep_merge.py` | Item 89: dependency-list merge (cold run is a union, rank settles a conflict, bare name never beats a constrained entry, later runs keep the user's add / delete / pin edit, a package pyproject.toml still lists stays, the changed flag, a failing helper exits 3, the batch wiring and message wording, Python 3.9 grammar guard, HP_DEP_MERGE payload sync) |
| `test_autopep_merge.py` | REQ-005.12 / Item 88: autopep723 name extraction, dedup against `requirements.txt`, newline repair, `main()` dispatch, and the local-module filter (sibling `.py` files and folders in any spelling are skipped and logged, ignored and hidden folders are not walked, a real package is still added), HP_AUTOPEP_MERGE payload sync |
| `test_embed_tier.py` | REQ-009 Tier 5: version-table resolution (floor/ceiling fallback, the newest minor a range allows, the swap download with the network mocked), the batch step that reads the request when no earlier step did, batch `HP_EMBED_LATEST_*` constants equal the table's `LATEST_MINOR` entry, HP_EMBED_EXTRACT / HP_EMBED_PYVER_CHECK payload sync, and static pins for `tests/selfapps_embed_version.ps1` (literal ids, own exit codes, watchdog, real-lane gating step, 3.12 strictly inside the table); synthetic cases prove each rule can fail |
| `test_nuitka_launchcache.py` | Item 72 (b): the Nuitka launch-cache experiment `tests/selfapps_nuitka_launchcache.ps1` builds with the same flags as the two Nuitka command lines in `run_setup.bat` (exactly 2 such lines; its `Build-App` takes its flags from the checked `$prodFlags`, not literals), runs only on the uv lane and is non-gating, emits its registered row, ends with its own exit codes and checks the cache folder in its long form (a runner reports it as `PVWEXP~1`); synthetic cases prove each rule can fail |
| `test_nuitka_cachesafety.py` | Item 72 follow-up: `run_setup.bat` has exactly two Nuitka command lines, with the production flags and NO `--onefile-tempdir-spec`/`:nuitka_cache_arg` anywhere (a static unpack folder failed cold concurrent launches; the message names the cold-storage trigger); the safety script emits its row once, builds with the production flag text plus the spec, asserts warm/overlap/kill-recovery/post-cold-launch but only RECORDS the cold rounds and the update scenario (`adoptable` needs both), ends with its own exit codes, and its step is uv-only and non-gating; synthetic cases prove each rule can fail |
| `test_nuitka_unsupported_hint.py` | Item 80: the mark/command/check order around each of the two Nuitka command lines, the count's `findstr` pattern against Nuitka's real "is not supported" line (matches) and its "only experimentally supported" warning, the bootstrapper's own sentence and a different failure (do not match), the sentence safe for `:log`, the check fail-safe without a mark, and the three `selfapps_pvw_builder.ps1` stub lines agreeing with the pattern; synthetic cases prove each rule can fail |

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

Items 35-46 below stem from a 2026-08-09 Opus 5 release-readiness deep dive of `run_setup.bat`'s
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
  lanes at the PER-LANE level -- `cache`, `justme-test`, `uv`, `contract-uv`, `contract-uv-fail`,
  `uv-dl-fallback` (the last three are explicitly load-bearing as non-gating, since they simulate
  failure/contract scenarios that intentionally diverge from a normal run -- re-verify that
  reasoning still holds before excluding them, don't just carry the text forward) still have no
  required-status-check of their OWN -- but since the "Enforce aggregate self-test verdict" gate
  below aggregates all 8 lanes, a real failure in any of them blocks a merge via the aggregate
  check even though the individual lane still shows non-required in the PR checks UI (the step is
  real since 2026-10-24, see "Aggregate gate" below). "Non-gating" in this item means "has no
  required check of its own", not "cannot block a merge." `ndjson-registry-check` (a separate
  advisory doc/code/log sync job, needs several more clean-PASS runs before even considering
  gating); inert/never-fired NDJSON rows with zero real-CI observation confirmed via
  `docs/agent-ndjson.md` -- `self.dll_bundle.recover` (see Item 37), `self.failfast.probe`,
  `self.exe.smokerun` (audit for others, these three are only the confirmed set); the real
  interactive `set /p` prompts and `pause`/`HP_INTERACTIVE_RUN`'s natural un-forced state, neither
  ever exercised in any CI configuration at all (lower priority -- already mitigated via forced-
  branch tests, just not the ambient real-user condition).

  **Row added 2026-10-09 (Item 62)**: `self.pep723.writeback.roundtrip` (`selfapps_pep723_writeback.ps1`,
  `uv` lane, real uv writes the header and the next run must read it back) was green on its first
  full run (`37938844739`). It gates through the aggregate check like every other row now.

  **Non-negotiable constraint: the diagnostics-site-publish job must never be blocked or skipped
  by this work.** `publish_diag`'s `if: ${{ always() }}` / `needs: [selftest, selftest-gate,
  model-quick-fix]` guard already covers this -- any change to the job graph as part of this item
  must re-verify that `needs:` list still covers the right jobs and `if: always()` still applies,
  empirically (not just by reading the YAML) the first time `selftest-gate` actually goes red in
  practice.

  **A DIFFERENT, more specific gap in this same guarantee was found and fixed 2026-08-30, prompted
  by a maintainer question about whether Pages publishing was truly guaranteed.** Job-level
  `if: always()` only makes the JOB start regardless of `needs:` outcomes -- it does NOT make every
  STEP inside the job run regardless of an earlier step's failure (GitHub Actions gives every step
  an implicit `if: success()` unless it declares its own condition, which a genuine, not just
  skipped, prior-step failure turns false). Two of `publish_diag`'s own early steps -- "Checkout
  repository" and "Prep site directories" (the step that actually creates the `_site`/`.nojekyll`
  skeleton) -- had no explicit `if:` at all. Had either genuinely failed, everything downstream
  would still have attempted to run (nearly every later step in this job already carries its own
  `if: always()`, and the deploy steps' own `event_name`/`outcome`-gated conditions already bypass
  the default `success()` chaining too), but `_site` itself would never have been created, so
  "Upload Pages artifact" would fail for real (path doesn't exist) rather than the deploy simply
  being skipped or attempted against a thinner site. Fixed by adding `if: always()` to those two
  steps plus three more found lacking it for consistency ("Record iterate artifact status",
  "Fetch batch-check artifacts", "Append job summary" -- lower-stakes, since everything after them
  already had `always()`, but leaving them inconsistent was pointless risk). **Clarifying the
  causal story, since it wasn't quite what was suspected**: the widespread `continue-on-error`/
  `exit 0` patterns scattered across the OTHER jobs in this file (the non-gating matrix lanes, a
  handful of optional sub-steps) are NOT what protects Pages publishing -- `publish_diag`'s own
  `if: always()` at the job level already guarantees it starts regardless of whether `selftest`/
  `selftest-gate`/`model-quick-fix` succeed OR fail, with no dependency on those jobs being lenient
  with themselves. Those other patterns exist for unrelated reasons already documented under this
  repo's own CI lane policy (see "CI Overview" and the "CI lane gating maturity" periodic check).
  One inherent, unfixable-via-YAML platform limit remains: `always()` does not run a job if the
  whole workflow run itself is cancelled or the runner dies outright -- accepted as an unavoidable
  GitHub Actions characteristic, not a gap in this repo's own control.

  **A WIDER, pre-existing version of this same class of gap remains open, out of scope for the
  2026-08-30 fix above (CodeRabbit review, PR #471).** The fix above closed the reachability gap
  for the 5 specific steps this PR's diff touches. Several OTHER `publish_diag` steps this PR never
  touched -- `Package iterate logs archive`, `Mirror iterate logs into site bundle`, `Normalize
  iterate artifact layout`, `Publish diagnostics index` (all pre-existing `if: always()`, confirmed
  absent from this PR's own diff) -- consume `steps.prep.outputs.ARTIFACTS`/`DIAG`/`SITE` directly,
  unguarded, the same way the 2 fixed steps did before their fix; if `Prep site directories` itself
  fails before writing those outputs (as opposed to merely being skipped because an earlier step
  failed), these steps would resolve to a malformed path (e.g. bash's `"${EMPTY}/iterate"` becomes
  `/iterate`) rather than the graceful scratch-directory fallback the 2 fixed steps now have.
  Auditing and fixing every such consumer across the whole job is a real, separate, larger
  undertaking (a full pass over `publish_diag`'s ~20+ steps) -- deliberately not folded into this
  PR, which is scoped to the reachability gap alone. A future slice should generalize the
  `_site_prep_failed`-style fallback to a single shared early step (writing a fallback env var or
  step output once) rather than repeating the guard at every consumer site.

  **"Gating" is a GitHub branch-protection setting, not a YAML edit.** This repo's actual merge
  gate is GitHub's native required-status-checks list on the default branch's protection rule
  (`pr-automerge.yml` delegates entirely to it, no custom required-check logic lives in this repo's
  own workflow code). Removing a job's `continue-on-error: true` is a necessary prerequisite but
  NOT sufficient -- someone with repo-admin access must also add the check's exact name to that
  list. Each slice's real deliverable is prove-readiness-then-flag-for-the-branch-protection-
  change (or make it directly, if the acting agent has that access) -- a YAML edit alone is never
  "done."

  **Aggregate gate: real since 2026-10-24 (criterion C6).** `selftest-gate` ("Aggregate self-test verdicts", a
  required check) aggregates the eight lanes' `lane_verdict.json` files through `tools/aggregate_selftest_verdicts.ps1`,
  fail-closed (a missing, unexpected or duplicate lane is `has_failures` on its own), and its "Enforce aggregate
  self-test verdict" step now `exit 1`s on `has_failures == 'true'` with no `continue-on-error`. So ANY row with
  `pass:false` in ANY lane (`cache`, `uv`, `justme-test`, `contract-uv`, `contract-uv-fail`, `uv-dl-fallback` included)
  turns that check red and holds auto-merge; the Pages publish and the iterate gate still run (`publish_diag` and
  `model-quick-fix` keep `if: always()`). A row that records a finding and not a failure must write `pass:true` plus a
  `details` flag (`self.nuitka.cachesafety` uses `inconclusive`); the per-lane verdict ignores nothing else.
  `tests/test_aggregate_gate.py` pins the step (no `continue-on-error`, its `if`, the lane list equal to the matrix,
  the `always()` jobs). Proof, run `40123300274` (a throwaway red row in `contract-uv-fail`, since removed): the
  aggregate job failed at that step while `model-quick-fix` and the Pages publish still ran and succeeded. All eight
  lanes were red in that run (the guard test fails while the probe is in), so it shows the step fails the job and the
  publish survives it; that a single failing lane is enough is shown by the fixtures in
  `tests/test_aggregate_selftest_verdicts.ps1`.
  **Consequence to know**: upstream drift on a provider-dependent `uv`-lane row (a new Python, uv or Nuitka release;
  Item 80 was five such rows for two days) now holds every PR until the row is fixed or its pass condition is
  corrected; do not skip or relax a row to get green (AGENTS.md). The history (the 2026-08-30 revert on PR #471, the
  cascade and warnfix reds fixed by PR #491, the `cache` smokerun artifact, the soak evidence) is in
  `docs/agent-closed-backlog.md`, "Item 35 aggregate gate history".

  **Process discipline for every future slice in this item**: (1) one lane/row at a time --
  confirm the mechanism is genuinely real and non-flaky, let the full 8-lane matrix run to
  completion several consecutive times before treating it as proven, only then take the gating
  step; (2) no shortcuts on "let CI run to completion" -- a partial or cancelled run never counts;
  (3) this soak applies to PROMOTING an existing non-gating lane or row, not to a new test: a new test
  gates from its first run and a red one holds auto-merge (see AGENTS.md, "New tests gate immediately").
  `docs/agent-ndjson.md`'s own notes on each currently-inert row already diagnose why it's inert;
  `docs/agent-closed-backlog.md`'s Item 19 entry is relevant prior art for the `cache` lane's own
  non-gating history.

- **Item 37: `self.dll_bundle.recover`'s visibility fix is confirmed via real CI (PR #452); its
  promotion out of `continue-on-error` (or the whole `cache` lane's) remains open, tracked as an
  Item 35 slice, not implemented independently.** The DLL-bundling repair loop's own NDJSON row
  previously never fired in any real CI run at all -- `selfapps_layered_e2e.ps1`'s sub-bootstrap
  ran with `HP_NDJSON` unset. Fixed by setting `HP_NDJSON` there (pointed at the same shared
  `~test-results.ndjson` the test's own rows already use, restored in `finally`) and diffing the
  file before/after to record (since 2026-10-11 the sub-bootstrap writes a private
  `~layered_e2e_sub.ndjson` and the test forwards the rows, see Item 35), as an informational
  `details` field on `self.layered_e2e.chain`
  (deliberately NOT folded into that test's own pass/fail, so a wiring hiccup can't turn an
  already-proven test red). Confirmed via a real published diagnostics artifact: the row fired
  TWICE with `state:"repaired"` in one run. One confirmed run is not yet the "several consecutive
  runs" Item 35's process requires before considering promotion -- that decision is a live next
  step for a future loop.

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

### Items 64-78: Aug-Sep 2026 real-user field report (filed 2026-10-08; Items 62, 63, 64, 65, 66, 67, 68, 70, 71, 72, 73, 74, 75, 76, 77, 78, 80 and 81 shipped, see `docs/agent-closed-backlog.md`)

Ranked by default-path impact. Evidence, root causes, fix shapes, the CI proof each needs, and
the "already fixed / do not add" list are in `docs/plan-field-report-2026-10.md`; read it before
starting any of these. No maintainer decisions are open. Q1-Q11 are decided or retired (see Items 65, 66, 67, 69, 71, 76 and 78).
The maintainer cannot hand-test, so every item ships with a Windows CI scenario that reproduces
the original symptom (see that doc's "CI-first testing policy").


### Item 89: the dependency lists are merged, not chosen between (filed 2026-10-23 from the maintainer's answer to open question 3)

- **Item 89 (in progress; README REQ-005.1 rewritten; red tests first, fix second, one PR)**: the maintainer decided that
  PEP 723 header, `pyproject.toml` and `requirements.txt` are merged with the existing rank settling conflicts, and
  that after a good run `requirements.txt` and the header both hold the merged list; a cold first run is a union and a
  later run keeps the user's changes since the last good run (an add is added everywhere, a removal from a list the
  bootstrapper wrote is removed everywhere, an edited pin beats the older pins without being called a conflict).
  Built as `tools/dep_merge.py` (`HP_DEP_MERGE`), `:dep_merge_inputs` after the PEP 723 extraction, the removal through
  `uv remove --script`, the records written by `:dep_merge_snapshot` from `:success`. Rows: `self.depsource.*`
  (`all_three`, new `requirements_pyproject` and `conflict`), `self.pep723.pyproject.merge` (was `.override`),
  `self.depmerge.later.*`, `self.realapp.edit_rerun`. Consequences recorded in the README notes: a folder with no record
  is cold on its first run after the change; a package deleted from one list while `pyproject.toml` still lists it comes
  back with a message. **Follow-up not built here**: the Item 65 runtime-install offer still edits no file for a
  `pyproject` or `pep723` source (`HP_RTI_EDITS`), although an appended `requirements.txt` line now lasts; simplifying
  that is a separate item (needs the coordinator's number).

### Item 90: bump the GitHub Actions pins by hand, one action per pull request (filed 2026-10-24)

- **Item 90 (small each, mechanical; from the October 2026 scan, `docs/open-questions.md` Q5 still open)**:
  Dependabot has opened nothing, so the pins are bumped by hand, each action in its own PR that is read in CI
  like any other (the maintainer's answer to Q5 can only switch this to Dependabot's PRs). Per bump: read the
  action's release notes for the new major (WebFetch of `https://github.com/<owner>/<repo>/releases`), change
  every use of that one action, and read the run, not only its colour. Status (in use -> latest as read on
  2026-10-24): `codeql-action` v3 -> v4 done in `codeql.yml` (v4 runs on Node.js 24, v3 is deprecated in
  December 2026; the run of PR #508 logged `CODEQL_ACTION_VERSION: 4.39.1` and uploaded its results without a
  warning). Open, with what the release notes say and what this repo's use of each action means for the bump
  (release notes read 2026-10-24; none says a Node.js or runner minimum beyond runner 2.327.1, which GitHub-hosted
  runners exceed): `github-script` v8 -> v9 (6 uses in `pr-automerge.yml`, 3 in `batch-check.yml`): v9 removes
  `require('@actions/github')` and injects `getOctokit`; no script here uses either (only `require('fs')`), so the
  bump should be inert. `checkout` v5 -> v7 (every workflow): v7 blocks a fork PR checkout under `pull_request_target`
  and `workflow_run`; no workflow here uses either trigger. `cache` v5 -> v6: ESM only. `upload-artifact` v6 -> v7: ESM,
  new `archive: false` option, no breaking change listed (13 uses in `batch-check.yml`, 1 in `workflow-lint.yml`).
  `download-artifact` v6 -> v8 is the one with a behavior change: v8 fails the step on a hash mismatch by default
  (`digest-mismatch: error`; v7 only warned) and no longer unzips non-zip downloads, so bump to v7 first, then v8, and
  re-read the GitHub Actions data-passing entry in `docs/agent-lessons-learned.md` (`merge-multiple`). Every open
  one touches `batch-check.yml`, which lane 1's aggregate-gate edit owns, so those wait for it to merge. Remove this
  item when every pin is on its latest major.

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

- **Last scanned**: 2026-10-24.
- **Findings**: the pins are no longer all on their latest majors (the 2026-07 sweep said they
  were; `upload-artifact` v7 shipped in 2026-02, so that sweep may already have been wrong). Read
  from each action's GitHub releases page (the page shows day and month, no year, so read these as
  indicative): in use -> latest: `checkout` v5 -> v7, `cache` v5 -> v6, `upload-artifact` v6 -> v7,
  `download-artifact` v6 -> v8, `github-script` v8 -> v9, `codeql-action` v3 -> v4 (bumped by hand under
  Item 90). Current: `configure-pages@v6`, `upload-pages-artifact@v5`,
  `deploy-pages@v5`. No pin was edited in this scan: the artifact actions' majors change behavior
  CI relies on (artifact naming, `merge-multiple`, hash checks), so each bump is its own CI-proven
  PR, one action at a time. **Dependabot is inert**: `.github/dependabot.yml` landed 2026-08-17 and
  not one Dependabot PR or `dependabot/*` branch has existed since (every PR checked by author and
  head branch). The reason is not visible from a session (repository settings), so it is
  `docs/open-questions.md` Q5. Notices unchanged: "Node.js 20 is deprecated ... forced to run on
  Node.js 24" against `download-artifact@v6` (now also explained by the pin being behind); the
  punycode notice was not seen in the sampled run. `actionlint` and `yamllint` clean.
- **Going forward**: once Q5 is answered, either Dependabot's first PRs arrive or the pins are
  bumped by hand. Re-read the latest majors every scan: from a session `gh` and `curl` cannot reach
  other repositories, but `WebFetch` of `https://github.com/<owner>/<repo>/releases` works.

### Persisted CI run-page warnings

- **Last scanned**: 2026-10-24.
- **Findings**: annotations of every job of the latest full `main` run (40055643200). (1) NEW on
  all seven Windows matrix jobs: `Environment variable 'INPUT_PATH' exceeds the maximum supported
  length` (53197 against 32766): the `test-logs` upload step's `path:` list, about 55k characters
  today and two lines per file. Nothing is lost today: 160 of the 233 forward-slash patterns that
  sit past character 32766 matched files in the `real` lane's `test-logs` artifact (the rest are
  scenario-specific). If a late scenario's log ever goes missing from an artifact, suspect this
  first, and prefer one directory pattern per scenario over per-file lines before the list doubles.
  (2) Benign by design, shown as red "failure" annotations: the aggregate-verdict fixtures
  (`expected lane(s) never reported a verdict`, `bogus-lane`) and the cache self-heal fixtures
  (`Conda binary health check failed`) on the `real` job, and `Artifact not found for name:
  iterate-logs-...` in "Publish diagnostics to Pages" (a `continue-on-error` download when the
  model quick-fix did not run). (3) The `ubuntu-latest will migrate to Ubuntu 26` notice on the
  Linux jobs: informational, but a Linux job that breaks in the next weeks should be checked
  against it first.
- **Going forward**: look for anything recurring across several runs, not one-off transient
  network blips (e.g. the `conda.anaconda.org` 403 already tracked separately as the
  conda-create transient-retry gap above).

### CI lane gating maturity

- **Last scanned**: 2026-10-24.
- **Findings**: policy unchanged: only `real` and `conda-full` gate PR merges on their own;
  `cache`, `justme-test`, `uv`, `contract-uv`, `contract-uv-fail`, `uv-dl-fallback` are
  non-gating (see AGENTS.md and the Closed Backlog for why each was made so). Evidence for Item
  35's soak rule: on the 11 most recent `main` push runs (2026-10-17 to 2026-10-24, run
  38985194530 through 40055643200) the aggregate step succeeded and "Enforce aggregate self-test
  verdict" was `skipped` every time, i.e. eleven consecutive complete matrices with no failing row
  on any of the eight lanes by the aggregate's own verdict, and `ndjson-registry-check` succeeded
  on all eleven. That is the "several consecutive complete green matrices" Item 35 asks for before
  removing `continue-on-error: true` from the aggregate gate; the removal landed with PR #509 the
  same day (criterion C6). Next scan: confirm "Enforce aggregate self-test verdict" is still
  `skipped` on the `main` push runs since, and that no PR sat red on a row nobody owns.
- **Going forward**: `uv` is the slowest lane (see the wall-clock entry) and its rows depend on the
  network (uv, Miniconda, python.org downloads), so a required check of its own would add flake
  risk the aggregate gate already covers; do not promote it separately. Leave
  `contract-uv`/`contract-uv-fail`/`uv-dl-fallback` non-gating indefinitely (their non-gating
  status is explicitly load-bearing, not provisional). `ndjson-registry-check` has now had a long
  clean run; gate it only after the aggregate gate is, one change at a time.

### CI wall-clock duration (slowest-lane growth)

This tracks a genuine periodic-reassessment concern, not a one-time backlog item -- moved here
2026-07-25 from Active Backlog (it was originally filed as a backlog item, but "worth periodic
reassessment, no action planned" is exactly what this section exists for, and letting it grow
stale as a single never-closed backlog entry was the wrong home for it).

**What this tracks and why it matters**: all 8 matrix lanes run in parallel, so the WHOLE
workflow's wall-clock is bounded by whichever lane is slowest, and that lane's growth directly sets
how long every contributor waits for a PR to go green (development velocity, not correctness --
nothing about the lanes is broken). Through 2026-07 that lane was `conda-full` (real conda solves
are slower than pip/uv); as of 2026-10-24 it is `uv`.

- **Last scanned**: 2026-10-24. The 18 most recent successful full runs on `main` (2026-10-11 to
  2026-10-24, `workflow_runs` list, `run_started_at` to `updated_at`): 70-139 minutes, average
  102 (2026-07-25: 85-110, average 92). Two regimes: 70-93 minutes through the middle of 2026-10-17,
  125-139 minutes since. Per-job durations (the breakdown the July scan lacked), run 40055643200
  (125 min): `uv` 122, `real` 97, `conda-full` 56, `justme-test` 37, `cache` 37, `contract-uv-fail`
  28, `uv-dl-fallback` 27, `contract-uv` 19, Pages publish 2. For comparison, run 39032331726 (91
  min): `uv` 91, `conda-full` 73, `real` 60.
- **Findings**: the premise above changed. `conda-full` got faster (73 to 56), `real` grew from 60
  to 97 minutes (the gating scenarios added to it since 2026-10-11), and `uv` (91 to 122) now sets
  the wall-clock. Cause is accumulated scenarios on the `uv` lane (many non-gating rows build
  EXEs, download Miniconda or run Nuitka), not one change. No single fixable root cause found.
- **Going forward**: re-check the same 18-run sample and the per-job table each scan (`gh api
  repos/.../actions/runs/<id>/jobs`). A new `real`-lane step only costs wall-clock once `real`
  passes `uv`'s duration, so add heavy scenarios to the lane with the most headroom; the
  embed-version scenario (three builds) was added to `real` for that reason in the 2026-10-24
  scan. Flag if the average climbs above ~110 minutes outside a queueing spike, or if `uv`
  passes 150 minutes.

### pipreqs ecosystem status

- **Last scanned**: 2026-10-24.
- **Findings**: pipreqs (bndr/pipreqs) still stagnant/maintenance-only; PyPI's newest release is
  still 0.5.0 (uploaded 2024-02-18, `Requires-Python >=3.8.1,<3.13`), none since; still correctly
  pinned to 0.4.13 here (see "pipreqs pin rationale" above); `self.stub.pipreqs_version_fail`
  (Closed Backlog) confirms the warnfix safety net covers total pipreqs unavailability regardless
  of the exact failure mode.
- **Going forward**: check whether pipreqs has a new maintainer/release that changes the
  `<3.13` Requires-Python situation, or whether it's been removed from PyPI (extremely unlikely)
  -- revisit the internalization decision above if either happens.
- **Next-pin probe** (add to each scan going forward, see "Next-pin probe concept" below for the
  general idea this instantiates): under the CURRENT latest target Python (not an old ambient
  one -- this matters, see the concept note), run an unpinned `python -m pip install --dry-run
  pipreqs` and check whether the resolved version is still 0.4.13. If a newer version resolves
  cleanly, pipreqs's own `Requires-Python` ceiling has moved -- open a dedicated loop to
  re-evaluate the pin (do not bump it inline during a routine scan; re-pinning needs its own
  verification pass, mirroring how the original 0.4.13 pin was chosen). **Use pip, not uv, for this
  probe**: on 2026-10-24 `uv pip install --dry-run pipreqs` resolved 0.5.0 under both Python
  3.13.16 and 3.15.0b4 although its metadata excludes both, so uv cannot answer the question; pip
  under 3.15.0b4 resolved 0.4.13 (probe result: pin holds). `pip index versions pipreqs` is a valid
  shortcut only on a Python 3.13 or newer, where it hides 0.5.0 for the same reason.

### Embed version table (REQ-009 Tier 5, `tools/embed_pyver_check.py`)

- **Last scanned**: 2026-10-24.
- **Findings**: `EMBED_PYTHON_TABLE` now spans 3.10 through 3.15 (`LATEST_MINOR="3.15"`,
  `FLOOR_MINOR="3.10"`), pinned to patches 3.10.11 / 3.11.9 / 3.12.10 / 3.13.17 / 3.14.9 / 3.15.1.
  The SHA256 of each new or changed zip was recomputed on 2026-10-24 from a fresh direct download
  of python.org's `python-<patch>-embed-amd64.zip` (3.15 is new, 3.13 and 3.14 moved to newer
  patches; 3.10 to 3.12 are unchanged). The `"3.15"` entry's patch/sha256 must stay in sync with
  `HP_EMBED_LATEST_PATCH`/`HP_EMBED_LATEST_SHA256` in `run_setup.bat`; `tests/test_embed_tier.py`'s
  `BatchPythonConsistency` test enforces this on every CI run. `FLOOR_MINOR` stays 3.10 for now:
  python.org's schedule ends 3.10 on 2026-10-31, so advance the floor to 3.11 (and drop the 3.10
  entry) in the January scan, not before. **The swap path was not reachable before this scan**: the
  new `self.embed.version.*` rows (`tests/selfapps_embed_version.ps1`, real lane, gating) went red on
  all three first scenarios with the program under the newest minor and no WARN, because a chain
  with neither uv nor Miniconda reaches the embed tier before `~detect_python.py` has run (the
  conda.bat-not-found branch), so `PYSPEC` was empty and `runtime.txt` / `pyproject.toml` were
  ignored in exactly the case README REQ-009 names for this tier. The tier now runs the helper under
  its own fresh interpreter, and `embed_pyver_check.py` picks the newest table minor a range
  allows (it used to take the range's first number, so `>=3.10` swapped down to 3.10). **Green read**: run
  `40084822967` (PR #507 head `b3e034d`) has all four `self.embed.version.*` rows (`swap`, `floor`, `ceiling`,
  `range`) true on the `real` lane, read from the pre-harness artifact, with no red row on that lane.
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
