# Agent Interconnectedness Map -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-interconnect.md`
import in CLAUDE.md. It documents the non-obvious cross-component dependencies that
future agents must understand to avoid re-introducing known failures.

**AGENT DIRECTIVE: When you discover a new interconnect or correct an existing one,
update this file immediately in the same commit. The map must stay current.**

---

## Python Version Hazard: uv selects older Python for sub-bootstrap venvs

**Critical: any embedded helper (`~pyproj_deps.py`, etc.) relying on Python 3.11+ stdlib
must have a fallback path for Python 3.9.x.**

In the real lane (uv-first), `uv venv` can select Python 3.9.25 from the system or
its own toolchain cache. This was confirmed in CI: the `self.pyproject.malformed` test
failed because `~pyproj_deps.py` assumed `tomllib` (3.11+ stdlib) was available.

**Root cause pattern:**
- `uv venv` selects Python 3.9.x when no `--python` version constraint is specified
  and a 3.9.x interpreter is available.
- `tomllib` was added in Python 3.11. On Python 3.9.x, `import tomllib` raises `ImportError`.
- Any embedded helper that does `import tomllib` without a try/except will crash on 3.9.x.

**Fix applied in `~pyproj_deps.py` (HP_PYPROJ_DEPS):**
```python
try:
    import tomllib
except ImportError:
    tomllib = None
```
When `tomllib is None`, the helper falls back to regex-based TOML parsing. The regex
fallback must also handle the malformed TOML detection case (exit 2 for missing `]`).

**Rule: Any helper embedded as `HP_*` base64 in run_setup.bat MUST work on Python 3.9.x.
Never assume 3.11+ stdlib (tomllib, match-statement, etc.).**

---

## uv-First Provider Architecture

The "uv-first" feature (skip Miniconda download when uv can provide Python) has a larger
blast radius than it appears. This section documents how it touches test infrastructure.

### Provider selection flow (run_setup.bat)

```
HP_FORCE_CONDA_ONLY=1 -> always go through Miniconda; uv is never tried as primary
HP_TEST_FORCE_UV_FAIL=1 -> fires at line 296 (BEFORE cached-uv check at 302); uv never used
HP_UV_PROVIDING_PYTHON=1 -> set when uv successfully detects Python; gates Miniconda skip
```

When `HP_UV_PROVIDING_PYTHON=1`:
- Miniconda is NOT downloaded or installed
- `:select_conda_bat` (line 398) runs, but `%PUBLIC%\Documents\Miniconda3\condabin\conda.bat`
  does not exist on disk, so `CONDA_BAT` is never set
- The corruption check at line 442 (`if defined CONDA_BAT ...`) never fires
- All conda-dependent bootstrap paths are bypassed

### Lanes and their conda state

| Lane | HP_FORCE_CONDA_ONLY | uv used | Miniconda installed | CONDA_BAT set |
|------|---------------------|---------|---------------------|---------------|
| conda-full | 1 | no | yes | yes |
| real | not set | yes (uv-first) | no | no |
| cache | not set | yes (uv-first) | maybe (cached) | maybe |
| justme-test | not set | no (HP_TEST_FORCE_UV_FAIL=1) | via JustMe | yes |
| contract-uv | not set | yes (forced) | no | no |

### Test files that assume conda is present -- skip=true pattern required

These test files call `Get-CondaBatPath` and use the result to run conda-specific operations.
When conda is absent AND `HP_FORCE_CONDA_ONLY != '1'`, they MUST emit `skip=true` rows
instead of failures. When `HP_FORCE_CONDA_ONLY == '1'`, they MUST emit `pass=$false`
(conda is supposed to be there in that lane).

**Sweep completed (2026-06-20): only 3 files use `Get-CondaBatPath`; all other selfapps files
run the full bootstrapper or are lane-guarded (see notes below).**

