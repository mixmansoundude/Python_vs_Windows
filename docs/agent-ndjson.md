# NDJSON Surface -- Python_vs_Windows

This file is loaded automatically by Claude Code via the `@docs/agent-ndjson.md`
import in CLAUDE.md. It lists all known NDJSON rows by lane and test source.

The diagnostics site is the authoritative source of truth for live row counts:
https://mixmansoundude.github.io/Python_vs_Windows/

**AGENT DIRECTIVE: When new NDJSON rows are added (new selfapps files, new harness checks),
update this file in the same commit. Row IDs listed here act as a registry to catch
accidental removal or unexpected additions.**

---

## CI-artifacts NDJSON (selfapps tests, conda-full lane)

```
self.harness.started, self.bootstrap.state, self.empty_repo.msg,
self.empty_repo.no_spurious_warn,
self.env.smoke.conda, self.env.smoke.run, self.env.smoke.uv, envsmoke.run,
self.uv.managed.interpreter,
self.exe.build, self.exe.run,
self.exe.smokerun.xfail, self.exe.smokerun.exedata.xfail, self.exe.smokerun.exedyn.xfail,
self.exe.fastpath.graceful, self.skiphooks.combined,
self.fastpath,
self.failfast.probe.fastfail, self.failfast.probe.alive, self.failfast.probe,
self.checkpoint.accept, self.checkpoint.decline,
self.entry.entry1, self.entry.entryA, self.entry.entryB, self.entry.entryC, self.entry.entryD,
self.entry.helper.invoke.absent, self.entry.results, self.entry.spaced-path, self.entry.picker,
self.entry.req011.crossdir, self.entry.req011.sameDir, self.isolation.req010.pythonpath,
entry.single.direct, entry.expected, helper.invoke,
self.envname.hyphen, self.size.tripwire,
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
self.exe.hidden_import,
self.preflight.syntax,
self.cascade.detect, self.cascade.consent,
self.cascade.exec (uv lane only -- selfapps_cascade.ps1; non-gating),
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
self.venv.fallback, self.venv.canary_fail, self.venv.nopip_retry, self.entry.override
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
self.cache.corrupted, self.cache.bootstrap.failed,
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
self.bootstrap.state, self.empty_repo.msg, self.empty_repo.no_spurious_warn,
self.harness.started,
self.stub.fastpath, self.stub.rebuild, self.stub.state_skip,
self.stub.conda_retry, self.stub.conda_create_retry, self.stub.conda_perpkg, self.stub.pip_warn,
self.stub.pipreqs_version_fail,
self.stub.lock_no_leak, self.stub.lock_held_decline, self.stub.lock_stale_evict,
self.stub.low_disk_warn,
self.pipreqs.warn.gated,
self.dep.diff.trace,
self.warn.onedrive, self.warn.longpath, self.warn.path_negative,
self.guardrail.g1, self.guardrail.g2, self.guardrail.g3,
self.pep723.valid, self.pep723.malformed, self.pep723.pyproject.override,
self.pyproject.malformed,
self.corrupt.conda.detect,
self.corrupt.conda.heal.decline,
self.corrupt.conda.heal.accept,
self.corrupt.uv.detect
```

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
self.venv.fallback, self.venv.canary_fail, self.venv.nopip_retry, self.entry.override
```

---

## Key facts for debugging missing rows

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

**NDJSON files and who owns them:**
- `tests/~test-results.ndjson` -- written by every `selfapps_*.ps1` test script during the
  CI run. The selfapps scripts APPEND rows to this file. The CI "Verdict from NDJSON" step
  reads it immediately after upload. Later, `harness.ps1` DELETES it and REWRITES it with
  harness static check rows. The final artifact content is harness rows only.
- `ci_test_results.ndjson` -- parallel aggregator written by selfapps scripts; used as
  fallback by the "Verdict from NDJSON" step if `tests/~test-results.ndjson` is empty/missing.
  `harness.ps1` does NOT read this file.
