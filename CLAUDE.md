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
   - `HP_COLLECT_SUBMODULES` -- decodes to `~collect_submodules.py`; emits pre-build
     `--collect-submodules=PKG` flags for curated packages (sklearn, matplotlib, scipy,
     plotly) that load submodules dynamically (the warn file is silent about them).
     Double-gated: a flag is emitted only when the package is BOTH imported by the user's
     project source AND importable in the build interpreter, so a fat global env never
     bloats a lean app's EXE. Canonical source `tools/collect_submodules.py`; PayloadSync
     in `tests/test_collect_submodules.py` asserts byte-equality of the embedded base64.
   - `HP_HIDDEN_IMPORT_SCAN` -- decodes to `~hidden_import_scan.py`; for the Slice 2
     `--hidden-import` auto-recovery loop (`:hidden_import_recover` in run_setup.bat). Reads a
     frozen EXE's stderr and emits the next hidden-import target ONLY when stderr shows
     `ModuleNotFoundError: No module named 'X'` AND X is installed in the build interpreter --
     so a user typo or `ImportError: cannot import name` causes ZERO rebuilds. Bounded to 3
     rebuilds (helper tried-list + iter cap). Canonical source `tools/hidden_import_scan.py`;
     PayloadSync in `tests/test_hidden_import_scan.py`.

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

