# NDJSON Surface -- Python_vs_Windows

**This file is NOT auto-loaded into every session's context** (unlike
`docs/agent-lessons-learned.md` and `docs/agent-interconnect.md`, which CLAUDE.md's own `@import`
lines pull in automatically -- moved out of auto-load 2026-08-30, ~17k tokens of pure registry
content with no forward-looking guidance most sessions need). Read it on demand: when adding,
renaming, or removing an NDJSON row, or debugging why a row is missing from a CI artifact.

It lists all known NDJSON rows by lane and test source.

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
self.builder.override,
self.exe.smokerun.xfail, self.exe.smokerun.exedata.xfail, self.exe.smokerun.exedyn.xfail,
self.hint.hidden_import.wording,
self.exe.smokerun.cwd_consistency,
self.exe.fastpath.graceful, self.skiphooks.combined,
self.fastpath,
self.failfast.probe.fastfail, self.failfast.probe.alive, self.failfast.probe.seconds, self.failfast.probe,
self.honest.fastpath.note, self.honest.fastpath.outcome,
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
self.preflight.pycache.unwritable, self.preflight.pycache.litter, self.preflight.syntax.compiler (real lane only --
selfapps_preflight_pycache.ps1; REQ-021.4, REQ-021.5 and REQ-021.6, CLAUDE.md Item 83; the third row passes before
and after the fix on purpose: a `return` outside a function is accepted by ast.parse and rejected only by the
compiler, so it pins that the in-memory check stays as strict as py_compile was),
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
self.nuitka.launchcache (uv lane only -- selfapps_nuitka_launchcache.ps1; non-gating),
self.optbuild.offer (uv lane only -- selfapps_optimized_build.ps1; non-gating),
self.parse_warn.table.v6, self.parse_warn.pytest,
self.heuristics.pytest,
self.pytest.unit,
self.runtime.writeback,
self.pandas.openpyxl.install, self.pandas.openpyxl.import,
pandas_excel.translate, pandas_excel.conda.install, pandas_excel.conda.install.req006,
pandas_excel.runtime,
pipgap.conda.miss, pipgap.pip.fill, pipgap.import,
pyvisa.detect, pyvisa.nivisa.branch, pyvisa.nivisa.outcome, pyvisa.nivisa.reason, pyvisa.nivisa.warn, pyvisa.nivisa.disabled,
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
in shared CI runners. Decision (docs/plan-test-suite-gaps.md T10, 2026-10-17): leave the script and this entry
as they are; wiring it into `conda-full` would run `conda update -n base` on the Miniconda every other row in that
lane uses. Revisit if a throwaway Miniconda root becomes cheap to create in the lane.

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

**These rows never appear in this repo's own lanes, by design.** The "Run dynamic tests (if present)" step runs
`tests/dynamic_tests.py` only when `~bootstrap.status.json` at the repo root reports `state=ok`; this repo has no
`.py` entry at its root, so the state is `no_python_files`, the step writes `SKIPPED: no_python_files`, removes
`~dynamic-results.ndjson` and returns. `tests/dynamic_tests.py` is a template that a consumer repo gets together
with `run_setup.bat` (`tests/README_TESTS.txt` says so); the same logic is covered here by the pytest files
`test_detect_python.py`, `test_find_entry.py`, `test_heuristics.py` and `test_pyproj_deps.py`. The registry check lists
the ids above under "never observed in this run's artifacts"; that is expected, not a gap.

## Test-logs NDJSON (harness/selftest, additional rows)

```
file.hash, bootstrap.state, bootstrap.exit, emit.extract (x many),
batch.delayed.off, batch.delayed.enable_absent, batch.bang.scan,
conda.channels, pipreqs.flags, pyi.onefile, tilde.naming,
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
batch.wording.nuitka_duration, batch.wording.optbuild_rerun, batch.optbuild.noninteractive_default, batch.wording.interpreter_prompt_note,
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
self.dep.diff.trace, self.litter.appfolder, self.elevation.logged,
self.warn.onedrive, self.warn.path_negative, self.warn.sysdir,
self.guardrail.g1, self.guardrail.g2, self.guardrail.g3,
self.pep723.valid, self.pep723.uvformat, self.pep723.malformed, self.pep723.pyproject.merge,
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
it; since 2026-10-11 it is a private `~layered_e2e_sub.ndjson` whose rows the test forwards to the
shared stream, see the layered section below) so this row fires for real, recorded as an informational (non-gating) detail on
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
self.sysbuild.decline, self.sysbuild.nuitka_prompt,
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
self.pep723.writeback.warnfix, self.pep723.writeback.roundtrip
```

`idempotent` also emits `roundtrip` (Item 62): run 2 must accept, as the
dependency source, the header the REAL uv wrote on run 1 (not a hand-typed fixture), so a uv layout
change that the bootstrapper's extractor cannot read turns CI red. Same skip rules as the others.

## selfapps-pep723-uverr NDJSON rows (selfapps_pep723_uverr.ps1, real lane, gating)

Item 73: a failed PEP 723 header write-back must log uv's reason. One real bootstrap with the
test hook `HP_TEST_PEP723_UV_ERR` (the helper acts as if uv exited 1 with that text on stderr);
the row needs the `[WARN] REQ-005.11 ... (ERROR:uv_rc_1)` line, both injected reason lines in
`~setup.log`, the entry file byte-identical, and bootstrap state `ok`. If `HP_ENV_MODE` did not
resolve to uv the row fails with `reason=provider_not_uv` on the real lane (a run that never reached the
write-back proved nothing) and records `skip=true` only off the real lane.

```
self.pep723.writeback.uverr
```

## selfapps-vcruntime NDJSON rows (selfapps_vcruntime.ps1, real lane, gating)

Item 77: a run that prints `DLL load failed` on a machine without Microsoft's Visual C++ runtime
(`msvcp140.dll` or `vcruntime140_1.dll` missing from System32) must print a console `[WARN]` naming the
runtime and the download link, once. CI runners have the runtime, so the test hook
`HP_TEST_VCRT_MISSING=1` reports it as missing. Five scenarios, each its own scratch folder; the
fixture raises the exact message the field run printed. `interp` and `interp_probe` force the build to
fail so the interpreter runs the program (legacy branch, and the fail-fast probe a double-click user
gets); `exe` pays for a real EXE build; `runtime_present` has no simulation and expects the warning
exactly when this runner's System32 really lacks the files; `unrelated_error` has the simulation on and a
non-DLL failure and expects no warning. Every row also requires proof the program ran (its captured
stderr holds the fixture text).

```
self.vcruntime.warn.interp, self.vcruntime.warn.interp_probe, self.vcruntime.warn.exe,
self.vcruntime.warn.runtime_present, self.vcruntime.warn.unrelated_error
```

## selfapps-pvw-quickstart NDJSON rows (selfapps_pvw_quickstart.ps1, uv lane only)

Two scenarios (`QUICKSTART_SCENARIO`) -- a dry-run test for README's "PVW QuickStart" copy-paste
commands (standalone uv/autopep723 usage, no `run_setup.bat` involved), self-contained (own uv
acquisition line). Skips with `skip=true, reason=non-windows-host` on non-Windows.

```
self.pvw_quickstart.check, self.pvw_quickstart.run
```

## selfapps-toml-uvcorpus NDJSON rows (selfapps_toml_uvcorpus.ps1, uv lane only, non-gating)

Item 79 slice 1: a standalone canary (installs uv the README way, no `run_setup.bat`). Real
`uv add --script` writes four dependencies (lower bound, extra with `~=`, two markers) and
`tools/pep723_extract.py` must list exactly what `tests/toml_oracle_check.py` (PEP regex plus tomllib)
reads from the same block. The row also requires the marker and the extra to be present, so a header
that lost them cannot pass. Non-gating: it needs the network. Skips with `skip=true` on non-Windows.