| Test file | Affected rows | Skip guard added? |
|-----------|--------------|-------------------|
| `tests/selfapps_reqspec.ps1` | reqspec.translate.*, reqspec.conda.*, reqspec.install.import, reqspec.gte.explicit, reqspec.ingest.* | YES (current) |
| `tests/selfapps_pyproject_precedence.ps1` | pyproject.precedence.detect, pyproject.dep.detect, pyproject.dep.noproj | YES (current) |
| `tests/selftest.ps1` | self.corrupt.conda.detect, self.corrupt.conda.heal.decline, self.corrupt.conda.heal.accept | YES -- guards on `$condaBatOnDisk` |
| `tests/selfapps_pandas_excel.ps1` | pandas_excel.translate, pandas_excel.conda.install, pandas_excel.conda.install.req006, pandas_excel.runtime, self.pandas.openpyxl.install, self.pandas.openpyxl.import | YES (current) -- all 6 rows |
| `tests/selfapps_envsmoke.ps1` | self.env.smoke.conda, self.env.smoke.uv | NOT NEEDED -- already uv-aware via `$isUvMode = Test-Path .uv_env\Scripts\python.exe`; self.env.smoke.conda tests full bootstrapper; self.env.smoke.uv has explicit skip logic when uv not acquired or fell back to conda |
| `tests/selfapps_pipgap.ps1` | pipgap.conda.miss, pipgap.pip.fill | NOT NEEDED -- test sets `$env:HP_FORCE_CONDA_ONLY = '1'` (line 66) before running run_setup.bat; always in conda mode |
| `tests/selfapps_depcheck.ps1` | self.depcheck.install, self.depcheck.skip | NOT NEEDED -- dep-check runs in both conda AND uv mode (`HP_ENV_MODE` guard at run_setup.bat line 1048); in uv mode, `~environment.lock.txt` is written by copying `~dependency_installed.txt` (run_setup.bat lines 1141-1145) |
| `tests/selfapps_warnfix.ps1` | self.exe.warnfix.* | NOT NEEDED -- runs full bootstrapper; warnfix is a PyInstaller post-build phase in run_setup.bat that uses pip/conda within the bootstrapper's own install logic; no direct conda bat calls in test |
| `tests/selfapps_justme.ps1` | conda.install.justme | NOT NEEDED -- only runs in justme-test lane where HP_TEST_FORCE_UV_FAIL=1; conda always present via JustMe install |
| `tests/selfapps_ux_hardening.ps1` | self.ux.* | NOT NEEDED -- runs full bootstrapper; references conda only in a comment |

The `pyproject.precedence.writeback` test runs the FULL bootstrapper (which uses uv in
uv-first lanes) and does NOT require conda to be present. It is NOT in the "needs guard" list.

### EXE fast path vs env-state fast path vs uv venv reuse

Three distinct "fast" paths exist in run_setup.bat. They serve different purposes and
produce different log lines. Future agents must not confuse them:

| Fast path | Trigger | Log line | Lane |
|-----------|---------|----------|------|
| EXE fast path (`:try_fast_exe`) | `dist\<ENVNAME>.exe` exists AND `HP_FAST_CHECK` token = "fresh" | `[INFO] Fast path: reusing dist\<ENVNAME>.exe` | All lanes |
| Env-state fast path (`:env_state_fast_path`) | `~env.state.json` valid, conda env python.exe present | `[INFO] Env-state fast path: reusing conda env <ENVNAME>.` | conda mode only; skipped when HP_UV_PROVIDING_PYTHON=1 |
| uv venv reuse | `.uv_env\Scripts\python.exe` exists AND `import pip` succeeds | `[INFO] uv: reusing existing .uv_env` | uv mode only |

**Critical order**: EXE fast path runs at line 222 (top of file, BEFORE provider selection).
If it fires, run_setup.bat goes directly to `:success`. uv/conda provider logic is never reached.
The env-state check (line 507) and uv venv reuse (line 544) are therefore only reached when
the EXE fast path does NOT fire (first run, or sources changed).

**`self.fastpath` test** (`selfapps_envsmoke.ps1` second run): matches `'Fast path: reusing'`
which appears in the EXE fast path log line. This works in ALL lanes (uv and conda) because
the EXE fast path is completely provider-independent. The test correctly validates the EXE
fast path, not the env-state or uv venv fast path.

### ~dependency_installed.txt: pip freeze output and its consumers

`~dependency_installed.txt` is written after install via `pip freeze` (run_setup.bat lines 1122-1134):
- uv mode: `uv pip freeze --python "%HP_PY%"`
- conda/venv mode: `"%HP_PY%" -m pip freeze`

**Consumers:**
- `selfapps_pipgap.ps1`: reads `~dependency_installed.txt` to check `opencv-python` was installed
- `~environment.lock.txt` (uv mode): `copy /y "~dependency_installed.txt" "~environment.lock.txt"` (line 1145)
- The dep-check (`~dep_check.py`) reads `~environment.lock.txt` (either conda list --export or pip freeze copy)

### warnfix install + uv mode

When `HP_ENV_MODE=uv`, the warnfix repair loop (run_setup.bat lines 2055-2062) uses
`uv pip install --python "%HP_PY%" %%M` for each missing module. When `HP_ENV_MODE=conda`,
it uses `conda install -y -n "%ENVNAME%"`. PyInstaller is also installed via
`uv pip install --python "%HP_PY%" -q pyinstaller` in uv mode (line 2018).

