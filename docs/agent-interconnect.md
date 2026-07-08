# Agent Interconnectedness Map -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-interconnect.md`
import in CLAUDE.md. It documents the non-obvious cross-component dependencies that
future agents must understand to avoid re-introducing known failures.

Standalone hazards, rules, budgets, and procedures (batch/CMD quirks, the CMD `set` line
limit, the embedded-helper workflow, the ambient-Python lesson, etc.) now live in
`docs/agent-lessons-learned.md`.

**Categorization principle:** interconnect = a dependency between two or more components
such that changing one requires understanding the other ("touch A, must understand B"). A
standalone discovered fact, hazard, budget, or procedure belongs in
`docs/agent-lessons-learned.md` instead.

**AGENT DIRECTIVE: When you discover a new interconnect or correct an existing one, update
this file immediately in the SAME commit (edit existing entries, do not only append). Keep
`docs/agent-lessons-learned.md` current too. The map must stay accurate.**

---

## Concurrent-instance lock (REQ-024) touches every exit path -- call-graph tracing method

The lock (`:acquire_lock`/`:lock_is_stale`/`:release_lock`, called near the top of the file
right after `%STATUS_FILE%` cleanup, released at `:die` and `:success`) is a cross-cutting
concern: **any future change that adds a NEW top-level process-terminating `exit /b` site, or
converts an existing `call`-based subroutine into a `goto`-only continuation of the main line,
must consider whether that site also needs `call :release_lock` before it.** This section
documents the call-graph tracing method used to scope the lock's release points, and its limits,
so a future agent doesn't have to rediscover them.

