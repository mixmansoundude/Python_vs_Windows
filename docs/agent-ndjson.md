# NDJSON Surface -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-ndjson.md`
import in CLAUDE.md. It lists all known NDJSON rows by lane and test source.

The diagnostics site is the authoritative source of truth for live row counts:
https://mixmansoundude.github.io/Python_vs_Windows/

**AGENT DIRECTIVE: When new NDJSON rows are added (new selfapps files, new harness checks),
update this file in the same commit. Row IDs listed here act as a registry to catch
accidental removal or unexpected additions.**

**House rule: distill to the load-bearing rule; move the narrative to
`docs/agent-closed-backlog.md`.** This file's job is the registry itself (row id -> emitting
test/lane/mechanism) -- keep annotations to what a row means and how it's gated, not a retelling
of the bug that motivated adding it. If a row's own mechanism is already documented at length in
`docs/agent-interconnect.md` or `docs/agent-lessons-learned.md`, point there instead of
re-explaining it here. See CLAUDE.md's Active Backlog Item 34 for the restructuring pass this
principle is driving.

---

## CI-artifacts NDJSON (selfapps tests, conda-full lane)

```
self.harness.started, self.bootstrap.state, self.empty_repo.msg,
self.empty_repo.no_spurious_warn,
self.env.smoke.conda, self.env.smoke.run, self.env.smoke.uv, envsmoke.run,
self.uv.managed.interpreter,
self.exe.build, self.exe.run, self.exe.build.xfail,
self.exe.smokerun.xfail, self.exe.smokerun.exedata.xfail, self.exe.smokerun.exedyn.xfail,
self.exe.fastpath.graceful, self.skiphooks.combined,
self.fastpath,
self.failfast.probe.fastfail, self.failfast.probe.alive, self.failfast.probe,
self.checkpoint.accept, self.checkpoint.decline,
self.entry.entry1, self.entry.entryA, self.entry.entryB, self.entry.entryC, self.entry.entryD,
self.entry.helper.invoke.absent, self.entry.results, self.entry.spaced-path, self.entry.picker,
self.entry.picker.overflow,
self.entry.req011.crossdir, self.entry.req011.sameDir, self.isolation.req010.pythonpath,
entry.single.direct, entry.expected, helper.invoke,
self.envname.hyphen, self.envname.ampersand, self.envname.longname, self.size.tripwire,
reqspec.translate.{gte,eq,compat,gt,neq,lte}, reqspec.conda.dryrun,
reqspec.conda.channelpin, reqspec.conda.dryrun.failcase,
reqspec.conda.channelpin.req006, reqspec.conda.dryrun.req006,
reqspec.gte.explicit,
reqspec.install.import, reqspec.ingest.translate,
reqspec.ingest.conda.dryrun, reqspec.ingest.install.import,
self.depcheck.install, self.depcheck.skip,
pipreqs.install, pipreqs.run,
self.parse_warn.table,
self.exe.warnfix.install, self.exe.warnfix.pass, self.exe.warnfix.xfail,
self.exe.warnfix.real, self.exe.warnfix.real_warnfix,
self.exe.warnfix.real_warnfix_delayed,
self.collect.submodules,
self.exe.hidden_import, self.exe.hidden_import.exhaust,
self.preflight.syntax,
self.preflight.no_powershell, self.preflight.ps_check_fail, self.preflight.lf_only,
self.cascade.detect, self.cascade.consent, self.cascade.timed,
self.cascade.exec (uv lane only -- selfapps_cascade.ps1; non-gating),
self.cascade.conda_create_fail (uv lane only -- selfapps_cascade_conda_create_fail.ps1; non-gating),
self.layered_e2e.chain (cache lane only -- selfapps_layered_e2e.ps1; non-gating),
self.gribapi_hook_probe.hidden_import (conda-full lane only -- selfapps_gribapi_hook_probe.ps1; non-gating),
self.conda.bothfail (uv lane only -- selfapps_conda_bothfail.ps1; non-gating),
self.exe.build.tiera (uv lane only -- selfapps_nuitka_tiera.ps1; non-gating),
self.exe.tiera.hidden_skip (uv lane only -- selfapps_nuitka_tiera_hidden_skip.ps1; non-gating),
self.optbuild.offer (uv lane only -- selfapps_optimized_build.ps1; non-gating),
self.parse_warn.table.v6, self.parse_warn.pytest,
self.heuristics.pytest,
self.pytest.unit,
self.runtime.writeback,
self.pandas.openpyxl.install, self.pandas.openpyxl.import,
pandas_excel.translate, pandas_excel.conda.install, pandas_excel.conda.install.req006,
pandas_excel.runtime,
pipgap.conda.miss, pipgap.pip.fill, pipgap.import,
pyvisa.detect, pyvisa.nivisa.branch, pyvisa.nivisa.outcome, pyvisa.nivisa.reason, pyvisa.nivisa.disabled,
pyproject.precedence.detect, pyproject.precedence.writeback,
pyproject.dep.detect, pyproject.dep.noproj,
self.prime.bootstrap, self.prime.run, self.prime.spaced-path,
self.prime.exe.build, self.prime.exe.run,
self.ux.connectivity.offline.n, self.ux.connectivity.prompt.shown,
self.ux.connectivity.offline.uv.skip, self.ux.connectivity.offline.conda.skip,
self.ux.connectivity.online, self.ux.connectivity.retry,
self.ux.system.gate.n, self.ux.system.gate.prompt, self.ux.system.gate.real, self.ux.system.gate.accept,
self.ux.gitignore.merge, self.ux.gitignore.preserve, self.ux.gitignore.idem,
self.ux.gitattributes.merge, self.ux.gitattributes.idem,
self.ux.postflight,
self.venv.fallback, self.venv.canary_fail, self.venv.nopip_retry, self.entry.override,
self.embed.fallback.decline, self.embed.fallback.real, self.embed.dl.retry
```

## justme-test lane rows (flag-triggered)

```
conda.install.justme
```

## dl-fallback lane rows

### justme-test lane (HP_TEST_CONDA_DL_FALLBACK=1 + HP_TEST_FORCE_UV_FAIL=1)

`self.dl.conda.fallback` fires as a real test (Miniconda fallback URL exercised).
`self.dl.uv.fallback` passes with skip=true (HP_TEST_FORCE_UV_FAIL bypasses uv before download).

```
self.dl.conda.fallback, self.dl.uv.fallback
```

### uv-dl-fallback lane (HP_TEST_UV_DL_FALLBACK=1, non-gating)

`self.dl.uv.fallback` fires as a real test (primary uv URL replaced with invalid URL;
fallback URL is tried and uv is acquired). `self.dl.conda.fallback` passes with skip=true
(Miniconda DL fallback is not exercised in this lane).

```
self.dl.conda.fallback, self.dl.uv.fallback
```

## conda-full lane rows (HP_TEST_CONDA_UPDATE=1, flag-triggered)

NOT currently wired to CI; conda base update is implemented in run_setup.bat but
HP_TEST_CONDA_UPDATE injection was removed because it causes conda solver corruption
in shared CI runners.

```
self.conda.base.update  (test file: tests/selfapps_conda_update.ps1 -- not run in CI)
```

## contract-uv lane rows (flag-triggered)

```
self.contract.uv
self.contract.uv.pyver
self.contract.uv.pyver.range
self.contract.uv.pyver.exactpin
self.uv.first.miniconda.skip
```

## contract-uv-fail lane rows (HP_TEST_UV_FAIL=1, flag-triggered)

```
self.contract.uv.fail
```

## Dynamic-tests NDJSON (dynamic_tests.py, selftest artifact `dynamic/` subdirectory)

```
pr.to_conda (x many), pr.pandas.openpyxl, pr.pandas.xlsxwriter,
pr.requests.certifi, pr.sqlalchemy.pymysql, pr.matplotlib.tk,
pr.cryptography.cffi, pr.pycryptodome.cffi,
app.visa.detect, app.pyserial.detect,
dp.pep440 (x many), dp.detect.runtime, dp.detect.pyproject,
entry.select.single, entry.select.main_vs_app, entry.select.common_vs_generic,
helpers.run_setup, bootstrap.status,
helpers.decode.~detect_python.py, helpers.decode.~prep_requirements.py,
helpers.decode.~print_pyver.py, helpers.decode.~detect_visa.py,
helpers.decode.~find_entry.py
```

