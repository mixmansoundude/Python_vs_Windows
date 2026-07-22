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
self.exe.build, self.exe.run, self.exe.build.xfail,
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
self.embed.fallback.decline, self.embed.fallback.real
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
self.warn.onedrive, self.warn.longpath, self.warn.path_negative, self.warn.sysdir,
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
self.venv.fallback, self.venv.canary_fail, self.venv.nopip_retry, self.entry.override,
self.embed.fallback.decline, self.embed.fallback.real
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

## selfapps-pyinstaller-fail NDJSON rows (selfapps_pyinstaller_fail.ps1, real/conda-full lanes)

Two scenarios (`PYI_FAIL_SCENARIO` env var: `execfail` / `output_vanish`), both emitting the
same row id. XFAIL-style, mirroring `selfapps_exefail.ps1`'s sibling pattern but testing the
PyInstaller BUILD step failing outright (not a successfully-built EXE crashing at runtime).
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

**NDJSON files and who owns them:**
- `tests/~test-results.ndjson` -- written by every `selfapps_*.ps1` test script during the
  CI run. The selfapps scripts APPEND rows to this file. The CI "Verdict from NDJSON" step
  reads it immediately after upload. Later, `harness.ps1` DELETES it and REWRITES it with
  harness static check rows. The final artifact content is harness rows only.
- `ci_test_results.ndjson` -- parallel aggregator written by selfapps scripts; used as
  fallback by the "Verdict from NDJSON" step if `tests/~test-results.ndjson` is empty/missing.
  `harness.ps1` does NOT read this file.