**Why release is hooked at `:die`/`:success` only, not all ~100 `exit /b` sites.** Before this
feature, `run_setup.bat` had 129 `:label` definitions and 55 top-level (unindented) `exit /b`
sites (100 total once indented/parenthesized ones are included). A naive count of lines matching
`exit /b` (including ones indented inside parenthesized blocks) is not a reliable proxy for
"process-terminating site" -- whether a given `exit /b` actually terminates the whole process or just
returns from a subroutine depends on the RUNTIME call stack at that point, not on whether the
label it lexically sits under was ever `call`ed -- CMD.EXE's `exit /b` returns to the nearest
active `call` frame, and a label reached purely via `goto` from *inside* an active call frame
(e.g. `:venv_canary_fail`, reached by `goto` from within `:try_venv_fallback`'s call frame) still
returns to `:try_venv_fallback`'s caller, not the whole process. A static, line-based CFG walk
(BFS over `goto`/`call`/fall-through edges, attempted while designing this feature) correctly
proves depth for pure goto/call/fall-through code, but breaks down at parenthesized
`if (...) ( ... ) else ( ... )` blocks: a bare `exit /b N` line lexically inside such a block is
only reached when the block's condition is true, and the walker has no notion of "skip to the
line after the matching close-paren" for the false branch without a full paren-balance parser --
early lines 45-52 (`if not exist "%~dp0" ( ... exit /b 1 )`) demonstrated this: the naive walker
treated that `exit /b 1` as *always* reached and stopped exploring right there, never proving
reachability for the other ~4000 lines that obviously do execute in a normal run. Building a true
paren-aware CFG parser was assessed as disproportionate effort for this feature.

**`tools/audit_batch_exit_paths.py`** (new, not wired into CI -- run by hand) captures the
label/call/exit inventory this section is based on: it lists every label, every `call :label`
site, and every `exit /b` site with its containing label and whether that label is ever `call`ed
anywhere in the file. It explicitly does NOT attempt the paren-aware CFG proof described above --
its own module docstring documents the same "called=False is a hint, not proof" limitation. Use
it as the starting point for a future exit-path audit (e.g. before reworking this lock feature,
or before adding a new top-level consent gate), not as a final answer on its own.

**The practical, sufficient answer instead:** CMD has no `finally`/`trap`, so a lock design that
depends on *proving* every exit path releases it is the wrong shape regardless of how good the
audit is -- a `Ctrl+C`, a killed process, a power loss, or a genuinely-missed exit site all bypass
any release hook unconditionally. The correct backstop is age-based staleness (already the
design), so the release hooks at `:die`/`:success` are an optimization (avoid leaving a stale
lock around for up to ~2 hours after an ordinary successful run or an ordinary handled failure),
not the correctness mechanism. Both labels were independently confirmed as the two universal
funnels for the normal flow: every `call`-based consent-gate decline (REQ-014 system-Python
consent, REQ-009 cascade consent, REQ-013 connectivity decline, the venv canary probe, etc.)
returns up its call chain and continues the bootstrap (possibly into a further fallback tier)
rather than terminating the process directly, and the EXE fast path's early success shortcut
(`:try_fast_exe`, called at line ~294, near the top of the file) also funnels through `:success`
(confirmed separately in the "EXE fast path vs env-state fast path" section below). The three
handful of truly-early, pre-label `exit /b 1` sites (workspace-path-invalid guards, lines ~47/52)
execute before the lock is ever acquired (lock acquisition is placed intentionally AFTER those
checks), so they need no release call by construction.

**If you add a new top-level (non-`call`ed) `exit /b` site to the main line in the future**, ask
whether it can be reached with an empty call stack (i.e., directly off a `goto` from the main
line, not from inside any `call`ed subroutine's continuation chain). If so, and if it is a
*routine* exit that a real user could hit often (not a crash), add `call :release_lock` before it
-- the same way `:die` and `:success` do -- so a normal repeated-decline pattern doesn't leave
stale locks for other users of the same folder to wait out.

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

### Provider cascade execution re-enters env-create (REQ-009/REQ-005.10 slice 3)

`:provider_cascade` (reached from the main line via `if defined HP_CASCADE_APPROVED goto
:provider_cascade`, just after `:run_entry_smoke` returns) re-attempts the dependency phase
under the next provider tier. **It does not re-implement env-create -- it reuses the existing
paths**, so anyone touching those paths must understand the cascade re-entry:

- `uv -> conda`: sets `HP_ENV_MODE=conda`, clears `HP_UV_PROVIDING_PYTHON`, sets
  `ENV_PATH=%MINICONDA_ROOT%\envs\%ENVNAME%`, then `goto :try_conda_create`. Because uv-first
  runs skipped Miniconda, `:cascade_acquire_conda` first downloads+installs it on demand
  (mirroring the normal acquisition at lines ~423-432; `MINICONDA_ROOT`/`CONDA_MAIN`/`CONDA_ALT`
  are already set near line 410 even in uv-first runs, so `:select_conda_bat` / `:try_conda_install`
  work). `:try_conda_create` ends with `goto :after_env_mode_selection`, which re-runs dep
  install + build.
- `conda -> venv`: `call :try_venv_fallback` (sets `HP_ENV_MODE=venv`), then
  `goto :after_env_mode_selection`. Suppressed when `HP_FORCE_CONDA_ONLY=1`.
- `venv -> system`: `call :try_system_fallback` (sets `HP_ENV_MODE=system`), then
  `goto :after_env_mode_selection`. **Reached in any run** -- the only gate is the REQ-014
  consent prompt inside `:try_system_fallback` (no env flag; `HP_ALLOW_SYSTEM_FALLBACK` is
  deprecated/ignored). In CI the consent gate auto-declines (`HP_CI_LANE`, or an explicit
  `HP_TEST_SYSCON_ANSWER=N`), so the cascade logs `cascading provider venv to system`, the gate
  declines, and `:cascade_system_unavailable` keeps the current build -- the cascade stops at
  system in CI without entering it. `HP_FORCE_CONDA_ONLY=1` suppresses this tier upstream (the
  cascade never leaves `:cascade_from_conda`).

**No-loop guarantee (touch one, understand all):** each tier is marked `HP_CASCADE_TRIED_<tier>`
the first time it is used as a cascade source, and `HP_ENV_MODE` only ever advances
(uv->conda->venv->system). Re-entry therefore cannot revisit a tier, and tiers exhaust to a
"keeping current build" terminal. If you add a new provider or reorder tiers, you MUST add a
matching `HP_CASCADE_TRIED_*` guard and keep the order monotonic, or the cascade can loop.

**`:after_env_mode_selection` re-entrancy:** the cascade relies on this label being safe to
re-enter (it recomputes REQ/DEP_SOURCE/entry/pyproject state from scratch). The EXE fast path
(`:try_fast_exe`, top of file) is NOT re-run on cascade, and `:run_entry_smoke`'s rebuild-skip
is gated on `HP_FASTPATH_USED` (unset on a fresh first build), so the next tier genuinely
rebuilds. Do not introduce first-run-only state into `:after_env_mode_selection` without
making it idempotent.

### uv uses managed-only CPython (UV_PYTHON_PREFERENCE)

`run_setup.bat` sets `UV_PYTHON_PREFERENCE=only-managed` at the top of the uv acquisition
block (before the `PVW_UV_EXE` branch and before the first uv invocation). Consequences that
ripple across components:
- Every uv command in the bootstrapper process (`uv run` detect, `uv venv`, `uv pip`)
  inherits it; uv never selects an ambient/system/conda interpreter.
- With no user constraint, `.uv_env` is the latest managed CPython; a user
  `runtime.txt`/`pyproject.toml` is still forwarded via `uv venv --python X.Y`.
- Tests that read the resulting `.uv_env` (e.g. `self.uv.managed.interpreter` in
  `selfapps_envsmoke.ps1`) depend on this; `harness.ps1` also statically asserts the `set`
  line via `uv.python.preference.configured`. The rationale and the embedded-helper Python
  baseline live in `docs/agent-lessons-learned.md`.

### Lanes and their conda state

| Lane | HP_FORCE_CONDA_ONLY | uv used | Miniconda installed | CONDA_BAT set |
|------|---------------------|---------|---------------------|---------------|
| conda-full | 1 | no | yes | yes |
| real | not set | yes (uv-first) | no | no |
| cache | not set | yes (uv-first) | maybe (cached) | maybe |
| justme-test | not set | no (HP_TEST_FORCE_UV_FAIL=1) | via JustMe | yes |
| contract-uv | not set | yes (forced) | no | no |
| uv-dl-fallback | not set | yes (HP_TEST_UV_DL_FALLBACK=1 forces primary URL fail, fallback URL used) | no | no |

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
| EXE fast path (`:try_fast_exe`) | `dist\<ENVNAME>.exe` exists AND `HP_FAST_CHECK` token = "fresh" | `[INFO] Fast path: reusing dist\<ENVNAME>.exe` (non-interactive/CI -- `HP_INTERACTIVE_RUN` unset) or `[INFO] Launching your program now via the cached standalone EXE (PyInstaller build): dist\<ENVNAME>.exe` (interactive -- see "Fail-fast probe (Slice 2b-C)" below) | All lanes |
| Env-state fast path (`:env_state_fast_path`) | `~env.state.json` valid, conda env python.exe present | `[INFO] Env-state fast path: reusing conda env <ENVNAME>.` | conda mode only; skipped when HP_UV_PROVIDING_PYTHON=1 |
| uv venv reuse | `.uv_env\Scripts\python.exe` exists AND `import pip` succeeds | `[INFO] uv: reusing existing .uv_env` | uv mode only |

**Critical order**: EXE fast path runs at line 222 (top of file, BEFORE provider selection).
If it fires, run_setup.bat goes directly to `:success`. uv/conda provider logic is never reached.
The env-state check (line 507) and uv venv reuse (line 544) are therefore only reached when
the EXE fast path does NOT fire (first run, or sources changed).

**`self.fastpath` test** (`selfapps_envsmoke.ps1` second run): matches `'Fast path: reusing'`
which appears in the EXE fast path log line ONLY on the non-interactive branch (real CI always
sets `HP_CI_LANE` at the job level, so this holds in every CI lane regardless of whether the
individual test file pins it locally -- see the "Accepted gap" entry in
`docs/agent-lessons-learned.md`). This works in ALL lanes (uv and conda) because the EXE fast
path is completely provider-independent. The test correctly validates the EXE fast path, not
the env-state or uv venv fast path.

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

**Malformed TOML regex fallback detail** (the helper must not assume `tomllib`; see the
embedded-helper Python baseline in `docs/agent-lessons-learned.md`):
The regex must detect `[project` missing the closing `]` even without tomllib. The fix:
`re.search(r'^\[project\s*$', txt, re.MULTILINE)` -- matches `[project` at end of line
(with optional whitespace/CRLF). This exits 2 so the caller emits WARN. No false positives
for sub-tables like `[project.urls]` because `\s*$` requires end of line after `project`.

**Test assertion** (`tests/selftest.ps1` lines 599-643, all lanes, no HP_FORCE_CONDA_ONLY):
- Asserts: `[WARN] pyproject.toml TOML parse error` in log AND `exitCode == 0`
- Row: `self.pyproject.malformed`
- In conda-full lane: malformed TOML is detected by HP_PYPROJ_DEPS (conda create doesn't read TOML)
- In uv-first lane: the `:uv_venv_fail` retry path allows the bootstrap to continue so HP_PYPROJ_DEPS runs

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
| `self.ux.system.gate.real` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1, HP_TEST_FORCE_VENV_FAIL=1, HP_TEST_SYSCON_ANSWER=N | Same; forced chain: no-uv -> conda-fail -> venv-fail -> REQ-014 consent gate (declines). **No HP_ALLOW_SYSTEM_FALLBACK** -- proves the tier is reachable in a default no-flag run. |
| `self.ux.system.gate.accept` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1, HP_TEST_FORCE_VENV_FAIL=1, HP_TEST_SYSCON_ANSWER=Y | Same forced chain, but ACCEPT routes into Tier 4: asserts `System Python (degraded)` provider selected + `consent: user accepted` (REQ-009 "system Python alone"). |
| `self.entry.override` | HP_OFFLINE_MODE=1, HP_TEST_FORCE_CONDA_FAIL=1 | Same; forced chain: no-uv -> conda-fail -> venv-succeed |

These tests skip in conda-full lane (HP_FORCE_CONDA_ONLY=1 blocks system/venv fallbacks there).
Note: `HP_TEST_SYSCON_ANSWER` (Y/N) deterministically answers the REQ-014 consent prompt; it is
checked BEFORE the `HP_CI_LANE` auto-decline, so `=Y` reaches the system tier even in CI.

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
- `self.contract.uv.pyver` (contract-uv lane): verifies an exact runtime.txt version is
  forwarded to `uv venv --python X.Y`
- `self.contract.uv.pyver.range` (contract-uv lane): verifies a loose pyproject
  `requires-python = ">=X.Y"` forwards the RANGE to uv so it resolves the latest satisfying
  managed CPython (interpreter minor in `.uv_env\pyvenv.cfg` is greater than the floor), not
  the floor. This is the floor-vs-pin fix: `run_setup.bat` emits `HP_UV_PY_REQ` (range for
  loose forms, bare `X.Y` for exact) and an operator-free `HP_UV_PY_DISP` for `:log`.
- `self.contract.uv.pyver.exactpin` (contract-uv lane): verifies an exact `==X.Y` pin stays
  pinned to `X.Y` and does not drift to latest after the range change.
- `self.uv.first.miniconda.skip` (contract-uv lane): verifies Miniconda is NOT downloaded when uv provides Python
- `self.contract.uv.fail` (contract-uv-fail lane): verifies graceful degradation when uv fails
- `self.uv.managed.interpreter` (selfapps_envsmoke.ps1, all uv-first lanes): verifies the
  `.uv_env` base interpreter is a uv-managed CPython, not an ambient/system Python
- `uv.python.preference.configured` (harness.ps1, static): verifies the
  `UV_PYTHON_PREFERENCE=only-managed` line is present in run_setup.bat
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

## Single-verification smoke model (REQ-018 2b-A.2) couples run_setup.bat to envsmoke/skiphooks

The bootstrapper runs the user's code for verification at most ONCE per invocation. Touching the
smoke flow in `run_setup.bat` requires understanding the assertions in
`tests/selfapps_envsmoke.ps1` and `tests/selfapps_skiphooks.ps1`, which are coupled by exact log
strings and run artifacts:

- **Removed:** the pre-build interpreter smoke (in `:run_entry_smoke`) and
  `:try_entry_smoke_after_warnfix`. The EXE path no longer runs the app twice (interpreter then EXE).
- **EXE path = sole verification via the timed EXE smoke** (`:run_exe_smokerun`). To keep the
  existing tests passing WITHOUT re-pointing them, the EXE smoke now emits the **same vocabulary**
  the interpreter smoke used and **captures the EXE stdout/stderr** to the app root:
  - `[INFO] Running entry script smoke test via packaged EXE.` -> matches envsmoke `$hasEntryRun`
    (`'Running entry script smoke test'`).
  - `[INFO] Entry smoke exit=%HP_EXE_EXIT%` at `:smokerun_ndjson` -> matches `$hasEntryExit`
    (`'Entry smoke exit=0'`) when the EXE verifies clean.
  - The EXE smoke runs from `pushd dist` (CWD = dist\) -- the working directory a frozen EXE has
    always used here, and **load-bearing**: `selfapps_exedata_fail`'s app opens a CWD-relative
    `config.json` that MUST be absent at runtime (xfail), which only holds when CWD is `dist\`, not
    the app root (the app root contains `config.json`). Do NOT switch the EXE smoke to run from the
    app root -- it makes that file findable and turns the xfail into an xpass.
  - `$so.Result | Set-Content -Path '..\~run.out.txt'` (and `~run.err.txt`) from inside `pushd dist`
    captures the EXE's stdout/stderr to the app root so envsmoke `$tokenFound` (`'smoke-ok'`, on
    stdout) is satisfied by the EXE run instead of the deleted interpreter run.
  - **sys.argv[0]-relative files land in dist\ for a frozen EXE.** An app that writes next to
    `sys.argv[0]` (e.g. the spaced-path app's `~smoke_token.txt`, written to
    `dirname(abspath(sys.argv[0]))`) lands it in `dist\` under the EXE, not the app root where the
    interpreter would. `selfapps_envsmoke.ps1` therefore reads the spaced-path token from BOTH the
    app root and `dist\` (`$spaceTokenDist`). This is an inherent EXE-vs-script behavior difference,
    not something the bootstrapper can normalize.
  **If you change any of these strings/paths, envsmoke `$bootstrapPass` /
  `self.env.smoke.run` / `self.prime.run` / `self.prime.bootstrap` break.** `harness.ps1`
  `batch.smoke.single_verify` statically guards them.
- **No-EXE path** (system-Python build declined, or build skipped) runs the interpreter ONCE via
  `:verify_no_exe_interpreter` (after the build gate), emitting the same vocabulary. It is
  **UNTIMED on purpose** (in those providers the interpreter run IS the user's run, not a throwaway
  -- hard-killing a long-running app would have no recourse). It is skipped when `dist\<env>.exe`
  exists (EXE smoke handled it), `HP_FASTPATH_USED` (fast path ran it), or `HP_SKIP_ENTRY_SMOKE`.
- **skiphooks** (`HP_SKIP_ENTRY_SMOKE` + `HP_SKIP_EXE_SMOKERUN`) still asserts no user code ran:
  `:run_exe_smokerun` exits at the skip check BEFORE the vocab line, and
  `:verify_no_exe_interpreter` exits on `HP_SKIP_ENTRY_SMOKE`, so `'Running entry script smoke test'`
  is never emitted -> `$noUserCode` holds.
- **Shipped in 2b-C: fail-fast probe for the two previously-untimed runs** (`:try_fast_exe`'s cached
  EXE reuse and `:verify_no_exe_interpreter`). See the dedicated "Fail-fast probe (Slice 2b-C)"
  section below for the full mechanism, state variables, and the interconnects that touching either
  call site must respect (CWD-per-call-site, the `HP_FASTPATH_USED`/`HP_SMOKE_RC` decoupling fix,
  and the shared `:run_failfast_probe` subroutine both now route through).
- The `~run.out.txt` capture happens on the INITIAL EXE smoke run, before any hidden-import recovery, so
  after a recovery rebuild it reflects the pre-recovery run (diagnostic-only; token tests do not hit
  recovery). The fail-fast probe's own capture (interactive branch of `:try_fast_exe` /
  `:verify_no_exe_interpreter`) is a SEPARATE write of the same two files, pre-truncated at the start
  of `:run_failfast_probe` -- see the dedicated section below for why that pre-truncation matters.

## Fail-fast probe (Slice 2b-C): shared state machine for the two untimed launch points

`:try_fast_exe` (cached EXE reuse) and `:verify_no_exe_interpreter` (no-EXE interpreter run) both
launch user code with NO timeout at all in CI/automation (unchanged, plain `cmd` redirect). For a
real interactive double-click user (`HP_INTERACTIVE_RUN` set -- see `:compute_interactive_run`,
mirrors `:pick_entry_interactive`'s `NOINPUT`/`HP_NONINTERACTIVE`/`HP_CI_LANE` signals, plus
`HP_TEST_FORCE_INTERACTIVE_PROBE=1` to force the branch under `HP_CI_LANE` for CI coverage), both
call the shared `:run_failfast_probe` subroutine instead, which launches via
`~failfast_probe.ps1` (`HP_FAILFAST_PROBE`, a base64 embedded helper emitted through the existing
`:emit_from_base64` mechanism -- NOT an inline `-Command` one-liner, deliberately: the two-stage
wait needs interpolated strings, and `.ps1` file content sidesteps every cmd.exe quote-nesting
hazard an inline `-Command "..."` string would hit here). The helper does `WaitForExit(HP_FAILFAST_PROBE_MS)`
(default 10000ms, distinct from the unrelated ~30s hard-kill cap used by `:run_exe_smokerun`/
`:hidden_import_recover` -- that is a force-kill ceiling for the fresh-build verification run, the
ONLY run this bootstrapper ever kills; this probe window is purely a classification checkpoint,
never a ceiling) then, if the process is still running, a SECOND, UNBOUNDED `WaitForExit()` with no
`Kill()` call anywhere.

**Touch either call site, must understand the other, plus the top-of-file success gate:**
- Both callers set `HP_PROBE_EXE` / `HP_PROBE_ARGS` (raw, UNQUOTED -- the helper quotes it via
  `'"' + $rawArgs + '"'`, which only works correctly for a SINGLE path argument; do not repurpose
  `HP_PROBE_ARGS` for a multi-token command line) / `HP_PROBE_CWD` before calling
  `:run_failfast_probe <site>`. **CWD is preserved per call site exactly as before this slice**:
  `:try_fast_exe` runs from the app root (`%CD%`, no `pushd dist`) and `:verify_no_exe_interpreter`
  also runs from the app root -- neither adopts `:run_exe_smokerun`'s `pushd dist` CWD (load-bearing
  for `selfapps_exedata_fail`'s CWD-relative `config.json` check; see the paragraph above). If you
  ever unify these CWDs, re-verify that xfail test.
- `:run_failfast_probe` always leaves `HP_SMOKE_RC` set to the true final exit code (whether the
  process exited fast or only after the unbounded continuation) and `HP_PROBE_EXCEEDED` set (`1`)
  iff the probe window was crossed. `:try_fast_exe`'s discard-and-rebuild block is gated on
  `if not "%HP_SMOKE_RC%"=="0" if not defined HP_PROBE_EXCEEDED` -- once a process is classified
  alive/healthy at the probe, a LATER non-zero exit is presumed to be the user's own program outcome
  (not proof of a stale artifact) and the cached EXE is kept, never discarded.
- **The silent-success bug this closed:** the top-of-file fast-path caller (`run_setup.bat`, near
  the very top, before provider selection) used to gate its `goto :success` shortcut on
  `HP_FASTPATH_USED` alone, with no check of the run's outcome -- harmless before this slice because
  any non-zero `HP_SMOKE_RC` always cleared `HP_FASTPATH_USED` too (inside `:try_fast_exe`'s old
  unconditional discard). Once the probe's "don't discard past the probe window" rule could leave
  `HP_FASTPATH_USED` set through a real later failure, that same shortcut would have silently
  reported full bootstrap success while hiding the failure. Fixed by computing
  `HP_FASTPATH_RUN_FAILED` (true only when `HP_SMOKE_RC` is DEFINED and non-"0" -- empty/undefined
  `HP_SMOKE_RC` still means "no real failure observed," e.g. the REQ-012
  `HP_SKIP_EXE_SMOKERUN` skip-without-running case, which must still take the zero-friction path)
  and branching the log message on it before `write_status`/`goto :success`; `HP_BOOTSTRAP_STATE`
  stays `ok` either way (env/build genuinely succeeded; a runtime bug in the user's own code is not
  something a rebuild could fix -- matches the "User-code exit-code semantics" item in
  `CLAUDE.md`'s Active Backlog), but the console/log now always shows the true
  `[STATUS] Run Status: ...` outcome first. This second call site was recomputed with the exact
  same `HP_FASTPATH_RUN_FAILED` guard (see the next bullet).
- **Both `:try_fast_exe` call sites now carry this guard, not just the top-of-file one.** The
  second call site (inside `:run_entry_smoke`'s build gate, `if defined HP_FASTPATH_USED (...)`
  just before the PyInstaller build block) recomputes `HP_FASTPATH_RUN_FAILED` fresh as its own
  top-level statement and branches the same way. It is normally unreachable with a real failure
  today -- any first-call success or post-probe-failure outcome already took `goto :success`
  before this point -- but a future provider-cascade re-entry (`:after_env_mode_selection`) could
  reach it with `HP_FASTPATH_USED` still set from a probe-classified alive-then-failed run, and
  this closes that gap defensively rather than leaving a second, unguarded copy of the same logic.
- **cmd.exe parse-time-expansion hazard, avoided via goto, not if/else, at both call sites.** An
  earlier revision of this slice launched the process and read `set "HP_SMOKE_RC=%ERRORLEVEL%"`
  (plus the immediate SUCCESS/FAILED branch) INSIDE the non-interactive `else ( ... )` clause of
  the `if defined HP_INTERACTIVE_RUN (...) else (...)` dispatch. cmd.exe expands every `%VAR%` in
  a parenthesized block ONCE, at parse time, using values from before the block started -- so
  `%ERRORLEVEL%` (and every in-block `%HP_SMOKE_RC%` read) silently froze to whatever it was right
  before the dispatch began (almost always `"0"`), meaning a genuinely broken cached EXE was NEVER
  discarded in the legacy/CI branch. Both `:try_fast_exe` and `:verify_no_exe_interpreter` now use
  `if defined HP_INTERACTIVE_RUN goto :<label>_probe` instead, so each branch's statements are
  parsed and executed as fresh top-level lines -- see
  `docs/agent-lessons-learned.md` "Provider-cascade dispatch is goto-based on purpose" for the same
  pattern used elsewhere in this file, and do not reintroduce a parenthesized if/else around a
  launch+`%ERRORLEVEL%`-capture sequence at either call site.
- `:try_fast_exe`'s legacy (non-interactive) branch also gained a `[STATUS] Run Status:
  SUCCESS/FAILED` line for parity (it previously never emitted `[STATUS]` telemetry at all, unlike
  `:verify_no_exe_interpreter` and `:run_exe_smokerun`) -- purely additive, does not change any
  branch/goto target, so it does not affect CI determinism for `self.fastpath` /
  `self.exe.fastpath.graceful`.
- NDJSON row `self.failfast.probe` (gated on `HP_NDJSON`, same convention as `self.exe.smokerun`)
  carries `details.site` (`'fastpath'|'interpreter'|'checkpoint'` -- the third value added when
  `:run_postexec_checkpoint`, Slice 2b-C's post-execution checkpoint, shipped; see that section
  below) so one schema covers all three call sites. Because the checkpoint can trigger this same
  subroutine a SECOND time within one bootstrap invocation, `self.failfast.probe` is no longer
  guaranteed to appear at most once per `HP_NDJSON` stream -- a consumer must key off
  `details.site` to distinguish the primary verification's row from an accepted checkpoint's row,
  not assume a single row per run.
- Test coverage: `tests/selfapps_failfast_probe.ps1` (`self.failfast.probe.fastfail`,
  `self.failfast.probe.alive`), forced via `HP_TEST_FORCE_INTERACTIVE_PROBE=1` under
  `HP_CI_LANE=test` (mirrors the `HP_TEST_FORCE_PICKER` pattern) since CI is otherwise always
  non-interactive. `tests/harness.ps1`'s `batch.failfast.probe` statically guards the interactivity
  subroutine, the shared probe subroutine, the test override, the default probe window, the
  `HP_PROBE_EXCEEDED` state var, and the decoupling fix.

## Post-execution checkpoint (Slice 2b-C, second half): the elective second run

`:run_postexec_checkpoint` is the other half of 2b-C promised by the original REQ-018 design doc
(the fail-fast probe above shipped first, in a separate PR). It is a **consent gate**, not a probe
mechanism -- it follows the SAME 3-branch template as `:system_build_consent_gate` /
`:cascade_consent_gate` / `:system_python_consent_gate` (echo the prompt UNCONDITIONALLY, then
`HP_TEST_CHECKPOINT_ANSWER` override checked first, then `HP_CI_LANE` auto-decline, then
interactive `set /p`) -- **not** the `HP_INTERACTIVE_RUN`/`HP_TEST_FORCE_INTERACTIVE_PROBE`
convention the fail-fast probe uses. Do not conflate the two patterns: `HP_INTERACTIVE_RUN`
silently SKIPS a branch under `HP_CI_LANE` (no prompt text at all in CI); the consent-gate pattern
always ECHOES the prompt even when auto-declining, so a `self.checkpoint.*` test can assert the
prompt text is shown regardless of lane.

**What it does and why it is safe to call unconditionally:** `:run_postexec_checkpoint <site>` is
called at the end of every place that already printed `[STATUS] Run Status: ...` telemetry for a
FRESH verification run -- `:smokerun_ndjson` (after the EXE smoke + its NDJSON emission) and both
branches of `:verify_no_exe_interpreter` (the legacy branch, and after `:run_failfast_probe
interpreter` returns in `:verify_no_exe_probe`). It is deliberately **never** called from
`:try_fast_exe`'s fast-path reuse -- the locked design requirement is "Fast path = ZERO friction...
do NOT add a prompt or flag to the fast path," and since the checkpoint gate itself would decline
silently-but-still-echo a prompt in CI, adding the call there would violate that zero-friction
guarantee even on the auto-decline path. On accept, it reuses `:run_failfast_probe` (site
`'checkpoint'`) for the actual second launch rather than a fourth ad hoc process-launch mechanism
-- same never-kill, two-stage-wait guarantee as the fail-fast probe's own interactive branch.

**State it touches, and why nothing downstream breaks:** the checkpoint's accepted run reuses
`HP_PROBE_EXE`/`HP_PROBE_ARGS`/`HP_PROBE_CWD` (cleared and reset, same as any other
`:run_failfast_probe` call), and via `HP_PROBE_OUT`/`HP_PROBE_ERR` writes to distinct
`~checkpoint_run.out.txt`/`~checkpoint_run.err.txt` files rather than the FIRST run's
`~run.out.txt`/`~run.err.txt` (see the `:run_failfast_probe` header comment above --
`HP_PROBE_OUT`/`HP_PROBE_ERR` exist specifically so this elective second run cannot clobber the
real verification's captured output). `HP_SMOKE_RC`/`HP_PROBE_EXCEEDED` are explicitly
**saved before and restored after** the `:run_failfast_probe checkpoint` call
(`HP_CHECKPOINT_SAVED_SMOKE_RC`/`HP_CHECKPOINT_SAVED_PROBE_EXCEEDED`) -- NOT left overwritten by
the second run's outcome -- because they belong to the FIRST (real) verification run in the
caller's namespace and any code a caller might add after the checkpoint call (before its own
`exit /b 0`) must still see the FIRST run's result, not the elective diagnostic run's. The elective
run's own outcome is only ever surfaced via its own `[STATUS]`/NDJSON emission inside
`:run_failfast_probe checkpoint` itself, never propagated back into the caller's `HP_SMOKE_RC`.

**Cascade re-entry can offer the checkpoint more than once per bootstrap.** `:after_env_mode_selection`
(see "Provider cascade execution re-enters env-create" above) is re-entrant, so a REQ-009 provider
cascade (uv -> conda -> venv -> system) that reaches a NEW verification run at any of the three
call sites offers a FRESH checkpoint prompt each time. This is intentional, not a bug: each cascade
tier is a genuinely different build/environment, so a fresh "run it again to check" offer is
correct per tier -- but it does mean `self.checkpoint.*`-style assertions on a cascading run must
not assume exactly one prompt occurrence, and a real interactive user could see the prompt more
than once in a single double-click session if their run happens to cascade through providers.

Test coverage: `tests/selfapps_postexec_checkpoint.ps1` (`self.checkpoint.accept` via
`HP_TEST_CHECKPOINT_ANSWER=Y`, `self.checkpoint.decline` via the default/`HP_CI_LANE` path),
asserting the prompt is shown in both cases and the run footprint is exactly two vs. one
`Entry smoke exit=0` occurrences. `tests/harness.ps1`'s `batch.postexec.checkpoint` statically
guards the subroutine, the test override, the unconditional prompt echo, both log lines, and that
all three call sites are still wired (`call :run_postexec_checkpoint` count `-ge 3`).
