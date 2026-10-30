# Plan: test suite gap map (the finish line for the test-suite phase)

Filed 2026-10-11. Planning only: no test, tool, workflow or `run_setup.bat` line changes here. Every
claim below was checked against the repo at `b8732c6` (main after PR #485) and against the rows of one
finished CI run read from its artifacts (run `38141042628`, all 8 lanes). Claims I inferred instead of
reading are marked **(to verify)**. Rules for every slice below: AGENTS.md's Iteration Contract (one
loop, one change set) and its "Test-first" section; the CI-first policy in
`docs/plan-field-report-2026-10.md`; Item 35's soak discipline for anything that could turn a lane red.

This file builds on, and does not replace, Item 35 (promote non-gating lanes and rows) and Item 75
(real-app end-to-end scenarios) in CLAUDE.md. No other whole-suite gap list existed; the README's
per-requirement "TESTED:" notes and `req_coverage.json` on the diagnostics site were the only partial
ones, and the second is a tag floor (see T5).

---

## Bottom line

**How complete is it?** Large and strong on the golden path, not yet complete by AGENTS.md's own test.
One CI run produces 307 distinct row ids, from 62 `selfapps_*.ps1` scripts (one, `selfapps_conda_update.ps1`,
is not wired into CI), 39 `tests/test_*.py` files (36 run in CI), 44 static `batch.*` harness rows and
the harness's other static checks. 259 of those ids appear in at least one gating lane (`real`, `conda-full`), 183 appear
in all 8 lanes. Of the 25 requirement numbers the README mentions, 22 are tagged on at least one row.

AGENTS.md has no numeric finish line. Its Iteration Contract says what "not done" means: an unmet
requirement, an implemented behavior with no test, or a green run that hides a false pass. Its Branch
coverage policy adds that every branch needs a test that would notice the branch being deleted. Against
those, the suite falls short on **six axes** (ranked list further down):

1. **Rows that cannot block a merge** (Item 35). 48 row ids appear only in non-gating lanes, among them
   the whole uv-only feature set (PEP 723 write-back, cascade execution, optimized build, Tier A). The
   aggregate gate was advisory when this plan was written (the 3 known red rows blocked nothing); the baseline reds
   are fixed and the gate has been real since Item 35 C6.
2. **Launch behavior is unobserved.** Nothing counts how many times the user's program runs (REQ-018),
   nothing checks that launch arguments arrive (REQ-026, which the maintainer used for real on
   2026-08-31), and the skip hooks are tested only in combination (REQ-012).
3. **No dependency-source matrix.** REQ-005.1's five-way order is tested pairwise at best, and no row
   asserts which source won plus what actually got installed.
4. **False and vacuous passes.** `batch.req005.warn_gate` passes by finding dead code,
   `self.pipreqs.warn.gated` cannot fail, `log.rotate` and `tilde.naming` are regex presence checks,
   `self.warn.longpath` is skipped in all 8 lanes.
5. **Isolation and path hazards.** REQ-010 asserts `PYTHONPATH` only; no non-ASCII folder, UNC path, or
   long path is ever run.
6. **The traceability and flag-hygiene metrics are not mechanical.** README has no section for
   REQ-024/025, 128 of 307 rows carry no `req` tag, and REQ-019 (flags are scaffolding) has no row at
   all.

### Ranked gaps (details in "The gaps")

| Rank | Id | Gap | Field evidence | Smallest test | Lane to start in |
|---|---|---|---|---|---|
| 0 | (Item 35) | uv-only rows and the aggregate gate cannot block; 3 reds hidden (done: reds fixed, gate real since C6) | uv-first is the default path | fix the 2 uv red rows, then flip the gate | existing |
| 1 | T1 | launch ledger: REQ-026 args, REQ-018 run count, REQ-012 flags, REQ-010 decoy | args used 2026-08-31; hardware programs | one stub that appends one line per launch; 4 bootstraps | uv, then real |
| 2 | T2 | dependency-source matrix and lineage (REQ-005.1/.4/.6) | requirements.txt "not obeyed" reports | 7 cells, assert `dependency_source=` and the installed set | uv, then real |
| 3 | T3 | "no litter" allow-list for the app folder | Item 76 was found by eye | list non-tilde files after a default run | real |
| 4 | T4 | uv-lane red rows (cascade, venv repair) | default path after a failed repair | owned by Item 35; evidence below | existing |
| 5 | T5 | requirement traceability ratchet (orphan REQ, tags, README stubs) | none (process) | one pytest, zero Windows cost | pytest, all lanes |
| 6 | T6 | flag-inventory ratchet (REQ-019, dead hooks) | `HP_ALLOW_SYSTEM_FALLBACK` precedent | one pytest | pytest, all lanes |
| 7 | T7 | replace vacuous rows | Item 68 dead WARN | behavioral replacements | with T2/T3 |
| 8 | T8 | non-ASCII folder name | none yet; common on real machines | 1 bootstrap | uv |
| 9 | T9 | UNC and long path | `self.warn.longpath` skipped 8/8 | probe row, then a hook | uv |
| 10 | T10 | housekeeping: `dynamic_tests.py`, `selfapps_conda_update.ps1`, excluded pytest files | none | decisions, not tests | n/a |

---

## Status (2026-10-30)

The slices of the ranked list that have landed, with the pull request that carried each. The sections below
keep their 2026-10-11 wording; where they disagree with this section, this section is the newer one.

| Slice | State | Landed in |
|---|---|---|
| Item 35, T4 (baseline red rows, aggregate gate) | done; the aggregate verdict is a required check (criterion C6) | #491, #509 |
| T5 requirement-trace ratchet | done; README sections for REQ-022, REQ-024 and REQ-025 added and `NOT_IN_README` is empty | #490, and the docs-and-tags change after #511 |
| T6 flag-inventory ratchet | done, except the decision on `HP_TEST_DISABLE_LOCK` (below) | #490 |
| T1 A to D launch ledger | done | #494 |
| T1 E single-flag skip hooks, T2 dependency-source matrix, T7 log rotation, T8 non-ASCII folder, T9 UNC launch, T12 no-flag default run | done | #498 |
| T9 long path at its real boundary, T10 housekeeping, REQ-027 rows | done | #502 |
| T3 no-litter allow-list | done as `self.litter.appfolder` | #488 (Item 76) |

