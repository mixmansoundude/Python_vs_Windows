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

**AGENT DIRECTIVE -- keep the knowledge docs current.** When a change teaches or invalidates
a lesson, update the relevant doc in the SAME commit, editing existing entries (not only
appending):
- `docs/agent-interconnect.md` -- cross-component dependencies ("touch A, must understand B").
- `docs/agent-lessons-learned.md` -- standalone hazards, rules, budgets, procedures. Most are
  batch/CMD syntax quirks and Windows shell gotchas; record those here.
- `docs/agent-ndjson.md` -- the NDJSON row registry (add/rename/remove rows here too).

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
     not-found/error, 2 on malformed TOML. Used by the layered dep resolution block.
   - `HP_PREP_REQUIREMENTS` -- decodes to `~prep_requirements.py`; applies heuristic
     dep-augmentation rules (REQ-005.8); strips pip extras (`[excel]`) before name lookup.

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
| `~environment.lock.txt` | conda mode: after conda list --export; uv mode: copy of ~dependency_installed.txt |
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

**pipreqs is pinned to 0.4.13, NOT 0.5.0.** This is deliberate and load-bearing:

- pipreqs 0.5.0 (the latest release) added Jupyter notebook scanning, which hard-pins `ipython==8.12.3`
  (the last ipython supporting Python 3.8). ipython 8.12.3 does not support Python 3.13+, so 0.5.0's
  metadata declares `Requires-Python >=3.8.1,<3.13`.
- The bootstrapper always targets the latest conda-forge Python (currently 3.14+). On that Python, pip
  refuses to install 0.5.0 (version cap), so pipreqs would be lost entirely and every run would fall back
  to warnfix.
- pipreqs 0.4.13 has `Requires-Python >=3.7` (no upper cap), deps only `docopt`+`yarg`, supports the same
  `--mode compat` / `--force` / `--savepath` flags, uses only stable stdlib (ast-based scan), and runs on
  Python 3.14. It restores pipreqs as the primary discovery tool.
- **Do NOT "upgrade" the pin back to 0.5.0** -- it reintroduces the `<3.13` cap and silently disables
  pipreqs on modern Python. The only feature lost by 0.4.13 is `.ipynb` scanning, which was already
  non-functional on latest Python (0.5.0 cannot run there).

The `pipreqs.flags` CI gate validates the invocation flags, not the version, so the pin is free to change.
The setup log line `[INFO] pipreqs <ver> installed successfully` confirms pipreqs is active on a given run.

## Dependency Discovery: pipreqs invocation (bootstrap determinism)

**pipreqs is invoked via `python -m pipreqs.pipreqs`, NOT the console script (`pipreqs` command).**
This is an intentional bootstrap execution strategy, not a workaround for pipreqs limitations.

**Constraints driving this choice:**
- Windows batch bootstrap never depends on shell state (PATH, activation, environment variables)
- Bootstrap runs immediately after environment creation in the same shell session
- Console scripts require PATH correctness and activation to persist--neither is guaranteed
- Bootstrap reliability > API purity in this system class

**Why internal module invocation is safe here:**
- pipreqs is pinned to 0.4.13 permanently (no automatic upgrades)
- Version freeze makes internal module structure (`pipreqs/pipreqs.py`) stable by contract
- Internal coupling is a low-risk controlled assumption due to the pinned dependency version

**Comparison of approaches:**
| Approach | Reliability in Bootstrap | Architecture | Scope |
|----------|--------------------------|--------------|-------|
| `pipreqs` (console script) | WARN Fragile (PATH dependent) | OK Official API | General use |
| `python -m pipreqs.pipreqs` | OK Deterministic (no PATH) | WARN Internal mechanism | Bootstrap only |

See `run_setup.bat` lines ~813-820 for the invocation comment and rationale. This is a **deterministic execution pattern required for bootstrap reliability**, not a sign of fragility or a temporary workaround.

## Dependency Discovery Fallback: warnfix (secondary safety net)