```
self.toml.uvcorpus
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

**The sub-bootstrap's own rows reach the shared stream through the test, not directly** (CLAUDE.md
Item 35, 2026-10-11). The uv tier builds an EXE that cannot import `pygrib`, so its verification run exits
1 by design and `run_setup.bat` emits `self.exe.smokerun` `pass:false` before the cascade moves to conda
(run `38157663037` cache NDJSON: uv `env.mode`, `pass:false`/`exitCode:1`, conda `env.mode`, DLL rows,
`pass:true`/`exitCode:0`). That row was the `cache` lane's only red row. The test forwards every row of
`~layered_e2e_sub.ndjson` unchanged except an EARLIER `self.exe.smokerun` that matches the expected uv-tier
failure on every point: `pass:false` with `exitCode:1`, `uvInstallFailed`, the cascade approved with exactly
one uv to conda hop, and `[HINT][HIDDEN_IMPORT] Hidden import likely missing: pygrib` in the setup log before
that hop (`:hint_hidden_import` reads it out of the EXE's own output). Any other failing row, including an
unexpected uv-tier failure, is forwarded and stays red; the LAST `self.exe.smokerun` is always forwarded as
emitted. The chain row carries `smokerunExits` (every exit code in order, for example `1,0`),
`smokerunDropped`, `uvTierPygribHint`, `condaSmokePass` and `smokeSequencePass`, and `chainPass` requires
`smokeSequencePass` (exactly one dropped row and a passing last row).

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
`self.exe.build.tiera`). The `execfail_runtimefail` scenario also writes `self.honest.noexe.caveat` (README
REQ-027.1): the closing panel names the caveat heading and says it cannot tell whether the failure is the program's
or the bootstrapper's, the success heading and the "ran successfully" sentence are absent, the setup log carries the
matching `[WARN] REQ-016` line, and the `[STATUS]` line shows the interpreter's exit code (3 from the stub app).
The two cached-EXE rows of the same requirement, `self.honest.fastpath.note` (REQ-027.2: one note, names the EXE to
delete) and `self.honest.fastpath.outcome` (REQ-027.3: state `ok` and exit code 0), are written by
`selfapps_failfast_probe.ps1` from its alive scenario (real/conda-full lanes, gating).

```
self.exe.build.xfail
self.honest.noexe.caveat
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

## selfapps-nuitka-launchcache NDJSON rows (selfapps_nuitka_launchcache.ps1, uv lane only, non-gating)

Item 72 (b) experiment. After a forced-PyInstaller-failure bootstrap leaves a uv venv with Nuitka,
the script builds a `--onefile` EXE with a 40 MB data file twice with the bootstrapper's own flags
(default unpacking, and `--onefile-tempdir-spec={CACHE_DIR}/pvw_launchcache_exp/<token>`), launches
each three times, then rebuilds the cached variant from changed source and launches it. `pass` is
the mechanism only (flags still match `run_setup.bat`, builds ran, every launch printed the expected
marker and payload size, default unpack folders were removed, the cache folder stayed and lies under
the spec); `details` holds the findings (`defaultLaunchMs`, `cachedLaunchMs`, `rebuildRanNewCode`,
`rebuildRanStaleCode`, `realtimeMonitoringDisabled`, `finding`). Non-gating: three real Nuitka
builds and a possible compiler download.

```
self.nuitka.launchcache
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

## selfapps-pvw-builder NDJSON rows (selfapps_pvw_builder.ps1; five scenarios on real/conda-full, two on the uv lane)

Item 71: the `PVW_BUILDER=auto|pyinstaller|nuitka|both` super-user override (see
`docs/agent-interconnect.md`'s "PVW_BUILDER" entry). Absence of the variable is today's behavior, so
every scenario sets it and asserts a decision the default run would not make. Gating, deterministic
(`PVW_BUILDER_SCENARIO`): `invalid` (an unknown value full of cmd syntax warns once, is not echoed or acted on,
behaves as auto),
`pyinstaller_nofallback` (Nuitka fallback switched off, never reached, and an EXE left by an earlier run is removed), `pyinstaller` (a real build is
kept and the optimized-build offer is not shown), `nuitka_forcefail` (PyInstaller is neither installed nor run,
failure reported with `reason=builder_nuitka`), `nuitka_stale` (a `dist\<env>.exe` left by an earlier run is removed
by a failed Nuitka-only build, so the verification run goes through the interpreter as the log says), `nuitka_warnfile` (a PyInstaller warn file the bootstrapper cannot delete, held open by the test, never starts the warnfix repair, an install or a PyInstaller rebuild), `both_forcefail` (the optimized build starts without a prompt
and its failure leaves the verified EXE untouched). Non-gating, uv lane only, because a real Nuitka
build needs a compiler download that can fail for network reasons (same precedent as
`self.exe.build.tiera`): `nuitka`, `both`.

```
self.builder.override
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

Precondition (Item 35): the test writes a user `requirements.txt` naming only `six`. Under venv mode
`HP_SKIP_PIPREQS` is reset by `:venv_canary_ok`, so without a `requirements.txt` pipreqs would find
xlrd and promote it, and the main install would install xlrd up front. `details.preconditionOk` is
false if `requirements.txt` ever names xlrd. `details.attemptedXlrd` (the dispatch's
`Attempting to install: xlrd` line) and `details.systemSkipWarn` separate "the repair dispatch ran no
branch" (`warnInstallFired` true, both false) from "pip ran and failed" (`repairFailed` true).

```
self.exe.warnfix.venv_repair
```

## selfapps-launch-ledger NDJSON rows (selfapps_launch_ledger.ps1, real lane only, gating)

