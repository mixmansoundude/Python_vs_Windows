# CLAUDE.md -- AI Assistant Guide for Python_vs_Windows

This file is the orientation document for AI assistants (Claude, Codex, Copilot, etc.)
working in this repository. It summarizes structure, workflows, and conventions.

**Do not duplicate content from these authoritative sources -- reference them instead:**
- **[README.md](./README.md)** -- Product requirements, Prime Directive specification, CI contract
- **[AGENTS.md](./AGENTS.md)** -- Agent iteration rules, scope policy, style rules, sanity checks
- **[CONTRIBUTING.md](./CONTRIBUTING.md)** -- Fork/branch/PR workflow and iteration priorities

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
run_setup.bat                  Main bootstrapper (self-contained, ~61 KB) -- the deliverable
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
  dynamic_tests.py             Python-side entry detection and version precedence tests
  test_*.py                    Python unit tests (13 files, see Testing section)

tools/
  apply_patch.py               Unified/legacy diff parser and applier (used by inline_model_fix)
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

.github/workflows/
  batch-check.yml              Main CI pipeline (3-lane Windows matrix, ~40 KB)
  codeql.yml                   CodeQL security analysis
  workflow-lint.yml            YAML/workflow lint (actionlint + PyYAML)
  pr-automerge.yml             Auto-merge handler for all non-draft same-repo PRs (blocks on 'no-automerge' label)

scripts/
  poll_public_diag.ps1         Diagnostics polling helper
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

Run these before every commit. README.md changes do not affect them but run as a baseline.

```bash
# Python syntax and name errors
python -m compileall -q .
python -m pyflakes .

# Delimiter balance in the main bootstrapper
python tools/check_delimiters.py run_setup.bat

# YAML lint (if workflow files changed)
python -m yamllint .github/workflows/
```

For modified PowerShell files, see **AGENTS.md** for the AST-based syntax validation method
(`pwsh -c "[System.Management.Automation.Language.Parser]::ParseFile(...)"`) since PSGallery
is blocked by proxy on CI runners.

For actionlint (workflow files), see **AGENTS.md** for the download/install method.

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
   the batch file under `:define_helper_payloads`. To refresh a helper:
   ```python
   import base64, pathlib
   print(base64.b64encode(pathlib.Path('path/to/helper.py').read_bytes()).decode('ascii'))
   ```
   Paste output into the matching `set "HP_*"=...` line.

   Current embedded payloads (in addition to legacy HP_FAST_CHECK):
   - `HP_DEP_CHECK` -- decodes to `~dep_check.py`; compares pipreqs output against
     `~environment.lock.txt` and exits 0 (skip) or 1 (install needed).
   - `HP_ENV_STATE` -- decodes to `~env_state.py`; reads/writes `~env.state.json` to
     cache conda env validity across runs.

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

## Edit Detection Sprint (Loops 1-3) -- SHIPPED

All three loops are complete and live in `run_setup.bat`.

### Loop 1 -- PyInstaller build artifact cleanup