**Trace status** (generated by `python tools/req_trace_table.py` on the day of the update; regenerate it, do
not edit the numbers by hand). A shall is "named" when some row carries `req = 'REQ-nnn.m'`; a row that checks
several shalls of one scenario names one of them, so a shall can be checked and still not be named.

| Requirement | Shalls | Named by a row | Not named | Rows tagged with the number only |
|---|---|---|---|---|
| REQ-001 | 2 | 2 | 0 | 6 |
| REQ-003 | 5 | 2 | 3 | 19 |
| REQ-005 | 18 | 0 | 18 | 32 |
| REQ-009 | 13 | 5 | 8 | 28 |
| REQ-012 | 6 | 3 | 3 | 1 |
| REQ-018 | 36 | 4 | 32 | 22 |
| REQ-019 | 3 | 2 | 1 | 1 |
| REQ-021 | 6 | 4 | 2 | 0 |
| REQ-022 | 3 | 1 | 2 | 0 |
| REQ-024 | 8 | 4 | 4 | 0 |
| REQ-025 | 3 | 1 | 2 | 0 |
| REQ-026 | 6 | 6 | 0 | 0 |
| REQ-027 | 3 | 3 | 0 | 0 |
| REQ-028 | 2 | 2 | 0 | 0 |

39 of 114 numbered shalls are named by at least one row tag.

Shalls no row names: REQ-003.1, REQ-003.2, REQ-003.3, REQ-005.1.1, REQ-005.1.2, REQ-005.1.3, REQ-005.1.4, REQ-005.1.5, REQ-005.1.6, REQ-005.1.7, REQ-005.1.8, REQ-005.1.9, REQ-005.1.10, REQ-005.1.11, REQ-005.1.12, REQ-005.1.13, REQ-005.1.14, REQ-005.1.15, REQ-005.1.16, REQ-005.1.17, REQ-005.1.18, REQ-009.9, REQ-009.10, REQ-009.11, REQ-009.12, REQ-009.13, REQ-009.14, REQ-009.15, REQ-009.16, REQ-012.1, REQ-012.3, REQ-012.5, REQ-018.1, REQ-018.2, REQ-018.3, REQ-018.4, REQ-018.5, REQ-018.6, REQ-018.7, REQ-018.8, REQ-018.9, REQ-018.10, REQ-018.11, REQ-018.12, REQ-018.13, REQ-018.14, REQ-018.15, REQ-018.16, REQ-018.17, REQ-018.19, REQ-018.20, REQ-018.21, REQ-018.22, REQ-018.23, REQ-018.24, REQ-018.25, REQ-018.26, REQ-018.27, REQ-018.28, REQ-018.29, REQ-018.30, REQ-018.31, REQ-018.35, REQ-018.36, REQ-019.2, REQ-021.1, REQ-021.3, REQ-022.2, REQ-022.3, REQ-024.1, REQ-024.2, REQ-024.4, REQ-024.5, REQ-025.2, REQ-025.3.

Requirement numbers the README mentions that have no numbered shall yet: REQ-002, REQ-004, REQ-006, REQ-007, REQ-008, REQ-010, REQ-011, REQ-013, REQ-014, REQ-015, REQ-016, REQ-017, REQ-020, REQ-023.

**What is left, in the order I would take it** (each is one pull request and one AGENTS.md loop):

1. **Tag-only: move the rows tagged with the number alone to the sub-id they verify.** Largest: REQ-018 (22
   rows, 32 of 36 shalls unnamed), then REQ-009, REQ-003 and REQ-012. No behavior changes, so no Windows cost
   beyond the run. `tests/test_req_trace.py` accepts only a one-level sub-id (`REQ-005.1`), so the 18
   shalls numbered `REQ-005.1.n` cannot be named until its tag pattern accepts a dotted id.
2. **Rows for shalls nothing checks:** REQ-022.3 (a failure without the four phrases is not retried; one
   conda-full scenario with a package conda-forge does not have), REQ-024.1 (the lock folder exists while the
   run goes on; today `self.stub.lock_no_leak` also passes when no lock is ever created, so a stub that
   reports whether `~bootstrap.lock` exists is the missing half) and REQ-025.3 (no warning when the drive has
   enough space). Each is written first and read red.
3. **Decision: `HP_TEST_DISABLE_LOCK`.** The hook in `:acquire_lock` is set by no test and no workflow
   step (`tests/test_flag_inventory.py` lists it as an exception). Either use it (a row that proves a
   disabled lock leaves no folder) or delete the line and the exception; deleting is smaller and removes a
   switch no test exercises.
4. **Convert the remaining sections** (REQ-007, 008, 013 to 017, 020, 023 and the requirements the last line of
   the table lists) to goal and shalls, each in the change that works on its tests.

---

## Method and yardstick