Gap T1 of `docs/plan-test-suite-gaps.md`. A stub program appends one JSON line per launch to
`~ledger.jsonl` in its working directory (argv, `sys.frozen`, `sys.prefix`, `sys.executable`,
`PYTHONHOME`, cwd), so the suite counts launches and compares argv instead of reading log lines. The
batch is invoked through a generated `~ledger_launch.cmd` so quoting (including the empty argument) is
exactly what a user types: `run_setup.bat ledger_app.py "a b" "" c d e f g h i`. Five bootstraps:
A fresh (EXE smoke run), B rerun in the same folder (cached-EXE fast path), C PyInstaller and Nuitka
forced to fail (interpreter verification) with a poisoned `PYTHONHOME` and a decoy `python.cmd` first
on `PATH`, D `HP_TEST_CHECKPOINT_ANSWER=Y` (the accepted checkpoint's second run), E a fresh build with no
program arguments (the EXE smoke run must record an empty argv). The expected argv is
`["a b","c","d","e","f","g","h"]`: positions 2 to 9 are forwarded, the empty one is dropped, the 10th is
ignored. An in-script comparator self-check (`comparatorOk`) fails the first row if the comparison could
not fail. Skips on non-Windows and in conda-full (`HP_FORCE_CONDA_ONLY=1`).

```
self.launch.argv.fresh
self.launch.argv.cap
self.launch.count.default
self.launch.argv.fastpath
self.launch.argv.interpreter
self.isolation.req010.pythonhome
self.isolation.req010.path_shadow
self.launch.count.checkpoint
self.launch.argv.checkpoint
self.launch.argv.none
```

## selfapps-skiphooks-single NDJSON rows (selfapps_skiphooks_single.ps1, real lane only, gating)

Gap T1 slice E of `docs/plan-test-suite-gaps.md` (README REQ-012). `selfapps_skiphooks.ps1` sets
`HP_SKIP_ENTRY_SMOKE` and `HP_SKIP_EXE_SMOKERUN` together; this script runs each ALONE, with the launch ledger
idea of `selfapps_launch_ledger.ps1` (a stub appends one JSON line per launch to `~ledger.jsonl`). Each scenario is
one fresh folder bootstrapped twice. `entry_only`: the interpreter smoke test is skipped but the EXE verification run
is not, so the build launches the program once (frozen) and the repeat, which reuses the cached EXE, once more (two
lines). `exe_only`: the EXE is built and not run, the interpreter verifies the build once (not frozen) because
skipping the EXE run must not leave the build unverified, and the repeat logs `reusing cached EXE without running it`
and launches nothing (the ledger stays at one line). Details also record whether the `entry_only` repeat reused the
cached EXE or rebuilt (informational, not asserted). Skips on non-Windows.

```
self.skiphooks.entry_only
self.skiphooks.exe_only
```

## selfapps-runtests-contract NDJSON rows (selfapps_runtests_contract.ps1, every lane, gating)

CLAUDE.md Item 84. Runs a copy of the real `run_tests.bat` against stub `harness.ps1` /
`selftest.ps1` / `selftests.ps1` scripts (each records a marker file and exits with a chosen code), so the
promises about the self-test section are checked in seconds without a provider. `all_green`: every
stub passes, exit 0. `harness_red`: a red harness still runs both self-test scripts and the exit stays
1 (before the fix the self-test rows simply vanished from a run with a red harness, and an absent row cannot
be red). `selftest_red`: a red selftest.ps1 keeps the exit at 1 and selftests.ps1 still runs.
`selftest_unreported` / `selftests_unreported`: a script that exits 0 but never wrote its summary file
did not complete, so the batch exits 1 and says "did not complete", even with an older summary file lying
there (run_tests.bat clears them first). `summary_locked`: the same stale summary held open by another
process, so it cannot be deleted; it must not vouch for the run, the batch exits 1 and says it could not remove
the file (details `lockHeld` and `staleSurvived` prove the precondition). Pairs with `tests/test_run_tests_step.py`, which pins the CI
step to `exit $rc`. Runs before "Upload CI NDJSON" like every selfapps step, so its rows are part of the
pre-harness verdict.

```
self.runtests.all_green
self.runtests.harness_red
self.runtests.selftest_red
self.runtests.selftest_unreported
self.runtests.selftests_unreported
self.runtests.summary_locked
```

## selfapps-unicode-path NDJSON rows (selfapps_unicode_path.ps1, real lane only, gating)

Gap T8 of `docs/plan-test-suite-gaps.md` (README REQ-001). The stub program is bootstrapped from
`<tests>\~selftest_unicode_path\Caf<U+00E9> Test\Jos<U+00E9>` (an accented e in two components, one with
a space; built at run time so repo files stay ASCII) through a generated `~unicode_launch.cmd`, so no
non-ASCII text is typed into a command line by the script. The row passes only if the bootstrap exits 0,
`~bootstrap.status.json` says `ok`, an EXE exists under `dist`, the log shows `Entry smoke exit=0` with no
path error, and the frozen program's own record (`~unicode_token.json`) names the same two folder
components (compared by code points, so a lossy `?` would not match) and carries the expected token. ASCII
copies of the logs go to `tests\~selftest_unicode_path_evidence`. First real run (CI run 39023711765): the
bootstrap succeeded and the program saw the exact folder names; the environment name (and so the EXE) loses the
accented letter, `Jos_.exe`, which the row records without asserting. The two `The system cannot find the drive
specified.` lines in `suspectLines` are the known stray message the batch announces before the PyInstaller build.
Skips on non-Windows.

```
self.prime.unicode-path
```

## selfapps-unc NDJSON rows (selfapps_unc.ps1, real lane only, gating)

Gap T9 of `docs/plan-test-suite-gaps.md` (README REQ-003 limitation: UNC paths are not supported for reliable
bootstrap). A copy of the bootstrapper is started through the runner's own admin share, `\\localhost\<drive>$\...`,
from a local working directory (a wrapper `~unc_launch.cmd` logs locally). `self.warn.unc.probe` writes a marker
file locally and reads it back through the share; it only records whether the share reaches the folder
(`reachable`) and is `pass:true` whenever the probe ran. `self.warn.unc` runs only when `reachable` is true and
passes only if the batch printed the UNC warning and `Workspace path invalid`, exited 1, left no `dist` folder and
finished inside 180 seconds. When the share is unavailable it reports `skip` with reason `unc-share-unavailable`,
which is a skip and not a pass of the behavior (a lane where that happens everywhere is a finding, plan criterion
C5). A copy of the launch log goes to `tests\~selftest_unc_evidence`. Skips on non-Windows.

```
self.warn.unc.probe
self.warn.unc
```

## selfapps-noflag-default NDJSON rows (selfapps_noflag_default.ps1, real lane only, gating)

Gap T12 of `docs/plan-test-suite-gaps.md` (README REQ-019, REQ-018). Every other scenario runs under
`HP_CI_LANE`, so the branches a double-click user takes (the elective prompts reaching `set /p`, the
end-of-run `pause`, the interactive fast-path probe) never ran in CI. This script removes every `HP_*`,
`PVW_*` and `NOINPUT` variable from its own environment (restored afterwards; the lane tag is captured
first so rows keep it) and starts the bootstrapper with standard input closed (`< nul`, so `set /p` and
`pause` get end-of-file, which is the closest stand-in for nobody answering) and a hard time limit. A
stub program appends one line per launch to `~noflag_ledger.jsonl`. Scenario F is a fresh folder, G the
same folder again. `.run`: finished within the limit, exit code, state `ok`, both `[Y/N]` prompts and the
end-of-run `Press any key` line shown, and no flag in the environment the bootstrapper is started with. That last
check reads the launched shell's own listing (`set HP_`, `set PVW_`, `set NOINPUT`, prefixes only so no token is
dumped). Two real runs showed that `[Environment]::SetEnvironmentVariable($name, $null)` does NOT remove the job's own
variables on the runner (`HP_ALLOW_SYSTEM_FALLBACK`, `HP_ALLOW_VENV_FALLBACK`, `HP_CI_LANE`, `HP_CI_TEST_CONDA_DL`
stayed listed both in the script and in the launched shell), so the script removes them with the `Env:` drive, and
the wrapper clears every one again with `set "NAME="` before the verdict listing. The details keep all three views:
`flagsAtLaunch` (the shell's list before its own clear), `flagsSeenByRun` (after it, the verdict) and `parentStillSet`
(what the script's own removal left behind), so a removal that stops working shows up by name instead of as a bare red.
`.once`: the unanswered
prompts decline and the ledger holds exactly one launch (EXE). `.rerun`: the repeat run takes the
interactive probe branch ("Launching your program now via the cached standalone EXE", not "Fast path:
reusing") and starts the program once more. Limits: only the happy path through the provider chain is
exercised (REQ-019 asks the default run to reach every fallback tier that gets the code running). Skips on non-Windows.

```
self.noflag.default.run
self.noflag.default.once
self.noflag.default.rerun
```

## selfapps-dep-source-matrix NDJSON rows (selfapps_dep_source_matrix.ps1, real lane only, gating)

Gap T2 of `docs/plan-test-suite-gaps.md` (README REQ-005.1, "Source Resolution (authoritative order)"; Item 89: the
lists a program declares are merged on a first run, the rank only settles a conflict about one package, and the recorded
source is the highest ranked list that contributed). One fresh folder and one bootstrap per row. Each folder holds a stdlib-only stub (or one importing `six` in the two
pipreqs cells) and one distinct tiny package per declared source: requirements.txt `termcolor`, pyproject.toml
`iniconfig`, PEP 723 header `toolz`. Both skip hooks are set (no user code runs; the build still does), and the
PEP 723 write-back and autopep723 merge are off so the declared lists stay as written. A row passes only if the
one-line source record the bootstrapper writes (`~dependency_source.txt`, Item 76; only that name is read, so a
return to the old non-tilde name leaves the cells without a record) names the expected source, exactly the expected watched packages are
in `~dependency_installed.txt` (so a losing source's package is absent) and the run exited 0. `.pep723_malformed`
also needs the documented `PEP 723 block found but dependency list is empty or malformed` warning. Details carry the
recorded source, the watched packages installed, and `sourceOk`/`watchedOk`/`ran`. Cells: `.pep723_only`,
`.requirements_only`, `.all_three` (all three packages installed and in requirements.txt, source `pep723`, the
`Dependency lists merged` line and no `overrides requirements.txt` claim), `.pep723_malformed` (falls to
requirements.txt), `.pyproject_nodeps` (falls to requirements.txt), `.requirements_empty` (an empty file is deleted, the
scan decides), `.nothing_declared` (the scan decides; the last two read `pipreqs` and so depend on Item 68's
`DEP_SOURCE` fix), `.requirements_pyproject` (source `pyproject`, both packages) and `.conflict` (`six` pinned 1.15.0,
1.16.0 and 1.17.0 in the three lists: installed at the header's 1.17.0, requirements.txt holds that pin, and the log
names the conflict and the winner). Limits: only the winner and the packages are asserted, not the console wording of every branch. Skips on
non-Windows.

```
self.depsource.pep723_only
self.depsource.requirements_only
self.depsource.all_three
self.depsource.pep723_malformed
self.depsource.pyproject_nodeps
self.depsource.requirements_empty
self.depsource.nothing_declared
self.depsource.requirements_pyproject
self.depsource.conflict
```

## selfapps-dep-merge-later NDJSON rows (selfapps_dep_merge_later.ps1, real lane only, gating)

Item 89, README REQ-005.1: what a LATER run does with the dependency lists (the cold first run is the matrix above).
After a run whose install fully succeeded, requirements.txt and the PEP 723 header hold the same list and each list is
recorded (`~dep_base.requirements.txt`, `~dep_base.pyproject.txt`, `~dep_base.pep723.txt`); the next run treats a
difference from those records as the user's change. Each folder holds a stdlib-only `app.py` (no user code runs: both
skip hooks are set, the build still does; the header write-back is NOT skipped, it is the point) and tiny PyPI packages.
Folder A: `.baseline` (first run of requirements.txt `termcolor` + `iniconfig`: both lists agree, both snapshots exist,
the `Dependency lists recorded for the next run` line), `.delete` (iniconfig deleted from requirements.txt: gone from
both lists, `Removed iniconfig: you removed it from requirements.txt` and `Removed iniconfig from the PEP 723 header`
logged), `.add` (toolz appended: in both lists and installed, no removal line), `.stable` (nothing changed, dist removed so
the dependency flow runs: requirements.txt byte-equal, header names equal, no removal, conflict, still-lists-it or
merge-failure line). Folder B `.pyproject_keeps`: pyproject.toml lists `iniconfig`, the user deletes it from
requirements.txt; it stays in both lists and the log says `iniconfig was removed from requirements.txt but pyproject.toml
still lists it, so it stays`. Folder C `.pin_edit`: requirements.txt `six==1.16.0` edited to `six==1.17.0`: installed at
1.17.0, both lists hold `six==1.17.0`, no `Conflict for six` line (an edit is not a conflict). Folder D `.header_add`:
`toolz` added to the header by hand: in requirements.txt too and installed. Folder E `.delete_last`: requirements.txt `termcolor`,
the only package, is moved into `deps.txt` and requirements.txt becomes `-r deps.txt` (a comment-only or empty file counts as
absent and casts no vote, so a directive-only file is how a list ends up naming no package): the merged list is empty, the
write-back helper answers `SKIP:no_packages`, and the header must still lose `termcolor` (`Removed termcolor from the PEP 723
header` logged, header names empty); the next run (dist removed so the flow runs) must not report the removal again, which it
would if the records were left as they were. Every later row also requires its folder's
first run to have agreed (`baselineOk`), so a broken first run cannot hide behind a later pass. Packages removed from a
list stay installed in the environment (documented, harmless), so the rows assert the lists and the log, not an absence
from `~dependency_installed.txt`. Skips on non-Windows.

```
self.depmerge.later.baseline
self.depmerge.later.delete
self.depmerge.later.add
self.depmerge.later.stable
self.depmerge.later.pyproject_keeps
self.depmerge.later.pin_edit
self.depmerge.later.header_add
self.depmerge.later.delete_last
```

## selfapps-log-rotate NDJSON rows (selfapps_log_rotate.ps1, real lane only, gating)

Gap T7 of `docs/plan-test-suite-gaps.md` (README "Maintenance, Logging"; replaces the static harness row
`log.rotate`, which only looked for the text `Length -gt 10485760` in the batch). The script seeds real logs and
lets the real bootstrapper start through the short system-Python path (`HP_CI_SKIP_ENV=1`, the same as
`selfapps_isolation.ps1`; rotation happens before the environment is chosen, so a provider run would only add
minutes). `.over`: `~setup.log` holds 11 MiB starting with a marker line and an older `~setup.prev.log` exists; the
row passes only if the old log is now in `~setup.prev.log` (first line is the marker, at least the seed's size, the
older prev content is gone) and the new `~setup.log` is smaller than `newLogMaxBytes` and does not carry the marker.
`.under`: `~setup.log` holds 1 MiB; the row passes only if it is kept (first line is still the marker), grew with this
run's lines and no `~setup.prev.log` appeared (a rotation on every start would throw the history away). Details carry
the sizes and first lines. The seeded big logs are deleted at the end; only the boot logs and the new
`~setup.log` of the over-limit folder are uploaded. Skips on non-Windows. Limit: the bootstrapper is stopped after
the early system-Python path, so the row proves what the start does with the log, not that a later run in a long
session trims a log that grew past the limit midway.

```
self.log.rotate.over
self.log.rotate.under
```

## selfapps-longpath-near NDJSON rows (selfapps_longpath_near.ps1, real lane only, gating)

Gap T9 of `docs/plan-test-suite-gaps.md` (README REQ-003.5; replaces `self.warn.longpath`, which built a path over 260
characters that a default runner cannot enter and so reported skip in all 8 lanes). `run_setup.bat` measures its own
folder path with the closing backslash (`HP_SCRIPT_ROOT`) and warns at 200 characters or more (`*** WARNING: Script path
is N chars...` on the console, `[WARN] Script path is N chars; ...` in the setup log), then goes on. The script builds
scratch folders whose path including the closing backslash is exactly 199, 200 and 215 characters (a runner can enter
anything under 260), starts a copy of the bootstrapper in each through the short system-Python path (`HP_CI_SKIP_ENV=1`,
child only; the guard is before provider selection) with a one-line program that writes `~longpath_ran.txt`, and reads
the console and the setup log. `.below` (199): no warning anywhere, the program ran, exit 0. `.at` (200) and `.over` (215):
the warning is on the console and in the log, it names the same length the script built (so an off-by-one in either the
measurement or the threshold fails), the program ran, exit 0. Every row also requires `built` (the real length of the
scratch path equals the intended one). The scratch folders are long paths, so each run's two logs are copied to
`tests\~longpath_near_<tag>.boot.log` and `.setup.log` for the artifact upload and the folder is removed. Skips on
non-Windows.

```
self.longpath.near.below
self.longpath.near.at
self.longpath.near.over
```

## selfapps-example-apps NDJSON rows (selfapps_example_apps.ps1, real lane only, gating)

CLAUDE.md Item 74 (README REQ-001.1). `tests/fixtures/examples/` holds four small example programs a person can drop next
to `run_setup.bat`: `stdlib_single` (`solo.py`), `multifile_sibling` (`main.py` imports `helper.py`), `gui_exits` (a
tkinter window that closes itself after half a second) and `pandas_excel` (`app.py` plus `requirements.txt`, read by the
conda-full `selfapps_pandas_excel.ps1`). This script copies the first three, one at a time, into
`tests\~selftest_example_<name>` with a copy of the bootstrapper and starts it with no argument and no skip hook (only
the skip variables a leaked environment could carry are cleared, `HP_CI_LANE` stays so prompts resolve), so the whole
default path runs. A row passes only when every named detail holds: `fixtureFound` (the folder exists with the expected
number of `.py` files), `timedOut` false (a run is stopped after 25 minutes), bootstrapper exit 0, `statusState` `ok`, an
EXE in `dist`, `entrySmokeExit0` (the EXE's own verification run), `entryOk` (`Chosen entry:` names the expected file, so
`main.py` and not `helper.py` for the two-file app), `fileCountOk` (`Python file count: N`) and `outputOk` (the program's
own line is in `~run.out.txt`, the stdout of that verification run). `uvUsed`, `errorLines` and `runOutTail` are
information for a red row. A missing fixture folder fails the row with `error` naming it. The two-file row is the
realistic regression guard for Item 88 (a sibling module must not be installed as a dependency). Skips on non-Windows.

```
self.examples.stdlib_single
self.examples.multifile_sibling
self.examples.gui_exits
```

## selfapps-unlaunchable-exe NDJSON rows (selfapps_unlaunchable_exe.ps1, real lane only, gating)

CLAUDE.md Item 87 (README REQ-018.3 and REQ-018.5). A `dist\<env>.exe` that Windows cannot start (a text file, a
zero-byte file, a cut-off copy) used to hang the three bounded-launch helpers, because `Process.Start()` threw and the read
loop waited for a process that never ran. Each scenario is a real bootstrapper run of the `stdlib_single` fixture in
`tests\~selftest_unlaunch_<name>` under a 15-minute watchdog, so a hang is a red row (`timedOut`). `smoke_stub`: the hook
`HP_TEST_CORRUPT_BUILT_EXE=1` turns the freshly built EXE into a text file right before its verification run; the row
passes only when the run ends (exit 0, state `ok`), the hook fired, the console says the program `could not be started`
and gives a reason line, the stub is gone from `dist`, `~launch_failed.txt` is consumed, the program was then checked
through the interpreter (`Entry smoke exit=0`, `from-single` in `~run.out.txt`) and the log does not claim a timeout.
`fastpath_stub`: run 1 builds (EXE over 1 MB, source hash file written), the EXE is replaced with a text file, run 2 forces
the interactive fail-fast probe; the row passes only when the probe started the stub (`Launching your program now via the
cached standalone EXE`), said it could not be started with a reason, discarded and rebuilt it (a real EXE over 1 MB again,
`Entry smoke exit=0`) and never claimed the program was still running. The third helper (`~exe_hint_rerun.ps1`) has no
bootstrapper scenario, only `tests/test_unlaunchable_exe.py`. Skips on non-Windows.

```
self.unlaunchable.smoke_stub
self.unlaunchable.fastpath_stub
```

## selfapps-embed-version NDJSON rows (selfapps_embed_version.ps1, real lane only, gating)

README REQ-009 Tier 5. The embed tier always downloads the table's newest minor first; when `runtime.txt` asks for another
minor, `~embed_pyver_check.py` downloads it into `~embed_python_swap` and the batch swaps it into `~embed_python` (`rd`,
then `move`, guarded because a directory `move` onto an existing folder nests). That swap was recorded as "NOT
CI-confirmed" in `docs/agent-interconnect.md` because the older embed rows never request a version, and a failed swap is
quiet by design (the helper exits 1, the batch keeps the interpreter it has), so each scenario judges by the version the
program really runs under. Each scenario is a real bootstrapper run (conda forced to fail, offline mode on, the embed
download let through) of `import sys; print("embed-version-ok %d.%d" % sys.version_info[:2])` under a 30-minute watchdog in
`tests\~selftest_embed_ver_<name>`. The expected minors are read from `tools/embed_pyver_check.py` (`LATEST_MINOR`,
`FLOOR_MINOR`, `EMBED_PYTHON_TABLE`), so a table refresh needs no change here; the rows fail (`tableOk` false) if 3.12 ever
leaves the table or becomes the newest or oldest minor, because the swap scenario would then prove nothing. `swap`
(`runtime.txt` asks for 3.12): the log says `swapped to requested Python`, no WARN, the line in `~run.out.txt` and the
interpreter in `~embed_python` (asked directly) both say 3.12, exactly one `python3NN.dll` (the requested one) is there, no
`~embed_python_swap` is left and nothing is nested inside `~embed_python`. `floor` (`python-3.9`, below the table): the WARN
`requested Python not in embed table` names the floor minor and the program runs under it. `ceiling` (`python-3.99`): the
WARN names the newest minor, no swap download happens and the program runs under the newest minor. `range` (`pyproject.toml`
with `requires-python = ">=3.11,<3.13"`, no `runtime.txt`): the newest minor the range allows (3.12) is swapped in, not the
range's lower bound. Every scenario also requires the log line `embed fallback: a Python version request was found in this
folder.`: the first run of these rows (PR #507, run `40074772192`) showed all of them red with the program under the newest
minor and no WARN, because a chain with neither uv nor Miniconda reaches the embed tier before `~detect_python.py` has run, so
the tier saw no request; it now runs that helper under its own fresh interpreter. Skips on non-Windows and under
`HP_FORCE_CONDA_ONLY=1`.

```
self.embed.version.swap
self.embed.version.floor
self.embed.version.ceiling
self.embed.version.range
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

## selfapps-postflight-runline NDJSON rows (selfapps_postflight_runline.ps1, uv and justme-test lanes, non-gating)

CLAUDE.md Item 69 investigation (no product change): runs a real bootstrap, reads the "run it
yourself" line the post-flight briefing printed out of the console capture, and runs it as printed.
`verbatim` passes when cmd.exe (the line written to a `.cmd` file, so it parses like a pasted
Command Prompt line, not like `cmd /c "<line>"`) runs the app. `variants` is always `pass:true` and
only records, per variant, whether the app ran: quotes dropped, curly quotes, a space in the
interpreter path (junction) quoted and unquoted, and the line in Windows PowerShell with and
without a leading `&`. `interpreterKind` (`uv-venv`/`conda`) says which provider produced the line.
Not wired into `real`/`conda-full`, the only gated lanes.

```
self.postflight.runline.verbatim, self.postflight.runline.variants
```

## selfapps-pipreqs-encoding NDJSON rows (selfapps_pipreqs_encoding.ps1, real lane only, GATING)

Item 63 regression test (`docs/agent-closed-backlog.md`). One real bootstrap (skip hooks, so `main.py` never runs) over a
folder holding the maintainer's real file shape (valid UTF-8, no coding cookie, U+201C and U+201D
in raw-string regexes), an emoji file, a cp1252 file that declares its encoding, a cp1252 file with
no cookie, and an unparseable file. `PYTHONUTF8=0` is set for the sub-bootstrap because Python
3.15 (which the uv-first lanes now provision) defaults to UTF-8 mode and would hide the bug; the
`curly_quote` row's `pyEncoding` detail records what the env's interpreter really reports
(`<utf8_mode> <preferred encoding>`, `0 cp1252` expected); all three rows also require it (`encodingOk`),
so a lane that did not read with cp1252 fails loudly instead of passing without testing the bug. Each row is judged on its own concern:
`curly_quote` (the real file's import lands in `requirements.auto.txt`), `mixed_files` (emoji and
declared-cp1252 imports land, the two unreadable files are each named in a `[WARN]` line of
`~setup.log` AND of the console capture and neither module name becomes a requirement), `never_no_imports` (neither
`~pipreqs.summary.txt` nor `~setup.log` says "no imports found" for a folder that has imports).
Skips with `skip=true, reason=non-windows-host` off Windows. Expected red on the commit that adds
it (pipreqs 0.4.13 reads with the locale encoding and aborts on the first undecodable file) and
green once the pre-check and staged UTF-8 copy land.

```
self.pipreqs.encoding.curly_quote, self.pipreqs.encoding.mixed_files, self.pipreqs.encoding.never_no_imports
```

## selfapps-pipreqs-output NDJSON rows (selfapps_pipreqs_output.ps1, real lane only, GATING)

Item 63 follow-up regression test (PR #478 review; `docs/agent-closed-backlog.md`). Three real
bootstraps (skip hooks). Bootstraps 1 and 2 use a folder with `good.py` (imports colorama), a cp1252
file with no coding cookie (forces the UTF-8 copy scan) and `main.py`; their rows also require
proof that the copy was scanned (the summary says `scanned a UTF-8 copy`, or for a scan that failed
the setup log says `scanning a UTF-8 copy of the project`), so a run that scanned in place cannot
pass without testing anything.
Bootstrap 1 seeds a READ-ONLY old `requirements.auto.txt` listing `six` and a sentinel file in the
fixed temp folder name `%RUNNER_TEMP%\pipreqs_stage` (standing in for another project's scan):
`readonly_replaced` (the file now lists colorama and no longer lists six), `temp_isolated` (the
sentinel survives and the scan leaves no `pipreqs_stage_*` folder of its own behind). Bootstrap 2
holds the old file open from the test process (`FileShare.Read`, so it can be read but neither
deleted nor overwritten): `locked_named` (summary `Phase: failed`, a console `[WARN]` line names
`requirements.auto.txt`, nothing says "no imports found", the bootstrap carries on). Bootstrap 3
(clean UTF-8 folder, so the scan runs in place) holds the old file open the same way and sets
`REQUESTS_CA_BUNDLE` to a file that does not exist, which makes pipreqs crash on its PyPI lookup
in every scan (uv ignores the variable): `locked_crash` (`crashSeen` proves the crash happened, from the traceback in `~pipreqs_direct.log`,
then neither `~dependency_resolved.txt` nor `requirements.txt` lists the old `six`, the summary says
`Phase: failed`, and a console `[WARN]` names `requirements.auto.txt`). Skips with
`skip=true, reason=non-windows-host` off Windows. Expected red on the commit that adds it (the
copy-back failure was only a log line and the old file was accepted; the temp folder name was
fixed; a delete that failed was not remembered, so a crashed scan promoted the old file) and green
once the scan clears the old output first, fails loudly on a copy-back failure, uses a per-run temp
folder name and treats a surviving old file as untrusted.

```
self.pipreqs.output.readonly_replaced, self.pipreqs.output.temp_isolated, self.pipreqs.output.locked_named, self.pipreqs.output.locked_crash
```

## selfapps-entryarg NDJSON rows (selfapps_entryarg.ps1, real lane only, GATING)

CLAUDE.md Item 67 regression test (`docs/plan-field-report-2026-10.md`; README REQ-002, REQ-026). One
real bootstrap builds a two-file app (`main.py` and `entry.py`, both exit 2 when they receive any
argument), then five quick runs drive the cached-EXE path with bad first arguments. Every run's
checks read only that run's output: the console capture, and the bytes the run appended to
`~setup.log` (which is not rotated per run). `noext` (run 1, `run_setup.bat entry`: `entry.py` is
chosen over `main.py`, the `.py` is appended and logged), `csv` (run 2, an existing `data.csv`:
non-zero exit, `Usage: run_setup.bat your_script.py` on the console, status `error`, EXE byte-for-byte
and timestamp unchanged, no `Fast path` or `discarding cached EXE` line), `missing` (run 3, `arg1
arg2`, the 2026-08-31 command: same checks, and the good EXE is never run with the wrong arguments or
discarded), `wildcard` (run 4, `*`: a wildcard matches every file so it must be rejected, same checks),
`directory` (a folder named `folder.py` exists for two runs: `folder.py` and `folder` must each be rejected with the usage line, status `error`, EXE untouched, because `if exist` is true for a folder), `stops_release_lock` (run 5 is a file from another folder, the REQ-011 stop; run 6 is `entry` again
and must see no REQ-024 lock message and reuse the EXE). Skips with `skip=true,
reason=non-windows-host` off Windows. Expected red on the commit that adds it (the old code takes a
missing first argument as no argument and an existing non-Python file as the entry, launches the
cached EXE with the wrong arguments, and leaves the lock behind after the REQ-011 stop) and green once
the first argument is validated before the fast path and every early stop releases the lock.

```
self.entryarg.noext, self.entryarg.csv, self.entryarg.missing, self.entryarg.wildcard, self.entryarg.directory, self.entryarg.stops_release_lock
```

## selfapps-honest-wording NDJSON rows (selfapps_honest_wording.ps1, real lane only, GATING)

CLAUDE.md Item 68 regression test (`docs/plan-field-report-2026-10.md`; README REQ-005, REQ-005.5, REQ-007).
One tiny standard-library app, three real runs in one folder; each run's checks read only the bytes
that run appended to `~setup.log` plus its console capture. `dep_source_warn_shown` (run 1, no
`requirements.txt`, pipreqs on: the console carries `Dependencies were auto-detected via pipreqs` and
`~dependency_source.txt` reads `dependency_source=pipreqs`; before the fix the warning's gate tested a
variable that is initialized to `unknown`, so neither happened), `rebuild_notice` (runs 2 and 3 edit
`main.py`, so the cached EXE is stale and is rebuilt: the log must say `Fast path: not reusing`, the
EXE must really change and print the new output, and run 1, with no EXE yet, must not print the line),
`diff_placeholder` (run 2 has neither requirements file, run 3 has `requirements.txt` only, pipreqs
skipped in both: `~pipreqs.diff.txt` names the missing file instead of "requirements files not both
present"). Skips with `skip=true, reason=non-windows-host` off Windows. Expected red on the commit
that adds it. The other Item 68 fixes are covered elsewhere: `self.failfast.probe.seconds` (the probe
line states its window in seconds, in `selfapps_failfast_probe.ps1`), `batch.wording.nuitka_duration`
(static, `tests/harness.ps1`: the Nuitka fallback and optimized-build messages say the build can take a
long time and point at `~setup.log`), `batch.wording.optbuild_rerun` (static: the optimized-build prompt
says, in an echo line before the question, that accepting starts the program once more for up to 30
seconds; README REQ-018.2), `batch.optbuild.noninteractive_default` (static: under `HP_CI_LANE`,
`NOINPUT` and `HP_NONINTERACTIVE` the answer resolves to no without reaching `set /p`; the prompt text is
still echoed by design, see the CI-safe gate pattern, but nothing is asked or run) and
`batch.wording.interpreter_prompt_note` (static: both panels that print the interpreter run command add
that a bare interpreter opens a Python prompt and that pip is run as `-m pip`). The decline scenario of
`selfapps_optimized_build.ps1` also counts launches: a fixture that appends to `~launches.txt` on every
start must have been started exactly once when the offer is declined.

```
self.wording.dep_source_warn_shown, self.wording.rebuild_notice, self.wording.diff_placeholder
```

## selfapps-warnfix-noise NDJSON rows (selfapps_warnfix_noise.ps1, real and conda-full lanes, GATING)

CLAUDE.md Item 64 (slice 1) regression test, README REQ-005.9. One real bootstrap (no skip hooks) of
a program with no third-party imports whose PyInstaller warn file still lists noise: `from
multiprocessing import Pool, freeze_support` gives `missing module named multiprocessing.Pool`,
`import pkgutil` gives PyInstaller's own `pyimod02_importers`, `import platform` gives `java` and
`vms_lib`. `self.warnfix.noise.stdlib` first proves its precondition (`warnHasMultiprocessing` and
`warnHasPyimod`: the copied `~warnfile.txt` really lists them, so a PyInstaller that stops printing
them cannot make the row pass vacuously), then requires no `Attempting to install:` line at all
(`attempted` lists every name tried), no `Repair failed:` line, no `[REPAIR] missing modules
detected` block, no `REQ-009: cascade candidate detected`, and an EXE that was built and ran
(`exeExit` 0, token file written). Skips with `skip=true, reason=non-windows-host` off Windows.
Expected red on the commit that adds it (`tools/parse_warn.py` forwards every top-level name to
warnfix, so multiprocessing, pyimod02_importers, java and vms_lib are all tried and the failed
repair raises the cascade prompt) and green once stdlib, PyInstaller-internal and other-interpreter
names are filtered.

```
self.warnfix.noise.stdlib
```

## selfapps-warnfix-library NDJSON rows (selfapps_warnfix_library.ps1, real lane only, GATING)

CLAUDE.md Item 64 slice 2 regression test, README REQ-005.9. One real bootstrap (no skip hooks) of a
program whose only third-party import is pandas, with no `requirements.txt`. PyInstaller's pandas hook
pulls the whole package in, so the warn file lists dozens of modules that pandas imports lazily or
under a guard (pyarrow, numba, numexpr, sqlalchemy, tables, matplotlib, scipy, the Excel readers,
qtpy and PyQt4 for the clipboard...). `self.warnfix.noise.library` first proves its precondition
(`warnHasPandasImports`: the copied `~warnfile.txt` really has `missing module named ... imported by
...pandas.` lines, so a PyInstaller that stops printing them cannot make the row pass vacuously;
`pandasWarnLineCount` is the number of such lines), then requires no `Attempting to install:` line at
all (`attempted` lists every name tried), no `Repair failed:` line, no `[REPAIR] missing modules
detected` block, no `REQ-009: cascade candidate detected`, and an EXE that was built and ran
(`exeExit` 0, token file written). Skips with `skip=true, reason=non-windows-host` off Windows.
Real lane only on purpose: the filter in `tools/parse_warn.py` is provider-independent, the stdlib row
above already covers both repair-install paths, and a pandas build under conda-forge would lengthen
the slowest lane. Expected red on the commit that adds it (the parser sends every name that no
`SKIP`/stdlib rule catches, library backends included, to warnfix) and green once a missing module
counts only when the user's own code imports it.

```
self.warnfix.noise.library
```

## selfapps-realapp-pandas-excel NDJSON rows (selfapps_realapp_pandas_excel.ps1, real lane only, GATING)

CLAUDE.md Item 75 (a) and (b). One folder, three bootstraps, no skip hook, so the whole default path runs (pipreqs
scan, pandas heuristics, autopep723 merge, uv install, PEP 723 write-back, PyInstaller build, EXE verification). The
app is `main.py` plus a sibling module and a sibling package whose names no PyPI project uses (`pvw_realapp_sheetio`,
`pvw_realapp_report`); it writes an `.xlsx` next to the EXE, reads it back with pandas and writes
`~realapp_token.txt` (`realapp-ok total=32 rows=3`). No `requirements.txt`, `pyproject.toml` or PEP 723 header exists
at the start. Run 1 is the first run, run 2 changes nothing (the token file is deleted first, so a pass proves the EXE
ran again), run 3 appends `termcolor` to `requirements.txt`. Every row records its sub-checks by name in `details`, so
a red row says which one failed. `.first_run`: exit 0, status `ok`, EXE built, the verification run exited 0 (the last
`Entry smoke exit=`), token text exact, `.xlsx` in `dist\`. `.deps_discovered`: pandas, openpyxl and xlsxwriter in
`~dependency_installed.txt`, `[HEURISTIC] pandas->openpyxl` logged, recorded source `pipreqs`, no `[REPAIR] missing
modules detected` block and no `Attempting to install:` line (discovery was complete). `.local_modules`: precondition
that autopep723 ran (`~requirements.autopep.txt` exists), listed both local names (`autopepReportedLocal`) and its merge
logged `skipped local:` (`skippedLocalLogged`), so a run where the filter never fired cannot pass; then neither local name in
`requirements.txt` nor in the installed set and no `uv pip install -r requirements.txt failed` line (one unresolvable
name fails the whole atomic install). `.fastpath_rerun`:
`Fast path: reusing` logged, no `Fast path: not reusing`, same EXE timestamp, token rewritten, no `UV_USED=1` (no
reinstall) and no pipreqs command. `.edit_rerun`: `Fast path: not reusing` logged, EXE newer than after run 2, token
rewritten, the run recorded a source, and `termcolor` is installed, still in `requirements.txt` and written into the PEP 723
header run 1 left in `main.py` (Item 89: the lists are merged and a change since the last run is kept; before it the
header outranked the edit and the row only asserted that the run agreed with the source it named). Skips with
`skip=true, reason=non-windows-host` off Windows. Real lane only on purpose: it needs PyPI like every real-lane
scenario and adds two pandas builds, so conda-full (slowest lane) is not given it.

```
self.realapp.first_run
self.realapp.deps_discovered
self.realapp.local_modules
self.realapp.fastpath_rerun
self.realapp.edit_rerun
```

## selfapps-runtime-modnotfound NDJSON rows (selfapps_runtime_modnotfound.ps1, real lane only, GATING)

CLAUDE.md Item 65 slice 1 regression test, README REQ-018. One real bootstrap of a fixture that
stands in for a GUI callback: it catches the `ImportError` for `xlsxwriter` itself (module name joined
at run time, no `requirements.txt`, so nothing installs it), prints the traceback to stderr and exits 0.
`self.runtime.modnotfound` first proves its precondition (`symptomReproduced`: `Entry smoke exit=0`
in `~setup.log` AND `ModuleNotFoundError: No module named 'xlsxwriter'` in `~run.err.txt`), then
requires a console `[WARN]` line that names `xlsxwriter` as not installed (`consoleLine`,
`namedModules` must list only that module), the bootstrapper's own `self.runtime.module_missing` row in
the private `HP_NDJSON` file the test points the run at (`rowIds`, `rowModules`), and
`~bootstrap.status.json` state `ok`. Skips with `skip=true, reason=non-windows-host` off Windows.
Real lane only on purpose: the scan is provider-independent and the fixture needs no third-party
package. Expected red on the commit that adds it (nothing reads the stderr of a run that exits 0) and
green once the scan exists.

A second scenario in the same script (`self.runtime.modnotfound.pyproject`, CodeRabbit finding on PR #487)
bootstraps the same fixture with a `pyproject.toml` that lists one dependency, so `DEP_SOURCE=pyproject`.
Setup copies those dependencies over `requirements.txt` on every run, so advice to edit `requirements.txt`
would be lost on the next run. The row proves its precondition (`DEP_SOURCE=pyproject` in `~setup.log`, run
exits 0, traceback in `~run.err.txt`) and requires both advice lines (the second `[WARN]` line and the closing
reminder, `adviceLines`) to name `pyproject.toml` and neither to name `requirements.txt`. The first row now
requires exactly one report per module (console and row), not at least one. Expected red on the commit that
adds the pyproject scenario and green once the advice names the active source.

```
self.runtime.modnotfound
self.runtime.modnotfound.pyproject
```

## selfapps-runtime-install NDJSON rows (selfapps_runtime_install.ps1, real lane only, GATING)

CLAUDE.md Item 65 slice 2 regression test, README REQ-018. The same fixture as above, bootstrapped three
times with `HP_TEST_RTM_ANSWER` set. `self.runtime.install.accept` (answer Y) requires the first run's report, the
echoed prompt, `Runtime install: installed xlsxwriter`, `xlsxwriter` importable from `.uv_env`, a
`xlsxwriter` line in `requirements.txt`, `[REPAIR] rebuild complete after runtime install`, a second
`Entry smoke exit=` line, a clean check run (`~run.err.txt` without `No module named`, `~run.out.txt` with
`runtime app ok`, which only happens when the rebuild passed `--hidden-import`), the bootstrapper's
`self.runtime.install` row with state `verified`, site `exe`, packages `xlsxwriter`, and status `ok`.
`self.runtime.install.decline` (answer N) requires the report and prompt, `Runtime install: declined`,
no `xlsxwriter` in the environment or in `requirements.txt`, exactly one `Entry smoke exit=` line, the
end-of-run reminder still printed, row state `declined`, and status `ok`.
`self.runtime.install.pyproject` (answer Y, a `pyproject.toml` with `dependencies = ["six"]`) requires
`DEP_SOURCE=pyproject`, a prompt that says the file is not edited, the install, a verified clean check run,
`pyproject.toml` byte-identical afterwards, no `xlsxwriter` in `requirements.txt`, the log line `did not edit
the dependencies in pyproject.toml`, and row `depSource` `pyproject`: requirements.txt is overwritten from
pyproject on every run, so an appended line would be lost (CodeRabbit, PR #487). All three skip with
`skip=true, reason=non-windows-host` off Windows. Expected red on the commit that adds them (no prompt
exists) and green once `:runtime_install_offer` exists.

```
self.runtime.install.accept
self.runtime.install.decline
self.runtime.install.pyproject
```

## selfapps-pyvisa-subfolder NDJSON rows (selfapps_pyvisa_subfolder.ps1, real and conda-full lanes, GATING)

CLAUDE.md Item 78 slice 2 (README REQ-008). An `import visa` that sits only below a subfolder (an archived
older program) must not start a 30 to 45 minute NI-VISA driver install without asking, and the log always
names the file that triggered the install branch. Four real runs, each in its own folder (a second run in one
folder would take the cached-EXE fast path and never reach the VISA step); the gate sits after the
`HP_SKIP_NIVISA` and already-installed checks, so a runner without NI-VISA reaches it, and `accepted` really
enters the install branch like `selfapps_pyvisa.ps1` does (any ending counts). `declined` (CI lane auto-decline: the
`found in: archive\old_tool.py (subfolder)` line in `~setup.log`, the prompt echoed on the console,
`[VISA] skipped (subfolder_only)`, no download, no installer file; run with a stale `HP_VISA_DECISION=Y` inherited from the
caller, which must not stand in for the answer), `accepted` (`HP_TEST_VISA_ANSWER=Y`: the
accepted line, then a `[VISA]` install-branch line, no `subfolder_only`; runs LAST because it may really install
NI-VISA, after which a later scenario would see `[VISA] present`), `topfolder` (the import next to
`run_setup.bat` with `HP_SKIP_NIVISA=1`: logged as `(top folder)`, no prompt, `skipped (disabled)`), `timeout` (`HP_TEST_FORCE_INTERACTIVE_VISA=1`
reaches the timed `choice` prompt, shrunk to 2 seconds, nobody answers, default no). Skips with `skip=true,
reason=non-windows-host` off Windows. Expected red on the commit that adds it (the scanner printed only 0 or
1 and the batch never asked). The unit side is `tests/test_detect_visa.py` (the 0/1/2 contract, the three-path
cap, the character set of the logged path).

```
self.nivisa.subfolder.declined, self.nivisa.subfolder.accepted, self.nivisa.topfolder.noprompt, self.nivisa.subfolder.timeout
```

## Runtime missing-module row (run_setup.bat, written only when HP_NDJSON is defined)

CLAUDE.md Item 65 slice 1. `:report_runtime_missing_module` writes `self.runtime.module_missing`
(`pass` always true, it is a finding not a verdict) once per module per bootstrap run, with
`details.module` (a plain identifier), `details.site` (`exe`, `interpreter`, `fastpath` or `checkpoint`)
and `details.provider`. No lane puts it in a shared artifact: `selfapps_runtime_modnotfound.ps1` points
`HP_NDJSON` at a private file and reports what it found in its own row `self.runtime.modnotfound`
(`rowIds`, `rowModules`).

```
self.runtime.module_missing
```

## Runtime install row (run_setup.bat, written only when HP_NDJSON is defined)

CLAUDE.md Item 65 slice 2. `:rti_row` writes `self.runtime.install` once per bootstrap run when the offer
reaches a state: `details.state` is `declined`, `not_offered`, `install_failed`, `rebuild_failed`,
`verified`, `still_missing` or `not_verified`; `details.site` is `exe` or `interpreter`; `details.provider`
is `HP_ENV_MODE`; `details.depSource` is `DEP_SOURCE` (what decides whether `requirements.txt` is edited);
`details.packages` lists what was installed (empty when nothing was). `pass` is always true. As with
`self.runtime.module_missing`, no lane puts it in a shared artifact: `selfapps_runtime_install.ps1` reads it
from a private file and judges it in its own three rows.

```
self.runtime.install
```

## selfapps-lastchance NDJSON rows (selfapps_lastchance.ps1, real lane GATING, uv lane non-gating)

CLAUDE.md Item 82 slice 1 regression test, README REQ-018 and REQ-009. Each scenario is one real bootstrap of a
standard-library fixture, with the answer to the offer supplied by `HP_TEST_LASTCHANCE_ANSWER`, the automated-run
guards, or a real `set /p` read (`HP_TEST_FORCE_INTERACTIVE_LASTCHANCE`). Each row first proves its precondition
(`Entry smoke exit=3` and the fixture's own stderr), and every check on the prompt's text looks only at console text
after the heading, because the EXE verification run live-tees its own stderr to the console before the offer.
`LASTCHANCE_GROUP` picks the group (`real`, `uv`, unset runs both). Real lane (gating, nothing downloaded beyond a
normal uv bootstrap): `self.lastchance.worked` (answer W: the prompt, `Last chance: you said it worked`, no cascade,
EXE kept, row state `worked`, `passType` `user_confirmed`, site `exe`); `self.lastchance.errline` (no answer in an
automated run resolves to `automated` with no wait, and the error line `Error: a<b>c&d|e%PATH%^f "q" end` is shown
intact on the console and in the setup log, with the same non-tilde top-level names as the `worked` run and no
file named after the operators); `self.lastchance.enter` (interpreter site via `HP_SKIP_EXE_SMOKERUN`, a bare Enter
at the real `set /p` means `neither`, and `HP_TEST_FORCE_EMIT_FAIL=HP_LAST_ERROR_LINE` only drops the last-line part:
row `hasLine` false); `self.lastchance.checkpoint_ok` (the accepted checkpoint ran the interpreter and it exited 0:
no prompt, row state `not_offered`, reason `checkpoint_ok`); `self.lastchance.exit0` (no prompt, no row).
Uv lane (non-gating because a force-stopped silent EXE and a mid-run Miniconda download can fail for transient
reasons): `self.lastchance.timeout` (exit `-1` is a window app, no prompt even with an answer supplied);
`self.lastchance.cascade` (answer C: `cascading provider uv to conda`, the program passes on conda, one prompt, one
row `cascade`); `self.lastchance.cascade_again` (the program fails on conda too: still one prompt, and the conda
tier writes row `not_offered` with reason `provider`). All skip with `skip=true, reason=non-windows-host` off
Windows. Expected red on the commit that adds them (no offer exists) and green once `:last_chance_offer` exists.

Item 82 slice 2 adds four more uv-lane rows for the "Did it open and work?" question of a window app on the conda
tier reached through the cascade. Each scenario is one fixture that fails on uv (so the slice 1 prompt is raised and
answered `C` through `HP_TEST_LASTCHANCE_ANSWER`), then on conda stays silent until the runner force-stops it
(`HP_SMOKERUN_KILL_MS=6000`); the answer comes from `HP_TEST_WINDOWOK_ANSWER`, the automated-run guards, or a real
`set /p` (`HP_TEST_FORCE_INTERACTIVE_WINDOWOK`). `self.lastchance.window_yes` (answer Y: the question is shown once,
log `Last chance: you said the window opened and worked`, second offer row `window_confirmed` with `passType`
`user_confirmed`, provider `conda`, `exitCode` `-1`); `self.lastchance.window_enter` (a bare Enter at the real prompt:
`window_declined`, no pass type); `self.lastchance.window_auto` (no override in an automated run: the question text is
echoed, `window_automated`, no pass type, no wait); `self.lastchance.window_selfexit` (the conda-tier program exits by
itself with `-1`, the same code a force-stop produces, after the uv tier left a stale `~smokerun_killed.txt`: the
question is absent even with a Y supplied, only the slice 1 row exists, and the marker is gone). The existing
`timeout`, `cascade` and `cascade_again` rows also assert the question never shows (`windowPrompt` false). The
`selfexit` row is a negative control, so on the red run it passes for the wrong reason; its precondition fields
(`Entry smoke exit=-1` on conda, `stale marker written`) are what show the old `-1` gate could not tell the two cases
apart.

```
self.lastchance.worked
self.lastchance.errline
self.lastchance.enter
self.lastchance.checkpoint_ok
self.lastchance.exit0
self.lastchance.timeout
self.lastchance.cascade
self.lastchance.cascade_again
self.lastchance.window_yes
self.lastchance.window_enter
self.lastchance.window_auto
self.lastchance.window_selfexit
```

## selfapps-provider-memory NDJSON rows (selfapps_provider_memory.ps1, real lane GATING, uv lane non-gating)

CLAUDE.md Item 66 regression test, README REQ-009; decided 2026-10-17 (Q11, option A). Each scenario is one real
bootstrap (or two, in the same folder) of a standard-library fixture; each row asserts the reason it passes (log
lines, files, status), not only the exit code. `PROVIDER_GROUP` picks the group (`real`, `uv`, unset runs both).
Real lane (gating, nothing downloaded beyond a normal uv bootstrap): `self.provider.unset` (no switch and no file:
the normal uv run, nothing about memory or the switch in any output, and a plain uv pass writes no file);
`self.provider.invalid` (`Conda`, `miniconda` and a hostile string stop the run with one `[ERROR]` before any uv work,
and the value is never echoed or turned into a file); `self.provider.miniconda_gone` (the file names conda but
`PUBLIC` points where no Miniconda is: cleared with a visible line, normal order); `self.provider.unreadable` (a
file the bootstrapper cannot read is ignored with a visible warning and kept); `self.provider.fastpath` (a valid
cached EXE is reused before provider selection, so `PVW_PROVIDER=conda` changes nothing for that run). Uv lane
(non-gating because they download Miniconda and solve a conda environment, which can fail for transient reasons):
`self.provider.forced` (switch with Miniconda not yet installed in a fresh `PUBLIC`, an existing `.uv_env` and an
exact pin the bootstrapper itself wrote earlier: Miniconda acquired, uv venv not reused, the stale pin ignored,
nothing written); `self.provider.remember` (run 1 reaches conda through the cascade and writes the file, run 2 after
editing `requirements.txt` and the program starts at conda, says so and how to reset, skips uv, keeps the file);
`self.provider.forced_stop` (a Python version conda cannot give: stops at conda with a hint, no other provider).
All skip with `skip=true, reason=non-windows-host` off Windows. `self.lastchance.window_yes`, `.window_enter` and
`.window_auto` also read the file: only an explicit yes on the conda tier records `user_confirmed`. Expected red on the
commit that adds them (no memory and no switch exist) and green once they do.

```
self.provider.unset
self.provider.invalid
self.provider.miniconda_gone
self.provider.unreadable
self.provider.fastpath
self.provider.forced
self.provider.remember
self.provider.forced_stop
```

## Last-chance offer row (run_setup.bat, written only when HP_NDJSON is defined)

CLAUDE.md Item 82 slice 1. `:lc_row` writes `self.lastchance.offer` once per call of `:last_chance_offer` that
reached a state, which is only after a non-zero verification exit on a fresh build, and an exit of `-1` counts only
when the runner really stopped a silent process on the conda tier (a program that exits by itself with `-1`
writes nothing): `details.state` is
`worked`, `cascade`, `neither`, `automated` (a guard answered) or `not_offered`; slice 2 adds `window_confirmed`,
`window_declined` and `window_automated` for the conda-tier window question (written only when the runner really
stopped a silent process, with `exitCode` `-1`); `details.reason` is set for
`not_offered` (`provider`, `cascade_approved`, `checkpoint_ok`, `runtime_install`); `details.site` is `exe` or
`interpreter`; `details.provider` is `HP_ENV_MODE`; `details.exitCode` is the failing exit; `details.passType` is
`user_confirmed` for `worked` (the Item 66 record will carry it); `details.hasLine` says whether an error line was
shown. `pass` is always true. No lane puts it in a shared artifact: `selfapps_lastchance.ps1` reads it from a private
file and judges it in its own rows.

```
self.lastchance.offer
```

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