After a successful PyInstaller build, `run_setup.bat` now:
- Deletes the `build\%ENVNAME%\` directory.
- Deletes `%ENVNAME%.spec` **unless** a spec file pre-existed (guarded by
  `HP_SPEC_PREEXIST` set before PyInstaller runs).
- Logs: `[INFO] PyInstaller build artifacts cleaned up.`

### Loop 2 -- Dependency skip (HP_DEP_CHECK / ~dep_check.py)

After `pipreqs` generates `requirements.auto.txt`, `run_setup.bat` compares the
output against `~environment.lock.txt` (written on first successful conda install).
If every package listed by pipreqs is already present in the lock file, conda install
is skipped entirely.
- Log line: `Dep-check: all pipreqs packages satisfied in lock; skipping conda install.`
- The lock file is written via `conda list --export` gated on errorlevel=0 AND
  non-empty output.
- Skip is conservative: if package name normalization is uncertain, falls through to
  `conda install`.

### Loop 3 -- Env-state fast path (HP_ENV_STATE / ~env_state.py)

After a successful bootstrap, `run_setup.bat` writes `~env.state.json`:
```json
{
  "schema": 1,
  "env_name": "...",
  "env_path": "...",
  "python_version": "...",
  "req_hash": "...",
  "runtime_hash": "...",
  "lock_hash": "..."
}
```
On the next run, if state is valid and `python.exe` is present in the env, `conda create`
is skipped entirely.
- Log line: `Env-state fast path: reusing conda env <ENVNAME>.`
- Schema field = 1. If schema is unknown or missing, treated as stale (not error).
- State file is not backwards compatible before it was introduced -- first run after
  upgrade does a full rebuild (expected behavior).

### Runtime artifacts written by the bootstrapper

| File | When written |
|------|-------------|
| `~bootstrap.status.json` | Every run (state, exitCode, pyFiles) |
| `~setup.log` | Every run (probe errors, bootstrap path) |
| `~environment.lock.txt` | After successful conda install (errorlevel=0, non-empty) |
| `~env.state.json` | After successful full bootstrap |

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

---

## NDJSON Surface (current)

CI-artifacts NDJSON (from selfapps tests, 23 rows in conda-full lane):

```
self.harness.started, self.bootstrap.state, self.empty_repo.msg,
self.env.smoke.conda, self.env.smoke.run, self.exe.build, self.exe.run,
self.fastpath,
reqspec.translate.{gte,eq,compat,gt,neq,lte}, reqspec.conda.dryrun,
reqspec.conda.channelpin, reqspec.conda.dryrun.failcase,
reqspec.install.import, reqspec.ingest.translate,
reqspec.ingest.conda.dryrun, reqspec.ingest.install.import,
self.depcheck.install, self.depcheck.skip
```

Test-logs NDJSON (from harness/selftest, additional rows):

```
file.hash, bootstrap.state, bootstrap.exit, emit.extract (x many),
batch.delayed.off, batch.delayed.enable_absent, batch.bang.scan,
conda.channels, pipreqs.flags, pyi.onefile, log.rotate, tilde.naming,
visa.detect, emit.helpers, env.state.write, dep.check.parse_lock,
dp.compat, prep.multi.constraint, batch.paren.balance, env.foldername,
conda.path,
self.stub.fastpath, self.stub.rebuild, self.stub.state_skip
```

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
| `test_entry_single.py` | Single Python file bootstrap (Windows only, skipped on Linux) |
| `test_inline_model_fix_decision.py` | Model quick-fix decision logic |
| `test_ndjson_fail_list.py` | Fail list extraction from NDJSON artifacts |
| `test_poll_public_diag_logging.py` | Diagnostics polling and logging |
| `test_ps_colon_scan.py` | PowerShell scoped variable detection ($var:) |
| `test_check_delimiters_import.py` | Delimiter checker import guard |
| `test_publish_index_regex.py` | Regex patterns in diagnostics publisher |
| `test_sanitize_iterate_payload.py` | NDJSON redaction and deduplication |

### Static harness (Windows-only, requires PowerShell)
```batch
run_tests.bat
```
Runs `tests/harness.ps1` which validates NDJSON output structure and counts pass/fail.

### Dynamic tests (run automatically by CI)
Triggered when `~bootstrap.status.json` reports `state=ok`. Runs `tests/dynamic_tests.bat`
or `tests/dynamic_tests.py` if present. See README.md §Dynamic test rules.

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
  `pandas.read_excel` needing `openpyxl`. See README.md §Dependency strategy.
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
truth. See README.md §Dependency strategy for the full explanation including the PIL/pillow
and cv2/opencv mapping limitation.

---

## Iteration Loop Rules

See **AGENTS.md** §Iteration Contract for the full policy. Key points:

1. Freeze scope for the current loop -- new requirements go to backlog.
2. Fix CI first (pipeline/config), then test errors, then test assertions, then product code.
3. After going green, verify no false positives.
4. Implement exactly ONE missing feature slice per loop.
5. Add exactly ONE missing test per loop.

---

## Active Backlog

Items deferred to future loops:

- **Runtime import-error retry loop**: run EXE, catch ModuleNotFoundError, extract module
  name, reinstall, retry with cap.
- **EXE skip on hard Python import errors**: deferred -- needs sandbox work.

## Closed Backlog

Items completed and shipped:

- **Conda `justme` fallback**: if AllUsers Miniconda install fails, retry with
  `/InstallationType=JustMe`. CLOSED by feat: retry Miniconda install with JustMe if AllUsers fails.
- **Diag index clickable links for stub/depcheck setup logs**: add Quick Links on the
  diagnostics index page for ~selftest_stub/~setup.log and ~selftest_depcheck/~setup.log.
  CLOSED by diag: add clickable preview links for stub and depcheck setup logs.
- **Auto-merge on PR creation**: ensure auto-merge is enabled when a PR is opened after
  commits are pushed (pull_request:opened trigger). CLOSED by ci: enable auto-merge when
  PR is opened, not just on push.
