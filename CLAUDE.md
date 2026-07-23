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

1. **conda-full lane duration (~80 min on both the original and retriggered attempt of run
   29002681009)** is the dominant single contributor to overall CI wall-clock growth (20 min ->
   1.5 h), separate from the (now-fixed, see Closed Backlog) diagnostics-bloat item. Likely
   accumulated feature/test-scenario growth (more selftest scripts each doing a real
   `conda create`), not a regression from any single change. Worth periodic reassessment, no
   action planned yet.
3. **~85 lines of near-duplicated env-var save/set/restore boilerplate between
   `self.embed.fallback.decline` and `self.embed.fallback.real`** in
   `tests/selfapps_ux_hardening.ps1`. Factorable into a shared helper, but each block forces a
   genuinely different set of env vars (decline: 6 vars; real: 5 different vars), so the helper
   would need real parameterization -- a small design decision, not a mechanical copy-paste
   cleanup. Cosmetic; defer unless already touching these test blocks for another reason.
4. **PYSPEC-aware venv-vs-embed decision function (promising, deliberately not implemented yet --
   don't add the complexity until there's a concrete reason to).** `:try_venv_fallback` currently
   uses whatever ambient Python is on the machine unconditionally, with no check of whether it
   actually satisfies `PYSPEC` (the same value `~detect_python.py` already computes for
   uv/conda/embed). This means the current linear order (embed before venv) always pays embed's
   network cost even in the common case where the ambient Python already satisfies the pin and
   venv would have been strictly better (instant, no network dependency, no extra disk). The
   flip side also matters: embed is reached immediately after conda, so by the time it's
   attempted, uv and conda have already both failed -- and since all three of uv/conda/embed
   need network, embed is disproportionately likely to fail for the *same* underlying reason
   (see the README's REQ-009 failure-causes table), making it a low-odds attempt in exactly the
   scenario where it's tried. A smarter design would check "does the ambient Python (if any)
   already satisfy PYSPEC?" and prefer venv when yes, falling to embed only when the ambient
   Python is absent or version-mismatched -- turning the fixed uv/conda/embed/venv/system chain
   into uv/conda/(venv-if-it-already-satisfies-PYSPEC, else embed)/system. Not pursued now: it
   changes `:try_venv_fallback`'s dispatch shape (must read `PYSPEC` before deciding, not just on
   creation), and the current fixed order is not wrong, just not optimal in either direction.
   Revisit if the network-correlated-embed-failure pattern shows up for real in CI or user
   reports, rather than speculatively building it now.