Items deferred to future loops. This list is for genuine future work -- a decision already made,
a fact confirmed with no action needed, or a recurring/periodic check belongs in
"Known Findings", `docs/agent-lessons-learned.md`, or "Periodic Maintenance Checks" below instead
(see those sections' own scope notes).

- **Provider symmetry: no standalone Python-download tier**: confirmed gap in the REQ-009
  provider cascade (uv -> conda -> venv -> system). uv and conda both self-acquire a full Python
  interpreter (uv's managed CPython, conda's bundled Miniconda Python); venv and system
  (`:resolve_system_python`) both require an *ambient* interpreter already on the host and have
  no download path of their own. If uv is unreachable, conda create/install fails, and no
  ambient `python`/`py` launcher exists, the bootstrap has no remaining way to acquire a Python
  interpreter and falls through to `:die`. A future tier could target the official
  python.org embeddable zip (`python-X.Y.Z-embed-amd64.zip`), verified by checksum, extracted to
  a local/isolated directory, treated like an ambient interpreter, with pip bootstrapped via
  `get-pip.py` if needed to feed warnfix. This is a substantial feature (new tier, checksum
  verification, new fallback-ladder wiring, new tests) -- backlog for a dedicated future round,
  not attempted piecemeal.

- **No proactive disk-space check (2026-07 iteration-pass finding)**: confirmed via code search
  -- the only disk-space-related output is the post-flight "SAFE TO DELETE to reclaim disk
  space" hint; there is no pre-flight free-space check before Miniconda download/install or
  conda env creation (which together can require several hundred MB to a few GB depending on
  packages). A beginner on a low-spec/older machine who runs out of space mid-bootstrap sees
  whatever low-level error curl/conda/pip happens to surface for "no space left on device"
  rather than a clear, early, plain-language message. Lower urgency than the concurrent-instance
  finding above -- existing `[ERROR]`/`[WARN]` logging conventions mean the user isn't left with
  zero explanation, just a less specifically-tailored one -- but worth a future round: a cheap
  `fsutil volume diskfree` (or PowerShell `Get-PSDrive`) check before the first large download,
  with a generous threshold and a friendly early abort/warning rather than a failure deep inside
  a conda solver or pip install.

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

- **Last scanned**: 2026-07-04 (`batch-check.yml:48` audit).
- **Findings**: only `real` and `conda-full` gate PR merges; `cache`, `justme-test`, `uv`,
  `contract-uv`, `contract-uv-fail`, `uv-dl-fallback` are deliberately non-gating (see AGENTS.md
  policy and this file's Closed-Backlog history for why each was made so) -- not a bug.
- **Going forward**: `uv` and `justme-test` are the two most mature/stable of the six non-gating
  lanes -- re-assess each scan whether either has soaked long enough (no flakiness, no
  lane-specific caveats left) to graduate to gating. Leave `contract-uv`/`contract-uv-fail`/
  `uv-dl-fallback` non-gating indefinitely (their non-gating status is explicitly load-bearing,
  not provisional).

### pipreqs ecosystem status

- **Last scanned**: 2026-07-04.
- **Findings**: pipreqs (bndr/pipreqs) still stagnant/maintenance-only as of this scan; no new
  PyPI release since 0.5.0; still correctly pinned to 0.4.13 here (see "pipreqs pin rationale"
  above); `self.stub.pipreqs_version_fail` (Closed Backlog) confirms the warnfix safety net
  covers total pipreqs unavailability regardless of the exact failure mode.
- **Going forward**: check whether pipreqs has a new maintainer/release that changes the
  `<3.13` Requires-Python situation, or whether it's been removed from PyPI (extremely unlikely)
  -- revisit the internalization decision above if either happens.

## Known Findings (diagnosed, no action warranted)

- **User-code exit-code semantics are already correctly isolated from bootstrapper status --
  verified, no action needed.** Traced the full flow: `HP_SMOKE_RC` is captured directly from
  `%ERRORLEVEL%` immediately after launching the user's program at every verification call site
  (`:run_exe_smokerun`'s EXE smoke, `:verify_no_exe_interpreter`'s interpreter run,
  `:run_failfast_probe`'s interactive probe), via goto-based dispatch (not nested in a
  parenthesized if/else) with no bootstrapper logic interleaved between launch and capture --
  confirms it is purely the user program's own exit code. Separately confirmed the
  bootstrapper's own reported status is entirely decoupled: the terminating `exit /b 0` at the
  end of the `:success` label (the actual `run_setup.bat` process exit code on a real
  double-click) and every `call :write_status ok 0 ...` site pass a hardcoded literal `0`,
  never `%HP_SMOKE_RC%` -- so a crashing/non-zero-exiting user program is never reported as a
  bootstrapper failure. `~bootstrap.status.json`'s `exitCode` field means "did the
  bootstrapper's own env/build lifecycle succeed," not "what did the user's program return";
  the true user-program outcome is surfaced separately via the console
  `[STATUS] Run Status: SUCCESS/FAILED (Exit Code: N)` line. Also confirmed such a case does
  not get misrouted into repair logic: the `--hidden-import` auto-recovery loop only engages
  for a narrow signature (`ModuleNotFoundError` of a module that IS installed in the build
  interpreter -- see "--hidden-import auto-recovery must stay STRICT" in
  `docs/agent-lessons-learned.md`); any other user-program failure (a logic bug, an unrelated
  unhandled exception, etc.) takes no recovery action and is left exactly as observed, correctly
  not conflated with a packaging/bootstrapper problem. No code change needed; existing behavior
  already satisfies the intent.

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

- **pipreqs dead-or-not / internalization decision (2026-07, moved here from Active Backlog
  during a 2026-07 documentation thinning pass -- this is a decision already made with no
  action pending, not open future work).** pipreqs (bndr/pipreqs) is stagnant
  (maintenance-only, looking for maintainers) but not at risk of disappearing from PyPI
  outright -- PyPI does not delete established packages. The real risk the community cites is
  future-Python bitrot (an AST parser silently failing on new syntax), which this repo has
  already pre-empted twice over: the 0.4.13 pin (see "pipreqs pin rationale" above) avoids
  0.5.0's `<3.13` Requires-Python ceiling, and the warnfix build-time safety net (see
  "Dependency Discovery Fallback: warnfix" above) means the bootstrap **never hard-fails** even
  if pipreqs is 100% unavailable -- confirmed by `self.stub.pipreqs_version_fail` (Closed
  Backlog), which forces pipreqs's own install to fail via `HP_PIPREQS_VERSION=99.99.99`
  (already an env-overridable variable, no code change needed to trigger this; a nonexistent
  version number was chosen over pipreqs 0.5.0's real `<3.13` cap after CI showed the cap alone
  does not reliably fail across every lane's ambient Python) and proves the bootstrap still
  reaches a working, fully-run EXE via warnfix alone. Decision: **defer full internalization**
  (embedding a native AST-based scanner + mapping table to replace pipreqs entirely). It is
  technically feasible and roughly the size a 3rd-party estimate suggested (a few hundred lines
  + a small mapping table), but it duplicates a safety net that already works and is tested,
  and is its own nontrivial project (matching pipreqs's accumulated edge-case handling:
  encoding fallback, syntax-error tolerance, stdlib filtering). When it is eventually
  undertaken: write a **clean-room** scanner rather than copying pipreqs's actual source or
  mapping file (pipreqs is MIT-licensed; copying it verbatim would require carrying its
  copyright notice -- a clean-room reimplementation sidesteps this entirely, though crediting
  pipreqs by name/link as prior art in a code comment is a fair courtesy). Seed the mapping
  table by extending this repo's own already-license-clear `tools/parse_warn.py`
  `TRANSLATIONS` dict rather than importing external mapping databases (showmereqs/
  FawltyDeps/marimo/Grayskull all carry their own licenses needing separate audit, and none of
  those tables have been vetted against this repo's actual needs). Use
  `sys.stdlib_module_names` with a `try/except ImportError` guard per the existing
  "Embedded-helper Python baseline" convention (it's a 3.10+ feature; must degrade gracefully
  on an older ambient interpreter on the venv/system fallback tiers). Do not chase alternative
  tools as a wholesale replacement: `pigar` was correctly ruled out elsewhere (its wheel
  bundles an ~40 MB SQLite package database, a non-starter for a single-file bootstrapper).

## Closed Backlog

Items completed and shipped:

- **Concurrent-instance lock (REQ-024, double-click race)**: closes the 2026-07 iteration-pass
  finding that no mutex/lockfile mechanism existed anywhere in `run_setup.bat`, so a beginner
  double-clicking the `.bat` twice in quick succession (plausible -- no console window may be
  visibly open yet during the earliest startup checks) could launch two concurrent bootstrap
  processes racing on the same `conda create -n <name>` / `~setup.log` writes / `dist\<name>.exe`
  build target. Added `:acquire_lock`/`:lock_is_stale`/`:release_lock` (new subroutines, right
  after `:rotate_log`): `mkdir "~bootstrap.lock"` is the atomic acquire primitive (NTFS `mkdir`
  is race-free, unlike a check-then-create sequence), called near the very top of the main line
  (right after `%STATUS_FILE%` cleanup, before any real bootstrap work) with the caller checking
  `errorlevel` and exiting the whole process directly if acquisition fails -- matching the
  existing top-level `call :subroutine` / `if errorlevel 1 exit /b 1` idiom already used for the
  REQ-014 test-hook consent gate a few lines above it. A losing instance prints a friendly
  message (points the user at deleting the `~bootstrap.lock` folder if they're sure no other
  instance is really running), logs `[WARN] REQ-024: setup already running...`, and critically
  never deletes or otherwise touches the lock directory it does not own. Staleness is age-based
  (`~bootstrap.lock`'s `LastWriteTime`, >= 2 hours via the same PowerShell
  `(Get-Date)-$d).TotalHours` idiom already used by the conda-base-update timer), deliberately
  NOT PID-liveness-based -- a dead process's PID can be recycled by an unrelated program, so
  automated staleness logic must not trust PID liveness; the PID is still written to
  `~bootstrap.lock\owner.txt` for human troubleshooting only. Release is hooked at `:die` and
  `:success` (the two confirmed universal termination funnels for the normal flow), NOT at every
  one of the ~100 `exit /b` sites in the file -- CMD has no `finally`/`trap`, so a design that
  depended on *proving* every exit path releases the lock would be the wrong shape regardless of
  audit thoroughness; staleness is the correctness backstop, the `:die`/`:success` hooks are
  purely an optimization to avoid an ordinary successful run or ordinary handled failure leaving
  a lock sitting for up to 2 hours. See `docs/agent-interconnect.md` "Concurrent-instance lock
  (REQ-024) touches every exit path" for the call-graph tracing method used to scope this (and
  its limits -- a line-based CFG walk cannot fully resolve parenthesized `if/else` block
  structure without a paren-balance parser, which was assessed as disproportionate for this
  feature). Test hooks: `HP_TEST_DISABLE_LOCK` (opt out entirely, for tests that don't want
  lock semantics at all) and `HP_TEST_FORCE_LOCK_STALE` (deterministically force the staleness
  check without waiting out the real threshold). Three new `tests/selftest.ps1` rows:
  `self.stub.lock_no_leak` (lock does not persist after a normal successful run -- reuses the
  already-completed pipreqs-fail-fallback run above it at zero extra CI cost),
  `self.stub.lock_held_decline` (a fresh pre-existing lock blocks a second instance, which exits
  non-zero, logs the message, and leaves the lock untouched), and `self.stub.lock_stale_evict`
  (a forced-stale pre-existing lock is evicted and the bootstrap proceeds and completes
  normally). CLOSED by this PR.

- **NDJSON registry backfill + scanner scope fix + `selftest-gate` artifact-collision fix**:
  follow-up to the registry-check tool below (same day). Investigating its first real findings
  (11 code-only rows, 3 doc-only "stale" rows) found the "stale" classification was **wrong**:
  those 3 rows (`self.heuristics.pytest`, `self.parse_warn.pytest`, `self.pytest.unit`) were
  never removed from code -- they're emitted directly from inline PowerShell in
  `.github/workflows/batch-check.yml`, a file the scanner never read (it only scanned
  `tests/*.ps1` and `run_setup.bat`). Extended `tools/check_ndjson_registry.py`'s `code_paths`
  to also scan `.github/workflows/*.yml`/`*.yaml`, which fixed the false "stale" classification
  and surfaced 3 MORE genuinely-undocumented rows the old scope had made invisible entirely
  (`meta.env.mode`, `self.cache.bootstrap.failed`, and `workflow.lint` from the separate dormant
  `workflow-lint.yml`) -- bringing the real gap count to 14, not 11. Also found and added a 4th
  PowerShell/JSON emission convention while scanning workflow YAML: a raw JSON-string literal
  (`'{"id":"...",...}'`), used by the "Catch cache lane bootstrap failure" step instead of the
  `id = '...'` hashtable-literal form the other three conventions use. All 14 rows are now
  registered in `docs/agent-ndjson.md` (see that file's "Key facts" section for the full
  per-row breakdown); a clean re-run now shows 0 code-only findings and exactly the 16
  genuinely-out-of-scope `dynamic_tests.py` rows as the only doc-only findings. Two new unit
  tests cover the JSON-literal pattern and workflow-YAML scanning.

  Separately, while auditing the repo for other instances of the exact artifact-collision bug
  the registry-check job itself had (see the entry below), found a second, pre-existing
  instance: `selftest-gate`'s "Download lane verdicts" step had the identical
  `merge-multiple: true` + identical-local-filename (`lane_verdict.json`) collision, silently
  limiting its `has_failures` aggregation to whichever single lane's verdict survived instead of
  ORing all 8 matrix lanes. Lower severity than it sounds: `has_failures` only gates
  `model-quick-fix`'s auto-fix trigger, not PR merge gating (the `real`/`conda-full` matrix jobs
  gate merges via their own independent check conclusions) -- but it could silently skip
  auto-fix attempts when a non-surviving lane had real failures. Fixed with the same one-line
  removal of `merge-multiple`. Audited the workflow's two other `merge-multiple: true` usages:
  one (`iterate-logs-*` download) is a single-named-artifact download with no collision
  possible, confirmed safe and left as-is. Added a general lessons-learned entry
  (`docs/agent-lessons-learned.md`, "`download-artifact@v6` `merge-multiple: true` silently
  overwrites same-named files") documenting the hazard class and an audit method for future
  additions, so this class of bug is checked for by construction rather than rediscovered a
  third time. CLOSED by this PR.

- **CI-side NDJSON row registry check (3-way: doc vs code vs log)**: no automated signal
  existed that `docs/agent-ndjson.md`'s row registry had drifted from what the code actually
  emits, despite the file's own AGENT DIRECTIVE asking for in-commit sync. Added
  `tools/check_ndjson_registry.py` (stdlib-only): parses doc-registered IDs from the fenced
  code blocks (with brace-expansion for `prefix.{a,b,c}` syntax and parenthetical-annotation
  stripping), statically scans `tests/*.ps1` and `run_setup.bat` for all three PowerShell
  emission conventions in use (`id = '...'` hashtable literals, `Write-Result '...'`
  positional, `-Id '...'` named-parameter), and optionally cross-references against IDs
  actually observed in a directory of downloaded NDJSON artifacts. Deliberately excludes
  `tests/dynamic_tests.py` (Python, different emission pattern, and its "Dynamic-tests
  NDJSON" doc section already documents several rows as "(x many)" per-test-case IDs) --
  documented as an explicit scope limitation, not silently ignored. Discovered along the way
  that the doc's own "(x many)" annotation means "same literal id fires multiple times in a
  loop," not "dynamically-suffixed id family" as first assumed -- verified by tracing actual
  emission sites (`pr.to_conda`, `dp.pep440`, `emit.extract` are all single literal IDs
  called repeatedly, not templated); an earlier draft that treated them as wildcards produced
  a false positive on `emit.extract`, fixed before shipping. Wired into `batch-check.yml` as
  a new `ndjson-registry-check` job (`needs: [selftest]`, `ubuntu-latest`, downloads only the
  small `ci_test_results-selftest-*` artifacts -- not the multi-hundred-MB `diag-*` bundles)
  with job-level `continue-on-error: true`, matching this repo's established non-gating-lane
  convention so a real finding is visible without blocking merges while the tool is new. Five
  unit tests in `tests/test_check_ndjson_registry.py` cover brace expansion, all three code
  emission patterns, log-file parsing, and both pass/fail end-to-end paths via `main()`. First
  real run against this repo found 11 genuine undocumented rows and 3 stale registry entries
  (see the new Active Backlog item to backfill them -- deliberately left unfixed in this same
  PR). CLOSED by this PR.

- **Pages-deploy retry with backoff**: the "Deploy to GitHub Pages" step (`publish_diag` job)
  previously made a single `actions/deploy-pages@v5` attempt with no retry, so a transient
  backend failure ("Deployment failed, try again later" -- observed directly in this repo's own
  CI, e.g. run 28798318708) required a manual empty-commit retrigger. Split the single step into
  up to three attempts: attempt 1, then (only on failure) a 30s wait and attempt 2, then (only
  if both failed) a 20-minute wait and a final attempt 3 -- escalating rather than flat, on the
  theory that two consecutive failures signal a longer-lived backend issue worth giving real
  recovery time rather than hammering on a short cadence. Mirrors this repo's existing
  detect-transient-failure-then-retry idiom (conda create/bulk install) rather than pulling in a
  third-party retry-wrapper action. The job's `timeout-minutes` was widened 25 -> 40 to
  accommodate the worst case. Non-gating and safe to wait long: the job already has
  `concurrency.cancel-in-progress: true` scoped to the ref, so a sleeping attempt is safely
  superseded (not wasted runner time) if a newer push lands in the meantime. CLOSED by this PR.

- **Add `.github/dependabot.yml`**: no dependabot config existed anywhere in the repo, so there
  was no automated signal when a GitHub Action pin fell behind (the 2026-07 maintenance sweeps
  found every pin already on its latest major, but that was a manual, point-in-time audit).
  Added a minimal config with a single `github-actions` ecosystem entry (weekly schedule,
  `open-pull-request-limit: 5`) -- the only ecosystem with anything for Dependabot to track,
  since this repo has no committed `requirements.txt`/`pyproject.toml` (CI installs ad-hoc pip
  packages inline in workflow YAML `run:` steps, which Dependabot's `pip` ecosystem has no
  manifest file to scan). Dependabot PRs land on a same-repo branch (not a fork), so the
  existing `pr-automerge.yml` handler picks them up automatically like any other PR -- auto-merge
  is armed (not an instant merge), so the `real`/`conda-full` gating lanes still have to pass
  before a version bump actually merges. No workflow changes needed. CLOSED by this PR.

- **Fail-fast probe window widened 5000ms -> 10000ms**: `HP_FAILFAST_PROBE_MS` (the REQ-018
  Slice 2b-C fail-fast probe's classification window -- see the entry below for the full
  mechanism) was tuned assuming the window only needs to outlast a failing process's own error
  handling (effectively instant). It does not: a PyInstaller *onefile* EXE must first extract its
  bundled runtime to a temp directory and boot an embedded interpreter before any user code (or
  its failure) can run at all, and that cold-start step alone is commonly 1-3+ seconds even on an
  idle machine. Root-caused against a real CI flake in `self.failfast.probe.fastfail`: identical
  code produced `discardedAndRebuilt: true` on one run and `discardedAndRebuilt: false` on the very
  next run of the same commit -- a pure timing race between cold-start-plus-failure and the
  classification window, worsened by CI-runner CPU/disk contention or a Defender on-access scan of
  the freshly-extracted EXE/DLLs. Widening this value is unconditionally low-risk since it is
  classification-only and never introduces a kill point (see `docs/agent-lessons-learned.md`
  "Fail-fast probe window vs. the ~30s hard-kill cap are unrelated numbers" for why); the only
  cost of widening it is a few extra seconds before a genuinely broken cached EXE is recognized
  and rebuilt. Justifying comment added directly above the `set "HP_FAILFAST_PROBE_MS=10000"`
  line in `run_setup.bat` so a future reader does not "fix" it back down. Updated the matching
  static assertion in `tests/harness.ps1` (`batch.failfast.probe`) and all doc mentions of the old
  default. CLOSED by this PR.

- **venv creation resilience, part 2 (REQ-023b, --without-pip + get-pip.py retry)**:
  `:try_venv_fallback` previously declined the venv tier outright the
  moment plain `python -m venv .\.venv` failed, with no retry -- the most commonly-cited
  real-world failure mode (a stripped-down host Python missing `ensurepip`, which plain `venv`
  requires but `--without-pip` does not) had no recovery path. Added a single retry with
  `--without-pip` on the first failure, followed by a manual pip bootstrap via a newly downloaded
  `get-pip.py` (new `:download_get_pip` subroutine, mirroring the existing Miniconda/uv
  download-with-fallback pattern: curl, then PowerShell `Invoke-WebRequest`, then a fallback URL
  via both methods -- no interactive REQ-013 connectivity gate, since a plain failure here should
  silently decline the tier, not pause to ask the user). Goto-based dispatch throughout per
  "Provider-cascade dispatch is goto-based on purpose" in `docs/agent-lessons-learned.md`. New
  test hook `HP_TEST_FORCE_VENV_CREATE_FAIL` forces the first plain attempt to fail so the retry
  runs for real (including a real network download of `get-pip.py`); it also carves out a narrow
  exception in `:download_get_pip`'s offline check so the test can still use `HP_OFFLINE_MODE=1`
  to cheaply skip the unrelated Miniconda download, without weakening real-user offline
  protection (the flag is never set outside CI). New test `self.venv.nopip_retry` in
  `tests/selfapps_ux_hardening.ps1` exercises this end-to-end. This closes the second half of the
  "venv creation resilience" backlog item (part 1, the REQ-023 canary probe below, shipped
  separately). Explicitly **rejected** as part of this item, and not planned for any future round:
  relocating venv creation to `%LOCALAPPDATA%\hp_cache\...` and a `PYTHONUSERBASE`-based "stealth
  isolation" fallback tier -- both have a blast radius disproportionate to their benefit here
  (nearly every downstream path in this bootstrapper assumes CWD-relative execution, and
  `PYTHONUSERBASE` directly contradicts the REQ-010 host-isolation invariant this repo already
  enforces while risking leaving dependency residue on the user's machine, arguably worse than
  simply falling through to the existing system-Python tier below it in the cascade). CLOSED by
  this PR.

- **venv fallback canary probe (REQ-023)**: `:try_venv_fallback` (the canary-probe-specific
  logic this entry describes sits right before the final `[BOOT] REQ-009: Selected Python
  provider` log line in that subroutine -- see REQ-023b above, which added the `--without-pip`
  retry earlier in the same subroutine) previously declared the venv tier ready as soon as
  `.venv\Scripts\python.exe` existed on disk,
  without ever confirming the interpreter actually runs -- a venv can be "created" (directory +
  exe present) yet non-functional (missing DLLs, broken symlinks, execution-policy blocks),
  exactly the failure mode a stripped-down or corrupted host Python produces. Added a
  post-creation canary probe (`python -c "import sys"`) right before the tier is declared ready;
  on failure it logs a WARN and `exit /b 1` exactly like the tier's three existing failure
  branches already do, falling through to the next REQ-009 provider (system Python) with no new
  failure-handling path needed. Goto-based dispatch (not nested in a parenthesized if/else) per
  "Provider-cascade dispatch is goto-based on purpose" in `docs/agent-lessons-learned.md`. New
  test hook `HP_TEST_FORCE_VENV_CANARY_FAIL` plus `self.venv.canary_fail` in
  `tests/selfapps_ux_hardening.ps1` exercise this end-to-end. This was split from the broader
  "venv creation resilience" backlog item -- the other half (a `--without-pip` + `get-pip.py`
  retry when venv creation itself fails outright, above) shipped separately. CLOSED by this PR.

- **conda-create transient-retry gap (REQ-022)**: `:try_conda_create` previously
  had zero retry logic on a `conda create` failure -- it fell straight to `:handle_conda_failure`
  (venv/system cascade) on the very first non-zero exit, asymmetric with the sibling
  `:conda_bulk_install` phase's already-proven transient-retry pattern. Root-caused against a
  real CI failure (conda-full lane, run #1517: a transient `conda.anaconda.org` 403 during the
  `repodata.json` fetch, resolved only by a manual retrigger to run #1518). Fixed by porting the
  identical detect-transient-error-and-retry-once pattern from `:conda_bulk_install`
  (`findstr` for `CondaHTTPError`/`Failed to fetch`/`timed out`/`ConnectionError`, wait 15s,
  retry once) into `:try_conda_create`, using goto-based dispatch throughout (never nesting the
  create call + `%ERRORLEVEL%` capture inside a parenthesized if/else block) per the
  "Provider-cascade dispatch is goto-based on purpose" lesson in
  `docs/agent-lessons-learned.md`. On a non-transient or retry-also-fails outcome, behavior is
  byte-for-byte identical to before (falls through to `:handle_conda_failure` then `:die` exactly
  as it always did). New test hook `HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL` (separate from
  `HP_TEST_FORCE_CONDA_NETWORK_FAIL`, which only covers the bulk-install phase) plus
  `self.stub.conda_create_retry` in `tests/selftest.ps1` exercise this end-to-end. CLOSED by
  this PR.

- **REQ-018 Slice 2b-C -- unified run-model, both halves**: shipped in two PRs. The **fail-fast
  probe** (`:compute_interactive_run`, `:run_failfast_probe`, `HP_FAILFAST_PROBE_MS` default
  10000ms as of a later widening -- see Closed Backlog entry above) times out the two
  previously-untimed user-code launch points (`:try_fast_exe`'s
  cached-EXE reuse, `:verify_no_exe_interpreter`'s no-EXE path): an interactive user gets a short
  classification window then an unbounded, never-killed wait so a genuinely long-running app is
  never force-stopped, while a stale/broken cached EXE that fails fast still triggers
  discard-and-rebuild. Also fixed a silent-success gap it surfaced (`HP_FASTPATH_RUN_FAILED`
  decouples "keep the cached EXE" from "declare full success"). CLOSED by PR #318. The
  **post-execution checkpoint** (`:run_postexec_checkpoint`, `HP_TEST_CHECKPOINT_ANSWER`) is the
  other half of the original design: after the FIRST verification run's `[STATUS]` telemetry
  prints, offers an ELECTIVE second run via the interpreter (diagnostic tool), gated by the same
  3-branch consent-gate pattern as `:system_build_consent_gate`/`:cascade_consent_gate` -- never
  offered on the zero-friction fast path. Reuses `:run_failfast_probe` for the actual second
  launch rather than a fourth execution mechanism. See `docs/agent-interconnect.md` "Post-execution
  checkpoint (Slice 2b-C, second half)" for the full state-touching/safety analysis. CLOSED by
  this PR.

- **Iterate-gate pre-flight snapshot contradiction**: `tools/iterate_gate.ps1` emitted
  `has_failures:false` even when NDJSONs were missing, contradicting the intent that missing
  `tests/~test-results.ndjson` / `ci_test_results.ndjson` are treated as failures so empty
  streams never pass. Fixed by setting `$hasFailingTests = $true` after the NDJSON probing
  loop when `$missing.Count -gt 0`, but only when `$skipIterate` is not already `$true` --
  `batchcheck_failing.txt`/`failing-tests.txt` is itself derived from NDJSON rows by the
  harness, so an authoritative "no failures" verdict from the fail list is trusted over
  NDJSON copies this gate invocation did not have staged (an unconditional override broke
  `test_iterate_gate_skips_when_fail_list_is_none`, which stages a clean fail list with no
  NDJSON files present). Also updated the "Append iterate gate to Summary" CI step header in
  `batch-check.yml` to remove the confusing "expected has_failures:true while NDJSONs are
  missing" phrase (which appeared alongside `has_failures:false` in green runs where NDJSONs
  ARE present, creating a misleading appearance). CLOSED by this PR.

- **Progress messaging for >5s steps**: Added `[INFO]` progress messages before the two
  longest silent steps (conda env create at `:try_conda_create`, PyInstaller install+build in
  the main EXE-build branch) so users never mistake silence for a hang. Harness static checks
  `batch.progress.conda_create` and `batch.progress.pyi_build` verify both strings are present
  in `run_setup.bat`. CLOSED by PR #308.

- **uv DL fallback CI coverage**: Added a dedicated non-gating `uv-dl-fallback` lane
  (`HP_TEST_UV_DL_FALLBACK=1`) that forces the primary uv download URL to fail so the
  pinned-release fallback URL (`HP_UV_FALLBACK_URL`) is exercised and uv is acquired from it.
  `self.dl.uv.fallback` now fires as a real test in this lane (verifies `Trying fallback uv URL:`
  logged and `uv: acquired at ~uv_bin\uv.exe` confirms binary acquired). In `justme-test` it
  continues to pass with `skip=true` (HP_TEST_FORCE_UV_FAIL bypasses uv before any download).
  Fixed a duplicate `self.dl.uv.fallback` block in `selfapps_dl_fallback.ps1`. CLOSED by this PR.

- **Miniconda probe deferred to after uv detection**: the probe (CI-only, HP_CI_TEST_CONDA_DL=1)
  was firing before uv acquisition, downloading ~99 MB unnecessarily in all uv-first lanes
  (real, uv, contract-uv*). The probe is now deferred to after `:uv_first_skip`; when
  `HP_UV_PROVIDING_PYTHON=1` the probe emits `skipped=true, reason=uv-first` via
  `emit_conda_probe_skip` instead of downloading. The conda-full lane is unaffected (uv
  disabled there). Harness static check `batch.conda.probe.deferred` verifies the probe call
  appears after `UV_PYTHON_PREFERENCE` in the file and the `HP_UV_PROVIDING_PYTHON` guard is
  present. CLOSED by this PR.

- **Provider cascade on warnfix hard failure (REQ-009 / REQ-005.10)**: shipped in three slices.
  Slice 1 (#301) detects an unresolved-after-rebuild candidate (`:warnfix_cascade_detect`):
  fires only when warnfix still reports missing modules AND a repair install failed
  (`HP_CASCADE_CANDIDATE`). Slice 2 (#303) adds the user-consent gate
  (`:cascade_consent_gate`, `HP_CASCADE_APPROVED`; CI-safe via `HP_TEST_CASCADE_ANSWER` /
  `HP_CI_LANE` auto-decline). Slice 3 adds EXECUTION: on approval the main line jumps to
  `:provider_cascade`, which re-attempts the dependency phase under the next REQ-009 tier in
  priority order (uv -> conda -> venv -> system; uv->conda is the main gain since conda is the
  strongest solver). Re-entry reuses the existing env-create paths (`:try_conda_create` /
  `:after_env_mode_selection`); a uv->conda cascade acquires Miniconda on demand
  (`:cascade_acquire_conda`) because uv-first runs skip it. Per-tier `HP_CASCADE_TRIED_*`
  guards ensure a tier is never used as a cascade source twice, so the tiers exhaust and the
  run stops -- it never loops. conda-only mode (`HP_FORCE_CONDA_ONLY=1`) and a cleared
  `HP_ALLOW_SYSTEM_FALLBACK` suppress the respective downstream tiers. Tests: gating warnfix
  `xfail` now declines (stable, provider-independent) -> `self.cascade.consent`; the dedicated
  NON-gating `uv`-lane test `tests/selfapps_cascade.ps1` exercises the heavy uv->conda
  execution -> `self.cascade.exec`; harness static check `batch.req009.cascade_exec`. CLOSED
  by this PR.

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
- **Edit Detection Sprint (Loops 1-3)**: the earliest fast-path work in this repo's history,
  predating most of the conventions documented above. Loop 1 (PyInstaller build artifact
  cleanup): after a successful build, deletes `build\%ENVNAME%\` and `%ENVNAME%.spec` unless
  a spec file pre-existed (`HP_SPEC_PREEXIST`), logging `[INFO] PyInstaller build artifacts
  cleaned up.` Loop 2 (`HP_DEP_CHECK`/`~dep_check.py`) and Loop 3 (`HP_ENV_STATE`/
  `~env_state.py`) are the dep-check skip and env-state fast paths already summarized under
  "run_setup.bat Rules" above; their runtime-artifact schedule (`~bootstrap.status.json`,
  `~setup.log`, `~environment.lock.txt`, `~env.state.json`) and the `~env.state.json` schema
  both live in AGENTS.md's "Runtime artifact paths" section -- not duplicated here. All three
  loops are complete and live in `run_setup.bat`. CLOSED (this entry condensed from a
  standalone top-level section during a 2026-07 documentation thinning pass).
