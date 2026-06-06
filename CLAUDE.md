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
  selfapps_isolation.ps1       REQ-010/REQ-011 behavioral tests (unconditional, HP_CI_SKIP_ENV=1)
  dynamic_tests.py             Python-side entry detection and version precedence tests
  test_*.py                    Python unit tests (14 files, see Testing section)

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
   - `HP_PYPROJ_DEPS` -- decodes to `~pyproj_deps.py`; parses pyproject.toml
     `[project].dependencies` and writes one dep per line; exit 0 on success, 1 on
     not-found/error. Used by the layered dep resolution block (step 2 of 3).

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

### CI Pipeline Architecture (key facts for debugging)

**NDJSON files and who owns them:**
- `tests/~test-results.ndjson` -- written by every `selfapps_*.ps1` test script during the
  CI run. The selfapps scripts APPEND rows to this file. `harness.ps1` then DELETES and
  REWRITES it from `ci_test_results.ndjson` (the root-level aggregator). Do not confuse
  the mid-run append file with the final harness output.
- `ci_test_results.ndjson` -- root-level aggregator written by selfapps scripts and read
  by `harness.ps1`. This is the authoritative input for verdict computation.
- Rows in `ci_test_results.ndjson` but not in `tests/~test-results.ndjson` after the run
  means harness.ps1 ran after the selfapps scripts rewrote the file.

**CI job step ordering (within each lane job):**
1. Selfapps scripts run (each appends rows to both NDJSON files).
2. Artifacts are uploaded (NDJSON snapshots, logs).
3. `run_tests.bat` runs `tests/harness.ps1` (verdict -- reads `ci_test_results.ndjson`,
   rewrites `tests/~test-results.ndjson`, emits pass/fail).
4. `tests/selftest.ps1` runs the bootstrapper self-tests (empty repo + stub).

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

**Missing rows in NDJSON:**
- A row absent from the diag site means the test script either was not reached, threw
  before the `Write-NdjsonRow` call, or the lane skipped that selfapps file.
- Rows gated by `pyFileCount` (e.g. `entry.single.direct`) will be absent whenever the
  bootstrapper repo itself is the test target (pyFiles != 1 in the main repo).
- Check the CI step log for `[INFO] ... skipped:` messages before assuming a test regressed.

---

## NDJSON Surface (current)

The diag site is the source of truth for row counts. Listed below are known rows by lane.

CI-artifacts NDJSON (from selfapps tests, conda-full lane):

```
self.harness.started, self.bootstrap.state, self.empty_repo.msg,
self.empty_repo.no_spurious_warn,
self.env.smoke.conda, self.env.smoke.run, self.env.smoke.uv,
self.exe.build, self.exe.run,
self.exe.smokerun.xfail, self.exe.smokerun.exedata.xfail, self.exe.smokerun.exedyn.xfail,
self.fastpath,
self.entry.entry1, self.entry.entryA, self.entry.entryB, self.entry.entryC, self.entry.entryD,
self.entry.helper.invoke.absent, self.entry.results, self.entry.spaced-path,
self.entry.req011.crossdir, self.entry.req011.sameDir, self.isolation.req010.pythonpath,
reqspec.translate.{gte,eq,compat,gt,neq,lte}, reqspec.conda.dryrun,
reqspec.conda.channelpin, reqspec.conda.dryrun.failcase,
reqspec.conda.channelpin.req006, reqspec.conda.dryrun.req006,
reqspec.gte.explicit,
reqspec.install.import, reqspec.ingest.translate,
reqspec.ingest.conda.dryrun, reqspec.ingest.install.import,
self.depcheck.install, self.depcheck.skip,
self.parse_warn.table,
self.exe.warnfix.install, self.exe.warnfix.pass, self.exe.warnfix.xfail,
self.exe.warnfix.real, self.exe.warnfix.real_warnfix,
self.exe.warnfix.real_warnfix_delayed,
self.parse_warn.table.v6, self.parse_warn.pytest,
self.heuristics.pytest,
self.pytest.unit,
self.runtime.writeback,
self.pandas.openpyxl.install, self.pandas.openpyxl.import,
pandas_excel.translate, pandas_excel.conda.install, pandas_excel.conda.install.req006,
pandas_excel.runtime,
pyvisa.detect, pyvisa.nivisa.branch, pyvisa.nivisa.outcome, pyvisa.nivisa.reason, pyvisa.nivisa.disabled,
pyproject.precedence.detect, pyproject.precedence.writeback,
pyproject.dep.detect,
self.prime.bootstrap, self.prime.run, self.prime.spaced-path,
self.prime.exe.build, self.prime.exe.run,
self.ux.connectivity.offline.n, self.ux.connectivity.prompt.shown,
self.ux.connectivity.offline.uv.skip, self.ux.connectivity.offline.conda.skip,
self.ux.connectivity.online, self.ux.connectivity.retry,
self.ux.system.gate.n, self.ux.system.gate.prompt, self.ux.system.gate.real,
self.ux.gitignore.merge, self.ux.gitignore.preserve, self.ux.gitignore.idem,
self.ux.gitattributes.merge, self.ux.gitattributes.idem,
self.ux.postflight,
self.venv.fallback, self.entry.override
```

