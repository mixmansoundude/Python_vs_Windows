# Agent Closed Backlog -- Python_vs_Windows

**This file is NOT auto-loaded into every session's context** (unlike
`docs/agent-lessons-learned.md`, `docs/agent-interconnect.md`, and
`docs/agent-ndjson.md`, which CLAUDE.md's own
`@import` lines pull in automatically). Read it on demand: when CLAUDE.md's own pointer sends you
here, when you need the full resolution history behind a specific PR/item cited by number, or
when investigating something that "feels like it was already done" and you want the receipt.

Moved out of `CLAUDE.md` directly (2026-07-31) specifically to reduce that file's per-session
context footprint -- CLAUDE.md is loaded in full every session, and this file alone was ~2600 of
CLAUDE.md's ~4200 lines (>60%) despite being pure historical record with no forward-looking
action attached to any entry. Nothing here needs re-reading by default; it exists so a specific
past decision or fix can be looked up when its details actually matter.

**A `docs/demo-bootstrapper-output.md` "Part N, Scenario N" citation below reflects that doc's
structure AT THE TIME the entry was written, not necessarily its current numbering** -- that file
went through a flow-only reorg pass (2026-08-02) that renumbered every Part and Scenario, and will
likely be reorganized again as it grows. Treat a Part/Scenario citation here as "roughly where to
look," not a precise current coordinate; this file is an append-only historical record, so its own
entries are not retroactively renumbered to track that doc's current structure.

**Two sections below.** "Closed Active Backlog Items" holds items that were promoted out of
`CLAUDE.md`'s own "Active Backlog" section once fully resolved (each keeps its original item
number for cross-reference stability -- other docs cite these by number). "Closed Backlog" is
`CLAUDE.md`'s own pre-existing changelog-style record of completed feature/fix work, moved here
verbatim.

---

## Closed Active Backlog Items

### Item 7 (closed 2026-07-27; moved here 2026-07-31)

- **CI job steps in `batch-check.yml` don't use `if: always()`, so one failing self-test step
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

   **Re-examined 2026-07-25 per an owner request to raise confidence-to-implement wherever
   possible, gating-lane half only.** Found real, previously-uninvestigated information in both
   directions -- net effect: still not implemented, but for a more precise reason than before.
   - **Lower risk than originally feared, confirmed by actually reading the step definitions
     rather than assuming**: `steps.X.outputs` cross-references and `GITHUB_ENV` state-passing
     inside the `selftest` job are minimal and almost entirely early/self-contained (lane-config
     flags set before the main bootstrap step, plus the already-`always()`-guarded `cache`-lane
     corruption chain) -- confirming the established "every selfapps_*.ps1 test creates its own
     `~selftest_X` scratch directory, independent of sibling steps" convention genuinely holds at
     the CI-step level too, not just within a single test file. This means the originally-feared
     failure mode (step N's crash corrupting step N+1's inputs, producing confusing, misattributed
     secondary failures) is less likely than assumed -- most conda-dependent tests already have
     their own defensive "conda not found" handling (see "Test files that assume conda is present"
     above), which would produce an accurate, if repetitive, `pass=false` rather than a nonsensical
     crash.
   - **A genuinely NEW risk surfaced that the original reasoning never considered**: `if:
     always()` does not just control whether a step RUNS, it can change HOW LONG a job takes to
     FAIL. If the root cause is the top-level "Bootstrap environment" step itself (e.g. Miniconda
     failing to install), a blanket `if: always()` would mean dozens of downstream steps EACH
     attempt their own real sub-bootstrap (each potentially retrying its own slow Miniconda/
     conda-forge network operations) before finally completing, rather than failing fast as today.
     This directly compounds with item 1's own concern (below, now under Periodic Maintenance
     Checks) about CI wall-clock growth -- turning a fast single-step failure into a much longer
     one specifically in the failure case, which is exactly when a contributor is waiting on the
     signal most.
   - **Net assessment: medium, not high, confidence** -- the coupling risk is lower than
     originally assumed, but the newly-found duration-inflation risk is real and unquantified
     (verifying it would need deliberately breaking a real CI run and observing actual timing
     across ~40 downstream steps, not something to do casually). Still correctly deferred; the
     two original reasons for deferral (a wide, ~50-step blast radius; no observed instance of
     this class of gap hiding a real regression yet) both still hold, now with a clearer picture
     of what a future dedicated pass would actually need to verify before shipping.

   **Partially closed, 2026-07-26: the dedicated scoping pass this item asked for, owner-
   requested directly ("Item 7 scoping pass").** Catalogued all 123 steps in the `selftest` job
   by exact `if:` condition, not from memory: ~44 (steps ~84-123, plus the two harness-parse
   steps near the top) already carry `always()`/`failure()` -- the summary/verdict/upload/
   diagnostics tail of the job is already fully hardened. The real risk band is steps ~17-83
   (~67 steps, gated on `env.HP_CACHE_CORRUPTED != '1'` or a specific `matrix.mode` match, no
   `always()`), all downstream of the single "Bootstrap environment (run_setup.bat)" step.
   - **Traced every one of those ~67 steps to its underlying script and found exactly 5 that are
     provably zero-risk** -- they never execute `run_setup.bat` as a subprocess at all, so
     `always()` cannot trigger a redundant real bootstrap for them, only surface a result that
     was previously silently skipped: `selfapps_size.ps1` (a static byte-size tripwire, REQ-017),
     `selfapps_parse_warn_table.ps1` (decodes the embedded `HP_PARSE_WARN` base64 payload as
     static text, never runs the bootstrapper), and the three pure `python -m unittest`/`pytest`
     steps against this repo's own `tests/test_*.py` suite (`test_parse_warn.py`,
     `test_heuristics.py`, the cross-platform pytest step). **Shipped in this pass**: all 5
     converted to `if: always() && <existing lane condition>`, each with an inline comment
     recording why it's safe (verified via `yamllint`/`actionlint`, both clean). Real, if modest,
     immediate hardening at zero duration risk -- a bug in `tools/parse_warn.py` or
     `tools/prep_requirements.py` that coincides with an unrelated bootstrap failure is no longer
     silently invisible.
   - **The remaining ~62 steps all genuinely spin up their own scratch-dir `run_setup.bat`
     invocation** (confirmed via `grep` for each script's actual execution pattern, e.g.
     `cmd /c .\run_setup.bat`, not just a textual mention) -- this is the real, still-open blast
     radius the original backlog text worried about, essentially unchanged in size.
   - **The duration-inflation risk itself is now sharper, not just "lower," thanks to two
     concrete pieces of new evidence.** First, this repo's own already-documented fact (see the
     `:tci_both_failed` Closed Backlog entry) that Miniconda installs to a SHARED, machine-wide
     path (`%PUBLIC%\Documents\Miniconda3`), not a per-test-directory one -- meaning once the main
     bootstrap step gets far enough to install Miniconda successfully, every downstream
     conda-dependent selfapps step finds `conda.bat` already present and skips its own install
     block entirely, at zero extra cost. Second, this session's own owner-authorized CI
     fault-injection experiment (three throwaway-branch probes, see chat history) produced live
     confirmation of BOTH ends of this: a probe that broke `run_setup.bat` before Miniconda is
     ever touched (an unbalanced paren) failed in under a second via cmd.exe's own native parser,
     and a probe that broke it well after Miniconda/conda would already be installed (a corrupted
     PyInstaller flag) also failed fast and deterministically, not via a slow network timeout.
     **Net conclusion: the duration-inflation risk is not "any bootstrap failure," it is
     specifically scoped to the one case where Miniconda itself fails to install** (a real,
     if narrower, failure mode this repo has hit before -- see the REQ-013 connectivity-check
     retry-hardening entry's `conda.anaconda.org` 403 example) -- only THAT case would make every
     downstream conda-dependent step redundantly retry a slow install in lockstep.
   **Closed same day, follow-up slice: the remaining ~36 steps converted too, owner-directed
   ("if confidence is high then proceed to next slice and drive to completion").** Built the
   shared pre-check the paragraph above proposed -- a new `Check Miniconda availability` step
   (`id: conda_avail`, a dual-path `Test-Path` fallback against the shared
   `%PUBLIC%\Documents\Miniconda3\condabin\conda.bat` and its `Scripts\conda.bat` fallback --
   matching `run_setup.bat`'s own `:select_conda_bat` (`CONDA_MAIN`/`CONDA_ALT`) and the existing
   "Validate restored conda binary" step's dual-path check, caught by CodeRabbit on PR #390's
   first real-CI pass -- zero execution/network cost either way) placed right after the main
   bootstrap step -- then converted 36 of the remaining candidates, each gated
   through it with a LANE-AWARE condition, not a uniform one. **Shown here in their final,
   shipped form (`!cancelled()`, not the `always()` these were first written with -- see the
   "Two CodeRabbit findings" paragraph below for why the whole job was converted from one to the
   other in the same pass; this section is kept in sync with the actual condition strings rather
   than describing an intermediate state)**:
   - Steps restricted to `real || conda-full` (22 steps: warnfix family, hidden-import family,
     the PyInstaller-failure family, EXE-smokerun xfails, etc.): `!cancelled() && (matrix.mode ==
     'real' || (matrix.mode == 'conda-full' && steps.conda_avail.outputs.available == 'true'))`.
     The `real` lane is uv-first (see REQ-009 provider order), so it needs no conda gate at all --
     its own redundant-retry worst case is bounded by uv's existing `--retry`/`--max-time` budget
     (seconds to low minutes), not conda's. Only the `conda-full` half of the condition needs the
     pre-check, since that lane unconditionally forces conda for the whole job.
   - Steps restricted to `conda-full` only (5 steps: skiphooks, entry picker, cascade-timed,
     pandas/openpyxl, pip gap-fill): `!cancelled() && matrix.mode == 'conda-full' &&
     steps.conda_avail.outputs.available == 'true'`.
   - Steps that run on every non-corrupted lane (9 steps: empty-repo, single-entry, entry
     selection, isolation, env-name, real-env-smoke, reqspec, UX hardening, system-Python
     consent): `!cancelled() && env.HP_CACHE_CORRUPTED != '1' && (matrix.mode != 'conda-full' ||
     steps.conda_avail.outputs.available == 'true')` -- only conda-full among the lanes this
     condition reaches needs the extra guard.
   **Deliberately NOT converted, three distinct reasons, not oversight**: (1) the three
   pre-bootstrap/setup steps (`Enable Miniconda probe`, `Force conda-only bootstrap`, `Bootstrap
   environment (run_setup.bat)` itself) -- these must run in ORDER, before anything else; `always()`
   on the root step itself is a no-op at best; (2) `Run dynamic tests (if present)` and `Run tests
   (map empty repo to success)` -- confirmed via direct reading that `tests/harness.ps1` `throw`s
   on a missing `~bootstrap.status.json` (lines ~67/71), so `always()`-ing these without ALSO
   hardening that guard risks trading a clean skip for a confusing uncaught-exception failure;
   correctly left for its own small follow-up rather than risking it in this already-large diff;
   (3) `Validate Miniconda before cache save`/`Save Miniconda cache` -- restricted to the `cache`
   lane, which is non-gating (job-level `continue-on-error`), so out of this item's scope entirely.
   Verified via `yamllint`/`actionlint` (clean) and a scripted diff-scope check (exactly 36 `if:`
   lines changed, matching the 36 target steps, no stray edits) before committing -- the same
   "verify the diff touches exactly what's intended" discipline this file's own
   `docs/agent-lessons-learned.md` documents for `run_setup.bat` edits, applied here to YAML.
   Real-CI confirmation (does the `conda_avail` output actually read as `'true'`/`'false'`
   correctly, does a genuine conda-full run behave identically to before when conda IS available)
   is the one thing that can't be verified locally -- watch the next `conda-full` run closely.

   **Two CodeRabbit findings on PR #390's first real-CI pass, both verified independently before
   acting, not taken on faith.** (1) **Real bug, fixed**: the new `conda_avail` check only tested
   `condabin\conda.bat`, but `run_setup.bat`'s own `:select_conda_bat` (`CONDA_MAIN`/`CONDA_ALT`)
   and the pre-existing "Validate restored conda binary" step both already treat
   `Scripts\conda.bat` as an equally valid fallback -- confirmed by reading `:select_conda_bat`
   directly (lines ~1934-1938) before fixing; an install that only landed via the fallback path
   would have made `conda-full`'s own bootstrap succeed while `conda_avail` wrongly reported
   unavailable, silently skipping every newly-gated conda-full self-test. (2) **Real, separately-
   scoped finding, extended and shipped in the same pass**: `always()` keeps a step running even
   after the WORKFLOW ITSELF is cancelled (e.g. a newer push superseding an in-flight run via this
   file's own `cancel-in-progress: true` concurrency group) -- `!cancelled()` is GitHub's own
   documented idiom for "run regardless of prior step outcome, but still respect cancellation."
   This is a real, well-established GitHub Actions semantic distinction, not specific to CI-time
   cost (which this repo's owner has separately said isn't a constraint) -- it's about not letting
   an already-abandoned run's steps keep grinding for no reason. CodeRabbit's own finding was
   scoped to 3 example steps with a note to "apply to the other long-running self-tests in this
   job"; verified this cleanly generalizes to EVERY `always()` in the `selftest` job (84 total,
   none of which hold or release any cross-run resource the way `run_setup.bat`'s own `:acquire_
   lock`/`:release_lock` does -- these are all self-contained diagnostic/self-test steps) and
   applied it uniformly via a scripted replace, not just the 3 cited examples. **A second, real
   bug surfaced during this exact fix, caught by `actionlint` before it shipped**: a bare `if:
   always()` (no `${{ }}` wrapper) is safe YAML since it starts with a letter, but a bare `if:
   !cancelled()` is NOT -- a leading `!` is a YAML tag indicator, so unquoted `!cancelled()`
   fails to parse. 17 of the 84 replacements were bare and needed wrapping in `${{ !cancelled()
   }}`; the other 67 were already inside a `${{ ... }}` compound expression and needed no extra
   wrapping. Verified via `yamllint`/`actionlint` (clean) and an exact before/after occurrence
   count (84 `always()` removed, 84 `!cancelled()` added, 0 stray edits) before committing.
   Deliberately scoped to the `selftest` job only, matching the review's own scope -- the other
   4 jobs in this file (`selftest-gate`, `ndjson-registry-check`, `model-quick-fix`,
   `publish_diag`) have 25 more `always()` occurrences between them, not touched in this pass.
   The suggested dedicated regression test for `conda_avail`'s own dual-path logic (a third
   CodeRabbit comment) was NOT implemented -- disproportionate scope for a 4-line inline check
   with an already-untested precedent in the same file (the "Validate restored conda binary"
   step's own identical dual-path pattern has no dedicated test either).

   **STATUS: gating-lane half of this item is now fully closed, including the one residual noted
   above.** 41 of the ~67 candidate steps were converted in the pass documented above (5 zero-risk
   + 36 lane-aware); the remaining 2 (`Run dynamic tests (if present)`, `Run tests (map empty repo
   to success)`) are now also `!cancelled()`-gated, closing the loop. **Correction to the original
   residual note**: it named `tests/harness.ps1`'s own two `throw` sites (missing
   `.ci_bootstrap_marker` / `~bootstrap.status.json`) as the blocker -- re-reading the actual code
   before fixing it found this was imprecise. Those two `harness.ps1` throws are reached only via
   `Run tests (map empty repo to success)`'s `cmd /c run_tests.bat` call, a genuine subprocess
   boundary: `run_tests.bat` invokes `powershell -File tests\harness.ps1` as its own process, so an
   uncaught `throw` inside it just becomes that process's exit code (captured via `%ERRORLEVEL%`,
   then `$rc`), never an uncaught exception in the CALLING GH Actions step -- that step was already
   safe to `!cancelled()`-gate exactly as-is. The REAL risk was three separate, unrelated `throw`
   statements inline in `Run dynamic tests (if present)`'s own PowerShell block (not in
   `harness.ps1` at all, and not run via a subprocess) -- `~bootstrap.status.json not found`,
   a JSON-parse failure, and `Bootstrap state '{0}' blocks dynamic tests execution`, all reachable
   for the first time once this step could run even after an earlier "Bootstrap environment"
   failure. Fixed by converting those three specifically to `Write-Host "::error::..."` + `exit 1`
   -- same final outcome (the step still fails when the precondition genuinely isn't met), just
   without an uncaught-exception stack trace obscuring the real cause. Two later, unrelated
   `throw`s in the same step (`dynamic_tests.bat`/`.py failed with exit code N`) were deliberately
   left alone -- they only fire once dynamic tests actually ran, meaning the precondition race this
   fix targets never applies to them.

   **CORRECTION, 2026-07-27 (CodeRabbit-flagged on PR #391, verified before acting): the
   `conda_avail` mechanism this item introduced (see the "shared pre-check" paragraph above) was
   itself broken from the day it shipped -- do not treat it as a working part of this item's
   history.** Its premise ("the main bootstrap step installs Miniconda first, so this check only
   ever needs to catch a genuine install failure") is false for this repo's own CI shape: the main
   "Bootstrap environment (run_setup.bat)" step runs against this repo's own empty root (the
   `no_python_files` graceful-exit path), never touches conda, and every downstream selfapps step
   capable of performing the FIRST real install was ALSO gated behind this same check -- a
   circular self-skip that silently disabled ~27 `real/conda-full`-only self-tests on every run
   since this item closed, invisible because a skipped step doesn't fail the job. See Active
   Backlog item 15 for the full diagnosis and fix (PR #391): all 36 `conda_avail`-dependent `if:`
   clauses were reverted to their pre-item-7 unconditional form, keeping only the `!cancelled()`
   half of this item's own work (which IS correct and unaffected by this correction). The
   `conda_avail` step itself remains in the file, unused, pending the re-wiring item 15 defers.

*(Item 5 from the pre-existing "cosmetic log noise/path doubling" debrief note was checked
briefly per standing instruction not to over-invest: no `--distpath`/`--workpath` override or
other structural path-doubling exists in the PyInstaller build invocation. Most likely source is
the "Build public diagnostics tree" step's own `DIAG CWD`/`DIAG ROOT`/`DIAG TREE` debug print
lines, which naturally show GitHub Actions' inherent doubled checkout path
(`.../Python_vs_Windows/Python_vs_Windows/...`) -- a runner convention, not a bug. Not chased
further.)*

- **`conda_avail`'s own gating premise was wrong for this repo's actual CI shape (Active
  Backlog item 15), and it merged (PR #390) before this was caught -- found 2026-07-27 via a
  direct owner question ("are we sure we aren't shorting conda-full?") that prompted re-checking
  real step-level conclusions instead of trusting the job's overall green status.** Item 7's
  `conda_avail` check (`id: conda_avail`, a `Test-Path` against the shared
  `%PUBLIC%\Documents\Miniconda3\condabin\conda.bat`/`Scripts\conda.bat`) was designed on
  the assumption that the earlier "Bootstrap
  environment (run_setup.bat)" step performs the first real Miniconda install for the
  `conda-full` lane, so gating ~27 downstream `real/conda-full`-restricted self-test steps on
  "is conda already on disk" would only ever skip in the rare case that install genuinely
  failed. **That assumption is false**: the "Bootstrap environment" step runs against THIS
  repo's own root (no loose `.py` files there -- it's exercising the empty-repo/
  `no_python_files` graceful-exit path, not a real target app), so it never installs Miniconda
  at all. Worse, every downstream selfapps step capable of performing the FIRST real install
  was ALSO gated behind this same `conda_avail` check -- a circular self-skip with no way to
  ever break out of it. Confirmed directly via the GitHub Actions API against the CI runs for two
  real commits on PR #390 (`efd7a5c` and `fd7a046`): all ~27 `real/conda-full`-only steps showed
  `"conclusion":"skipped"` at the identical timestamp on the `conda-full` lane in BOTH runs
  (dep-check, all 5 warnfix scenarios, pre-build collect-submodules, both hidden-import
  auto-recovery scenarios, all EXE-smokerun/PyInstaller-failure xfails, py_compile preflight,
  fast-path graceful fallback, fail-fast probe, post-execution checkpoint, super-user skip
  hooks, REQ-002 timed picker, REQ-009 cascade timed prompt, pandas/openpyxl, pip gap-fill,
  runtime.txt write-back, pyvisa detection, pyproject precedence, UX hardening). The job still
  reported overall SUCCESS both times (a skipped step doesn't fail a job), so this silent,
  100%-reproducible coverage loss on a GATING lane produced no automated signal at all and
  merged via auto-merge before it was noticed -- exactly the failure mode the owner's question
  was worried about, and the CI-time-is-free/watch-for-skips instinct behind it was correct.
  **Fix, pushed as a follow-up commit on a fresh branch (the merged PR's branch can't be reused
  per this repo's own stacking rule)**: reverted all 36 `conda_avail`-dependent `if:` clauses
  to their pre-item-7 unconditional form (`matrix.mode == 'conda-full'`, no `conda_avail`
  dependency), while KEEPING the `!cancelled()` half of each condition (the part of item 7 that
  is actually correct and validated -- it still prevents one failing step from cascade-skipping
  every subsequent step in the job). The `conda_avail` step itself is left in place, unused,
  with a comment explaining why and pointing here -- removing it outright was judged riskier
  than leaving a harmless, informational `Write-Host` step for a fix meant to land fast.
  **Deliberately not attempted in this pass: correctly re-wiring `conda_avail` to fire at a
  point where a real install has actually had a chance to happen.** The redundant-retry risk it
  was meant to prevent ("dozens of steps each independently retrying a genuinely failed,
  up-to-90-minute Miniconda install") is real in principle, but finding the right insertion
  point requires identifying which selfapps step is genuinely first to trigger a real install
  for a non-empty app under `HP_FORCE_CONDA_ONLY=1` -- multiple candidates already inspected
  (`selfapps_single.ps1`, `selfapps_entry.ps1`, `selfapps_isolation.ps1`) turned out to run under
  `HP_CI_SKIP_ENV=1` themselves (system-Python bypass, never touches conda), so this needs a
  proper trace, not a guess, before being reintroduced. Revisit as its own dedicated, reviewed
  pass -- the same "disproportionate to fold into an unrelated fix" reasoning item 7's own
  history already applies elsewhere in this list.

  **The trace this needed was completed 2026-07-27, same day, per the standing 2-hour watchdog
  mandate re-checking Active Backlog once nothing else was in-flight.** Read `batch-check.yml`'s
  full `selftest` job step order from the top and checked each step's own env/script for an
  `HP_CI_SKIP_ENV` override or a static-only check (never invokes `run_setup.bat` at all):
  `selfapps_single.ps1`/`selfapps_entry.ps1`/`selfapps_isolation.ps1` all set
  `HP_CI_SKIP_ENV: '1'` at the STEP level in the YAML itself (confirming the prior note directly,
  not just citing it); `selfapps_envname.ps1` sets `HP_CI_SKIP_ENV=1` internally in its own script
  body (a fourth candidate not previously named); `tests\selftests.ps1` (the empty-repo step)
  replays a captured log rather than re-running the bootstrapper at all (see this file's own
  "selftest.ps1 vs selftests.ps1" note); `selfapps_size.ps1` is a static byte-size check with no
  bootstrap invocation. **The genuine first candidate is `selfapps_envsmoke.ps1`** ("Self-test:
  real env smoke (CI-only)," gated only on `env.HP_CACHE_CORRUPTED != '1'`, no lane restriction
  and no `HP_CI_SKIP_ENV` override) -- its own script comment says outright "FULL bootstrap here:
  do NOT set HP_CI_SKIP_ENV," and it does `cmd /c .\run_setup.bat` against a real scratch app
  directory, genuinely exercising conda-mode install under `HP_FORCE_CONDA_ONLY=1` inherited from
  the job env. It runs immediately after the (confirmed-safe) size tripwire and immediately
  before the first `real/conda-full only`-gated self-test block (`selfapps_depcheck.ps1`) --
  i.e., right where `conda_avail` would need to move to for its premise to actually hold this
  time, instead of checking too early (the original bug) or too late.
  **Decision: do not re-implement the gating a third time without explicit owner sign-off,
  despite having the answer this section asked for.** Two real, independently-discovered bugs
  have already come out of this exact mechanism in close succession (the original premature-gate
  bug this whole entry documents, plus a distinct CodeRabbit-caught wording slip on the very PR
  that reverted it) -- both subtle, both missed on first read, both only caught via careful
  after-the-fact scrutiny. A third attempt at gating steps in the two GATING lanes
  (`real`/`conda-full`, explicitly must-not-regress territory) on a new `conda_avail`-at-a-new-
  position mechanism carries real risk of a third, differently-subtle mistake in the same fragile
  spot, and the value it buys is a bounded-but-unobserved worst case: no genuine Miniconda
  install failure (as opposed to a transient blip already covered by REQ-022's own retry
  hardening) has actually been hit in this repo's real CI history despite extensive documented
  usage. Per this file's own standing instruction to escalate architecturally-significant,
  already-burned-twice decisions rather than re-attempt them silently a third time: this is left
  here, fully traced and ready to implement in a single well-scoped commit (move the existing,
  currently-unused `conda_avail` step to right after `selfapps_envsmoke.ps1`, re-point the same
  36 `if:` conditions at it), pending the owner's explicit go-ahead.

  **Owner explicitly authorized proceeding ("if confident then implement or register open
  question," same day) -- split into two staged PRs rather than one shot, since one shot is
  exactly the pattern that produced both prior bugs.** Step 1 (this commit): moved the existing
  `conda_avail` step from right after "Bootstrap environment" to right after "Self-test: real env
  smoke (CI-only)" (`selfapps_envsmoke.ps1`) -- **deliberately left completely unwired, zero `if:`
  conditions reference it yet.** A genuinely new wrinkle surfaced mid-implementation, worth
  recording since it wasn't visible from the trace alone: in the ORIGINAL (buggy) design,
  `selfapps_envsmoke.ps1` itself was one of the 9 "every non-corrupted lane" steps gated behind
  `conda_avail` -- but envsmoke is now the PRODUCER of the signal this step reads, not a consumer,
  so it must stay unconditional (`!cancelled() && env.HP_CACHE_CORRUPTED != '1'`, no `conda_avail`
  clause) or the exact same circularity would return in a new spot. The other 8 steps in that
  "every lane" category (empty-repo, single-entry, entry-selection, isolation, env-name, reqspec,
  UX-hardening, system-Python-consent) are likewise NOT candidates for the gate going forward --
  the real target is specifically the 27 steps already enumerated above as "silently skipped"
  (22 `real/conda-full` + 5 `conda-full`-only), which all sit after envsmoke in file order.
  Landing the corrected POSITION on its own first, with nothing depending on it, lets the very
  next `conda-full` CI run prove (via its own step log) that `available` now correctly flips to
  `'true'` once envsmoke's real install succeeds -- before any gating logic is re-added in a
  follow-up commit. Watch that first run closely before proceeding to step 2 (wiring the 27
  conditions).

  **First real `conda-full` run watched, 2026-07-27 (PR #395's merge run, run 30266482736):
  confirmed positive.** Downloaded the `ci_test_results-selftest-conda-full-30266482736-1`
  artifact directly (not just the console log) and read the `diag.conda.available` NDJSON row:
  `{"id":"diag.conda.available","pass":true,"desc":"Miniconda availability diagnostic
  (non-gating, unwired)","details":{"available":true}}` -- `available` flips to `true` exactly as
  predicted, confirming the relocated step's premise now genuinely holds in this repo's real CI
  shape. **This is read-only verification only, not authorization to proceed to step 2.** The
  owner's explicit go-ahead already covered (and was scoped to) step 1's move; step 2 (wiring the
  27 `if:` conditions) still needs its own separate, explicit go-ahead per the reasoning above --
  two independent bugs from this exact mechanism is reason enough to keep that a deliberate,
  owner-confirmed step rather than something a single green run alone unlocks.

  **Step 2 shipped, 2026-07-27, owner-directed with full rigor after a detailed risk-vs-benefit
  assessment posted in chat.** The owner's own framing: "yes default to fail CI if any problem
  for loud notification even if it isn't necessarily the fault of things we control." Two pieces
  shipped TOGETHER, deliberately never one without the other -- shipping the gate alone would
  reintroduce exactly the PR #390 risk (a wrong condition silently skips real tests while the job
  stays green):
  - The 27 `real/conda-full`/`conda-full`-only steps now gate their conda-full half on
    `steps.conda_avail.outputs.available == 'true'` (skip fast instead of each independently
    retrying a doomed sub-bootstrap).
  - A new paired step, "Enforce Miniconda availability" (`id: conda_avail_gate`), runs
    immediately after `conda_avail` in every non-cache-corrupted lane (skip=true outside
    conda-full; both steps are skipped, like everything else in the job, on the rare
    `HP_CACHE_CORRUPTED=1` path) and unconditionally FAILS the job (`Write-Host '::error::...'`
    + `exit 1`, no
    `continue-on-error`) whenever `available` is anything other than `'true'` in conda-full --
    deliberately without trying to distinguish "genuine Miniconda install failure" from "a bug in
    this gating mechanism itself." On failure it also prints the tail of
    `tests\~envsmoke\~envsmoke_bootstrap.log` inline for immediate root-cause visibility.
  - **A key fact that shaped the final design, found by re-reading `tests/selfapps_envsmoke.ps1`
    before implementing rather than assuming**: a GENUINE Miniconda install failure already
    independently fails the "Self-test: real env smoke (CI-only)" step's own `self.env.smoke.conda`
    NDJSON row TODAY, with no changes needed -- `$bootstrapPass` requires a clean interpreter,
    successful entry-run, PyInstaller output, AND the absence of any `[ERROR]` line in the
    bootstrap log, not just a zero process exit code (which the file's own `:die`-exit-code
    lessons-learned entry already warns is not by itself reliable evidence of success). This means
    the tripwire's genuinely NEW protection is narrower and more precise than "catch Miniconda
    failing" -- it specifically catches a bug in the gate/tripwire mechanism ITSELF (wrong lane,
    wrong step id, wrong output name, a GH Actions expression typo) that could cause the 27 steps
    to skip even when conda_avail's own check is working correctly. The genuine-failure case still
    gets caught too (belt-and-suspenders, via an independent signal -- `Test-Path` on disk vs.
    parsing bootstrap log text -- rather than relying on the log-parsing signal alone), exactly
    per the owner's "default to fail CI if any problem" direction.
  - **Recovery-mechanism exploration, per the owner's own ask ("if there is any more proactive
    recovery mechanism... to make the benefit more worth it").** Traced what already exists
    entirely inside `run_setup.bat`'s own single invocation (i.e. within ONE call to
    `selfapps_envsmoke.ps1`): AllUsers -> JustMe Miniconda install fallback (`:tci_justme`),
    REQ-022's transient-network detect-and-retry for `conda create`/bulk install, REQ-013's
    connectivity-aware retry (recently hardened, see this doc's own Closed Backlog entry), a
    secondary Miniconda download URL, and Active Backlog item 14's own bounded (60-minute)
    installer timeout so a hung installer can't hang forever. **Decision: did NOT add a
    CI-orchestration-level retry (e.g. wrapping the whole envsmoke step in a re-run-on-failure
    action).** Two reasons: (1) no genuine Miniconda install failure has ever been observed in
    this repo's real CI history despite extensive documented usage (the one related incident --
    a `conda.anaconda.org` 403 -- was already a transient network blip, already covered by REQ-022's
    own retry, not an install failure) -- the marginal benefit of a SECOND retry layer on top of an
    already-comprehensive one is small against a problem that has not actually materialized; (2) a
    CI-level auto-retry that silently succeeds on its second attempt would REDUCE signal quality by
    smoothing over a real transient issue instead of surfacing it, which cuts directly against the
    owner's own stated preference for loud, attributable failure even when "not our fault." The
    lower-risk, genuinely additive piece of "more proactive" WAS shipped instead: the tripwire's
    own diagnostic-log-tail printing (above), which makes whichever failure DOES occur maximally
    actionable without extra digging, at zero new control-flow risk (pure read-only enrichment).
  - **No genuinely blocking open question was found while implementing this** -- confirmed via a
    full manual trace of all 27 target `if:` conditions (diff-scope-verified: exactly 27 lines
    changed, matching the enumerated step names one-for-one) plus `yamllint`/`actionlint`, both
    clean. Nothing added to `docs/open-questions.md`.
  - **STATUS: item 7 is now fully closed, gating-lane half included.** Real-CI confirmation that
    the gate correctly reads `true` in a normal conda-full run, and correctly fails loud in a
    genuinely-broken one, is the one thing that could not be verified locally -- watch the next
    conda-full run closely, and specifically confirm the OLD-style circular-self-skip failure mode
    (PR #390) cannot recur even if some future edit accidentally reintroduces it, since it would
    now hard-fail instead of silently passing.
  - **The watch-closely follow-up landed clean, 2026-07-28 (PR #398's own merge-commit run,
    30324080455): `conda_avail` read `available: true`, `conda_avail_gate` passed, and all 15
    checks including `conda-full` (~1h34m, normal duration) completed with conclusion `success`
    -- no circular-self-skip regression, no unexpected step skips, no fallout from PR #398's own
    NDJSON-schema change (adding a top-level `lane` field to the two new rows).** This is the
    real-CI proof the item's own status note above was waiting on; nothing further is pending
    for item 7.

---

### Item 16 (closed 2026-07-31; moved here same pass; renumbered from 11)

**Renumbered from 11 to 16 when moving here** -- this finding was originally filed in CLAUDE.md's
Active Backlog as "item 11," but that number was already permanently retired by the older
"Hidden-import auto-recovery exhaustion coverage" entry in this file's own Closed Backlog section
below (closed 2026-07-25, still correctly cited as "item 11" by `docs/agent-ndjson.md`'s
`self.exe.hidden_import.exhaust` entry) -- a genuine number reuse that must have slipped in when
this finding was first logged. Renumbered to 16 and 17 respectively (see the sibling entry right
after this one) -- the next two numbers never used anywhere in this repo's docs -- rather than
leaving the collision in place; no other doc referenced this finding as "item 11" before this
move, so the renumber is clean. **This is one instance of a wider, unrelated bug** -- see the new
Active Backlog entry filed in the same pass for the full scope (items 8, 9, 10, 12, 13, 14, and 15
all appear to reuse numbers already retired the same way; only 9 and 11 were actually renumbered
here, since those were the two items this pass touched for unrelated reasons).

- **`:tci_justme`'s `[WARN] Miniconda AllUsers install failed; retrying with JustMe.` log line
   fired unconditionally, even when AllUsers was never actually attempted -- found 2026-07-29
   while documenting the Miniconda install chain for `docs/demo-bootstrapper-output.md`'s Part VI,
   flagged by a CodeRabbit review on PR #401 and verified against real CI evidence and the actual
   `run_setup.bat` source before acting.** `:try_conda_install` has three distinct paths into the
   shared `:tci_justme` label: (a) `HP_TEST_NOT_ELEVATED=1` (test-only, simulates a non-admin
   environment) skips straight to `:tci_justme` with no AllUsers attempt at all; (b) a real
   `fsutil dirty query %systemdrive%` failure (the genuine non-elevated-process detection) does
   the same; (c) a real, genuine AllUsers installer failure (`:run_installer_timeout` returning
   nonzero) also falls through to `:tci_justme`. All three paths logged the identical
   `[WARN] Miniconda AllUsers install failed; retrying with JustMe.` line at `:tci_justme` itself,
   regardless of which path got there -- so on the common non-elevated real-world machine (paths a
   or b), the WARN text was a misnomer: AllUsers was never launched, only skipped, yet the log
   claimed it "failed." Confirmed directly against real CI capture (run `30328748330`, `justme-test`
   and `uv` lanes): both the `[INFO] Not elevated; skipping AllUsers Miniconda install.` line and
   the `[WARN] ... AllUsers install failed ...` line appeared back-to-back for the identical
   non-elevated test run, with no genuine AllUsers attempt in between.
   **Fixed 2026-07-31.** `:try_conda_install` now sets `HP_CONDA_ALLUSERS_ATTEMPTED=1` (reset
   defensively at subroutine entry) immediately before the real AllUsers install attempt, and
   `:tci_justme` branches its log line on whether that flag is defined: the genuine-failure path
   keeps the original WARN wording (now also carrying the installer's own exit code and a reason
   token -- `exitCode=%HP_CONDA_ALLUSERS_RC%, reason=installer_failed`, captured immediately after
   `:run_installer_timeout` returns, per a CodeRabbit review comment on this same PR asking that
   external/environmental failures be made explicit in logs rather than left as a bare "failed"),
   while both skip paths now log
   `[INFO] Miniconda AllUsers install skipped (not elevated); trying JustMe install instead.`
   instead. The same review pass also caught that `:tci_both_failed`'s own terminal `:die` message
   had the identical problem one level up -- "Miniconda install failed (both AllUsers and JustMe)"
   still implied AllUsers was genuinely attempted-then-failed even when it was only ever skipped;
   fixed with the same `HP_CONDA_ALLUSERS_ATTEMPTED` branch, producing
   "Miniconda install failed (AllUsers skipped -- not elevated; JustMe also failed)" for the
   skip-path case and leaving the original wording for a genuine double-failure. Confirmed safe
   against all three existing tests that reach this code path (`tests/selfapps_justme.ps1`,
   `tests/selfapps_conda_bothfail.ps1`) -- updated `selfapps_conda_bothfail.ps1`'s own assertion
   to match the new terminal wording (it always sets `HP_TEST_NOT_ELEVATED=1`, so it exercises the
   skip-path terminal message specifically). Added a new regression assertion to
   `tests/selfapps_justme.ps1` (`skippedWordingCorrect`/`failedWordingAbsent`, checked against the
   envsmoke-scoped log rather than the combined root+envsmoke text a second CodeRabbit comment
   flagged as a staleness risk for a negative assertion) confirming the new INFO wording fires and
   the old WARN wording does NOT, in the non-elevated simulation this test already runs.
   **Follow-up fix, 2026-07-31 (same day, a later CodeRabbit review round on the follow-up PR):**
   the genuine-failure WARN's `exitCode=%HP_CONDA_ALLUSERS_RC%` was itself sometimes a fabrication
   -- `HP_CONDA_ALLUSERS_RC` is captured straight from `:run_installer_timeout`'s own return value,
   which that subroutine's own header comment documents as "the installer's real exit code (or 1
   on timeout)": on a genuine 60-minute installer timeout, `HP_CONDA_ALLUSERS_RC` reads `1` as a
   pure sentinel, not a real exit code, so the WARN was presenting a fabricated `exitCode=1` as if
   the installer itself had returned it. Fixed by no longer clearing `:run_installer_timeout`'s own
   `HP_INSTALLER_TIMEDOUT` flag before it returns (each call re-sets it fresh at entry regardless,
   so leaving it live across `exit /b` is safe -- no caller can read a stale value from an earlier,
   unrelated call), capturing it into a new `HP_CONDA_ALLUSERS_TIMEDOUT` variable right alongside
   `HP_CONDA_ALLUSERS_RC`, and branching `:tci_justme`'s genuine-failure WARN a second time on it:
   `reason=timeout` with no `exitCode` field on a real timeout, the existing
   `exitCode=..., reason=installer_failed` wording otherwise. `tests/selfapps_justme.ps1`'s own
   `failedWordingAbsent` negative assertion was separately found to have silently degraded into an
   assertion that could never fail: it matched the OLD, pre-exitCode-annotation exact sentence
   (`Miniconda AllUsers install failed; retrying with JustMe.`), which no longer appears anywhere
   verbatim now that the WARN always carries an `exitCode=.../reason=...` or `reason=timeout`
   suffix -- fixed to match the stable `Miniconda AllUsers install failed` prefix instead, so it
   once again actually catches a skip-path regression to any failure-wording variant. No CI hook
   can force a genuine timeout deterministically (would need a real 60-minute hang or a dedicated
   fake-timeout test hook, neither built here), so the timeout branch itself remains
   `[Extrapolated Branch]`-only in `docs/demo-bootstrapper-output.md`, same status as the
   genuine-failure branch it refines.

---

### Item 17 (closed 2026-07-31; moved here same pass; renumbered from 9)

**Renumbered from 9 to 17 when moving here** -- filed in CLAUDE.md's Active Backlog as "item 9,"
but that number was already permanently retired by the older "Cascade-vs-postexec fix" entry in
this file's own Closed Backlog section below (closed 2026-07-25, still correctly cited as
"item 9" by both `docs/agent-ndjson.md` and `docs/agent-interconnect.md` -- both auto-loaded into
every session). Nothing outside CLAUDE.md's own now-removed entry referenced this finding as
"item 9," so the renumber is clean (see the preceding item's own header for the wider collision
this belongs to).