If pipreqs install ever fails (e.g., a future Python drops a stdlib API pipreqs needs, or docopt/yarg
cannot build), the bootstrapper still falls back to `warnfix`:
1. PyInstaller builds the EXE (static analysis finds many imports)
2. Read the `warn` file (list of modules PyInstaller couldn't find)
3. Parse warn file via `parse_warn.py`: extract top-level, delayed, and conditional imports
4. Filter out platform-specific modules (posix, fcntl, grp, pwd, resource, _scproxy, _posixsubprocess, collections.abc, _frozen_importlib_external -- all POSIX/Unix-only, safe to ignore on Windows)
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

This system prioritizes **deterministic execution during bootstrap** over packaging purity. These principles guide decisions about tool invocation, dependency handling, and error handling in `run_setup.bat`:

1. **Bootstrap reliability > API correctness.** If a feature depends on "maybe PATH is set" or "activation might work," it is invalid for bootstrap paths. Determinism is non-negotiable.

2. **Never depend on console scripts during bootstrap.** Console scripts (`pipreqs`, `pytest`, etc.) are forbidden in bootstrap logic because they require: Scripts/ on PATH, activation state correctness, OS-level shim resolution. Instead: use explicit interpreter paths or direct Python APIs.

3. **All execution must be interpreter-anchored.** Every tool invocation roots in an explicit Python executable path (`%HP_PY%` or `%CONDA_PREFIX%\python.exe`), never relying on PATH or activation to supply the correct interpreter.

4. **Pinned dependencies are assumed stable.** For version-frozen tools (pipreqs 0.4.13), internal behavior and module structure may be relied upon as stable by contract. Internal coupling is acceptable when version is locked.

5. **Bootstrap must fail fast and explicitly.** If bootstrap cannot guarantee interpreter, environment, or dependency availability, it fails loudly and early. No silent fallbacks unless explicitly logged.

6. **Non-obvious decisions must be self-documenting.** If bootstrap does something like `python -m pipreqs.pipreqs` instead of `pipreqs`, it must include a comment explaining why PATH/CLI/activation was not used. Future maintainers must not be tempted to "fix" it incorrectly.

**Application:** These principles validate the pipreqs invocation strategy, justify the dep-check cache optimization, and guide all future bootstrap-critical decisions. See pipreqs invocation section above for a concrete example.

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

Items deferred to future loops:

- **Provider cascade on warnfix hard failure (REQ-009 / REQ-005.10)**: Currently a warnfix hard failure within a provider (uv, conda, venv) logs and exits rather than cascading to the next REQ-009 provider. Intended direction: exhausting repair within a provider triggers fallback to the next tier and re-attempts from the dependency installation phase. Requires deciding the cascade trigger condition (max repair attempts, specific error classes, or explicit unresolvable signal) and updating the retry loop in `run_setup.bat` accordingly.

- **uv DL fallback CI coverage**: `self.dl.uv.fallback` (uv download fallback path -- HP_TEST_UV_DL_FALLBACK=1) has no active CI lane. justme-test now uses HP_TEST_FORCE_UV_FAIL=1 (skips uv entirely before any download) so the secondary uv URL is never exercised in CI. Needs a dedicated non-gating lane that sets HP_TEST_UV_DL_FALLBACK=1 without HP_FORCE_CONDA_ONLY=1 and without HP_TEST_NOT_ELEVATED=1, so uv download path is reached and the fallback URL is tried.

- **Miniconda probe runs even when uv succeeds**: in a normal uv run the log shows a
  "Miniconda probe" line reporting a ~95 MB download even though nothing conda-related should
  be touched once the uv lane succeeds. Investigate where the probe fires and consider
  deferring it to immediately before an actual conda download attempt, so uv-only runs neither
  perform nor log conda work. (Confirm whether the 95 MB is actually downloaded or just a
  size estimate printed.)

- **User-code exit-code semantics**: verify the exit code read after running the user's code
  is purely the user program's (no bootstrapper logic interleaved). If so, a non-zero exit is
  very likely outside bootstrapper control; confirm such a case routes to warnfix gracefully
  rather than being reported as a bootstrapper failure. Document the conclusion.

- **Iterate-gate pre-flight snapshot contradiction**: the pre-flight snapshot is described as
  "expected has_failures:true while NDJSONs are missing" but the emitted JSON shows
  `{"has_failures":false,...}`. Reconcile the message vs. the emitted verdict (the intent is
  that missing `tests/~test-results.ndjson` / `ci_test_results.ndjson` are treated as
  failures so empty streams never pass).

- **Persisted run-page warnings**: review the last several CI runs for warnings that recur
  across runs (Actions "Annotations"/warnings), and triage each as fix-or-accept.

- **Progress messaging for >5s steps**: audit steps that take more than ~5 seconds (installer
  creation, downloads, env build) and ensure each emits a user-facing "starting X / installing
  X" line before the long operation, so a slow step never looks like a hang.

- **CI-side NDJSON row registry check**: consider building the `docs/agent-ndjson.md` row
  audit into CI (it exists today so agents can see which rows are missing). Likely still a
  manual-sync confirmation step, since fully automated discovery can miss flag-gated rows.

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

- **Spurious "add requirements.txt" WARN when one already exists**: gated the WARN (lines
  900-902 of `run_setup.bat`) on `not defined DEP_SOURCE`; it now fires only when no
  user-provided dep source was found (no requirements.txt / pyproject / PEP 723). When the
  user has explicit deps, pipreqs runs as an augmentation pass and the WARN is suppressed with
  a `[TRACE]` log. Also fixed the silent regression where `DEP_SOURCE=pyproject` was being
  overwritten to `pipreqs` (now `DEP_SOURCE` is only set to `pipreqs` when it was unset).
  Confirmed that a user-provided `requirements.txt` is never overwritten by
  `requirements.auto.txt` (guarded by `if not exist "%REQ%"` at line 1058).
  Covered by `self.pipreqs.warn.gated` (selftest.ps1, conda-retry scenario) and
  `batch.req005.warn_gate` (harness.ps1 static check). CLOSED by this PR.

- **uv floor-vs-pin: loose `>=`/`>` constraints now forward the range to uv**: previously
  `run_setup.bat` regex-extracted only the lower-bound `X.Y` from PYSPEC and passed a concrete
  `uv venv --python X.Y`, so `requires-python = ">=3.11"` pinned exactly 3.11. Confirmed uv's
  `--python` accepts PEP 440 ranges (`>=3.12,<3.13`) and prefers newer versions, so the
  translation now emits two values: `HP_UV_PY_REQ` (forwarded to uv -- the full range for
  loose forms, bare `X.Y` for exact `=`/`==` pins) and `HP_UV_PY_DISP` (operator-free log
  string, since `:log` echoes unquoted). The range (with `<`/`>`) flows only through the
  double-quoted `--python "%HP_UV_PY_REQ%"` argument. Conda path untouched (PYSPEC unchanged).
  Covered by new rows `self.contract.uv.pyver.range` and `self.contract.uv.pyver.exactpin`
  (contract-uv lane). CLOSED by this PR.

- **pandas[excel] extras syntax not triggering heuristic**: `names_lower` was built without
  stripping pip extras, so `pandas[excel]` was stored as `"pandas[excel]"` and `'pandas' in
  names_lower` returned False. Fixed by applying `re.sub(r"\[.*?\]", "")` before the lookup.
  Covered by `test_heuristics.py::TestPandas::test_pandas_extras_triggers`. CLOSED by this PR.

- **uv-first: skip Miniconda download when uv can provide Python**: Moved uv acquisition
  before the Miniconda block. After acquiring uv, runs `~detect_python.py` via
  `uv run --no-project python` to detect PYSPEC without needing Miniconda base Python.
  Sets `HP_UV_PROVIDING_PYTHON=1` on success; all Miniconda-dependent guards check this
  flag. Miniconda is still downloaded when uv is unavailable or HP_FORCE_CONDA_ONLY=1.
  Verified by `self.uv.first.miniconda.skip` NDJSON row (contract-uv lane). CLOSED by this PR.

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
  parse-time expansion fix). HP_TEST_CONDA_DL_FALLBACK for justme-test CI coverage.
  HP_TEST_UV_DL_FALLBACK is implemented but has no active CI lane (see Active Backlog).
  CLOSED by this PR (uv DL fallback coverage deferred).
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