6. **AV-Safe Build Path (PyInstaller quarantine fallback via Nuitka)** -- full PRD at
   `docs/prd-av-safe-build-path.md`. A large, well-specified, preemptive feature (no real user
   report yet, a documented industry-wide problem) covering a two-tier Nuitka fallback when
   PyInstaller's build gets AV-quarantined, including a narrow, well-justified Python-3.12 pin
   scoped to that one fallback tier. The PRD's own "Notes from Claude" section has the original
   "way later" priority reasoning and a deliberately blunt writeup of why the PRD's narrow,
   well-justified Tier B version pin should **never** be generalized into a bootstrapper-wide
   "stay a version or two behind latest" default -- this repo's total absence of telemetry or an
   auto-update mechanism means any such pin would be permanently frozen into every
   already-distributed copy of `run_setup.bat`, with no way to walk it back later even after the
   reason for it stops being true. Read that section before extending Tier B's pinning pattern
   anywhere else in this codebase.

   **Implementation started 2026-07-20 (owner green light, after a refinement pass on the
   just-shipped autopep723 work held up cleanly -- see the Closed Backlog entry directly above
   this one).** Phase 1 requirement 1 (failure-simulation tests, test-first per the PRD's own
   sequencing note) is SHIPPED -- see the separate Closed Backlog entry for the real,
   independent correctness bug found and fixed while scoping it. **Requirements 2-4 (dispatch +
   Tier A: real Nuitka fallback build in the existing environment, no reprovisioning) are ALSO
   now SHIPPED** -- see the dedicated Closed Backlog entry. **Requirement 9 (P1, the elective
   "want an optimized build too?" post-success upsell) is ALSO now SHIPPED** -- see its own
   dedicated Closed Backlog entry.

   **Requirement 5 (Tier B, reprovisioned pinned-3.12 environment via the existing provider
   chain) is explicitly DEFERRED, owner's direct instruction (2026-07-21): "Until I run the
   bootstrapper myself and have real problems, I don't want to do the reprovision rollback."**
   This is not "not started yet" in the usual backlog sense -- it is a deliberate decision not
   to build it speculatively before a real, owner-observed failure justifies the added
   complexity (a second provider-chain traversal, a pinned-version environment, the
   stale-PATH/VIRTUAL_ENV hazard research Finding 6 already flagged). Requirements 6 (loop
   avoidance) and 8 (connectivity check before Tier B) both depend on Tier B existing and are
   deferred with it. Do not start Tier B without a fresh, explicit go-ahead -- this differs from
   how items 2-4 and 9 were greenlit (a broad "go as far as you can" authorization for the PRD
   generally); Tier B specifically was carved back out after that authorization, so it needs its
   own separate green light, not inference from the general one.

   **Downtime re-check, 2026-07-20 (research only, no code written):**
   verified against Nuitka's live changelog/issue tracker that Finding 1's core blocker (MinGW64
   doesn't support Python 3.13+) is still unresolved as of Nuitka 4.1.2 -- no change to the
   PRD's design. One narrower update folded into the PRD in place: a real Nuitka 4.0.4 bug fix
   ("compiling with newer Python versions did not fall back to Zig when MSVC/MinGW64 was
   unusable") means Tier A's own compiler-discovery chain may now land on Zig automatically more
   often than Finding 1's original "not mature enough" framing assumed, and the specific crash
   report Finding 1 cited turned out to be macOS/M3-scoped, not Windows. See the PRD's own inline
   "Re-checked 2026-07-20" note under Finding 1 for the full detail -- flagged for confirmation
   whenever Tier A is actually implemented, not verified end-to-end here (no Windows machine
   available for this research pass).
7. **CI job steps in `batch-check.yml` don't use `if: always()`, so one failing self-test step
   silently cascade-skips every subsequent step in the same job -- observed directly, not
   theorized.** While landing item 6's requirement-1 tests (PR #368), a bug in the new
   `selfapps_pyinstaller_fail.ps1` test itself (see Closed Backlog) caused its own step to fail
   in the `real` lane -- and the resulting `ci_test_results-selftest-real-*` artifact showed only
   ~59 rows total, ending abruptly right at the failing step, with ~40+ unrelated, pre-existing
   test rows expected afterward (the `self.stub.*`/`self.warn.*`/`self.guardrail.*`/
   `self.pep723.*` families and more) completely absent -- not failed, just never run. This is a
   pre-existing, repo-wide characteristic of the whole job (none of the ~50+ steps in the `real`/
   `conda-full` lane's step sequence use `if: always()`), not something introduced by that PR;
   it just happened to be the first time a step failure actually surfaced it. **Not fixed now,
   two reasons**: (a) `continue-on-error: true` is the wrong fix -- these are GATING lane steps
   specifically so a real regression blocks merges, and `continue-on-error` would silently defeat
   that; the real fix is `if: always()` on steps after the risk point (or all of them), which is
   a genuine, valuable hardening pass but touches ~50 existing step definitions across a job that
   already works today when nothing fails -- disproportionate to fold into an unrelated feature
   PR. (b) No user report or observed instance of this actually hiding a REAL regression yet
   (this instance was a test-bug false alarm, immediately visible via the job's own failure
   status) -- worth fixing deliberately, in its own reviewed pass, not as a rushed side effect.
   **Second real-world occurrence, 2026-07-21 (CI run 29829724937, uv lane, job 88632292427):**
   `self.optbuild.offer`'s `accept` scenario step (`tests/selfapps_optimized_build.ps1`) failed on
   a test-authoring bug (see the Closed Backlog entry for the AV-Safe Build Path requirement-9
   work), and because it was the first of three sequential `OPTBUILD_SCENARIO` steps in the same
   job with no `if: always()`, the `forcefail` and `decline` steps never ran at all -- same
   mechanism, same job, different test file.

   **Partially closed, 2026-07-22: the non-gating-lane half of this gap is now fixed; the
   gating-lane half remains open exactly as before.** Re-examined the actual workflow YAML rather
   than relying on memory of the original reasoning, and found `continue-on-error` is already set
   at the JOB level for six of eight matrix lanes (`cache`, `justme-test`, `uv`, `contract-uv`,
   `contract-uv-fail`, `uv-dl-fallback`) -- only `real`/`conda-full` are true gating lanes. This
   means the original "continue-on-error would silently defeat gating" reasoning above applies
   ONLY to steps that can run under `real`/`conda-full`; it never applied to steps restricted to
   the six already-non-gating lanes, since those never gated merges to begin with. Surveyed every
   step's `if:` condition and found 33 steps restricted to non-gating lanes only, of which the PEP
   723 write-back / PVW QuickStart / autopep723-discovery steps already carried per-step
   `continue-on-error: true` (established precedent, not invented for this pass) while 9 others
   (uv-contract assertions, JustMe/download-fallback self-tests, the provider-cascade-exec step,
   both Tier A steps, all 4 `self.optbuild.offer` scenarios) were missing it. Added it to those 9
   -- this is a narrower, safe subset of the originally-declined blanket fix: it changes nothing
   about merge gating (never gated anything) and only stops one failing self-test from hiding its
   siblings' results within the same non-gating-lane job run. The `real`/`conda-full` gating-lane
   half of this backlog item is untouched and remains deliberately deferred for the same two
   reasons as before -- do not extrapolate this fix onto the gating lanes without the same kind of
   deliberate, reviewed pass the original reasoning called for.

   **Two more missed instances found and fixed in a follow-up bug-hunt pass, same day.** A
   dedicated CI-YAML bug-hunt agent re-surveyed the file with fresh eyes and found the `cache`-lane
   `Restore Miniconda cache` step (`uses: actions/cache/restore@v5`) and its sibling `Validate
   restored conda binary` step both missing `continue-on-error: true` despite being restricted to
   the (non-gating) `cache` lane -- the same bug class, just missed in the original 9-step sweep.
   This instance is more severe than the previously-fixed ones: `actions/cache/restore@v5` is a
   real network/service call (GitHub's cache backend has known transient failures) sitting near the
   very START of the job, before roughly a dozen unconditional (non-`always()`) steps including the
   bootstrapper run itself -- a single transient cache-restore failure would silently skip the
   entire cache-lane self-test battery, not just a handful of sibling scenario steps. Fixed the
   same way (added `continue-on-error: true` to both steps); `cache` remains non-gating either way.
*(Item 5 from the pre-existing "cosmetic log noise/path doubling" debrief note was checked
briefly per standing instruction not to over-invest: no `--distpath`/`--workpath` override or
other structural path-doubling exists in the PyInstaller build invocation. Most likely source is
the "Build public diagnostics tree" step's own `DIAG CWD`/`DIAG ROOT`/`DIAG TREE` debug print
lines, which naturally show GitHub Actions' inherent doubled checkout path
(`.../Python_vs_Windows/Python_vs_Windows/...`) -- a runner convention, not a bug. Not chased
further.)*
8. **CLI-args and stdin-interactive Python program support.** Full plan at
   `docs/plan-cli-interactive-verification.md`. Confirmed real (not hypothetical) via direct code
   tracing: every verification launch point redirects the child's stdout/stderr into an in-memory
   buffer only written to disk after the process exits, so an interactive program's prompts never
   reach the visible console; the primary EXE verification (`:run_exe_smokerun`) additionally
   force-kills after a hard 30s, which would kill a program correctly waiting on its first
   `input()` prompt. This is the owner's own original target shape for this repo (a program that
   asks setup questions, then loops on stdin until a quit command), not an edge case.

   **P0 requirement 1 (live-echo + stop passing results through `for /f`-captured stdout) is
   SHIPPED (2026-07-23)** -- see the Closed Backlog entry below for what shipped and the real,
   non-obvious async-output-drain race found and fixed along the way (not anticipated by the
   original plan). **Requirement 2 (confirm stdin passthrough on real Windows CI) and requirement
   3 (revisit the 30s kill, Open Question 1) remain OPEN** -- requirement 2 specifically needs a
   real Windows run, not just local `pwsh` testing, since the remaining unknown is cmd.exe's own
   console/stdin semantics for a double-clicked `.bat`'s process tree, which cannot be reproduced
   in this sandbox. P1 (argv-passthrough escape hatch) and P2 (honest ambiguous-exit messaging)
   are both still un-started, per the plan's own recommended P0-first sequencing. Not sized into
   further loops yet -- the natural next step is a non-gating Windows CI experiment for
   requirement 2, per the plan doc's own "Notes from Claude" update.

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
  already covers this on the "does a new version exist" axis. If REQ-AV's Tier B (see the PRD
  link in Active Backlog) ever ships its own Python-3.12 pin for Nuitka/MinGW64 compatibility,
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

- **The official `irm https://astral.sh/uv/install.ps1 | iex` installer script was researched as
  a possible replacement for the current uv acquisition method -- rejected, current approach is
  correct.** (Note: the exact official URL is `https://astral.sh/uv/install.ps1`, not the bare
  `https://astral.sh` domain -- verified directly against astral.sh's own installation docs.) The
  bootstrapper currently downloads uv's release zip directly from GitHub
  (`HP_UV_URL`/`HP_UV_FALLBACK_URL`, run_setup.bat) and extracts `uv.exe` into a private
  `~uv_bin\` directory that is prepended to `PATH` for the current process only (REQ-010 session
  isolation). The official installer script does something architecturally different and worse
  for this bootstrapper's needs: it installs uv to a persistent, shared, user-global location and
  writes a PATH update to the user's shell profile/registry -- a footprint the installer script's
  own documentation and general Windows tooling behavior both confirm requires a **fresh terminal
  window** to take effect, since PATH updates never propagate into an already-running process.
  That is fundamentally incompatible with `run_setup.bat`'s zero-terminal-restart promise (the
  same class of restart/PATH-propagation hazard flagged independently in
  `docs/prd-av-safe-build-path.md`'s Finding 6) -- the bootstrapper needs to use uv immediately,
  within the same running batch process, with no user interaction. It also conflicts with two of
  this repo's own stated Bootstrap Architecture Principles in this file (above): "Never depend on
  console scripts during bootstrap" and preferring a private, disposable footprint over a shared,
  persistent one -- the same reasoning that separately ruled out winget/Microsoft Store Python as
  a REQ-009 tier. Decision: keep the current direct-zip-to-private-directory approach; the
  installer script is the right choice for a normal interactive user setting up their own
  machine, not for a script that needs the tool usable in the same process that downloaded it.

- **Embed zip download has no genuine second-host fallback available, unlike Miniconda/uv/get-pip
  -- researched, no action planned.** A background code-review pass flagged that the embed tier's
  download (`:try_embed_fallback`, run_setup.bat) retries the *same* `HP_EMBED_URL`
  (`www.python.org/ftp/python/...`) on failure, unlike Miniconda (has a `repo.continuum.io` legacy
  alias), uv (has a pinned-release GitHub URL distinct from its "latest" CDN redirect), and get-pip
  (has the get-pip project's own GitHub source as a second host). Researched whether an equivalent
  second host exists for python.org's embeddable zip distribution: it does not, in the same sense.
  `www.python.org/ftp` is itself the canonical, Fastly-CDN-backed distribution point for CPython
  releases -- there is no alternate *official* domain serving the identical embeddable-zip artifact.
  python.org does list community mirrors, but none are guaranteed to carry the embeddable-zip
  variant specifically, or to match this repo's pinned SHA256 the way the primary source does by
  construction (the checksum was computed directly from a `python.org/ftp` download at pin time) --
  pointing at one would be a real trust/availability decision, not a mechanical copy of the
  Miniconda/uv/get-pip pattern. Decision: no forced fallback host. The existing 2-attempt
  same-URL retry (curl, then PowerShell `Invoke-WebRequest`) already covers the common transient
  failure case; a genuine second-host fallback remains possible future work if a specific mirror is
  ever vetted, but is not a quick win and is not planned. **One specific candidate WAS identified
  and considered, then rejected**: the CPython core team publishes an embeddable-equivalent build
  to NuGet (`nuget.org/packages/python`) as part of their official release process -- a real,
  independently-hosted, officially-maintained artifact on a different CDN (Azure-backed vs.
  Fastly), reachable without the NuGet client via `nuget.org/api/v2/package/python/<version>`.
  Rejected because it is not the same artifact the pinned `EMBED_PYTHON_TABLE` checksums were
  computed against -- using it would mean maintaining a second SHA256 column per pinned version
  going forward, doubling the table's maintenance burden for a download that's already covered by
  the existing 2-attempt retry against a CDN that's rarely actually down. Revisit only if the
  same-host retry proves insufficient in practice.

- **winget / Microsoft Store Python evaluated as a possible additional REQ-009 tier -- rejected,
  no action planned.** Considered whether `winget install Python.Python.3` (or the Microsoft Store
  Python package) could serve as another fresh-acquisition fallback alongside or instead of the
  embedded-Python tier. Researched winget's actual install behavior: without an explicit
  `--scope machine` flag (which needs elevation), it installs **per-user** to
  `%LOCALAPPDATA%\Programs\Python\Python3XX` -- but "per-user" is not the same axis as "isolated"
  in the sense the embed tier cares about. Unlike embed's private, checksummed, disposable
  `~embed_python\` directory (never registered anywhere, verified before use, gone if the app
  stops using it), a winget/Store install is **shared and persistent**: it registers itself on
  PATH, in Add/Remove Programs, and in the App Execution Alias registry, is discoverable by other
  applications and future bootstrap runs of *other* projects, and its integrity is delegated
  entirely to winget's own signature verification rather than this repo's own embedded SHA256.
  Architecturally this makes it closer to the **system** tier (shared, uncontrolled, arguably
  needing the same REQ-014-style consent) than to the **embed** tier (private, disposable,
  pre-verified) -- adding it would mostly duplicate embed's job (fresh acquisition) with weaker
  isolation, for the same underlying failure causes embed already fails for (no network, or -- for
  winget itself -- winget/App Installer not being present on an older Windows 10 build, which is
  its own new dependency this bootstrapper doesn't otherwise have). Decision: not worth adding as
  a 6th tier.

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

- **CLI-args/stdin-interactive support, P0 requirement 1 (live-echo + result-file redesign) --
  Active Backlog item 8's first shipped slice.** Owner asked to empirically validate the proposed
  fix locally with `pwsh` before implementing, then said "proceed with whatever you are confident
  on" once that testing (documented in PR #373's own commits to
  `docs/plan-cli-interactive-verification.md`, Findings 5b/6/7) held up. Implemented and shipped:
  - `tools/failfast_probe.ps1` (the shared, never-kills helper behind `:run_failfast_probe`, used
    by the cached-EXE fast path / interpreter fallback / postexec checkpoint) rewritten to
    live-tee the child's stdout/stderr via `Register-ObjectEvent` (polling `WaitForExit(100)`
    loop, never a single blocking wait -- confirmed both empirically and against
    PowerShell/PowerShell#11065 that a blocking wait prevents event dispatch) instead of only
    writing captured output to disk at exit.
  - **New `tools/exe_smokerun.ps1`**: `:run_exe_smokerun`'s old inline `-Command "..."`
    one-liner converted to a proper emitted `.ps1` helper (via the existing `:emit_from_base64`
    mechanism) -- required because `Register-ObjectEvent`'s `-Action { ... }` needs
    literal-quote-containing PowerShell an inline `-Command` string can't safely hold. Same
    live-tee pattern, with the one intentional behavioral difference preserved exactly: still
    calls `$p.Kill()` after 30s (now `HP_SMOKERUN_KILL_MS`, default 30000 when unset -- production
    behavior byte-for-byte unchanged; the override exists purely for
    `tests/test_exe_smokerun.py` to exercise the `Kill()` branch without a real 30s wait).
  - **Both callers in `run_setup.bat` (`:run_failfast_probe`, `:run_exe_smokerun`) stopped
    wrapping their helper invocation in `for /f ('powershell ...') do (...)`.** `for /f` captures
    the ENTIRE stdout of the wrapped command -- which would swallow every live-teed line (never
    shown to the user) and corrupt the `exceeded|exitcode`/exit-code result parsing (every teed
    line misparsed as a candidate result). Confirmed with a bash proxy of the identical
    command-substitution shape before touching production code (see the plan doc's Finding 6).
    Fixed by invoking each helper directly (a plain top-level `powershell -File ...` statement)
    and having each write its result to a dedicated file (`HP_PROBE_RESULT`/
    `HP_SMOKERUN_RESULT`) read afterward via a separate, safe (static-file) `for /f`.
  - **A second, independent race was found and fixed while empirically testing the above in
    `pwsh` -- not anticipated by the original plan.** Microsoft's own documented guidance for
    async-redirected output ("call the no-arg `WaitForExit()` after a timed one returns `true`,
    to ensure async event handling has completed") was empirically PROVEN INSUFFICIENT in this
    environment: a direct repro showed the final `OutputDataReceived` event (carrying a line
    Python only flushed at process exit -- an ordinary unflushed `print()` before a
    redirected/non-tty stdout) firing AFTER both `WaitForExit()` calls had already returned,
    silently losing that line from the captured buffer/file. Fixed by tracking each stream's own
    null-`Data` EOF event explicitly and adding a bounded drain-wait poll for both streams before
    reading the buffers -- see `docs/agent-lessons-learned.md`'s new ".NET Process
    async-redirected-output" entry for the full mechanism, a companion confirmed fact (Python's
    `input()` DOES flush stdout before blocking on stdin, even when redirected -- so the owner's
    actual target use case, `input()`-driven prompts, isn't at risk of this specific hazard), and
    a rule of thumb for any future `Register-ObjectEvent` consumer in this repo.
  - Both embedded payloads hit the CMD 8191-char line-length budget for real during this work
    (`HP_FAILFAST_PROBE`'s first draft exceeded it by 2021 chars) -- both header comments were
    trimmed to the terse, point-to-docs style already used by `HP_EMBED_PYVER_CHECK`.
  - `tests/test_failfast_probe.py` updated (result now read from a file, not `proc.stdout`; new
    `LiveTee` test class asserting live output reaches the script's own stdout/stderr) and new
    `tests/test_exe_smokerun.py` added (fast-exit, `Kill()`-timeout, output-path overrides,
    `PayloadSync`) -- both exercise the real scripts end-to-end via `pwsh` subprocesses.
  - **Requirement 2 (confirm stdin passthrough on real Windows CI) and requirement 3 (revisit the
    30s kill, Open Question 1) remain OPEN**, as does all of P1 (argv passthrough) and P2 (honest
    ambiguous-exit messaging) -- see the updated Active Backlog item 8. Requirement 2 specifically
    needs a real Windows run (cmd.exe's own console/stdin semantics for a double-clicked `.bat`
    cannot be reproduced in this sandbox), flagged as the natural next non-gating CI experiment.

- **No-EXE postflight briefing panel (docs/open-questions.md item 1, owner-approved "just better
  UX, go for it").** When BOTH PyInstaller and the Nuitka Tier A fallback fail outright and the
  interpreter fallback then runs cleanly, the final console line previously read a bare
  `[STATUS] Run Status: SUCCESS (Exit Code: 0)` -- identical to a genuine EXE success, with the
  only prior signal being one `[ERROR]` line several seconds earlier. Traced the actual gap:
  `:print_postflight_briefing` (the existing "SETUP COMPLETE" panel) is only ever called `if
  exist "dist\%ENVNAME%.exe"`, so when no EXE was ever produced at all, no briefing panel is
  shown at all -- not even the existing "SETUP COMPLETE -- WITH A CAVEAT" variant, since that one
  also assumes an EXE artifact exists. Fixed by adding a sibling `:print_no_exe_briefing` panel,
  gated on `HP_BUILD_OK` being defined (a build was actually attempted -- distinguishes this from
  "no entry file found" or a declined system-Python build, neither of which set it) AND
  `dist\%ENVNAME%.exe` not existing (distinguishes it from a real EXE success). Purely additive:
  does not touch `~bootstrap.status.json`'s `state=error` (already correct, via `:die`'s own
  `HP_BOOTSTRAP_STATE=error`) or the process exit code. Extended `selfapps_pyinstaller_fail.ps1`'s
  existing xfail scenarios (which already force total packaging failure via
  `HP_TEST_FORCE_PYINSTALLER_FAIL`/`HP_TEST_FORCE_OUTPUT_VANISH` + `HP_TEST_FORCE_NUITKA_FAIL`) to
  also assert the new panel's header text appears in the log, folded into the existing
  `$xfailPass` condition.

- **Multi-agent parallel bug-hunt pass, requested directly by the owner ("Do several refinement
  and iteration passes. Do deep dives to find bugs and potential issues. Dig in... launch some
  agents if you want").** Five parallel research-only agents swept `run_setup.bat`, `tools/*.py`,
  `tests/*.ps1`, `.github/workflows/*.yml`, and `tools/diag/*.py` respectively for new bugs beyond
  what earlier passes had already found; every finding was independently re-verified by direct code
  tracing before being acted on (two agent findings that didn't hold up on verification are noted
  below, not silently accepted). Six real, fixed issues:
  - **`:die`'s `HP_BOOTSTRAP_STATE=error` gap was systemic, not limited to the 3 already-fixed
    PyInstaller call sites -- fixed centrally instead of per-call-site.** Confirmed via direct
    tracing (not just the agent's claim) that `call :die "[ERROR] conda env create failed."` at
    the end of `:handle_conda_failure`'s exhausted-fallback chain falls straight through to
    `:conda_create_done` with `HP_PY` left pointing at a nonexistent interpreter path, and if
    execution eventually reaches `:after_cascade_decision`/`:after_env_skip` with
    `HP_BOOTSTRAP_STATE` still at its line-163 default of `"ok"`, the final status write silently
    reverts a real failure back to reported success -- the identical bug class already fixed for
    PyInstaller build failures (see "PyInstaller build-failure silently masked as success" below),
    just present at roughly 22 of the file's ~26 `call :die` sites instead of 3. Several of these
    were saved from being an OBSERVABLE bug purely by accident: a broken `HP_PY` downstream usually
    makes the later PyInstaller build itself fail too, which hits one of the 3 already-fixed sites
    and "rescues" the final state via a code path unrelated to the actual original failure -- but
    any run where the pipeline never reaches that rescue point (e.g. no entry file ever resolved,
    so PyInstaller is never invoked) would still silently report `state=ok`. Rather than touching
    ~22 call sites individually, fixed at the single point all of them funnel through: `:die` itself
    now sets `HP_BOOTSTRAP_STATE=error` unconditionally as its first action, before its existing
    `call :write_status "error" ...` line -- covering every existing AND future `call :die` site
    with one line. Verified this doesn't change any currently-passing test's outcome: tests like
    `self.embed.fallback.decline` that already assert `state=='error'` for an exhausted-fallback
    scenario were previously passing only via the PyInstaller-failure "rescue" coincidence; they now
    pass via the direct, reliable mechanism instead. See `docs/agent-lessons-learned.md`'s `:die`
    entry for the full trace.
  - **`tools/pvw_known_idempotent.py`'s live execute-mode discovery run had no timeout, unlike its
    own sibling calls in the same file (60s/120s).** `run_script()` genuinely executes the user's
    entry script (not a smoke test -- that's the whole point of `HP_PVW_KNOWN_IDEMPOTENT`'s
    execute-mode discovery). A GUI-mainloop app or a script blocking on `input()` -- both ordinary
    Python programs -- would hang this call, and therefore the entire bootstrap, forever with zero
    feedback, since it runs before any build/verification phase. Unlike `:run_failfast_probe`'s
    later verification runs (which must never be killed, since they represent the user's real
    deliverable output), this is a throwaway discovery pass that happens before two more runs of
    the same script anyway, so bounding it costs nothing a real run needs. Fixed with a 120s
    timeout, `subprocess.TimeoutExpired` caught and mapped to return code 1 (routing through
    `main()`'s existing "other nonzero" best-effort-fillin-and-retry branch, same as any other
    non-2 failure) rather than raising. New tests in `RunScript` assert both that a timeout is set
    and that it's caught cleanly.
  - **The same file's malformed-header strip-and-retry path could silently corrupt a non-UTF-8
    entry file, on both the success AND the double-failure "restore original" paths.** Unlike its
    sibling `tools/pep723_writeback.py` (which validates UTF-8-ness before ever opening the file
    for a destructive write), this file read with `errors="ignore"` with no prior validation --
    for a non-UTF-8 file, this silently drops invalid bytes on the very first read, so the
    in-memory "original" used for the failure-path restore was itself already corrupted before any
    write happened. Fixed by removing the ignoring read entirely and instead catching
    `UnicodeDecodeError` on a strict read, bailing out before any write -- simpler than the sibling
    file's two-open pre-check-then-read pattern while providing the identical guarantee. New
    regression test confirms a non-UTF-8 file is left byte-for-byte untouched.
  - **The embed tier's version-swap directory-move fix from an earlier pass was itself wrong, and
    a second pass caught it before it reached CI.** An earlier session had "fixed" `:embed_swap_
    retry`'s unreliable post-move success check by mirroring requirement 9's file-move pattern
    (check whether the source is gone instead of the destination). That mirroring doesn't actually
    hold: requirement 9 is a FILE move (atomic replace-or-noop onto an existing destination,
    verified via direct Windows `move` semantics), but this is a DIRECTORY move, and a directory
    `move` onto an existing destination silently NESTS the source inside it instead of failing --
    so if the preceding `rd /s /q` fails to fully clear the destination (the exact lock race this
    code exists to handle), BOTH "check destination" and "check source gone" read as false success,
    for different reasons (the stale prior destination content is still there either way; the
    source path is gone either way, since it got renamed into the nested subfolder rather than
    genuinely swapped). Fixed by gating `move` on `rd` having actually cleared the destination
    first, so `move` only ever runs onto a confirmed-nonexistent target (nesting becomes
    structurally impossible), making the destination-existence check reliable again. New general
    lesson added to `docs/agent-lessons-learned.md`: a Windows move/swap verification pattern
    proven for a FILE does not automatically transfer to a DIRECTORY (or vice versa) -- re-derive
    the semantics explicitly rather than assuming. Not CI-confirmed (no test currently exercises
    a non-default Python version through this tier), based on static reasoning about documented
    Windows `move`/`rd` semantics.
  - **Three `selfapps_*.ps1` test scripts always exited 0 regardless of their own computed
    `$pass`, silently masking a genuinely broken feature as a green CI step.** Every sibling test
    file in this batch ends with `if (-not $pass) { exit 1 }` before the final `exit 0` --
    `selfapps_pvw_idempotent.ps1`, `selfapps_autopep_discovery.ps1`, and `selfapps_pvw_quickstart.ps1`
    were each missing this guard (an omission, confirmed by comparing against every sibling file's
    identical ending pattern). Each already computes `$pass` correctly and writes it into the
    correct NDJSON row -- so the machine-readable signal was never wrong -- but a human scanning
    the GitHub Actions UI, or any tooling checking step-level (not NDJSON-content-level) status,
    would see a passing green step for a broken REQ-005.12/REQ-005.13/PVW-QuickStart feature. All
    three steps already carry `continue-on-error: true` in CI (non-gating `uv` lane), so this fix
    changes zero merge-gating behavior -- it only restores accurate step-level signal.
  - **`tests/selftest.ps1` -- the largest, oldest, most heavily-used self-test file, run in EVERY
    lane including the two true gating lanes -- had no exit statement at all, and this one DOES
    affect merge gating, not just step-level display.** Found via manual follow-up after the
    PS-test agent's finding above prompted checking every OTHER test file, not just the three
    newest ones the agent was scoped to. Confirmed via direct tracing: `run_tests.bat` (this
    file's own caller) does `if errorlevel 1 set ERR=1` right after invoking `selftest.ps1`, and
    the "Run tests (map empty repo to success)" CI step (`batch-check.yml`) does `exit $rc` using
    `run_tests.bat`'s own exit code, with NO `continue-on-error` -- so for `real`/`conda-full`
    (the lanes with no job-level `continue-on-error` either), this step's exit code directly
    determines job success/failure. Since `selftest.ps1` never had an `exit` statement, PowerShell's
    default (0, absent an unhandled exception) was always returned regardless of how many of its
    ~40+ internal scenarios (`self.stub.*`, `self.warn.*`, `self.guardrail.*`, `self.pep723.*`,
    `self.corrupt.*`, etc.) computed `pass=$false` -- a genuinely broken scenario here was
    previously invisible to the GATING mechanism itself, not just to a human eyeballing the Actions
    UI. Fixed at the single choke point every scenario already funnels through (`Write-NdjsonRow`,
    called by all ~40+ scenarios) rather than touching each one: the function now sets a
    script-scoped `$script:AnyRowFailed` flag whenever a row's `pass` is `$false`, and the file's
    final lines check it and `exit 1`/`exit 0` accordingly. Chose this central-choke-point approach
    specifically because retrofitting each of the ~40+ scenario blocks individually would have been
    a much larger, higher-risk change to the repo's oldest and most load-bearing test file for the
    same outcome. Verified the tracking logic in isolation (a standalone `pwsh` repro of the exact
    pattern, confirming both the failure-detection and all-pass cases) since the full file can't run
    end-to-end outside real Windows CI. No xfail/expected-failure scenarios exist in this file (
    confirmed via search), so `pass=$false` unambiguously means "this scenario's assertion did not
    hold" everywhere in it -- no risk of the aggregate flag misfiring on an intentional-failure row.
  - **`tools/diag/publish_index.py`'s NDJSON summary silently miscounted rows/pass/fail when
    multiple JSON objects were concatenated onto one physical line.** `tools/diag/ndjson_fail_list.py`
    already has a brace-depth-aware, string-escape-aware splitter (`_ndjson_segments`) specifically
    because real NDJSON artifacts in this repo can have `{...}{...}` on one line -- but
    `_summarize_ndjson_file` (which feeds the live public dashboard's `rows=X pass=Y fail=Z`
    summary block) used a naive `json.loads(line)` with no such splitting, so a concatenated line
    threw `JSONDecodeError` and the whole blob (potentially dozens of real rows) was silently
    counted as a single row/failure -- understating row counts and inflating the apparent fail
    rate with no error surfaced anywhere. Fixed by importing and reusing the existing splitter
    (same package, same established cross-module-import pattern already used for
    `generate_fail_list`) instead of writing a second, divergent implementation. New
    `SummarizeNdjsonFileTest` class (3 tests) covers the concatenated-line case directly, plus the
    normal one-object-per-line and `status`-field-fallback paths that had no prior coverage either.

  **Two agent findings investigated and NOT acted on, verification failed or impact judged
  too low relative to risk**: a `detect_python.py` PEP 440 wildcard-clause regex claim was traced
  and found to be a real but narrow silent-misparse (`!=3.0.*` truncates to `!=3.0`) -- correct as
  described but low real-world impact (wildcard exclusions are rare in `requires-python` fields
  specifically) and not fixed in this pass, left as a candidate for a future dedicated loop rather
  than folded in here. A `pyproj_deps.py` ASCII-with-`errors='replace'` output-encoding claim (a
  non-ASCII character in a dependency string silently becomes `?` on write) is real but requires an
  adversarial non-ASCII `pyproject.toml` dependency string, an uncommon real-world case; also left
  for a future pass rather than expanding this one's scope further.

- **User-facing messaging cleanup pass, requested directly by the owner via a detailed
  question-and-answer message reviewing several prior findings.** Four small, independent
  wording fixes plus a documentation restructuring:
  - `:warn_user_code_launch`'s "Verifying the built standalone EXE (PyInstaller) now" message now
    branches on `HP_NUITKA_FALLBACK_USED` and says "(fallback build system)" instead when the EXE
    being verified was actually Nuitka-built (Tier A or requirement 9's optimized build) -- this
    subroutine fires for both cases and previously always claimed PyInstaller regardless. The
    postflight briefing's "PyInstaller build cache" line for `build\` was deliberately left
    unchanged: Nuitka never creates a `build\<env>\` folder of its own (its `--remove-output`
    flag cleans up its own intermediates), so that line stays literally true either way -- if a
    `build\` folder exists at all, it's PyInstaller's, confirmed by tracing both build paths
    before deciding not to touch it.
  - The warnfix console message ("Platform-specific modules in the list above are expected on
    Windows...") referenced a "list above" that was never actually on the console -- the raw
    warn-file dump immediately before it (`type "build\<env>\warn-<env>.txt" >> "%LOG%"`) is
    redirected straight into `~setup.log` only, confirmed by tracing the exact redirect operator.
    Reworded to drop the false "above" reference and instead point at `~warnfile.txt` (already
    copied next to the app a few lines earlier) and `~setup.log` for the full list.
  - Added a one-line reassurance right after "[INFO] Building standalone executable..." for the
    benign "The system cannot find the drive specified." message that appears on-screen near
    almost every build attempt (confirmed already known-harmless and allowlisted by
    `tests/selfapps_envsmoke.ps1`). Researched the likely source before adding this: confirmed via
    direct code tracing (not assumption) that ALL of PyInstaller's own subprocess invocations in
    `run_setup.bat`, and `:compute_collect_flags`'s own Python subprocess call, have both
    stdout AND stderr fully redirected -- so the message cannot be literal PyInstaller output
    leaking through the normal redirect, and `:compute_collect_flags` runs before (not after) the
    log line the message appears near, ruling that subroutine out as the direct cause too. Root
    cause remains unconfirmed (most likely an unrelated background process whose output happens
    to flush around the same wall-clock window); not chased further per explicit instruction not
    to go deep (this exact investigation had already stalled in a prior pass) -- the message
    itself is the fix, not a suppression attempt. **Found and fixed a self-inflicted near-miss
    while writing this message**: the first draft quoted the trigger phrase verbatim inside the
    reassurance text, which would have made `tests/selfapps_envsmoke.ps1`'s unanchored
    `Get-LineSnippet` substring search capture the REASSURANCE line itself (appearing earlier in
    the transcript) instead of the real system-generated line, fail the exact-match allowlist
    check against it, and produce a false test failure. Reworded to avoid the literal trigger
    substrings entirely; grepped the whole test suite for both trigger phrases afterward to
    confirm no other detector collides. See `docs/agent-scratchlog.md` for the full trace.
  - **Documentation restructuring, per direct owner instruction**: `docs/demo-bootstrapper-output.md`
    is now latest-state-only (quotes updated in place, no historical narrative, no per-session
    dated log). Removed its "Refinement pass log" and "Findings worth a second look" sections
    entirely -- their still-relevant content was either folded into the demo doc's own scenario
    write-ups (as plain current-state notes, not history) or moved to one of two new files:
    `docs/agent-scratchlog.md` (internal working notes -- verification checks, dead ends, things
    ruled out; not user-facing, freely prunable) and `docs/open-questions.md` (unresolved
    questions needing a maintainer decision only; answered questions get removed from it and
    folded into wherever they actually belong once resolved). Two genuinely open questions moved
    into the new file: whether total EXE-packaging failure should change the final on-screen
    `[STATUS]` wording (recommended yes, not implemented pending confirmation), and the
    CLI-args-only-programs architecture question (tabled by the owner for a future dedicated
    discussion, not sized yet).
  - **Partial fix for CLAUDE.md Active Backlog item 7** (see that item's own updated entry above)
    landed in this same pass: `continue-on-error: true` added to 9 CI steps restricted to
    already-non-gating lanes, so one failing self-test scenario no longer hides its siblings'
    results within the same lane run. Does not touch the gating (`real`/`conda-full`) lanes, which
    remain deliberately deferred.

- **Refinement-pass fix on shipped requirement 9: the post-swap "did it work" check tested the
  wrong file, silently misreporting a failed swap as success.** Found via a self-directed
  refinement/code-review pass on the just-merged PR #370 (`:offer_optimized_build`), requested
  directly by the owner ("do some more refinement iterations on latest work"). The original check
  was `if not exist "dist\%ENVNAME%.exe"` after `move /y "dist\%HP_OPTBUILD_TMP%"
  "dist\%ENVNAME%.exe"` -- but `dist\%ENVNAME%.exe` is the DESTINATION, the already-working
  original EXE this subroutine exists to (maybe) replace, so it already exists BEFORE the move
  runs, success or failure alike. A same-volume `move /y` onto an existing destination is an
  atomic rename-replace: on success the SOURCE is consumed; on failure (e.g. an AV/indexer lock on
  the destination -- the exact hazard class already documented for `:try_embed_fallback`'s own
  `rd`/`move` swap, see `docs/agent-lessons-learned.md`) the whole operation is rejected and the
  source is left untouched, with the destination unaffected either way -- so the old
  destination-existence check could never actually detect a failed swap. A real failure would have
  been silently misreported as `[INFO] Optimized build succeeded and verified...`,
  `HP_NUITKA_FALLBACK_USED` would be wrongly set (incorrectly disabling
  `:hidden_import_recover`'s auto-recovery for what is still a PyInstaller-built EXE), and the
  leftover temp file would never be cleaned up (the old failure branch didn't route through the
  shared `:optbuild_cleanup` label either). Fixed by checking whether the SOURCE is gone instead,
  and by routing this failure through `:optbuild_cleanup` like every other failure branch (fixes
  the temp-file leak too). New test hook `HP_TEST_FORCE_OPTBUILD_SWAP_FAIL` (skips the real
  `move`, deliberately leaving the temp file in place to reproduce the exact "source still exists
  after move" failure signature without depending on an artificial OS-level file lock) and a new
  `swapfail` scenario in `tests/selfapps_optimized_build.ps1` (uv lane, non-gating, real Nuitka
  build + verify, like `accept`) prove the fix. See `docs/agent-interconnect.md`'s requirement 9
  section for the full trace. CLOSED by this pass.

- **AV-Safe Build Path requirement 9 (P1): the elective "want an optimized build too?" upsell
  after a normal successful PyInstaller build.** Owner explicitly greenlit this ("go ahead and
  do requirement 9 ... I personally want the optimized build") in the same message that
  explicitly DEFERRED requirement 5/Tier B (see the updated Active Backlog item 6 note above).
  New `:offer_optimized_build` subroutine (`run_setup.bat`, called from `:smokerun_ndjson` right
  after `call :run_postexec_checkpoint exe`, while `HP_EXE_EXIT` still holds this run's real
  outcome). Gated on `HP_NUITKA_FALLBACK_USED` being unset (skip if Tier A already ran -- the
  user already has an optimized build) and `HP_EXE_EXIT` genuinely `"0"` (skip on a failed/timed
  -out run). Reuses `:run_postexec_checkpoint`'s exact CI-safe 4-way auto-decline consent gate
  (`HP_TEST_OPTBUILD_ANSWER` override, then `HP_CI_LANE`/`NOINPUT`/`HP_NONINTERACTIVE`
  auto-decline, then interactive `set /p`) with the PRD's own suggested copy.

  **Strictly safer than Tier A's own build sequence, and deliberately so**: Tier A is free to
  delete-then-rebuild `dist\%ENVNAME%.exe` because the original PyInstaller build already
  failed there -- nothing working to lose. Requirement 9 runs in the OPPOSITE situation (a
  confirmed-working, already-smoke-tested EXE already exists), so it never touches the original
  until a replacement is PROVEN good: builds to a distinct temp filename
  (`%ENVNAME%.optimized_build.exe`), runs its own internal 30s-capped verification launch
  against that temp file (same `ProcessStartInfo`/`WaitForExit(30000)`/`Kill()`-on-timeout
  pattern `:run_exe_smokerun` already uses), and only on confirmed build-AND-run success does
  `move /y` swap it into place. Every failure branch deletes only the temp file and leaves the
  original completely untouched, with a plain-language "your app is still ready to use as-is"
  message -- matching requirement 7's plain-language, no-safety-framing messaging rule. On
  success, sets `HP_NUITKA_FALLBACK_USED=1` too (semantically accurate; harmless this late in
  the flow since hidden-import recovery has already completed for this pass).

  **Reactive-only Visual Studio hint added to both this subroutine's and `:try_nuitka_tier_a`'s
  failure paths, per direct owner question about whether Nuitka auto-detects an installed VS2022
  and whether to hint proactively or reactively.** Researched via Nuitka's own GitHub issue
  tracker (Nuitka/Nuitka#3317): confirmed Nuitka auto-detects an installed Visual Studio via the
  registry with no need for a Developer Command Prompt or `vcvarsall.bat` -- a plain VS2022
  install with the "Desktop development with C++" workload (which includes a Windows SDK by
  default) should have Nuitka "just work" via MSVC with zero extra setup. Per the owner's own
  framing ("we said probing wasn't a great idea... blindly proactive, failure reactive?"), the
  hint is a static `[WARN]` line that only prints AFTER Nuitka's own build already failed --
  never a proactive nag on a successful run, and no new detection/fingerprinting logic added
  (research Finding 2 already argued against that class of probing; Tier A's own design already
  committed to trusting Nuitka's internal discovery entirely).

  New test hooks `HP_TEST_OPTBUILD_ANSWER`/`HP_TEST_FORCE_OPTBUILD_FAIL` and
  `tests/selfapps_optimized_build.ps1` (uv lane, non-gating, `self.optbuild.offer`, three
  scenarios via `OPTBUILD_SCENARIO`): `accept` proves a REAL Nuitka build succeeds, verifies,
  and swaps in; `forcefail` proves a forced failure leaves the original PyInstaller EXE
  completely untouched and still runnable (re-executed directly by the test after the bootstrap
  completes, not just checked for existence); `decline` proves the default/CI path shows the
  prompt but never attempts a build. See `docs/agent-interconnect.md`'s new "AV-Safe Build Path
  requirement 9" section for the full design rationale. CLOSED by this pass.

- **Refinement pass on shipped Tier A: real bug found and fixed -- `:hidden_import_recover` had no
  guard against rebuilding via PyInstaller against a Nuitka-built EXE.** While doing a requested
  refinement/code-review pass on the just-merged Tier A work (PR #369; no other actionable work was
  open at the time), traced `:hidden_import_recover` (REQ-016 Slice 2, the `--hidden-import`
  auto-recovery loop) and found it had zero awareness of `HP_NUITKA_FALLBACK_USED` -- it would
  unconditionally re-run the EXE, scan for a fixable `ModuleNotFoundError`, and rebuild via
  `PyInstaller -y --onefile ... --hidden-import=X` regardless of whether `dist\<env>.exe` was
  actually built by PyInstaller or by Nuitka (Tier A). Since Tier A only ever runs after the
  ORIGINAL PyInstaller build already failed once in the same invocation, this PyInstaller rebuild
  inside the recovery loop had a real chance of reproducing the exact failure Tier A exists to
  route around (e.g. AV quarantine), or at minimum silently discarding a working Nuitka-built EXE
  for a PyInstaller rebuild attempt of undefined outcome. Confirmed `HP_NUITKA_FALLBACK_USED` is
  safely readable at `:hidden_import_recover`'s entry (process-global; the file's only `setlocal`
  is at the very top, disabling delayed expansion, with no scoping boundary in between). Fixed
  with an early-skip guard (`if defined HP_NUITKA_FALLBACK_USED exit /b 0`, with a log line)
  placed right after the subroutine's existing `if not exist "dist\%ENVNAME%.exe" exit /b 0`
  early-return -- deliberately a SKIP, not a Nuitka-aware repair (wiring up Nuitka's own
  `--include-module`/`--follow-import-to` missing-import mechanism is out of scope for this fix).
  New regression test `tests/selfapps_nuitka_tiera_hidden_skip.ps1` (uv lane, non-gating,
  `self.exe.tiera.hidden_skip`, wired into `batch-check.yml` right after the sibling Tier A step):
  forces Tier A via `HP_TEST_FORCE_PYINSTALLER_FAIL=1`, lets a real (unforced) Nuitka build
  succeed, and has the stub app print a FABRICATED, exact-format
  `ModuleNotFoundError: No module named 'nuitka'` to stderr before exiting 1 -- `nuitka` is
  guaranteed pip-installed into the exact build interpreter Tier A just used, so
  `~hidden_import_scan.py`'s `find_spec` gate would treat this as genuinely fixable if the skip
  guard were missing or broken; since the scanner is a pure text-based regex match against
  captured process output (not real Python introspection), this fabricated signal deterministically
  constructs the exact trigger condition the guard must catch, without depending on fragile,
  non-deterministic genuine Nuitka missing-import behavior. Asserts the new skip log line fires,
  the OLD `[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=` rebuild line does NOT, and
  `~bootstrap.status.json` still reads `state=ok` (the user program's own non-zero exit is not a
  bootstrapper failure). See `docs/agent-interconnect.md`'s new "AV-Safe Build Path Tier A and
  hidden-import auto-recovery" section for the full interaction and a note that any FUTURE
  alternate-build-tool path (e.g. Tier B) needs this same class of guard. CLOSED by this pass.

- **AV-Safe Build Path requirements 2-4: automatic dispatch + Tier A (real Nuitka fallback build
  in the existing environment, no reprovisioning).** New `:try_nuitka_tier_a` subroutine
  (`run_setup.bat`, placed right before `:die`) is `call`ed (never `goto`'d, so it's safe
  regardless of the caller's block depth) from all three of requirement 1's converging failure
  points (forced-fail test hook, real PyInstaller build errorlevel, missing/vanished output --
  requirement 3's single trigger category) before any of them falls through to `:die`. It
  installs Nuitka into the CURRENT environment (uv or pip, matching `HP_ENV_MODE` -- no
  reprovisioning, per requirement 4), then runs `python -m nuitka --onefile
  --assume-yes-for-downloads --remove-output --output-dir=dist -o "<env>.exe" <entry>`, doing
  no independent compiler probing (Nuitka's own MSVC-then-MinGW64 discovery is trusted
  entirely, exactly as requirement 4 specifies -- the same "don't fingerprint" principle
  research Finding 2 already established). `--assume-yes-for-downloads` is load-bearing: without
  it, Nuitka can prompt interactively to confirm its own dependency downloads, which would hang
  both CI and a real non-interactive double-click run -- a Prime Directive violation. On success,
  `HP_NUITKA_FALLBACK_USED=1` is set and the produced `dist\<env>.exe` is treated exactly like a
  PyInstaller-produced one by the rest of the pipeline; no special-casing needed downstream (the
  existing warn-file/smoke-test code already degrades gracefully when no warn file exists, and
  the EXE smoke-test itself doesn't care which tool built the file).

  **Verified 2026-07-20 against real Windows CI (run 29788624195, `self.exe.build.tiera`,
  uv lane): the Nuitka CLI flags above are correct as written.** No Windows machine was
  available in this sandbox to confirm them before shipping, so this was written from
  documented Nuitka CLI knowledge only -- the first real run genuinely built
  `dist\_selftest_nuitka_tiera.exe` via Nuitka 4.1.3, ran it, and the stub app's stdout came
  through cleanly. The FIRST real run of this new test did fail, but the root cause was a test
  bug, not a `run_setup.bat`/Nuitka-flags bug: `tests/selfapps_nuitka_tiera.ps1` hardcoded the
  expected EXE path as `dist\~selftest_nuitka_tiera.exe` (the literal tilde-prefixed workDir
  name) instead of the sanitized `dist\_selftest_nuitka_tiera.exe` that `run_setup.bat`'s
  ENVNAME derivation actually produces (every non-alnum/underscore/hyphen character, including
  the leading `~`, is replaced with `_` -- see run_setup.bat lines ~350-356), and it searched
  the console-redirected bootstrap log for the app's stdout instead of the `~run.out.txt`
  capture file where `:run_exe_smokerun` actually writes it. Fixed to compute the sanitized
  name the same way `selfapps_collect.ps1`/`selfapps_envsmoke.ps1` already do, and to read
  `~run.out.txt` directly. Second run (29788624195) passed clean.

  New test hook `HP_TEST_FORCE_NUITKA_FAIL` (forces Tier A to fail deterministically, without a
  real Nuitka attempt) and a new `tests/selfapps_nuitka_tiera.ps1` (uv lane, deliberately
  non-gating for its first landing -- promote once proven stable across several real runs,
  matching this repo's established lane-graduation pattern) prove the Tier A SUCCESS path for
  real: forces PyInstaller to "fail," lets a genuine Nuitka build run, and asserts the fallback
  succeeds, `dist\<env>.exe` exists, the stub app's own stdout came through the existing
  (unmodified) EXE smoke-test path, and `~bootstrap.status.json` reads `state=ok` (a successful
  fallback is bootstrap SUCCESS, not the error case). `tests/selfapps_pyinstaller_fail.ps1`
  (requirement 1's test, real/conda-full, gating) was updated to ALSO set
  `HP_TEST_FORCE_NUITKA_FAIL=1`, so it keeps testing tier EXHAUSTION (both PyInstaller and the
  fallback fail) rather than being accidentally saved by a real fallback success once Tier A
  existed -- without this update, that test would have silently started testing a different
  scenario than it was designed for. Tier B (requirement 5, reprovisioned pinned-3.12
  environment via the existing provider chain) is NOT implemented yet; a Tier A failure
  currently falls through to the pre-existing `:die` path, unchanged from before this feature.

- **PyInstaller build-failure silently masked as success -- real, independent correctness bug,
  found while scoping AV-Safe Build Path (item 6) requirement 1's failure-simulation tests, fixed
  before those tests were written.** Traced (via a dedicated static-analysis pass, since no
  Windows machine is available in this sandbox) exactly what happens today when the PyInstaller
  build command genuinely fails (nonzero exit, or never produces `dist\<env>.exe`): the two
  `call :die "..."` sites at that call site only return from `:die`'s own `call` frame (see
  `docs/agent-lessons-learned.md`'s `:die` entry) -- nothing downstream re-checks the outcome, so
  execution falls through to a misleading `[INFO] PyInstaller produced...` log line,
  `:run_exe_smokerun` silently no-ops (EXE missing), `:verify_no_exe_interpreter` runs the raw
  entry via the interpreter instead, and `:after_cascade_decision` unconditionally overwrites
  `~bootstrap.status.json` back to `state=ok` and the process exits 0 -- completely masking a
  build failure the user had explicitly consented to (`HP_BUILD_OK`). Fixed by setting
  `HP_BOOTSTRAP_STATE=error` at the PyInstaller call site (in `:run_entry_smoke`'s else-branch),
  mirroring the pre-existing, already-correct precedent in the SAME subroutine's
  preflight-failure branch. Deliberately restructured as nested `if/else` (not `goto`+labels)
  to avoid introducing labels inside the enclosing parenthesized block -- see the inline comment
  at the fix site and `docs/agent-lessons-learned.md`'s "Provider-cascade dispatch is goto-based
  on purpose" entry for why that specific combination (goto targeting a label inside the same
  block) is a known risk class in this file; `call`/`if errorlevel`/`if defined`/`set` are all
  already-confirmed runtime-safe inside a block, so the fix needed no goto at all. Two new test
  hooks (`HP_TEST_FORCE_PYINSTALLER_FAIL`, `HP_TEST_FORCE_OUTPUT_VANISH`) and a new
  `tests/selfapps_pyinstaller_fail.ps1` (two scenarios, real/conda-full lanes, matching
  `selfapps_exefail.ps1`'s sibling pattern) assert the fix: `~bootstrap.status.json` genuinely
  reads `state=error`, not silently overwritten (the process's own exit code stays 0 either way
  -- `:success`'s `exit /b 0` runs unconditionally regardless of `HP_BOOTSTRAP_STATE`, matching
  the pre-existing `selfapps_preflight.ps1` precedent's own contract, which never checks exit
  code either; caught and corrected in this same PR after the first real-CI run's `bootstrapExit`
  detail showed 0, initially misread as a test failure before tracing it to an over-specified
  assertion, not a bug in the fix itself). This
  simultaneously ships requirement 1's first fixture from `docs/prd-av-safe-build-path.md`
  ("a generic PyInstaller build failure... confirmed [to fail] in the expected way") -- "the
  expected way" is now a correct, visible failure rather than the bug this entry describes; the
  second fixture (output vanishing immediately after creation, research Finding 2) ships in the
  same test file via the `output_vanish` scenario. No Tier A/B fallback logic exists yet; that's
  future work under item 6. CLOSED by this PR (this bug-fix slice only).

- **Post-ship refinement pass on the two-tier `autopep723` work (both PR #365/Tier 1 and PR
  #366/Tier 2, requested directly by the maintainer after both merged) -- one real bug found and
  fixed, plus closes out backlog items 5 and 8, both now fully satisfied by the shipped tiers.**
  - **Real bug: `tools/pvw_known_idempotent.py`'s retry paths were exposed to a live, still-open
    uv caching bug (astral-sh/uv#15156, "Cached Script Dependencies Not Properly Invalidated"),
    already documented in `docs/agent-lessons-learned.md` from an unrelated dev-testing repro but
    never checked against this specific shipped call site until now.** Read `autopep723`'s own
    source (`autopep723/__init__.py`'s `run_with_uv`, pulled from the local `uv` cache) and
    confirmed its default "run" mode shells out to `uv run` itself. `main()`'s "other nonzero" and
    post-strip-repair branches both call `persist()` (writes a NEW header via `uv add --script`)
    then immediately re-run the SAME entry file via `run_script()` -- exactly the
    change-then-rerun-same-filename sequence #15156 describes. Fixed by adding a `force_fresh`
    parameter to `run_script()` that sets `UV_NO_CACHE=1` in the subprocess env, applied ONLY to
    the two post-persist retry calls (the first attempt -- the common, successful case, since the
    whole premise of the flag is "trust me, my script already works" -- keeps normal caching for
    speed). `tests/test_pvw_known_idempotent.py` gained a dedicated `RunScript` class plus
    assertions in both retry-branch `MainDispatch` tests confirming the env split, so a future
    edit that drops `force_fresh` from either retry call site is caught in CI. Re-synced
    `HP_PVW_IDEMPOTENT` (had to trim several comments to restore budget under the CMD 8191-char
    line limit -- see `docs/agent-lessons-learned.md`'s budget table).
  - **Investigated and found NOT a bug, correctly consistent with pre-existing architecture**: Tier
    2's unconditional `copy /y` of the entry's (now-updated) PEP 723 header into `requirements.txt`
    (no `if not exist` guard, unlike Tier 1's additive merge) initially looked like a destructive
    overwrite risk for a multi-file app whose `requirements.txt` covers more than the entry file's
    own direct imports. Traced the pre-existing (pre-Tier-2) PEP-723-header-in-source and
    `pyproject.toml` paths (`run_setup.bat` ~line 1008-1119) and confirmed this repo already treats
    a PEP 723 header as the AUTHORITATIVE, self-contained dependency declaration for a script --
    both paths already do an unconditional overwrite of `requirements.txt` when active, by
    long-standing, deliberate design (matches PEP 723's own single-file-script intent). Tier 2 is
    correctly consistent with this existing precedence system, not a new hazard.
  - **One asymmetry noted, not fixed (too small/speculative to act on without a concrete report)**:
    the pre-existing PEP-723-header-in-source path also syncs `requirements.auto.txt` (line 1119)
    so dep-check's own next-run comparison stays aware of it; neither Tier 1 nor Tier 2 do this --
    both only ever touch `requirements.txt`. This is the SAME accepted trade-off Tier 1's own
    Closed Backlog entry already documents (a repeat-run's dep-check gate is scoped to what pipreqs
    itself finds, not the full `requirements.txt`; the unconditional pip-gap-fill step is what
    actually covers the gap in practice), so Tier 2 sharing it is consistent, not a regression.
  - **Backlog items 5 and 8 closed**: item 5 ("opt-in trust-me-idempotent fast-discovery mode")
    described exactly what Tier 2 (`HP_PVW_KNOWN_IDEMPOTENT`) now ships; item 8's own remaining
    open piece (README QuickStart, `tests/selfapps_pvw_quickstart.ps1` as its CI proof) is also
    fully shipped. Confirmed with the maintainer directly: the still-not-built standalone
    downloadable `pvw_quickstart.ps1` (a packaged-script alternative to the copy-paste README
    commands, for end users rather than CI) and the deferred `HP_QUICKSTART_MODE` `run_setup.bat`
    hook remain deliberately not pursued -- both were always recorded as optional fallbacks, not
    required scope, and nothing else was outstanding under either item.

- **Two-tier `autopep723` integration, Tier 2 (REQ-005.13, `HP_PVW_KNOWN_IDEMPOTENT`) -- an
  opt-in flag causing `run_setup.bat` to actually run the entry script live via `uvx autopep723
  <entry>` as execute-mode dependency discovery, now SHIPPED, same day as Tier 1 (below).** Full
  design at `docs/plan-autopep723-two-tier.md`'s Tier 2 section. Picked back up immediately once
  Tier 1's PR merged, satisfying this doc's own explicit sequencing dependency. Relocates
  README's already-shipped, already-tested "Just run it (and remember what it needed)" QuickStart
  logic into `run_setup.bat` itself -- same exit-code branching (0 = ran clean, best-effort
  persist; 2 = malformed header, strip-and-retry-once; other nonzero = fill in what's missing
  without stripping, retry once), not a new mechanism.

  **Hook point: right after `:determine_entry` returns (`run_setup.bat` ~line 980), before the
  pyproject.toml/PEP 723 header/pipreqs block even begins** -- earlier than Tier 1's own insertion
  at `:after_pipreqs_run`, since Tier 2's whole premise is "skip static discovery, use execution
  instead," so it must run before any static-analysis-based source gets a chance to populate
  `requirements.txt` first. Does not need its own PEP-723-awareness: `uvx autopep723 <entry>`
  already respects an existing header on its own.

  **Real design wrinkle resolved during the code-grounded pass (before implementation): `uv add
  --script` only updates the PEP 723 header, not `requirements.txt`.** A naive "run, persist,
  continue" implementation would have left `requirements.txt` empty, since everything downstream
  (the dep-check fast path, heuristic augmentation, the actual install step) all operate on
  `requirements.txt`, never the header directly. Fixed by reusing the ALREADY-EXISTING
  `:extract_pep723_requirements` subroutine (the same one the pre-existing-header case already
  uses) to re-extract the just-updated header straight into `requirements.txt` -- no second
  requirements.txt-writing mechanism was added.

  **Deliberately does NOT set `HP_SKIP_PIPREQS`** -- additive layering, not a replacement:
  pipreqs and Tier 1's own `autopep723 check` merge still run normally afterward, catching
  anything a single execution path didn't happen to exercise (e.g. a conditionally imported
  module whose branch wasn't hit during this particular run). Mirrors Tier 1's own "augment,
  never replace" philosophy.

  **A real, non-hypothetical bug was found and fixed before shipping, via direct reasoning about
  file-descriptor inheritance, not via a test failure.** The Tier 2 helper's `run_script()`
  deliberately inherits stdio for the "run the user's script live" step, so the user sees their
  own program's output exactly like a normal `python entry.py` run. The first draft had the batch
  caller redirect the helper's stdout to a result file to capture its printed result marker --
  copying `tools/pep723_writeback.py`'s proven pattern verbatim. But `pep723_writeback.py` never
  inherits a child's stdio (its own `uv add --script` call is always `capture_output=True`),
  while Tier 2's helper does. Redirecting the OUTER Python process's stdout to a file would have
  meant the INNER `uvx autopep723 <entry>` child process -- which inherits whatever stdio its own
  parent has -- silently redirected its stdout into that same result file too, swallowing the
  user's live script output instead of showing it on the console. Fixed by moving the helper's
  own result marker to **stderr** and having the batch caller redirect only stderr, leaving
  stdout completely unredirected end-to-end. `tests/selfapps_pvw_idempotent.ps1` asserts the stub
  app's own `print()` output appears directly in the bootstrap log, specifically to guard against
  this exact regression recurring.

  **What shipped**: `tools/pvw_known_idempotent.py` (new, canonical source for
  `HP_PVW_IDEMPOTENT`) -- `strip_pep723_block` deliberately duplicated (not imported) from
  `tools/pep723_writeback.py`'s function of the same name, since independently-decoded
  single-file embedded payloads cannot share imports at runtime. The `:pvw_known_idempotent_run`
  subroutine, gated on `HP_PVW_KNOWN_IDEMPOTENT` defined AND `HP_ENV_MODE=uv` AND `HP_ENTRY`
  defined AND the derived `uvx.exe` path existing on disk -- never gates the lane; any failure
  (the run itself failing even after its one retry, the helper payload failing to write) falls
  back gracefully to the Default Path. `tests/test_pvw_known_idempotent.py` (16 unit tests:
  `strip_pep723_block`, dependency-name extraction from `autopep723 check` output, the
  discover-and-persist sequence, and all three exit-code branches via a mocked `subprocess.run`
  that dispatches on argv shape, plus `PayloadSync`). `tests/selfapps_pvw_idempotent.ps1` (new,
  uv lane, non-gating): `HP_SKIP_PIPREQS=1` isolates Tier 2's own contribution (test-level only,
  not how Tier 2 behaves in production), asserts the discovery-succeeded log line, the stub app's
  own stdout passthrough, `requirements.txt` population, and that the app actually builds and
  runs afterward. Doc updates: README's new REQ-005.13 section and `HP_PVW_KNOWN_IDEMPOTENT`
  table row, `docs/agent-ndjson.md`'s new `self.pvw_idempotent.discovery` row registration,
  `docs/agent-interconnect.md`'s new "HP_PVW_KNOWN_IDEMPOTENT execute-mode discovery" section, and
  `docs/plan-autopep723-two-tier.md` itself updated to SHIPPED status throughout -- both tiers of
  that doc are now fully implemented. CLOSED by this PR.

- **Two-tier `autopep723` integration, Tier 1 (REQ-005.12) -- "add `autopep723 check` alongside
  `pipreqs` in the Default Path discovery phase," now SHIPPED.** Full design at
  `docs/plan-autopep723-two-tier.md`; this entry is the historical record of the whole
  investigation through Tier 1 shipping (Tier 2, `HP_PVW_KNOWN_IDEMPOTENT`, shipped the same day
  -- see the entry directly above). Originated from a user-supplied third-party spec proposing (a) this
  Tier 1 discovery augmentation and (b) an opt-in Tier 2 runtime-discovery flag -- the concrete
  design that supersedes `plan-pvw-quickstart.md`'s deferred "Shape B." Found and fixed two real
  problems in the source spec before it could be treated as implementation-ready, both via direct
  testing and source-code reading, not just review:
  - **The proposed v1 command (`uvx autopep723 check . > requirements.autopep.txt`) was broken as
    written.** `autopep723` is strictly single-file (confirmed via its own argument parser -- no
    directory/glob mode exists at all); passing `.` hits `Path.read_text()`'s
    `IsADirectoryError`, silently caught and turned into an empty result with **exit code 0** --
    confirmed directly, reproducibly. The spec's own "autopep723 fail != lane fail" fallback
    would never even trigger, since nothing ever reports nonzero. As designed, the merge would
    have been a permanent no-op on every run. Fixed by targeting the resolved entry file
    (`%HP_ENTRY%`) as shipped, never a directory.
  - **The spec's central claim ("autopep723 check never reports delta, environment-independent")
    is false as a blanket statement -- confirmed by reading `autopep723`'s actual source (pulled
    from the local `uv` cache) and by direct reproduction: a venv with only `requests`
    pre-installed running `autopep723 check` on a script importing `requests` + `click` silently
    dropped `requests` from the output.** Root cause: `get_builtin_modules()` unions
    `sys.builtin_module_names` with `pkgutil.iter_modules()`, which walks whatever Python process
    is actually running the tool -- any package already installed there gets misclassified as
    "not third-party." Confirmed this is invocation-method-dependent, not universal: `uvx
    autopep723 check` is immune to an active `VIRTUAL_ENV` (confirmed directly) but still
    vulnerable to a leaked `PYTHONPATH` (also confirmed directly) -- and a *direct* interpreter
    invocation (no `uvx`) is not protected at all. Full empirical trail lives in
    `docs/agent-lessons-learned.md`'s autopep723 section since it's a standalone, reusable fact,
    not specific to this one plan. **Practical resolution, shipped as designed**: `run_setup.bat`
    invokes via `uvx` (resolved as `%HP_UV_EXE:uv.exe=uvx.exe%`, not a bare PATH lookup or a path
    derived from `HP_UV_BIN` directly -- the latter would silently break under the `PVW_UV_EXE`
    super-user override), and `run_setup.bat` already clears `PYTHONPATH`/`PYTHONHOME` well before
    the discovery phase (REQ-010) -- so Tier 1 as shipped is safe from this hazard as scoped. This
    also resolves, not just caveats, a mystery the original requester raised: a collaborator
    suspected this exact delta bug, lost the specific repro, and couldn't tell if it was a
    miscommunication -- it wasn't; the bug is real, it's just conditional on invocation method in
    a way that made it easy to "fix" by accident between test sessions without anyone identifying
    why.

  **Code-grounded pass (2026-07-19), then implementation (2026-07-20).** Traced the exact
  `run_setup.bat` insertion point (`:after_pipreqs_run`'s `requirements.txt`/
  `requirements.auto.txt` diff computation, before the dep-check fast-path setup), confirmed
  `%HP_ENTRY%` is reliably set there across every reachable code path (one narrow pre-existing
  edge case -- AppleDouble `._`-prefixed shadow files as the only top-level `.py` match -- handled
  via a defensive `if defined HP_ENTRY` guard, not a design change), and settled the merge-target
  question (`requirements.txt` only, not `requirements.auto.txt` -- the existing unconditional pip
  gap-fill step already covers the correctness gap that would otherwise create, with one
  documented, accepted trade-off on conda-vs-pip installation path for a narrow repeat-run case).
  `tests/selfapps_pvw_quickstart.ps1` (Closed Backlog, above) served as the isolated, already-
  passing dry-run proof that the underlying `uv`/`autopep723` mechanics work correctly in this
  exact CI environment, sequenced before this tier's own bootstrapper-integrated code, exactly as
  intended.

  **What shipped**: `tools/autopep_merge.py` (new, canonical source for `HP_AUTOPEP_MERGE`) --
  a small, dedicated helper doing case-insensitive set-union against `requirements.txt`'s existing
  top-level names, plus a defensive trailing-newline repair before appending; always exits 0
  (best-effort, additive-only, never removes or reorders existing content). The `run_setup.bat`
  insertion sits between the REQ-005.5 diff-computation log line and the dep-check fast-path
  reset, gated on `HP_ENV_MODE=uv` AND `HP_ENTRY` defined AND the derived `uvx.exe` path existing
  on disk AND `HP_SKIP_AUTOPEP_DISCOVERY` unset (new suppression-only flag, REQ-019-compliant).
  `tests/test_autopep_merge.py` (18 unit tests: PEP-723-style dependency-array extraction
  including the no-dependencies-key and malformed/error-output cases, name-collision dedup,
  missing-file handling for both inputs, trailing-newline repair, and `PayloadSync`).
  `tests/selfapps_autopep_discovery.ps1` (new, uv lane, non-gating): isolates Tier 1's own
  contribution by setting `HP_SKIP_PIPREQS=1` so the merged `requirements.txt` is populated by
  autopep723 discovery alone (no other source present), then asserts the app actually builds and
  runs from it -- not just that a log line appears. Doc updates: README's new REQ-005.12 section
  and `HP_SKIP_AUTOPEP_DISCOVERY` table row, `docs/agent-ndjson.md`'s new
  `self.autopep_discovery.merge` row registration, `docs/agent-interconnect.md`'s new "autopep723
  discovery merge (REQ-005.12, Tier 1)" section (documents the `:after_pipreqs_run` neighbor
  dependency and the `HP_UVX_EXE`-derivation-from-`HP_UV_EXE` decision), and
  `docs/plan-autopep723-two-tier.md` itself updated to SHIPPED status throughout.

  What held up unchanged from the original spec review: `uv add --script` over `autopep723 add`
  for writeback (already established elsewhere), UV-only writeback (no other package manager has
  an equivalent mechanism), and Tier 2's exit-code branching being a relocation of README's
  already-shipped, already-tested QuickStart logic rather than a new mechanism -- confirmed true
  when Tier 2 shipped the same day (see the entry directly above). CLOSED by this PR (Tier 1
  only; Tier 2 shipped separately, same day).

- **PVW QuickStart CI dry-run test (`tests/selfapps_pvw_quickstart.ps1`, new, uv lane only)**:
  requested directly by the maintainer as "a good isolated dry run for the next two before any
  bootstrapper integration" -- i.e. proof, in real CI, that the underlying `uv`/`autopep723`
  mechanics README's "PVW QuickStart" section documents actually work as written, BEFORE
  `docs/plan-autopep723-two-tier.md`'s Tier 1 and Tier 2 build bootstrapper-integrated logic on
  top of the same mechanics. Two scenarios (`QUICKSTART_SCENARIO=check`/`run`), each copying the
  relevant README command close to verbatim (the "spaced out" form for `run`, filename
  substituted only) -- including README's own `irm https://astral.sh/uv/install.ps1 | iex`
  uv-acquisition line, so the test is self-contained and does not depend on any other CI step's
  PATH state (`run_setup.bat`'s own uv download is process-local PATH, invisible to a separate
  PowerShell CI step). Not a `run_setup.bat` test at all -- standalone `uv`/`autopep723` usage
  only. `check` validates the read-only `uvx autopep723 check <file>` command (exit 0, dependency
  discovered, file byte-for-byte unchanged) -- this is the exact call Tier 1 will make against
  `%HP_ENTRY%`. `run` validates the full persist-on-success one-liner (script's own stdout came
  through, proving real execution; success message printed; PEP 723 header now contains the
  dependency; no `.bak` left behind on the clean-header path) -- this is the exact logic Tier 2's
  `HP_PVW_KNOWN_IDEMPOTENT` relocates into `run_setup.bat`. Verified locally before shipping: the
  underlying `uv`/`autopep723` round-trip (check -> extract dependency names via regex -> `uv add
  --script`) reproduced directly against a real `uv` 0.8.17 binary, then the actual `.ps1` file's
  own logic re-verified end-to-end via `pwsh` (both scenarios, `pass:true`, real NDJSON rows) --
  the only piece that could not be locally verified is the `irm | iex` uv-acquisition line itself,
  blocked by this sandbox's proxy restrictions on `releases.astral.sh`/`github.com` (identical
  limitation to every other network-dependent CI step in this repo, e.g. Miniconda/embed-Python
  downloads -- not something local testing has ever been able to cover). **Found and fixed one
  real scanner-compatibility bug before shipping**: the first draft computed the NDJSON row id
  once into a `$ndjsonId` variable and passed it via `-Id $ndjsonId` at both call sites --
  `tools/check_ndjson_registry.py`'s PowerShell scanner only matches a LITERAL `-Id '...'` string
  at the call site (documented in `selfapps_pep723_writeback.ps1`'s own `Write-Pep723Row` comment,
  which this file should have followed from the start), so the scanner reported both new rows as
  "registered in docs but no matching code emission site found" on the very first
  `check_ndjson_registry.py` run. Fixed by branching on `$scenario` and using a literal `-Id`
  string in each branch instead -- confirmed the registry check goes clean afterward. Wired into
  `batch-check.yml` as two new non-gating steps (own `continue-on-error: true` each, matching the
  sibling PEP 723 write-back steps' established per-step pattern) right after the write-back
  block. `docs/agent-ndjson.md` updated with the two new row IDs in the same commit. Deliberately
  does not add explicit `upload-artifact` path entries for this test's scratch directories (unlike
  most sibling tests) -- there is no `run_setup.bat` bootstrap log to capture here, and the NDJSON
  `details` field already carries the load-bearing evidence (exit codes, stdout matches, the exact
  success/failure message); the full-tree `diag-selftest-*` artifact still captures everything at
  a coarser level if ever needed. Distinct from the still-not-built "standalone downloadable
  `pvw_quickstart.ps1` file" mentioned in Active Backlog item 8's history (a packaged script FOR
  END USERS to run themselves) -- this is a CI test, not a user-facing deliverable. CLOSED by this
  PR.
- **`embed_pyver_check.py`'s unreachable "fellback" tag for above-ceiling requests (Active
  Backlog item 2)**: `main()`'s second early-return (after `resolve_table_entry`, firing when the
  resolved `minor` equals `LATEST_MINOR`) previously always wrote `"unchanged|{minor}"`, even
  when `resolve_table_entry` reached that branch via its own fallback path (`fell_back=True` --
  an above-ceiling request, e.g. `python>=3.99`). Confirmed via `ResolveTableEntry`'s existing
  tests that this early-return is ONLY reachable through the fallback path (an exact match for
  `LATEST_MINOR` is already intercepted by `main()`'s first early-return, one guard clause
  earlier) -- so `fell_back` is always `True` here, and the fix writes `"fellback|{minor}"`
  unconditionally rather than adding a now-always-true conditional. This makes the
  `:embed_pyver_check_tagcheck` WARN (`run_setup.bat`, "requested Python not in embed table;
  using ... instead") reachable for an above-ceiling request too, matching the below-floor
  request's already-correct behavior -- purely a diagnostic-visibility fix, the actual behavior
  (falling back to latest, no swap needed) is unchanged either way. Added `MainDispatch` to
  `tests/test_embed_tier.py` (3 new tests) exercising `main()`'s two early-return branches
  directly, including the specific regression this fix targets
  (`test_above_ceiling_request_is_fellback_not_unchanged`); the actual swap path (exact in-table
  match or below-floor fallback) is untouched by this fix and already has real end-to-end CI
  coverage via `self.embed.fallback.real`, so it wasn't re-tested here with mocked network calls.
  **Hit the CMD 8191-char line-length budget for real while writing this**: an initial, more
  verbose comment explaining the fix pushed `HP_EMBED_PYVER_CHECK`'s line to 8395 chars (204 over
  budget) -- trimmed to a 2-line comment, landing at 452-char margin. Re-encoded and re-synced
  `run_setup.bat`'s `HP_EMBED_PYVER_CHECK` line; `test_embed_tier.py`'s existing
  `BatchPythonConsistency`/`PayloadSync` tests confirm the batch-side constants and payload stay
  in sync. CLOSED by this PR.
- **`HP_DETECT_VISA` false-positive regex fix (Active Backlog item 10, found during the payload
  promotion above, fixed in its own isolated commit per that entry's own stated precedent)**:
  `PATTERNS` in `tools/detect_visa.py` now anchors on the FULL module name (`pyvisa`/`visa`) with
  a trailing `\b`, instead of the truncated `pyvis`/`vis` prefixes that previously had no boundary
  at all. **The exact regex shipped differs from the backlog entry's own literal suggestion, and
  deliberately so**: that entry proposed adding `\b` immediately after the truncated prefixes
  (`pyvis\b`, `vis\b`) -- verified directly, before writing any code, that this literal suggestion
  is wrong and would have introduced a regression: `\b` only matches at a word/non-word character
  transition, and there is no such transition between "vis" and the "a" in "visa" (both are word
  characters), so a `vis\b` pattern fails to match the genuine, already-tested `import visa` case.
  The correct fix anchors the boundary after the COMPLETE correct word instead of after a
  truncated prefix (`pyvisa\b`, `visa\b`) -- confirmed via direct regex testing before implementing
  that this excludes all three cited false positives (`import pyvista`, `import vision`,
  `import pyviscoelastic` -- none of these contain "pyvisa"/"visa" as a literal substring, so the
  fix rejects them structurally, not just via the boundary) while still matching every existing
  true-positive case (`import pyvisa`, `from pyvisa import ...`, `import visa`) AND a dotted
  submodule import (`import pyvisa.constants`, `from pyvisa.constants import ...` -- `\b` still
  matches before a non-word `.` character). `tests/test_detect_visa.py`'s
  `test_import_pyvista_false_positive_documented_not_fixed` flipped to
  `test_import_pyvista_false_positive_fixed` (now asserts `"0"` instead of `"1"`) exactly as that
  entry predicted; added `test_import_vision_false_positive_fixed`,
  `test_import_pyviscoelastic_false_positive_fixed`, and `test_dotted_submodule_import_still_matches`
  as new coverage (15 total tests, up from 12). Re-encoded and re-synced `run_setup.bat`'s
  `HP_DETECT_VISA` line (4958-char margin under the CMD 8191-char budget). Audited
  `tests/selfapps_pyvisa.ps1` (the only other test file referencing pyvisa/NI-VISA behavior) and
  confirmed it only ever uses plain `import pyvisa`, unaffected by the fix. CLOSED by this PR.
- **Mac-garbage filter for entry detection (first of the two Cross-platform pre-flight checks
  items, see the remaining System-directory guard bullet in Active Backlog)**: `tools/find_entry.py`'s
  `is_py()` now excludes `._`-prefixed names (macOS AppleDouble metadata files, e.g. `._main.py`)
  the same way it already excluded `~`-prefixed names, closing a real, common cross-platform
  papercut when a Windows user unzips something a Mac user zipped. `HP_FIND_ENTRY`'s embedded
  base64 payload re-synced to match (`tests/test_find_entry.py`'s `PayloadSync` test confirms
  byte-equality); new `test_apple_double_metadata_file_excluded` case added.
  **Investigated and found NOT applicable, no action needed**: the backlog item's original text
  also called for "skipping any `__MACOSX` directory in the same walk." Traced `main()`'s actual
  file discovery (`os.listdir(".")`, non-recursive, filtered through `is_py()`'s own
  `os.path.isfile()` check) and confirmed a `__MACOSX` folder -- a directory, not a `.py` file --
  can never match `is_py()` regardless of any prefix filter, since `os.path.isfile()` already
  excludes it by construction. No code change was needed or made for this half of the original
  item; noted here so it is not mistaken for an oversight later.
- **`HP_DETECT_PY` promoted to canonical-source-plus-`PayloadSync`-plus-logic-test (first of the
  six-payload backlog item, now shipped alongside `HP_PYPROJ_DEPS` below -- see Active Backlog item
  7 for the remaining four)**: extracted the
  embedded payload to `tools/detect_python.py`, verified the functional code is byte-identical to
  what was already embedded (only a new module docstring was added, mirroring the
  `find_entry.py`/`collect_submodules.py` header convention), then re-encoded and re-synced
  `run_setup.bat`'s `HP_DETECT_PY` line (well within the CMD 8191-char budget -- 1552-char
  margin). Added `tests/test_detect_python.py`: a `PayloadSync` byte-equality test plus 20 total
  unit tests covering `pep440_to_conda` (the same 6 cases already exercised by
  `tests/dynamic_tests.py`'s `dp.pep440` rows, kept in sync rather than duplicated, plus 5 new
  edge cases: single-digit `~=`, empty spec, unmatched clause, duplicate-clause dedup, comma
  whitespace tolerance) and `detect_requires_python`'s REQ-004 Tier 1/2 precedence (runtime.txt
  wins over pyproject.toml when both exist; pyproject.toml alone; missing files; a patch version
  in runtime.txt is accepted but not forwarded, since providers pin by minor only; an unparseable
  runtime.txt falls through to pyproject.toml rather than failing; single- vs double-quoted
  `requires-python` values). **Correction to this backlog item's own original wording**: it
  previously said `HP_DETECT_PY` had "zero automated test coverage of any kind" -- not quite
  accurate even before this change: `tests/dynamic_tests.py` already exercised
  `pep440_to_conda`/`detect_requires_python` via `dp.pep440`/`dp.detect.runtime`/
  `dp.detect.pyproject` rows (decoding and importing the embedded payload at real-CI runtime).
  That coverage is real but Windows-CI-only, has no `PayloadSync` guarantee, and is thinner than a
  dedicated suite -- the distinction this backlog item is actually drawing is the dedicated,
  cross-platform, locally-runnable `pytest tests/test_*.py` pattern, not "any coverage at all".
  Updated README's "Rebuilding embedded helper payloads" inventory table (7 of 16 payloads now
  have canonical source + `PayloadSync`, not 6; `HP_DETECT_PY` moved out of the zero-coverage
  list). CLOSED by this PR (only the `HP_DETECT_PY` slice; the item stays open in Active Backlog
  for the remaining five payloads).
- **`HP_PYPROJ_DEPS` promoted to canonical-source-plus-`PayloadSync`-plus-logic-test (second of the
  six-payload backlog item, now shipped alongside `HP_DETECT_VISA` below -- see Active Backlog
  item 7 for the remaining three)**: extracted
  the embedded payload to `tools/pyproj_deps.py`, verified byte-identical to what was already
  embedded (docstring-only addition), then re-encoded and re-synced `run_setup.bat`'s
  `HP_PYPROJ_DEPS` line (3410-char margin under the CMD 8191-char budget). Added
  `tests/test_pyproj_deps.py`: 16 total tests including a `PayloadSync` byte-equality check. The
  script is a flat, top-level `sys.exit()`-based script with no importable functions (unlike
  `find_entry.py`/`detect_python.py`), so it is exercised via subprocess, mirroring
  `test_find_entry.py`'s pattern. The interesting code path -- the regex-based char-by-char
  dependency-array walk that only runs when `tomllib` is unavailable -- turned out to be
  essentially untestable via the obvious route (this sandbox and real CI both run Python 3.11+,
  so `tomllib` is always importable, and a `[project].dependencies` key that tomllib CAN parse
  never falls through to the regex path at all). Solved by shadowing `tomllib` with a stub module
  (`raise ImportError` at import time) placed on `PYTHONPATH` ahead of the real stdlib path for
  the subprocess call -- confirmed directly that this reliably reproduces the script's own
  `try: import tomllib / except ImportError: tomllib = None` branch without needing an actual
  pre-3.11 interpreter. This let 9 of the 16 tests exercise the fallback path for real, including
  its own independent malformed-`[project`-header detection (a second, narrower TOML-parse-error
  check that only matters when tomllib itself isn't there to catch it) and the double-gate that
  `[tool.other].dependencies` never bleeds into a `[project]` table lacking its own key.
  **Found and documented, not fixed, a genuine pre-existing minor behavioral difference between
  the two paths**: tomllib properly unescapes a backslash-escaped quote inside a dependency
  string (`weird\"quote` -> `weird"quote`), but the regex fallback's char-by-char walk only skips
  over the escaped character to avoid stopping early -- it does not strip the backslash from the
  collected text, so the same input comes out as `weird\"quote` (backslash intact) via the
  fallback. Confirmed via direct side-by-side reproduction, not just inferred from reading the
  code. Left as-is and captured in a test asserting the fallback's actual behavior, since
  "fixing" it would be a functional change out of scope for a payload-promotion pass, and
  real-world `pyproject.toml` dependency strings essentially never contain escaped quotes.
  Updated README's inventory table (8 of 16 payloads now have canonical source + `PayloadSync`).
  CLOSED by this PR (only the `HP_PYPROJ_DEPS` slice; the item stays open in Active Backlog for
  the remaining four payloads: `HP_DEP_CHECK`, `HP_DETECT_VISA`, `HP_ENV_STATE`,
  `HP_FAILFAST_PROBE`).
- **`HP_DETECT_VISA` promoted to canonical-source-plus-`PayloadSync`-plus-logic-test (third of the
  six-payload backlog item, see Active Backlog item 7 for the remaining three)**: extracted the
  embedded payload to `tools/detect_visa.py`, verified byte-identical to what was already embedded
  (docstring-only addition), then re-encoded and re-synced `run_setup.bat`'s `HP_DETECT_VISA` line
  (5550-char margin under the CMD 8191-char budget). Added `tests/test_detect_visa.py`: 12 total
  tests including a `PayloadSync` byte-equality check, exercised via subprocess against a crafted
  temp project directory (mirrors `test_find_entry.py`'s pattern), covering positive/negative
  detection, the `~`/`.`-prefixed dir/file skip rules, and recursive nesting. **Found and
  documented, not fixed, a real (non-hypothetical) false-positive**: `PATTERNS`'s two regexes have
  no word-boundary anchor after the letters they match (`pyvis`/`vis`), so `import pyvista` (a
  real, popular, unrelated 3D-visualization package) -- confirmed via direct reproduction, along
  with `import vision`/`import pyviscoelastic` -- also matches, incorrectly triggering the REQ-008
  NI-VISA driver install branch for apps that have nothing to do with instrument control. Unlike
  the `HP_PYPROJ_DEPS` escape-quote finding (genuinely rare in practice), this one is realistically
  reachable by any user whose app happens to import a `vis`/`pyvis`-prefixed package -- added as a
  new Active Backlog item 10 (not fixed in this pass, consistent with the escape-quote precedent:
  a regex behavior change belongs in its own isolated, reviewable commit) with a concrete fix
  shape (add `\b` after each matched prefix) and the exact existing test that should flip once
  fixed. Updated README's inventory table (9 of 16 payloads now have canonical source +
  `PayloadSync`). CLOSED by this PR (only the `HP_DETECT_VISA` promotion slice; the false-positive
  fix itself is tracked separately as Active Backlog item 10; three payloads remain in item 7:
  `HP_DEP_CHECK`, `HP_ENV_STATE`, `HP_FAILFAST_PROBE`).
- **`HP_DEP_CHECK` promoted to canonical-source-plus-`PayloadSync`-plus-logic-test (fourth of the
  six-payload backlog item, see Active Backlog item 7 for the remaining two)**: extracted the
  embedded payload to `tools/dep_check.py` -- unlike the previous three payloads, this one already
  had a proper functional docstring (matching the `parse_warn.py` precedent), so the only addition
  was a short "canonical source" note for consistency with the other promotions, and it already
  exposes importable functions (`parse_lock`, `parse_reqs`, `main`) rather than being a flat
  script. Re-encoded and re-synced `run_setup.bat`'s `HP_DEP_CHECK` line (4604-char margin under
  the CMD 8191-char budget). Added `tests/test_dep_check.py`: 16 total tests -- `parse_lock`/
  `parse_reqs` take an explicit path argument, so most are called directly (name normalization,
  version-specifier and extras stripping, comment/blank-line skipping, missing-file handling);
  `main()` reads hardcoded relative filenames from the current directory, so its six run-vs-skip
  decision paths (no lock file, lock present with no reqs file, empty lock, empty reqs, all reqs
  covered, a genuinely missing req) are exercised via subprocess with `cwd` set to a crafted temp
  directory, mirroring `test_find_entry.py`'s pattern. Updated README's inventory table (10 of 16
  payloads now have canonical source + `PayloadSync`). CLOSED by this PR (only the `HP_DEP_CHECK`
  promotion slice; two payloads remain in item 7: `HP_ENV_STATE`, `HP_FAILFAST_PROBE`).
- **`HP_ENV_STATE` promoted to canonical-source-plus-`PayloadSync`-plus-logic-test (fifth of the
  six-payload backlog item, see Active Backlog item 7 for the remaining one)**: extracted the
  embedded payload to `tools/env_state.py` -- like `HP_DEP_CHECK`, already had a proper functional
  docstring, so the only addition was a short "canonical source" note, and it already exposes
  importable functions (`read_state`, `write_state`, `check_state`). Re-encoded and re-synced
  `run_setup.bat`'s `HP_ENV_STATE` line (4568-char margin under the CMD 8191-char budget). Added
  `tests/test_env_state.py`: 14 total tests. All three functions reference module-level
  `STATE_FILE`/`LOCK_FILE` constants (CWD-relative filenames, not parameterized) and read
  `ENVNAME`/`ENV_PATH`/`HP_ENV_MODE` from `os.environ`, so tests patch those module attributes
  (mirrors `test_detect_python.py`'s `RUNTIME_PATH`/`PYPROJECT_PATH` patching technique) and
  `os.environ` via `patch.dict(..., clear=True)` for full isolation from the real process
  environment, rather than invoking a subprocess. Covers `read_state`/`write_state` round-tripping
  (missing file, malformed JSON, env-var defaults) and `check_state`'s full run-vs-skip decision
  matrix (no state file, `ENVNAME` unset, name mismatch, non-conda `envMode`, empty `envPath`,
  missing `python.exe`, lock-size mismatch, and the all-valid skip case). Updated README's
  inventory table (11 of 16 payloads now have canonical source + `PayloadSync`). CLOSED by this PR
  (only the `HP_ENV_STATE` promotion slice; `HP_FAILFAST_PROBE` -- PowerShell, not Python -- is
  the only payload remaining in item 7).
- **`HP_FAILFAST_PROBE` promoted to canonical-source-plus-`PayloadSync`-plus-logic-test (sixth and
  final payload of the six-payload backlog item -- item 7 is now fully CLOSED)**: extracted the
  embedded payload to `tools/failfast_probe.ps1` -- the first PowerShell (not Python) canonical
  source in this promotion sequence, mirroring the `tools/embed_extract.ps1` precedent: the
  script itself never had a standalone source file or a header comment (only a `rem`-prefixed
  "decoded content" echo block sitting next to the `set "HP_FAILFAST_PROBE=..."` line in
  `run_setup.bat`, the same convention `HP_FAST_CHECK` still uses), so the new file's header
  comment folds that existing decoded-content block's information into a proper docstring-style
  comment (purpose, the never-`Kill()` invariant, the env-var input contract, the
  single-argument-only constraint on `HP_PROBE_ARGS`, and a "canonical source" pointer) while
  keeping the functional body byte-identical (diffed directly against the prior embedded payload
  before re-encoding). The redundant `rem HP_FAILFAST_PROBE decoded content:` echo block in
  `run_setup.bat` was removed in the same pass, since the same information now lives in the
  payload's own header comment (matching how `HP_EMBED_EXTRACT`/`HP_EMBED_PYVER_CHECK` already
  carry their own header comments instead of a separate `rem` block). Re-encoded and re-synced
  `run_setup.bat`'s `HP_FAILFAST_PROBE` line (4439-char margin under the CMD 8191-char budget).
  Added `tests/test_failfast_probe.py`: 8 tests, all exercised end-to-end via a real `pwsh`
  subprocess (no importable functions exist -- the script reads env vars and prints one line to
  stdout) covering fast-exit classification (`exceeded=0`) with both zero and nonzero exit-code
  passthrough, probe-window-exceeded classification (`exceeded=1`) with the true final exit code
  still captured after the unbounded second wait, default-vs-caller-specified output-path
  behavior, stdout/stderr capture content, and a `PayloadSync` byte-equality check
  (CRLF/LF-normalized, per the `.ps1` `.gitattributes` `eol=crlf` gotcha documented in
  `docs/agent-lessons-learned.md` "Embedded Helper Update Workflow"). **One test iteration
  surfaced a real, pre-existing constraint the script's own header comment already documented but
  this promotion pass is the first to have verified empirically**: an initial test attempt passed
  a two-token string (`"<path> 5"`) via `HP_PROBE_ARGS` expecting it to arrive as two CLI
  arguments; because `$si.Arguments = '"' + $rawArgs + '"'` wraps the ENTIRE string in one pair of
  quotes, the whole two-token string is handed to the child process as a single literal
  (nonexistent) filename, which the child interpreter reports as exit code 2 ("can't open file"),
  not as a second positional argument. This is not a bug -- it is exactly the documented
  single-argument-only contract -- but the test suite now asserts this behavior explicitly
  (`ArgsIsSingleArgumentOnly`) rather than silently avoiding it, so a future change to the
  quoting logic that relaxes or breaks this constraint is caught either way. Updated README's
  inventory table (12 of 16 payloads now have canonical source + `PayloadSync`; the "no automated
  test coverage" list is now empty -- `HP_CONDARC` remains static config, correctly out of scope).
  CLOSED by this PR (final slice of Active Backlog item 7; item removed from Active Backlog).
- **System-directory guard (second and final half of the Cross-platform pre-flight checks item --
  now fully closed)**: `run_setup.bat` now aborts early (`exit /b 1`, plain-language message) when
  the script root resolves under `%WINDIR%`, `%ProgramFiles%`, or `%ProgramFiles(x86)%`. Placed
  right after the existing OneDrive guard, matching its style, but check-and-abort rather than
  warn-only -- unlike the OneDrive/path-length/disk-space guards (marginal conditions that MIGHT
  fail), a script dropped into a system folder without elevation will essentially always fail on
  write-permission errors several steps in (creating `~setup.log`, `~uv_bin`, `.uv_env`, etc. right
  next to itself), so a clear early abort is kinder than a cryptic failure deep in the bootstrap.
  Detection uses `findstr` substring matching (mirrors the existing top-of-file UNC-path check)
  rather than the `%VAR:%OTHER%=%` nested-substitution idiom, since the latter has no existing
  precedent anywhere in this file and could not be verified against a real cmd.exe from this
  sandbox. **A real bug shipped in the first version and was caught by the new test's own first
  real CI run**: the `findstr /C:"..."` search patterns originally ended in a single backslash
  immediately before the closing quote (e.g. `%WINDIR%\"`), which per the standard Windows
  argv-parsing rule `findstr.exe` itself applies to its own command line, escapes the quote
  instead of closing it -- silently corrupting the search pattern (and swallowing the trailing
  `>nul`) so the guard could never fire. Fixed by doubling the trailing backslash
  (`%WINDIR%\\"`), which collapses to the intended single literal backslash while letting the
  quote close normally; verified against a direct Python re-implementation of the parsing rule,
  not just asserted. See `docs/agent-lessons-learned.md`'s new "A single trailing backslash
  before a closing quote silently corrupts a subprocess argument" entry for the full mechanism
  and a rule of thumb for future `findstr`/subprocess-argument call sites. `%WINDIR%`/
  `%ProgramFiles%` are each guarded with their own `if defined` check before the `findstr` call
  (an undefined variable would otherwise expand to an empty search pattern, which is not itself
  a false-positive risk here since `HP_SCRIPT_ROOT` always ends with a trailing backslash the
  pattern also requires, but the guard is kept anyway for defensive parity with the disk-space
  guard's own `if defined HP_FREE_GB` gate). `%ProgramFiles(x86)%` is copied to a plain-named
  `HP_PF86` variable first, since referencing `%ProgramFiles(x86)%` directly as a bare token inside
  `if defined ...` risks cmd's parser misreading the literal parentheses in the variable name.
  New behavioral test `self.warn.sysdir` (`tests/selftest.ps1`) creates a real directory under
  `%WINDIR%\Temp` (writable without elevation, unlike Program Files) and runs the bootstrapper
  there for real -- the same "real environmental trigger" approach as the existing OneDrive test,
  not a new `HP_TEST_FORCE_*` scaffolding flag -- asserting the `[ERROR] System-directory guard`
  message appears and the process exits 1. No static `harness.ps1` check was added, matching the
  existing precedent that the OneDrive/path-length/disk-space guards are covered by behavioral
  tests only, not a static string-presence check. CLOSED by this PR (both halves of the
  Cross-platform pre-flight checks backlog item are now shipped).
- **PEP 723 dependency write-back via `uv add --script` (REQ-005.11)**: full design at
  `docs/plan-pep723-writeback.md`. Promotes a resolved dependency set into the entry file's own
  PEP 723 header after a fresh, fully-successful uv-mode dependency install or a fully-successful
  warnfix repair round, so the pin becomes part of the user's own source rather than only a
  transient `requirements.txt`/lock file this bootstrapper manages. v1 scope: `HP_ENV_MODE=uv`
  only, best-effort/non-gating (any failure logs a `[WARN]` and the run continues unaffected).
  Shipped in two loops per the plan's own Part 4 sizing split:
  - **Loop 1** (PR #349): the two hook points (`:pep723_writeback`, called from `:lock_done` for
    the fresh trigger and from the warnfix repair block for the warnfix trigger), the
    `HP_UV_INSTALL_OK` confirmed-installed gate (reset on every `:after_env_mode_selection` entry
    for REQ-009 cascade re-entrancy), `tools/pep723_writeback.py` (embedded as
    `HP_PEP723_WRITEBACK`; strip-and-retry-once on uv's exit code 2, encoding pre-check, file-lock
    canary, `.py.lock` sidecar check), the `HP_SKIP_PEP723_WRITEBACK` opt-out flag (`[REQ-019]`),
    and the three simplest/most load-bearing test scenarios (`fresh`/`idempotent`/`skipflag`).
    A same-PR self code-review pass (Codex reviewer was unavailable/rate-limited; 8 parallel
    finder-angle agents against the diff) found and fixed two real, confirmed correctness bugs
    before merge: `read_packages()` didn't filter pip-only requirement-file directives (`-e`,
    `--hash`, ...), which exit uv's clap parser with the SAME code 2 used to detect a malformed
    existing header -- confirmed directly against a real `uv` binary that this would wrongly
    strip a perfectly valid header; and the exit-code-2 strip/retry path read the entry file in
    text mode without `newline=""`, silently collapsing all CRLF in the whole file to LF on both
    the stripped write and the restore-on-double-failure write, violating the feature's own "no
    line-ending normalization, anywhere, ever" rule -- also confirmed via direct repro. Also added
    a `subprocess` timeout on the `uv add --script` call (same bug class already fixed once for
    `tools/embed_pyver_check.py`) and reordered `:pep723_writeback`'s gate checks so a
    dependency-free (stdlib-only) app no longer gets a misleading "install did not fully succeed"
    log line.
  - **Loop 2**: the five adversarial-input test scenarios (`malformed`, `trailing_ws_malformed`,
    `existing_lockfile`, `non_utf8`, `warnfix`) and CI wiring. Confirmed via direct local testing
    (a scratch `pipreqs` 0.4.13 venv, built from wheels since docopt's sdist doesn't build under
    modern setuptools) that pipreqs crashes with an unhandled `UnicodeDecodeError` on non-UTF-8
    source regardless of a PEP 263 coding-cookie override -- a pre-existing limitation independent
    of this feature, not fixed here -- so the `non_utf8` and `warnfix` scenarios set
    `HP_SKIP_PIPREQS=1` to keep pipreqs away from the crafted entry file entirely. Wired into the
    non-gating `uv` lane only for this first CI pass (not the gating `real` lane) so these
    brand-new scenarios can prove out in real Windows CI without risking a merge block; promoting
    to `real`/`conda-full` is a natural follow-up once stable, mirroring how `self.cascade.exec`
    graduated from uv-lane-only. `pip-compile-multi` and `vulture` (researched alongside the
    original design) were **not applicable** to this repo and were not carried forward.
- **Three small hardening/cleanup items from the reorder's research pass**: (1)
  `:conda_base_update`'s inline `-Command` PowerShell (run_setup.bat, `:conda_base_update`)
  rewritten to raw .NET APIs (`[System.IO.File]::Exists`/`ReadAllText`/`WriteAllText`,
  `[datetime]::Now`) in place of `Test-Path`/`Get-Content`/`Get-Date`/`Set-Content` -- closes the
  plausible (never confirmed; masked by an existing `try/catch`) Windows PowerShell 5.1
  `Microsoft.PowerShell.Utility` module-autoload gap documented in
  `docs/agent-lessons-learned.md`'s "Prefer raw .NET types over Utility-module cmdlets" entry;
  notably `Get-Date` needed replacing too, not just `Get-Content`/`Set-Content`, since it lives in
  the same module and would fail identically if the gap were ever triggered here. All three
  PowerShell snippets stayed inline `-Command "..."` one-liners (not converted to an emitted
  `.ps1` file) since the .NET replacements use only single-quoted PowerShell string literals, so
  no literal `"` was ever introduced into the `-Command` body -- the quoting hazard that would
  have forced the more invasive `.ps1`-file conversion never actually applied once written out
  correctly. (2) `tests/harness.ps1`'s `batch.req009.provider_logs` static check extended with a
  5th pattern (`Embedded Python`) and retitled "all five provider log lines" -- it previously only
  asserted the pre-Tier-5 four providers (UV/Conda/Local venv/System Python), never covering
  embed's own `[BOOT] REQ-009: Selected Python provider: Embedded Python (python.org).` line even
  though embed shipped as a fifth tier. (3) The embed-tier declaration-block comment at
  run_setup.bat ~line 163 (`rem REQ-009 Tier 5: embeddable-Python fallback...`) still read "last
  resort when uv/conda/venv/system all fail" -- stale since the REQ-009 provider-chain reorder
  made embed execute 3rd (right after conda), not last; this was missed during that reorder
  because only the two dispatch-chain sections' own comments were fixed at the time, not this
  earlier declaration-block comment. Updated to state the tier's actual position and rationale
  (front-loaded so a pinned runtime.txt/pyproject.toml version is honored before falling back to
  ambient venv/system Python). All three were confirmed via a dedicated research pass (which also
  covered two items that stayed open -- see Active Backlog -- and the embed-fallback-URL question,
  which resolved to "no action" -- see Known Findings). CLOSED by this PR.

- **Embed version table quarterly-maintenance-checklist entry**: the Tier 5 design doc stated
  the `EMBED_PYTHON_TABLE` in `tools/embed_pyver_check.py` should refresh on the same quarterly
  cadence as the pipreqs pin, but no corresponding entry existed in "Periodic Maintenance
  Checks." Added an "Embed version table (REQ-009 Tier 5)" entry there, recording the current
  table range (3.10-3.14) and going-forward checks (new CPython minors, patch EOL within a
  pinned minor, whether `FLOOR_MINOR` should advance to track five-minors-behind-latest). Also
  noted that `tests/test_embed_tier.py`'s `BatchPythonConsistency` test already catches a
  batch/table cross-reference drift in CI automatically, independent of the quarterly scan.
  Doc-only. CLOSED by this PR.

- **REQ-009 provider-chain reorder (`uv -> conda -> embed -> venv -> system`)**: the embed tier
  (Tier 5 by naming/history) moved from last-resort (after venv and system) to right after conda,
  so a user who pinned a specific Python version via `runtime.txt`/`pyproject.toml` still gets it
  via a fresh checksummed python.org download when uv/conda are unreachable, instead of silently
  falling back to whatever's already ambient on the machine (venv/system just wrap the ambient
  interpreter; they cannot acquire a different one). System stays absolute final regardless,
  since it's the only tier gated by the REQ-014 consent prompt. Both dispatch mechanisms that
  encode provider order moved together: `:handle_conda_failure` (the linear initial fallback
  chain) and `:provider_cascade` (the goto-based, re-entrant post-warnfix cascade -- added a new
  `:cascade_from_embed` label + `HP_CASCADE_TRIED_EMBED` guard, deleted `:cascade_from_system` +
  `HP_CASCADE_TRIED_SYSTEM` since system has no cascade target now, exactly mirroring how embed
  had none before). Confirmed via a full repo-wide trace that no downstream consumer of
  `HP_ENV_MODE`/`HP_ENV_READY` needed to change (every consumer does pure exact-string-equality,
  order-agnostic) -- only the two dispatch chains and their comments moved. Tier numbering
  ("Tier 4" = system, "Tier 5" = embed) was deliberately kept as a historical/naming label, not
  renumbered to match new execution order, since renumbering would touch ~15 comment sites plus
  two docs files for zero functional benefit (the load-bearing NDJSON `id` fields are not
  tier-numbered). `tests/selfapps_ux_hardening.ps1`'s `self.embed.fallback.decline`/`.real` and
  `tests/selfapps_cascade.ps1`'s `self.cascade.exec` updated to match, including new assertions
  that prove the reordered edges actually fire (not just that embed is reachable). See
  `docs/agent-interconnect.md` "Standalone Python-download tier" for the full ordering rationale
  and dispatch-chain detail. CLOSED by this PR.

- **Embed tier's version-swap mechanism was dead code (correctness bug, found via code review of
  the shipped Tier 5 PR)**: the "pull latest, then swap to the user's requested Python version"
  design -- the core value proposition of the embed tier's two-stage split -- had never actually
  executed, in production or in CI. The version-check-and-swap sequence in `run_setup.bat` was
  wrapped in one parenthesized `if not errorlevel 1 ( ... )` block; a `for /f` loop inside that
  block set `HP_EMBED_SWAP_DIR`/`_TAG`/`_MINOR` from the Python stage's output, and code later in
  the SAME block read `%HP_EMBED_SWAP_DIR%` to decide whether to swap -- but CMD's parse-time
  `%VAR%` expansion substitutes every `%VAR%` in a parenthesized block using the value from
  BEFORE the block began, not a value a `for /f` loop set during the same block's own execution
  (the exact bug class documented in `docs/agent-lessons-learned.md`'s "Provider-cascade
  dispatch is goto-based on purpose", previously hit by the drag-and-drop empty-filename bug and
  the fail-fast-probe `%ERRORLEVEL%` bug). Since `HP_EMBED_SWAP_DIR` was never set earlier in the
  subroutine, that read was always empty, so the swap body never ran regardless of what version
  was actually requested. No test caught it because `self.embed.fallback.real` never requests a
  non-default version through this tier. Fixed via goto-based dispatch, matching this file's
  established fix pattern for this bug class. CLOSED by this PR.

- **REQ-013 connectivity-check retry hardening (found via a real CI failure analysis, requested
  by the user after having to manually retrigger PR #336)**: `:check_net_after_dl_fail` did
  exactly one `ping -n 1 8.8.8.8` and, if that failed, exactly one `curl --connect-timeout 5
  --max-time 8` to `conda.anaconda.org` before concluding "no internet detected" -- root-caused a
  real `conda-full` lane failure (`self.ux.connectivity.online`) to this: a single dropped ICMP
  echo plus a curl connect exceeding 5s under shared-runner network contention is enough to
  misclassify a genuinely-online host as offline, which would show a real user an unnecessary
  offline prompt for the same transient blip. Added a 2-total-attempts retry to both checks,
  mirroring the REQ-022 transient-retry idiom already used by
  `:try_conda_create`/`:conda_bulk_install`. The top-level check uses a counter-based goto loop;
  the interactive "Y" retry branch (nested in a parenthesized block) uses literal duplication
  instead, since a counter var set+read inside the same block would hit the same parse-time
  `%VAR%` expansion trap described above. CLOSED by this PR.

- **Diagnostics artifact bloat (root-caused 2026-07-09 via a debug-logging-enabled CI retrigger
  of the merge-commit run, 29002681009 attempt 2; fix implemented 2026-07-10)**:
  `batch-check.yml`'s "Build public diagnostics tree" step (`publish_diag` job) blanket-copied
  the ENTIRE post-test repo working tree into each lane's `diag-selftest-*` artifact with zero
  exclusion for build/binary output (`dist\*.exe`, `build\`, conda envs, `.venv`, `.uv_env`,
  `~uv_bin`, `~embed_python*` extraction, Miniconda3, downloaded zips). Confirmed via exact
  per-artifact byte sizes in a debug log: per-lane bundles totaled ~5.4 GB combined while the
  final published `github-pages` artifact was only ~32 MB -- proving the published site itself
  wasn't bloated, but `publish_diag` had to download all ~5.4 GB before filtering it down, the
  most likely cause of the `Publish diagnostics to Pages` cancellation on the Tier 5 merge-commit
  run. Fixed by extending the existing `Where-Object` exclusion filter to also skip known
  scratch/binary directories and extensions. YAML-only, zero `run_setup.bat`/Prime-Directive
  risk. CLOSED by this PR.

- **REQ-016 hidden-import auto-recovery: no dedicated user-facing message on exhaustion.**
  `:hidden_import_recover_done` logged nothing when the 3-attempt cap was reached with the EXE
  still failing -- the subroutine just returned. Added one `[WARN]` log line for that branch;
  purely additive. CLOSED by this PR.

- **`:try_venv_fallback`'s `:venv_canary_fail` HP_PY leak**: sibling of the `:try_system_fallback`
  leak already fixed in the Tier 5 PR (see `docs/agent-lessons-learned.md` "A declined/failed
  fallback tier must clear HP_PY"). Fixed by clearing `HP_PY=` before that path's `exit /b 1`,
  exact mirror of the already-shipped fix. CLOSED by this PR.

- **`embed_pyver_check.py`'s `download_and_verify` had no socket timeout** (validated finding
  from a 3rd-party review): `urllib.request.urlretrieve(url, dest_zip)` used Python's default
  (unbounded) socket timeout, so a stalled connection during the rare version-swap path could
  hang the whole bootstrap indefinitely. **Note: the originally-proposed fix (`timeout=` kwarg on
  `urlretrieve`) was wrong** -- `urlretrieve` does not accept a `timeout=` parameter (verified
  via `inspect.signature`), which would have shipped a `TypeError` crash. Fixed instead with
  `socket.setdefaulttimeout(120)` near the top of the script, safe since the whole helper is a
  one-shot script that exits immediately after use. CLOSED by this PR.

- **`:try_embed_fallback`'s `rd /s /q` + `move /y` swap (a real, low-severity Windows
  deletion-race)** (validated finding from a 3rd-party review): `rd /s /q` can return before all
  file handles are released (AV/indexer lock), causing the immediately-following `move /y` to
  fail. Already failed safely (checked `python.exe` exists after, logged `[WARN]`, failed the
  tier cleanly) -- added a retry of the pair up to 3 total attempts with a short pause between,
  using `ping -n 2 127.0.0.1` (this file's existing delay idiom at line 1461) rather than the
  `timeout` command, so a rare transient lock doesn't needlessly fail the last-resort tier.
  CLOSED by this PR.
  - **Investigated and NOT valid, no action**: the companion 3rd-party claim that the `for /f`
    capturing `~embed_extract.ps1`'s stdout "swallows PowerShell failures" and leaves
    `HP_EMBED_PY` holding stale prior state on a crash is already defended against -- the code
    explicitly clears `HP_EMBED_PY=` immediately before the `for /f` call, so a zero-output
    crash leaves it empty (not stale), and the following existence check correctly treats an
    empty value as a failure and retries/exits. No gap here.

- **Standalone Python-download tier (REQ-009 Tier 5)**: closes the confirmed gap in the REQ-009
  provider cascade (uv -> conda -> venv -> system) where uv and conda both self-acquire a full
  Python interpreter (uv's managed CPython, conda's bundled Miniconda Python) but venv and system
  (`:resolve_system_python`) both require an *ambient* interpreter already on the host and have no
  download path of their own -- if uv is unreachable, conda create/install fails, and no ambient
  `python`/`py` launcher exists, the bootstrap previously had no remaining way to acquire a Python
  interpreter and fell straight through to `:die`. Implements Tier 5: download the official
  python.org embeddable zip, verify against an embedded SHA256, extract, patch its disabled-`site`
  `._pth` file, bootstrap pip via the existing `:download_get_pip` subroutine (reused from
  REQ-023b, not duplicated), and canary-probe (`import sys, pip`) before selecting it as the
  provider. No REQ-014-style consent gate -- unlike system Python (a shared, uncontrolled,
  version-unknown ambient environment), the embeddable zip is a private, checksummed,
  bootstrapper-controlled extraction under `~embed_python\`, more REQ-010-isolated than the system
  tier, not less; it behaves like `venv` (freely installable-into), not like `system`
  (install-avoiding). New subroutine `:try_embed_fallback`, called from both fallback ladders
  (`:handle_conda_failure`'s initial chain, after `:try_system_fallback`; and `:provider_cascade`'s
  post-warnfix cascade via a new `:cascade_from_system` label, guarded by the standard
  `HP_CASCADE_TRIED_SYSTEM` no-loop var -- embed is the final tier, no further cascade target). A
  new `HP_ENV_MODE=embed` case was threaded through the one call site that mattered most: the
  dependency-install branch (`:after_env_mode_selection`), which previously would have silently
  caught `embed` in the conservative no-install `system` catch-all -- embed now gets the same
  plain `pip install -r requirements.txt` treatment as venv.

  **Two-stage PowerShell/Python design (the key implementation decision, refined beyond the
  original design discussion)**: this tier runs precisely when no Python interpreter exists
  anywhere on the system, so per-request version-selection logic cannot live in Python until some
  interpreter is on disk first. Stage 1, `tools/embed_extract.ps1` (embedded as
  `HP_EMBED_EXTRACT`), is pure PowerShell with zero per-request branching -- it only verifies,
  extracts, and patches ONE hardcoded "latest" version batch already downloaded
  (`HP_EMBED_LATEST_PATCH`/`HP_EMBED_LATEST_SHA256`). Stage 2, `tools/embed_pyver_check.py`
  (embedded as `HP_EMBED_PYVER_CHECK`), runs under that fresh interpreter and is the ONLY place
  per-request version logic lives -- it reuses the same `PYSPEC` value `~detect_python.py` already
  computed (the value uv/conda already honor), and if it requests a minor other than "latest",
  re-fetches/verifies/extracts the correct version itself via `urllib.request`/`hashlib`/`zipfile`.
  `EMBED_PYTHON_TABLE` covers Python 3.10-3.14 (5 pinned minor -> (patch, sha256) entries, all
  independently verified via real downloads plus local SHA256 computation before shipping); an
  out-of-range request falls back to the table's floor (below) or latest (above) with a WARN,
  never growing the table indefinitely. A `BatchPythonConsistency` unit test asserts the "3.14"
  table entry matches the batch-side constants exactly, so a refresh that updates one but not the
  other is caught at CI time.

  **Windows self-file-lock fix**: a running process cannot delete/replace its own executable/DLLs,
  so a version swap in stage 2 cannot extract directly into the directory it is running from.
  Fixed by extracting any swap into a sibling `_swap` directory; the actual `rd /s /q` + `move /y`
  swap happens in the BATCH caller only after the Python subprocess has fully exited (confirmed
  via the `for /f` capture call having already returned), releasing its file locks first.

  Sigstore verification was evaluated and rejected for MVP: it requires `cosign` or
  `sigstore-python`, both of which themselves require an existing Python/tool installation --
  circular for a tier whose entire purpose is "no Python exists yet." Embedded SHA256 (computed
  once at pin-time, independently verified) is proportionate and matches this repo's "bootstrap
  reliability > API correctness" principle.

  Test coverage: `tests/test_embed_tier.py` (10 tests: version-table resolution logic, batch/table
  consistency, and `PayloadSync`-style byte-equality of both embedded payloads against their
  `tools/` canonical sources, mirroring the established `test_collect_submodules.py`/
  `test_hidden_import_scan.py` pattern). CI: `tests/selfapps_ux_hardening.ps1`'s
  `self.embed.fallback.decline` (forces the full uv/conda/venv/system chain to fail, then forces
  the embed tier itself to fail via `HP_TEST_FORCE_EMBED_FAIL=1`, asserting a clean `:die` instead
  of a hang or false success) and `self.embed.fallback.real` (same chain, but
  `HP_TEST_FORCE_EMBED_REAL=1` -- a narrow, test-only hole through the `HP_OFFLINE_MODE=1` gate,
  mirroring the existing `HP_TEST_FORCE_VENV_CREATE_FAIL` exception pattern for
  `:download_get_pip` -- exercises the real download-verify-extract-patch-pip-bootstrap-canary-
  build-run path end-to-end). Both skip gracefully in the conda-full lane. Full interconnect
  detail (the complete `HP_ENV_MODE` call-site audit, the two-stage split rationale, the file-lock
  fix, and the offline-mode exception chain touching two call sites) lives in
  `docs/agent-interconnect.md`'s "Standalone Python-download tier (REQ-009 Tier 5, SHIPPED)"
  section. One pre-existing, unrelated gap was confirmed (not fixed) during this work: the warnfix
  REPAIR-install branch has no plain-pip fallback for venv/system-family modes; embed inherits
  this identical gap, matching venv's/system's current behavior -- remains its own future backlog
  item, not folded into this PR. CLOSED by this PR.

- **`ndjson-registry-check` Python-source scanning (closes the permanent 16-row noise gap)**:
  `tools/check_ndjson_registry.py` previously only scanned `tests/*.ps1`, `run_setup.bat`, and
  `.github/workflows/*.yml` -- `tests/dynamic_tests.py` (Python) was out of scope by design, so
  the 16 rows it emits (`pr.to_conda`, `dp.pep440`, `entry.select.*`, etc.) showed up as
  "registered in docs but no matching code emission site found" on literally every single run,
  forever, with zero chance of ever converging to green. Added `scan_dynamic_tests_ids()`: an
  `ast`-based resolver (not regex -- the id-construction shapes turned out more varied than the
  original backlog note assumed) that walks `record({"id": ...})` calls and resolves the id
  value three ways: a plain string literal; an f-string templated from an enclosing `for`
  loop's literal iterable (`f"pr.{_pkg}.{_target}"`, including `dict.items()` iteration via a
  locally-tracked dict-literal assignment, e.g. `needed = {...}; for dst, var in
  needed.items():`); or a *bare* loop variable used directly as the id with no string literal
  at all (`for rec_id, ... in [("entry.select.single", ...), ...]: record({"id": rec_id, ...})`
  -- the `entry.select.*` rows use this shape, which a pure regex cannot resolve at all). Also
  handles the one-hop `rec = {"id": ...}; ...; record(rec)` indirection
  `ensure_extracted()` uses. Deliberately does not attempt anything more dynamic than that
  (nested loops, non-literal iterables, function calls) -- see the module docstring and
  `_for_loop_bindings`'s own docstring for the exact resolution scope.
  Running the extended scanner against this repo's real state immediately surfaced 7
  **genuinely new**, previously-invisible undocumented rows the old scope could never have
  found even in principle: `helpers.run_setup`, `bootstrap.status`, and 5
  `helpers.decode.~<name>.py` rows (one per embedded helper payload
  `ensure_extracted()` decodes out of `run_setup.bat`). Backfilled all 7 into
  `docs/agent-ndjson.md`'s "Dynamic-tests NDJSON" section in the same commit, matching this
  repo's established backfill-in-the-same-PR convention. Also fixed a latent bug the tilde in
  `helpers.decode.~detect_python.py` exposed: `DOC_TOKEN_RE` (the doc-side token regex) didn't
  include `~` in its character class, so it silently mis-split any tilde-containing id into two
  bogus tokens at the tilde boundary -- fixed by adding `~` to the regex's character class.
  A local dry-run now shows a clean `PASS: no doc/code registry mismatches found.` for the
  first time since the job was added -- see the new Active Backlog entry above for the
  follow-up (confirm this holds in real CI, then consider flipping the job off
  `continue-on-error`). 3 new unit tests in `tests/test_check_ndjson_registry.py` cover the
  three id-resolution shapes plus the `.items()`/`rec` indirection and an end-to-end `main()`
  wiring check. CLOSED by this PR.

- **Proactive disk-space check (REQ-025)**: closes the 2026-07 iteration-pass finding that the
  only disk-space-related output anywhere in `run_setup.bat` was the post-flight "SAFE TO DELETE
  to reclaim disk space" hint -- there was no pre-flight free-space check before Miniconda
  download/install or conda env creation (which together can require several hundred MB to a few
  GB depending on packages), so a beginner on a low-spec/older machine who ran out of space
  mid-bootstrap saw whatever low-level error curl/conda/pip happened to surface for "no space
  left on device" instead of a clear, early, plain-language message. Added a new guard block
  (grouped with the existing path-length and OneDrive early-warning checks, right before
  `%STATUS_FILE%` cleanup -- runs before `:acquire_lock`, though order relative to the lock does
  not matter since this check never acquires or gates anything) that reads the script's drive's
  free space via a single PowerShell `Get-PSDrive` one-liner (using `$env:HP_SCRIPT_ROOT` inside
  the command rather than textually interpolating the path into the command string, matching the
  existing path-length guard's safer idiom) and logs a `[WARN] REQ-025: low disk space detected`
  message when free space is under a generous 2 GB threshold. **Warn-only, by design, per REQ-001
  (env-var flags are scaffolding, never a Prime-Directive gate)**: a low reading never aborts the
  run -- the user may still have just enough space, or may free some and retry after seeing the
  warning; a hard-block here would be exactly the kind of flag-gated behavior REQ-001 forbids for
  anything the Prime Directive needs. New test hook `HP_TEST_FORCE_LOW_DISK` (deterministically
  forces the low-disk branch, since a CI runner's drive is never actually low) and a new
  `tests/selftest.ps1` row, `self.stub.low_disk_warn`, asserting both that the WARN fires AND
  that the bootstrap still completes normally (`state=ok`, `exitCode=0`) -- proving the guard
  never blocks. CLOSED by this PR.

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