- **README.md's `[REQ-018]` bullet describing the mandatory verification run as
   "force-stopped after a short interval even if running fine" was stale relative to the
   activity-aware-kill behavior actually shipped later -- found 2026-07-29 via a CodeRabbit review
   comment on PR #400 that (correctly) flagged a possible mismatch between README's REQ-018 prose
   and `docs/demo-bootstrapper-output.md`'s new Scenario 11.** Traced it down: the real, current
   WARN text (quoted verbatim in Scenario 10 from a real CI capture) said the opposite of what
   README claimed -- "if it stays completely silent for about 30 seconds it will be
   force-stopped, but any output (including a prompt waiting on your input) keeps it running as
   long as needed" -- matching this file's own "Activity-aware EXE-smoke kill
   (docs/plan-cli-interactive-verification.md P0, requirement 3) -- resolves Open Question 1"
   entry below. That feature shipped after README's REQ-018 section was last written and the
   corresponding bullet was never updated to match.
   **Fixed 2026-07-31**, in the same pass as the bottom-up console-message audit: the bullet now
   reads "Verifying a fresh build is activity-aware and announced," describes the actual
   silent-vs-any-output condition, and separately notes that the narrower re-verification inside
   the `--hidden-import` auto-recovery loop remains unconditionally time-boxed (unaffected by this
   fix, by design -- see this file's own entry on that loop for why). No behavior changed; this
   was a documentation-only correction.

### Item 8 (closed 2026-08-01)

- **`[WARN] UNC paths not supported` fired unconditionally in CI on an ordinary (non-UNC) local
   path -- found 2026-07-29 while gathering real console-output evidence for
   `docs/demo-bootstrapper-output.md`'s default-happy-path documentation pass, not investigated
   further at the time.** The unlabeled prologue in `run_setup.bat` did
   `echo %~dp0 | findstr /C:"\\\\" >nul` / `if not errorlevel 1 echo [WARN] UNC paths not
   supported` -- its exact internal parsing (how `findstr`'s own additional backslash-doubling
   behavior interacts with cmd.exe's own C-runtime backslash-before-quote argument parsing,
   documented in `docs/agent-lessons-learned.md`) was never independently verified; what WAS
   confirmed empirically is that it did not correctly gate on a UNC prefix (that's the separate,
   independent check two lines below, `if "%HP_SCRIPT_LAUNCH_DIR:~0,2%"=="\\"`, which prints the
   louder `*** WARNING: UNC/network paths detected...` banner). Confirmed firing as the very FIRST
   line of console output across 6
   lanes of a real clean CI run (`30328748330`) against an entirely ordinary checkout path
   (`D:\a\Python_vs_Windows\Python_vs_Windows\tests\~envsmoke\`) -- not a UNC path by any
   reasonable definition. No test anywhere referenced this string (confirmed via a repo-wide
   grep), so this had apparently been firing on every single CI run, unnoticed, indefinitely.
   **Root cause of the double-backslash was never identified** (the companion, correctly-targeted
   `HP_SCRIPT_LAUNCH_DIR:~0,2` check never fired in the same logs, ruling out "the whole checkout
   path is UNC" but not pinning down what actually produced it -- possibly something in how
   GitHub-hosted Windows runners provision the `D:\a\...` work directory). Whether this also fired
   for a genuine end-user double-click on an ordinary local folder was likewise never confirmed
   (no Windows machine available to test, no end-user report either way).
   **Fixed 2026-08-01, without needing the root cause.** The broken check was simply removed --
   the companion check two lines below it already does the real, correctly-targeted UNC-prefix
   detection, so the broken/redundant line added nothing worth repairing. Updated
   `docs/demo-bootstrapper-output.md`'s explanatory paragraph (which had documented this as an
   "unexplained anomaly") to note the fix and why root-causing the double-backslash became moot;
   left the real, timestamped console captures containing the old WARN line unedited, since they
   are historical record of a run that genuinely happened. No test needed updating (none
   referenced the removed line), and no other call site in `run_setup.bat` depends on it.

### Item 14 (closed 2026-08-01)

- **Total REQ-009 provider-tier exhaustion produced a MISLEADING "your program has a syntax
   error" final message instead of surfacing the real "no Python interpreter found" cause -- found
   2026-07-31 while sweeping `run_setup.bat` line-by-line for `docs/demo-bootstrapper-output.md`
   coverage gaps, confirmed against real CI evidence and the actual source, not just theorized.**
   `:after_env_mode_selection`'s own guard (`run_setup.bat`, right after
   `:conda_base_update`/`:emit_from_base64 "~prep_requirements.py"`) did
   `if not defined HP_PY ( call :die "[ERROR] Active Python interpreter not resolved." )` -- but
   per this file's own long-documented `:die` semantics (`exit /b` inside `:die` only returns from
   `:die`'s OWN call frame, never halts the calling code), execution fell straight through to the
   very next line regardless: `echo Interpreter: %HP_PY%` (printing a blank interpreter path),
   then an `"%HP_PY%" -c "print('py_ok')" ... || call :log "[WARN] Interpreter smoke test failed
   (continuing)."` that silently downgraded the failure to a WARN and continued. The bootstrap
   then proceeded through pipreqs, dependency install, the pyvisa check, and entry selection --
   all effectively no-ops against an empty interpreter path -- and finally reached
   `:preflight_compile` (REQ-021), whose `"%HP_PY%" -m py_compile "%HP_ENTRY%"` became a literal
   `"" -m py_compile "app.py"` with `HP_PY` empty. cmd.exe cannot execute an empty-quoted command
   name, producing `'""' is not recognized as an internal or external command, operable program or
   batch file.` -- a CMD.EXE ERROR, NOT A PYTHON TRACEBACK -- which `:preflight_compile`
   unconditionally reported as
   `*** [ERROR] REQ-021: Your Python program has a syntax error and cannot run. ***`.
   **Confirmed via real CI capture** (run `30328748330`, `real` lane, job `90179708091`,
   `tests/~selftest_embed_decline/`'s own sub-bootstrap -- a test that force-fails EVERY provider
   tier via `HP_TEST_FORCE_EMBED_FAIL`/`HP_TEST_FORCE_VENV_FAIL`/declined system-Python consent,
   deterministically reproducing total exhaustion). **This was a real, non-test-only reachable
   scenario**: README's own REQ-009 table already documents that falling through three-plus tiers
   in one run is "almost always one shared root cause" (no internet, full disk, or a locked-down
   managed image) -- a real user with no connectivity, no working ambient Python, and who declines
   the REQ-014 system-Python prompt hits this identical path for genuine, non-test reasons.
   `~bootstrap.status.json`'s machine-readable `state` field was never affected (`:die`'s own
   unconditional `HP_BOOTSTRAP_STATE=error` set already applied before the fall-through) -- only
   the human-readable console text was misleading.
   **Fixed 2026-08-01.** `:after_env_mode_selection`'s guard now also sets `HP_NO_INTERPRETER=1`
   before calling `:die` (deliberately did NOT attempt the deeper "make the guard a goto-based
   hard stop" refactor the original finding floated as the more robust alternative -- judged
   disproportionate risk for this fix, since it would require tracing every call-stack depth
   `:after_env_mode_selection` can be reached from, including REQ-009 cascade re-entry). Instead,
   `:preflight_compile` checks `HP_NO_INTERPRETER` first and, if set, reports the real cause
   (a self-contained "No Python interpreter is available; your program was not run or built...
   Either every automatic Python-acquisition method -- uv, conda, a fresh download, or a local
   virtual environment -- failed... or a PVW_PYTHON_EXE override points at a path that does not
   run" message) instead of running `py_compile` against an empty interpreter path, sets
   `HP_PREFLIGHT_FAILED=1`, and returns -- which also means `:run_entry_smoke`'s pre-existing
   `HP_PREFLIGHT_FAILED` check skips the doomed PyInstaller build attempt entirely, not just the
   misleading message. Verified: no test in the repo asserted on the old misleading text
   (confirmed via grep) -- the one test reaching this code path, `self.embed.fallback.decline`,
   gates on the embed-attempt/forced-failure log lines, their relative order, and `state: error`,
   none of which this fix touches; the genuine syntax-error path (`tests/selfapps_preflight.ps1`)
   is untouched since it never sets `HP_NO_INTERPRETER`. `tests/harness.ps1`'s
   `batch.preflight.compile` static check (subroutine + call site + `py_compile` + REQ-021
   message + `HP_PREFLIGHT_FAILED` guard, all presence-only) still passes unchanged.
   **A genuine batch-syntax regression shipped in the first version of this fix, caught by real CI
   before merge (same PR, commit `fd52a3f`), not caught by any local check first.** The first
   wording of the new echo block split one logical parenthetical across two `echo` lines --
   `(uv, conda, a fresh download, a` on one line, `local virtual environment) failed -- ...` on
   the next -- both lines sitting inside the enclosing `if defined HP_NO_INTERPRETER ( ... )`
   parenthesized block. cmd.exe's block parser counts every `(`/`)` character in a parenthesized
   block's text, including inside plain `echo` statements, regardless of intent -- it does not
   understand "this is prose, not block structure." The `)` on the second line was read as
   prematurely closing the `if` block, and the very next token, `failed`, was then parsed as a
   stray top-level command, producing `failed was unexpected at this time.` -- a real cmd.exe
   parse error, not a test flake. Because this fires the moment `HP_NO_INTERPRETER` is set
   (declined/exhausted-provider paths, and the companion canary-probe hardening below), it broke
   every CI lane whose own self-tests ever reach that state in the same run: `uv`,
   `contract-uv`, `contract-uv-fail`, `uv-dl-fallback`, `cache`, and `justme-test` all failed on
   the same commit. `python tools/check_delimiters.py run_setup.bat` did NOT catch this --
   confirmed a real gap: the checker's paren-balance logic does not currently walk `echo` text
   inside a block the same way cmd.exe's own parser does. Root-caused by downloading the real
   `uv`-lane job log via `mcp__github__get_job_logs` (pre-signed blob URL, `curl`'d directly to
   bypass tool-side truncation on a ~15K-line log) and tracing the exact byte offset where
   `failed was unexpected at this time.` appeared, immediately after the `[BOOT] REQ-002: Entry
   selected:` log line -- confirming it was `:preflight_compile`'s own new block, not something
   unrelated. **Fixed by rewording the message to avoid any `(`/`)` character entirely** (dashes
   instead of parenthetical asides) rather than escaping the parens with `^` -- simpler and more
   robust against a future re-wrap of the same prose reintroducing the same hazard. This is the
   same general hazard class `docs/agent-lessons-learned.md`'s batch-syntax-quirks section already
   warns about for other constructs (parse-time `%VAR%` expansion, `:log`'s unquoted echo) but had
   not yet been documented specifically for literal parens split across `echo` lines inside a
   block -- worth adding there if a future instance recurs.

### Item 19 (closed 2026-08-01)

- **The `cache` CI lane's corruption recovery was a one-way trap: once a restored cache was
   flagged corrupted, nothing in that lane ever produced a fresh, valid cache again -- found
   2026-07-31 while investigating a maintainer report that the lane "never works," always logging
   `Cache corrupted, skipping fast-path tests (HP_CACHE_CORRUPTED=1)`, confirmed against the
   `.github/workflows/batch-check.yml` source, not just the symptom report.** Traced the full
   mechanism: the cache key is `win-...-conda-${{ hashFiles('run_setup.bat') }}-<pipreqs_ver>`
   with `restore-keys: win-...-conda-` as a prefix fallback. `run_setup.bat` changes on nearly
   every PR in this repo, so the EXACT primary key rarely matched twice -- the restore step almost
   always fell through to the `restore-keys` PREFIX match instead, which returns whatever cache
   blob currently exists under that prefix (GitHub Actions cache entries are immutable once saved;
   a "stale" blob can only be replaced by a NEW save under a NEW key, never overwritten in place).
   The "Validate restored conda binary" step (`cache_health`) then ran `conda.bat info` against
   whatever got restored; on failure it set `HP_CACHE_CORRUPTED=1` unconditionally. The trap was
   downstream: the "Bootstrap environment (run_setup.bat)" step -- the ONLY step in this lane
   capable of performing a fresh Miniconda install -- was gated on `env.HP_CACHE_CORRUPTED != '1'`,
   so once corruption was flagged, bootstrap was SKIPPED ENTIRELY for that run; no fresh install
   was ever attempted. The save step (`actions/cache/save`) was gated on BOTH
   `steps.conda_cache_restore.outputs.cache-hit != 'true'` AND `env.HP_CACHE_CORRUPTED != '1'` --
   since a `restore-keys` prefix match reports `cache-hit: false`, the `cache-hit` half of the
   save gate was usually already satisfied when corruption was the actual blocker -- the
   `HP_CACHE_CORRUPTED` half is what stopped the save. Net effect: the SAME poisoned blob (saved
   once, likely before this health-check mechanism existed, or from a one-off flake) got restored
   via the prefix fallback on every subsequent run, was correctly detected as corrupted every
   time, but the detection itself prevented the one action (a fresh install this run, followed by
   a fresh save) that would ever replace it -- a permanent, self-perpetuating loop with no exit,
   fully consistent with "never works, always says corrupted." Confirmed this was real, not a
   one-off: every `if:` gate on the lane's ~25 self-test steps after "Bootstrap environment"
   already depended on `HP_CACHE_CORRUPTED != '1'`, so once corrupted, the entire lane
   short-circuited to placeholder `pass:true, skip`-style NDJSON rows (`self.cache.corrupted`) and
   reported overall green -- exactly why this had been invisible in CI.
   **Fixed 2026-08-01, on maintainer instruction not to hold this back for dedicated multi-cycle
   verification** -- since `cache` is one of the 8 matrix lanes that runs on every future PR
   regardless of subject, ordinary subsequent work already re-exercises it, so no dedicated
   verification loop is needed (the earlier "needs multiple real cache-lane CI cycles" concern in
   `docs/open-questions.md` overweighted the cost of a *dedicated* effort that isn't actually
   required). Implemented the fix already reasoned through when this item was filed: the
   "Validate restored conda binary" step now reads `steps.conda_cache_restore.outputs.cache-hit`
   (passed in via an env var, `HP_CACHE_EXACT_HIT`, to avoid GitHub Actions expression
   interpolation directly into the PowerShell script body) and branches on it. On an EXACT
   primary-key hit that's corrupted, behavior is unchanged (`HP_CACHE_CORRUPTED=1`, skip this run)
   -- that narrower case genuinely cannot be fixed without an explicit cache-deletion API call
   (`gh cache delete` / `DELETE /repos/{owner}/{repo}/actions/caches`), left as a smaller,
   not-yet-implemented follow-on. On a `restore-keys` PREFIX match that's corrupted (the common
   case), the stale `C:\Users\Public\Documents\Miniconda3` directory is now deleted and
   `HP_CACHE_CORRUPTED` is NOT set, letting the run fall through exactly like a genuine cache miss
   -- "Bootstrap environment" then runs a real fresh install, and the save step creates a
   genuinely fresh, valid cache entry under the current key afterward, breaking the loop. Guarded
   against the same AV/indexer file-lock hazard class already documented elsewhere in this repo
   for `:try_embed_fallback`'s own directory swap in `run_setup.bat`: if `Remove-Item` doesn't
   fully clear the directory, the fix falls back to the original safe `HP_CACHE_CORRUPTED=1`
   skip-this-run behavior rather than proceeding into an uncertain half-deleted state. Verified
   `python -m yamllint` and `actionlint -oneline` both clean on the modified workflow file before
   landing; the actual "does a fresh cache finally get saved" effect will be observed
   opportunistically across this and future PRs' own `cache`-lane runs, not via a dedicated
   verification loop.

   **Follow-on shipped 2026-08-02, prompted by the owner directly asking "is the fix holding" and
   then "make it go red so it actually helps something."** The "observed opportunistically" plan
   above turned out to have two real gaps, both found while answering the first question
   honestly rather than assuming: (1) verification meant manually pulling raw job logs each time
   -- nothing queryable recorded whether a run's self-heal had actually fired (a corrupted
   restore-keys-prefix-match cache with a successful heal never sets `HP_CACHE_CORRUPTED`, so no
   NDJSON row was ever emitted for it -- the only trace was a `::warning::` buried in the log);
   (2) even a hypothetical step-level failure inside the `cache` lane could never have surfaced as
   a real CI failure, because that whole lane is job-level `continue-on-error` (see the top of
   `batch-check.yml`) -- confirmed directly against the first real post-fix run (`30684739923`,
   job `91328449387`, commit `40e6187`/PR #409): the corrupted-prefix-match branch fired for real
   (`##[warning]Conda binary health check failed (exit=1) on a restore-keys prefix match; deleting
   stale cache directory and proceeding as a fresh install.` at 04:55:51Z, `Stale cache directory
   removed; fresh install will proceed normally.` at 04:56:21Z, `Cache saved with key:
   win-Windows-py311b-conda-...` at 05:16:43Z) -- genuine end-to-end proof the fix works, found
   only by pulling the raw log by hand, not by anything CI itself surfaced.
   - Extracted the inline health-check-and-heal PowerShell out of `batch-check.yml`'s "Validate
     restored conda binary" step into `tools/ci_cache_selfheal.ps1`, a small parameterized script
     (`-CondaDir`, `-ExactHit`) with 4 distinct exit codes (0=healthy/no-op, 1=exact-hit-corrupted
     [unchanged accepted gap], 2=prefix-corrupted-and-healed, 3=prefix-corrupted-heal-FAILED --
     the new case: the stale directory could not be fully cleared, meaning this fix has regressed
     back toward its own pre-fix trap).
   - Added `tests/test_ci_cache_selfheal.ps1`: a deterministic regression test exercising all 4
     exit codes against a scratch temp directory with fake `conda.bat` stand-ins (including a
     genuine locked-file reproduction of the heal-FAILED case via a held `FileStream` handle) --
     no dependency on GitHub's cache ever being organically corrupted. Wired into the `real`
     lane specifically (a GATING lane, not in the job-level `continue-on-error` list), so a future
     regression in this logic fails CI for real, unlike the ambient `cache` lane which cannot.
     Windows-only (shells out to `conda.bat` via `cmd.exe`; the lock scenario needs Windows
     file-locking semantics), matching this repo's usual `$IsWindows`-gated-skip convention.
   - Added `self.cache.selfheal.fired`: an always-`pass:true` visibility row emitted by the
     ambient `cache` lane itself whenever the self-heal branch is entered (success or failure),
     recording the real outcome in `details.healed` -- closes gap (1) above; an organic
     occurrence is now queryable on the diagnostics site instead of requiring a raw-log dig.
   - Added a loud `::error::` tripwire step (`Enforce cache self-heal success`) for the
     heal-FAILED sub-case specifically, mirroring `diag.conda.available.gate`'s established
     "default to a loud failure, not a silent one" pattern -- explicitly documented as *not* a
     substitute for the gating test above (still absorbed by the `cache` lane's own job-level
     `continue-on-error`), only a clearer annotation than the `::warning::` it replaces for that
     one case.
   - Deliberately did NOT flip the `cache` lane itself to gating, and did NOT touch the still-open
     exact-key-hit-corrupted gap (still needs the `gh cache delete`/cache-deletion-API follow-on
     noted above) -- both out of scope for this pass; the ask was specifically "make a regression
     in the self-heal mechanism visible and blocking," not "make ordinary organic cache flakiness
     block PRs."

### Item 15 (closed 2026-08-01)

- **`:exe_smokerun_hints`'s diagnostic re-run of a freshly-failed EXE had no timeout, unlike every
   other user-code launch point in `run_setup.bat` -- found 2026-07-31, flagged by a CodeRabbit
   review on PR #402, fixed 2026-08-01.** `:exe_smokerun_hints` did `pushd dist` then
   `"%ENVNAME%.exe" > "~exe_out.txt" 2>&1` with no `.NET Process`/`WaitForExit(ms)`/`Kill()`
   wrapper at all -- a plain, synchronous, unbounded invocation. Every other user-code/EXE launch
   point in the file (`:run_exe_smokerun`'s primary verification, `:run_failfast_probe`'s three
   call sites, `:hidden_import_recover`'s own repair-check re-run) is deliberately bounded, either
   by the ~30s hard-kill ceiling or by the fail-fast-probe's classify-then-never-kill design. The
   call site's own guard (`if not "%HP_EXE_EXIT%"=="-1" call :exe_smokerun_hints`) only confirms
   the FIRST launch (inside `:run_exe_smokerun`) exited with a real, non-hang code -- it says
   nothing about whether the SAME program behaves identically on this SECOND, separate launch a
   few lines later. Any non-determinism (a race, an env check that sometimes succeeds, anything
   that occasionally blocks on inherited stdin) could hang this second, untimed invocation and
   hang the whole bootstrap, even though the FIRST invocation legitimately classified as "fast,
   real, non-hang failure."
   **Fixed** with a new dedicated helper, `tools/exe_hint_rerun.ps1` (embedded as
   `HP_EXE_HINT_RERUN`, following the standard `sync_payload.py`/`emit_from_base64` embedded-helper
   convention) -- deliberately NOT a reuse of `~exe_smokerun.ps1`'s activity-aware kill philosophy
   (which skips the kill once any output has been observed, correct for a REAL verification run
   worth waiting on indefinitely). This re-run is diagnostic-only, never shown live to the user, so
   the new helper kills UNCONDITIONALLY at its deadline (`HP_HINT_RERUN_KILL_MS`, default 10000ms
   -- a diagnostic capture on an already-failed run does not need the full 30s primary-verification
   budget; test-only override, mirroring `HP_SMOKERUN_KILL_MS`'s established pattern). Output is
   written as ONE combined stdout+stderr file (`~exe_out.txt`, matching the original `2>&1` merge
   exactly), since the existing `findstr`-based hint-matching in `:exe_smokerun_hints` only checks
   for substring presence, never which stream a line came from. See
   `docs/agent-lessons-learned.md`'s "Fail-fast probe window vs. the ~30s hard-kill cap" entry for
   the full three-helper comparison (`~exe_smokerun.ps1` / `~failfast_probe.ps1` activity-aware vs.
   `~exe_hint_rerun.ps1` unconditional).
   **Test coverage**: `tests/test_exe_hint_rerun.py` (new, mirrors `tests/test_exe_smokerun.py`'s
   established harness -- `sys.executable` as the fake exe, logic fed via inherited stdin, real
   `pwsh` subprocess). `UnconditionalKill.test_hang_after_output_is_ALSO_killed_unlike_exe_smokerun`
   is the regression test that actually proves the defining behavioral difference from the other
   two helpers in this file family: a process that prints once and then hangs is still killed here
   (unlike `~exe_smokerun.ps1`, where the same shape would be left running unbounded). A
   `PayloadSync` test confirms the embedded base64 matches the canonical source byte-for-byte
   (CRLF/LF normalized, per the established `.ps1` PayloadSync convention). No existing test relied
   on the old unbounded behavior (confirmed via grep for `exe_smokerun_hints`/`exe_out.txt` across
   `tests/`), so nothing needed to change on the success path.
   **A genuine gap in the first version of this fix was caught by CodeRabbit review on PR #410
   before merge: `Process.Kill()` only terminates the immediate tracked process, not its
   descendants.** A PyInstaller onefile bootloader (or any program) that spawns a child inheriting
   the redirected stdout/stderr handles can leave that child running after the immediate process
   is killed -- the pipe then never reaches EOF, and the original unbounded
   `ReadToEndAsync().Result` read would hang forever, defeating the entire point of adding a
   bounded helper. Fixed two ways: (1) `taskkill /F /T /PID` (process-tree kill) instead of a bare
   `Kill()` -- Windows PowerShell 5.1 targets .NET Framework, which has no
   `Process.Kill(entireProcessTree)` overload (that's .NET 5+ only), so `taskkill /T` is the
   available mechanism; (2) a bounded final read (`Task.Wait($drainMs)`, hardcoded 5000ms) as an
   independent second safety net, so even a descendant `taskkill /T` somehow misses cannot hang
   the helper indefinitely -- it degrades to partial/empty output instead.
   `tests/test_exe_hint_rerun.py::ProcessTreeAndDrainTimeout` spawns a grandchild that inherits the
   pipe and outlives its own immediate parent (via `subprocess.Popen(..., stdout=sys.stdout)`),
   proving the helper still terminates within a bounded time instead of hanging -- when this test
   was first written, the sandbox this fix was built in had no `taskkill.exe`, so it only proved
   the drain-wait fallback; **now confirmed on real Windows CI too** (two lanes on PR #410 showed
   the same test's `returncode`/timing assertions passing, meaning the `taskkill /T` path itself
   was genuinely exercised there -- only the test's own `tempfile.TemporaryDirectory()` cleanup
   failed afterward, a separate, Windows-only bug in the TEST fixed below, not in the production
   helper). Also fixed a
   second, smaller CodeRabbit finding in the same review: `:exe_smokerun_hints` never explicitly
   set `HP_HINT_RERUN_OUT` before invoking the helper, relying on its default -- an inherited/leaked
   value for that env var from elsewhere would silently redirect the helper's output away from the
   file the hint-matching `findstr` checks actually read. Fixed by setting it explicitly
   (`~exe_out.txt`) at the call site, matching `HP_HINT_RERUN_EXE`'s own set/clear pattern.
   **A wall-clock timing assertion in the same test file proved genuinely unfixable by tuning the
   bound, and had to be redesigned instead.** `UnconditionalKill`'s two tests asserted elapsed
   time stayed under a fixed ceiling to prove `HP_HINT_RERUN_KILL_MS=500` was actually honored
   (not silently ignored in favor of the 10000ms default). The first bound (8s) failed on real CI
   at 9.235s; the revised bound (13s) then failed on THREE SEPARATE real-CI lanes on the very next
   push, at 13.468s, 14.578s, and 16.328s respectively -- a moving target across runs, not
   converging toward any stable value, most likely reflecting variable overhead from the new
   `taskkill.exe` process-tree-kill call (no other helper in this file family spawns it, so there
   was no prior timing data to draw from) compounded by ordinary load variance on a shared runner
   deep into a long sequential test suite. **Fixed by removing the dependency on wall-clock time
   entirely**: `tools/exe_hint_rerun.ps1` now writes its resolved `$killMs` directly to
   `HP_HINT_RERUN_KILLMS_OUT` (default `~exe_hint_killms.txt`), unconditionally, right after
   computing it -- production callers never read this file, so it costs nothing there. The tests
   now assert on that value DIRECTLY (proving the override was read and used, deterministically,
   immune to CI-runner noise) instead of inferring it from timing. A generous, untuned wall-clock
   ceiling (45s, well below the underlying test scripts' own 120s sleep) is kept only as a coarse
   sanity net against the kill mechanism being completely broken -- it is not expected to need
   future adjustment for ordinary CI variance, since it no longer needs to distinguish "honored a
   500ms override" from "silently fell back to 10000ms," only "did the kill fire at all."

### Item 12 (closed 2026-08-01)

- **`:embed_dl_retry`'s genuine mid-download-failure-then-retry-once path (REQ-009 Tier 5) had no
   CI test hook at all -- found 2026-07-29 while documenting the embed-tier download for
   `docs/demo-bootstrapper-output.md`'s Part VI, Scenario 20, fixed 2026-08-01.** Only two test
   hooks existed for this tier -- `HP_TEST_FORCE_EMBED_FAIL` (immediate decline, no download
   attempted) and `HP_TEST_FORCE_EMBED_REAL` (a full, real, successful download end-to-end).
   Neither exercised the retry branch: `:embed_dl_retry`'s own `[WARN] embed fallback: download
   failed; retrying once.` line (both curl and PowerShell failing on the FIRST try, succeeding on
   the second) was reachable in principle but never observed firing in any real CI run.
   **Fixed** with a new one-shot test hook, `HP_TEST_FORCE_EMBED_DL_FAIL_ONCE=1`, mirroring the
   existing `HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL`-style one-shot-then-succeed pattern already
   used for REQ-022's conda-create retry -- deterministically fails ONLY the first download
   attempt (no network touched) and clears itself immediately, so the second attempt always goes
   through for real. `:embed_dl_retry` was restructured to share its "retry vs. give up" decision
   (`if %HP_EMBED_DL_ATTEMPT% LSS 2 (...)`) between the real-failure path and the test-hook path
   via a new shared `:embed_dl_attempt_failed` label, rather than duplicating that logic.
   **Test coverage**: `self.embed.dl.retry` (new, `tests/selfapps_ux_hardening.ps1`), combining
   the new one-shot-fail hook with the existing `HP_TEST_FORCE_EMBED_REAL=1` (same narrow
   `HP_OFFLINE_MODE` hole as the sibling `.real` scenario) so the SECOND, real attempt genuinely
   downloads/extracts/verifies/runs -- asserts both the `[TEST] HP_TEST_FORCE_EMBED_DL_FAIL_ONCE:`
   hook-fired line and the `[WARN] ... retrying once.` line appear, AND that the tier still
   succeeds end-to-end afterward (proving retry-then-succeed, not just retry-then-give-up). Skips
   with `skip=true` in the conda-full lane, same reasoning as `.decline`/`.real`. Registered in
   `docs/agent-ndjson.md`'s row registry per this file's own AGENT DIRECTIVE.

### Item 10 (closed 2026-08-01)

- **Two of the five `PVW_*` super-user override variables (`PVW_PYTHON_EXE`, `PVW_WORKSPACE`) had
   ZERO test coverage of any kind, and ALL FIVE had zero coverage of their invalid-value behavior
   -- found 2026-07-29 while documenting them for `docs/demo-bootstrapper-output.md`'s Part V,
   fixed 2026-08-01.** `PVW_UV_EXE` and `PVW_TARGET_PY` each had real, valid-value CI coverage
   incidental to another test's own purpose; `PVW_CONDA_EXE` had dedicated coverage
   (`self.corrupt.conda.override_exit`); `PVW_PYTHON_EXE`/`PVW_WORKSPACE` had none at all, and no
   test anywhere exercised an INVALID value for any of the five.
   **Fixed** with a new file, `tests/selfapps_pvw_overrides.ps1` (uv lane only, non-gating),
   covering the item's own suggested shape in full: both currently-zero-coverage variables'
   valid-value paths (the cheapest, highest-value gap), plus 2 representative invalid-value
   scenarios (not the full 5x2 combinatorial matrix, per the item's own "2-3 representative cases
   would likely cover the real risk" reasoning) --
   - `self.pvw.python_exe.valid` -- a two-stage test: stage 1 does an ordinary uv bootstrap purely
     to materialize a real, working interpreter; stage 2 is a genuinely fresh scratch directory
     (so the EXE-cache fast path cannot short-circuit past `:after_env_mode_selection`, where the
     override actually applies) running a different stub app with `PVW_PYTHON_EXE` pointed at
     stage 1's interpreter -- confirms the override log line fires and the app runs successfully
     via the borrowed interpreter.
   - `self.pvw.workspace.valid` -- a fresh bootstrap with `PVW_WORKSPACE` set to a custom
     directory -- confirms the debug override log line fires, `Scripts\python.exe` exists at the
     CUSTOM path (not the default `.uv_env`), the default env was never created, and the app
     still runs successfully from the relocated venv.
   - `self.pvw.python_exe.invalid` -- `PVW_PYTHON_EXE` set to a nonexistent path -- confirms the
     pre-existing interpreter smoke test right after the override
     (`"%HP_PY%" -c "print('py_ok')" ... || (... [WARN] Interpreter smoke test failed
     (continuing). ...)`) absorbs the broken value gracefully, exactly as the original static
     trace predicted -- no uncontrolled crash.
   - `self.pvw.workspace.invalid` -- `PVW_WORKSPACE` set to a path already occupied by a plain
     file (uv cannot create a venv "inside" a file) -- confirms the failure cascades to the SAME
     already-established `:uv_venv_fail` -> conda-create fallback every other uv-venv-creation
     failure in this file already goes through, rather than a raw, unhandled failure. Deliberately
     does NOT require the conda fallback to actually succeed, only that it's reached -- a real
     Miniconda download in this lane is an already-accepted cost (see `self.conda.bothfail`'s own
     precedent).
   All four skip with `skip=true` in the conda-full lane (uv is never the provider there).
   **Remaining invalid-value combinations for `PVW_UV_EXE`/`PVW_TARGET_PY` (and any beyond the
   `PVW_CONDA_EXE` case already covered by `self.corrupt.conda.override_exit`) are deliberately
   NOT built** -- the original finding's own reasoning (the failure-absorption mechanism is
   shared/generic across most of these, so a combinatorial 5x2 matrix would mostly duplicate the
   same proof) still applies; revisit only if a real-world trigger surfaces a gap the
   representative cases above don't actually cover.

### Item 20 (closed 2026-08-03)

- **Postflight briefing should always show the interpreter-run command, not only in the caveat
   branch.** `run_setup.bat`'s `:print_postflight_briefing` previously only printed
   `"%HP_PY%" "%HP_ENTRY%"` inside the caveat-only preamble (EXE verification uncertain/failed),
   never in the shared `:pfb_runapp` section both the clean-success and caveat branches jump to.
   Since `dist\%ENVNAME%.exe` existing at all proves `HP_PY` already worked (PyInstaller needs a
   working interpreter to run), showing the interpreter command is always accurate there, not just
   in the caveat case -- confirmed with the owner directly (2026-08-03 discussion). **Fixed**: the
   line moved out of the caveat-only text into the shared `:pfb_runapp` section so it prints
   unconditionally once, with the now-duplicate caveat mention removed. README.md's REQ-016
   section was updated to describe the new unconditional behavior (previously documented the
   caveat-only behavior as intentional). `docs/demo-bootstrapper-output.md`'s quoted postflight
   panels (Scenarios 4, 15, 32, 33, 34, 35, 37) were all updated to reflect the new line, each
   noting explicitly which lines were "updated to reflect current source" vs. preserved as
   unmodified real-capture evidence, per this repo's sourcing convention.

### Item 21 (closed 2026-08-03)

- **Surface the requirements diff and warnfix install-attempt names on screen.** Two small
   `run_setup.bat` product changes, confirmed as genuine gaps (not just doc-fidelity issues) by
   reading source directly: (1) the pipreqs-vs-`requirements.txt` diff (`fc` output,
   `~pipreqs.diff.txt`) was previously written to file only, never shown on screen; (2) warnfix
   repair installs were previously silent on attempt/success, only naming a package on failure
   (`[WARN] Repair failed: %%M`).
   **Fixed, deliberately simpler than the original sketch (which proposed a curated one-line
   summary of newly-detected packages):** re-derivation during implementation favored the lower-risk
   option -- `type` the existing `fc` output verbatim when a genuine difference exists (detected via
   `findstr /C:"FC: no differences encountered"` on the diff file, `if errorlevel 1` gating the
   `type`), rather than writing new, untested set-difference parsing logic for a curated summary.
   For warnfix, added `[INFO] Attempting to install: %%M` immediately before each per-module
   install call (both the `HP_ENV_MODE=uv` branch's `uv pip install` loop and the conda branch's
   `conda install` loop) and `[INFO] Installed: %%M` in a new `else` success branch alongside the
   existing `[WARN] Repair failed: %%M` failure branch -- same `%%M` for-loop variable, same
   `call :log` mechanism, same nesting depth as the pre-existing failure line, so no new variable
   or delayed-expansion exposure was introduced. `docs/demo-bootstrapper-output.md` was updated to
   show both new behaviors: the warnfix scenario's real capture gained the two new lines with a
   note identifying them as updated-to-reflect-current-source (rest of the panel preserved
   unmodified), and the pipreqs-diff scenario gained an `[Extrapolated Branch]`-labeled example of
   what the console diff looks like when one genuinely exists (the real capture's own
   `requirements.txt` was freshly copied from the auto-detected scan moments earlier, so `fc` finds
   no differences there and the new line never fires in that specific capture).

### Item 22 (closed 2026-08-03)

- **Real, non-simulated end-to-end layered-dependency-chain test.** New CI test
   (`tests/selfapps_layered_e2e.ps1`, `self.layered_e2e.chain`, `cache` lane only, non-gating for
   its first landing) proving the uv-fails-to-conda cascade, warnfix repair (both a genuine
   success AND a genuine failure in the same round), and hidden-import auto-recovery all fire for
   real (not simulated) in one run. Uses three real packages, no `HP_TEST_FORCE_*`/`HP_SKIP_*`/
   `HP_DISABLE_*` flags beyond the unavoidable `HP_TEST_CASCADE_ANSWER=Y`:
   - `pygrib` (the cascade trigger): confirmed via a direct PyPI JSON API query
     (`https://pypi.org/pypi/pygrib/json`) that it ships macOS/Linux wheels for every recent
     CPython but ZERO Windows wheels (deliberately excluded, not merely absent) -- its sdist needs
     the ecCodes/GRIB-API C library a bare CI runner does not have, so `uv pip install` genuinely
     fails to build it. Confirmed via the anaconda.org API
     (`https://api.anaconda.org/package/conda-forge/pygrib`) that conda-forge has real `win-64`
     builds (5 current per-Python-version builds for 2.1.8).
   - **GDAL was the original candidate, researched and REJECTED after further investigation -- a
     genuine near-miss worth recording so it is not re-attempted.** GDAL's Python bindings live
     under the `osgeo` namespace (`from osgeo import gdal`), and PyInstaller's warn file always
     records the top-level import name ("osgeo"), not the actual PyPI distribution name
     ("gdal"/"GDAL"). PyPI hosts a real, always-succeeding DUMMY package literally named `osgeo`
     (`https://pypi.org/pypi/osgeo/json` -- a deliberate typosquat-protection placeholder
     maintained specifically to catch people who mistakenly `pip install osgeo` instead of
     `pip install gdal`), so warnfix's own per-module repair attempt for GDAL would install that
     harmless dummy instead of genuinely failing -- silently defeating
     `:warnfix_cascade_detect`'s Signal B (a REAL recorded install failure, gated on
     `~warnfix_repair_failed.flag`, set only by a genuine per-module install failure). `pygrib`'s
     top-level import name IS its own correct PyPI/conda-forge package name (no namespace
     indirection, no decoy package), so this trap cannot occur. `pygraphviz`, `rasterio`, and
     `fiona` were also considered and ruled out -- all now ship real Windows wheels (confirmed via
     the same direct PyPI JSON API method), so none would reproduce a genuine install failure.
   - `xlrd` (the warnfix-success half of the same repair round): a real PyPI wheel, so once
     genuinely absent (caught up in the same failed bulk install as `pygrib`), warnfix's
     per-module retry installs it successfully -- no `HP_SKIP_PIPREQS` isolation needed (unlike
     `tests/selfapps_warnfix.ps1`'s `real_warnfix` scenario), since warnfix operates on whatever
     the warn file shows as genuinely unresolved regardless of how it got there.
   - `colorama` via `importlib.import_module()` (the hidden-import trigger): already a proven
     real trigger elsewhere (`tests/selfapps_hidden_import.ps1`) -- invisible to warnfix (dynamic
     import), installs fine once cascaded to conda (declared in requirements.txt), but the frozen
     EXE still needs `--hidden-import=colorama` to actually bundle it.
   Lane placement confirmed as researched: NOT `conda-full` (`HP_FORCE_CONDA_ONLY=1` skips uv
   entirely) and NOT `justme-test` (`HP_TEST_FORCE_UV_FAIL=1` fakes uv's absence, simulated).
   `cache` lane matches the original reasoning (uv-first, already carries Miniconda-caching infra
   to amortize the one-time conda install cost this test's own cascade triggers).
   **CORRECTION (superseding the "CONFIRMED by a real CI run" claim originally written here):**
   that claim was wrong, and was itself based on a real verification mistake -- not a fabrication,
   but a genuine failure to check the actual result before writing "confirmed." The GitHub Actions
   step for `self.layered_e2e.chain` (run `30779274430`, cache-lane job `91580880846`, step 61) has
   `continue-on-error: true` (this test is non-gating, see the lane-placement note above), which
   makes GitHub report the step's own `conclusion` as `success` REGARDLESS of the wrapped script's
   real exit code. A later re-check via `get_workflow_job` (during the second CodeRabbit review
   round) reported `conclusion: success` and was taken at face value as proof the test passed --
   without ever opening the step's own raw log to confirm. It did not pass. The real log (pulled
   directly via the workflow run's downloadable log archive, not the truncated `get_job_logs` tail)
   shows `mech1Pass=True mech2Pass=False mech3Pass=False exePass=False ... chainPass=False` and
   ends with `##[error]Process completed with exit code 1.` -- `chainPass` was in fact `False`, not
   `True` as this file previously, incorrectly, claimed. Lesson for future verification of any
   `continue-on-error: true` step in this repo: the step-level `conclusion` field is NOT evidence
   of the wrapped script's own result for such a step -- always read the actual log content.
   **Two hardening fixes applied post-landing, from CodeRabbit review on the same PR:** (1)
   `$mech2Pass`'s original `pygrib`/`xlrd` checks were plain "does this string appear anywhere in
   `$combined`" regexes -- true independently of each other, but not proof the two outcomes
   occurred in the SAME warnfix round the way the prose above already claimed; a future code
   change splitting them across two rounds could keep this test green without the claim actually
   holding. Fixed by scoping those two checks to the substring between the round's own start
   marker (`[REPAIR] missing modules detected; installing and rebuilding.`) and its end marker
   (`[REPAIR] rebuild complete after warnfix.`), plus a new `$warnfixRoundCount -eq 1` check
   proving exactly one round exists (so the slice cannot itself straddle two). (2) workspace setup
   (`Remove-Item`/`New-Item`/`Copy-Item` on `~selftest_layered_e2e\`) ran under the script's own
   `$ErrorActionPreference = 'Continue'` with no failure check -- a failed `Remove-Item` (e.g. an
   AV/indexer lock on a leftover `dist\<env>.exe` from a prior interrupted run) would silently let
   the run reuse stale artifacts and potentially pass for the wrong reason. Fixed with
   `-ErrorAction Stop` on all three calls plus an explicit re-check-and-throw after the removal.

   **Three more hardening fixes, from a SECOND CodeRabbit review round on the same PR -- one of
   which was a real regression introduced by fix (1) above, not caught by the real CI run that
   already passed before this round.** (3) Fix (1)'s own round-scoping matched against `$combined`
   (bootstrap log + `~setup.log` concatenated) -- but every `:log`-emitted line (including BOTH the
   round start/end markers) is written to BOTH streams by `run_setup.bat`'s own `:log` subroutine,
   so matching against their concatenation silently DOUBLE-COUNTED every occurrence. This meant
   `$warnfixRoundCount` would read 2 for a single genuine round, making the new `-eq 1` check
   FALSE on every normal run -- an unconditional regression that the already-passed real CI run
   (item above) never caught, since that run predates this fix. Fixed by matching against
   `$setupText` alone, the same single-source convention `$uvToConda` already used one line above
   it in the same file -- a precedent this fix should have followed the first time. (4) The round
   substring's fallback-to-EOF when no completion marker is found meant an INCOMPLETE round (the
   rebuild itself errored, or the log was truncated) could still count as valid same-round
   evidence if the rest of the log happened to contain both substrings. Fixed by requiring the
   completion marker explicitly -- no marker means no evidence, not "assume the rest of the log is
   the round." (5) Workspace-prep (`Remove-Item`/`New-Item`/`Copy-Item`, see fix (2)) now uses
   `-ErrorAction Stop`, but a genuine failure there would raise a terminating error with no
   `self.layered_e2e.chain` NDJSON row emitted at all, leaving CI with silence instead of an
   explicit failure record. Fixed by wrapping the block in `try`/`catch`, emitting a `pass=false`
   row with the error message before `exit 1` on any workspace-prep failure.

   **Root cause of the actual `chainPass=False` failure, found by reading the real log (see the
   CORRECTION above) instead of trusting the step's own `continue-on-error`-masked `conclusion`.**
   Two independent real runs (job `91580880846` on run `30779274430`, and the equivalent cache-lane
   job on commit `694f325`) both show the identical, fully deterministic sequence: after the
   uv-to-conda cascade (mechanism 1) fires correctly, a SECOND, unplanned warnfix round fires under
   conda and fails on a module named `cStringIO` -- not one of the test's own three declared
   packages -- triggering a SECOND, unplanned cascade (conda to embed) that the test's design never
   anticipated, so mechanism 3 (hidden-import recovery for `colorama`) never gets a chance to fire
   before the run ends in a caveat panel (`~bootstrap.status.json` reads `state=embed_env`, not
   `state=ok`). The exact warn-file line: `missing module named cStringIO - imported by
   xlrd.timemachine (conditional)` -- `xlrd`'s own source (`xlrd/timemachine.py`, its internal
   Python 2/3 compatibility shim) does `try: from cStringIO import StringIO except ImportError:
   from io import StringIO`, a dead code path under any Python 3 interpreter but still flagged by
   PyInstaller's static analysis regardless. `cStringIO` was pure Python 2 stdlib, removed entirely
   in Python 3, and was never a real PyPI/conda package -- warnfix's attempt to `conda install
   cStringIO` was always guaranteed to fail, for every single run, unconditionally. **Fixed** by
   adding `cStringIO` and its bare sibling `StringIO` (identical Python-2-only-stdlib-shim
   property) to `tools/parse_warn.py`'s `SKIP` frozenset -- the same mechanism already filtering
   Unix-only stdlib modules (`posix`, `fcntl`, `grp`, etc.) from the warn file, just a different
   axis (Python-version-only rather than platform-only) sharing the same "guaranteed to never be a
   real installable package" justification. `run_setup.bat`'s `[INFO] warnfix: some modules could
   not be automatically bundled...` log line was extended to mention this second filtered category
   with accurate wording (not folded into the existing "expected on Windows" phrasing, since this
   exclusion has nothing to do with platform). New regression test
   `test_cstringio_skipped_real_xlrd_warn_line` in `tests/test_parse_warn.py` uses the exact warn
   line captured from the real CI log verbatim. Embedded `HP_PARSE_WARN` payload re-synced via
   `tools/sync_payload.py`.

   **cStringIO fix CONFIRMED by a real CI run (run `30875520181`, cache-lane job `91886501141`,
   commit `a095fa9`) -- read directly from the real log, not the step's own masked `conclusion`,
   per the lesson two paragraphs up.** The cascade now fires exactly once and cleanly:
   `mech1Pass=True mech2Pass=True` -- `xlrd` installs on the first warnfix round, `pygrib`
   genuinely fails (still the only real failure, no more spurious `cStringIO` entry), the cascade
   triggers uv-to-conda exactly once (`warnfixRoundCount=1`, `warnfixRoundComplete=true`), and
   conda is selected. This closes the fix's own open question: it behaves exactly as predicted.

   **A SEPARATE, previously-unreached bug surfaced once mech1/mech2 started passing, keeping
   `chainPass=False` for a new reason.** Under conda, `pygrib` (with its real conda-forge win-64
   build, `pygrib-2.1.8-py314h7badd63_0`) installs successfully and PyInstaller's build itself
   succeeds, but the build log shows `WARNING: Library not found: could not resolve
   'eccodes.dll', dependency of '...\pygrib\_pygrib.cp314-win_amd64.pyd'` -- PyInstaller's static
   analysis bundles the Python extension module but not its native DLL dependency (`eccodes`, a C
   library `pygrib`'s compiled `_pygrib` extension links against, itself a separate conda-forge
   package that IS installed in the env but whose DLL PyInstaller never discovers/copies). The
   frozen EXE then fails at runtime with `ImportError: DLL load failed while importing _pygrib:
   The specified module could not be found.` -- a missing-native-library error, not a
   `ModuleNotFoundError` for an installed Python module, so `--hidden-import` auto-recovery
   correctly declines to attempt anything (see "--hidden-import auto-recovery must stay STRICT" in
   `docs/agent-lessons-learned.md` -- this is exactly the class of failure that mechanism is NOT
   supposed to touch). `mech3Pass=False` (`hiddenAdding=false, hiddenRecovered=false`) reflects
   this correctly -- colorama's own hidden-import recovery is never reached because the run fails
   before mechanism 3 gets a chance to matter, not because mechanism 3 itself is broken.
   **Not yet fixed or filed as a dedicated backlog item as of this entry** -- a real fix (e.g.
   `--collect-binaries=pygrib` or an explicit eccodes DLL copy step) needs its own scoped
   investigation, not a same-loop patch on top of the cStringIO fix; the test remains `pass:false`
   and non-gating (`cache` lane, `continue-on-error`) in the interim, so no CI lane that gates PR
   merges is affected.

### Item 23 (closed 2026-08-04)

- **A genuine (non-test) conda-create failure during a REQ-009 cascade re-entry did not restore
  the previous working build via `HP_CASCADE_SAVED_PY`, unlike every other cascade-target
  failure.** Found via a CodeRabbit review finding on PR #412, verified by reading the source
  directly. `:try_conda_create`'s own failure label (`:conda_create_failed`) does NOT hard-fail
  immediately -- it first calls `:handle_conda_failure`, the same linear embed/venv/system
  fallback chain the ORIGINAL (non-cascade) conda-create failure path already relies on; if any
  of those tiers succeeds, `HP_ENV_READY` is set and control correctly `goto
  :after_env_mode_selection`. Only when `:handle_conda_failure` ALSO exhausts every tier does
  `:conda_create_failed` fall through to `call :die`, and only then did the actual bug surface:
  `:die` returns via `exit /b` (subroutine return, not a process halt; see
  `docs/agent-lessons-learned.md`'s `:die` entry), so execution fell straight through past it
  into `:conda_create_done`, which sets `HP_PY=%CONDA_PREFIX%\python.exe` and checks `if not
  exist "%HP_PY%"` -- true in this case, so it retried the identical `:handle_conda_failure`
  chain a second time (redundant, since nothing changed) before a second `call :die`, after which
  execution again fell through, now carrying a genuinely broken `HP_PY` into whatever code
  followed. Neither fall-through ever routed through `:after_cascade_decision` (the label every
  OTHER cascade-target failure -- `:cascade_conda_unavailable`, `:cascade_embed_unavailable`,
  `:cascade_venv_unavailable`, `:cascade_system_unavailable` -- correctly uses, logging `[WARN]
  ... unavailable; keeping current build.` and restoring `HP_CASCADE_SAVED_PY` into `HP_PY` so
  the bootstrap gracefully continues on the PREVIOUS successful build, e.g. uv, if cascading
  uv-to-conda). `:try_conda_create`'s failure handling had no cascade-context-awareness at all --
  it behaved identically whether this was the very first creation attempt (where there is no
  earlier build to restore, so eventually hard-failing is correct) or a `:cascade_from_uv`
  re-entry (where `HP_CASCADE_SAVED_PY` holds a known-working uv build that never got restored).
  **Fixed** by inserting `if defined HP_CASCADE_SAVED_PY goto :cascade_conda_create_failed`
  immediately before both `call :die` fall-through sites (`:conda_create_failed`'s own line and
  the companion `python.exe`-missing check inside `:conda_create_done`), and adding a new
  `:cascade_conda_create_failed` label mirroring the existing sibling template exactly -- logs
  `[WARN] REQ-009: cascade target conda create failed; keeping current build.` and `goto
  :after_cascade_decision`, deliberately never calling `:die` (that label's own restore logic
  only works correctly when `HP_BOOTSTRAP_STATE` is left as whatever it already was -- the prior
  successful build's `ok` -- not overwritten to `error`). `HP_CASCADE_SAVED_PY`-definedness is a
  safe signal to distinguish "first attempt" (never defined) from "cascade re-entry" (always
  defined by `:provider_cascade` before dispatching to `:cascade_from_uv`, the only cascade
  source that can reach `:try_conda_create`).
  **New regression test, forcing a GENUINE (not `HP_TEST_FORCE_CONDA_FAIL`-style simulated)
  failure through the real create/retry code path** -- `tests/selfapps_cascade_conda_create_fail.
  ps1` (uv lane, non-gating, `self.cascade.conda_create_fail`; see `docs/agent-ndjson.md` for the
  full assertion list). New hook `HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL=1` (distinct from the
  existing `HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL`, which only fails the first attempt then
  clears itself so the retry can genuinely succeed) persists through both the initial attempt and
  the retry, so `:conda_create_failed` is reached deterministically without depending on real
  network conditions. Combined with `HP_TEST_FORCE_EMBED_FAIL=1`/`HP_TEST_FORCE_VENV_FAIL=1`/
  `HP_TEST_SYSCON_ANSWER=N` to exhaust `:handle_conda_failure`'s own fallback chain so the fix's
  new check is actually reached. Placement is load-bearing: wired into `batch-check.yml`
  immediately AFTER `selfapps_cascade.ps1`'s own step so Miniconda is already cached from that
  step (mirrors `self.conda.bothfail`'s own placement note, opposite direction). `:hp_test_conda_
  fail` (the existing `HP_TEST_FORCE_CONDA_FAIL` test hook) has the identical fallthrough shape
  and reaches the same `:after_env_mode_selection` clear, but is scoped to the FIRST-attempt path
  only -- it was never evidence this gap was already covered by existing tests.
  **Follow-up, same PR (#413), from a CodeRabbit review finding**: the original regression test
  above only exercised `:conda_create_failed`'s own call site (create itself genuinely fails). The
  fix's OTHER call site -- the `if not exist "%HP_PY%"` check inside `:conda_create_done`, reached
  when conda create genuinely SUCCEEDS but the resulting environment is somehow missing
  `python.exe` -- had zero coverage. Closed by adding a `missing_python` scenario
  (`CASCADE_CCF_SCENARIO` env var) to the SAME test file, via a new hook
  `HP_TEST_FORCE_CONDA_MISSING_PYTHON=1` (`run_setup.bat`, `:conda_create_done`) that lets the real
  create succeed and then deletes the `python.exe` it just produced -- genuine success followed by
  a genuinely missing interpreter, not a simulated create failure. Wired as a second CI step
  (`CASCADE_CCF_SCENARIO: missing_python`) immediately after the original, same placement
  constraint (Miniconda already cached from `selfapps_cascade.ps1`). See `docs/agent-ndjson.md`'s
  updated `self.cascade.conda_create_fail` entry for the full two-scenario assertion list,
  including the message-occurrence-COUNT technique used to distinguish "handle_conda_failure
  logged the failure once, as expected" from "the old :die fall-through regression is back"
  (both scenarios' own failure messages are logged once by `:handle_conda_failure` regardless of
  outcome; a second occurrence would come only from `:die`'s own separate echo).

### Item 13 (closed 2026-08-01)

- **`self.warn.longpath`'s own real CI run showed an INCONCLUSIVE result (`ranBootstrap:false`),
   yet the test still reported an overall pass -- found 2026-07-29 while documenting the
   path-length pre-flight guard for `docs/demo-bootstrapper-output.md`'s Part VI, Scenario 24,
   root-caused and fixed 2026-08-01.** The original finding's NDJSON row (run `30328748330`,
   `real` lane) read `warnFound: false, ranBootstrap: false, pathLen: 312`. **Root cause
   (`tests/selftest.ps1`'s long-path scenario)**: `$lpRanBootstrap` is only set `$true` right
   after the `cmd /c "call run_setup.bat ..."` line executes without PowerShell itself throwing;
   the surrounding `try { Push-Location $longDir; ... } catch { $lpRanBootstrap = $false }` means
   a `Push-Location` failure (thrown BEFORE `cmd /c` is ever reached) lands in the catch block
   with `$lpRanBootstrap` still at its initial `$false`. `Push-Location` throws here because
   default GitHub-hosted Windows runners do not have `LongPathsEnabled` turned on, so
   PowerShell's own CWD-navigation cannot enter a >260-char directory at all -- `run_setup.bat`'s
   own long-path guard is never reached, genuinely never confirming the WARN fires.
   **Confirmed PERSISTENT, not a one-off**: a second real CI run on PR #410 (months after the
   original finding) showed the byte-identical signature (`ranBootstrap:false, warnFound:false,
   pathLen:312, pass:true`) -- same runner limitation, same scratch-path length, same outcome.
   **Fixed**: `$lpPass`/the NDJSON row now distinguish three outcomes instead of two --
   bootstrap ran and the WARN fired (real pass/fail on `$lpWarnFound`/`$lpExit`), bootstrap could
   not even be attempted but the scratch path was verified long enough (now reported as
   `skip=true, reason='runner-cannot-navigate-long-path'` rather than a plain, overstated pass --
   mirrors this repo's established skip pattern for "infra could not reach the code path under
   test," e.g. the conda-not-installed-uv-first pattern in `docs/agent-interconnect.md`), or the
   scratch path itself was not built long enough (a genuine test-setup bug, still a hard FAIL).
   `docs/demo-bootstrapper-output.md`'s Scenario 24 was already correctly labeling the WARN text
   `[Extrapolated Branch]` for this exact reason -- no change needed there, since this fix only
   makes the NDJSON row's own `pass`/`skip` fields honestly reflect what the earlier investigation
   had already concluded from source.

### Item 27 (closed 2026-08-07)

- **`tools/exe_hint_rerun.ps1`'s `taskkill /F /T /PID` process-tree kill showed real, correlated
   slowness across THREE independent CI runner VMs in one real Windows run, 2026-08-07 -- escalated
   to a GATING lane, so fixed the same day rather than deferred further.**
   `tests/test_exe_hint_rerun.py::UnconditionalKill::test_hang_after_output_is_ALSO_killed_unlike_
   exe_smokerun` failed on 3 of 8 lanes (`uv`, `contract-uv` non-gating; `real` **gating**) on a
   commit that touched neither the test nor the helper script (confirmed via `git log`/`git diff
   origin/main`) -- the other 5 lanes, including `conda-full` (the other gating lane), passed the
   identical suite on the identical commit. All three showed the same direction of failure:
   `contract-uv` hit a hard `subprocess.TimeoutExpired` after the test's outer 60s budget (kill
   never completed in time); `uv` hit `AssertionError: 50.641... not less than 45`; `real` hit the
   identical signature, `AssertionError: 48.437... not less than 45` -- kill eventually completes,
   just 40-60s later than a 500ms test deadline. Once a gating lane was hit, the item's own former
   "do not speculatively rewrite on a single run's evidence" caveat no longer applied (three
   correlated occurrences, one of them merge-blocking) -- **fixed same day**: both previously-
   unbounded waits in the post-kill sequence (`& taskkill.exe ...` itself, launched via the
   blocking `&` operator with no way to bound it; and the trailing `$p.WaitForExit()` with no
   argument right after) are now bounded to 5000ms each, via `taskkill.exe` running through its own
   `System.Diagnostics.Process` object instead of `&`. See `docs/agent-lessons-learned.md`'s "A
   third bounded-launch helper exists" entry for the full mechanism trace and the fix detail. The
   root cause (taskkill.exe itself vs. the trailing `WaitForExit()` vs. both) was never isolated on
   a real Windows host, since none was available; the fix bounds both defensively rather than
   pinpointing one. **Confirmed on both gating lanes post-fix** (commit `f106f78`, run
   `31196980168`): `real` (job `92928320716`) and `conda-full` (job `92928320698`) both came back
   `conclusion: success`, full pytest suite included -- the same runner-contention class did not
   recur on either gating lane's re-run, closing this item.

### Item 24 (closed 2026-08-07)

- **PyInstaller does not bundle `pygrib`'s native `eccodes.dll` dependency under the
  conda provider, so the frozen EXE fails at runtime even though the build itself succeeds.**
  Found via `self.layered_e2e.chain`'s real CI evidence (run `30875520181`, cache-lane job
  `91886501141`) once Item 22's cStringIO fix let the test reach this far for the first time --
  see that item's own closed-backlog entry for the full mechanism trace. `pygrib`'s conda-forge
  build (`pygrib-2.1.8-py314h7badd63_0`) links its compiled `_pygrib.cp314-win_amd64.pyd`
  extension against `eccodes.dll`, a separate native C library shipped by its own conda-forge
  package (`eccodes-2.48.0-h3bec8ca_0`, present in the env) -- PyInstaller's static analysis
  bundles the Python extension module itself but never discovers or copies that DLL dependency,
  so the build succeeds (with only a `WARNING: Library not found: could not resolve
  'eccodes.dll'...` note) and the frozen EXE then fails immediately at runtime with `ImportError:
  DLL load failed while importing _pygrib: The specified module could not be found.` This is a
  missing-native-library failure, not a missing-Python-module one -- `--hidden-import`
  auto-recovery correctly never attempts anything here (see "--hidden-import auto-recovery must
  stay STRICT" in `docs/agent-lessons-learned.md`), since that mechanism is deliberately scoped to
  `ModuleNotFoundError` only and this is a different failure class entirely.
  **Practical impact:** keeps `self.layered_e2e.chain` at `pass:false` (`chainPass=False`) even
  though the two mechanisms it was originally designed to test (REQ-009 cascade, warnfix
  success/failure) now both genuinely pass. The test is `cache`-lane-only and non-gating
  (`continue-on-error`), so this does not block any lane that gates PR merges.
  **Full PRD at `docs/prd-conda-native-dll-bundling.md`.** Requirement 1's own CI-only experiment
  (`tests/selfapps_gribapi_hook_probe.ps1`, PR #415, merged 2026-08-04) empirically confirmed the
  "does an existing upstream hook already solve this for free" question negative: forcing
  `--hidden-import=gribapi` did NOT make `hook-gribapi.py` bundle `eccodes.dll` for a pygrib-only
  build (`self.gribapi_hook_probe.hidden_import`, `details.conclusive=true`,
  `details.hiddenImportHelped=false` -- both the control and forced-hidden-import builds showed
  identical `bundledDll=false`/`exeExit=1`/`dllLoadFailed=true`), matching the PRD's own updated
  Finding 1 expectation (`pygrib`/`gribapi` are architecturally independent bindings to the same C
  library). **Requirements 2-6 now implemented** (this session, same day): `:dll_bundle_recover` in
  `run_setup.bat` (new subroutine, called from `:run_entry_smoke` right before `:run_exe_smokerun`)
  reacts to PyInstaller's own build-time `WARNING: Library not found: could not resolve 'X.dll'`
  line (Requirement 2's chosen design -- build-time, not runtime, to skip a guaranteed-failing
  smoke-test cycle), mirrors `:hidden_import_recover`'s bounded-iteration/tried-list shape
  (Requirement 3, 3-iteration cap), is gated to `HP_ENV_MODE=conda` for the actual
  `--add-binary`/`Library\bin` glob action (Requirement 3), carries the identical
  `HP_NUITKA_FALLBACK_USED` early-exit guard `:hidden_import_recover` already has (Requirement 6),
  and is built GENERAL rather than `eccodes`-hardcoded (see `docs/open-questions.md`'s former item
  1, now resolved below) -- the new `tools/dll_bundle_scan.py` (`HP_DLL_BUNDLE_SCAN` payload)
  parses whatever DLL name PyInstaller's own warning names via regex, not a fixed string, and
  double-gates on the DLL actually existing under the conda env's `Library\bin` (recursively, since
  `hook-gribapi.py` itself nests `eccodes.dll` under a package-named subfolder there on Windows).
  `tests/test_dll_bundle_scan.py` (34 tests at this point, growing to 37 once finding (13)'s
  `HpPyDirArgvQuoting` class is added below) covers the warning parse, the tried-list guard, the
  double-gate, the byte-offset log-tail read (so a stale warning from an earlier run in the same
  persistent `~setup.log` is never re-detected), the `--detect` mode, and the embedded-payload sync.
  **A CodeRabbit review pass caught 4 genuine bugs in the first-shipped version, all fixed same
  day**: (1) detection itself was gated on `HP_ENV_MODE=conda`, silently defeating the PRD's own
  "provider-agnostic detection" design -- fixed by moving detection (a `--detect` CLI mode) before
  both the conda and Nuitka gates; (2) the tried-list was accumulated via an unquoted batch
  variable expanded on the scan command line, which a DLL basename containing a space or `&` would
  corrupt or split -- fixed by routing it through a file (`~dll_bundle_tried.txt`, appended via
  `type ... >>`, never through `%VAR%`-expanded command text); (3) `main()` stopped at the first
  candidate that failed the `Library\bin` lookup instead of trying the next one -- fixed with a
  loop that skips unresolvable candidates; (4) the "Native-DLL bundling complete" log line could
  fire even after a genuine rebuild failure, since `HP_DLL_ITER GEQ 1` is true on both the success
  and failure paths -- fixed with an explicit `HP_DLL_FAILED` flag (mirroring the exact bug class
  already fixed once before for the warnfix-triggered rebuild, see
  `docs/agent-interconnect.md`'s "AV-Safe Build Path Tier A" section). Separately, the FIRST real
  CI run of this implementation failed all 8 lanes on a genuine bug in the test file itself, not
  the batch logic: `tests/test_dll_bundle_scan.py` wrote fixture files via `Path.write_text()`,
  which performs platform newline translation (`\n` -> `\r\n`) on Windows but not Linux -- the
  exact-string-equality assertions in the `ReadTail` test class passed locally (Linux sandbox) and
  failed on the real Windows runner. Fixed by switching every fixture write in that file to
  `Path.write_bytes(text.encode("utf-8"))`, which never translates.
  **A second CodeRabbit review pass caught 2 more genuine findings, both fixed same day**:
  (5) `HP_DLL_DETECTED`/`HP_NEXT_DLL`/`HP_NEXT_DLL_PATH` (all derived from PyInstaller's own
  warning text, which can legally contain `&`/`|`/`<`/`>`) reached `:log`'s UNQUOTED echo -- an
  already-documented hazard class in this repo (see `docs/agent-lessons-learned.md`'s ":log
  echoes UNQUOTED" entry) this loop had not yet been checked against; fixed with display-only
  `_SAFE` sanitized variables used only in `:log` calls, leaving every functional use of the raw
  value (tried-file byte-copy, quoted `--add-binary` argument) untouched; (6) the loop's
  detected/skipped/repaired/unlocatable/failed outcomes reached only `:log`'s console text, with
  no machine-readable record -- fixed with a new `:emit_dll_bundle_row` subroutine emitting NDJSON
  id `self.dll_bundle.recover` from all 6 outcome points, pulling the DLL name/provider/iteration
  via `[Environment]::GetEnvironmentVariable(...)` inside PowerShell rather than `%VAR%` cmd.exe
  substitution (protecting cmd.exe's own command-line parsing, where `&`/`|` are metacharacters
  even inside a quoted argument). See `docs/agent-interconnect.md`'s DLL-bundling section and
  `docs/agent-ndjson.md` for full detail, including why this row is not yet observed in
  `self.layered_e2e.chain`'s own artifact (that test's isolated sub-bootstrap leaves `HP_NDJSON`
  unset, matching established convention) and relies instead on `tests/harness.ps1`'s new
  `batch.dll_bundle.ndjson` static wiring check.
  **A third CodeRabbit review pass on that same fix caught a 7th genuine bug**: the `_SAFE`
  sanitization from finding (5) stripped `&`/`|`/`<`/`>` but missed that `call :log "..."` triggers
  cmd.exe's OWN second expansion pass on its own command line -- a well-established (if not
  officially documented) `call` behavior -- so a raw `%` or `^` surviving into a `_SAFE` variable
  could still expand an unrelated environment variable (e.g. a crafted `%SOME_SECRET%.dll` warning
  text from an adversarial native extension) into the log, or alter escaping, on that second pass.
  Fixed by extending all three `_SAFE` chains (`HP_DLL_DETECTED_SAFE`/`HP_NEXT_DLL_SAFE`/
  `HP_NEXT_DLL_PATH_SAFE`) with two more substitutions each: `%` (doubled to `%%` in the search
  text, believed at the time to be a standard cmd.exe idiom for matching a literal percent sign in
  a `:search=replace` substitution -- **this belief was wrong, see finding (10) below**) and `^`
  (no doubling needed there). See `docs/agent-lessons-learned.md`'s ":log echoes UNQUOTED" entry
  (new subsection) and `docs/agent-interconnect.md`'s DLL-bundling section for the full mechanism
  trace.
  **Requirement 4 (regression test) extended `tests/selfapps_layered_e2e.ps1`** with a 4th
  mechanism (`mech4Pass`, requiring `dllWarningSeen`/`dllBundling`/`dllBundleComplete`) alongside
  the three it already proved -- this is the acceptance criterion that should finally flip
  `chainPass` to `True` for the first time.
  **A FOURTH CodeRabbit review pass caught 2 more findings, both triaged**: (8) Blinter (a static
  linter, not a real cmd.exe) flagged the `%VAR:%%=_%` doubled-percent idiom from finding (7) as a
  possible "malformed string operation" (rule E021) -- assumed at the time to be a Blinter false
  positive (its pattern matcher not modeling the doubled-`%%` escape), but rather than trust either
  static tool's verdict or this repo's own reasoning about undocumented cmd.exe parsing a fourth
  time, `tests/harness.ps1` gained a NEW gating check (`batch.dll_bundle.pct_sanitizer`) that runs
  the EXACT idiom against a real `cmd.exe` via a live fixture and asserts the observed output --
  settling it empirically rather than by further static reasoning. **Blinter turned out to be
  RIGHT, not a false positive -- see finding (10).** (9) A genuine, still-open correctness gap,
  DEFERRED to Item 25 (below/closed-backlog) rather than fixed in this already-large change: when
  a 4th locatable DLL candidate is found after `HP_DLL_ITER` already hit its 3-iteration cap, the
  loop currently reports `repaired` + "bundling complete" even though that 4th DLL was never
  bundled -- needs a distinct `exhausted` outcome state, mirroring `:hidden_import_recover`'s own
  `self.exe.hidden_import.exhaust` pattern.
  **Real CI evidence, first observed 2026-08-07**: `self.layered_e2e.chain` came back
  `chainPass:false`, but the failure is EARLIER than the DLL-bundling mechanism entirely --
  `mech1Pass:false`, `condaSelected:false`, `statusState:"venv_env"`. Root cause (confirmed via the
  real `~setup.log`/`~layered_e2e_bootstrap.log` artifacts): a genuine, PRE-EXISTING bug unrelated
  to the DLL-bundling loop itself. The `runtime.txt` write-back feature (REQ-004) writes the EXACT
  patch version uv resolved (e.g. `python-3.14.7`) the moment uv's own venv succeeds; when the
  REQ-009 cascade later re-enters targeting conda (because pygrib still fails to build under uv),
  `:after_env_mode_selection`'s re-derivation of `PYSPEC` reads that freshly-written `runtime.txt`
  and forwards `python=3.14.7` verbatim to `conda create` -- but conda-forge's own `python` package
  release cadence is entirely separate from CPython's/uv's, and did not have that exact patch,
  producing `PackagesNotFoundInChannelsError: python=3.14.7` and a hard `conda env create failed.`
  The chain then fell through embed -> venv, never reaching a real conda environment, so pygrib
  was never built and `dllWarningSeen` never fired -- the DLL-bundling loop was never exercised at
  all in this run, regardless of its own correctness. **Fixed**: a new `HP_PYSPEC_WRITEBACK` flag,
  set at all 3 sites where write-back reassigns `PYSPEC` (the `:write_runtime_txt` subroutine plus
  its two inline duplicates), marks a `PYSPEC` value as "self-authored by whichever provider ran
  first," not a genuine user requirement (distinct from `HP_RUNTIME_TXT_PREEXIST`, which only
  tracks the FILE's pre-existence, not whether write-back overwrote it this run). `:try_conda_create`
  now drops the version pin (falls back to its own existing unconstrained `"%PYSPEC%"==""` branch)
  whenever `HP_PYSPEC_WRITEBACK` is set, at both the initial attempt and the transient-retry --
  a REAL pre-existing user pin (`HP_RUNTIME_TXT_PREEXIST` defined) is left untouched.
  **(10) The very first real CI run of `batch.dll_bundle.pct_sanitizer` (finding 8's own live-cmd.exe
  fixture) proved the `%VAR:%%=_%` doubled-percent idiom from finding (7) FALSE, not the Blinter
  flag it was built to double-check.** `details.output` came back `"ECHO is off."` with
  `exitCode:0` -- the substitution silently produced an EMPTY value instead of the expected
  sanitized text, an undocumented cmd.exe parsing quirk this repo's own reasoning got wrong (this
  broke `HP_DLL_DETECTED_SAFE`/`HP_NEXT_DLL_SAFE`/`HP_NEXT_DLL_PATH_SAFE` across essentially every
  CI lane). **Fixed by moving `%`/`^` stripping into PowerShell** (`-replace '%','_' -replace
  '\^','_'` against `[Environment]::GetEnvironmentVariable(...)`, written to a temp file and read
  back via a plain, non-`call` `for /f "usebackq delims=" %%X in (...) do set` -- never a
  delayed-expansion multi-line parse, which this repo bans repo-wide) instead of cmd.exe
  substitution; `&`/`|`/`<`/`>` stripping is unchanged (that part was never wrong). The
  `batch.dll_bundle.pct_sanitizer` fixture itself was rewritten to validate the REPLACEMENT
  mechanism (still a real cmd.exe + PowerShell child-process execution) and additionally proves the
  actual security property end-to-end via a real `call`-based second-expansion-pass check. See
  `docs/agent-interconnect.md`'s DLL-bundling section and `docs/agent-lessons-learned.md`'s ":log
  echoes UNQUOTED" entry for the full corrected trace.
  **(11) Refined further the same day, before any real CI confirmation of finding (10) had even
  landed, in response to a maintainer question plus an independently-converging CodeRabbit
  finding**: a new `HP_PYSPEC_ORIGINAL` snapshot (captured immediately before each of the 3
  write-back sites reassigns `PYSPEC`) now lets `:try_conda_create` preserve a genuine
  user-authored `pyproject.toml`/PEP 723 `requires-python` range across cascade instead of always
  dropping to "no constraint" -- CodeRabbit's own finding. Investigating the maintainer's separate
  "would loosening write-back also help subsequent runs" question turned up that it already does,
  via PRE-EXISTING code unrelated to this fix (`tools/detect_python.py`'s `read_runtime_spec()`
  already truncates any version to major.minor on every fresh read of `runtime.txt`) -- no
  write-side change was needed for that half. Also fixed a genuine, independent, pre-existing bug
  found while making this change: `%PYSPEC%` was used UNQUOTED on both `conda create` command
  lines, so a PEP 440 range containing `<`/`>` would already have corrupted the command even
  before today's session (unrelated to write-back specifically). See
  `docs/agent-interconnect.md`'s write-back/cascade section for the full trace.
  **(12) The PowerShell fix from finding (10) ALSO shipped broken -- caught by the same
  `batch.dll_bundle.pct_sanitizer` fixture's own very next real CI run, `details.output` again
  `"ECHO is off."`.** The replacement text (`-replace '%','_'`) put a lone, unpaired `%` on the
  SAME cmd.exe logical line as the legitimate `%LOG%`/`%TEMP%` reference; cmd.exe pairs `%`
  characters via a left-to-right scan of the whole line regardless of quoting, so the lone `%`
  paired with `%LOG%`'s own opening `%` and everything between them (the entire real replace
  logic) was parsed as one bogus, undefined variable name -- silently deleted, since an undefined
  `%VAR%` collapses to empty text inside a batch file. A sibling block with an EVEN total `%` count
  failed the same way for a related reason: its two lone `%`'s (one per `-replace` call) paired
  with EACH OTHER instead of each pairing with `%LOG%`, deleting an entire intervening
  `Set-Content` call -- proving even parity alone does not establish correct pairing. **Fixed by
  removing every literal `%` from the `-Command` text entirely**: `$pct = [char]37` builds the
  percent character inside PowerShell itself, leaving only the one legitimate, correctly-paired
  `%LOG%`/`%TEMP%` reference on each cmd.exe line -- verified by literally counting `%` occurrences
  per fully-joined logical line after the fix (exactly 2 in every case). The
  `batch.dll_bundle.pct_sanitizer` fixture in `tests/harness.ps1` was updated with the identical
  `[char]37` technique. Static reasoning about cmd.exe's own `%`-pairing/substitution semantics has
  now been wrong THREE separate times in this one code path; the live-cmd.exe fixture is what
  caught the second and third rounds, exactly as it was built to do. See
  `docs/agent-interconnect.md`'s DLL-bundling section and `docs/agent-lessons-learned.md`'s ":log
  echoes UNQUOTED" entry for the full corrected trace.
  **(13) The first REAL `cache`-lane run of the whole feature (2026-08-07) came back
  `chainPass:false` again -- `mech1Pass:true`/`mech2Pass:true` (cascade + warnfix both confirmed
  working for real), but `mech3Pass:false` and `mech4Pass:false`.** `mech4`'s own detail fields
  (`dllWarningSeen:true, dllBundling:false, dllBundleComplete:false`) showed the loop correctly
  DETECTED the `eccodes.dll` warning but never actually bundled it, logging "could not locate a
  matching file under the conda env's Library\bin" -- despite `eccodes=2.48.0=h3bec8ca_0` being
  genuinely installed (confirmed via the run's own `~environment.lock.txt`). **Root cause: an
  EIGHTH bug, a real, deterministic argv-corruption issue, NOT a locate_dll() logic bug.**
  `HP_PY_DIR` (from `%~dpI`) always ends in exactly one trailing backslash; quoted as
  `"%HP_PY_DIR%"` immediately before another quoted argument (the tried-file path) at the
  `~dll_bundle_scan.py` call site, that trailing backslash escapes the closing quote instead of
  closing it (the same general hazard already documented for `findstr.exe` in
  `docs/agent-lessons-learned.md`'s "A single trailing backslash before a closing quote" entry --
  confirmed here as a genuinely general rule, not findstr-specific, since this hit `python.exe`'s
  own argv parser instead) -- silently merging `conda_env_dir` with the tried-file argument into
  garbage, so `os.path.isdir()` fails regardless of whether the real DLL exists. Confirmed by
  downloading the real `eccodes-2.48.0-h3bec8ca_0` conda-forge win-64 package directly and
  inspecting its contents: `eccodes.dll` genuinely ships at exactly `Library\bin\eccodes.dll`,
  precisely where an uncorrupted search would have found it. Deterministic (not flaky) --
  `HP_PY_DIR` always ends in one backslash by construction, so this fired on every single
  conda-provider run since the loop shipped, meaning `chainPass` could never have been observed
  `true` before this fix regardless of anything else being correct. **Also plausibly explains
  `mech3Pass:false` in the same run**: the EXE never got past the corrupted-DLL pygrib import to
  reach colorama's own separate hidden-import gap, so `:hidden_import_recover`'s strict
  `ModuleNotFoundError`-only gate never had a chance to fire (an `ImportError: DLL load failed` is
  a different signature it correctly declines) -- fixing this one bug may unblock both mechanisms
  on the next run, not just `mech4`. **Fixed same day**: `HP_PY_DIR_ARG` (`%HP_PY_DIR%` plus one
  appended backslash, giving an even count before the closing quote) replaces the raw `HP_PY_DIR`
  at this one call site. Verified via a faithful Python simulation of the documented Windows
  `CommandLineToArgvW` algorithm (`tests/test_dll_bundle_scan.py`'s new `HpPyDirArgvQuoting`
  class) rather than a real Windows subprocess repro -- this hazard is Windows-argv-specific and
  cannot be reproduced via a real subprocess on a Linux sandbox at all (`execve` passes argv as a
  real array, no command-line re-tokenizing step to catch a regression in). See
  `docs/agent-interconnect.md`'s DLL-bundling section and `docs/agent-lessons-learned.md`'s
  trailing-backslash entry for the full trace.
  **(14) CONFIRMED FIXED via real CI evidence (commit `45ec269`, `cache`-lane run `31208498606`),
  closing this item.** The fresh `~layered_e2e_bootstrap.log` shows the loop genuinely working for
  the first time: `[REPAIR][DLL_BUNDLE] Bundling native DLL dependency: eccodes.dll (found at
  C:\Users\Public\Documents\Miniconda3\envs\_selftest_layered_e2e\Library\bin\eccodes.dll);
  rebuilding EXE (iter 1/3).` followed by `[REPAIR][DLL_BUNDLE] Native-DLL bundling complete (1
  DLL(s) added); EXE will be re-verified next.` -- `mech4Pass` (`dllWarningSeen`/`dllBundling`/
  `dllBundleComplete`, all matched via `tests/selfapps_layered_e2e.ps1`'s own exact log-text
  assertions) is confirmed `true`. **This closes Item 24's own scope** -- the native-DLL bundling
  gap this item exists to track is genuinely fixed and evidenced. `chainPass` itself is STILL
  `false` on this same run, but for a reason entirely OUTSIDE this item's scope: `mech3Pass`
  (`--hidden-import=colorama` specifically) doesn't fire, because now that the DLL bundling gap no
  longer blocks progress, the EXE gets further and hits a DIFFERENT, deeper gap first -- `pygrib`'s
  own compiled extension needs `numpy` and `packaging` as hidden imports before colorama's own gap
  is ever reached, exceeding what the test's colorama-specific assertion anticipated. This is a
  genuinely new, separately-scoped finding, not a continuation of the DLL-bundling work -- filed as
  its own Active Backlog item rather than reopening this one. See that item for the full trace.

## Closed Backlog

- **Cascade-vs-postexec fix (Active Backlog item 9), 2026-07-25, owner-directed follow-up to a
  question posed for maintainer decision the same day.** The owner reviewed
  `docs/open-questions.md` item 1 and directly instructed: implement the "skip both postexec
  offers once cascade is approved" piece (their own framing: "once they ask for cascade, then
  immediately cascade and don't do anything else"), and separately, make the cascade consent gate
  timed like sibling prompts plus add a persistent "dependencies may be incomplete" note for the
  decline path.
  - **The literal "don't do anything else" framing was investigated and found unsafe as a literal
    instruction -- caught before shipping, not after.** A first draft skipped `:run_exe_smokerun`
    itself (not just the two elective postexec offers) whenever `HP_CASCADE_APPROVED` was set.
    Tracing the actual control flow found a real regression: `HP_CASCADE_APPROVED` only means the
    NEXT provider tier will be TRIED -- `:provider_cascade` (reached later, from the top-level main
    line, only after the whole build+warnfix subroutine returns) can still find every remaining
    tier unavailable/declined (e.g. the terminal system tier's own REQ-014 consent being declined)
    and fall back to one of its six "keeping current build" exhaustion messages. Skipping the
    smoke run unconditionally would have left that KEPT build completely unverified in the
    exhaustion case -- a real regression from the pre-fix behavior, which always verified at least
    once even when the verified build later turned out to be replaced. Fixed by keeping the smoke
    run unconditional and only wrapping the two ELECTIVE follow-ups (`:run_postexec_checkpoint`,
    `:offer_optimized_build`, both called from `:smokerun_ndjson`) in the `HP_CASCADE_APPROVED`
    check. See `docs/agent-interconnect.md`'s new "Cascade-vs-postexec fix" subsection (under
    "Post-execution checkpoint") for the full trace.
  - **`:cascade_consent_gate` now uses a TIMED `choice /T` prompt** (default 30s,
    `HP_TEST_FORCE_INTERACTIVE_CASCADE=1` forces the branch under CI and shrinks it to 2s) instead
    of an unbounded `set /p`, mirroring `:pick_entry_interactive`'s own established pattern -- an
    unattended interactive user no longer hangs the whole bootstrap forever; on timeout it
    defaults to decline (N), so the current build is still tried once, unprompted. Rewritten with
    goto-based dispatch (not nested parens) per "Provider-cascade dispatch is goto-based on
    purpose" in `docs/agent-lessons-learned.md` -- `choice` followed by an `%ERRORLEVEL%`-reading
    `set` is exactly the bug class that lesson warns about inside a shared parenthesized block;
    `if errorlevel N` is used instead to sidestep it entirely.
  - **New `HP_DEP_MAYBE_INCOMPLETE` note**: set in `:warnfix_cascade_detect` when a cascade
    candidate was detected but not approved (declined, timed out, or CI auto-declined); reset at
    the top of every fresh build attempt so a provider needing no warnfix repair doesn't inherit a
    stale flag from an earlier, cascaded-away provider. Surfaced at two points -- an immediate
    `[WARN]` at decision time and a second reminder right before the EXE launches
    (`:warn_user_code_launch`) -- deliberately a note, never a second gate, since the user may know
    something the automated install missed and want to push through anyway.
  - **The "extra credit" idea (tell the user their odds of a specific next tier helping) was
    investigated with a real mechanism-level analysis, not implemented in this pass.** At the time
    this was written, the full reasoning lived as an open item in `docs/open-questions.md`; that
    item is now resolved (see this file's own Known Findings entry) and the analysis itself now
    lives in `docs/agent-interconnect.md`'s "Cascade signal reliability" subsection. Headline:
    cascading uv->conda has real, mechanism-justified value (a genuinely different package index),
    but conda->embed and beyond are all pip/PyPI-based and add comparatively little once uv and
    conda have both already struggled -- a well-supported qualitative claim, but left out of this
    pass at the owner's own flagged hesitation about complexity/risk, and still not implemented
    after the follow-up review that closed the broader question.
  - Test coverage: `tests/selfapps_cascade.ps1`'s existing `self.cascade.exec` (uv lane) gained an
    assertion that all 4 approved-cascade builds correctly skip their postexec offers (exactly 4
    occurrences, one per real cascade hop). New `tests/selfapps_cascade_timed.ps1` (conda-full
    lane, `self.cascade.timed`) proves the timed-choice mechanism and both dirty-flag injection
    points positively, and that the offers-skip message correctly does NOT fire on decline.

- **Env-var save/set/restore boilerplate dedup (Active Backlog item 3), 2026-07-25, owner-approved
  after confidence was raised to high.** New `Invoke-WithEnvOverrides` helper in
  `tests/selfapps_ux_hardening.ps1` (test-only, zero `run_setup.bat` risk) replaces the ~85 lines
  of near-identical save/set/restore code duplicated between `self.embed.fallback.decline` (6 env
  vars) and `self.embed.fallback.real` (5 different env vars) with a single hashtable-driven
  helper: `[Environment]::SetEnvironmentVariable($name, $null)` uniformly both unsets a
  previously-unset var and restores a previously-set one on the way out, removing the need for the
  original code's special-cased `if ($null -eq $saved) { Remove-Item } else { set }` branches
  entirely. Confirmed correct via direct local `pwsh` verification before touching the real file:
  proper unset-on-restore for a var that wasn't set before, proper restore-to-original-value for a
  var that was, and correct closure-scoping (the body scriptblock can read caller-scope variables
  like `$embedDeclineDir`, and its return value -- `$LASTEXITCODE` from inside a `try/finally` --
  propagates back through `& $Body` to the caller's own assignment) -- this is what raised
  confidence from "reasonable design" to "verified correct" before landing it.

- **`HP_PREP_REQUIREMENTS` canonical-source promotion (Active Backlog item 8), 2026-07-25,
  `/goal`-directed close-out pass.** New `tools/prep_requirements.py`, a byte-for-byte decode of
  the CURRENTLY embedded payload with deliberately NO header comment added (unlike all 17 other
  promoted payloads), plus a new `PayloadSync` test class in `tests/test_heuristics.py`.
  - **Resolves the item's core ask (canonical source + drift-detection test) without the
    originally-assumed prerequisite (shrinking the file to recover margin for a header
    comment).** Re-reading the backlog item's own wording, "proper promotion" implicitly assumed
    stylistic parity with the other 12 (now 17) promoted payloads, all of which carry a header
    comment -- but nothing about the `PayloadSync`/canonical-source MECHANISM actually requires
    one. Confirmed via `tools/sync_payload.py --check` that the byte-for-byte decode is trivially
    "already in sync" (304-char margin unchanged, zero cost) -- promotion and margin recovery are
    separable concerns, and only the margin-recovery half remains genuinely deferred (still
    correctly gated on the future helper-function-shrinking work the item originally described).
  - **Found and fixed a real, unrelated documentation-drift bug while updating README.md's
    payload inventory table to include this promotion**: the table's own header claimed "18
    embedded payloads, 14 with canonical source" -- re-counting the file's ACTUAL current base64
    payload declarations found 21 total (now 22 after this session's Active Backlog item 14 added
    `HP_INSTALLER_TIMEOUT`), 18 with canonical source. Two payloads (`HP_EXE_SMOKERUN` ->
    `tools/exe_smokerun.ps1`, `HP_PEP723_WRITEBACK` -> `tools/pep723_writeback.py`) had gained
    real canonical sources and `PayloadSync` tests in earlier work this repo has already shipped,
    but the README's own summary paragraph was never updated to include them -- a real, if
    cosmetic, drift between the doc and the code it describes. Corrected the count and both
    payloads' entries in the same commit.

- **Remaining Active Backlog items reviewed, 2026-07-25, `/goal`-directed close-out pass -- no
  new information changes any of these; each remains correctly deferred for the reason already
  on record.** Re-read items 1 (conda-full lane duration), 3 (env-var boilerplate dedup in
  `selfapps_ux_hardening.ps1`), 4 (PYSPEC-aware venv-vs-embed decision function), 7's remaining
  gating-lane half (`if: always()` hardening across ~50 `real`/`conda-full` steps), and 9
  (cascade-consent-vs-postexec-offers ordering) against the current state of the codebase before
  leaving them untouched, rather than assuming the existing text still applies without checking:
  - **Item 1** (conda-full ~80min lane duration): no new CI timing data gathered in this pass;
    remains a periodic-reassessment item, not a one-time fix. No action.
  - **Item 3** (~85 duplicated lines in `selfapps_ux_hardening.ps1`): confirmed the file and its
    two named blocks (`self.embed.fallback.decline`/`.real`) are unchanged since the item was
    written; the "each block needs real, different parameterization" reasoning still holds.
    Cosmetic; still correctly deferred until a change to those specific blocks is already in
    flight for another reason.
  - **Item 4** (PYSPEC-aware venv-vs-embed decision): confirmed `:try_venv_fallback` still uses
    the ambient Python unconditionally with no `PYSPEC` check; no new evidence of the
    network-correlated-embed-failure pattern the item's own "revisit if" trigger names. Not
    pursued -- still speculative complexity with no concrete trigger yet.
  - **Item 7 (gating-lane half)**: confirmed via a fresh grep of `.github/workflows/batch-check.yml`
    that no step restricted to `real`/`conda-full` currently carries `continue-on-error: true` (a
    fact this session's own item-11 work independently re-derived and relied on, see that closed
    entry above) -- the gating-lane half of this item remains exactly as risky and
    disproportionate to fix as a drive-by change as originally reasoned (touches ~50 existing step
    definitions across two lanes that already work correctly when nothing fails). Deliberately not
    attempted in this pass; the two reasons on record (would need `if: always()` on steps after
    the risk point in a job that already works today, and no evidence yet of this class of gap
    actually hiding a real regression) both still hold.
  - **Item 9** (cascade consent granted before postexec offers fire): re-traced the exact call
    chain (`:warnfix_cascade_detect`/`:cascade_consent_gate` before `:run_exe_smokerun`/
    `:run_postexec_checkpoint`/`:offer_optimized_build`) and confirmed it is unchanged since the
    item was written. This is the one item of the five that is NOT a "no new information" case in
    the same way as the others -- it is a genuine, unresolved UX design question (does a user who
    already said "yes, try the next provider" still want to see how the CURRENT,
    soon-to-be-replaced build performs?) with two reasonable answers and no way to pick one from
    the code alone. Per this pass's own instruction to document open questions to the maintainer
    rather than resolve them unilaterally: **this question is posed here, explicitly, for the
    maintainer to answer** -- either (a) reorder cascade consent to be asked AFTER the current
    build's own postexec offers, or (b) gate both offers on `HP_CASCADE_APPROVED` being unset. No
    code change made pending that answer.

- **Hidden-import auto-recovery exhaustion coverage (Active Backlog item 11), 2026-07-25,
  `/goal`-directed close-out pass.** New `tests/selfapps_hidden_import_exhaust.ps1`
  (real/conda-full lanes, same gating as its sibling `selfapps_hidden_import.ps1`): a stub app
  rotates through 3 distinct, always-installed (`colorama`/`six`/`certifi`, declared in
  `requirements.txt`) fabricated `ModuleNotFoundError` messages via a small state file next to
  the EXE that survives across the recovery loop's own rebuilds. **Distinctness is load-bearing,
  not cosmetic**: `~hidden_import_scan.py`'s own tried-list exclusion means a REPEATED module
  name is treated as already-fixed and returns nothing, which would stop the loop via the
  existing "no next hidden import found" exit well before the 3-iteration cap this test needs to
  reach -- traced the exact launch sequence (the pre-loop smoke run's fabricated module is never
  scanned at all, so only the loop's own 4 launches matter) to confirm 3 rotating modules,
  starting at state index 1 for the loop's first launch, produces exactly 3 distinct discoveries
  before the 4th launch hits the iteration cap. Asserts exactly 3 `Adding --hidden-import=`
  lines (proves the loop stopped at the cap, not an early exhaustion-of-distinct-modules exit),
  the exhaustion WARN line, the absence of the recovery-succeeded line, and
  `~bootstrap.status.json` still reading `state=ok` (the user program's own perpetual failure is
  not a bootstrapper failure, per the existing "User-code exit-code semantics" Known Finding).
  Landed directly in the gating `real`/`conda-full` lanes (no `continue-on-error`), matching its
  sibling test exactly -- confirmed no existing precedent in this repo for step-level
  `continue-on-error` within those two lanes (Active Backlog item 7's own gating-lane distinction
  applies at job level, not step level), and the underlying mechanism (fabricated stderr text +
  requirements.txt-declared modules) is already proven safe by the sibling test.

- **`PVW_CONDA_EXE` super-user-override's corrupt-conda path (`:corrupt_override_exit`) CI
  coverage (Active Backlog item 12), 2026-07-25, `/goal`-directed close-out pass.** New 4th
  scenario in `tests/selftest.ps1` (`self.corrupt.conda.override_exit`), added right after the
  three existing `self.corrupt.conda.*` scenarios: sets `PVW_CONDA_EXE=<a placeholder path that
  does not need to exist>` + `HP_TEST_CORRUPT_CONDA=1`, asserting exit code 2, the distinct
  `[ERROR] Corrupt user-managed conda (PVW_CONDA_EXE); fix manually.` log message, and the
  on-screen "Automatic self-healing is not available for user-managed conda." guidance.
  - **Turned out simpler than item 10 (no CI-ordering dependency), confirmed by tracing the code
    rather than assuming symmetry with the other three scenarios.** The three existing
    `self.corrupt.conda.*` scenarios are gated on `$condaBatOnDisk` (real Miniconda already
    installed from an earlier step in the same job) because they rely on `:select_conda_bat`
    finding a genuine `conda.bat` on disk. This new scenario does NOT need that: `run_setup.bat`
    unconditionally sets `CONDA_BAT=%PVW_CONDA_EXE%` the moment `PVW_CONDA_EXE` is defined
    (`run_setup.bat` ~line 651), BEFORE the Miniconda install-if-missing block even runs -- so
    `if defined CONDA_BAT` (the corruption-check gate) is satisfied regardless of whether
    Miniconda was ever installed anywhere in the job, and `HP_TEST_CORRUPT_CONDA=1` routes
    straight to `:conda_binary_corrupt` before `"%CONDA_BAT%" info` is ever actually invoked --
    so the placeholder path never needs to exist or be a real conda binary. Self-contained by
    construction; not gated on `$condaBatOnDisk` at all.

- **`:tci_both_failed` (Miniconda install fails under BOTH AllUsers and JustMe) CI coverage
  (Active Backlog item 10), 2026-07-25, `/goal`-directed close-out pass.** New hook
  `HP_TEST_FORCE_JUSTME_FAIL=1` (`run_setup.bat`, `:tci_justme`) deterministically skips the real
  JustMe `start "" /wait` call and forces a nonzero result; combined with the already-existing
  `HP_TEST_NOT_ELEVATED=1` (reaches `:tci_justme` by skipping straight past the AllUsers attempt),
  reaches `:tci_both_failed -> :die "[ERROR] Miniconda install failed (both AllUsers and
  JustMe)."` without depending on a genuinely broken installer/ACL environment.
  - **A real CI-ordering constraint was discovered while scoping the test, not anticipated by
    the original backlog text** ("plus a new or extended selfapps scenario" undersold the actual
    difficulty): Miniconda installs to the SHARED, machine-wide `%PUBLIC%\Documents\Miniconda3`
    path, not a per-test-directory location. If Miniconda was already installed by an EARLIER
    step in the same CI job (the main "Bootstrap environment" step, or an earlier selfapps script
    that forces conda -- e.g. `self.cascade.exec`, which cascades uv -> conda), `:try_conda_
    install`'s own top-level gate (`if not defined CONDA_BAT (...)`) would find `conda.bat`
    already present and skip the install block entirely, silently making this test's hooks
    unreachable regardless of how correct they are. New `tests/selfapps_conda_bothfail.ps1`
    (uv lane, non-gating) is wired into `batch-check.yml` immediately BEFORE the provider-
    cascade-exec step specifically to guarantee conda genuinely isn't installed yet when it
    runs -- the `uv` lane's own main bootstrap step normally succeeds via uv alone (no Miniconda
    installed), so this ordering reliably holds today. Documented as load-bearing in both the
    workflow YAML's own comment and `docs/agent-ndjson.md`'s new section, so a future CI reorder
    doesn't silently break this test's premise.
  - Asserts the `HP_TEST_NOT_ELEVATED` skip line, the `HP_TEST_FORCE_JUSTME_FAIL` hook-fired
    line, the exact `:tci_both_failed` `[ERROR]` message, and `~bootstrap.status.json` reading
    `state=error` -- not process exit code, matching this repo's established "graceful stop"
    contract for `:die`-triggered failures (`:success`'s own `exit /b 0` runs unconditionally
    regardless of `HP_BOOTSTRAP_STATE`).

- **Timeout ceiling for the three `start "" /wait` external-installer launches (Active Backlog
  item 14), owner-directed via `/goal` ("It's ok to make the start "" /wait timeout extra long
  to be conservative... check online for times... visa and Conda likely take longest, ni at
  least half hour"), 2026-07-25.** Reopens and resolves the item this same doc had previously
  closed-as-deliberately-deferred: the earlier reasoning (force-killing a real installer
  mid-write risks a worse outcome than a slow-but-succeeding install -- a genuinely corrupted
  half-installed target) is still correct and is exactly why this fix is a *generous safety
  ceiling*, not a responsiveness check -- but the owner's explicit direction to research real
  durations and pick a conservative-but-bounded value removed the "needs real design work
  first" blocker that had stalled it.
  - **Research (not guessed)**: Miniconda's Windows silent installer has a directly-corroborated
    real-world report of a 40+ minute install (Travis CI Community forum, "Installing
    Anaconda/Miniconda times out after 40 minutes"), plus multiple `conda/conda` and
    `ContinuumIO/anaconda-issues` GitHub issues reporting the installer hanging indefinitely at
    extraction or the post-install script (no duration, but confirms "eventually finishes" is
    not guaranteed). NI-VISA itself has no hard duration figure in public reports (only
    "stuck at 0%" complaints with no elapsed time), but the shared underlying NI
    Package-Manager-family installer stack has a directly-relevant NI Community report of
    installs/repairs taking multi-hour durations, explicitly attributed to antivirus scanning
    every file the installer writes.
  - **Chosen ceilings**: 60 minutes (3,600,000 ms) for both Miniconda AllUsers and Miniconda
    JustMe (generous headroom above the documented ~40 min real-world duration); 90 minutes
    (5,400,000 ms) for NI-VISA (satisfies the owner's explicit "at least half hour" floor with
    real margin for the AV-scanning-heavy scenarios the NI Package Manager family reports show,
    while staying well short of that family's multi-hour extreme outlier -- this repo's own
    Known Findings entry separately confirms NI-VISA fails FAST, ~10s, in THIS CI environment,
    so 90 minutes is deliberately generous headroom for a real user's machine, not a value tuned
    to this repo's own CI experience).
  - **Implementation**: new `tools/run_installer_with_timeout.ps1` (canonical source for the new
    `HP_INSTALLER_TIMEOUT` embedded payload, added via `tools/sync_payload.py` -- the first real
    user of the tool built in the immediately-preceding tooling pass), following the established
    `.NET Process` + `WaitForExit(ms)` pattern from `tools/exe_smokerun.ps1`/
    `tools/failfast_probe.ps1`, but with two deliberate differences from those: (1)
    `UseShellExecute=$true` (not `$false`) to preserve the same UAC-elevation-via-manifest
    behavior plain `start "" /wait` already had -- these installers may need elevation, unlike
    user-code launches; no stdout/stderr redirection is needed since the installers run silently
    (`/S`, `--quiet`); (2) on timeout, `taskkill.exe /F /T /PID <pid>` instead of
    `$p.Kill()` -- Windows PowerShell 5.1 (.NET Framework)'s `Process.Kill()` has no
    process-tree-kill overload (that's a .NET Core 3.0+ addition this runtime doesn't have), and
    this repo's own existing NI-VISA comment already notes "NI installers may spawn child
    processes," so a tree-kill is needed to avoid orphaning a sub-installer. New
    `:run_installer_timeout` subroutine in `run_setup.bat` (goto-based dispatch throughout, per
    "Provider-cascade dispatch is goto-based on purpose" in `docs/agent-lessons-learned.md` --
    the result-file read via `for /f` sets two variables that a later top-level, freshly-parsed
    line then reads, never inside the same parenthesized block) wraps all three call sites;
    returns the installer's real exit code (or `1` on timeout) via errorlevel, so each caller's
    existing `if errorlevel 1 goto ...` needed no change. Falls back to the OLD untimed
    `start "" /wait` behavior if the helper payload cannot be emitted to disk (extremely rare --
    disk/permission failure), so a helper-emission problem can never make an installer
    unreachable outright.
  - **Tests**: new `tests/test_run_installer_with_timeout.py` (8 tests, exercised end-to-end via
    real `pwsh` subprocesses, mirroring `tests/test_exe_smokerun.py`'s established pattern) --
    fast-exit result capture, argument forwarding (a single pre-assembled Arguments string,
    matching `HP_PROBE_ARGS`'s own "caller provides a ready string" contract), the
    timeout-detection path (confirmed the result file correctly reports `1|1` even on this
    non-Windows test host, where `taskkill.exe` genuinely doesn't exist and the script's own
    `try/catch` swallows that cleanly -- the actual process-tree kill itself can only be
    confirmed on real Windows CI), result-path override, `PayloadSync` byte-equality, and a
    regression guard scanning `run_setup.bat` for any bare (untimed) `start "" /wait` installer
    launch that should have been routed through the subroutine. **Found and fixed two of my own
    test-authoring bugs while verifying locally, both before committing**: (1) an argv-forwarding
    assertion expected the script's own path to appear in `sys.argv[1:]`, which is wrong --
    `sys.argv[0]` is the script path, excluded from the `[1:]` slice the stub script actually
    writes; (2) the timeout-path test hung past its own `subprocess.run(timeout=...)` because
    `capture_output=True`'s real pipes block on EOF, and the orphaned grandchild (left running
    since `taskkill.exe` isn't present on this Linux test host) inherits and holds those pipes
    open even after the direct `pwsh` child has exited -- fixed by redirecting to `DEVNULL`
    instead of a pipe for that one test, which doesn't block on EOF.
  - **CI flake found and fixed 2026-07-26, PR #390 gating-lane run (`conda-full`, run
    30226246284)**: `FastExit::test_arguments_forwarded_as_single_arguments_string` reported
    `"1|1"` (timed out) instead of `"0|0"` for a script that only writes a file and exits --
    the original `5000ms HP_INSTALLER_TIMEOUT_MS` window was too tight under real Windows
    CI-runner contention, the exact same flake class already fixed once for
    `HP_FAILFAST_PROBE_MS` (widened 5000ms->10000ms; see `docs/agent-lessons-learned.md`'s
    "Fail-fast probe window vs. the ~30s hard-kill cap" entry). Widened all four `FastExit`/
    `ResultPathOverride` call sites from 5000ms to 30000ms and the outer `_run_installer`
    `wait` default from 10s to 45s (to stay comfortably above the new 30s inner ceiling) --
    costs nothing in the normal case, since `WaitForExit` returns as soon as the child exits,
    not after the full window; it only adds headroom against a slow-starting process on a
    loaded runner. Unrelated to this PR's own `!cancelled()`/`always()` scope; a pure
    pre-existing timing-flake fix surfaced by watching the gating lane.

- **Tooling pass, owner-requested 2026-07-25 ("Update check delimiters to catch the rem space...
  see if there are any other lessons learned that can be baked into tools... expand the tools
  and agents.md"), directly following the PR #380 rem-comment CI catch.** Three concrete
  deliverables plus one honest bookkeeping fix:
  - **`tools/check_delimiters.py` gained `_check_bat_rem_comment_spacing`**, a new heuristic
    (matching the file's existing `# derived requirement:` convention) that flags any
    `.bat`/`.cmd` line whose first token starts with `rem` immediately followed by a non-
    whitespace character -- exactly the pattern that caused the PR #380 near-miss (see
    docs/agent-lessons-learned.md's "`rem` needs a space after it" entry). Verified it fires on
    a synthetic reproduction of the exact original bug and produces zero false positives against
    the real `run_setup.bat`. 4 new tests in `tests/test_check_delimiters_import.py`.
  - **New `tools/sync_payload.py`**: formalizes the "read run_setup.bat as bytes, build the
    candidate in memory, diff-verify exactly one line changed, only then write" safe procedure
    (previously hand-rolled via one-off `python -c` snippets every time) into a reusable,
    defensively-verified tool -- refuses to write if the target `set "HP_VARNAME=..."` line isn't
    found exactly once, if any OTHER line would change, or if the CMD 8191-char budget would be
    exceeded (without `--force`). 10 tests in `tests/test_sync_payload.py`, all against synthetic
    `.bat` files (never the real `run_setup.bat`). Dogfooded against the real repo (round-tripped
    a deliberate corruption of `HP_PYPROJ_DEPS` back to the byte-identical correct state) before
    committing. `docs/agent-lessons-learned.md`'s "Embedded Helper Update Workflow" and the
    original near-miss entry both updated to point at it as the required method going forward.
  - **New `tools/run_sanity_sweep.sh`**: runs CLAUDE.md's "Mandatory Sanity Checks" block (a
    block copy-pasted by hand dozens of times across this session alone) as one command with a
    clear per-check pass/fail summary. Deliberately does NOT auto-install missing tools
    (`pwsh`/`actionlint`/`yamllint`/`pyflakes`) -- installing system packages is a real,
    side-effect-having action a sweep script should not take silently; a missing tool is reported
    as a failed check pointing back to AGENTS.md's install instructions. Verified against both a
    clean pass (real repo, all 9 checks OK) and a genuine failure (a synthetic broken-Python fake
    repo, confirmed non-zero exit and correct FAIL reporting per check) before relying on it.
  - **Two entries from commit `17c483c` (the original PR #380 rem-comment docs writeup) were
    discovered to be completely missing from `main` and had to be restored.** Root cause: that
    commit was made LOCALLY but never pushed before the turn ended (a `ScheduleWakeup` call was
    made without a preceding `git push`); when the next turn ran
    `git checkout -B <branch> origin/main` to start slice 2, the local-only commit was silently
    discarded (this is expected, correct git behavior for `checkout -B` -- the loss was a process
    error, not a git bug). Found only by chance, while trying to update the very entries this
    pass was already updating and discovering they didn't exist. Restored both the
    `docs/agent-lessons-learned.md` entry (corrected in the process -- it originally said no
    local tool could catch this; that's no longer true now that `check_delimiters.py` does) and
    the `CLAUDE.md` Closed Backlog addendum, with a note on both explaining the loss and recovery
    so a future reader isn't confused by the discrepancy between the commit history and the
    restoration date. Added a new AGENTS.md rule ("Push every commit before it can be lost") to
    reduce the odds of a repeat.

- **`pyproj_deps.py`'s regex-fallback TOML parser could silently truncate a dependency list if a
  comment inside the `dependencies = [...]` array contained an unquoted `]`** (closes Active
  Backlog item 13). The char-walk loop treated any unquoted `]` as end-of-array with no
  comment-awareness, so a line like `"requests",  # supports array syntax e.g. [1,2]` inside the
  array had its comment's own `]` misread as the array's real closing bracket, silently dropping
  every dependency listed after that line (exit 0, no error surfaced). Fixed by adding a `#`
  branch to the char-walk: outside of a quoted string, `#` now skips to the next `\n` (or end of
  input) before continuing, matching TOML's own comment syntax (comments run to end of line and
  cannot appear inside a string -- confirmed the fix doesn't need to special-case `#` inside a
  string, since the existing quote-handling branch already consumes to the closing quote before
  this new branch is ever reached). Re-synced `HP_PYPROJ_DEPS`'s embedded payload (2346-char
  margin under the CMD 8191-char budget, comfortable). Two new tests in
  `tests/test_pyproj_deps.py`'s `RegexFallbackPath` class: the exact backlog-described scenario
  (comment-with-bracket inside the array, previously-dropped dependency now correctly captured),
  and a companion case confirming a `#` genuinely inside a quoted string (e.g. an environment
  marker like `"pkg; marker == 'a#b'"`) is still treated as ordinary string content, not
  mistakenly read as a comment start. 18/18 tests passing (up from 16), including `PayloadSync`.

- **Retry/loop-bound audit across `run_setup.bat` (owner-requested, "check for infinite or too
  many loops in bootstrapper like retries"), 2026-07-25 -- came back clean, with two real
  no-timeout findings unrelated to loops.** A dedicated research agent inventoried every
  goto-based retry/cascade mechanism in the file (REQ-022 conda create/bulk-install retry, REQ-013
  connectivity checks, the embed-tier download/swap retries, venv creation retry, the Miniconda
  AllUsers->JustMe fallback, the `--hidden-import` auto-recovery loop, the REQ-009 provider
  cascade, the corrupt-conda self-heal, the REQ-024 lock acquire/stale-evict) and confirmed EVERY
  ONE has a hard, provably-reachable cap (a counter incremented on a line always reached before
  its check, or a "tried" flag set unconditionally with no code path ever clearing it) -- this
  codebase's prior hardening passes (see the many "Provider-cascade dispatch is goto-based on
  purpose" / "No-loop guarantee" entries already in this file and docs/agent-lessons-learned.md)
  have genuinely eliminated the counter-bypass bug class they were designed to catch. No new fix
  needed for the loop-bound question itself.
  - **Two real findings surfaced, both about a DIFFERENT hazard class (single blocking calls with
    no timeout, not loops) -- one fixed, one deferred with reasoning.** (1) The NI-VISA installer
    download (`curl` at `run_setup.bat` ~line 1571, plus its PowerShell `Invoke-WebRequest`
    fallback) was the ONE download in the entire file missing the `--retry 3 --retry-delay 5
    --max-time 120` pattern every sibling download (uv/Miniconda/get-pip/embed) already carries --
    a stalled connection (e.g. a captive-portal network that completes the TCP handshake but never
    finishes the HTTP response) could hang the whole bootstrap indefinitely. Fixed by adding the
    same flags to the curl call and `-TimeoutSec 120` to the PowerShell fallback, matching the
    established sibling pattern exactly. (2) The three `start "" /wait` external-installer
    launches (NI-VISA installer, Miniconda AllUsers, Miniconda JustMe) have NO process-level
    timeout at all, unlike the deliberately-wrapped user-code launches elsewhere in this file
    (`.NET Process` + `WaitForExit(ms)` + `Kill()`). **Not fixed in this pass, deliberately**: these
    are REAL installer processes, not a stuck user script -- force-killing a Miniconda/NI-VISA
    installer mid-write risks leaving a genuinely corrupted, half-installed target directory
    (registry entries written but files missing, or vice versa), a materially worse outcome than
    the installer simply hanging. A correct fix needs real design work (e.g. detecting a stalled
    install and telling the user to intervene, rather than force-killing it), not a mechanical
    copy of the existing Kill()-after-timeout pattern. Logged as a new Active Backlog item with
    this reasoning attached so a future pass doesn't reach for the wrong fix shape.

- **PID display for stuck user programs (owner-requested), 2026-07-25 -- a deliberately simpler
  and safer alternative to process-group Ctrl+C isolation.** Follow-up to this session's earlier
  Ctrl+C research (see the Known Findings-style writeup in this session's own chat history):
  Ctrl+C broadcasts `CTRL_C_EVENT` to the ENTIRE console process group by default (confirmed via
  Microsoft's own docs), so a user pressing it to stop a stuck program would also risk killing
  `run_setup.bat` itself and `cmd.exe`'s own "Terminate batch job (Y/N)?" prompt -- making it
  fundamentally unsuited to "stop just my program" without real process-group-isolation
  engineering (P/Invoke `CREATE_NEW_PROCESS_GROUP`, `SetConsoleCtrlHandler`), which was assessed
  as disproportionate and left unbuilt.
  - **The chosen fix instead: print the real Windows Process ID and point the user at Task
    Manager's "End Task."** `TerminateProcess` (what Task Manager's End Task calls) targets a
    single PID directly -- it is NOT a console-signal broadcast, so it surgically kills only the
    stuck program, never touching `cmd.exe`/`powershell.exe`/the bootstrapper itself. This
    requires zero new isolation machinery (no P/Invoke, no signal handlers) since the PID is
    already sitting in the existing `$p` (`System.Diagnostics.Process`) object at both of this
    file's "never kill the process ourselves" launch points.
  - Added `Write-Host "[INFO] Process ID $($p.Id). If it seems stuck: Task Manager > Details tab >
    find this PID > End Task (this window stays open)."` immediately after `$p.Start()` in both
    `tools/exe_smokerun.ps1` (the primary fresh-build verification run -- the "activity-aware"
    kill from Requirement 3 means once output starts, this becomes genuinely unbounded) and
    `tools/failfast_probe.ps1` (covers the cached-EXE-reuse fast path, the no-EXE interpreter run,
    and the elective postexec-checkpoint second run -- all of which never kill at all past their
    classification window). **Deliberately `Write-Host`, not `[Console]::Out.Write`**: unlike the
    per-chunk child-output passthrough (which must avoid an auto-appended newline since chunks
    arrive at arbitrary boundaries), this is one complete, bootstrapper-generated line -- verified
    empirically (real `pwsh` runs) that it never lands in `~run.out.txt`/`~run.err.txt` (the files
    that specifically capture the CHILD's own output), so it cannot be mistaken for the user's
    program output or contaminate anything downstream that reads those files.
  - **Both payloads have the tightest CMD line-length budgets in the file** (per the existing
    table in this doc); the message was written to be maximally compact while still actionable,
    landing at 145/151-char margins after the addition -- tight but workable, verified via the
    established `base64.b64encode(...)`-length-measurement method.
  - **A real, pre-existing test bug was found and fixed while verifying this, not caused by this
    change**: `tests/test_failfast_probe.py`'s `NoNewlinePromptVisibility` test assumed the FIRST
    chunk read from the child process's stdout would be the child's own prompt text -- true before
    this change (nothing printed before the child), but now the new PID line is genuinely the
    first thing written. Fixed by having the test accumulate reads until the prompt substring
    appears (matching the pattern the same test already used for its own second phase), rather
    than assuming any single read IS the complete answer -- this is a more correct test regardless
    of the PID-message change, since assuming a single `os.read()` call returns exactly one
    logical unit of output was never guaranteed by the underlying pipe semantics to begin with.
  - 4 new regression tests (2 per file): the PID line appears with a real positive numeric PID and
    mentions "Task Manager"/"End Task", and the PID line never contaminates the captured output
    file. All existing tests re-verified passing (22/22 combined across both files, including
    `PayloadSync`).

- **`dep_check.py` name normalization (PEP-503-style): the dep-check fast-path skip could
  false-negative on separator-style mismatches**, another finding from the 2026-07-25 Python
  helper edge-case research. `parse_lock`/`parse_reqs` only `.lower()`ed extracted names, with no
  `-`/`_`/`.` folding -- conda-forge and PyPI sometimes spell the same logical package with
  different separators for the same name (e.g. `typing_extensions` in a conda lock vs.
  `typing-extensions` in pipreqs output), which would look "missing" from the lock on every run,
  forcing an unnecessary reinstall and defeating the fast path's whole purpose (not a
  correctness break -- the reinstall is idempotent -- just wasted time on affected package
  names). Fixed with a small `_norm()` helper (`re.sub(r"[-_.]+", "-", name).lower()`, PEP 503's
  own normalization rule) applied consistently in both functions. `tools/dep_check.py` is an
  already-promoted canonical source with `PayloadSync`; margin was comfortable (4604 chars
  before, 4000 after). 5 new tests in `tests/test_dep_check.py` (unit-level normalization in
  both functions, a repeated-separator collapse case, and two `main()`-level end-to-end
  regressions proving the fast path now correctly skips across a hyphen/underscore and a
  hyphen/dot mismatch) -- 21/21 passing (up from 16).
  - **A related agent finding -- adding PyQt5/PySide6 to `tools/collect_submodules.py`'s
    `DYNAMIC_PKGS` curated set, to fix the well-known "could not find or load the Qt platform
    plugin" PyInstaller runtime crash -- was investigated and NOT implemented, because it does
    not actually fix that problem.** Read `collect_submodules.py`'s own module docstring
    carefully before acting: `--collect-submodules` collects a package's PYTHON submodules
    (the exact gap sklearn/matplotlib/scipy/plotly genuinely have -- dynamically-dispatched
    Python code PyInstaller's static tracer can't see). Qt's platform-plugin loading is a
    completely different, NATIVE plugin-loading mechanism (DLLs, not Python submodules) that
    `--collect-submodules` has no ability to address at all -- PyInstaller's own bundled
    PyQt5/PySide6 hooks (or `--collect-data`) are the actual correct fix for that specific
    crash, a mechanism this file doesn't touch. Adding PyQt5/PySide6 here would have bloated
    GUI-app EXEs (a large framework) without fixing the real issue the finding was aimed at --
    a case where verifying an agent's suggestion against the actual mechanism it proposes using
    caught a misdiagnosis before it shipped.

- **`HP_TEST_JUSTME_FALLBACK` removed as vestigial dead test-scaffolding**, found by a
  background research agent auditing `run_setup.bat` against AGENTS.md's own "Branch coverage
  policy" (every branch needs a CI test). Confirmed via a repo-wide grep that no test file
  anywhere referenced this flag; it sat in `:try_conda_install` as a THIRD, redundant way to
  reach `:tci_justme` (skip straight to the JustMe Miniconda install), alongside the genuine
  elevation-check failure and the already-tested `HP_TEST_NOT_ELEVATED` flag (covered by
  `tests/selfapps_justme.ps1`) -- both of which already reach the exact same destination with
  real coverage. Rather than build a redundant test for a flag that added no coverage value
  beyond what `HP_TEST_NOT_ELEVATED` already provides, removed the flag entirely. `AGENTS.md`'s
  own "Branch coverage policy" section cited this flag by name as its example -- updated to cite
  `HP_TEST_NOT_ELEVATED` instead, a still-live flag with real test coverage.
  - **Three sibling findings from the same branch-coverage audit were NOT acted on in this pass,
    logged as new Active Backlog items instead**: `:tci_both_failed` (both AllUsers and JustMe
    Miniconda install fail -- no `HP_TEST_*` hook exists to force this deterministically),
    the hidden-import auto-recovery exhaustion WARN line (no test drives the loop to its 3-attempt
    cap without ever succeeding), and the `PVW_CONDA_EXE` super-user-override corrupt-conda path
    (`:corrupt_override_exit`, distinct "fix manually" messaging never exercised by
    `tests/selftest.ps1`'s existing corruption scenarios, which never set `PVW_CONDA_EXE`). All
    three are real, reachable production branches with zero CI coverage, but each needs a new
    `HP_TEST_*` hook plus a new or extended selfapps scenario -- real, if modest, engineering
    investment better sequenced as its own dedicated pass than rushed alongside this session's
    other fixes. See Active Backlog for the full reasoning per item.

- **Two more findings from the same 2026-07-25 deep research pass, both in the REQ-027/AV-Safe
  Build Path area** -- a background research agent specifically tasked with finding interaction
  gaps between the newest, least-battle-tested features (live-tee, argv passthrough, honest
  messaging, the elective second/optimized-build runs) found two real, independently-verified
  bugs:
  - **`HP_NOEXE_VERIFY_FAILED` was never cleared on success, unlike its sibling
    `HP_EXE_VERIFY_FAILED`.** `:smokerun_ok` explicitly clears `HP_EXE_VERIFY_FAILED` on a clean
    EXE run; both call sites that set `HP_NOEXE_VERIFY_FAILED` (the legacy and probe branches of
    `:verify_no_exe_interpreter`/`:verify_no_exe_probe`) only ever SET it on failure, never
    cleared it on success. Since the variable is a process-global initialized once at the top of
    the file, a stale `1` from an earlier REQ-009 cascade tier's failed no-EXE run could in
    principle survive into a later tier's genuinely successful run (requires `HP_SKIP_EXE_SMOKERUN`
    plus a cascade spanning a failing-then-succeeding tier -- narrow, but real, and directly
    falsifies the flag's own code comment claiming it mirrors `HP_EXE_VERIFY_FAILED`'s behavior).
    Fixed by adding the matching clear on both success branches. No dedicated new CI test added
    (the trigger condition is narrow and hard to construct deterministically without a purpose-
    built multi-tier-cascade fixture) -- consistent with this repo's established practice of not
    building speculative test scaffolding for a narrow, low-frequency correctness path; flagged
    here for a future dedicated pass if this path's real-world trigger rate ever justifies it.
  - **`:offer_optimized_build`'s internal build-verify launch never forwarded `HP_APP_ARGS`, and
    this doc's own prior reasoning for treating that as intentional (grouped with
    `:hidden_import_recover`'s unrelated omission) did not actually hold for this call site.**
    See `docs/agent-interconnect.md`'s "AV-Safe Build Path requirement 9" section for the full
    fix and the corrected "Argv passthrough escape hatch" text -- in short: unlike
    `:hidden_import_recover`'s repair-check-on-an-already-working-build, this call site verifies
    a BRAND-NEW, never-before-run Nuitka binary, so any program requiring launch arguments to
    even start would always fail this check regardless of whether the build itself was fine.
    Fixed by having the inline PowerShell `-Command` read `$env:HP_APP_ARGS` (PowerShell's own
    inherited-environment access) rather than having cmd.exe substitute the batch variable
    directly -- `HP_APP_ARGS` contains literal embedded double-quotes per token, which would have
    corrupted the `-Command` argument via the same quote-parsing hazard already documented in
    `docs/agent-lessons-learned.md` for `HP_FAILFAST_PROBE`'s inline-vs-emitted-`.ps1` history.
  - **A third finding from the same agent (cascade consent granted before the current tier's own
    postexec offers fire, so a user can be asked to build/rerun a soon-to-be-discarded EXE) was
    investigated but NOT fixed in this pass** -- the sequencing is real (confirmed via direct
    tracing: `:warnfix_cascade_detect`/`:cascade_consent_gate` run before `:run_exe_smokerun`/
    `:run_postexec_checkpoint`/`:offer_optimized_build` within the same build attempt), but a
    correct fix requires either reordering when cascade consent is asked relative to postexec
    offers, or gating the offers on `HP_CASCADE_APPROVED` -- a genuine design decision with
    UX tradeoffs (e.g. does the user still want to see how the CURRENT build performs even
    though it's about to be superseded?) that deserves its own dedicated, reviewed pass rather
    than a rushed fix folded into an unrelated research sweep. Logged as a new Active Backlog
    item with the full reasoning preserved.

- **`HP_PARSE_WARN` TRANSLATIONS table: 12 new import-name-to-package mappings**, second finding
  from the same 2026-07-25 deep research pass (see the sibling entry below for the pass's
  headline finding). A background research agent flagged several common import/package-name
  mismatches missing from the warnfix repair table; each was independently verified (correct
  conda-forge/PyPI package name, real mismatch) before adding. New entries: `win32com`,
  `win32gui`, `win32file`, `win32process`, `win32event`, `pywintypes`, `pythoncom`, `winerror`
  (all -> `pywin32` -- the table previously only covered `win32api`/`win32con`, but COM
  automation via `win32com.client` and other common pywin32 usage patterns are at least as likely
  in a beginner Windows-automation script), `pptx` -> `python-pptx` (direct analog of the
  existing `docx` -> `python-docx` entry), `skimage` -> `scikit-image` (direct analog of the
  existing `sklearn` -> `scikit-learn` entry), `Cryptodome` -> `pycryptodome` (pycryptodome's own
  dedicated import namespace, used specifically to avoid pycrypto/pycryptodome conflicts -- the
  table already had `Crypto` -> `pycryptodome` for the other import spelling), and
  `zmq` -> `pyzmq`. `tools/parse_warn.py` is an already-promoted canonical source with
  `PayloadSync` (`tests/test_parse_warn.py::ParseWarnPayloadSync`), so this was a normal
  edit-reencode-verify cycle, not a payload-promotion project -- margin was comfortable (2603
  chars before, 2151 after). `TranslationTableCompletenessTest` (an existing guard requiring
  every `TRANSLATIONS` key to have a dedicated test) forced -- correctly -- a matching test method
  and `_TESTED_KEYS` entry per new mapping; all added. 12 new tests, 55/55 passing in
  `tests/test_parse_warn.py` (up from 43).

- **Deep research/review pass, owner-requested ("general research refinement and code review...
  shoring up and checking if things are really the way they need to be... burn cheap promo time
  this week"), 2026-07-25.** Ran three parallel background research agents (run_setup.bat branch
  coverage, Python-helper edge cases, CLI-interactive-verification feature interactions) plus
  independent direct-code-tracing investigation. All findings independently re-verified before
  acting, per this repo's established practice -- see the sibling entries below for the individual
  fixes; this entry covers the single highest-value finding from the pass.
  - **`~prep_requirements.py`'s heuristic dependency-augmentation output (REQ-005.8: pandas,
    sqlalchemy, requests, matplotlib, cryptography/pycryptodome rules) was silently dead for
    every non-conda provider -- uv/venv/system/embed, the DEFAULT since the REQ-009 uv-first
    reorder -- confirmed via direct tracing, not assumption.** The helper writes two files:
    `~reqs_conda.txt` (genuinely consumed, by `:conda_bulk_install`) and `~reqs_pip.txt` -- which,
    confirmed via `grep -rn "reqs_pip" run_setup.bat tests/`, is **written but never read anywhere
    else in the entire repo**. Every pip-based install branch in `:after_env_mode_selection`
    (conda's own "pip gap fill", venv, uv, embed) installs from `requirements.txt` directly,
    unaugmented -- confirmed by reading each branch's exact command
    (`"%HP_PY%" -m pip install -r requirements.txt` / `uv pip install ... -r requirements.txt`).
    This means a pandas+`pd.read_excel()` app bootstrapped via the now-default uv path never got
    `openpyxl`/`xlsxwriter` installed by this mechanism at all -- exactly the runtime-dependency
    class (CLAUDE.md's own "Dependency Discovery" section) this heuristic exists to catch, silently
    not firing for most real users. A prior agent's own comment in
    `tests/selfapps_pep723_writeback.ps1` (found while investigating) had already partially
    diagnosed this for the `requests->certifi` rule specifically and correctly judged it harmless
    THERE ONLY because `certifi` happens to already be a real transitive dependency of `requests`,
    so pip/uv installs it anyway regardless of the heuristic -- that reasoning does NOT extend to
    `openpyxl`/`xlsxwriter` (neither is a `pandas` dependency; both are optional, lazily-imported
    Excel-engine packages pandas' own metadata never declares) or `pymysql` (not a `sqlalchemy`
    dependency; a DB-driver choice sqlalchemy is deliberately agnostic about) -- both are genuine,
    silently-unfixed gaps for non-conda providers before this fix.
  - **A second, independent bug was compounding in the same code and is fixed by the same
    change**: the `matplotlib->tk` rule's `pip_specs.append('tk')` line. Researched (not assumed)
    whether `pip install tk` fails cleanly: it does not -- there IS a real, unrelated third-party
    PyPI package literally named `tk` (confirmed via web search), so this heuristic would have
    silently installed the WRONG package while giving the false impression the Tk-backend
    dependency was handled, had `~reqs_pip.txt` ever been wired up naively without also fixing
    this. `tk` is correctly conda-only (it maps to the real Tcl/Tk system libraries via
    conda-forge, with no correct pip equivalent at all) -- removed `pip_specs.append('tk')`
    entirely; `conda_specs.extend(format_line('tk', []))` (the correct, still-needed path) is
    unchanged.
  - **Fix**: after the six heuristic rules run, `main()` now additively merges any package
    genuinely NEW to `pip_specs` (tracked via a pre-heuristics length marker, `n0 = len(pip_specs)`,
    then `added = pip_specs[n0:]`) back into `requirements.txt` itself -- the one file every
    provider's install step already reads, so no `run_setup.bat` install-branch code needed to
    change at all. Idempotent by construction: a second run re-reads the now-augmented
    `requirements.txt`, so `names_lower` already contains the added package and the corresponding
    `if 'X' in names_lower and 'Y' not in names_lower:` guard correctly skips re-adding it --
    exactly mirroring the established idempotent-additive-merge pattern already used by
    `tools/autopep_merge.py` (REQ-005.12) and `tools/pep723_writeback.py` (REQ-005.11), just without
    a shared helper (this payload has no canonical `tools/` source, see below).
  - **This payload's CMD 8191-char line-length budget was the tightest in the whole file
    (188-char margin per the existing table in this doc) and the fix initially blew it by 48
    chars.** Recovered margin by finding and removing a second, independent piece of dead code in
    the same file: `normalize_specifiers()`, a fully-defined function with zero call sites anywhere
    in the file (confirmed via a call-site grep of every function in the module) -- its removal
    alone recovered enough space to land the fix with a healthier 304-char margin than the
    ORIGINAL (pre-fix) payload had, a net improvement in future edit headroom despite adding real
    functionality. Verified via the same `base64.b64encode(...)`-length-measurement method this
    doc's own "CMD.EXE 8191-Character Line Limit" section already documents.
  - **Deliberately NOT promoted to a canonical `tools/prep_requirements.py` source file with
    `PayloadSync` in this pass**, unlike the 6 other payloads already promoted -- this payload's
    extraordinarily tight budget makes even a single-line header comment a real, avoidable risk
    (a `# canonical source: ...` pointer line would cost real margin that a future functional
    edit might need more), and mid-way through this exact fix a careless verification script
    accidentally truncated `run_setup.bat` to zero bytes (caught immediately via `git status`/
    `wc -l`, restored losslessly from the last commit with zero data loss -- see
    `docs/agent-lessons-learned.md`'s new entry on this near-miss) -- a second reminder that this
    file deserves extra care, not additional edit surface, until a dedicated pass can also address
    the budget itself (e.g. trimming other helper functions, which was NOT attempted here to keep
    this fix's own diff minimal and reviewable). Tracked as a new Active Backlog item.
  - Five new regression tests in `tests/test_heuristics.py` (`TestRequirementsWriteback`): the
    pandas rule's additive writeback, idempotency across two runs, `tk`'s exclusion from
    `requirements.txt` specifically (not just from `~reqs_pip.txt`), the kill-switch leaving
    `requirements.txt` untouched, and an unrelated package (`flask`) leaving it untouched too. All
    20 tests in the file (15 pre-existing + 5 new) pass with zero regressions.


Items completed and shipped:

- **Multi-agent parallel bug-hunt pass, requested directly by the owner ("general research
  refinement and code review... shoring up and checking if things are really the way they need to
  be"), 2026-07-24.** Two parallel research-only agents (`run_setup.bat` itself; CI workflow +
  test infrastructure) swept the codebase for new bugs beyond what earlier passes had already
  found. Every finding was independently re-verified by direct code tracing before being acted on.
  - **8 `selfapps_*.ps1` files never propagated their computed `$pass` to a process exit code --
    a NEW instance of the exact bug class already found and fixed twice before (3 files, then
    separately `tests/selftest.ps1`, per the earlier Closed Backlog entries).** A fresh sweep found
    `selfapps_contract_uv.ps1`, `selfapps_entry.ps1`, `selfapps_envsmoke.ps1`,
    `selfapps_pandas_excel.ps1`, `selfapps_pipgap.ps1`, `selfapps_reqspec.ps1`, and
    `selfapps_runtime_writeback.ps1` all missing `if (-not $pass) { exit 1 }; exit 0` at the end --
    confirmed via `grep` that none contained any final exit statement (a few had only mid-file
    `exit 0` skip-guards for non-Windows hosts or missing conda, all writing `pass=$true` rows
    only, genuinely safe as unconditional exits). Four of these files (`entry`, `envsmoke`,
    `reqspec`, `runtime_writeback`) run unconditionally in the GATING `real`/`conda-full` lanes
    with no `continue-on-error`, meaning a real regression in entry selection, env-smoke
    verification, requirement-spec translation, or runtime.txt write-back could compute
    `pass=$false`, write it correctly into the NDJSON row -- and the step, job, and PR check would
    still report green. **`selfapps_pandas_excel.ps1` had the more severe variant already seen
    once before in `reqspec.ps1`'s own conda-not-found branch**: its `HP_FORCE_CONDA_ONLY -eq '1'`
    branch (the conda-full gating lane, where conda genuinely missing IS a real failure) writes
    six `pass=$false` NDJSON rows and then unconditionally `exit 0`s -- and `reqspec.ps1`'s own
    structurally identical conda-not-found branch (line 347-353, same `HP_FORCE_CONDA_ONLY -eq '1'`
    condition, same pattern of real `pass=$false` rows via `Write-ReqspecRows`) turned out to have
    the SAME gap, caught in a follow-up self-check rather than the original sweep, and fixed the
    same way. **A follow-up, targeted grep pass (files with zero `exit 1` occurrences anywhere,
    run after the first 7 were fixed) found an 8th instance the two research agents both missed:
    `selfapps_single.ps1`** (REQ-002, `entry.single.direct`/`helper.invoke`/`pipreqs.run`/
    `entry.expected` rows) -- unconditional `exit 0` at end of file with zero `exit 1` anywhere,
    despite four call sites that can write `pass=$false`. Lower real-world severity than the other
    7 (this file's own header docstring notes it's gated on `pyFiles==1`, which the bootstrapper
    repo's own multi-file CI runs never satisfy -- so this repo's CI has likely never actually
    exercised the buggy branch -- but the file is an explicit template "In consumer repos it checks
    the entry selection breadcrumbs when exactly one Python file is present," where the gap is
    real). Fixed via the identical central-choke-point pattern: each file's `Write-NdjsonRow`
    function now sets a script-scoped `$script:AnyRowFailed` flag whenever a row's `pass` is
    `$false`, and every exit site (final, plus the genuinely-unsafe mid-file ones in
    `pandas_excel.ps1` and `reqspec.ps1`) checks it -- chosen over hand-deriving each file's own
    "real" aggregate pass condition, since `reqspec.ps1`'s own ingest rows use locally-scoped pass
    variables that are NOT folded into its `$overallPass`, making a per-file manual aggregation
    riskier to get right than the already-proven central-tracking mechanism. This pass's own
    lesson: a grep for "zero `exit 1` occurrences despite `pass=$false` literals present" is a
    cheap, mechanical way to re-run this exact check in the future without needing a fresh agent
    sweep -- worth remembering as the go-to verification method if this bug class is ever
    suspected to have a 9th instance.
  - **`tests/harness.ps1`'s `$allowedStates` for the `bootstrap.state` check was missing
    `'embed_env'`** -- the state value `:try_embed_fallback` (REQ-009 Tier 5) sets on a successful
    embed-tier fallback, confirmed present in `run_setup.bat` alongside the already-allowlisted
    `venv_env`/`degraded_env` sibling states. Since the provider chain is
    `uv -> conda -> embed -> venv -> system`, a genuine (non-test-forced) double failure of uv and
    conda in the `real` (gating) lane would legitimately land here -- and would have been reported
    as a `harness.ps1` failure despite being correct, designed fallback behavior, exactly mirroring
    the already-allowlisted `venv_env`/`degraded_env` cases. Fixed by adding it to the allowlist.
  - **The warnfix-triggered PyInstaller rebuild (`run_setup.bat`, inside the `HP_WARNFIX_NEEDED`
    block) had zero failure handling, unlike its sibling original-build call a few dozen lines
    earlier.** See `docs/agent-interconnect.md`'s "AV-Safe Build Path Tier A and hidden-import
    auto-recovery" section for the full trace, failure scenario, and fix (mirrors the original
    build's `if errorlevel 1 (...) else if not exist ... (...) else (...)` shape and
    `HP_BOOTSTRAP_STATE=error` handling, deliberately without a `:try_nuitka_tier_a` retry; also
    clears `HP_NUITKA_FALLBACK_USED` on a genuine PyInstaller rebuild success so
    `:hidden_import_recover`'s existing Nuitka-skip guard doesn't misfire afterward). No dedicated
    CI test added -- flagged here as a candidate for a future dedicated test pass (a
    `HP_TEST_FORCE_WARNFIX_REBUILD_FAIL` hook mirroring the existing
    `HP_TEST_FORCE_PYINSTALLER_FAIL` pattern) if this path's real-world trigger rate ever
    justifies the investment; not built speculatively here, consistent with this repo's general
    bias against untriggered speculative work.
  - **Real bug in this exact fix, caught on the very first real Windows CI run (PR #380,
    2026-07-25): a `rem` comment split a hyphenated word across two lines, and the second line
    (`rem-nested failure path.`) was missing the space `rem` needs to be treated as a comment --
    cmd.exe ran it as a literal (nonexistent) command instead, leaving a nonzero errorlevel sitting
    right in front of the brand-new `if errorlevel 1` check this same fix added.** This made the
    check fire on every run, including fully successful ones -- confirmed via the real
    `~warnfix_bootstrap.log` from the failed CI run (downloaded directly via
    `mcp__github__actions_get`'s `download_workflow_run_artifact` method): PyInstaller had already
    produced the EXE successfully, and the only actual error was the stray
    `'rem-nested' is not recognized as an internal or external command` line. Fixed by keeping
    "already-nested" together instead of splitting it across two `rem` lines; confirmed via
    `grep -nP '^\s*rem\S' run_setup.bat` that no other line in the file has the same "rem
    immediately followed by a non-space character" pattern. See
    `docs/agent-lessons-learned.md`'s new "`rem` needs a space after it" entry for the full
    mechanism and a reusable grep-based check for future multi-line `rem` comment edits.
    **This was originally documented here in commit 17c483c, but that commit was never pushed
    before the branch was reset for the next slice, silently discarding it -- restored 2026-07-25
    during a tooling/documentation pass that also formalized `tools/check_delimiters.py`'s
    `_check_bat_rem_comment_spacing` check (which now catches this exact class of bug locally,
    before any CI push) and `tools/sync_payload.py` (which would have made the original mistake
    structurally harder to repeat, though it doesn't guard against an unpushed commit).**
  - **Investigated and found NOT a new issue, no action**: the `real`-lane review agent's other
    observations (a loose substring match in `selfapps_pyinstaller_fail.ps1`'s `$testHookFired`
    clause, two cache-lane steps still missing `continue-on-error`) were both judged low-impact
    (the loose match is ANDed with 3 other specific assertions so the test as a whole isn't
    tautological; the cache-lane gap sits right before a step that already has `if: always()`) and
    left for a future pass rather than expanding this one's scope further. The `run_setup.bat`
    review agent's broader sweep (parse-time `%VAR%` freezing, fallback-tier state consistency,
    unquoted risky `:log`/`echo` values, `move`/`rd` swap verification, guaranteed-vs-assumed-set
    variables, and the newest REQ-026/REQ-027/activity-aware-kill code) found the codebase
    consistently applying its own already-documented defensive patterns everywhere else traced,
    including a specific check of whether `HP_NOEXE_VERIFY_FAILED`/`HP_FASTPATH_RUN_FAILED` could
    go stale across a REQ-009 provider-cascade re-entry (confirmed they cannot, since
    `HP_CASCADE_APPROVED` is unconditionally cleared at the top of `:provider_cascade` on every
    re-entry) -- no further findings surfaced there.

- **CLI-args/stdin-interactive support, P2 (honest ambiguous-exit messaging) -- final slice,
  `docs/plan-cli-interactive-verification.md`'s plan is now FULLY SHIPPED (P0, P1, P2 all
  complete).** Scope was narrowed from the plan's literal wording during implementation: the
  original sketch suggested a NEW "let us try a deeper dependency-resolution pass?" prompt at the
  final `[STATUS]` line, but tracing the actual code flow found this mechanism already exists and
  fires EARLIER, at build time (`:warnfix_cascade_detect` + `:cascade_consent_gate`, the REQ-009
  provider cascade) -- re-offering it post-hoc at the final status line would be redundant and
  architecturally awkward (it would need to re-enter build/dependency-install logic from a point
  that currently only prints and exits). Documented this scope decision in both
  `docs/plan-cli-interactive-verification.md` (Open Question 3, now marked RESOLVED) and
  `docs/agent-interconnect.md` rather than silently deviating from the plan's wording.

  What P2 actually ships instead: two real, previously-undiscovered honesty gaps found by tracing
  what P0/P1 had already changed, both fixed with a new outcome-tracking flag apiece, no new
  consent prompts, no `~bootstrap.status.json`/exit-code changes -- messaging only.
  - **Gap 1**: `:print_no_exe_briefing` (the no-EXE postflight panel, shipped earlier this same
    day -- see the "No-EXE postflight briefing panel" Closed Backlog entry above) unconditionally
    claimed "your code ran successfully just now" regardless of whether the interpreter fallback
    run that immediately precedes it (`:verify_no_exe_interpreter`) actually exited 0 -- a real,
    pre-existing dishonest claim. Fixed with a new `HP_NOEXE_VERIFY_FAILED` flag (set in both of
    `:verify_no_exe_interpreter`'s branches -- the legacy/CI branch on a non-zero `HP_SMOKE_RC`,
    and the interactive fail-fast-probe branch the same way, noting that call site has zero
    `-1`/timeout ambiguity since `:run_failfast_probe` never kills, so `HP_SMOKE_RC` is always the
    interpreter's true final exit code once observed). `:print_no_exe_briefing` was rewritten with
    goto-based dispatch (mirroring `:print_postflight_briefing`'s own `:pfb_caveat` shape) into a
    new `:noexe_caveat` branch when the flag is set, replacing the false success claim with
    "NO STANDALONE .EXE -- AND WE CAN'T CONFIRM YOUR CODE RAN CLEANLY" and honest wording that
    points the user at running the program themselves.
  - **Gap 2**: the cached-EXE fast path (`:try_fast_exe`) had NO postflight signal at all -- beyond
    one WARN log line buried among other console output -- for the case where the fail-fast probe
    classifies a reused `dist\<env>.exe` as alive/healthy (so it is kept, never discarded/rebuilt)
    and it later exits non-zero. Fixed with a new `:print_fastpath_ambiguous_note` subroutine,
    called from `:success`'s dispatch only when `HP_FASTPATH_USED` AND `HP_FASTPATH_RUN_FAILED`
    are both set -- a plain informational print, never a consent gate, preserving the fast path's
    "zero friction for PROMPTS" design invariant (`docs/agent-interconnect.md`). Suggests deleting
    `dist\<env>.exe` and re-running for a fully fresh dependency check.

  **Neither panel claims to know WHY the run was ambiguous** (a bug in the user's own code vs.
  something this bootstrapper missed vs. an unresolved dependency) -- both are deliberately honest
  about that limit rather than attempting a diagnosis, which is what Open Question 3 asked and is
  now resolved by: P2 does not attempt to distinguish root causes, it only states the outcome
  honestly and points the user at the full output.

  Test coverage extends existing scenarios rather than adding net-new test files, matching this
  repo's established convention: `tests/selfapps_failfast_probe.ps1`'s existing "alive" scenario
  (already produces the exact "cached EXE kept, later exits non-zero" condition via a stub that
  sleeps 6s then exits 7) gained an assertion that the new fastpath-ambiguous-note text appears;
  `tests/selfapps_pyinstaller_fail.ps1` gained a third `PYI_FAIL_SCENARIO` value,
  `execfail_runtimefail` (both PyInstaller and the Nuitka fallback fail, AND the interpreter
  fallback that runs afterward also exits non-zero via a stub that prints then
  `sys.exit(3)`), wired into `real`/`conda-full` in `batch-check.yml`, asserting the new
  `:noexe_caveat` text appears instead of the false-success text -- reuses the existing
  `self.exe.build.xfail` NDJSON row id, matching the file's established multi-scenario-same-row
  pattern. `docs/agent-ndjson.md` updated to describe all three `PYI_FAIL_SCENARIO` values.

- **CLI-args/stdin-interactive support, P1 requirement 4 (argv passthrough escape hatch) --
  owner-approved next work after all of P0 shipped ("P1 and p2 at least look good enough to
  try", 2026-07-24).** `HP_APP_ARGS` is captured once, at the very top of `run_setup.bat` (right
  after `set "DEP_SOURCE=unknown"`), from `%2`-`%9` directly -- deliberately NOT via `shift`,
  since `%~1` (the entry file) is read directly by several later call sites in this file (the
  top-of-file UNC check, both `:determine_entry` call sites), and shifting would silently change
  what those later `"%~1"` reads see. This caps the feature at 8 extra arguments, a documented
  limitation, not a silent one. Each present token is individually re-quoted at capture time so a
  token containing spaces survives as one argv element to the target program.

  **Required changing `HP_PROBE_ARGS`'s own contract in `tools/failfast_probe.ps1`, not just
  wiring up new callers.** The script used to wrap WHATEVER was in `HP_PROBE_ARGS` in exactly one
  extra pair of quotes (`$si.Arguments = '"' + $rawArgs + '"'`) -- correct only for a single
  token (a path, possibly with spaces); wrapping a multi-token string the same way would collapse
  it into one literal argv element instead of several. Fixed by using `$rawArgs` verbatim as
  `$si.Arguments`, shifting the quoting responsibility to the caller (`run_setup.bat`). Every
  existing `HP_PROBE_ARGS` assignment site had to be re-audited under the new contract: the EXE
  fast-path probe (`:try_fast_exe_probe`) now sets it to `%HP_APP_ARGS%` alone (no entry-file
  prefix needed, the EXE is self-contained); the interpreter probe (`:verify_no_exe_probe`) and
  the post-execution checkpoint's second run (`:run_postexec_checkpoint`) both now set it to
  `"%HP_ENTRY%"%HP_APP_ARGS%` (the entry path explicitly re-quoted at the call site, since the
  script no longer does this implicitly). The two DIRECT invocation sites that never went through
  the probe helper at all (`:try_fast_exe`'s legacy/CI branch,
  `:verify_no_exe_interpreter`'s legacy branch) got `%HP_APP_ARGS%` appended straight to their
  command lines instead. `tools/exe_smokerun.ps1` gained a NEW variable, `HP_SMOKERUN_ARGS`
  (it never had any `Arguments` handling before -- the EXE smoke previously always ran with zero
  argv), using the same "caller provides a ready string" contract.

  **`:log` echoes UNQUOTED (documented in `docs/agent-lessons-learned.md`), so the one new log
  line this feature adds (confirming forwarding is active right after `:determine_entry`
  succeeds) is deliberately content-free** -- it never interpolates `%HP_APP_ARGS%` itself, since
  a user-supplied argument could legitimately contain `<`/`>`/`|`/`&` and corrupt the line the
  same way `%HP_ENTRY%`'s own already-documented "accepted risk" does at its 4 existing call
  sites.

  **Test-suite consequence: this REPLACED an existing test that had documented the OLD contract
  as correct, not just added new ones.** `tests/test_failfast_probe.py`'s
  `ArgsIsSingleArgumentOnly` class explicitly asserted that a multi-token `HP_PROBE_ARGS` was
  misparsed as one argument -- true before this change, actively WRONG after. Replaced with
  `ArgvPassthrough` (proves multiple pre-quoted tokens now forward as separate argv elements, and
  documents that an unquoted token containing a space is now the CALLER's responsibility to
  quote, not a script bug). A second, previously-passing test
  (`test_single_argument_path_with_spaces_quoted_correctly`) also needed a fix: it relied on the
  script's own old auto-quoting for an unquoted path with spaces, which now fails under the new
  contract -- fixed by having the test quote the path itself, matching production usage.
  `tests/test_exe_smokerun.py` gained its own `ArgvPassthrough` class; its existing test harness
  (launches `sys.executable` fed the test program via inherited stdin, with zero CLI args, to
  mimic a frozen EXE's own invocation shape -- see that file's module docstring) had no spare
  "script path" slot to attach extra CLI args to the normal way. Solved with CPython's own
  documented `python - arg1 arg2` form (a literal `-` as the script name means "read the program
  from stdin," with everything after becoming `sys.argv[1:]`), confirmed directly
  (`python3 - --foo "bar baz" < script.py` -> `ARGV:--foo|bar baz`) before relying on it in the
  test.

  **Documented in README's new `[REQ-026]` section and both postflight briefing panels**,
  including the practical 8-argument limit, the unsupported-embedded-quote limitation, and an
  explicit correction that forwarding does NOT persist into how a later plain double-click of the
  built EXE launches it (an early draft of the briefing text incorrectly implied it would be
  "baked into" future re-runs -- caught and fixed before shipping, since that would have been a
  materially misleading claim about what the feature actually does).

  **Deliberately out of scope, matching precedent already established for this class of
  decision**: the two internal, bounded repair/optimization verification loops
  (`:hidden_import_recover`'s own re-run, `:offer_optimized_build`'s internal verify launch) do
  NOT receive `HP_APP_ARGS` -- both are diagnostic checks against an already-confirmed-working
  build, not the user's primary run. The `HP_CI_SKIP_ENV=1` CI-only test path
  (`:ci_skip_entry`'s system-Python launch) was also left out -- test infrastructure, not one of
  the plan's four named real launch sites, and CI has no interactive terminal to benefit from it
  anyway. See `docs/agent-interconnect.md`'s new "Argv passthrough escape hatch (REQ-026, P1)"
  section for the full call-site-by-call-site trace. P2 (honest ambiguous-exit messaging) is the
  one remaining un-started P0/P1/P2 slice from the plan.

- **CLI-args/stdin-interactive support, Finding 9 -- `ReadLineAsync()` line-buffering hid
  no-newline prompts from BOTH the live-tee and the activity-aware kill, found during a
  requested research/refinement pass and fixed the same day, with owner authorization
  ("if you think the raw character read is the fix then go for it and test locally and let CI
  confirm").** While reviewing the just-shipped requirement-3 work, confirmed empirically
  (standalone `pwsh` + Python repro, not assumption) that Python's canonical `input("prompt")`
  idiom -- the pattern this whole plan is built around -- writes its prompt WITHOUT a trailing
  newline by design, and `StreamReader.ReadLineAsync()` (the read primitive both
  `tools/failfast_probe.ps1` and `tools/exe_smokerun.ps1` used, per the just-prior
  `Register-ObjectEvent` fix) does not surface ANY text for a stream until it sees a full
  newline-terminated line. A child process writing `"Enter your name: "` and blocking on stdin
  produced zero completed reads for 2+ seconds even though the bytes were genuinely flushed and
  sitting in the OS pipe. Two real consequences: (1) a real user watching the console during
  verification would see nothing until AFTER blindly typing an answer, undercutting requirement
  1's whole stated goal; (2) `$sawOutput` (requirement 3's activity-aware kill flag, shipped
  hours earlier) inherited the same blind spot, meaning the 30s kill could still fire for the
  EXACT scenario requirement 3 was built to protect. The owner independently confirmed hitting a
  closely related symptom in their own code (progress dots not appearing until later when
  frozen into an EXE, fixed by an explicit flush) -- separately caused by Python's OWN writer-side
  buffering, not this bug, but the two together motivated a careful investigation of the actual
  reading mechanism rather than assuming it was already correct.

  **Fix**: replaced `ReadLineAsync()` with `StreamReader.ReadAsync(char[], int, int)` chunk reads
  on a 4096-char buffer in both helper scripts (same single-read-in-flight polling shape the
  `Register-ObjectEvent` fix already established -- only the read primitive changed).
  `[Console]::Out.Write($chunk)`/`[Console]::Error.Write($chunk)` (no auto-newline) replace
  `Write-Host`/`WriteLine`, since chunks now arrive at arbitrary boundaries; EOF became a
  0-length read instead of a null result. Verified the fix empirically before touching
  production code (a no-newline prompt became readable in single-digit milliseconds, versus
  never within 2s before), then wrote two NEW regression tests specifically targeting the
  no-newline-chunk case (existing tests all use newline-terminated output, so none of them
  exercised this) -- `tests/test_failfast_probe.py::NoNewlinePromptVisibility` (drives stdin via
  a live, test-controlled pipe using raw `os.read`/`select`, not a pre-loaded answers file, since
  a static file makes the whole answer available to the OS instantly regardless of read strategy
  and cannot distinguish the timing bug at all) and
  `tests/test_exe_smokerun.py::ActivityAwareStop::test_output_with_no_trailing_newline_still_
  prevents_kill`. Both new tests were confirmed to genuinely FAIL when checked out against the
  pre-fix implementation (from the actual merge commits) and PASS against the fix -- proven
  regression tests, not new tests that happen to pass. Full existing suite (19 tests across both
  files, including the pre-existing 20/20-clean interactive round-trip test) re-verified clean
  with the new read primitive, run 3x with no flakiness. See
  `docs/plan-cli-interactive-verification.md` Finding 9, `docs/agent-interconnect.md`'s "Live-echo
  redesign" (point 6) and "Activity-aware EXE-smoke kill" sections, and
  `docs/agent-lessons-learned.md`'s new dedicated entry for the full trace and a reusable rule of
  thumb for future async-output consumers in this repo.

- **CLI-args/stdin-interactive support, P0 requirement 3 (activity-aware EXE-smoke kill) --
  resolves Open Question 1, direct owner decision.** Owner's exact framing: "I think don't change
  the timeout if they were told at the beginning that it was timed. At best, if interactive input
  was received then extend or stop the timeout." Implemented in `tools/exe_smokerun.ps1`: the
  `HP_SMOKERUN_KILL_MS` window stays fixed at 30000ms (unchanged, per "don't change the timeout"),
  but it is now a classification checkpoint rather than an unconditional deadline -- `Kill()` only
  fires if the process has produced ZERO output by that point. The parent cannot observe stdin
  directly without reintroducing the exact risk the requirement-1 live-tee redesign just fixed
  (`RedirectStandardInput` is deliberately left inherited), so "interactive input was received" is
  approximated by the best available proxy: any output at all, since Python's `input(prompt)`
  flushes stdout before blocking (confirmed) -- a process at its first prompt has already printed
  something. Chose "stop" (unbounded wait once alive, mirroring `~failfast_probe.ps1`'s own
  philosophy) over "extend by a fixed increment," since a bounded extension only relocates the
  same ambiguity to a later deadline. Accepted trade-off, matching Open Question 1's own
  previously-listed option (b): a process that prints something once and then genuinely
  deadlocks for a non-stdin reason now hangs the bootstrap instead of being caught at 30s.
  `:warn_user_code_launch` now takes a parameter (`main`/`hidden_import`) so each of its two
  callers gets accurate messaging -- the main EXE smoke describes the new conditional behavior;
  the separate, still-unconditional hidden-import recovery loop (a bounded repair-verification
  check, deliberately out of this requirement's scope) keeps its original wording, since its
  actual behavior didn't change. `tests/test_exe_smokerun.py`'s `KillTimeout` class was split so
  the pre-existing "hung process is killed" test uses a genuinely silent script (the case still
  correctly caught); a new `ActivityAwareStop` class proves a process that prints, then runs well
  past a short kill window, then exits on its own, is never force-stopped. See
  `docs/agent-interconnect.md`'s new "Activity-aware EXE-smoke kill" section for the full
  mechanism. This closes out all of P0 in `docs/plan-cli-interactive-verification.md`; P1 and P2
  are the next owner-approved slices ("P1 and p2 at least look good enough to try").

- **CLI-args/stdin-interactive support: `Register-ObjectEvent` line-reordering bug found and
  fixed, plus a real interactive round-trip test added -- direct follow-up to requirement 1's
  shipment, requested by the owner ("Do we have a test to fake a selected entry py that uses
  output and input()... Would the command line interface input() tee stuff work on the QuickStart
  uv and all lanes and such?").** Building the requested test (a multi-round `input()`-driven stub
  script: ask for a name, greet, then loop `ping`/`exit`) surfaced a genuine, previously-unknown
  bug in the just-shipped live-tee mechanism: `Register-ObjectEvent` on
  `OutputDataReceived`/`ErrorDataReceived` dispatches via `ThreadPool.QueueUserWorkItem`, which
  gives no ordering guarantee between events -- a confirmed, filed upstream PowerShell bug
  (PowerShell/PowerShell#11937) that reordered lines WITHIN a single stream when several arrived
  close together (round 2 of the test conversation appearing before round 1's in the captured/teed
  text, non-deterministically -- 2 failures out of 5 local runs). Fixed by replacing
  `Register-ObjectEvent` entirely in both `tools/failfast_probe.ps1` and `tools/exe_smokerun.ps1`
  with self-sequenced `StreamReader.ReadLineAsync()` polling (only ever one read in flight per
  stream, so no out-of-order delivery is possible by construction) -- this also subsumes and
  removes the separate async-drain-race workaround from requirement 1's own original fix, since a
  completed `ReadLineAsync()` task with a `$null` result IS the stream's definitive EOF signal.
  Verified with 20 repeated runs of the new interactive round-trip test (0/20 failures after the
  fix, versus 2/5 before) and 5 repeated full test-suite runs. See
  `docs/agent-lessons-learned.md`'s new dedicated entry and `docs/plan-cli-interactive-verification.md`
  Finding 8 for the full trace.

  **New CI test closes (pending its first observed real run) the remaining confirmation gap for
  requirement 2**: `tests/selfapps_interactive_stdin.ps1` (new, uv lane, non-gating) builds a real
  PyInstaller EXE from the same multi-round `input()`-driven stub shape and pipes a scripted
  answer sequence into `cmd.exe`'s own stdin, exercising the FULL real chain (`cmd.exe ->
  :run_exe_smokerun -> ~exe_smokerun.ps1 -> the built EXE`) rather than a simplified local proxy --
  asserting ordering (via `IndexOf` comparisons on the bootstrap log), that the EXE was genuinely
  built, and that the bootstrap reports `state=ok`. Provider-agnostic by construction
  (`:run_exe_smokerun`/`~exe_smokerun.ps1` behave identically regardless of which REQ-009 tier
  built the environment), so one passing run in the uv lane is representative of every lane -- a
  per-provider repeat would exercise the same code path, not a different one. New NDJSON row
  `self.interactive.stdin.roundtrip`, registered in `docs/agent-ndjson.md`.

  **Answered the owner's third question directly, via source-reading, not assumption**: the
  separate "PVW QuickStart" (`HP_PVW_KNOWN_IDEMPOTENT`, REQ-005.13) execute-mode discovery path
  was NEVER affected by this bug (or by any tee mechanism at all) -- `tools/pvw_known_idempotent.py`'s
  `run_script()` invokes `uvx autopep723 <entry>` via a plain `subprocess.run(..., timeout=120)`
  with full stdio inheritance and zero redirection, so both the original drain-race and the
  Finding-8 reordering bug are entirely out of scope for it; its output/input always passed
  straight through unmodified. Flagged, not fixed here: that helper carries its own separate
  `timeout=120` risk (a genuinely slow interactive session during discovery could be killed by it)
  -- a distinct, not-yet-actioned observation, out of scope for this pass.

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