This means `selfapps_warnfix.ps1` works correctly in uv-first lanes without any guard:
the full bootstrapper handles the uv/conda split internally. The test only checks for log
phrases (`[REPAIR] missing modules detected`) and EXE success, both of which work in uv mode.

### dep-check + uv mode lock file interconnection

`~environment.lock.txt` is the dep-check cache key. In conda mode it is written via
`conda list --export`. In uv mode it is written by copying `~dependency_installed.txt`
(run_setup.bat lines 1141-1145). This ensures `selfapps_depcheck.ps1` works correctly
in uv-first lanes: the lock file exists after run 1, and dep-check on run 2 correctly
finds all packages already in the lock and emits the skip log line.

`dep_check.py` is run for BOTH `HP_ENV_MODE=conda` and `HP_ENV_MODE=uv` (line 1048:
`if not "%HP_ENV_MODE%"=="conda" if not "%HP_ENV_MODE%"=="uv" goto :dep_check_done`).
For venv and system modes, dep_check is skipped entirely (no lock written, no skip check).

`HP_DEP_SKIP` is honored in uv mode too (line 1108: `if not defined HP_DEP_SKIP` guards
the `uv pip install` call), so second-run dep-check correctly skips pip install as well.

### HP_TEST_FORCE_UV_FAIL and HP_TEST_CORRUPT_UV interaction

`HP_TEST_FORCE_UV_FAIL=1` fires at `run_setup.bat` line 296 (BEFORE the cached-uv check
at line 302 where `HP_TEST_CORRUPT_UV` fires). If both are set simultaneously, the
FORCE_UV_FAIL gate fires first and the CORRUPT_UV test never reaches its trigger.

Fix (applied in `tests/selftest.ps1`): the corrupt-uv sub-bootstrap saves/clears/restores
`HP_TEST_FORCE_UV_FAIL` so that the corrupt-uv branch is correctly exercised in all lanes.

### Malformed pyproject.toml + uv venv failure (uv-first lanes)

`uv venv` reads `pyproject.toml` for `[project].requires-python` even without `--python`.
When pyproject.toml is malformed TOML, `uv venv` exits non-zero. In the uv-first real lane
(no conda installed), this cascades: `:uv_venv_fail` falls to `:try_conda_create`, but
`CONDA_BAT` is empty, so conda create also fails, and the bootstrap exits non-zero.

**Symptom**: `self.pyproject.malformed` fails in real/cache lanes (uv-first).
**Root cause**: `uv venv` runs in the project directory and hits the malformed TOML before
`HP_PYPROJ_DEPS` gets a chance to detect and warn about it.
**Fix** (in `:uv_venv_fail`): when `HP_UV_PROVIDING_PYTHON=1`, retry via
`uv run --no-project python -m venv .uv_env` which bypasses project discovery entirely.
On success, go to `:uv_venv_ready`. The `HP_PYPROJ_DEPS` path (line ~712) then naturally
detects the malformed TOML and emits `[WARN] pyproject.toml TOML parse error; falling back.`

**Note**: `UV_NO_CONFIG=1` does NOT help -- uv's own docs say: "Note that if a pyproject.toml
file is present, uv will still use the [project] metadata (e.g., requires-python) to guide
dependency resolution." Only `--no-project` truly bypasses pyproject.toml discovery.

**Note**: `~detect_python.py` reads pyproject.toml via REGEX (not TOML parser), so it exits 0
even on malformed TOML (just returns empty string). That's why `HP_UV_PROVIDING_PYTHON=1` is
set correctly, and the venv creation step is the first point of failure.

**Malformed TOML regex fallback detail** (tomllib unavailable on Python 3.9.x):
The regex must detect `[project` missing the closing `]` even without tomllib. The fix:
`re.search(r'^\[project\s*$', txt, re.MULTILINE)` -- matches `[project` at end of line
(with optional whitespace/CRLF). This exits 2 so the caller emits WARN. No false positives
for sub-tables like `[project.urls]` because `\s*$` requires end of line after `project`.