**Backfilled 2026-07 via `tools/check_ndjson_registry.py`'s new AST-based Python scan.** The 7
`helpers.*`/`bootstrap.status` rows above were always emitted (`ensure_extracted()`'s payload-decode
loop and `main()`'s status-file read at the top of `tests/dynamic_tests.py`) but were invisible to
this registry until the scanner learned to parse Python. `helpers.run_setup` fires only on the rare
`run_setup.bat missing` guard clause (a hard `SystemExit(1)` before any other row); `bootstrap.status`
fires exactly once per `dynamic_tests.py` run (pass/fail depending on whether `~bootstrap.status.json`
parses); the 5 `helpers.decode.*` rows fire once per embedded helper payload
(`~detect_python.py`/`~prep_requirements.py`/`~print_pyver.py`/`~detect_visa.py`/`~find_entry.py`)
decoded out of `run_setup.bat`.

## Test-logs NDJSON (harness/selftest, additional rows)

```
file.hash, bootstrap.state, bootstrap.exit, emit.extract (x many),
batch.delayed.off, batch.delayed.enable_absent, batch.bang.scan,
conda.channels, pipreqs.flags, pyi.onefile, log.rotate, tilde.naming,
visa.detect, emit.helpers, env.state.write, dep.check.parse_lock,
dp.compat, prep.multi.constraint, batch.paren.balance, env.foldername,
conda.path, conda.url, env.mode,
self.warnfix.platform_filter, self.exe.smokerun, helper.find_entry.syntax, entry.helper.ok,
self.cache.corrupted, self.cache.bootstrap.failed, self.cache.selfheal.fired,
meta.env.mode, workflow.lint,
version.metadata,
host.env.os, host.env.ps, host.env.python,
batch.req009.venv_unconditional, batch.req009.provider_logs, batch.req009.cascade_detect, batch.req009.cascade_consent, batch.req009.cascade_exec,
batch.req010.isolation, batch.req011.dircheck, batch.req012.skiphooks,
batch.req002.findentry_cli, batch.req002.findentry_run, batch.req002.entry_log, batch.req002.findentry_payload,
batch.req002.picker,
batch.ux.pause.gated,
batch.dep.diff.trace,
batch.conda.warmup,
batch.req013.connectivity,
batch.req014.consent,
batch.req005.warn_gate,
batch.conda.probe.deferred,
uv.python.preference.configured,
batch.progress.conda_create, batch.progress.pyi_build,
batch.pyi.collect.precheck,
batch.pyi.hidden_import.recover,
batch.smoke.kill_warn,
batch.preflight.compile,
batch.req007.provider_build,
batch.smoke.telemetry,
batch.smoke.single_verify,
batch.failfast.probe,
batch.postexec.checkpoint,
batch.dll_bundle.ndjson,
batch.dll_bundle.pct_sanitizer,
batch.dll_bundle.second_pass,
self.dll_bundle.recover,
self.bootstrap.state, self.empty_repo.msg, self.empty_repo.no_spurious_warn,
self.empty_repo.pytxt_hint,
self.harness.started,
self.stub.fastpath, self.stub.rebuild, self.stub.state_skip,
self.stub.conda_retry, self.stub.conda_create_retry, self.stub.conda_perpkg, self.stub.pip_warn,
self.stub.pipreqs_version_fail,
self.stub.lock_no_leak, self.stub.lock_held_decline, self.stub.lock_stale_evict,
self.stub.low_disk_warn,
self.pipreqs.warn.gated,
self.dep.diff.trace,
self.warn.onedrive, self.warn.longpath, self.warn.path_negative, self.warn.sysdir,
self.guardrail.g1, self.guardrail.g2, self.guardrail.g3,
self.pep723.valid, self.pep723.malformed, self.pep723.pyproject.override,
self.pyproject.malformed,
self.corrupt.conda.detect,
self.corrupt.conda.heal.decline,
self.corrupt.conda.heal.accept,
self.corrupt.conda.override_exit,
self.corrupt.uv.detect,
diag.conda.available, diag.conda.available.gate
```

`self.corrupt.conda.override_exit` (CLAUDE.md Active Backlog item 12) covers the
`PVW_CONDA_EXE` super-user-override's corrupt-conda path (`:corrupt_override_exit`, distinct
"fix manually, do not self-heal" messaging) -- unlike its three `self.corrupt.conda.*` siblings
above, this scenario is NOT gated on Miniconda already being on disk: setting `PVW_CONDA_EXE`
(to any path, real or not) unconditionally sets `CONDA_BAT=%PVW_CONDA_EXE%` in `run_setup.bat`
before the Miniconda install-if-missing block even runs, so the corruption-check gate
(`if defined CONDA_BAT ...`) fires regardless of whether Miniconda was ever installed anywhere
in the job -- self-contained by construction, no CI-ordering dependency (unlike
`self.conda.bothfail`, above).