- **Evidence source.** Run `38141042628` (branch `claude/field-report-backlog-oaelc8`, head `0dd945e`,
  the Item 64 slice 2 merge head, content equal to main `b8732c6`; all 8 lanes complete,
  conclusion success). I downloaded `ci_test_results-selftest-<lane>-...` (pre-harness selfapps rows)
  and `test-logs-selftest-<lane>-...` (harness and selftest rows) for every lane and merged by row id,
  worst status wins. A later passing row with the same id must not hide an earlier failing one (my first
  merge did exactly that and hid the cache lane's `self.exe.smokerun` failure).
- **Baseline reds, matching project memory exactly**: `self.exe.smokerun` (cache),
  `self.exe.warnfix.venv_repair` (uv), `self.cascade.exec` (uv). Nothing else failed in any lane.
  `self.warn.longpath` is `skip` in all 8 lanes.
- **Strength scale.** **Strong** = behavioral assertion on the real output or state, in a gating lane.
  **Medium** = behavioral but only in non-gating lanes, or a log-line proxy, or helper-level only.
  **Weak** = static grep, negative-only check, or a skip. **None** = no row.
- **Lane letters** in the table: gating `R` real, `F` conda-full; non-gating `c` cache, `u` uv, `j`
  justme-test, `k` contract-uv, `K` contract-uv-fail, `d` uv-dl-fallback. "all" means all 8 lanes.
- **What `req_coverage.json` is.** It aggregates rows by their `req` tag (`tools/req_coverage.py`). It
  reports a requirement as covered when any tagged row passes, which says nothing about strength. This
  map is the strength view.

---

## Requirement-by-requirement map

Row ids are literal NDJSON ids (registry: `docs/agent-ndjson.md`). Unit tests run as the single
aggregate row `self.pytest.unit` in every lane.

| REQ | What it requires (short) | Evidence | Strength | Gap |
|---|---|---|---|---|
| 001 | Prime Directive end to end | `self.prime.bootstrap/.run/.exe.build/.exe.run/.spaced-path` (all) | Strong | |
| 002 | Entry selection order | `self.entry.entry1/A/B/C/D/override/helper.invoke.absent/results/spaced-path` (all), `self.entry.picker/.overflow` (F), `test_find_entry.py` | Strong | |
| 003 | Platform and locations | `self.env.smoke.conda/.uv/.run`, `self.exe.build/.run`, `self.fastpath` (all), `self.warn.onedrive/.sysdir/.path_negative` (all), `self.prime.unicode-path`, `self.warn.unc*`, `self.longpath.near.*` (R) | Medium | T8, T9 done |
| 004 | Python version precedence, write-back | `self.envname.*`, `self.uv.managed.interpreter` (all), `self.runtime.writeback`, `pyproject.precedence.*` (R,F); exact pin and range only `self.contract.uv.pyver*` (k) | Strong, with the uv exact-pin case non-gating | |
| 005 / 005.1 | Dependency source order | `reqspec.*` x16 (all), `self.pep723.pyproject.merge` (all), `self.pyproject.malformed` (all), `pyproject.dep.detect/.noproj` (R,F) | Medium: pairwise only | T2 |
| 005.2, .3 | conda bulk retry, per-package fallback | `self.stub.conda_retry`, `self.stub.conda_perpkg` (all) | Strong | |
| 005.4 | pipreqs scan | `pipreqs.flags` (harness), `self.pipreqs.encoding.*` x3, `self.pipreqs.output.*` x4 (R), `self.depcheck.*` (R,F) | Strong | |
| 005.5 | requirements diff log | `batch.dep.diff.trace`, `self.dep.diff.trace` | Medium: log-line proxy | |
| 005.6 | pipreqs-only fallback source | `self.env.smoke.*` (all): one file importing colorama, no source assertion; `pandas_excel.*` (F); `self.realapp.deps_discovered` (R, Item 75, shipped) | Medium to strong | T2 |
| 005.7 | pip gap fill | `pipgap.conda.miss/.pip.fill/.import` (F) | Strong in conda-full | |
| 005.8 | heuristic extras | `test_heuristics.py`, `pandas_excel.*`, `self.pandas.openpyxl.*` (F); `self.realapp.deps_discovered` (R, Item 75, shipped) | Strong on conda and on the real lane (uv) | none |
| 005.9, .10 | warnfix repair loop | `self.exe.warnfix.*`, `self.warnfix.noise.stdlib` (R,F), `self.warnfix.noise.library` (R), `self.parse_warn.table(.v6)` (all); `self.exe.warnfix.venv_repair` (u) **red** | Strong on conda, venv branch red | T4 |
| 005.11 | PEP 723 write-back | 9 `self.pep723.writeback.*` rows (u) | Medium: strong rows, non-gating | Item 35 |
| 005.12, .13 | autopep723 merge, execute-mode discovery | `self.autopep_discovery.merge`, `self.pvw_idempotent.discovery` (u) | Medium: one row each, non-gating | Item 35 |
| 006 | conda channel policy | `reqspec.conda.dryrun.req006`, `.channelpin.req006` (all), `pandas_excel.conda.install.req006` (F) | Strong | |
| 007 | Executable build | `self.exe.*` (all), `self.exe.build.xfail`, `self.exe.warnfix.*`, `self.exe.fastpath.graceful` (R,F), `self.parse_warn.table*` (all); `self.exe.smokerun` (c) **red** | Strong | |
| 008 | NI-VISA optional | `pyvisa.detect/.nivisa.*` x5 (R,F); subfolder case Item 78 | Strong for the flow | |
| 009 | Provider chain and cascade | `self.venv.fallback`, `self.embed.fallback.*`, `self.embed.dl.retry` (all), `self.cascade.detect/.consent` (R,F), `self.cascade.timed` (F); `self.cascade.exec` (u) **red**, `.conda_create_fail` (u), `self.layered_e2e.chain` (c) | Medium: execution only in non-gating lanes | T4 |
| 010 | Session isolation | `self.isolation.req010.pythonpath` (all); runs under `HP_CI_SKIP_ENV=1` with system Python | Weak: `PYTHONPATH` only | T1 |
| 011 | Directory integrity | `self.entry.req011.crossdir/.sameDir` (all) | Strong | |
| 012 | Execution-skip hooks | `self.skiphooks.combined` (F), both flags set together | Weak: no single-flag case | T1 |
| 013 | Network resilience | `self.ux.connectivity.*` x7 (all) | Strong | |
| 014 | System Python consent | `self.ux.system.gate.*` x4 (all) | Strong | |
| 015 | Git config merge | `self.ux.gitignore.*`, `self.ux.gitattributes.*` x6 (all) | Strong | |
| 016 | Post-flight briefing | `self.ux.postflight` (all), `self.exe.hidden_import*` (R,F), `self.postflight.runline.*` (j,u) | Strong | |
| 017 | Size limit | `self.size.tripwire` (all) | Strong | |
| 018 | Controlled execution of user code | `self.exe.smokerun.cwd_consistency`, `self.failfast.probe.*`, `self.checkpoint.*` (R,F), `self.fastpath.hash.backdated_mtime`, `self.interactive.stdin.roundtrip` (u) | Medium: no run counter | T1 |
| 019 | Flags are scaffolding | none; a manual standing directive in `docs/agent-lessons-learned.md` | None | T6 |
| 020 | Cache corruption | `self.corrupt.conda.*`, `self.corrupt.uv.detect` x5 (all) | Strong | |
| 021 | Static pre-flight | `self.preflight.*` (R,F), `batch.preflight.compile` | Strong | |
| 022 | conda create retry | `self.stub.conda_create_retry` (all, `REQ-022.1`); README section REQ-022 (three shalls); the retry-exhausted path through `self.cascade.conda_create_fail` (u, tagged REQ-009) | Strong for .1; .2 and .3 have no row of their own | row for REQ-022.3 |
| 023, 023b | venv canary, no-pip retry | `self.venv.canary_fail`, `self.venv.nopip_retry` (all) | Strong | |
| 024 | concurrent-instance lock | `self.stub.lock_no_leak/.held_decline/.stale_evict/.indeterminate` (all, tagged `REQ-024.8/.3/.6/.7`); README section REQ-024 (eight shalls) | Strong for the decline, stale, indeterminate and release cases; .1 (the lock exists during the run) has no row | row for REQ-024.1 |
| 025 | low disk warning | `self.stub.low_disk_warn` (all, tagged `REQ-025.1`, forced by `HP_TEST_FORCE_LOW_DISK`; it also checks .2); README section REQ-025 (three shalls) | Strong for .1 and .2; .3 (no warning with enough space) has no row | row for REQ-025.3 |
| 026 | argv passthrough | helper-level only: `test_exe_smokerun.py`, `test_failfast_probe.py`; Item 67 will cover the bad `%1` | Weak: nothing at batch level | T1 |
| 027 | honest ambiguous exit | no-EXE branch via `self.exe.build.xfail` (scenario `execfail_runtimefail`, tagged REQ-003); fast-path note via `selfapps_failfast_probe.ps1` `ambiguousNoteFound` | Strong, untagged | T5 |
| AV | Tier A and optimized build | `self.exe.build.tiera`, `self.exe.tiera.hidden_skip`, `self.optbuild.offer` x4 (u) | Medium: non-gating; Item 80 | Item 35 |

**Scoreboard** (37 lines above; each is one requirement or one group): 24 Strong, of which 4 (022,
024, 025, 027) have only a spec or tag gap; 9 Medium (003, 005/005.1, 005.5, 005.6, 005.11,
005.12/.13, 009, 018, AV); 3 Weak (010, 012, 026); 1 None (019). Strong here means "the best row we
have is behavioral and gating", not "every branch is covered"; 005.8 and 005.9/.10 are Strong on
conda only.

---

## Priority 0 (already owned by Item 35): rows that cannot block a merge

This dominates the completeness number but is not a new test, so it stays with Item 35. Facts for it:

- 48 of 307 ids exist only in non-gating lanes. By group:
  - `uv` lane, 28 ids: the 9 PEP 723 write-back rows; `self.autopep_discovery.merge`,
    `self.pvw_idempotent.discovery`, `self.pvw_quickstart.check/.run` and the 4 `self.pvw.*` override
    rows; `self.exe.build.tiera`, `self.exe.tiera.hidden_skip`, `self.optbuild.offer`;
    `self.cascade.exec`, `self.cascade.conda_create_fail`, `self.conda.bothfail`,
    `self.exe.warnfix.venv_repair`; `self.fastpath.hash.backdated_mtime`,
    `self.interactive.stdin.roundtrip`, `self.console.tiering`, `self.exe.timeout_gui_hint`.
  - `cache` lane only, 9 ids: `self.layered_e2e.chain`, `self.dll_bundle.recover`,
    `self.warnfix.platform_filter`, `self.exe.smokerun`, `conda.url`, `entry.helper.ok`, `env.mode`,
    `helper.find_entry.syntax`, `pipreqs.install`.
  - `justme-test`/`uv-dl-fallback`, 5 ids: `conda.install.justme`, `self.dl.conda.fallback`,
    `self.dl.uv.fallback`, `self.postflight.runline.verbatim/.variants`.
  - contract lanes, 6 ids (non-gating by design): `self.contract.uv`, `.pyver`, `.pyver.range`,
    `.pyver.exactpin`, `self.contract.uv.fail`, `self.uv.first.miniconda.skip`.
- `real` is uv-first like a user's run, so a uv-only row is not a different product; it is the same
  provider path with the check wired into the non-gating lane. Promotion therefore means wiring the
  step into `real` after it soaks, not rewriting it.
- The Item 35 note already explains `self.exe.warnfix.venv_repair`: the test-side precondition is
  stale (`HP_SKIP_PIPREQS=1` is reset by `:venv_canary_ok`), so the fix is test-only and can go
  first. `self.cascade.exec` is unexplained and stays open there. `self.exe.smokerun` (cache) is the
  third baseline red; it is the layered chain's deliberately failing uv tier leaking into the shared
  stream (CLAUDE.md Item 35, read from run `38157663037`), fixed test-side.
- Suggested order inside Item 35: fix the test-side venv_repair precondition, root-cause
  `self.cascade.exec`, then remove `continue-on-error` from "Enforce aggregate self-test verdict".
  Until the last step, the baseline's 3 reds are invisible to merges. All three steps have shipped.
- **Update 2026-10-11, from reading the baseline `uv` job log in full (diagnosis; proven by run
  `38157663037`: `venv_repair` `attemptedXlrd:false`, `systemSkipWarn:false`, `preconditionOk:true`;
  `cascade.exec` `repairMarkers:3`, `installAttempts:2`, `repairWithoutAttempt:1`; fixed on the follow-up
  PR).** The two `uv` reds are not independent. In the cascade log the embed
  tier prints `[REPAIR] missing modules detected; installing and rebuilding.` and then goes straight
  to `Rebuilding standalone executable after warnfix`, with no `Attempting to install:` line and no
  `System fallback: skipping warnfix repair installation.` line, so no repair install ran, no failure
  flag was set, no cascade candidate was raised, and the chain stopped at embed (`offersSkipped` 2,
  not 4). The dispatch in `run_setup.bat` (`) else if "%HP_ENV_MODE%"=="conda" if defined CONDA_BAT (`,
  the only nested `if` in an else-chain in the file) puts the venv, embed and system branches in the
  else of the inner `if defined`, so when the mode is not `conda` the whole chain is skipped. That is
  the Item 36 bug again, reintroduced by Item 36's own review fix. `self.exe.warnfix.venv_repair`
  could not show it because its precondition was stale (pipreqs installed xlrd up front); with the
  precondition fixed it is the regression test for this. The fix is in `run_setup.bat` and belongs to
  the lane that owns that file, test first.

---

## The gaps

Each gap lists what is missing, the field or design evidence, the smallest test, the lane, and how to
show it can fail. For coverage of behavior that already works, the first push carries a deliberately
wrong expectation (a count off by one, an inverted assertion, or a test-only hook that re-creates the
bug) and CI must show exactly that row red and every other row green; then the correct expectation
follows. If the correct expectation is red, the test found a real bug: file a backlog item with the
row as its test-first proof. **New coverage rows start in the `uv` lane (non-gating by construction)
and are promoted by moving the step into `real` after several consecutive full-matrix greens read row
by row** (Item 35's discipline). "Cost" counts extra `run_setup.bat` bootstraps, each of which includes
a PyInstaller build unless noted.

### T1. Launch ledger: argv (REQ-026), run count (REQ-018), skip hooks (REQ-012), decoy interpreter (REQ-010)

**Missing.**
- REQ-026 has only helper-level unit tests (`tests/test_exe_smokerun.py:216`,
  `tests/test_failfast_probe.py:188`). Nothing runs `run_setup.bat app.py "a b" c` and checks that the
  program receives exactly `["a b", "c"]` at each of the four launch sites README lists (EXE smoke,
  cached-EXE fast path, interpreter verification, checkpoint second run). The capture block is
  `run_setup.bat:143-151`; the forwarding sites include `:3422`, `:3620`, `:3645`, `:4240`, `:4268`.
- REQ-018 says mandatory verification runs the user's code exactly once. Today that is a log-line
  proxy: `selfapps_postexec_checkpoint.ps1` counts `Entry smoke exit=0` lines (about lines 120-183),
  and `selfapps_envsmoke.ps1` writes its token file with mode `'w'` (about line 666), so a second
  launch is invisible.
- REQ-012: `selfapps_skiphooks.ps1` sets both flags together. `HP_SKIP_ENTRY_SMOKE` alone and
  `HP_SKIP_EXE_SMOKERUN` alone are never run.
- REQ-010: the only assertion is that `PYTHONPATH` is empty (`selfapps_isolation.ps1:158`). The same
  script records `PYTHONHOME` but never asserts it (`:134`), and it runs under `HP_CI_SKIP_ENV=1`
  with system Python, so the README's "prepend the provider's `Scripts` to `PATH`" is unreachable
  there. `run_setup.bat:383-384` clears both variables.

**Evidence.** Field notes line 62-64 (2026-08-31): the maintainer passed `arg1 arg2` and hit the `%1`
trap, so argument passing is a feature real runs use. Hardware-driving programs (pyvisa) are in the
notes; a regression that launches the program twice, or with dropped arguments, has side effects the
suite cannot see. The 2026-08-27 EXE-working-directory bug was found the same way: nothing observed
where the program actually ran.

**Smallest test.** `tests/selfapps_launch_ledger.ps1` with one stub, `ledger_app.py`, that appends one
JSON line per launch to `~ledger.jsonl` in its working directory:
`{"argv": sys.argv[1:], "frozen": bool(getattr(sys, "frozen", False)), "prefix": sys.prefix,
"pythonhome": os.environ.get("PYTHONHOME", "")}`. Scenarios:
- **A** fresh folder, `run_setup.bat ledger_app.py "a b" "" c d e f g h i` (the entry file is position
  1; the batch reads positions 2 to 9, so `i` at position 10 is ignored and the empty one is dropped):
  expect exactly 1 ledger line, `frozen=true`, argv `["a b","c","d","e","f","g","h"]`. This also pins
  README's "up to 8 extra arguments" and "explicitly empty is dropped". Passing the empty argument
  through `cmd /c` from PowerShell needs care **(to verify)**.
- **B** rerun in the same folder with the same args (cached-EXE fast path): 1 more line, same argv.
- **C** fresh folder with PyInstaller (and Nuitka) forced to fail, as `selfapps_pyinstaller_fail.ps1`
  does (interpreter verification): 1 line, `frozen=false`, same argv, `pythonhome` empty, `prefix`
  under the provider's environment folder. Before the run, put a decoy directory first on `PATH`
  containing a `python.cmd` that writes `~decoy_ran.txt` and exits 1, and set `PYTHONHOME` to a
  poison path; assert the marker is absent. Rows `self.isolation.req010.pythonhome` and
  `self.isolation.req010.path_shadow` ride this one bootstrap.
- **D** fresh folder with `HP_TEST_CHECKPOINT_ANSWER=Y`: exactly 2 lines, both with the argv.
- **E** (second PR) `HP_SKIP_ENTRY_SMOKE=1` alone and `HP_SKIP_EXE_SMOKERUN=1` alone: ledger line
  counts as README REQ-012 states them. Derive the exact expected counts from README and the code at
  implementation time **(to verify)**; the fast-path wording in REQ-012 makes the ENTRY_SMOKE-alone
  case the subtle one.

Row ids (literal at every `Write-NdjsonRow` call, per the registry-checker lesson):
`self.launch.argv.fresh`, `self.launch.argv.fastpath`, `self.launch.argv.interpreter`,
`self.launch.count.default`, `self.launch.count.checkpoint`, `self.launch.argv.cap` (all `req =
'REQ-026'` or `'REQ-018'`), plus the two REQ-010 rows and, in slice E, `self.skiphooks.entry_only` /
`self.skiphooks.exe_only` (`req = 'REQ-012'`).

**Lane and cost.** `uv`, then `real`. Scenarios A to D are 4 bootstraps; E adds 2. Add the new
artifact paths to the test-logs upload (AGENTS.md "No silent features").

**Prove red.** Scenario A first with the expected argv missing its last element; then correct.

**Overlap.** Item 67 tests the bad `%1`; this test always passes a real `.py` first. Item 82's CI rows
launch the program through other branches; they do not count launches.

### T2. Dependency-source matrix with lineage (REQ-005.1, .4, .6)

**Missing.** README's "Source Resolution (authoritative order)" has five outcomes. Existing rows:
PEP 723 and pyproject merged on a first run (`self.pep723.pyproject.merge`, was `.override` before Item 89), malformed pyproject
(`self.pyproject.malformed`), pyproject detection (`pyproject.dep.detect/.noproj`, conda-full and
real). Not run: PEP 723 over requirements.txt without a pyproject; requirements.txt alone as an
asserted source; an empty `requirements.txt` falling through ("present and non-empty"); a malformed
PEP 723 header falling through with its WARN to the next source; a pyproject with no
`[project].dependencies` falling through to requirements.txt; all three present. No row asserts
`DEP_SOURCE` (the batch sets `requirements.txt`, `pyproject`, `pep723`, `pipreqs`, or leaves
`unknown`: `run_setup.bat:130,1346,1421,1524,1542`) together with what was actually installed.

**Evidence.** The field notes spend several entries on "my requirements.txt edit was not obeyed"; the
plan doc found it was obeyed, but no row would catch a regression either way. Item 76 renames the file
that records the source, so a test that reads it by one variable is also its safety net.

**Smallest test.** `tests/selfapps_dep_source_matrix.ps1`: each cell is a folder with a stdlib-only
stub (so pipreqs cannot add anything) except the pipreqs cells, plus one distinct tiny pure-Python
package per source (for example `six` in requirements.txt, `colorama` in pyproject,
`iniconfig` in the PEP 723 header). Assert, per cell: the logged `dependency_source=` value; the
winning package present in `~dependency_installed.txt`; the losing sources' packages absent.
Cells: (1) PEP 723 only, (2) requirements.txt only, (3) all three present, (4) malformed PEP 723 plus
requirements.txt (expects the documented WARN and fall-through), (5) pyproject without
`[project].dependencies` plus requirements.txt, (6) empty requirements.txt plus a program importing
`six` (falls to pipreqs), (7) nothing declared plus a program importing `six` (pipreqs, with the
positive form of the pipreqs-only WARN once Item 68 revives it; see T7). Read the file name from one
variable so Item 76's rename touches one line.

**Lane and cost.** `uv`, then `real` (this is the user's provider). 7 bootstraps. Check which
existing flags avoid the PyInstaller build and the program run for these cells (for example
`HP_SKIP_ENTRY_SMOKE=1` with `HP_SKIP_EXE_SMOKERUN=1`, or the forced-PyInstaller-failure flag)
**(to verify)**: the dependency install happens before the build, so these cells only need it to
get that far.

**Prove red.** Cell (3) first with the wrong expected winner.

**Overlap.** Item 75a is the multi-file pandas+Excel app without requirements.txt (the heuristics and
the 63-65 discovery path); this matrix is the single-source semantics underneath it. Do the matrix
first; Item 75a then needs fewer assertions of its own. (Shipped: Item 75 is `tests/selfapps_realapp_pandas_excel.ps1`,
which asserts the installed set, the recorded source and the sibling-module rule on top of the matrix; it found Item 88.)
Item 89 (maintainer decision on open question 3): the inputs are merged, not chosen between, so cells 3 and 8 (pyproject plus
requirements.txt) and 9 (one package pinned three ways) assert the union and the conflict line, and
`tests/selfapps_dep_merge_later.ps1` covers what only a second run can show: delete, add, pin edit, header edit, a package
`pyproject.toml` still lists, and an unchanged run.

### T3. "No litter" allow-list for the app folder

**Missing.** README's tilde rule (REQ-015 plus the 2026-10-09 addition) says bootstrapper-internal
files take a tilde and are git-ignored. Nothing enforces it: `tilde.naming` only counts five known
names in the batch text (`harness.ps1:232-233`). `dependency_source.txt` (`run_setup.bat:2232`) is a
non-tilde file the bootstrapper writes into the user's folder, and Item 76 was filed after someone saw
it by eye.

**Smallest test.** After any one default bootstrap in `real`/`uv` (reuse the stub run in
`selftest.ps1`, no new bootstrap): list the top-level entries of the app folder; fail on any entry
that is not tilde-prefixed and not in a short allow-list (the user's own files, `dist`, `build`,
`.uv_env`, `runtime.txt`, `requirements.txt`, `.gitignore`, `.gitattributes`, the spec file if any
**(to verify exact set)**). Start with `dependency_source.txt` on the allow-list marked "Item 76", and
remove it in Item 76's PR, which turns the check from a ratchet into a lock. Row id
`self.litter.appfolder`, `req = 'REQ-015'`.

**Lane and cost.** `real` (gating) is reasonable from the start because it reads files an existing
bootstrap already produced; zero extra bootstraps. **(to verify)** the allow-list against a real
artifact listing before committing, since a wrong list is the only way this goes red falsely.

**Prove red.** Run it once with the allow-list missing `runtime.txt` and confirm that is the only
failing entry.

### T4. uv-lane red rows (owned by Item 35; evidence)

`self.cascade.exec` (REQ-009: the cascade falls through to embed instead of stopping at conda) and
`self.exe.warnfix.venv_repair` (REQ-005.9/.10: test-side stale precondition) are red in the baseline
and invisible to merges. They are the only two failing rows in the 8 lanes besides the cache-lane
`self.exe.smokerun`. See "Priority 0". No new test is proposed; the point for this map is that they
are the two highest-risk *known* red rows and both sit on the default (uv-first) path after a failed
repair.

### T5. Requirement traceability ratchet

**Missing.** The README defines no section for REQ-024 and REQ-025 (they exist in the batch, in
`tests/selftest.ps1:620-835`, and in `docs/agent-closed-backlog.md`) and mentions REQ-022 once. 128 of
307 row ids carry no `req` tag, 45 of them `self.*` rows in gating lanes, including every `REQ-024` and
`REQ-025` row, the long-path/OneDrive/sysdir warning rows, and the PEP 723 reader rows. REQ-019,
REQ-024, REQ-025, REQ-026 and REQ-027 appear on no row, so `req_coverage.json` omits them entirely.

**Smallest test (no Windows cost).** One pytest, `tests/test_req_trace.py`, that parses the README for
`## [REQ-nnn]` headings plus an explicit list of known-undefined numbers, scans `tests/*.ps1`,
`tests/harness.ps1` and the workflow for `req = 'REQ-nnn'` literals, and fails when a README heading
has no tagged row and no entry in a short exemption list. Land it with the exemption list pre-filled
for today's gaps, so it starts green and every closed gap shrinks the list. A second slice adds the
tags (a test-file edit, no behavior change) and README stubs for REQ-022/024/025 (a README edit,
which the maintainer should approve as a scope question, since AGENTS.md says to file a backlog item
rather than edit requirements).

**Lane.** pytest step, all lanes (runs on Windows with the other unit tests).

**Prove red.** Remove one tag in the first push.

**Status (2026-10-11): landed.** `tests/test_req_trace.py` is the pytest. Its exemption tables are
`NO_ROW_TAG_YET` (REQ-019, 026, 027: no row yet) and `NOT_IN_README` (empty since the README
sections for REQ-024 and REQ-025 landed). Each rule is proven able to fail by the synthetic cases
in the same file, and a stale exemption warns instead of failing. The tag-only follow-up is done too:
the four REQ-024 lock rows and `self.stub.low_disk_warn` (REQ-025) in `tests/selftest.ps1` now carry
`req`, and since the sections landed each carries the sub-id it verifies.

### T6. Flag-inventory ratchet (REQ-019)

**Missing.** `run_setup.bat` references 391 `HP_*`/`PVW_*` names, 51 of them `HP_TEST_*` hooks. The
README's standing directive ("re-run this check whenever a new flag is added") is manual. At least one
hook is dead: `HP_TEST_DISABLE_LOCK` (`run_setup.bat:5681`) is set by no test and no workflow step.

**Smallest test.** One pytest, `tests/test_flag_inventory.py`: (1) every `HP_TEST_*` name read in
`run_setup.bat` is set by at least one file under `tests/` or `.github/workflows/`, with an allow-list
containing `HP_TEST_DISABLE_LOCK` until it is either used (a test that opts out of the lock) or removed
(a `run_setup.bat` change, so it waits for the backlog's batch edits); (2) every `HP_*`/`PVW_*` name in
README's "Advanced Environment Variables (reference)" table exists in the batch. It cannot automate the
real rule (a flag must never *enable* a Prime Directive behavior); that review stays manual, now with
the mechanical half enforced.

**Lane.** pytest step, all lanes. Cost: none.

**Status (2026-10-11): landed** as `tests/test_flag_inventory.py` with a third rule (every `PVW_*`
override the batch reads is documented). `UNTESTED_HOOKS` holds `HP_TEST_DISABLE_LOCK` only.

### T7. Replace vacuous and false-pass rows

| Row | Why it cannot fail meaningfully | Replacement |
|---|---|---|
| `batch.req005.warn_gate` (`harness.ps1:380-382`) | passes while the batch contains the strings `if not defined DEP_SOURCE (` and the WARN text; that block is dead (`DEP_SOURCE` is initialized to `unknown` at `run_setup.bat:130`), which is exactly Item 68's "dead WARN" | Delete it in Item 68's PR and replace with the pair: WARN shown when pipreqs is the only source (T2 cell 7), absent when requirements.txt exists (T2 cell 2) |
| `self.pipreqs.warn.gated` (`selftest.ps1:1691`) | asserts only that the WARN is absent; the WARN never fires in any scenario, so it cannot go red | same pair as above |
| `log.rotate` (`harness.ps1:231`) | regex for `Length -gt 10485760` anywhere in the batch | seed a log over 10 MB, run, assert the old file was rotated and the new one is small **(to verify)** what the batch rotates and where |
| `tilde.naming` (`harness.ps1:232-233`) | passes when 3 of 5 known names occur anywhere | superseded by T3 |
| `self.warn.longpath` (`selftest.ps1:925-985`) | `skip` in all 8 lanes because default runners cannot enter a path over 260 characters | T9: replaced by `self.longpath.near.below/.at/.over` (199, 200 and 215 characters); the old row is removed |

Each replacement lands with its pair or successor, not alone, so no coverage is lost in between.

### T8. Non-ASCII folder name

**Missing.** `self.envname.ampersand/hyphen/longname` and `self.prime.spaced-path` cover awkward ASCII
names. No test bootstraps from a folder with a non-ASCII character in its path, although accented user
profile names (`C:\Users\<name with an accent>\Downloads\...`) are ordinary on real machines and the
batch, PyInstaller, and `pip` all touch the path. Repo files must stay ASCII, so the test builds the
name at run time (`[char]0x00E9`). No field note shows a failure yet, so this ranks below the others;
it is cheap and high-severity if it fails.

**Smallest test.** `self.prime.unicode-path`, `req = 'REQ-001'`: the Prime Directive stub from
`selfapps_single.ps1` in a folder named `Cafe` with the accented e plus a space and a short second
word; assert `~bootstrap.status.json` state ok and the stub's output token. 1 bootstrap.
**Lane.** `uv`, then `real`. If it fails, the failure is the finding: file an item before touching
the batch.

### T9. UNC and long path

**Missing.** `run_setup.bat:153-160` prints a UNC warning and then `cd /d "%~dp0"` fails (cmd cannot
use a UNC working directory) with `[ERROR] Workspace path invalid` and exit 1. That branch has never
run in CI. The long-path guard row is skipped in every lane (see T7).

**Smallest tests.**
- UNC: a probe row first, `self.warn.unc.probe`, that checks whether `\\localhost\C$\...` resolves to the
  runner's scratch folder **(to verify; admin shares may be absent on hosted runners)**. If it does,
  `self.warn.unc` runs `cmd /c "\\localhost\C$\...\run_setup.bat"` and asserts the WARNING text, the
  `Workspace path invalid` error, exit code 1, and no hang. If it does not, the row reports `skip`
  with reason `unc-share-unavailable`, not a pass.
- Long path: add a test-only hook mirroring `HP_TEST_FORCE_LOW_DISK` (for example
  `HP_TEST_FORCE_LONGPATH`, which makes the guard measure a fake length). That is a `run_setup.bat`
  edit, so it waits until the backlog's batch edits finish; it also needs a README mention of the hook
  only if REQ-019's reference table lists test hooks **(to verify)**.

**Lane.** `uv`. Cost: 1 short bootstrap that stops early.

### T10. Housekeeping decisions (no new rows)

- `tests/dynamic_tests.py` emits `dp.*`, `pr.*`, `helpers.decode.*` rows that appear in no lane,
  because the CI step runs only when the repo root reports `state=ok`, and the repo root has no `.py`
  entry. `tests/README_TESTS.txt` calls it a template for consumer repos, so default: leave it,
  state that in `docs/agent-ndjson.md`, and rely on the pytest equivalents (`test_detect_python.py`,
  `test_heuristics.py`). Alternative: run it against the stub folder.
- `tests/selfapps_conda_update.ps1` (`self.conda.base.update`) is not run in CI by design
  (`docs/demo-bootstrapper-output.md:1974`). Wire it into `conda-full` or delete the registry entry.
- `test_entry_selection.py` and `test_entry_single.py` are excluded from the CI pytest step
  (`batch-check.yml:1353`) because they drive `selfapps_entry.ps1` and the single-file scenario, which
  the lanes already run directly. `test_poll_public_diag_logging.py` is excluded too; I did not find the
  reason written down **(to verify)**: add one comment line at the exclusion.

---

## False-pass hunt (AGENTS.md: "IF all green -> verify no false passes")

Read in this pass, beyond T7: `self.isolation.req010.pythonpath` is real but narrower than REQ-010;
`self.env.smoke.run` proves the program ran at least once, not once; `self.pytest.unit` is one row for
the whole unit suite, so a failing file shows only in `details.summary` (acceptable, but the first
ten FAILED names are all a reader sees). Skips counted as passes: only `self.warn.longpath` is
skip-only in every lane; the conda-dependent rows skip correctly outside conda-full (`skip=true` with a
reason) and fail for real inside it.

---

## Already owned by Items 62-82 (do not duplicate)

Items 64-65 (stdlib and library-internal warnfix noise, runtime `ModuleNotFoundError` naming), 66
(provider memory), 67 (bad `%1`), 68 (wording, dead WARN), 70, 71 (`PVW_BUILDER`), 72-73, 74
(example apps), 75 (real-app end-to-end), 76 (rename), 77 (VC++ runtime warning), 78 (NI-VISA elevation
and subfolder scan), 79 (TOML hygiene), 80 (Nuitka unsupported Python), 81 (pipreqs staging log),
82 (last-chance cascade offer) each bring their own test-first rows. This map adds nothing that
duplicates them; where a gap above touches one (T2 with 68 and 75a, T3 with 76, T1 with 67), it says so
and keeps the shared assertion in one place. Do not add `pip freeze > requirements.txt`, a
`--hidden-import=xlsxwriter` blanket, or a "move the cascade prompt" test: the field-report plan
rejects those.

---

## Suggested slice order (each is one PR and one AGENTS.md loop)

Only the test-only slices below are safe to run alongside the two threads editing `run_setup.bat`;
all touch `tests/` and `.github/workflows/batch-check.yml` (the yml is the likeliest merge conflict).

1. **S1: T5** traceability ratchet, then its tag-only follow-up. Pytest only. Makes "complete"
   measurable on the traceability axis.
2. **S2: T6** flag-inventory ratchet. Pytest only.
3. **S3: T1 A to D** launch ledger (uv lane). Highest field risk of the new tests.
4. **S4: T2** dependency-source matrix (uv lane); the positive WARN cell waits for Item 68.
5. **S5: T3** no-litter allow-list (real lane); lock it down when Item 76 merges.
6. **S6: T1 E** single-flag skip hooks.
7. **S7: T8** non-ASCII folder; **S8: T9** UNC probe.
8. **S9: promotion pass**: move soaked rows (S3, S4) from `uv` to `real`, per Item 35.
9. **After the batch edits settle**: the `HP_TEST_FORCE_LONGPATH` hook (T9), removing or using
   `HP_TEST_DISABLE_LOCK` (T6), the T7 replacements that depend on Item 68.

---

## Proposed finish line for "the test suite is complete"

AGENTS.md defines no threshold, so this is the default I picked; change it freely.

- **C1** Every README requirement number has a section, at least one tagged row, or a written
  exemption (T5 enforces it).
- **C2** Every requirement has a Strong row in a gating lane, or an exemption naming why (today: 9
  Medium, 3 Weak, 1 None in the map above).
- **C3** No row lives only in non-gating lanes unless its lane is non-gating by design
  (`contract-uv`, `contract-uv-fail`, `uv-dl-fallback`).
- **C4** Every `HP_TEST_*` hook in the batch is set by a test (T6 enforces it).
- **C5** No known-vacuous row, and no row skipped in all lanes (T7, T9).
- **C6** The three baseline reds are fixed and the aggregate gate is no longer advisory (Item 35). Met.

---

## What I verified and what I did not

**Read directly from run `38141042628` artifacts:** the row inventory per lane, the three failing rows,
the permanent skip, the `req` tag sets, which ids appear in which lanes.

**Read in the repo at `b8732c6`:** README requirement text, AGENTS.md, the code and test lines cited
above, the pytest exclusion list, the `DEP_SOURCE` assignments, the flag counts (a text scan, so
names inside comments count).

**Not verified (marked "to verify" above):** the UNC share on hosted runners; the exact app-folder
allow-list for T3; which flags skip the PyInstaller build cheaply for T2; the exact expected
ledger counts for the single-flag hooks; what `log.rotate` should observe; whether the README's
environment-variable table lists test hooks. No proposed test has been run.

## Defaults I chose (change any of them)

- New coverage rows gate from their first run (AGENTS.md, "New tests gate immediately"); only a row that can
  fail from a transient network or provider problem starts non-gating, with the reason in its pull request.
- `tests/dynamic_tests.py` stays a consumer template.
- README sections for REQ-022/024/025 were a separate docs slice, not part of T5's first PR; they landed
  after #511 with the sub-id tags on the existing rows.
- Coverage tests for existing behavior prove they can fail with a deliberately wrong first
  expectation, not with a product bug.