justme-test lane rows (subset, flag-triggered):

```
conda.install.justme
```

dl-fallback lane rows (HP_TEST_CONDA_DL_FALLBACK=1, HP_TEST_UV_DL_FALLBACK=1, justme-test):

```
self.dl.conda.fallback, self.dl.uv.fallback
```

conda-full lane rows (HP_TEST_CONDA_UPDATE=1, flag-triggered -- NOT currently wired to CI;
conda base update is implemented in run_setup.bat but HP_TEST_CONDA_UPDATE injection was
removed because it causes conda solver corruption in shared CI runners):

```
self.conda.base.update  (test file: tests/selfapps_conda_update.ps1 -- not run in CI)
```

contract-uv lane rows (flag-triggered):

```
self.contract.uv
self.contract.uv.pyver
```

contract-uv-fail lane rows (HP_TEST_UV_FAIL=1, flag-triggered):

```
self.contract.uv.fail
```

Dynamic-tests NDJSON (from dynamic_tests.py, selftest artifact `dynamic/` subdirectory):

```
pr.to_conda (x many), pr.pandas.openpyxl, pr.pandas.xlsxwriter,
pr.requests.certifi, pr.sqlalchemy.pymysql, pr.matplotlib.tk,
pr.cryptography.cffi, pr.pycryptodome.cffi,
app.visa.detect, app.pyserial.detect,
dp.pep440 (x many), dp.detect.runtime, dp.detect.pyproject,
entry.select.single, entry.select.main_vs_app, entry.select.common_vs_generic
```

Test-logs NDJSON (from harness/selftest, additional rows):

```
file.hash, bootstrap.state, bootstrap.exit, emit.extract (x many),
batch.delayed.off, batch.delayed.enable_absent, batch.bang.scan,
conda.channels, pipreqs.flags, pyi.onefile, log.rotate, tilde.naming,
visa.detect, emit.helpers, env.state.write, dep.check.parse_lock,
dp.compat, prep.multi.constraint, batch.paren.balance, env.foldername,
conda.path,
version.metadata,
host.env.os, host.env.ps, host.env.python,
batch.req009.venv_unconditional, batch.req009.provider_logs,
batch.req010.isolation, batch.req011.dircheck,
batch.req002.findentry_cli, batch.req002.findentry_run, batch.req002.entry_log, batch.req002.findentry_payload,
batch.ux.pause.gated,
batch.dep.diff.trace,
self.bootstrap.state, self.empty_repo.msg, self.empty_repo.no_spurious_warn,
self.harness.started,
self.stub.fastpath, self.stub.rebuild, self.stub.state_skip,
self.stub.conda_retry, self.stub.conda_perpkg, self.stub.pip_warn,
self.dep.diff.trace,
self.warn.onedrive, self.warn.longpath, self.warn.path_negative,
self.guardrail.g1, self.guardrail.g2, self.guardrail.g3,
self.pep723.valid, self.pep723.malformed, self.pep723.pyproject.override,
self.corrupt.conda.detect,
self.corrupt.conda.heal.decline,
self.corrupt.uv.detect
```

selfapps-ux-hardening NDJSON rows (selfapps_ux_hardening.ps1, non-conda-full lanes):