`self.dll_bundle.recover` (inline `run_setup.bat`'s `:emit_dll_bundle_row`, called from all 7
outcome points inside `:dll_bundle_recover` -- CLAUDE.md Item 24 / `docs/prd-conda-native-dll-
bundling.md`) is a CodeRabbit review finding on PR #414: the native-DLL bundling repair loop's
detected/skipped/repaired/unlocatable/failed outcomes previously only reached `:log`'s console
text, with no machine-readable record. `details.state` is one of `skipped_nuitka` (a Nuitka-built
EXE, repair not attempted), `skipped_non_conda` (a non-conda provider, repair not attempted),
`repaired` (rebuild genuinely succeeded), `unlocatable` (detected but the named DLL was never
found under the conda env's `Library\bin`), `exhausted` (CLAUDE.md Item 25 -- the 3-iteration
cap was reached with a real, locatable candidate still pending, so at least one native-DLL
dependency remains unbundled; distinct from `repaired` so a partial fix is never reported as a
clean completion), `failed_rebuild` (PyInstaller rebuild itself failed),
or `failed_missing_exe` (rebuild reported success but `dist\<env>.exe` was not produced) --
`pass` is `false` only for the two `failed_*` states (`exhausted` is `pass:true`, same treatment
as `unlocatable` -- both are informational: the bootstrap itself did not fail, only the repair was
incomplete). `details.dll`/`details.provider`/
`details.iteration` are pulled inside the emitting PowerShell command via
`[Environment]::GetEnvironmentVariable(...)` rather than `%VAR%` cmd.exe substitution into the
`-Command` text, for the same reason the sibling `HP_DLL_DETECTED_SAFE`/`HP_NEXT_DLL_SAFE`
display-only sanitization exists (see `docs/agent-interconnect.md`'s DLL-bundling section) --
a DLL basename can legally contain `&`/`|`, which are metacharacters to cmd.exe's own
command-line parsing even inside a quoted argument, not just inside `:log`'s unquoted echo.

**Not currently observed in any real CI artifact.** `run_setup.bat`'s own `HP_NDJSON`
auto-detection (`if not defined HP_NDJSON if exist "%CD%\tests" set "HP_NDJSON=..."`) only fires
when the bootstrapped app directory has its own `tests\` subfolder -- `tests/selfapps_layered_
e2e.ps1` (the one test that genuinely triggers the `repaired` state, via `pygrib`/`eccodes.dll`)
runs its sub-bootstrap from a bare scratch directory with no `tests\` subfolder, and does not
explicitly set `HP_NDJSON` either, matching this repo's established convention for isolated
sub-bootstrap tests (see `tests/selfapps_postexec_checkpoint.ps1`, which deliberately `Remove-
Item Env:HP_NDJSON` around its own sub-bootstrap calls and asserts via log text instead, to avoid
an isolated scratch run's rows leaking into the shared `~test-results.ndjson` stream). So
`:emit_dll_bundle_row`'s own `if not defined HP_NDJSON exit /b 0` guard means this row is never
actually written during that test's run today -- `mech4Pass` continues to rely on the pre-existing
`[REPAIR][DLL_BUNDLE]` log-text assertions (`docs/agent-interconnect.md`'s DLL-bundling section),
unaffected by this addition. `batch.dll_bundle.ndjson` (`tests/harness.ps1`, static) is the actual
coverage for this row: it verifies the `:emit_dll_bundle_row` subroutine exists, the row id string
is present, and all 7 `call :emit_dll_bundle_row <state>` sites are wired (including the
`exhausted` state added for CLAUDE.md Item 25) -- the same "static wiring
guard, not runtime execution" pattern already used for `batch.failfast.probe`/`batch.postexec.
checkpoint` above. Per-state runtime coverage (deliberately setting `HP_NDJSON` for a sub-bootstrap
and reading the row back) remains a candidate for a future, dedicated test if ever justified --
not pursued now, since simulating the other 6 states (Nuitka-used, non-conda provider, a genuine
PyInstaller rebuild failure, a missing post-rebuild EXE, a detected-but-unlocatable DLL, the
3-iteration cap hit with a candidate still pending) each needs
its own scaffolding beyond what `self.layered_e2e.chain`'s real `pygrib` trigger already provides
for the `repaired` state alone.

`batch.dll_bundle.pct_sanitizer` (`tests/harness.ps1`, gating) is a SEPARATE static check, not a
sibling of the above -- it live-executes a real cmd.exe + PowerShell fixture proving the `_SAFE`
sanitization's `%`/`^`-stripping mechanism (and the `call`-based second-expansion-pass security
property) actually works, rather than statically checking `run_setup.bat`'s own wiring. See
`docs/agent-interconnect.md`'s DLL-bundling section for the real bug this fixture caught (a first
implementation attempt used a cmd.exe `%VAR:%%=_%` substitution that CI proved silently produced an
empty string) and `docs/agent-lessons-learned.md`'s corresponding entry.

`batch.dll_bundle.second_pass` (`tests/harness.ps1`, CLAUDE.md Item 29) is a THIRD, separate static
check in the same family -- unlike `batch.dll_bundle.ndjson`'s 7-state wiring guard and
`batch.dll_bundle.pct_sanitizer`'s live-executed sanitization fixture, this one guards the
second `:dll_bundle_recover` pass that runs after `:hidden_import_recover` (a hidden-import
rebuild's own `--collect-submodules=X` can surface a native-DLL warning the FIRST
`:dll_bundle_recover` call, which only ever ran before any hidden-import rebuild, could never
have seen -- see `docs/agent-interconnect.md`'s "Conda native-DLL bundling repair loop" section
for the full mechanism and its real `pyproj`/`proj_9.dll` trigger). Asserts: both `call
:dll_bundle_recover` and `call :hidden_import_recover` appear at least twice in the file (the
original call plus the new second-pass call), the DLL rebuild command threads the hidden-import
flags, `HP_DLL_REPAIRED` is both set (on genuine repair) and checked (gating the extra
`:hidden_import_recover` pass), the second `:dll_bundle_recover` call is itself gated on a new
`HP_HIDDEN_REPAIRED` flag, `HP_LOG_SIZE_BEFORE` advances immediately before
`:hidden_import_recover`'s own rebuild (scoped to that subroutine's own body via a regex
extraction bounded by the next label, not a whole-file match -- a whole-file match would stay
true even if this specific line were deleted, since the identical text already exists in
`:run_entry_smoke`'s initial snapshot and in `:dll_bundle_loop`), and -- specifically to catch a
REINTRODUCED per-call reset regressing the two cross-call state-leak bugs this same fix had to
close -- the bare `set "HP_PYI_DLLBIND="` line appears EXACTLY twice in the file (the
fresh-build-attempt reset plus `:run_entry_smoke`'s own pre-existing end-of-pass trailer) and the
bare `HP_PYI_HIDDEN_IMPORTS`/`HP_PYI_HID_COLLECT` resets appear EXACTLY once each. Static wiring
guard only, same as `batch.dll_bundle.ndjson` -- runtime proof is `self.layered_e2e.chain`'s own
`chainPass` (`cache` lane, non-gating), CONFIRMED `true` for the first time via real CI (PR #421
merge commit `dcfce1d`, `cache`-lane run `31264219121`) -- see `docs/agent-closed-backlog.md`'s
Item 29 entry for the full trace.

## selfapps-ux-hardening NDJSON rows (selfapps_ux_hardening.ps1, non-conda-full lanes)

```
self.ux.gitignore.merge, self.ux.gitignore.preserve, self.ux.gitignore.idem,
self.ux.gitattributes.merge, self.ux.gitattributes.idem,
self.ux.postflight,
self.ux.connectivity.offline.n, self.ux.connectivity.prompt.shown,
self.ux.connectivity.offline.uv.skip, self.ux.connectivity.offline.conda.skip,
self.ux.connectivity.online, self.ux.connectivity.retry,
self.ux.system.gate.n, self.ux.system.gate.prompt, self.ux.system.gate.real, self.ux.system.gate.accept,
self.sysbuild.decline,
self.venv.fallback, self.venv.canary_fail, self.venv.nopip_retry, self.entry.override,
self.embed.fallback.decline, self.embed.fallback.real, self.embed.dl.retry
```

## selfapps-pep723-writeback NDJSON rows (selfapps_pep723_writeback.ps1, uv-first lanes)

Eight scenarios (`PEP723_SCENARIO` env var; see the file's own header comment for the full
setup/assertion table). `fresh`/`idempotent`/`skipflag` are Loop 1 (the simplest, most
load-bearing cases); `malformed`/`trailing_ws_malformed`/`existing_lockfile`/`non_utf8`/`warnfix`
are Loop 2's adversarial-input scenarios (see `docs/plan-pep723-writeback.md` Part 2.3 / Part 4).
Each row emits `skip=true, reason=provider_not_uv` when `HP_ENV_MODE` did not resolve to uv
(e.g. a conda-only run), mirroring the established `Get-CondaBatPath` skip pattern.

```
self.pep723.writeback.fresh, self.pep723.writeback.idempotent, self.pep723.writeback.skipflag,
self.pep723.writeback.malformed, self.pep723.writeback.trailing_ws_malformed,
self.pep723.writeback.existing_lockfile, self.pep723.writeback.non_utf8,
self.pep723.writeback.warnfix
```

## selfapps-pvw-quickstart NDJSON rows (selfapps_pvw_quickstart.ps1, uv lane only)

Two scenarios (`QUICKSTART_SCENARIO` env var). A dry-run test for README's "PVW QuickStart"
copy-paste commands (standalone uv/autopep723 usage, no `run_setup.bat` involved) -- see that
file's own header comment for the full setup/assertion detail. Both scenarios include their own
`irm https://astral.sh/uv/install.ps1 | iex` uv-acquisition line (copied from README), so this
test is self-contained and does not depend on any other CI step's PATH state. Skips with
`skip=true, reason=non-windows-host` on non-Windows (mirrors this suite's usual convention, even
though the underlying uv/autopep723 CLI mechanics are cross-platform in principle).

```
self.pvw_quickstart.check, self.pvw_quickstart.run
```

## selfapps-autopep-discovery NDJSON rows (selfapps_autopep_discovery.ps1, uv lane only)

Single deterministic scenario (REQ-005.12, Tier 1 of `docs/plan-autopep723-two-tier.md`): proves
the bootstrapper-integrated `autopep723 check`-and-merge block (`run_setup.bat` ~line 1294,
`:after_pipreqs_run`) actually populates `requirements.txt` and the app builds/runs from it
alone. `HP_SKIP_PIPREQS=1` isolates Tier 1's own contribution from pipreqs's overlapping
discovery -- with pipreqs skipped and no other requirements source present, the only way the
stub app's `requests` import ends up installed is via this new merge step. Unlike
`selfapps_pvw_quickstart.ps1`, this test DOES run `run_setup.bat` (copies it into a scratch dir,
same pattern as `selfapps_pep723_writeback.ps1`), so it relies on the coarser full-tree
`diag-selftest-*` artifact capture rather than per-path `upload-artifact` wiring, matching that
file's own Loop-1 scratch dirs (`~selftest_pep723_fresh` etc.), which also have no individual
wiring.

```
self.autopep_discovery.merge
```

## selfapps-pvw-idempotent NDJSON rows (selfapps_pvw_idempotent.ps1, uv lane only)

Single deterministic scenario (REQ-005.13, Tier 2 of `docs/plan-autopep723-two-tier.md`): proves
`HP_PVW_KNOWN_IDEMPOTENT` actually runs the entry file live via `uvx autopep723 <entry>` (the
`:pvw_known_idempotent_run` subroutine, `run_setup.bat` ~line 3289, hooked in right after
`:determine_entry` returns -- earlier than Tier 1's own insertion point), persists what it
needed via `uv add --script`, and the app builds/runs from it afterward. `HP_SKIP_PIPREQS=1` is
test-level isolation only (matching `selfapps_autopep_discovery.ps1`'s own technique) -- it is
NOT how Tier 2 behaves by default in production; pipreqs runs normally alongside Tier 2 there.
Also asserts the stub app's own `print()` output appears directly in the bootstrap log, proving
the execute-mode discovery run's stdout was genuinely inherited/passed through live rather than
captured or suppressed -- the specific design point `tools/pvw_known_idempotent.py`'s helper
exists to preserve (see its module docstring: result markers print to stderr specifically so
they never collide with the passed-through script's own stdout). Same scratch-dir/coarser
full-tree-artifact-capture pattern as `selfapps_autopep_discovery.ps1` -- no individual
`upload-artifact` wiring.

```
self.pvw_idempotent.discovery
```

## selfapps-pvw-overrides NDJSON rows (selfapps_pvw_overrides.ps1, uv lane only, non-gating)

CLAUDE.md former Active Backlog item 10: `PVW_PYTHON_EXE` and `PVW_WORKSPACE` had ZERO test
coverage of any kind, unlike the other three PVW_* super-user overrides (`PVW_UV_EXE`,
`PVW_TARGET_PY`, `PVW_CONDA_EXE`), and ALL FIVE had zero coverage of their invalid-value
behavior. Four scenarios: valid- and invalid-value paths for both variables (2-3 representative
invalid-value cases, not the full 5x2 combinatorial matrix, per the backlog item's own suggested
shape).

`self.pvw.python_exe.valid` is a two-stage test: stage 1 does an ordinary uv bootstrap purely to
materialize a real, working interpreter on disk; stage 2 is a genuinely fresh scratch directory
(so `:try_fast_exe`'s EXE-cache fast path cannot short-circuit past `:after_env_mode_selection`,
where the override actually applies) running a different stub app with `PVW_PYTHON_EXE` pointed
at stage 1's interpreter -- asserts the `[INFO] Python host: using super-user override
PVW_PYTHON_EXE.` log line fires and the app actually runs successfully via the borrowed
interpreter. `self.pvw.workspace.valid` runs a single fresh bootstrap with `PVW_WORKSPACE` set to
a custom directory, asserting the `[DEBUG] Using super-user override for PVW_WORKSPACE:` log
line fires, `Scripts\python.exe` exists at the CUSTOM path (not the default `.uv_env`), the
default `.uv_env` was never created, and the app still runs successfully from the relocated venv.

`self.pvw.python_exe.invalid` sets `PVW_PYTHON_EXE` to a nonexistent path and confirms the
pre-existing interpreter smoke test right after the override (`"%HP_PY%" -c "print('py_ok')" ...
|| (... [WARN] Interpreter smoke test failed (continuing). ...)`) absorbs the broken value
gracefully rather than an uncontrolled crash. `self.pvw.workspace.invalid` sets `PVW_WORKSPACE`
to a path already occupied by a plain file (uv cannot create a venv "inside" a file) and confirms
the failure cascades to the SAME already-established `:uv_venv_fail` -> conda-create fallback
every other uv-venv-creation failure in this file already goes through (`falling back to conda
create` in the log) -- does NOT require the conda fallback to actually succeed, only that it's
reached; a real Miniconda download in this lane is an already-accepted cost (see
`self.conda.bothfail`'s own precedent).

All four skip with `skip=true` in the conda-full lane (uv is never the provider there, so none of
these overrides' own effects are reachable). Non-gating for its first landing, matching this
repo's established graduation pattern for a new PowerShell scenario not yet proven stable across
several real runs (see CLAUDE.md's "CI lane gating maturity" periodic check).

```
self.pvw.python_exe.valid, self.pvw.workspace.valid,
self.pvw.python_exe.invalid, self.pvw.workspace.invalid
```

## selfapps-cascade-timed NDJSON rows (selfapps_cascade_timed.ps1, conda-full lane only)

CLAUDE.md item 9 / docs/open-questions.md item 1 follow-up: `:cascade_consent_gate` previously used
an unbounded `set /p` for a real interactive user, unlike sibling prompts such as
`:pick_entry_interactive`'s own `choice /T` timed prompt -- an unattended real user (not physically
present when the prompt appeared) would hang the whole bootstrap forever. Now uses the same
`choice /T` pattern (default 30s, mirrors `:pick_entry_interactive`'s HP_PICK_T convention),
defaulting to N (decline) on timeout so an unattended run still tries the current build once rather
than hanging. `HP_TEST_FORCE_INTERACTIVE_CASCADE=1` forces the timed-choice branch to be reached
even under `HP_CI_LANE` (mirrors `HP_TEST_FORCE_PICKER`'s own established pattern for
`:pick_entry_interactive`, see `tests/selfapps_entry_picker.ps1`) and shrinks the timeout to 2s.
With no interactive console and no `HP_TEST_CASCADE_ANSWER` override, `choice` degrades to its
default (N) within ~2s, proving the mechanism reaches the prompt and resolves without hanging.

Also proves the companion "dependencies may be incomplete" note (`HP_DEP_MAYBE_INCOMPLETE`, set
only when a cascade candidate was detected but NOT approved) fires at both its injection points
(the decline-time WARN in `:warnfix_cascade_detect` and the pre-launch reminder in
`:warn_user_code_launch`), and that the postexec-offers-skip message (proven positively by
`self.cascade.exec`'s approved-cascade path, below) correctly does NOT fire here, since only
cascade *approval* -- not detection alone -- skips the elective postexec checkpoint/optimized-build
offers.

```
self.cascade.timed
```

## selfapps-layered-e2e NDJSON rows (selfapps_layered_e2e.ps1, cache lane only, non-gating)

Implements `docs/agent-closed-backlog.md`'s Item 22 (closed 2026-08-03, confirmed by real CI run
`30779274430`, cache-lane job `91580880846` -- passed on its first real execution, no iteration
needed): a real, non-simulated end-to-end test originally proving three
distinct mechanisms fire for real in ONE run, replacing Part VII Scenario 33's
`[Extrapolated Branch]` splice with genuine evidence -- the uv-to-conda provider cascade
(REQ-009/REQ-005.10 slice 3), warnfix repair (REQ-007, both a genuine success AND a genuine
failure in the same repair round), and `--hidden-import` auto-recovery (REQ-016 Slice 2). No
`HP_TEST_FORCE_*`/`HP_SKIP_*`/`HP_DISABLE_*` flags are used beyond the unavoidable
`HP_TEST_CASCADE_ANSWER=Y` (accepting an interactive consent prompt deterministically in CI) --
every failure and repair is a genuine, unflagged consequence of three real packages' own
availability on PyPI vs. conda-forge: `pygrib` (zero Windows wheels on PyPI, confirmed via a
direct PyPI JSON API query -- macOS/Linux wheels exist for every recent CPython, Windows was
deliberately excluded, and the sdist needs the ecCodes/GRIB-API C library a bare CI runner does
not have -- but real conda-forge win-64 builds exist, verified via the anaconda.org API), `xlrd`
(a real PyPI wheel, so warnfix's per-module install genuinely succeeds for it in the same round
pygrib genuinely fails), and `colorama` (imported only via `importlib.import_module`, invisible
to PyInstaller's static analysis, so never touched by warnfix -- installs fine once cascaded to
conda but the frozen EXE still needs `--hidden-import` to actually bundle it).

**GDAL was the original candidate for the cascade trigger, researched and rejected.** GDAL's
Python bindings live under the `osgeo` namespace (`from osgeo import gdal`), and PyInstaller's
warn file always records the top-level import name ("osgeo"), not the actual PyPI distribution
name ("gdal"/"GDAL"). PyPI hosts a real, always-succeeding dummy package literally named `osgeo`
(a deliberate typosquat-protection placeholder maintained specifically to catch people who
mistakenly `pip install osgeo` instead of `pip install gdal`) -- so warnfix's own per-module
repair attempt for GDAL would install that harmless dummy instead of genuinely failing, silently
defeating `:warnfix_cascade_detect`'s Signal B (a REAL recorded install failure, gated on
`~warnfix_repair_failed.flag`, set only by a genuine per-module install failure). `pygrib`'s
top-level import name IS its own correct PyPI/conda-forge package name (no namespace
indirection, no decoy package), so this same trap cannot occur. See `docs/agent-closed-backlog.md`'s
Item 22 for the full research trail.

**Extended 2026-08-04 with a 4th mechanism (CLAUDE.md Active Backlog Item 24,
`docs/prd-conda-native-dll-bundling.md`): the conda native-DLL bundling repair loop
(`:dll_bundle_recover`).** `pygrib`'s conda-forge build genuinely triggers the exact
`eccodes.dll`-not-bundled failure this loop exists to repair, so this same test (no new flags,
no new fixtures) is also this loop's Requirement 4 regression test -- see
`docs/agent-interconnect.md`'s "Conda native-DLL bundling repair loop" section for the full
mechanism trace. `$mech4Pass` (`dllWarningSeen`/`dllBundling`/`dllBundleComplete`) is required for
`$chainPass`, alongside the original three mechanisms. Item 24 (this mechanism's own first
confirmation, `eccodes.dll`) and its two successors, Item 28 (`--collect-submodules` pairing) and
Item 29 (a second `:dll_bundle_recover`/`:hidden_import_recover` pass for a DLL gap a hidden-import
rebuild surfaces later), are all closed in `docs/agent-closed-backlog.md` -- `chainPass` was
finally confirmed `True` for the first time via PR #421's merge (`cache`-lane run `31264219121`),
closing the last of the three.

Asserts, mostly against `$combined` (the bootstrap stdout log plus `~setup.log`, concatenated) --
except the exact cascade COUNT (`$uvToConda`) and the warnfix-round evidence (`$warnfixRoundCount`/
`$warnfixRoundText`, both derived below), which are checked against `$setupText` (`~setup.log`
alone) so a genuine occurrence is never double-counted: every `:log`-emitted line (`run_setup.bat`'s
`:log` subroutine) is written to BOTH stdout (captured into the bootstrap log) AND `~setup.log`
(`%LOG%`), so counting matches against the concatenation of both would silently double every
occurrence -- matching `self.cascade.exec`'s own single-source-for-counts convention: the initial
`uv pip install -r requirements.txt` genuinely failed; the REQ-009 cascade candidate was detected
and approved and executed exactly once (uv to conda); conda was selected as the new provider;
warnfix's per-module loop both attempted AND failed to install `pygrib`, and both attempted AND
succeeded at installing `xlrd` -- proven to have happened in the SAME repair round (not merely
somewhere in the run), by scoping the `pygrib`/`xlrd` checks to the substring between the round's
own `[REPAIR] missing modules detected; installing and rebuilding.` start marker and its
`[REPAIR] rebuild complete after warnfix.` end marker (required explicitly -- an incomplete round
with no completion marker does NOT fall back to "everything to end of log," it counts as no
evidence at all), plus a `$warnfixRoundCount -eq 1` check proving exactly one such round exists in
the run (so that slice cannot itself straddle two rounds) -- see Item 21's `[INFO] Attempting to
install:`/`[INFO] Installed:` lines for where those
per-module log lines originate; `--hidden-import=colorama` was added and the EXE was verified
after hidden-import recovery; the final EXE (built under conda, the tier the cascade lands on)
genuinely exists, exits 0, and writes a token file combining evidence from all three packages; and
`~bootstrap.status.json` reads `state=ok`.

Lane: `cache` only (uv-first, and the only lane that already caches Miniconda across runs to
amortize the one-time download this test's own cascade triggers -- unlike adding it fresh to
`real`). Non-gating for its first landing (the `cache` job is `continue-on-error` at the job
level) -- promote once proven stable across several real runs, matching this repo's established
graduation pattern (see CLAUDE.md's "CI lane gating maturity" periodic check). Wired
immediately after the `uv` lane's own `self.cascade.exec` step in `batch-check.yml` (thematically
grouped, no ordering dependency between them -- different lanes).

```
self.layered_e2e.chain
```

## selfapps-gribapi-hook-probe NDJSON rows (selfapps_gribapi_hook_probe.ps1, conda-full lane only, non-gating)

CLAUDE.md Active Backlog Item 24 / `docs/prd-conda-native-dll-bundling.md` Requirement 1: a
one-off empirical experiment testing whether forcing `--hidden-import=gribapi` on a `pygrib`
PyInstaller build makes `pyinstaller-hooks-contrib`'s existing `hook-gribapi.py` bundle
`eccodes.dll` for free, without building any new bootstrapper mechanism. See the PRD's Finding 1
for the full research trail on why this is now expected to come back negative (pygrib and gribapi
are architecturally independent bindings to the same C library) but is still worth the real CI
evidence per explicit owner instruction.

**Deliberately standalone -- does NOT invoke `run_setup.bat` or the REQ-009 provider cascade at
all.** Creates its own scratch conda env directly (`gribapi_probe_env`, removed after every exit
path including early ones, per a CodeRabbit review finding that the original version leaked it on
one guard) with `python pygrib eccodes python-eccodes pyinstaller pip --override-channels -c
conda-forge`, then runs PyInstaller twice from that env's own interpreter against a trivial
`import pygrib` stub: once as a control (no extra flags), once with `--hidden-import gribapi`
added. **Builds use `--onedir`, not `--onefile`** (fixed from the first version, another
CodeRabbit finding) -- `--onefile` embeds bundled support files, DLLs included, inside the
compressed EXE itself, extracting them only to a runtime-only `_MEIxxxxxx` temp directory that
never touches disk under the dist path, which would have made the DLL-bundling scan structurally
unable to ever detect a positive result regardless of whether the hidden-import worked. `--onedir`
writes bundled files under `dist_$Variant\probe_$Variant\`, where the scan can actually see them.
For each build, checks whether the `could not resolve 'eccodes.dll'` build-time warning still
appears, whether any `eccodes*.dll` landed anywhere under that directory (recursive --
`hook-gribapi.py`'s own directory-preservation logic nests it under an `eccodes` subfolder on
Windows, not the dist root), and whether the resulting EXE actually runs clean (exits 0 and prints
its own success token, as opposed to failing with `DLL load failed`).

**`pass` reflects whether the experiment ran to completion and produced conclusive evidence, NOT
whether the hidden-import "worked" -- there is no `pass`/`fail` on the actual research question
itself, only a recorded finding.** `details.hiddenImportHelped` (`true`/`false`/`null`) is the
actual answer, determined from `bundledDll` (a structural, build-output fact -- did the DLL
actually land on disk), NOT from `ranClean` (a runtime-behavior fact kept only as supplementary
per-variant evidence) -- a review finding correctly pointed out these are two distinct questions
that a runtime-only signal would have conflated. `null` when the experiment was inconclusive
(either variant's observation was incomplete), otherwise `true` only if the control build did NOT
bundle the DLL AND the experiment build did. An "observation" requires BOTH the build itself
(launched, completed within its 600s budget, output fully captured, exited 0) AND the resulting
EXE (launched, completed within its 30s budget, output fully captured) to be complete --
`buildObservationComplete`/`observationComplete` are both explicit, checkable per-variant facts
(not inferred from `dist\*.exe` merely existing on disk) precisely so a timed-out or partially-
written build/run can never masquerade as real evidence. `pass=false` covers a genuine infra
failure (conda env create failed, or python.exe missing from the created env) that prevented the
probe from running at all -- distinct from `pass=true, hiddenImportHelped=null`, which means the
probe ran but the builds themselves were inconclusive.

Lane: `conda-full` only, gated on `steps.conda_avail.outputs.available == 'true'` (same gate the
27 other conda-full-only self-tests already use) -- guarantees real Miniconda is present without
any step-ordering placement constraint. Non-gating in practice, though NOT via `continue-on-error`
alone (a review finding on this PR's first commit correctly caught that this does not, by itself,
exempt a row from `batch-check.yml`'s separate NDJSON-verdict enforcement step, which fails the
`conda-full` lane job on any raw `pass=false` regardless of which step emitted it) -- every exit
path in the test script emits `pass=true` unconditionally, with `skip`/`details.conclusive`
carrying the real outcome instead. Exploratory by design: the conda-forge solve for
`pygrib`+`eccodes`+`python-eccodes`+`pyinstaller` together in one env is unproven as of this
test's first landing.

```
self.gribapi_hook_probe.hidden_import
```

## selfapps-conda-bothfail NDJSON rows (selfapps_conda_bothfail.ps1, uv lane only, non-gating)

Closes CLAUDE.md Active Backlog item 10: `:tci_both_failed` (both Miniconda AllUsers and JustMe
install types fail) previously had zero CI coverage. New hook `HP_TEST_FORCE_JUSTME_FAIL=1`
(`run_setup.bat`, `:tci_justme`) deterministically skips the real JustMe `start "" /wait` call and
forces a nonzero result; combined with `HP_TEST_NOT_ELEVATED=1` (already reaches `:tci_justme` by
skipping straight past the AllUsers attempt), the sub-bootstrap reaches `:tci_both_failed ->
:die "[ERROR] Miniconda install failed (both AllUsers and JustMe)."` without depending on a
genuinely broken installer/ACL environment.

**Placement is load-bearing, not arbitrary.** Miniconda installs to the SHARED, machine-wide
`%PUBLIC%\Documents\Miniconda3` path, not a per-test-directory location -- if Miniconda was
already installed by an EARLIER step in the same CI job (the main "Bootstrap environment" step,
or an earlier selfapps script that forces conda), `:try_conda_install`'s own top-level gate
(`if not defined CONDA_BAT (...)`) would find `conda.bat` already present and skip the install
block entirely, so this test's hooks would never fire. Wired into `batch-check.yml` immediately
BEFORE the provider-cascade-exec step (`self.cascade.exec`, which cascades uv -> conda and would
install Miniconda for real if it ran first) -- the `uv` lane's own main bootstrap step normally
succeeds via uv alone (no Miniconda installed), so by the time this step runs, conda.bat
genuinely does not exist yet on the runner. If a future CI change reorders steps within the `uv`
lane, re-verify this ordering constraint still holds.

Asserts: the `HP_TEST_NOT_ELEVATED` skip line, the `HP_TEST_FORCE_JUSTME_FAIL` hook-fired line,
the exact `:tci_both_failed` `[ERROR]` message, and `~bootstrap.status.json` reading `state=error`
(not silently overwritten back to `ok` -- see `docs/agent-lessons-learned.md`'s `:die` entry).
Does NOT assert process exit code -- `:success`'s own `exit /b 0` runs unconditionally regardless
of `HP_BOOTSTRAP_STATE`, matching this repo's established "graceful stop" contract for this
failure class (see `selfapps_pyinstaller_fail.ps1`'s sibling reasoning). Non-gating: the
CI-ordering assumption above needs to soak before considering gating-lane promotion.

```
self.conda.bothfail
```

## selfapps-cascade-conda-create-fail NDJSON rows (selfapps_cascade_conda_create_fail.ps1, uv lane only, non-gating)

Closes CLAUDE.md Active Backlog Item 23: a genuine (non-`HP_TEST_FORCE_CONDA_FAIL`-simulated)
conda-create failure reached during a REQ-009 cascade re-entry (`:cascade_from_uv ->
:try_conda_create`) previously fell through `:die` into `:conda_create_done`'s own success-path
continuation instead of routing through `:after_cascade_decision` like every other cascade-target
failure -- see `docs/agent-interconnect.md`'s "Provider cascade execution re-enters env-create"
and `CLAUDE.md`'s Item 23 entry for the full trace. Fixed by adding `if defined
HP_CASCADE_SAVED_PY goto :cascade_conda_create_failed` at both `:conda_create_failed` fall-through
sites, plus a new `:cascade_conda_create_failed` label mirroring the existing
`:cascade_conda_unavailable` / `:cascade_embed_unavailable` / `:cascade_venv_unavailable` /
`:cascade_system_unavailable` template (log a `[WARN] ... keeping current build.` line, restore
`HP_CASCADE_SAVED_PY` via `:after_cascade_decision`, deliberately never call `:die`).

Two scenarios (`CASCADE_CCF_SCENARIO` env var; unset defaults to `create_fails`), covering the
fix's two distinct call sites -- both fall through the SAME `if defined HP_CASCADE_SAVED_PY goto
:cascade_conda_create_failed` pattern, but are reached via genuinely different real-code-path
triggers:

- **`create_fails`** (default): new hook `HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL=1`
  (`run_setup.bat`, `:try_conda_create`) forces a GENUINE failure through the real create/retry
  code path -- unlike the existing `HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL` (fails the first
  attempt only, then clears itself so the retry can genuinely succeed), this flag persists through
  the retry too, so both the initial attempt and the retry fail deterministically without
  depending on real network conditions. Exercises `:conda_create_failed`'s own call site.
- **`missing_python`** (PR #413 CodeRabbit review finding -- the original scenario above never
  exercised the fix's OTHER call site): new hook `HP_TEST_FORCE_CONDA_MISSING_PYTHON=1`
  (`run_setup.bat`, `:conda_create_done`) lets the real `conda create` command run and succeed for
  real, then deletes the `python.exe` it just produced -- a genuine successful create followed by
  a genuinely missing interpreter, not a simulated create failure. `HP_TEST_FORCE_CONDA_CREATE_
  BOTH_FAIL` is deliberately unset in this scenario (create must succeed for real to reach
  `:conda_create_done` at all). Exercises the `if not exist "%HP_PY%"` block's own call site
  inside `:conda_create_done`.

Both scenarios: `HP_TEST_FORCE_EMBED_FAIL=1`, `HP_TEST_FORCE_VENV_FAIL=1`, and
`HP_TEST_SYSCON_ANSWER=N` exhaust `:handle_conda_failure`'s own embed/venv/system fallback chain
deterministically, so `HP_ENV_READY` never gets set and the fix's own new check is actually
reached rather than short-circuited by an unrelated fallback tier succeeding. The app imports a
nonexistent module (`fake_pkg_cascade_xyz`, same trick as `selfapps_cascade.ps1`) so warnfix
genuinely fails to resolve it under uv, marking a cascade candidate and driving the uv-to-conda
cascade with `HP_TEST_CASCADE_ANSWER=Y`.

**Placement is load-bearing for both scenarios.** Each must run AFTER `selfapps_cascade.ps1`'s own
step (`self.cascade.exec`) in the same `uv`-lane job -- that step already downloads and installs
Miniconda for real, so by the time either scenario's step runs `CONDA_BAT` is already cached and
`:cascade_acquire_conda`'s own real-install branch is skipped. Same CI-ordering reasoning as
`selfapps_conda_bothfail.ps1`'s own placement note above, just the opposite direction: that test
needs Miniconda NOT yet installed, these want it already installed. `missing_python` additionally
needs a real (not simulated-failure) conda create to complete, so its own step runs slower than
`create_fails`'s immediate simulated failure.

Asserts, both scenarios: the cascade reached conda exactly once (`REQ-009: cascading provider uv
to conda`, single occurrence against `~setup.log` alone, matching `self.cascade.exec`'s own
single-source-for-counts convention), the new `[WARN] REQ-009: cascade target conda create failed;
keeping current build.` line fired, the scenario's own hard-failure message
(`[ERROR] conda env create failed.` for `create_fails`, `[ERROR] python.exe missing from conda
environment.` for `missing_python`) appears exactly ONCE in `~setup.log` -- not twice, since
`:handle_conda_failure` always logs its message once before attempting any fallback regardless of
outcome, so a SECOND occurrence (from `:die`'s own separate echo, if the old bug were still
present) is the actual fall-through-regression signal, not the message's mere presence -- the
bootstrap exited 0, and -- the key behavioral proof of the fix -- `~bootstrap.status.json` reads
`state=ok` (not `error`) since `HP_BOOTSTRAP_STATE`'s own default is `ok` at this point in the run
and `:after_cascade_decision` preserves whatever it already was. `create_fails` additionally
asserts both the simulated initial-attempt and retry-attempt failure signatures are PRESENT;
`missing_python` additionally asserts they are ABSENT (proving the real create genuinely
succeeded, not a simulated-failure path in disguise). Non-gating: depends on
`selfapps_cascade.ps1` having already run in the same job.

```
self.cascade.conda_create_fail
```

## selfapps-pyinstaller-fail NDJSON rows (selfapps_pyinstaller_fail.ps1, real/conda-full lanes)

Three scenarios (`PYI_FAIL_SCENARIO` env var: `execfail` / `output_vanish` /
`execfail_runtimefail`), all emitting the same row id. XFAIL-style, mirroring
`selfapps_exefail.ps1`'s sibling pattern but testing the PyInstaller BUILD step failing outright
(not a successfully-built EXE crashing at runtime). `execfail_runtimefail` (added for [REQ-027]
P2 honest messaging) is `execfail` plus a stub app that ALSO exits non-zero via the interpreter
fallback, asserting the `HP_NOEXE_VERIFY_FAILED`-gated caveat panel text appears instead of the
other two scenarios' plain "your code ran successfully" text -- see the Closed Backlog entry for
the real, pre-existing dishonest-claim bug this closes.
Regression test for a real bug found 2026-07-20 while scoping the AV-Safe Build Path PRD's
requirement-1 failure-simulation tests (`docs/prd-av-safe-build-path.md`): a genuine PyInstaller
build failure previously fell through `:die`'s call-frame-only `exit /b` (it never halts the
process) all the way to `:after_cascade_decision`, which unconditionally overwrote
`~bootstrap.status.json` back to `state=ok` and exited 0 -- silently masking the failure. Fixed
by setting `HP_BOOTSTRAP_STATE=error` at the build call site. This test asserts the fix:
`~bootstrap.status.json` genuinely reads `state=error` (not overwritten). It does NOT assert a
non-zero process exit code -- `:success`'s own `exit /b 0` runs unconditionally regardless of
`HP_BOOTSTRAP_STATE`, matching this repo's established "graceful stop" contract for this failure
class (see `selfapps_preflight.ps1`'s sibling test, which likewise never checks exit code). See
`docs/agent-lessons-learned.md`'s `:die` entry for the
full trace of why the pre-fix behavior was wrong. No individual `upload-artifact` wiring, same
as `selfapps_exefail.ps1` -- covered by the coarser full-tree `diag-selftest-*` capture.

**Updated when Tier A shipped**: also sets `HP_TEST_FORCE_NUITKA_FAIL=1` so the new
`:try_nuitka_tier_a` fallback is deterministically forced to fail too -- once Tier A existed, a
real Nuitka build against this test's trivial stub app would likely succeed on a Windows CI
runner with MSVC, silently turning this "everything fails" test into a fallback-success case
(a different scenario, covered separately by `self.exe.build.tiera` below).

```
self.exe.build.xfail
```

## selfapps-nuitka-tiera NDJSON rows (selfapps_nuitka_tiera.ps1, uv lane only, non-gating)

Proves AV-Safe Build Path requirements 2-4 (Tier A) work end to end: `HP_TEST_FORCE_PYINSTALLER_
FAIL=1` forces the primary build to "fail" deterministically, `HP_TEST_FORCE_NUITKA_FAIL` is
deliberately left unset so a REAL Nuitka build runs in the same environment (no reprovisioning),
and asserts the fallback succeeds, `dist\<env>.exe` exists, the stub app's own stdout came
through the existing (unmodified) EXE smoke-test path, and the final `~bootstrap.status.json`
reads `state=ok` (a successful fallback is bootstrap SUCCESS, distinct from `self.exe.build.xfail`
where every tier failing is the error case). Deliberately non-gating for its first landing --
unlike `self.exe.build.xfail`, this exercises genuine Nuitka CLI flags and MSVC/compiler
availability that could not be verified locally (no Windows machine in this sandbox); promote to
a gating lane once proven stable across several real runs, matching this repo's established
graduation pattern (see `CLAUDE.md`'s "CI lane gating maturity" periodic check).

```
self.exe.build.tiera
```

## selfapps-nuitka-tiera-hidden-skip NDJSON rows (selfapps_nuitka_tiera_hidden_skip.ps1, uv lane only, non-gating)

Regression test for a real bug found via a refinement pass on the shipped Tier A code:
`:hidden_import_recover` (the `--hidden-import` auto-recovery loop, REQ-016 Slice 2)
unconditionally rebuilt via PyInstaller on a recoverable missing-import failure, with no check
for whether `dist\<env>.exe` was actually built by Nuitka (Tier A, `HP_NUITKA_FALLBACK_USED=1`)
rather than PyInstaller -- PyInstaller's `--hidden-import` flag does not apply to a
Nuitka-produced EXE, so silently rebuilding via PyInstaller there risked reproducing the very
failure Tier A exists to route around, or clobbering a working Nuitka build with a broken
PyInstaller one. Fixed with an early-skip guard at the top of `:hidden_import_recover`.

Same `HP_TEST_FORCE_PYINSTALLER_FAIL=1` technique as `selfapps_nuitka_tiera.ps1` to force Tier A,
with a real (unforced) Nuitka build. The stub app deliberately prints a fabricated, exact-format
`ModuleNotFoundError: No module named 'nuitka'` to stderr and exits 1 -- `nuitka` itself is
guaranteed to be pip-installed into the same build interpreter Tier A just used, so
`~hidden_import_scan.py`'s `find_spec` gate would treat this as a genuinely fixable target if the
recovery loop were mistakenly attempted; since the scanner is a pure text-based regex match
against captured process output (not real Python introspection), this fabricated signal
deterministically constructs the exact trigger condition the skip guard must catch, without
depending on genuine (fragile, non-deterministic) Nuitka missing-import behavior.

Asserts: Tier A succeeds (same checks as `self.exe.build.tiera`), the EXE genuinely runs and
exits non-zero, the new skip log line fires, the OLD `[REPAIR][HIDDEN_IMPORT]` PyInstaller-rebuild
log line does NOT fire, and `~bootstrap.status.json` still reads `state=ok` (the user program's
own non-zero exit is not a bootstrapper failure -- see CLAUDE.md's "User-code exit-code semantics"
Known Finding). Same non-gating reasoning as `self.exe.build.tiera` (depends on a real Nuitka
build succeeding).

```
self.exe.tiera.hidden_skip
```

## selfapps-optimized-build NDJSON rows (selfapps_optimized_build.ps1, uv lane only, non-gating)

Proves AV-Safe Build Path requirement 9 (P1): after a NORMAL, verified-successful PyInstaller
build (never after Tier A -- gated on `HP_NUITKA_FALLBACK_USED` being unset), `:offer_optimized_
build` offers an elective, human-only, auto-declined-in-CI upsell to also build a Nuitka-optimized
version. Unlike Tier A (free to delete-then-rebuild since the original build already failed),
this feature builds to a distinct temp filename, verifies the new build actually runs, and only
then swaps it into `dist\<env>.exe` -- on any failure at any stage the original, already-working
EXE is left completely untouched.

Four scenarios (`OPTBUILD_SCENARIO` env var), all in this one file/lane:
- `accept` (`HP_TEST_OPTBUILD_ANSWER=Y`, no forced failure): a REAL Nuitka build runs, is
  verified, and is swapped into place. Same non-gating reasoning as `self.exe.build.tiera` --
  depends on a real Nuitka build succeeding, which could not be verified locally.
- `forcefail` (`HP_TEST_OPTBUILD_ANSWER=Y` + `HP_TEST_FORCE_OPTBUILD_FAIL=1`): the optimized
  build is forced to fail deterministically (no real Nuitka attempt); asserts the original
  PyInstaller-built `dist\<env>.exe` is left completely untouched and still runs (re-executed
  directly by the test after the bootstrap completes, not just checked for existence).
- `swapfail` (`HP_TEST_OPTBUILD_ANSWER=Y` + `HP_TEST_FORCE_OPTBUILD_SWAP_FAIL=1`): a REAL Nuitka
  build runs and verifies successfully (same as `accept`), but the final move-into-place step is
  forced to fail. Regression test for a real bug found via a refinement-pass code review (see
  Closed Backlog): the original "did the swap succeed" check tested whether `dist\<env>.exe` (the
  destination) existed -- but that file already exists BEFORE the move (it's the already-working
  original), so a genuinely failed `move /y` (e.g. an AV/indexer lock on the destination -- the
  same hazard class already documented for `:try_embed_fallback`'s own swap in
  `docs/agent-lessons-learned.md`) was silently misreported as success. Asserts the original EXE
  is left completely untouched and still runs, the leftover temp file is cleaned up (also part of
  the fix -- the old failure branch never routed through the shared `:optbuild_cleanup` label),
  and the "succeeded and verified" message is never logged.
- `decline` (neither env var set): falls through to the ambient `HP_CI_LANE` auto-decline, the
  same mechanism `selfapps_postexec_checkpoint.ps1`'s own `self.checkpoint.decline` scenario
  relies on; asserts the prompt is shown but no build is ever attempted.

All four deliberately kept in one file/lane rather than split across gating/non-gating lanes by
determinism, matching this repo's established multi-scenario pattern (e.g.
`selfapps_pyinstaller_fail.ps1`'s `PYI_FAIL_SCENARIO`) -- promote once proven stable, matching
this repo's established graduation pattern.

```
self.optbuild.offer
```

## selfapps-interactive-stdin NDJSON rows (selfapps_interactive_stdin.ps1, uv lane only, non-gating)

Closes the remaining gap in `docs/plan-cli-interactive-verification.md`'s live-echo redesign
(P0 requirement 1 shipped the tee mechanism; this test proves the full real-Windows nesting a
double-clicked `run_setup.bat` actually uses -- `cmd.exe -> :run_exe_smokerun -> the emitted
~exe_smokerun.ps1 helper -> the built EXE` -- carries genuine interactive stdin all the way
through, not just that output is teed). Builds a real PyInstaller EXE from a multi-round
`input()`-driven stub app (the owner's actual target program shape: no launch args, ask setup
questions, loop on stdin until a quit command) and pipes a scripted sequence of answers into
`cmd.exe`'s own stdin. Provider-agnostic by construction (`:run_exe_smokerun`/`~exe_smokerun.ps1`
run identically regardless of which REQ-009 tier built the environment), so one passing run in
one lane is representative of the mechanism working across all lanes -- a per-provider repeat
would not exercise any different code path. Asserts ORDERING (each answer consumed by the right
prompt in the right round via `IndexOf` comparisons on the bootstrap log), not just presence of
expected substrings, plus that the EXE was genuinely built and the bootstrap reports `state=ok`.

Does NOT prove a live human's own typing timing (impossible to automate) -- it proves the
plumbing does not silently drop or reorder stdin/stdout, which was the genuinely unconfirmed
part. See `docs/plan-cli-interactive-verification.md` requirement 2 for what remains open (a
Windows-CI-only stdin confirmation was exactly what this test set out to provide; it is not a
substitute for a human's own interactive session).

```
self.interactive.stdin.roundtrip
```

## selfapps-cache-selfheal NDJSON rows (test_ci_cache_selfheal.ps1, `real` lane only, GATING)

Item 19 follow-on (docs/agent-closed-backlog.md): the cache-lane self-heal logic
(`tools/ci_cache_selfheal.ps1`) previously had no deterministic CI coverage -- the ambient
`cache` lane only reaches it when GitHub's own cache happens to be organically corrupted, and
that lane is entirely informational (job-level `continue-on-error`) besides, so a regression in
the self-heal logic itself would ship silently. This test exercises all 4 branches of that
script directly against a scratch temp directory with fake `condabin\conda.bat` stand-ins (no
real conda/network dependency), wired into `real` -- a GATING lane -- so a regression actually
fails CI. Windows-only (the script under test shells out to `conda.bat` via `cmd.exe`, and the
locked-directory scenario needs Windows file-locking semantics); skips with `skip=true` on
non-Windows via the bare `self.ci.cache_selfheal` row.

```
self.ci.cache_selfheal,
self.ci.cache_selfheal.healthy, self.ci.cache_selfheal.prefix_healed,
self.ci.cache_selfheal.exact_hit_corrupted, self.ci.cache_selfheal.prefix_heal_failed,
self.ci.cache_selfheal.no_binary
```

`self.cache.selfheal.fired` (inline `batch-check.yml`, `cache` lane, `HP_CACHE_SELFHEAL_ATTEMPTED`-gated)
is the companion VISIBILITY row -- unlike the deterministic test above, this
fires only when the AMBIENT `cache` lane's own restored cache is organically corrupted on a
restore-keys prefix match, and records whether that real self-heal attempt actually succeeded
(`details.healed`). Always `pass:true` (informational, matching `self.cache.corrupted`'s own
convention) -- its purpose is to make an organic occurrence queryable on the diagnostics site
over time instead of requiring a raw-log dig to notice it happened at all, not to gate.

---

## selfapps-lineending-check NDJSON rows (selfapps_lineending_check.ps1, real/conda-full lanes, GATING)

CLAUDE.md Active Backlog Item 44's own "Known gap": the line-ending self-check at the top of
`run_setup.bat` (before any goto/call in the file -- see the file's own header comment) had zero
CI coverage of its three failure branches, since a normal `actions/checkout` always normalizes to
CRLF, so CI could exercise only the happy path on real cmd.exe, never the failure branches. Three
new `HP_TEST_FORCE_*` hooks close this: `HP_TEST_FORCE_NO_POWERSHELL` forces a synthetic nonzero
errorlevel right after the real `where powershell` call (no PATH tampering); `HP_TEST_FORCE_LF_
ONLY` and `HP_TEST_FORCE_PS_CHECK_FAIL` both redirect `HP_SELF_PATH` at something other than the
running copy of `run_setup.bat` (a synthetic pure-LF sentinel file, or a path that does not exist)
rather than corrupting the file actually executing -- the running copy must stay healthy CRLF to
reliably reach and execute the hook logic at all. Pointing at a nonexistent path makes the real,
unmodified PowerShell command genuinely throw (`FileNotFoundException`) and hit its own
`catch{exit 2}` branch, exercising the real failure path rather than a simulated one. All three
hooks and the underlying PowerShell command's exact behavior for each case (nonexistent path ->
exit 2; pure-LF file -> exit 1; genuine CRLF file -> exit 0) were verified directly against a real
PowerShell 7 binary before being wired into `run_setup.bat`, not just reasoned about.

Lane: `real` and `conda-full` only, gating from first landing -- matches `self.preflight.syntax`'s
own precedent for a cheap, provider-agnostic, pure-batch preflight check (no environment or
dependency work is ever reached in any of these three scenarios, unlike the Nuitka/MSVC-dependent
tests elsewhere in this registry that start non-gating specifically because they could not be
verified locally).

```
self.preflight.no_powershell, self.preflight.ps_check_fail, self.preflight.lf_only
```

---

## Key facts for debugging missing rows

- `self.exe.hidden_import.exhaust` (CLAUDE.md Active Backlog item 11, `tests/selfapps_
  hidden_import_exhaust.ps1`, real/conda-full lanes) proves `--hidden-import` auto-recovery
  reaches its 3-attempt cap for real, unlike its sibling `self.exe.hidden_import` (one-shot
  success only). The stub app rotates through 3 distinct, always-installed
  (`colorama`/`six`/`certifi`, all declared in `requirements.txt`) fabricated
  `ModuleNotFoundError` messages via a small state file next to the EXE that survives across the
  recovery loop's own rebuilds -- a REPEATED module name would be rejected by
  `~hidden_import_scan.py`'s own tried-list exclusion and stop the loop early via "no next hidden
  import found", never reaching the iteration cap this test needs to exercise.
- `diag.conda.available` (inline `.github/workflows/batch-check.yml`, the "Check Miniconda
  availability" step -- see `docs/agent-closed-backlog.md`'s Active Backlog item 7 entry for the
  full `conda_avail` history) is always
  `pass: true` (this step itself never fails the job, by design -- it only reports the observed
  fact) and carries `details.available` (`true`/`false`) reflecting whether Miniconda was found at
  the shared `%PUBLIC%\Documents\Miniconda3` path at that point in the job. Added on PR #394 per a
  CodeRabbit finding: the step's own `Write-Host`/output had been observable since PR #390 with no
  NDJSON row. Present in every non-`HP_CACHE_CORRUPTED` lane run regardless of `matrix.mode`, since
  the step itself has no lane restriction.
- `diag.conda.available.gate` (inline `.github/workflows/batch-check.yml`, the "Enforce Miniconda
  availability" step immediately after `diag.conda.available`'s own step) is the ENFORCED judgment
  that gates 27 `conda-full`-only self-test steps and, unlike its sibling above, DOES fail the job
  when it reads `pass: false` (`Write-Host '::error::...'` + `exit 1`, no `continue-on-error`).
  `skip: true, reason: 'not-conda-full'` in every lane except `conda-full`, where it re-reads the
  same `steps.conda_avail.outputs.available` value and requires exactly `'true'` -- anything else
  (including a never-set/empty value) fails loud, deliberately without distinguishing "Miniconda
  genuinely failed to install" from "a bug in this gating mechanism itself" (both are surfaced the
  same way, per an explicit owner decision to prefer a loud failure over any risk of a silent one
  recurring -- see `docs/agent-closed-backlog.md`'s Active Backlog item 7 entry for the full
  PR #390 incident this protects against and the risk/benefit assessment behind this design). On
  failure it also prints the tail
  of `tests\~envsmoke\~envsmoke_bootstrap.log` inline for immediate root-cause visibility.
- A row absent from the diag site means the test script either was not reached, threw
  before the `Write-NdjsonRow` call, or the lane skipped that selfapps file.
- Rows gated by `pyFileCount` (e.g. `entry.single.direct`) will be absent whenever the
  bootstrapper repo itself is the test target (pyFiles != 1 in the main repo).
- Check the CI step log for `[INFO] ... skipped:` messages before assuming a test regressed.
- `self.failfast.probe` (bare row, distinct from `self.failfast.probe.fastfail`/`.alive`) is
  emitted inline by `run_setup.bat`'s `:run_failfast_probe`, gated on `HP_NDJSON`. The current CI
  lane that forces the interactive branch (`HP_TEST_FORCE_INTERACTIVE_PROBE=1`, in
  `selfapps_failfast_probe.ps1`) unsets or never populates `HP_NDJSON` for that sub-bootstrap, so
  this row does not currently appear in a real CI artifact -- same situation as `self.exe.smokerun`
  and other inline-emitted rows. It is registered above so its id is not mistaken for an
  unexpected/typo'd addition if a future lane change makes it fire.
- **Backfilled 2026-07 via `tools/check_ndjson_registry.py`'s first real run.** Twelve rows were
  genuinely emitted but never registered: `conda.url` and `env.mode` (inline `run_setup.bat`,
  `HP_NDJSON`-gated -- the Miniconda download-probe outcome and the REQ-009 selected-provider
  log, respectively), `self.warnfix.platform_filter` (inline `run_setup.bat`, confirms the
  warnfix POSIX-module filter ran), `self.exe.smokerun` (inline `run_setup.bat`'s
  `:smokerun_ndjson`, the EXE smoke exit-code row -- already referenced by the bullet above but
  never formally registered), `helper.find_entry.syntax` (inline `run_setup.bat`, HP_FIND_ENTRY
  payload compile-probe result) and `entry.helper.ok` (`harness.ps1` re-emits the same
  pass/fail under this id), `entry.single.direct` (`selfapps_single.ps1`, REQ-002 -- already
  referenced two bullets above but never formally registered), `entry.expected` and
  `helper.invoke` (both `selfapps_single.ps1`, REQ-002 companion failure-detail rows --
  `helper.invoke` is the same passive failure-detector documented for
  `self.entry.helper.invoke.absent` above, just the underlying row itself), `envsmoke.run`
  (`selfapps_envsmoke.ps1`, REQ-003 failure-detail row), and `self.cache.corrupted` (`harness.ps1`,
  see `docs/agent-lessons-learned.md`'s cache-lane corruption-handling entry for the full
  mechanism). This pass also caught the tool's own scope gap: `.github/workflows/*.yml` inline
  PowerShell/Python was not scanned at all, which produced two kinds of error simultaneously --
  three ALREADY-registered rows (`self.heuristics.pytest`, `self.parse_warn.pytest`,
  `self.pytest.unit`, all emitted from `batch-check.yml` steps) were misreported as stale, and at
  least two genuinely emitted rows (`self.cache.bootstrap.failed`, the sibling of
  `self.cache.corrupted` documented in the same lessons-learned entry; `meta.env.mode`, the
  per-lane "matrix mode meta row" step that fires unconditionally at the end of every selftest
  matrix lane) were invisible to the tool entirely -- they never appeared in either the doc_only
  or code_only list on the first run, because the tool didn't scan the file that emits them. A
  fourth PowerShell/JSON emission convention was also found and added to the scanner: a raw
  JSON-string literal (`'{"id":"...",...}'`), used by the "Catch cache lane bootstrap failure"
  step instead of the `id = '...'` hashtable-literal form the other three conventions use.
  `tools/check_ndjson_registry.py` now scans `.github/workflows/*.yml`/`*.yaml` in addition to
  `tests/*.ps1` and `run_setup.bat`, and recognizes all four conventions. `workflow.lint` (from
  the separate, dormant `workflow-lint.yml` -- `workflow_dispatch`-only, not run automatically;
  see AGENTS.md/CLAUDE.md for why) was registered too for the same completeness reason, even
  though that workflow rarely executes in practice.
- `pipreqs.install` and `pipreqs.run` (backfilled into the registry 2026-07; both already
  existed in code before this) were emitted but undocumented gaps in this registry.
  `pipreqs.install` is emitted inline by `run_setup.bat` (gated on `HP_NDJSON`) right after the
  pipreqs package-install attempt, with `pass`/`reason` reflecting `success`,
  `install_failed`, `pep723_active`, or `skip_preexisting`. `pipreqs.run` is emitted by a
  `Check-PipreqsFailure` helper duplicated across `selfapps_entry.ps1`, `selfapps_envsmoke.ps1`,
  and `selfapps_single.ps1` -- it is a *passive* detector that only fires (and fails) if an
  *unexpected* real pipreqs failure (matching `No module named pipreqs\.__main__`) is found in
  a test's bootstrap log; it is not an active failure-injection hook. Contrast with
  `self.stub.pipreqs_version_fail` (Test-logs NDJSON, below), which *deliberately* forces
  pipreqs's own install to fail via `HP_PIPREQS_VERSION=99.99.99` (a version that has never
  existed on PyPI, chosen for determinism over pipreqs 0.5.0's real `<3.13` cap -- the cap alone
  does not reliably fail on every lane's ambient Python) to prove the warnfix fallback
  recovers gracefully.
- `self.embed.fallback.decline` and `self.embed.fallback.real` (REQ-009 Tier 5, the standalone
  embeddable-Python download fallback -- see `docs/agent-interconnect.md` "Standalone
  Python-download tier") are emitted by `selfapps_ux_hardening.ps1`. Since the provider-chain
  reorder (`uv -> conda -> embed -> venv -> system`), embed is reached directly after conda fails
  -- `HP_TEST_FORCE_CONDA_FAIL=1` alone is enough to reach it, the same way a real user with no
  reachable uv/conda (but a working venv/system fallback still available) would reach it.
  `.decline` ALSO forces `HP_TEST_FORCE_VENV_FAIL=1` and `HP_TEST_SYSCON_ANSWER=N` -- not to
  reach embed (unnecessary now), but so the run doesn't silently recover through venv/system
  after embed's forced failure (`HP_TEST_FORCE_EMBED_FAIL=1`), which would defeat the point of
  proving tier EXHAUSTION reaches a clean `:die` (state=error, non-zero exit) instead of a hang
  or false success. It additionally asserts the embed-attempt log line appears BEFORE the
  venv-fallback log line, proving the new order actually executes. `.real` sets
  `HP_TEST_FORCE_EMBED_REAL=1` (a narrow hole through the `HP_OFFLINE_MODE=1` gate for this tier
  only) and exercises the real download-verify-extract-patch-pip-bootstrap-canary-build-run path
  end-to-end -- `HP_TEST_FORCE_VENV_FAIL`/`HP_TEST_SYSCON_ANSWER` are NOT needed here since embed
  succeeding short-circuits the chain before venv is ever attempted; it instead asserts the
  venv-fallback log line is ABSENT, proving that short-circuit. Both skip with `skip=true` in the
  conda-full lane (`HP_FORCE_CONDA_ONLY=1` blocks all non-conda fallbacks).
- `self.embed.dl.retry` (former CLAUDE.md Active Backlog item 12, `selfapps_ux_hardening.ps1`)
  closes the gap that `.real` above does not cover: `:embed_dl_retry`'s genuine mid-download-
  failure-then-retry-once path. Combines `HP_TEST_FORCE_EMBED_DL_FAIL_ONCE=1` (deterministically
  fails ONLY the first download attempt, no network touched, cleared immediately after firing)
  with `HP_TEST_FORCE_EMBED_REAL=1` so the second, real attempt genuinely succeeds -- asserts
  both the `[TEST] HP_TEST_FORCE_EMBED_DL_FAIL_ONCE:` hook-fired line and the
  `[WARN] embed fallback: download failed; retrying once.` line appear, AND that the tier still
  succeeds end-to-end afterward. Skips with `skip=true` in the conda-full lane, same reasoning.

**NDJSON files and who owns them:**
- `tests/~test-results.ndjson` -- written by every `selfapps_*.ps1` test script during the
  CI run. The selfapps scripts APPEND rows to this file. The CI "Verdict from NDJSON" step
  reads it immediately after upload. Later, `harness.ps1` DELETES it and REWRITES it with
  harness static check rows. The final artifact content is harness rows only.
- `ci_test_results.ndjson` -- parallel aggregator written by selfapps scripts; used as
  fallback by the "Verdict from NDJSON" step if `tests/~test-results.ndjson` is empty/missing.
  `harness.ps1` does NOT read this file.
