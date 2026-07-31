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
"Known Findings", `docs/agent-lessons-learned.md`, or "Periodic Maintenance Checks" below instead;
a promising idea deliberately shelved pending a specific, named trigger belongs in "Cold Storage"
below instead of here (see that section's own scope note for the distinction from this one).
Item numbers are stable cross-reference identifiers, not sequential list positions -- once an
item is fully resolved it is removed from here entirely and archived (keeping its original
number) in `docs/agent-closed-backlog.md`, which is why the numbering below does not start at 1.
**Exception: if a new item's number collides with a number already permanently retired by an
older, unrelated closed item, renumber the new item to the next never-used number when archiving
it, and document the collision (old number, why, cite the colliding entry) in its
closed-backlog entry.** Keeping the original number is still the default; renumbering only
happens to resolve a genuine collision, never for its own sake. Concrete precedent: items 9 and
11 (filed 2026-07-29) each collided with an older, already-closed item of the same number and
were renumbered to 17 and 16 respectively when archived -- see item 18 below and
`docs/agent-closed-backlog.md`'s Item 16/17 entries for the full trace.

- **8. `[WARN] UNC paths not supported` fires unconditionally in CI on an ordinary (non-UNC) local
   path -- found 2026-07-29 while gathering real console-output evidence for
   `docs/demo-bootstrapper-output.md`'s default-happy-path documentation pass, not yet
   investigated further.** `run_setup.bat:57-58` does
   `echo %~dp0 | findstr /C:"\\\\" >nul` / `if not errorlevel 1 echo [WARN] UNC paths not
   supported` -- per the C-runtime backslash-before-quote rule already documented in
   `docs/agent-lessons-learned.md` ("A single trailing backslash before a closing quote silently
   corrupts a subprocess argument"), `\\\\"` collapses to a 2-backslash literal search pattern,
   so this is searching `%~dp0` for two CONSECUTIVE backslashes anywhere in the string -- not
   testing for a UNC prefix (that's the separate, independent check two lines below at line 59,
   `if "%HP_SCRIPT_LAUNCH_DIR:~0,2%"=="\\"`, which prints the louder `*** WARNING: UNC/network
   paths detected...` banner). Pulled `tests/~envsmoke/~envsmoke_bootstrap.log` (the full,
   unredirected console capture of a real, non-`HP_CI_SKIP_ENV` bootstrap) from a recent clean
   green run (`30328748330`, all lanes green) across 6 lanes (`real`, `uv`, `conda-full`,
   `justme-test`, `contract-uv`, `contract-uv-fail`) and found the `[WARN] UNC paths not
   supported` line as the very FIRST line of console output in all 6, every single time, against
   an entirely ordinary CI checkout path (`D:\a\Python_vs_Windows\Python_vs_Windows\tests\
   ~envsmoke\`) -- not a UNC path by any reasonable definition. No test in the repo asserts on
   or references this string at all (confirmed via a repo-wide grep), so this has apparently been
   firing on every single CI run, unnoticed, indefinitely.
   - **Ruled out one theory directly**: the companion `HP_SCRIPT_LAUNCH_DIR:~0,2` check (tests
     whether the path literally STARTS with `\\`) never fires in the same logs (zero hits for
     "UNC/network paths detected" across all 6 lanes) -- so whatever is producing a
     double-backslash for the `findstr` search must be sitting mid-string, not at the start of
     `%~dp0`. This is real, if partial, information: it means the failure mode is NOT "the whole
     checkout path is somehow UNC," which was the first, most obvious guess.
   - **Root cause NOT identified.** Best unconfirmed guess: something about how GitHub-hosted
     Windows runners provision the `D:\a\...` work directory (`actions/checkout`'s own path
     construction, or a junction/reparse point backing that drive) introduces a duplicated
     separator somewhere in the resolved `%~dp0` value for a batch file invoked from inside it --
     but this was NOT verified (no way to inspect the raw `%~dp0` bytes directly from this
     research pass; would need a dedicated diagnostic echo added to a test lane, e.g.
     temporarily `echo RAW_DP0=[%~dp0]` to a log file, to actually see the string with delimiters
     visible).
   - **Whether this also fires for a genuine end-user double-click (not CI, no nested
     `cmd`/PowerShell invocation, an ordinary local folder) is UNCONFIRMED** -- this sandbox has
     no Windows machine to test on, and no real end-user report exists either way. If it's
     CI-runner-specific plumbing, it's cosmetic noise (one extra harmless WARN line, unlikely to
     confuse a real user since it never fires for them); if it also fires for real users on an
     ordinary local path, it's a real, previously-unknown false-positive bug worth fixing (most
     likely fix shape: tighten the `findstr` pattern to require the double-backslash appear
     specifically in a network-path position, or just remove this redundant check entirely since
     the very next lines already do a correct, more targeted UNC-prefix check).
   - **Not investigated further in this pass** -- out of scope for a documentation-only task, and
     genuinely needs either a dedicated diagnostic-logging CI experiment (cheap, doable in a
     future loop) or a real Windows machine to resolve with confidence. Documented in
     `docs/demo-bootstrapper-output.md`'s new default-happy-path scenario as an observed,
     unexplained anomaly rather than either asserting it's harmless or that it's a bug.

- **10. Two of the five `PVW_*` super-user override variables (`PVW_PYTHON_EXE`, `PVW_WORKSPACE`)
   have ZERO test coverage of any kind, and ALL FIVE have zero coverage of their invalid-value
   behavior -- found 2026-07-29 while documenting them for `docs/demo-bootstrapper-output.md`'s
   Part V.** Confirmed via a repo-wide search across every `tests/*.ps1` file and every lane of a
   recent clean CI run (`30328748330`): `PVW_PYTHON_EXE` and `PVW_WORKSPACE` have zero references
   anywhere -- not even a valid-value smoke test. `PVW_UV_EXE` (`tests/selfapps_contract_uv.ps1`)
   and `PVW_TARGET_PY` (`tests/selfapps_pipgap.ps1`) each have real, valid-value end-to-end CI
   coverage, but that coverage is incidental to each test's own actual purpose (avoiding a
   redundant uv re-download; pinning a Python version for an unrelated opencv-python wheel test),
   not a dedicated test of the override mechanism itself. `PVW_CONDA_EXE` is the one exception with
   dedicated, purpose-built coverage (`self.corrupt.conda.override_exit`, CLAUDE.md's own earlier
   Active Backlog item 12 history).
   - **No test anywhere exercises an INVALID value for any of the five** -- e.g. `PVW_PYTHON_EXE`
     pointing at a nonexistent file, `PVW_UV_EXE` pointing at something that isn't actually uv,
     `PVW_TARGET_PY` set to a malformed version spec, `PVW_WORKSPACE` pointing at an unwritable or
     already-occupied-by-something-else path. Static tracing (done for the demo doc, see Part V)
     shows each case is plausibly absorbed gracefully by pre-existing fallback/cascade machinery
     (the REQ-009 provider cascade, the `:uv_venv_fail` chain, the interpreter smoke-test WARN),
     never an uncontrolled crash -- but this is reasoned from source, not empirically confirmed by
     any real run.
   - **Not fixed in this pass** -- documentation-only task, and building 5+ new dedicated test
     scenarios (a `PVW_PYTHON_EXE`-focused test, a `PVW_WORKSPACE`-focused test, plus invalid-value
     variants for all five) is real, multi-scenario engineering work, not a quick addition. Suggested
     shape for a future pass: one new `tests/selfapps_pvw_overrides.ps1`-style file (mirroring the
     existing `tests/selfapps_ux_hardening.ps1`/`...contract_uv.ps1` pattern) covering the two
     currently-zero-coverage variables' valid-value paths first (cheapest, highest-value gap), then
     a smaller number of representative invalid-value scenarios (not all 5x2 combinations -- the
     failure-absorption mechanism is shared/generic across most of them per the static trace above,
     so 2-3 representative invalid-value cases would likely cover the real risk without a
     combinatorial test matrix).

- **12. `:embed_dl_retry`'s genuine mid-download-failure-then-retry-once path (REQ-009 Tier 5) has
   no CI test hook at all -- found 2026-07-29 while documenting the embed-tier download for
   `docs/demo-bootstrapper-output.md`'s Part VI, Scenario 20.** Confirmed via `run_setup.bat`
   source and a repo-wide grep: only two test hooks exist for this tier --
   `HP_TEST_FORCE_EMBED_FAIL` (immediate decline, no download attempted at all) and
   `HP_TEST_FORCE_EMBED_REAL` (a full, real, successful download end-to-end). Neither exercises
   the retry branch itself: `:embed_dl_retry`'s own `[WARN] embed fallback: download failed;
   retrying once.` line (both the curl and PowerShell download attempts failing on the FIRST try,
   then succeeding on the second) and the sibling checksum/extraction-failure retry branch
   (`[WARN] embed fallback: checksum verification or extraction failed; retrying download once.`)
   are both reachable in principle but have never been observed firing in any real CI run
   examined for this documentation pass -- the demo doc's own Scenario 20 correctly labels the
   retry-branch text `[Extrapolated Branch]`, cited from source, for exactly this reason. **Not
   fixed in this pass** -- documentation-only task; a dedicated test would need a new hook (e.g.
   `HP_TEST_FORCE_EMBED_DL_FAIL_ONCE=1`, mirroring the existing `HP_TEST_FORCE_CONDA_CREATE_
   NETWORK_FAIL`-style one-shot-then-succeed pattern already used for REQ-022's conda-create
   retry) that fails the first curl+PowerShell attempt deterministically without touching the
   real network, then lets the second attempt through for real. Suggested as a small, well-scoped
   future addition to `tests/selfapps_ux_hardening.ps1` alongside the existing
   `self.embed.fallback.decline`/`.real` scenarios.

- **13. `self.warn.longpath`'s own real CI run examined for this documentation pass shows an
   INCONCLUSIVE result (`ranBootstrap:false`), yet the test still reports an overall pass -- found
   2026-07-29 while documenting the path-length pre-flight guard for
   `docs/demo-bootstrapper-output.md`'s Part VI, Scenario 24.** The test's own NDJSON row in run
   `30328748330` (`real` lane) reads `warnFound: false, ranBootstrap: false, pathLen: 312` -- the
   scratch directory this specific CI run created did not actually reach a state where the
   sub-bootstrap could run at all (most likely an OS-level path-length limit on the CI runner
   itself was hit before `run_setup.bat`'s own ~200-char check ever got a chance to fire), yet the
   test apparently tolerates this as a passing outcome rather than treating it as inconclusive.
   This means the guard's actual WARN-firing behavior (`*** WARNING: Script path is <N> chars.
   Paths near 260 chars may cause cmd.exe failures.`) has NOT been positively confirmed by this
   specific real-CI observation -- the demo doc's own Scenario 24 correctly labels the guard's
   exact text `[Extrapolated Branch]`, cited from source, for this reason, rather than presenting
   an inconclusive test result as if it were a real, confirmed capture. **Not fixed in this pass**
   -- documentation-only task, and root-causing exactly why the scratch directory's own path
   didn't reach the runner's practical limit (or why the test tolerates `ranBootstrap:false`)
   needs its own investigation into `tests/selftest.ps1`'s long-path scenario, not a rushed fix
   folded into an unrelated docs PR. Worth checking in a future pass whether this is a persistent,
   reproducible gap (in which case the test's own pass/fail logic may need tightening) or a
   one-off artifact of this particular run's CI-runner path layout.

- **14. Total REQ-009 provider-tier exhaustion produces a MISLEADING "your program has a syntax
   error" final message instead of surfacing the real "no Python interpreter found" cause -- found
   2026-07-31 while sweeping `run_setup.bat` line-by-line for `docs/demo-bootstrapper-output.md`
   coverage gaps, confirmed against real CI evidence and the actual source, not just theorized.**
   `:after_env_mode_selection`'s own guard (`run_setup.bat`, right after
   `:conda_base_update`/`:emit_from_base64 "~prep_requirements.py"`) does
   `if not defined HP_PY ( call :die "[ERROR] Active Python interpreter not resolved." )` -- but
   per this file's own long-documented `:die` semantics (`exit /b` inside `:die` only returns from
   `:die`'s OWN call frame, never halts the calling code), execution falls straight through to the
   very next line regardless: `echo Interpreter: %HP_PY%` (printing a blank interpreter path),
   then an `"%HP_PY%" -c "print('py_ok')" ... || call :log "[WARN] Interpreter smoke test failed
   (continuing)."` that silently downgrades the failure to a WARN and continues. The bootstrap then
   proceeds through pipreqs, dependency install, the pyvisa check, and entry selection -- all
   effectively no-ops against an empty interpreter path -- and finally reaches `:preflight_compile`
   (REQ-021), whose `"%HP_PY%" -m py_compile "%HP_ENTRY%"` becomes a literal `"" -m py_compile
   "app.py"` with `HP_PY` empty. cmd.exe cannot execute an empty-quoted command name, producing
   `'""' is not recognized as an internal or external command, operable program or batch file.` --
   a CMD.EXE ERROR, NOT A PYTHON TRACEBACK -- which `:preflight_compile` (any nonzero exit is
   treated as "compile failed," with no distinction between "the interpreter itself couldn't run"
   and "the interpreter ran and found a real syntax error") unconditionally reports as
   `*** [ERROR] REQ-021: Your Python program has a syntax error and cannot run. ***` followed by
   that cmd.exe text and "Fix the syntax error shown above, then run this batch again."
   **Confirmed via real CI capture** (run `30328748330`, `real` lane, job `90179708091`,
   `tests/~selftest_embed_decline/`'s own sub-bootstrap -- a test that force-fails EVERY provider
   tier via `HP_TEST_FORCE_EMBED_FAIL`/`HP_TEST_FORCE_VENV_FAIL`/declined system-Python consent,
   deterministically reproducing total exhaustion): the log shows exactly this sequence --
   `[ERROR] Active Python interpreter not resolved.` -> blank `Interpreter:` line -> `[WARN]
   Interpreter smoke test failed (continuing).` -> a full, unaffected pipreqs/dep-install/VISA/
   entry-selection sequence -> the misleading REQ-021 syntax-error block quoting the literal
   `'""' is not recognized...` cmd.exe text. **This is a real, non-test-only reachable scenario**:
   README's own REQ-009 table already documents that falling through three-plus tiers in one run
   is "almost always one shared root cause" (no internet, full disk, or a locked-down managed
   image) -- a real user with no connectivity, no working ambient Python, and who declines the
   REQ-014 system-Python prompt hits this identical path for genuine, non-test reasons. The
   test-forced flags in the capture above are a deterministic REPRODUCTION vector, not the only
   way to trigger it. **`~bootstrap.status.json`'s machine-readable `state` field is NOT
   affected** -- `:die`'s own already-fixed unconditional `HP_BOOTSTRAP_STATE=error` set (see this
   file's `:die` entry) still applies before execution falls through, so the status file correctly
   reads `state: error` regardless of the confusing console narrative; only the human-readable
   text is misleading, and only for a user who reads just the LAST error rather than scrolling
   back to the real, earlier "Active Python interpreter not resolved." line. **Not fixed in this
   pass** -- documentation-only task; `docs/demo-bootstrapper-output.md` documents this exact real
   capture as its own scenario rather than presenting the misleading text as a genuine syntax-error
   report. Suggested fix for a future pass: guard `:preflight_compile` (and any other `HP_PY`-using
   code reachable after `:after_env_mode_selection`'s interpreter-resolution guard) on `HP_PY`
   actually being a non-empty, existing path before invoking it -- or, more robustly, make the
   `:after_env_mode_selection` guard itself a `goto`-based hard stop (matching this file's own
   "Provider-cascade dispatch is goto-based on purpose" pattern) instead of relying on `:die`'s
   call-frame-only return, so total exhaustion genuinely halts the pipeline at the point of failure
   rather than continuing for another ~15 log lines under a broken interpreter.

- **15. `:exe_smokerun_hints`'s diagnostic re-run of a freshly-failed EXE has no timeout, unlike
   every other user-code launch point in this file -- found 2026-07-31, flagged by a CodeRabbit
   review on PR #402 while documenting the hint mechanism for
   `docs/demo-bootstrapper-output.md`'s Scenario 37, verified against source before logging.**
   `:exe_smokerun_hints` (`run_setup.bat`) does `pushd dist` then `"%ENVNAME%.exe" > "~exe_out.txt"
   2>&1` with no `.NET Process`/`WaitForExit(ms)`/`Kill()` wrapper at all -- a plain, synchronous,
   unbounded batch invocation. Every OTHER place in this file that launches a frozen EXE or the
   interpreter (`:run_exe_smokerun`'s primary verification, `:run_failfast_probe`'s three call
   sites, `:hidden_import_recover`'s own repair-check re-run) is deliberately bounded, either by
   the ~30s hard-kill ceiling (the one place this bootstrapper is allowed to `Kill()` a process) or
   by the fail-fast-probe's classify-then-never-kill design -- this is the one exception. The call
   site's own guard (`if not "%HP_EXE_EXIT%"=="-1" call :exe_smokerun_hints`, in `:smokerun_ndjson`)
   only confirms the FIRST launch (inside `:run_exe_smokerun`) exited with a real, non-hang code --
   it says nothing about whether the SAME program will behave identically on this SECOND, separate
   launch a few lines later. A program with any non-determinism (a race condition, an environment
   check that sometimes succeeds, or anything that occasionally blocks on stdin instead of exiting
   fast) could hang this second, untimed invocation and hang the whole bootstrap, even though the
   first invocation legitimately fell into the "fast, real, non-hang failure" classification that
   is this subroutine's own precondition for being called at all. **Not fixed in this pass** --
   documentation-only task, and the correct fix (reuse the existing bounded-launch pattern, e.g.
   `tools/exe_smokerun.ps1`'s own `.NET Process` + timeout wrapper, or add an independent
   termination deadline before the stderr pattern-match) touches `run_setup.bat` itself, out of
   scope for a docs-only PR. `docs/demo-bootstrapper-output.md`'s Scenario 37 was not changed to
   caveat this specifically, since the two real captures it documents are both genuine, already-
   completed runs (the hang risk is about a DIFFERENT, hypothetical program, not about the accuracy
   of what's shown) -- but a future pass fixing this should also confirm no currently-passing test
   silently relies on the unbounded behavior before adding a timeout.

- **18. Active Backlog items 8, 10, 12, 13, 14, and 15 all appear to reuse item numbers already
   permanently retired by older, unrelated closed items -- found 2026-07-31 while closing out
   items 9 and 11 during a `/goal`-directed backlog-fix pass, both of which turned out to have the
   identical problem (fixed for those two; this item tracks the rest).** The batch of findings
   filed 2026-07-29 while documenting the bootstrapper for `docs/demo-bootstrapper-output.md`
   (this file's current items 8, 10, 12, 13, 14, 15, plus the now-fixed 9 and 11) appears to have
   picked its numbers by eyeballing what looked unused in THIS file at the time, without checking
   `docs/agent-closed-backlog.md`'s own "Closed Backlog" changelog section (2026-07-25 through
   2026-07-27 work) for numbers already retired there. Confirmed for 9 and 11 specifically (both
   collided with real, already-closed, differently-numbered items -- see
   `docs/agent-closed-backlog.md`'s Item 16 and Item 17 entries for the full trace of each) and
   both renumbered to 16/17 when moved out of this file in the same pass that found this. A quick
   grep-based check (`grep -n "item N\b"` across `docs/agent-closed-backlog.md`, `docs/agent-
   ndjson.md`, `docs/agent-interconnect.md`, `docs/agent-lessons-learned.md` for each of N in
   8, 10, 12, 13, 14, 15) shows a same-number hit in the older Closed Backlog section for every
   single one of them, strongly suggesting the same mistake repeats across the whole batch --
   but each was only confirmed by number match, not individually read and verified the way 9 and
   11 were, so **treat this as a strong lead, not a certainty, until each one gets the same
   individual check.** Notably, item 14's collision is NOT purely a docs problem: `run_setup.bat`
   itself has a live `rem derived requirement: [Active Backlog item 14]` comment (in
   `:try_conda_install`, next to the Miniconda installer timeout) that refers to the OLDER,
   already-closed item 14 (the 60-minute installer-timeout work), not the current active item 14
   (the misleading post-exhaustion syntax-error message) -- so fixing this properly means checking
   inline source comments too, not just docs. **Not fixed in this pass** -- renumbering the
   remaining six items correctly requires reading each one's full closed-backlog collision
   individually (to write an accurate, non-templated "renumbered from X because Y" note the way
   16/17 got), then re-numbering every cross-reference to each (docs and, per the item-14 finding
   above, possibly `run_setup.bat`'s own comments) -- real, careful work, not a batch find-replace,
   and disproportionate to fold into an unrelated backlog-fix pass. Suggested approach for a
   future pass: process one item at a time (matching this repo's own iteration discipline), confirm
   its collision, pick the next genuinely-unused number (19 is next after this item, assuming no
   further items get filed first), update its own text plus every cross-reference, and move it to
   `docs/agent-closed-backlog.md` only if it was ALSO independently resolved -- an item can be
   renumbered without being closed, if its underlying finding is still open.

- **19. The `cache` CI lane's corruption recovery is a one-way trap: once a restored cache is
   flagged corrupted, nothing in that lane ever produces a fresh, valid cache again -- found
   2026-08-01 while investigating a maintainer report that the lane "never works," always logging
   `Cache corrupted, skipping fast-path tests (HP_CACHE_CORRUPTED=1)`, confirmed against the
   current `.github/workflows/batch-check.yml` source, not just the symptom report.** Traced the
   full mechanism: the cache key is `win-...-conda-${{ hashFiles('run_setup.bat') }}-<pipreqs_ver>`
   with `restore-keys: win-...-conda-` as a prefix fallback. `run_setup.bat` changes on nearly
   every PR in this repo, so the EXACT primary key rarely matches twice -- the restore step almost
   always falls through to the `restore-keys` PREFIX match instead, which returns whatever cache
   blob currently exists under that prefix (GitHub Actions cache entries are immutable once saved;
   a "stale" blob can only be replaced by a NEW save under a NEW key, never overwritten in place).
   The "Validate restored conda binary" step (`cache_health`) then runs `conda.bat info` against
   whatever got restored; on failure it sets `HP_CACHE_CORRUPTED=1` (informational, `exit 0`, by
   design -- this part is fine). The trap is downstream: the "Bootstrap environment (run_setup.bat)"
   step -- the ONLY step in this lane capable of performing a fresh Miniconda install -- is gated on
   `env.HP_CACHE_CORRUPTED != '1'`, so once corruption is flagged, bootstrap is SKIPPED ENTIRELY for
   that run; no fresh install is ever attempted. The save step (`actions/cache/save`) is gated on
   BOTH `steps.conda_cache_restore.outputs.cache-hit != 'true'` AND `env.HP_CACHE_CORRUPTED != '1'`
   -- since a `restore-keys` prefix match reports `cache-hit: false` (only an EXACT primary-key
   match reports `true`, confirmed against `actions/cache`'s own documented behavior), the
   `cache-hit` half of the save gate is usually already satisfied when corruption is the actual
   blocker -- the `HP_CACHE_CORRUPTED` half is what stops the save. Net effect: the SAME poisoned
   blob (saved once, likely before this health-check mechanism existed, or from a one-off flake)
   gets restored via the prefix fallback on every subsequent run, is correctly detected as
   corrupted every time, but the detection itself prevents the one action (a fresh install this
   run, followed by a fresh save) that would ever replace it -- a permanent, self-perpetuating
   loop with no exit, fully consistent with "never works, always says corrupted."
   **Confirmed this is real, not a one-off**: every `if:` gate on the lane's ~25 self-test steps
   after "Bootstrap environment" already depends on `HP_CACHE_CORRUPTED != '1'`, so once corrupted,
   the entire lane short-circuits to placeholder `pass:true, skip`-style NDJSON rows
   (`self.cache.corrupted`) and reports overall green -- exactly the "always green to avoid being
   gating" behavior observed, and exactly why this has been invisible in CI: nothing ever fails
   loud enough to surface it as a real problem, it just silently never does its job.
   **Not fixed in this pass** -- diagnosed only, per the maintainer's own "if you see an easy fix,
   maybe put that in the backlog" framing; the fix touches shared CI workflow gating logic that
   ~30 other steps also depend on, and can only be verified by watching real cache-lane runs
   (multi-cycle, since the fix's own effect -- "does a fresh cache finally get saved" -- isn't
   observable from a single run), so it doesn't fit safely into a downtime aside. **Suggested fix,
   reasoned through but not implemented:** on a corruption detection that came from a `restore-keys`
   PREFIX match specifically (`steps.conda_cache_restore.outputs.cache-hit != 'true'`, i.e. not an
   exact primary-key hit), delete the corrupted `C:\Users\Public\Documents\Miniconda3` directory
   and do NOT set `HP_CACHE_CORRUPTED` at all -- let the run fall through exactly like a genuine
   cache miss (the health-check step's own existing "No conda binary found; fresh install will
   proceed normally" branch already handles this shape correctly for a true miss). This lets
   "Bootstrap environment" run a real fresh install, and lets the save step create a genuinely
   fresh, valid cache entry under the current key afterward, breaking the loop. The narrower case
   -- an EXACT primary-key hit that's ALSO corrupted (only plausible when `run_setup.bat` is
   byte-identical to a previously-poisoned save, e.g. two runs on the same unchanged commit) --
   would still be stuck, since that specific key's blob can never be overwritten; fully closing
   that gap needs an explicit cache-deletion API call (`gh cache delete` / the GitHub Actions cache
   REST API, `DELETE /repos/{owner}/{repo}/actions/caches`) gated on `cache-hit == 'true'` at
   corruption-detection time, a smaller follow-on refinement once the main fix is proven working.

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
  already covers this on the "does a new version exist" axis. If REQ-AV's Tier B (dropped from the
  backlog entirely -- see the Known Findings entry below for why and what restarts it; PRD at
  `docs/prd-av-safe-build-path.md`) ever ships its own Python-3.12 pin for Nuitka/MinGW64 compatibility,
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

- **Cascade consent gate design (timed prompt, decline-by-default) kept exactly as shipped,
  2026-07-26 owner decision -- closes `docs/open-questions.md` item 1.** Following the
  cascade-vs-postexec fix (see Closed Backlog), a deeper investigation into the reliability of
  the `HP_CASCADE_CANDIDATE` signal was requested and completed -- a full truth table over its
  two constituent build-time static signals, with estimated odds the `.exe` still runs fine and
  odds each next provider tier would actually help, now preserved in
  `docs/agent-interconnect.md`'s "Cascade signal reliability" subsection (under "Post-execution
  checkpoint") rather than in the open-questions file, per that file's own convention of folding
  resolved questions into wherever they actually belong. Headline finding: the signal is real but
  imperfect (an estimated 60-75% chance of a genuine problem when it fires, not a certainty), and
  the uv->conda hop specifically has real, mechanism-level justification (a genuinely different
  package index) that later hops (conda->embed->venv->system, all pip/PyPI-based once bootstrapped)
  largely lack.
  - **Considered, not adopted**: flipping the timed prompt's default from decline (N) to accept
    (Y), specifically for the uv->conda hop, on the strength of that hop's own justification.
  - **Decision: keep `:cascade_consent_gate` exactly as shipped** -- the timed `choice /T` prompt,
    defaulting to decline (N) on timeout, unchanged for every hop including uv->conda. No code
    change resulted from this investigation.
  - Also considered and left out of the same pass, for a different reason (flagged as possibly
    too risky to be wrong and too complex to be robust, and the analysis didn't fully resolve
    that concern): telling the user their specific odds that the NEXT tier would help. Still not
    implemented.

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

## Closed Backlog

Moved to `docs/agent-closed-backlog.md` (2026-07-31, to reduce this file's per-session context
footprint -- that section alone was over 60% of this file's total length). It holds the full
historical record of completed feature/fix work (what shipped, why, and the design reasoning
behind it) plus any Active Backlog item that was later fully closed (each keeps its original
item number for stable cross-reference -- this is why Active Backlog above does not start at 1).
Read it on demand: when you need the resolution history behind a specific PR or item cited by
number, or when investigating something that "feels like it was already done."
