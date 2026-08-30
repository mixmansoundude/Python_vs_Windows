# NDJSON Surface -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-ndjson.md`
import in CLAUDE.md. It lists all known NDJSON rows by lane and test source.

The diagnostics site is the authoritative source of truth for live row counts:
https://mixmansoundude.github.io/Python_vs_Windows/

**AGENT DIRECTIVE: When new NDJSON rows are added (new selfapps files, new harness checks),
update this file in the same commit. Row IDs listed here act as a registry to catch
accidental removal or unexpected additions.**

**House rule: this file is the registry itself (row id -> emitting test/lane/mechanism), not a
narrative.** Keep annotations to what a row means and how it's gated. A row's own MECHANISM
(why the underlying feature works the way it does) belongs in `docs/agent-interconnect.md` or
`docs/agent-lessons-learned.md` -- point there instead of re-explaining it here. The "how this
row was found/fixed" bug-hunt detail belongs in `docs/agent-closed-backlog.md`.

---

## CI-artifacts NDJSON (selfapps tests, conda-full lane)

```
self.harness.started, self.bootstrap.state, self.empty_repo.msg,
self.empty_repo.no_spurious_warn,
self.env.smoke.conda, self.env.smoke.run, self.env.smoke.uv, envsmoke.run,
self.uv.managed.interpreter,
self.exe.build, self.exe.run, self.exe.build.xfail,
self.exe.smokerun.xfail, self.exe.smokerun.exedata.xfail, self.exe.smokerun.exedyn.xfail,
self.exe.smokerun.cwd_consistency,
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
self.preflight.cwd_not_writable, self.preflight.ps_capability_fail,
self.entrysmoke.no_interpreter_guard,
self.cascade.detect, self.cascade.consent, self.cascade.timed,
self.cascade.exec (uv lane only -- selfapps_cascade.ps1; non-gating),
self.cascade.conda_create_fail (uv lane only -- selfapps_cascade_conda_create_fail.ps1; non-gating),
self.layered_e2e.chain (cache lane only -- selfapps_layered_e2e.ps1; non-gating),
self.gribapi_hook_probe.hidden_import (conda-full lane only -- selfapps_gribapi_hook_probe.ps1; non-gating),
self.conda.bothfail (uv lane only -- selfapps_conda_bothfail.ps1; non-gating),
self.console.tiering (uv lane only -- selfapps_console_tiering.ps1; non-gating),
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
self.ux.connectivity.online, self.ux.connectivity.retry, self.ux.connectivity.override,
self.ux.system.gate.n, self.ux.system.gate.prompt, self.ux.system.gate.real, self.ux.system.gate.accept,
self.ux.gitignore.merge, self.ux.gitignore.preserve, self.ux.gitignore.idem,
self.ux.gitattributes.merge, self.ux.gitattributes.idem, self.ux.gitattributes.migrate,
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

The `helpers.*`/`bootstrap.status` rows fire from `tests/dynamic_tests.py`'s own
`ensure_extracted()` payload-decode loop and `main()`'s status-file read: `helpers.run_setup`
only on the rare `run_setup.bat missing` guard; `bootstrap.status` once per run; the 5
`helpers.decode.*` rows once per embedded helper payload decoded out of `run_setup.bat`.

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
batch.entrysmoke.no_interpreter_guard,
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
batch.script_root.trailing_backslash,
batch.progress.conda_create, batch.progress.pyi_build, batch.progress.dep_install,
batch.fastpath.hash_write,
batch.warnfix.fresh_build_ok_clear,
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
batch.dll_bundle.caveat_hint,
self.dll_bundle.recover,
self.bootstrap.state, self.empty_repo.msg, self.empty_repo.no_spurious_warn,
self.empty_repo.pytxt_hint,
self.empty_repo.subfolder_hint, self.empty_repo.subfolder_hint_neg,
self.empty_repo.subfolder_hint_pct,
self.harness.started,
self.stub.fastpath, self.stub.rebuild, self.stub.state_skip,
self.stub.conda_retry, self.stub.conda_create_retry, self.stub.conda_perpkg, self.stub.pip_warn,
self.stub.pipreqs_version_fail,
self.stub.lock_no_leak, self.stub.lock_held_decline, self.stub.lock_stale_evict,
self.stub.lock_indeterminate,
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

`self.corrupt.conda.override_exit` covers the `PVW_CONDA_EXE` super-user-override's corrupt-conda
path (`:corrupt_override_exit`, distinct "fix manually, do not self-heal" messaging) -- unlike its
three `self.corrupt.conda.*` siblings, NOT gated on Miniconda already being on disk (setting
`PVW_CONDA_EXE` unconditionally sets `CONDA_BAT` before the install-if-missing block runs).

`self.dll_bundle.recover` (`:emit_dll_bundle_row`, all 7 outcome points inside
`:dll_bundle_recover`) is the machine-readable record of the conda native-DLL bundling repair
loop -- see `docs/agent-interconnect.md`'s "Conda native-DLL bundling repair loop" section for the
full mechanism. `details.state` is one of `skipped_nuitka`, `skipped_non_conda`, `repaired`,
`unlocatable`, `exhausted`, `failed_rebuild`, or `failed_missing_exe`; `pass` is `false` only for
the two `failed_*` states. Now wired for real observation and confirmed via real CI (CLAUDE.md
Item 37, PR #452): `selfapps_layered_e2e.ps1` explicitly sets `HP_NDJSON` for its own
sub-bootstrap (the opposite of most other isolated-sub-bootstrap tests, which deliberately unset
it) so this row fires for real, recorded as an informational (non-gating) detail on
`self.layered_e2e.chain`'s own row rather than folded into that test's pass/fail. One confirmed
run is not yet enough for Item 35's promotion-out-of-`continue-on-error` bar.

`batch.dll_bundle.ndjson`/`.pct_sanitizer`/`.second_pass`/`.caveat_hint` (`tests/harness.ps1`) are
four SEPARATE static wiring/fixture checks in the same family, none of which prove runtime
correctness by themselves: `.ndjson` verifies the label/row-id/all-7-call-sites exist;
`.pct_sanitizer` (gating) live-executes a real cmd.exe+PowerShell fixture proving the `%`/`^`
sanitization actually works (see `docs/agent-lessons-learned.md`'s "`:log` echoes UNQUOTED" entry
for the fixture's own history); `.second_pass` guards the second `:dll_bundle_recover` pass that
runs after `:hidden_import_recover` (see the interconnect doc's same DLL-bundling section); and
`.caveat_hint` guards the postflight caveat panel's DLL-specific hint wording. Runtime proof for
all of these is `self.layered_e2e.chain`'s own `chainPass`/`mech4Pass` (`cache` lane, non-gating),
confirmed `true` via real CI (PR #421).

## selfapps-ux-hardening NDJSON rows (selfapps_ux_hardening.ps1, non-conda-full lanes)

```
self.ux.gitignore.merge, self.ux.gitignore.preserve, self.ux.gitignore.idem,
self.ux.gitattributes.merge, self.ux.gitattributes.idem, self.ux.gitattributes.migrate,
self.ux.postflight,
self.ux.connectivity.offline.n, self.ux.connectivity.prompt.shown,
self.ux.connectivity.offline.uv.skip, self.ux.connectivity.offline.conda.skip,
self.ux.connectivity.online, self.ux.connectivity.retry, self.ux.connectivity.override,
self.ux.system.gate.n, self.ux.system.gate.prompt, self.ux.system.gate.real, self.ux.system.gate.accept,
self.sysbuild.decline,
self.venv.fallback, self.venv.canary_fail, self.venv.nopip_retry, self.entry.override,
self.embed.fallback.decline, self.embed.fallback.real, self.embed.dl.retry
```

`self.ux.gitattributes.migrate` (CLAUDE.md Item 60) is a separate scratch-dir scenario from
`.merge`/`.idem` -- pre-seeds a `.gitattributes` already carrying the signature AND the disproven
`eol=crlf` rule (simulating a user re-running a newer bootstrapper copy), asserting the new
`HP_MIGRATE_GITATTRIBUTES` payload replaces only the exact stale lines in place.

## selfapps-pep723-writeback NDJSON rows (selfapps_pep723_writeback.ps1, uv-first lanes)

Eight scenarios (`PEP723_SCENARIO`); `fresh`/`idempotent`/`skipflag` are the simplest,
load-bearing cases, `malformed`/`trailing_ws_malformed`/`existing_lockfile`/`non_utf8`/`warnfix`
are adversarial-input scenarios (see `docs/plan-pep723-writeback.md`). Each row emits
`skip=true, reason=provider_not_uv` when `HP_ENV_MODE` did not resolve to uv.

```
self.pep723.writeback.fresh, self.pep723.writeback.idempotent, self.pep723.writeback.skipflag,
self.pep723.writeback.malformed, self.pep723.writeback.trailing_ws_malformed,
self.pep723.writeback.existing_lockfile, self.pep723.writeback.non_utf8,
self.pep723.writeback.warnfix
```

## selfapps-pvw-quickstart NDJSON rows (selfapps_pvw_quickstart.ps1, uv lane only)

Two scenarios (`QUICKSTART_SCENARIO`) -- a dry-run test for README's "PVW QuickStart" copy-paste
commands (standalone uv/autopep723 usage, no `run_setup.bat` involved), self-contained (own uv
acquisition line). Skips with `skip=true, reason=non-windows-host` on non-Windows.

```
self.pvw_quickstart.check, self.pvw_quickstart.run
```

## selfapps-autopep-discovery NDJSON rows (selfapps_autopep_discovery.ps1, uv lane only)

Single deterministic scenario (REQ-005.12, Tier 1): proves the bootstrapper-integrated
`autopep723 check`-and-merge block (`:after_pipreqs_run`) actually populates `requirements.txt`
and the app builds/runs from it alone. `HP_SKIP_PIPREQS=1` isolates Tier 1's own contribution from
pipreqs's overlapping discovery.

```
self.autopep_discovery.merge
```

## selfapps-pvw-idempotent NDJSON rows (selfapps_pvw_idempotent.ps1, uv lane only)

Single deterministic scenario (REQ-005.13, Tier 2): proves `HP_PVW_KNOWN_IDEMPOTENT` actually runs
the entry file live via `uvx autopep723 <entry>`, persists via `uv add --script`, and the app
builds/runs from it afterward. Also asserts the stub app's own `print()` output appears directly
in the bootstrap log, proving the execute-mode discovery run's stdout was genuinely inherited/
passed through live (see `docs/agent-interconnect.md`'s Tier 2 section for the stderr-marker
design this depends on).

```
self.pvw_idempotent.discovery
```

## selfapps-pvw-overrides NDJSON rows (selfapps_pvw_overrides.ps1, uv lane only, non-gating)

`PVW_PYTHON_EXE`/`PVW_WORKSPACE` had zero prior coverage of any kind, and all five `PVW_*`
overrides had zero coverage of their invalid-value behavior. Four scenarios: valid/invalid for
both variables. `self.pvw.python_exe.valid`/`self.pvw.workspace.valid` prove the override is
genuinely honored (log line fires, the app runs via the borrowed/relocated interpreter/venv, the
default path is never created). `self.pvw.python_exe.invalid`/`self.pvw.workspace.invalid` prove
the failure absorbs gracefully (a smoke-test warning, or a fallthrough into the already-established
`:uv_venv_fail` -> conda-create chain) rather than crashing uncontrolled. All four skip with
`skip=true` in the conda-full lane (uv is never the provider there).

```
self.pvw.python_exe.valid, self.pvw.workspace.valid,
self.pvw.python_exe.invalid, self.pvw.workspace.invalid
```

## selfapps-cascade-timed NDJSON rows (selfapps_cascade_timed.ps1, conda-full lane only)

Proves `:cascade_consent_gate`'s real-interactive-user branch uses a TIMED `choice /T` prompt
(default 30s, `/D N` on timeout) rather than an unbounded `set /p` that would hang an unattended
run forever -- `HP_TEST_FORCE_INTERACTIVE_CASCADE=1` forces the branch under `HP_CI_LANE` with a
2s timeout. Also proves the companion "dependencies may be incomplete" note
(`HP_DEP_MAYBE_INCOMPLETE`) fires at both its injection points when a cascade candidate was
detected but not approved, and that the postexec-offers-skip behavior correctly does NOT fire here
(only cascade approval, not mere detection, skips those elective offers).

```
self.cascade.timed
```

## selfapps-layered-e2e NDJSON rows (selfapps_layered_e2e.ps1, cache lane only, non-gating)

The repo's flagship real, non-simulated end-to-end test: proves FOUR distinct mechanisms fire
together in ONE run, no `HP_TEST_FORCE_*`/`HP_SKIP_*` flags beyond the unavoidable
`HP_TEST_CASCADE_ANSWER=Y` -- the uv-to-conda provider cascade, warnfix repair (a genuine success
AND a genuine failure in the same repair round), `--hidden-import` auto-recovery, and the conda
native-DLL bundling repair loop. Every failure/repair is a genuine, unflagged consequence of three
real packages' actual availability on PyPI vs. conda-forge: `pygrib` (no Windows PyPI wheels, real
conda-forge win-64 builds exist), `xlrd` (a real PyPI wheel, installs fine under warnfix), and
`colorama` (imported only via `importlib.import_module`, invisible to PyInstaller's static
analysis, needs `--hidden-import` even after cascading to conda). See `docs/agent-interconnect.md`'s
DLL-bundling section for the full mechanism trace and why GDAL (the original candidate) was
rejected as the trigger package (see `docs/agent-closed-backlog.md`'s Item 22 for that research).

`$chainPass` requires all 4 mechanism sub-checks (`mech1Pass`-`mech4Pass`); confirmed `true` for
the first time via PR #421's merge (`cache`-lane run `31264219121`). Counts are checked against
`~setup.log` alone, not the stdout+log concatenation, to avoid double-counting every `:log`-emitted
line (which is written to both).

Lane: `cache` only (already caches Miniconda across runs, amortizing the one-time download this
test's own cascade triggers). Non-gating for its first landing -- promote once proven stable
across several real runs (CLAUDE.md's "CI lane gating maturity" periodic check).

```
self.layered_e2e.chain
```

## selfapps-gribapi-hook-probe NDJSON rows (selfapps_gribapi_hook_probe.ps1, conda-full lane only, non-gating)

A one-off empirical experiment (`docs/prd-conda-native-dll-bundling.md` Requirement 1) testing
whether forcing `--hidden-import=gribapi` on a `pygrib` PyInstaller build makes
`pyinstaller-hooks-contrib`'s existing hook bundle `eccodes.dll` for free -- expected negative
(pygrib and gribapi are architecturally independent bindings to the same C library) but run for
real evidence per owner instruction. Deliberately standalone (own scratch conda env, no
`run_setup.bat`/cascade involvement); builds `--onedir` not `--onefile` (a onefile build would make
the DLL-bundling scan structurally unable to observe a positive result, since bundled files only
ever land in a runtime-only `_MEIxxxxxx` temp dir). `pass` reflects whether the experiment ran to
completion, NOT whether the hidden-import "worked" -- the actual finding is
`details.hiddenImportHelped` (`true`/`false`/`null`), determined from a structural build-output
fact (`bundledDll`), not a runtime-behavior fact. Gated on `steps.conda_avail.outputs.available ==
'true'`, same as the other conda-full-only self-tests.

```
self.gribapi_hook_probe.hidden_import
```

## selfapps-conda-bothfail NDJSON rows (selfapps_conda_bothfail.ps1, uv lane only, non-gating)

Covers `:tci_both_failed` (both Miniconda AllUsers and JustMe install types fail), previously zero
CI coverage. `HP_TEST_FORCE_JUSTME_FAIL=1` + `HP_TEST_NOT_ELEVATED=1` deterministically reaches
`:tci_both_failed -> :die` without depending on a genuinely broken installer/ACL environment.
**Placement is load-bearing**: wired immediately BEFORE the provider-cascade-exec step in the `uv`
lane, so Miniconda genuinely does not exist on the runner yet when this test's own install attempt
runs (Miniconda installs to a shared, machine-wide path -- an earlier step installing it first
would make this test's hooks never fire). Asserts `state=error` in `~bootstrap.status.json` (not
silently overwritten back to `ok`); does not assert process exit code (this repo's established
"graceful stop" contract).

```
self.conda.bothfail
```

## selfapps-cascade-conda-create-fail NDJSON rows (selfapps_cascade_conda_create_fail.ps1, uv lane only, non-gating)

Covers a genuine (non-simulated) conda-create failure reached during a REQ-009 cascade re-entry,
which previously fell through `:die` into `:conda_create_done`'s success-path continuation instead
of routing through `:after_cascade_decision` like every other cascade-target failure -- see
`docs/agent-interconnect.md`'s "Provider cascade execution re-enters env-create" section for the
fix (`:cascade_conda_create_failed`). Two scenarios (`CASCADE_CCF_SCENARIO`): `create_fails`
(default, `HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL=1` forces a genuine create+retry failure, exercises
`:conda_create_failed`'s call site) and `missing_python` (`HP_TEST_FORCE_CONDA_MISSING_PYTHON=1`
lets a real `conda create` succeed then deletes the produced `python.exe`, exercising the sibling
`if not exist "%HP_PY%"` call site inside `:conda_create_done`). **Placement is load-bearing**:
both must run AFTER `selfapps_cascade.ps1` in the same job, so Miniconda is already
installed/cached (opposite ordering need from `self.conda.bothfail` above). Asserts the cascade
reached conda exactly once, the new `keeping current build` WARN fired, the scenario's own
hard-failure message appears exactly once (not twice -- a second occurrence would be the
fall-through regression signature), and `~bootstrap.status.json` reads `state=ok` (the key
behavioral proof the fix works).

```
self.cascade.conda_create_fail
```

## selfapps-console-tiering NDJSON rows (selfapps_console_tiering.ps1, uv lane only, non-gating)

Proves the `:log` console-output tiering mechanism (CLAUDE.md Item 42, lever 1 -- see
`docs/agent-lessons-learned.md`'s "`:log` echoes UNQUOTED" entry for the suppression mechanism)
behaves at runtime: `[DEBUG]`/`[TRACE]`/`[INSTALL]` are suppressed from the live console by default
(still written to `~setup.log`) and restorable via `HP_VERBOSE_CONSOLE=1`. Two scenarios
(`CONSOLE_TIER_SCENARIO`): `default` and `verbose`. Forces `HP_FORCE_CONDA_ONLY=1` (conda is the
only provider with a real `[INSTALL]`-tagged install call site) and leaves pipreqs running
normally so all three tags get a genuine, unflagged trigger in one run. **Placement is
load-bearing**: wired immediately after the conda-create-fail steps, reusing their already-cached
Miniconda.

```
self.console.tiering
```

## selfapps-pyinstaller-fail NDJSON rows (selfapps_pyinstaller_fail.ps1, real/conda-full lanes)

Three scenarios (`PYI_FAIL_SCENARIO`: `execfail`/`output_vanish`/`execfail_runtimefail`), XFAIL-
style, testing the PyInstaller BUILD step failing outright. `execfail_runtimefail` (REQ-027 P2)
additionally has the interpreter fallback ALSO exit non-zero, asserting the honest
`HP_NOEXE_VERIFY_FAILED`-gated caveat text appears instead of a false "your code ran successfully"
claim. Asserts `~bootstrap.status.json` genuinely reads `state=error` (the fix this test guards:
a genuine build failure used to fall through `:die` all the way to a `state=ok` overwrite); does
NOT assert process exit code. Also sets `HP_TEST_FORCE_NUITKA_FAIL=1` so Tier A's own fallback is
deterministically forced to fail too (otherwise a real Nuitka build could silently succeed here,
turning this "everything fails" test into a fallback-success case, covered separately by
`self.exe.build.tiera`).

```
self.exe.build.xfail
```

## selfapps-nuitka-tiera NDJSON rows (selfapps_nuitka_tiera.ps1, uv lane only, non-gating)

Proves AV-Safe Build Path Tier A end to end: `HP_TEST_FORCE_PYINSTALLER_FAIL=1` forces the primary
build to fail, a REAL (unforced) Nuitka build runs in the same environment, and the fallback
succeeds with `state=ok`. Non-gating -- exercises genuine Nuitka CLI/MSVC availability that could
not be verified locally.

```
self.exe.build.tiera
```

## selfapps-nuitka-tiera-hidden-skip NDJSON rows (selfapps_nuitka_tiera_hidden_skip.ps1, uv lane only, non-gating)

Regression test: `:hidden_import_recover` used to unconditionally rebuild via PyInstaller even
when `dist\<env>.exe` was actually Nuitka-built (Tier A), risking reproducing the very failure Tier
A exists to route around. Same `HP_TEST_FORCE_PYINSTALLER_FAIL=1` technique as
`self.exe.build.tiera`, with a real Nuitka build; the stub app prints a fabricated exact-format
`ModuleNotFoundError: No module named 'nuitka'` (deterministically constructing the trigger
condition, since `nuitka` really is installed in Tier A's own build interpreter) and asserts the
new skip guard fires and the OLD PyInstaller-rebuild log line does not.

```
self.exe.tiera.hidden_skip
```

## selfapps-optimized-build NDJSON rows (selfapps_optimized_build.ps1, uv lane only, non-gating)

Proves AV-Safe Build Path requirement 9 (`:offer_optimized_build`, see
`docs/agent-interconnect.md`'s dedicated section): after a normal, verified-successful PyInstaller
build, an elective Nuitka-optimized-build upsell builds to a temp file, verifies it, and only then
swaps it into place -- any failure leaves the original untouched. Four scenarios
(`OPTBUILD_SCENARIO`): `accept` (real build+swap succeeds), `forcefail` (forced build failure,
original untouched), `swapfail` (forced swap failure -- regression test for a real bug where the
old "did the swap succeed" check tested the DESTINATION, which exists before the move regardless
of outcome; fixed by checking the SOURCE is gone instead), `decline` (ambient CI auto-decline, no
build attempted).

```
self.optbuild.offer
```

## selfapps-interactive-stdin NDJSON rows (selfapps_interactive_stdin.ps1, uv lane only, non-gating)

Proves the full real-Windows nesting a double-clicked `run_setup.bat` uses (`cmd.exe ->
:run_exe_smokerun -> ~exe_smokerun.ps1 -> the built EXE`) carries genuine interactive stdin all the
way through, not just that output is teed -- builds a real PyInstaller EXE from a multi-round
`input()`-driven stub app and pipes a scripted answer sequence into `cmd.exe`'s own stdin,
asserting ORDERING via `IndexOf`, not just presence. Provider-agnostic by construction, so one
passing lane represents all lanes. Does NOT prove a live human's own typing timing -- proves the
plumbing doesn't silently drop or reorder stdin/stdout (see `docs/agent-interconnect.md`'s
"Live-echo redesign" section).

```
self.interactive.stdin.roundtrip
```

## selfapps-gui-timeout-hint NDJSON rows (selfapps_gui_timeout_hint.ps1, uv lane only, non-gating)

Proves `:run_exe_smokerun`'s activity-aware kill correctly distinguishes "zero output by the
deadline" (which a correctly-behaving silent GUI app also produces) from a genuine hang, by
printing a GUI-specific hint instead of implying something is broken (see
`docs/agent-interconnect.md`'s "Activity-aware EXE-smoke kill" section). Uses a real
zero-output-forever EXE with `HP_SMOKERUN_KILL_MS` shortened to 12000ms (a pre-existing test-only
override) rather than a real GUI (no display on a headless CI runner). Asserts the TIMED OUT
status, the caveat header, the new GUI-hint text, and that `dist\` genuinely exists (proving a
real build, not the no-EXE briefing path).

```
self.exe.timeout_gui_hint
```

## selfapps-warnfix-venv-repair NDJSON rows (selfapps_warnfix_venv_repair.ps1, uv lane only, non-gating)

Closes CLAUDE.md's former Item 36: the warnfix repair-install dispatch used to have only
`uv`/`CONDA_BAT` branches, silently no-opping under venv/embed/system while still logging as if
the repair succeeded (see `docs/agent-interconnect.md`'s "Standalone Python-download tier"
section). Forces venv mode via the established `HP_OFFLINE_MODE=1` + `HP_TEST_FORCE_CONDA_FAIL=1`
technique in a fresh scratch dir, using the same `xlrd`-importing stub app as
`selfapps_warnfix.ps1`'s `real_warnfix` scenario. Asserts venv mode was genuinely selected AND
`[INFO] Installed: xlrd` actually appears -- the line NEVER emitted under venv mode before the fix,
even though the rebuild-complete marker fired unconditionally regardless. Skips on non-Windows and
in the conda-full lane.

```
self.exe.warnfix.venv_repair
```

## selfapps-fastpath-hash NDJSON rows (selfapps_fastpath_hash.ps1, uv lane only, non-gating)

Closes CLAUDE.md's former Item 39: the EXE fast path's freshness check switched from mtime-only to
a content-hash comparison (see `docs/agent-interconnect.md`'s "EXE fast path vs env-state fast
path" section for the `HP_FRESH_BUILD_OK`-gated write side). This test backdates a rewritten entry
file's mtime below the built EXE's own mtime (the exact scenario mtime-only checking would miss)
and asserts run 2's captured EXE stdout shows the NEW token, not the old one -- direct evidence a
genuine rebuild happened. `tools/fast_check.ps1` itself is unit-tested directly in
`tests/test_fast_check.py`; this selfapps test proves the full cycle wires correctly end-to-end on
real Windows CI.

```
self.fastpath.hash.backdated_mtime
```

## selfapps-cache-selfheal NDJSON rows (test_ci_cache_selfheal.ps1, `real` lane only, GATING)

The cache-lane self-heal logic (`tools/ci_cache_selfheal.ps1`, see
`docs/agent-lessons-learned.md`'s cache-corruption entry) previously had no deterministic CI
coverage at all -- the ambient `cache` lane only reaches it when GitHub's cache happens to be
organically corrupted, and that lane is itself non-gating. This test exercises all 4 branches
directly against a scratch temp directory with fake `conda.bat` stand-ins, wired into `real` (a
GATING lane) so a regression actually fails CI. Windows-only (shells out to `conda.bat` via
`cmd.exe`; needs Windows file-locking semantics for one scenario) -- skips on non-Windows via the
bare row.

```
self.ci.cache_selfheal,
self.ci.cache_selfheal.healthy, self.ci.cache_selfheal.prefix_healed,
self.ci.cache_selfheal.exact_hit_corrupted, self.ci.cache_selfheal.prefix_heal_failed,
self.ci.cache_selfheal.no_binary
```

`self.cache.selfheal.fired` (inline `batch-check.yml`, `cache` lane) is the companion VISIBILITY
row -- fires only when the ambient `cache` lane's own restored cache is organically corrupted,
recording whether that real self-heal attempt succeeded. Always `pass:true` (informational).

---

## selfapps-aggregate-selftest-verdicts NDJSON rows (test_aggregate_selftest_verdicts.ps1, `real` lane only, GATING)

Proves the fail-closed fix to `selftest-gate`'s own verdict aggregation (CLAUDE.md Item 35's
"Precondition" -- see that item for the full mechanism: comparing the SET of expected lane IDs
against the SET observed, rather than only detecting a total absence of files). Extracted to
`tools/aggregate_selftest_verdicts.ps1`, exercised via 8 fixture scenarios mimicking
`actions/download-artifact@v6`'s own output layout, no dependency on a real 8-lane matrix run.
Wired into `real` (GATING) so a regression in the aggregation logic itself fails CI on every run.

Scenarios: `healthy` (all 8 lanes present, including one whose record omits the `lane` field
entirely, proving the artifact-directory-name fallback), `lane_failed` (a genuine per-lane failure
still detected), `missing_lane` (7 of 8 present -- the actual gap this closes), `unexpected_lane`,
`duplicate_lane`, `empty_fallback` (proves the lane-set check fires independent of the fallback
result), `malformed_json`, `missing_field` (a parse failure or missing field must count as
`has_failures=true`, not silently pass). Pure PowerShell (no Windows-specific calls), verified
locally before reaching real CI.

```
self.ci.aggregate_selftest_verdicts.healthy, self.ci.aggregate_selftest_verdicts.lane_failed,
self.ci.aggregate_selftest_verdicts.missing_lane, self.ci.aggregate_selftest_verdicts.unexpected_lane,
self.ci.aggregate_selftest_verdicts.duplicate_lane, self.ci.aggregate_selftest_verdicts.empty_fallback,
self.ci.aggregate_selftest_verdicts.malformed_json, self.ci.aggregate_selftest_verdicts.missing_field,
diag.selftest_gate.verdict
```

`diag.selftest_gate.verdict` (inline `batch-check.yml`, `selftest-gate`'s own "Aggregate verdicts"
step) is the companion VISIBILITY row for the AMBIENT gate's real outcome each run -- fires once
per real CI run, recording whether the aggregation found `has_failures=true` against that run's
genuine 8-lane artifacts.

---

## selfapps-lineending-check NDJSON rows (selfapps_lineending_check.ps1, real/conda-full lanes, GATING)

The line-ending self-check at the top of `run_setup.bat` (before any goto/call) had zero CI
coverage of its failure branches, since a normal checkout always normalizes to CRLF. Three
`HP_TEST_FORCE_*` hooks close this by redirecting `HP_SELF_PATH` at a synthetic sentinel rather
than corrupting the actually-running copy: `HP_TEST_FORCE_NO_POWERSHELL`, `HP_TEST_FORCE_LF_ONLY`,
`HP_TEST_FORCE_PS_CHECK_FAIL`. Gating from first landing -- a cheap, provider-agnostic, pure-batch
preflight check verified directly against a real PowerShell binary.

Extended for `self.preflight.cwd_not_writable` (the writable-CWD preflight right after these three
checks, before `:merge_git_config`'s first write) and `self.preflight.ps_capability_fail` (probes
`Convert.FromBase64String`/`WriteAllBytes`/`ProcessStartInfo` together, since bare PowerShell
presence doesn't prove a locked-down corporate image -- AppLocker, WDAC, Constrained Language Mode
-- allows the operations this bootstrapper actually needs).

```
self.preflight.no_powershell, self.preflight.ps_check_fail, self.preflight.lf_only,
self.preflight.cwd_not_writable, self.preflight.ps_capability_fail
```

---

## selfapps-entrysmoke-no-interpreter NDJSON rows (selfapps_entrysmoke_no_interpreter.ps1, conda-full lane only, GATING)

Covers a genuine, non-cascade, non-bypassed first-attempt total-tier-exhaustion path reaching
`:run_entry_smoke` with a nonexistent `HP_PY` -- see `docs/agent-interconnect.md`'s "Genuine
(non-cascade) conda-create exhaustion" section for the full trace. The fix is a direct guard at
the top of `:run_entry_smoke` (`if not exist "%HP_PY%" set "HP_NO_INTERPRETER=1"`), a backstop at
the actual point of use rather than relying solely on an earlier smoke test. `HP_FORCE_CONDA_ONLY=1`
makes embed/venv/system fallback attempts a no-op, and `HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL=1`
forces the REAL conda create/retry path to fail both attempts. Asserts the honest "No Python
interpreter is available" message, the absence of the old fabricated "syntax error" message, and
that no PyInstaller build is ever attempted.

Updated for Item 46 Bucket A slice 1: also asserts the old `:conda_create_done`-specific message
is genuinely absent (proving that block is skipped) and the new `:after_env_mode_selection` sink
message appears instead -- this fix relocates the second pause to an already-precedented site, it
does not eliminate it (see CLAUDE.md's Item 46 entry).

```
self.entrysmoke.no_interpreter_guard
```

---

## selfapps-die-emit-fallthrough NDJSON rows (selfapps_die_emit_fallthrough.ps1, mixed lanes, GATING)

Covers Item 46 Bucket A Batches 2/3/4/5 (`docs/plan-die-fatal-remediation.md`'s "Batch Roadmap").
Four scenarios (`DIE_EMIT_SCENARIO`): `missing_python` (Batch 2, `:conda_create_done`'s own
non-cascade "python.exe missing" check), `condarc` (Batch 4, the same subroutine's `.condarc`-
staging failure), `ci_skip_entry` (Batch 5, `:ci_skip_entry`'s own staging failure),
`determine_entry` (Batch 3, the first of `:determine_entry`'s two per-run calls). All four emit
the SAME literal id with `details.scenario` as the discriminator (see
`docs/agent-lessons-learned.md`'s "NDJSON `id` must stay a literal string" entry for why).

New hook `HP_TEST_FORCE_EMIT_FAIL=<VARNAME>` (`:emit_from_base64`) fails one specific embedded-
helper write deterministically, used by `condarc`/`ci_skip_entry`/`determine_entry`;
`missing_python` reuses the existing `HP_TEST_FORCE_CONDA_MISSING_PYTHON` hook without any cascade
env vars set. `ci_skip_entry` also documents a known, unfixed, near-zero-exposure quirk:
`:after_env_skip` writes `state=ok` unconditionally regardless of an earlier `call :die` in the
same run (`HP_CI_SKIP_ENV` is test-infrastructure-only).

Lane: `conda-full` for `missing_python`/`condarc`/`determine_entry` (real conda create needed);
every lane for `ci_skip_entry` (no conda/uv dependency). Gating from first landing --
deterministic and self-contained.

```
self.die_emit_fallthrough
```

---

## Key facts for debugging missing rows

- `self.exe.smokerun.cwd_consistency` (`tests/selfapps_exe_cwd_consistency.ps1`, real/conda-full
  lanes) is a POSITIVE proof (not an xfail) that split out of `selfapps_exedata_fail.ps1`'s former
  "plain" scenario once CLAUDE.md Item 38's CWD-mismatch fix landed -- see
  `docs/agent-interconnect.md`'s "Single-verification smoke model" section. Runs `run_setup.bat`
  TWICE against a stub app with a CWD-relative `config.json`: a fresh build and a fast-path reuse
  must BOTH succeed from the same CWD.
- `self.exe.hidden_import.exhaust` (`tests/selfapps_hidden_import_exhaust.ps1`, real/conda-full
  lanes) proves `--hidden-import` auto-recovery reaches its 3-attempt cap for real (unlike its
  one-shot-success sibling `self.exe.hidden_import`) -- the stub app rotates through 3 distinct,
  always-installed fabricated `ModuleNotFoundError`s via a state file surviving the recovery loop's
  own rebuilds (a REPEATED module name would be rejected by the tried-list exclusion instead).
- `diag.conda.available` (inline `batch-check.yml`, "Check Miniconda availability") is always
  `pass:true` (reports the observed fact only) and carries `details.available`. Present in every
  non-`HP_CACHE_CORRUPTED` lane run regardless of `matrix.mode`.
- `diag.conda.available.gate` ("Enforce Miniconda availability," the step right after) is the
  ENFORCED judgment gating 27+ `conda-full`-only self-test steps -- DOES fail the job on
  `pass:false`, `skip:true` in every other lane. Deliberately does not distinguish "Miniconda
  genuinely failed" from "a bug in this gating mechanism itself" -- both fail loud, per an
  explicit owner decision (see `docs/agent-closed-backlog.md`'s Active Backlog item 7 entry for the
  PR #390 incident this protects against).
- A row absent from the diag site means the test script either was not reached, threw before its
  `Write-NdjsonRow` call, or the lane skipped that selfapps file. Rows gated by `pyFileCount` (e.g.
  `entry.single.direct`) are absent whenever the bootstrapper repo itself is the test target.
  Check the CI step log for `[INFO] ... skipped:` messages before assuming a test regressed.
- `self.failfast.probe` (bare row, distinct from its `.fastfail`/`.alive` siblings) is emitted
  inline, gated on `HP_NDJSON` -- the current CI lane forcing the interactive branch doesn't
  populate `HP_NDJSON` for that sub-bootstrap, so this row does not currently appear in any real CI
  artifact. Registered here so its id isn't mistaken for an unexpected/typo'd addition.
- `pipreqs.install` is emitted inline right after the pipreqs package-install attempt (`pass`/
  `reason` reflecting `success`/`install_failed`/`pep723_active`/`skip_preexisting`). `pipreqs.run`
  is a PASSIVE detector (a `Check-PipreqsFailure` helper across 3 test files) that only fires and
  fails on an UNEXPECTED real pipreqs failure -- contrast with `self.stub.pipreqs_version_fail`,
  which deliberately forces the failure to prove warnfix recovers gracefully.
- `self.embed.fallback.decline`/`.real` (REQ-009 Tier 5, `selfapps_ux_hardening.ps1` -- see
  `docs/agent-interconnect.md`'s "Standalone Python-download tier" section) are reached directly
  after a forced conda failure, since embed sits right after conda in the provider order.
  `.decline` additionally forces venv/system failure so the run doesn't silently recover past
  embed's own forced failure, proving genuine tier EXHAUSTION reaches `:die` cleanly. `.real` sets
  `HP_TEST_FORCE_EMBED_REAL=1` (a narrow hole through `HP_OFFLINE_MODE`) and exercises the real
  download-verify-extract-patch-pip-canary-build-run path end-to-end. Both skip in the conda-full
  lane.
- `self.embed.dl.retry` closes the remaining gap: `:embed_dl_retry`'s genuine mid-download-
  failure-then-retry-once path (`HP_TEST_FORCE_EMBED_DL_FAIL_ONCE=1` fails only the first attempt,
  combined with `HP_TEST_FORCE_EMBED_REAL=1` so the second genuinely succeeds).

**NDJSON files and who owns them:**
- `tests/~test-results.ndjson` -- written by every `selfapps_*.ps1` test script during the CI run
  (APPENDED to). The CI "Verdict from NDJSON" step reads it immediately after upload. Later,
  `harness.ps1` DELETES it and REWRITES it with harness static check rows -- the final artifact
  content is harness rows only.
- `ci_test_results.ndjson` -- parallel aggregator written by selfapps scripts; used as fallback by
  the "Verdict from NDJSON" step if `tests/~test-results.ndjson` is empty/missing. `harness.ps1`
  does NOT read this file.