**Test assertion** (`tests/selftest.ps1` lines 599-643, all lanes, no HP_FORCE_CONDA_ONLY):
- Asserts: `[WARN] pyproject.toml TOML parse error` in log AND `exitCode == 0`
- Row: `self.pyproject.malformed`
- In conda-full lane: malformed TOML is detected by HP_PYPROJ_DEPS (conda create doesn't read TOML)
- In uv-first lane: the `:uv_venv_fail` retry path allows the bootstrap to continue so HP_PYPROJ_DEPS runs

### INVENTORY_B64 E2BIG pattern (publish_index.py)

Passing large data through step env vars (`INVENTORY_B64` was ~168 KB base64) overflows
Linux's `execve` ARG_MAX. Fix: read the same data from a file written to disk by the
inventory step instead of routing it through the process environment. Applied to
`tools/diag/publish_index.py` and `.github/workflows/batch-check.yml`.

General rule: NEVER pass data >32 KB through GitHub Actions step `env:` -- write to a
temp file in `$GITHUB_WORKSPACE` and read from disk instead.

### HP_FORCE_CONDA_ONLY as a test-override pattern

Some tests that specifically test conda behavior SET `HP_FORCE_CONDA_ONLY=1` themselves,
rather than relying on the CI lane. These tests are self-contained and work in all lanes
(including uv-first lanes, where they trigger Miniconda download if not already installed):

| Test | Why it sets HP_FORCE_CONDA_ONLY=1 |
|------|-----------------------------------|
| `selfapps_pipgap.ps1` (line 66) | Must test conda bulk fail + pip gap-fill path; conda is required for the bulk fail path |
| `tests/selftest.ps1` conda_retry block (line 939) | Must test conda bulk transient network retry; conda path required |
| `tests/selftest.ps1` conda_perpkg block (line 978) | Must test conda per-package fallback; conda path required |

Contrast these with tests that SKIP when conda is absent (reqspec, pyproject_precedence, pandas_excel):
those tests test non-conda-specific behaviors (translation, pyproject parsing) but happen to call
conda. They emit `skip=true` when conda is absent rather than triggering a download.

The distinction: if the test IS testing conda behavior -> force it; if the test happens to USE conda
as a side effect but is testing something else -> skip=true in uv-first lanes.

### HP_UV_BIN locality: why offline sub-bootstrap tests work in all lanes

`HP_UV_BIN` is set to `%HP_SCRIPT_ROOT%~uv_bin` (run_setup.bat line 290), where `HP_SCRIPT_ROOT`
is the directory containing the bootstrapper, not a system temp or user-global path. This has
a critical consequence for sub-bootstrap tests:

**When a test creates a fresh temp directory and copies run_setup.bat into it:**
- The sub-bootstrap's `HP_SCRIPT_ROOT` = the new temp dir
- `HP_UV_BIN` = `~selftest_foo\~uv_bin\` (empty, no uv.exe)
- `HP_OFFLINE_MODE=1` (set by the test) prevents re-downloading uv
- Result: uv is ALWAYS unavailable in the sub-bootstrap

This makes the fallback chain tests in `selfapps_ux_hardening.ps1` work correctly in uv-first
(real/cache) lanes even though those lanes normally use uv as the primary provider:

| Test | Env vars set | Why uv is bypassed |
|------|--------------|-------------------|
| `self.venv.fallback` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1 | HP_OFFLINE_MODE blocks uv download; fresh dir has no ~uv_bin |
| `self.ux.system.gate.real` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1, HP_TEST_FORCE_VENV_FAIL=1 | Same; forced chain: no-uv -> conda-fail -> venv-fail -> consent gate |
| `self.entry.override` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1 | Same; forced chain: no-uv -> conda-fail -> venv-succeed |

All three tests skip in conda-full lane (HP_FORCE_CONDA_ONLY=1 blocks system/venv fallbacks there).

**What NOT to do**: never set HP_UV_BIN to a user-global or TEMP-based path -- it would break this
isolation property and make sub-bootstrap tests depend on whether the parent job happened to
download uv already.

`PVW_UV_EXE` is a super-user override (line 284) that would also break this property, but CI does
not set it (confirmed by grepping batch-check.yml).

### selfapps_isolation.ps1: HP_CI_SKIP_ENV=1 bypasses all provider logic

The three tests in `selfapps_isolation.ps1` (crossdir, sameDir, req010.pythonpath) run the
bootstrapper with `HP_CI_SKIP_ENV=1` inherited from the CI environment. This causes run_setup.bat
to jump to `:ci_skip_entry` (lines ~1090-1196) which uses system Python and bypasses the entire
provider selection (no uv, no conda, no venv decision). These tests are completely lane-agnostic
and safe in all lanes including uv-first.

### selfapps_skiphooks.ps1: provider-independent, conda-full lane only

Declared "Lane: conda-full only (behavior is provider-independent)" in the file header. The test
runs a full bootstrap and checks that HP_SKIP_ENTRY_SMOKE=1 + HP_SKIP_EXE_SMOKERUN=1 prevents
user code execution while still building the PyInstaller EXE. No Get-CondaBatPath call. The test
does not assert anything about the Python provider -- it only checks that the EXE was built and
that no user code ran. It is restricted to conda-full by CI wiring, not by the test itself.

### selfapps_pandas_excel.ps1: conda-full lane only (CI wiring)

This test script calls `Get-CondaBatPath` and runs pandas/openpyxl translation via conda.
It IS wired to the conda-full lane only in `.github/workflows/batch-check.yml`.
The `skip=true` guard for `HP_FORCE_CONDA_ONLY -ne '1'` is currently dead code in CI,
but correct defensively if CI wiring ever changes.

All 6 NDJSON rows (`pandas_excel.translate`, `pandas_excel.conda.install`,
`pandas_excel.conda.install.req006`, `pandas_excel.runtime`,
`self.pandas.openpyxl.install`, `self.pandas.openpyxl.import`) emit `skip=true` in
the uv-first guard branch.

### uv Coverage Status

**Currently covered by CI:**
- `self.contract.uv` (contract-uv lane): verifies uv venv creation and pip install work
- `self.contract.uv.pyver` (contract-uv lane): verifies Python version forwarded to `uv venv --python X.Y`
- `self.uv.first.miniconda.skip` (contract-uv lane): verifies Miniconda is NOT downloaded when uv provides Python
- `self.contract.uv.fail` (contract-uv-fail lane): verifies graceful degradation when uv fails
- `self.dl.uv.fallback` (justme-test lane): PASSES with `skip=true` because HP_TEST_UV_DL_FALLBACK is not set

**Gap (Active Backlog):**
- The actual uv DL fallback URL code path (`HP_TEST_UV_DL_FALLBACK=1`) has no active CI lane.
  justme-test uses `HP_TEST_FORCE_UV_FAIL=1` which skips uv before any download attempt.
  Needs a dedicated non-gating lane that sets `HP_TEST_UV_DL_FALLBACK=1` without
  `HP_FORCE_CONDA_ONLY=1` and without `HP_TEST_NOT_ELEVATED=1` so uv download is reached.

### Skip pattern template (copy-paste for new conda-specific test blocks)

```powershell
# derived requirement: in uv-first lanes, Miniconda is not installed so these
# conda-specific tests are not applicable -- emit skip=true.
# In conda-only lanes (HP_FORCE_CONDA_ONLY=1), conda MUST be present; emit failures.
if ($env:HP_FORCE_CONDA_ONLY -ne '1') {
    $myPass = $true
    $myDetails.skip   = $true
    $myDetails.reason = 'conda-not-installed-uv-first'
} else {
    $myDetails.reason = "conda python missing: $condaPython"
    $myDetails.condaBatCandidates = $condaInfo.candidates
}
```

---

## Heuristic dep-augmentation (HP_PREP_REQUIREMENTS)

### pandas[excel] extras syntax

The `names_lower` list is built from `pip_specs` by splitting at version specifier chars
and lowercasing. The original code did NOT strip pip extras (`[excel]`) before the lookup,
so `pandas[excel]` was stored as `"pandas[excel]"` in `names_lower` and the check
`'pandas' in names_lower` returned `False`.

**Fix applied (2026-06-21):** Strip `[...]` from each name before lowercasing:
```python
names_lower = [re.sub(r"\[.*?\]", "", re.split(r"[<>=!~,\s]", value, maxsplit=1)[0]).strip().lower() for value in pip_specs]
```

Covered by `tests/test_heuristics.py::TestPandas::test_pandas_extras_triggers`.

The fix is load-bearing for the primary use case: users who copy `pandas[excel]` from
modern documentation into requirements.txt now get openpyxl and xlsxwriter injected.

---

## Embedded Helper Update Workflow

All helpers embedded in `run_setup.bat` as `HP_*` base64 vars have NO standalone source file.
The canonical source is the decoded base64. To update a helper:

1. Extract + decode:
   ```python
   import base64, re
   with open('run_setup.bat', 'r', encoding='ascii', errors='ignore') as f:
       for line in f:
           m = re.match(r'^set "HP_VARNAME=(.*)"$', line.rstrip('\r\n'))
           if m:
               print(base64.b64decode(m.group(1)).decode('ascii'))
               break
   ```
2. Edit the decoded Python source.
3. Re-encode:
   ```python
   import base64
   new_b64 = base64.b64encode(open('helper.py', 'rb').read()).decode('ascii')
   ```
4. Replace the `set "HP_VARNAME=..."` line in run_setup.bat.
5. Run `python tools/check_delimiters.py run_setup.bat` and the relevant unit test.

**Python version hazard reminder:** The helper will run on whatever Python `uv venv` selects,
which may be 3.9.x. Avoid 3.11+ stdlib. Test with `python3.9 helper.py` if available.