```
self.ux.gitignore.merge, self.ux.gitignore.preserve, self.ux.gitignore.idem,
self.ux.gitattributes.merge, self.ux.gitattributes.idem,
self.ux.postflight,
self.ux.connectivity.offline.n, self.ux.connectivity.prompt.shown,
self.ux.connectivity.offline.uv.skip, self.ux.connectivity.offline.conda.skip,
self.ux.connectivity.online, self.ux.connectivity.retry,
self.ux.system.gate.n, self.ux.system.gate.prompt, self.ux.system.gate.real,
self.venv.fallback, self.entry.override
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
| `test_heuristics.py` | Heuristic dep-augmentation rules (REQ-005: all 6 rules, kill-switch, idempotency) |
| `test_parse_warn.py` | PyInstaller warn-file translation table (REQ-007: 5.x and 6.x formats, all TRANSLATIONS entries) |
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

(none)

## Known Findings (diagnosed, no action warranted)

- **NI-VISA real install fails fast in CI (`installer_rc=-125083`) -- environmental, NOT a repo/test/CI-code
  bug.** Diagnosed via the REQ-008 `[VISA]` diagnostic logging (download method / file size / PE check /
  installer exit code, surfaced in the `pyvisa.nivisa.reason` NDJSON details). On the conda-full lane the
  installer downloads cleanly via curl (~6.77 MB, `PE_OK` -- a genuine NI-VISA 21.5 online bootstrapper),
  then runs and exits `-125083` in ~10s. Because the install uses `start /wait`, the post-check budget never
  kills it; the failure is the online bootstrapper being unable to complete an unattended install on the
  runner (network policy to NI's package feed and/or no interactive/elevation path). Consequences:
  `[VISA] install_success` is **unreachable in CI by design**; the validated behavior is
  detect -> attempt -> log rc -> continue gracefully; **no dedicated real-install lane is warranted** (there
  is no slow-but-succeeding install to wait out). `HP_NIVISA_WAIT_SECS` remains a useful knob only for the
  narrow detached-child registry-propagation case.
  - **NOT YET CONFIRMED on a real machine.** This conclusion rests solely on CI evidence. It still needs a
    real user run (normal internet, interactive/admin session) to confirm the same valid installer succeeds
    off-CI (expected ~30-45 min per the maintainer's prior experience). Until then, treat the
    "environmental" classification as strongly-supported-but-provisional.

## Closed Backlog

Items completed and shipped:

- **Drag-and-drop message empty filename**: `:determine_entry` printed
  `*** Using drag-and-drop file: ` with no name (and set `HP_ENTRY` empty on the first
  call) because `%MAIN_FILE%` was expanded at parse time inside the parenthesized
  `if exist "%~1" (...)` block, before `set "MAIN_FILE=%~1"` ran. Fixed by using the `%~1`
  parameter directly for both `HP_ENTRY` and the message. Guarded by the tightened
  `self.entry.override` assertion (drag line must include the filename). CLOSED by this PR.

- **Warn-file driven missing-import install**: after PyInstaller build, read the warn file,
  extract flagged missing modules, apply the import-to-conda translation table, install via
  conda, and rebuild once. Supersedes the earlier runtime retry-loop design. CLOSED by
  (warn-file feature PR).

- **Conda `justme` fallback**: if AllUsers Miniconda install fails, retry with
  `/InstallationType=JustMe`. CLOSED by feat: retry Miniconda install with JustMe if AllUsers fails.
- **Diag index clickable links for stub/depcheck setup logs**: add Quick Links on the
  diagnostics index page for ~selftest_stub/~setup.log and ~selftest_depcheck/~setup.log.
  CLOSED by diag: add clickable preview links for stub and depcheck setup logs.
- **Auto-merge on PR creation**: ensure auto-merge is enabled when a PR is opened after
  commits are pushed (pull_request:opened trigger). CLOSED by ci: enable auto-merge when
  PR is opened, not just on push.
- **Python version detection Tier 2 (pyproject.toml) CI coverage**: end-to-end CI
  coverage of the pyproject.toml `requires-python` parse path. CLOSED by #192.
- **parse_warn v3 (delayed/conditional imports)**: Extend HP_PARSE_WARN to process
  `delayed` (function-scoped) and `conditional` (platform-guarded) PyInstaller 6.x imports
  in addition to `top-level`; skip `optional`-only entries. Added `real_warnfix_delayed`
  CI scenario for branch coverage. CLOSED by #232.
- **Fallback URL handling**: Miniconda and uv downloads now try a secondary URL if the
  primary fails. download logic extracted to :download_miniconda_exe subroutine (CMD
  parse-time expansion fix). HP_TEST_CONDA_DL_FALLBACK / HP_TEST_UV_DL_FALLBACK flags
  for CI coverage in justme-test lane. CLOSED by this PR.
- **Conda base periodic update**: conda update -n base runs at :after_env_mode_selection
  when HP_ENV_MODE==conda; skipped on first install (timestamp seeded in ~conda.lastupdate);
  timer threshold 30 days. HP_TEST_CONDA_UPDATE=1 CI injection was removed because
  conda update -n base --all upgrades conda to a broken solver version that cascades
  failures across the rest of the conda-full job. Feature is live in production code;
  CI coverage deferred. CLOSED by this PR.
- **Python version detection Tier 3 write-back**: Removed `python<3.13` hard-coded cap so
  conda picks the latest available Python (no-hard-coded fallback per REQ-004). After env
  creation, bootstrapper writes runtime.txt in `python-X.Y.Z` format and logs
  `[INFO] runtime.txt written: python-X.Y.Z`. Write-back guarded by `HP_RUNTIME_TXT_PREEXIST`
  so Tier 1 files (pre-existing runtime.txt) are never overwritten. Silent WARN on write
  failure (read-only filesystem). CLOSED by this PR.
- **REQ-004 uv Python version forwarding (Tiers 1-2)**: When PYSPEC is set from runtime.txt
  (Tier 1) or pyproject.toml (Tier 2), the detected Python version is now forwarded to
  `uv venv` via `--python X.Y`. PYSPEC is parsed by inline PowerShell regex to extract the
  lower-bound version from all forms (python=X.Y, python==X.Y, python>=X.Y, python>X.Y).
  Log line: `[INFO] uv: creating venv at .uv_env with Python X.Y`. Covered by new NDJSON
  row `self.contract.uv.pyver` (contract-uv lane). CLOSED by this PR.
