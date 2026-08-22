# Plan: `:die` Non-Halting Fall-Through Remediation (CLAUDE.md Active Backlog Item 46, Bucket A)

**Status:** Research pass complete (2026-08-18); maintainer decision recorded and full 20-site
trace completed (2026-08-21, see Finding 3 and "Batch Roadmap" below) -- grounded directly against
current `run_setup.bat` source via `tools/audit_batch_exit_paths.py` and manual tracing, not
written from memory or inference. **Batch 1 is merged** (PR #468). Batches 2, 3, 5, and one site of
Batch 4 (the `Could not stage ~condarc` site) are implemented, with regression tests and CI wiring,
landing as a follow-on PR stacked on Batch 1. Batch 6 and the "Active Python interpreter not
resolved" sink remain deferred, per "Batch Roadmap" below. See CLAUDE.md's Item 46 entry for the
full incident history (Bucket B, closed; Bucket A slice 1, closed) this plan picks up from, and
"Batch Roadmap" below for exactly what's implemented vs. what remains.
**Owner:** Supervisor (Python_vs_Windows)
**Related:** CLAUDE.md Active Backlog Item 46, `docs/agent-lessons-learned.md`'s `:die` entry,
`docs/agent-interconnect.md`'s "Genuine (non-cascade) conda-create exhaustion" section, PR #437
(Item 45), PR #438 (Bucket B), PR #439 (Bucket A slice 1), `tools/audit_batch_exit_paths.py`.

---

## Problem Statement

`:die` (`run_setup.bat`) uses `exit /b`, a subroutine return, not a process halt. A caller with no
`goto`/halt after `call :die` simply continues executing. This is correct behavior for a caller
that structurally cannot continue usefully (nothing follows), but wrong for the common case: most
`call :die` sites sit inside a parenthesized guard block, and falling through means execution
resumes at whatever comes AFTER that block -- sometimes harmless, sometimes a redundant re-attempt
of already-failed work, sometimes (before Item 45's fix) a doomed PyInstaller build against a
broken interpreter.

Two prior slices already closed the two most dangerous, best-understood instances of this pattern:
- **Item 45** (closed): a direct guard at the top of `:run_entry_smoke`
  (`if not exist "%HP_PY%" set "HP_NO_INTERPRETER=1"`) stops a broken `HP_PY` from ever reaching a
  doomed PyInstaller build, regardless of which upstream `:die` site let it through.
- **Bucket B** (closed): the 3 PyInstaller-build-failure `:die` sites were migrated to a new,
  non-pausing sibling `:warn_build_incomplete`, since real, outcome-determining verification work
  still follows them -- pausing there was misleading, not merely redundant.
- **Bucket A slice 1** (closed): `:conda_create_failed`'s own `call :die` now `goto`s straight to
  `:after_env_mode_selection`, skipping a redundant second `:handle_conda_failure` call (and its
  embed/venv-attempt + system-consent-prompt replay) for a genuine, non-cascade, total-tier-
  exhaustion failure.

This plan is about what comes next: the remaining `call :die` sites, and which of three candidate
approaches (CLAUDE.md's own Item 46 entry already named all three without choosing between them)
should carry the work forward.

## Goals

- Close the class of "misleading or redundant pause" bugs this pattern produces, to whatever
  extent the maintainer decides is worth the engineering cost.
- Preserve `:die`'s existing, correct choreography (pause for a real double-click user to read the
  message, release the concurrent-instance lock, write the honest `state=error` status) for every
  call shape -- none of the three candidates should regress that.
- Keep the same "EXTREME CAUTION, one slice at a time, full-matrix CI proof before the next slice"
  discipline this item has followed since it was first scoped -- this doc does not propose
  abandoning that discipline, only choosing which shape the next slice takes.

## Non-Goals

- Not attempting a single sweeping change across every remaining site in one PR -- ruled out
  explicitly in CLAUDE.md's own Item 46 process notes, and this doc doesn't revisit that.
- Not re-litigating Item 45 or Bucket B -- both are closed and out of scope here.
- Not proposing new user-facing behavior -- every candidate below is purely about what happens
  internally after a failure is already being reported; none change what a user sees on success.

---

## Research Findings

### Finding 1 -- current inventory: 27 `call :die` sites, down from ~31 before Items 45/Bucket B/slice 1

`grep -n "call :die " run_setup.bat` (2026-08-18) finds 27 occurrences. `tools/audit_batch_exit_
paths.py` independently confirms the file's broader shape (181 labels, 67 ever reached via `call`,
149 total `exit /b` sites) but does not itself classify `:die` sites specifically -- this doc's own
classification below was done by direct inspection of each site's surrounding code, not the tool
alone (the tool's own docstring is explicit that `called=False` is "a hint, not proof").

### Finding 2 -- 7 of the 27 are already effectively safe, just via an older idiom than slice 1's `goto`

Two (the `:conda_create_failed` site and its `:hp_test_conda_fail` test-bypass sibling) already
carry a `goto :after_env_mode_selection` immediately after `call :die`, from Bucket A slice 1 and
its pre-existing precedent respectively.

Five more -- all inside the `:conda_binary_corrupt` self-heal flow (`:heal_prompt`,
`:corrupt_override_exit`, `:corrupt_ci_exit`, `:evict_and_rebuild`'s own nested failure) -- pair
`call :die "..." N` with their own immediate, same-scope `exit /b N` right after. Traced this
flow's own entry points (`goto :conda_binary_corrupt`, two call sites, both plain `goto` from the
main line, never `call`): with no active call frame anywhere in this chain, `exit /b N` here
genuinely terminates the whole cmd.exe process, not just a subroutine return. These 5 sites were
already effectively "Bucket A shape" before Item 46 was ever filed -- they just used a manual
companion `exit /b N` instead of a `goto`, predating slice 1's own template. No fix needed here;
listed for completeness so the remaining count is accurate.

### Finding 3 -- complete trace of all 20 remaining sites (2026-08-21, supersedes the original spot-sample)

The original pass above spot-traced a representative sample. Per the maintainer's explicit request
("full trace now, then batch"), every one of the 20 remaining sites (27 total minus the 7 already
safe per Finding 2) was individually read and traced -- what falls through when the `:die` at that
exact line is reached, what code runs next, whether it is doomed/misleading/redundant/benign, and
what the correct `goto` target (or "no fix needed") is. Line numbers below are current as of this
pass (`git log`-visible drift from the original ~806/~838-852/~1157/~1908/~1911 estimates is
expected -- this repo's own files move as unrelated work lands).

This trace groups the 20 sites into 6 batches by shape, including 2 sites that need no code
change. See "Batch Roadmap" below for the landing plan; this Finding is the evidence each batch's
grouping and priority is based on. Sites below are cited by subroutine/label and `call :die`
message text, not
line number, per this repo's own "cite by stable label, not exact line number" documentation
convention (line numbers drift on every unrelated edit above the citation).

**Batch 1 -- conda-acquisition-probe chain (5 sites, all inside `:after_conda_bat_validation` or
`:after_conda_probes`).** All top-level (no active call frame), all guard a step in
acquiring/validating a conda installation before `:try_conda_create` is ever reached. The 4 sites
in `:after_conda_bat_validation` (`conda.bat not found after bootstrap.`, `'conda' not found on
PATH after bootstrap.`, `'python' not found on PATH after bootstrap.`, `'python -V' failed after
bootstrap.`) already call `:handle_conda_failure` and check `HP_ENV_READY` first -- structurally
identical to `:conda_create_failed` pre-slice-1, the exact shape slice 1 already proved safe. The
1 site in `:after_conda_probes` (the REQ-... channel-policy check, `Conda not found at:
%CONDA_BAT%`) skips the `:handle_conda_failure` attempt entirely (by design -- at that point
`CONDA_BAT` is known bad, not just possibly-recoverable) but shares the identical root cause and
convergence target. Traced the fall-through chain explicitly: `conda.bat not found after
bootstrap.`'s fall-through reaches the REQ-020 warm-up/corruption-check blocks right after it
(both no-ops when `CONDA_BAT` is undefined), then falls into the `where conda` check, and on THAT
falling through too, `where python`, `python -V`, then `:after_conda_probes` flows straight into
the channel-policy check -- so in the worst case (conda genuinely never acquired), a single root
cause can currently stack **4-5** back-to-back `[ERROR]`/pause pairs before the chain finally
reaches `:try_conda_create` with a broken `CONDA_BAT` and dies again (already-safe, slice-1-fixed)
at `:conda_create_failed`'s own `conda env create failed.` site, ultimately landing on the real
sink -- `:after_env_mode_selection`'s `Active Python interpreter not resolved.` check. Fix: `goto
:after_env_mode_selection` after each of the 5 `call :die` lines, mirroring slice 1's proven
pattern exactly. Per the already-documented limitation (this does not eliminate the pause at the
sink, only the redundant intermediate ones), this collapses the worst case from 5-6 stacked
pauses down to 2 (this site's own + the sink). **Existing test infrastructure already reaches
this exact chain**: `tests/selfapps_conda_bothfail.ps1` (`HP_TEST_FORCE_JUSTME_FAIL=1` +
`HP_TEST_NOT_ELEVATED=1` + `HP_FORCE_CONDA_ONLY=1`) drives a genuine Miniconda-install failure
straight into this chain via `:try_conda_install`'s own fall-through (see Batch 6) -- no new test
hook needed, only new assertions on the existing scenario. **Risk: LOW** -- same proven shape as
slice 1, applied to sibling call sites in the same functional chain, with an existing test already
positioned to prove it.

**Batch 2 -- `:conda_create_done`'s "python.exe missing" check (1 site).** Different shape
from Batch 1: this site already checks `HP_ENV_READY` AND `HP_CASCADE_SAVED_PY` (for cascade
re-entry) before its own `call :die "[ERROR] python.exe missing from conda environment."`, but on
a genuine, non-cascade fall-through, execution continues through the REST of
`:conda_create_done`'s body -- writing `.condarc` (which is harmless; conda config is arguably fine
to write even with a broken interpreter) and, more importantly, logging `[BOOT] REQ-009: Selected
Python provider: Conda (Portable).` -- a **misleading success-sounding message immediately after
an `[ERROR]` was already reported** -- before an unconditional `goto :after_env_mode_selection`
anyway. **Correction to the original Finding 3's "backstopped by Item 45" framing**: HP_PY is
*defined* here (set to a nonexistent path a few lines earlier), not *undefined* -- so the sink's own
`if not defined HP_PY` check does NOT catch this case (it only catches a genuinely-unset HP_PY).
The actual backstop is Item 45's `if not exist "%HP_PY%"` guard in `:run_entry_smoke`, which
correctly catches a defined-but-nonexistent path. The dangerous consequence (a doomed PyInstaller
build) is therefore still closed, but the misleading log line is real and worth fixing. Fix:
`goto :after_env_mode_selection` right after this site's `call :die`, skipping the misleading
message and the two now-pointless `.condarc`-write steps (`Could not stage ~condarc` and
`Could not write %ENV_PATH%\.condarc` remain untouched as *code* -- they still run normally for the
success path that reaches them without going through this site's failure branch). **Risk: LOW**,
but kept as its own PR since the surrounding code differs enough from Batch 1 to deserve
independent CI proof, per this item's own "don't assume symmetry" lesson (the same lesson slice 1
itself taught when its "reduces to one pause" claim needed correcting).

**Batch 3 -- entry-determination double-call (1 site to fix, the first `Could not determine entry
point` site inside `:after_env_mode_selection`; 1 site confirmed already safe, the second `Could
not determine entry point` site inside `:after_env_bootstrap`).** `:determine_entry` is called
**twice** in a normal (non-CI-skip) run: once inside `:after_env_mode_selection` (early, for PEP
723/pyproject-detection purposes), and again inside `:after_env_bootstrap` (late, for the real
entry-smoke decision) -- confirmed via `grep` that `:after_env_mode_selection`'s body flows
straight through, with no goto, into `:after_env_bootstrap` a few hundred lines later. If the
first call fails and its `call :die` falls through, execution runs the **entire** intervening
dependency-install/pipreqs/heuristics/warnfix-writeback/pyvisa-detection block (real network and
disk work) before reaching the second `:determine_entry` call, which -- if the same root cause
persists -- reproduces the identical failure and dies again at that second site. This is a
genuinely new finding (not in the original spot-sample): a redundant pause with far MORE wasted
intervening work than Batch 1's chain, even though it is likely rarer in practice. **The second
site needs no fix**: its own fall-through is already benign -- the very next line (`if
"%HP_ENTRY%"=="" (...)`) gracefully treats a blank entry as "no entry script detected, skip
PyInstaller packaging," not a crash. Fix: `goto :after_env_bootstrap` after the first site's
`call :die`, skipping the entire pointless dependency-install block when the entry is already
known-unresolvable. **Risk: MEDIUM** -- unlike Batches 1-2, this skips a large block of genuine
work (not just a misleading log line or a handful of already-doomed probe lines), so it is a real
behavior change deserving its own careful trace and test, not a drive-by lump into a lower-risk
batch.

**Batch 4 -- embedded-helper / file-staging write failures (7 sites).** Single-line `if errorlevel
1 call :die "..."` after a `call :emit_from_base64` / `copy` / redirected-write operation, all
top-level, no active call frame, scattered across different sections of the file: `Could not write
~detect_python.py` (inside `:after_conda_probes`), `Could not write ~print_pyver.py` / `Could not
stage ~condarc` / `Could not write %ENV_PATH%\.condarc` (all three inside `:conda_create_done`),
`Could not write ~prep_requirements.py` / `Could not stage PEP 723 requirements.` (both inside
`:after_env_mode_selection`), and `Could not write ~detect_visa.py` (inside `:lock_done`). Each
needs its own small trace (they are NOT one shared goto target -- each lives in a different part of
the dependency-resolution flow) but each trace is cheap and mechanical once done, the same per-site
effort Batch 1's sites needed, just spread across more distinct locations in the file. Low
real-world trigger rate: failure here implies a disk-write problem (permissions, disk full, AV
lock) that would almost certainly also break the very next real operation loudly and quickly.
**Risk: LOW per site**, but 7 independent small traces is real surface area -- batchable as
"several independent small gotos landed together" since none of the 7 share state with each other
(unlike Batch 1's genuinely chained sites), but each deserves its own one-line trace note in the PR
description so a reviewer isn't asked to trust 7 unexplained diffs.

**Batch 5 -- CI-only entry-helper staging (2 sites, both inside `:ci_skip_entry`).** Only reachable
under `HP_CI_SKIP_ENV=1`, a test-infrastructure-only flag never set by a real user or the default
bootstrap path. The `CI skip: entry helper staging failed` site (`~find_entry.py` staging)
structurally overlaps with Batch 4's write-failure shape, but is classified here by **exposure**
rather than shape, since exposure is what should drive landing priority -- this is the
lowest-priority batch of the six; could be deferred indefinitely with near-zero real-world cost.
The sibling site (`find_entry helper syntax error`) shares the same subroutine and exposure.

**Batch 6 -- `:try_conda_install`'s own failure sites (2 sites, both inside `:tci_both_failed`).**
Structurally different from every other batch: these live inside a genuinely `call`ed subroutine
(`:try_conda_install`, called once), and already have their own `goto :eof` immediately after the
if/else -- so falling through does NOT skip `:die`'s choreography and does NOT itself produce a
*dangerous* silent state; it simply means the CALLER proceeds to `:select_conda_bat`, finds no
conda.bat, and re-runs the entire Batch 1 chain a second time for the same root cause. **Batch 1's
own fix, once landed, already shrinks this site's blast radius as a side effect** -- post-Batch-1,
this cascade collapses from "`:tci_both_failed` then the full 5-6-pause Batch-1 chain" down to
"`:tci_both_failed` then just the first Batch-1 site's own single pause." A *complete* fix here
would need a signal-passing mechanism (a flag the caller checks right after `call
:try_conda_install` to skip straight to `:after_env_mode_selection`, since a plain in-place `goto`
inside the subroutine can't reach past its own `call`-frame return) rather than a simple in-place
goto -- a new, small piece of coordination, not a drop-in repeat of the Batch 1 pattern. **Risk:
MEDIUM** (new mechanism, not just a goto) -- recommend deferring until after Batch 1 lands and its
mitigating side-effect is confirmed via real CI, then reassess whether the residual one extra pause
is worth the added coordination code.

**No fix needed (2 sites, already traced and confirmed safe):**
- **The second `Could not determine entry point` site** (inside `:after_env_bootstrap`) -- see
  Batch 3 above; its own fall-through is already benign.
- **The "Active Python interpreter not resolved" sink** (inside `:after_env_mode_selection`) --
  every other batch's `goto` routes toward it. Already Item-45-backstopped for the one dangerous
  consequence (a doomed PyInstaller build): if this falls through, the only cost is some
  wasted-but-harmless intermediate work (a failed interpreter smoke-test attempt, a redundant
  `:determine_entry` call, some PEP 723 discovery attempts) before Item 45's `if not exist
  "%HP_PY%"` guard in `:run_entry_smoke` catches it. Lowest priority of everything traced in this
  pass; a goto here would only trim harmless wasted work, not close any remaining risk. Deferred
  indefinitely, or as a future opportunistic micro-slice.

**Total accounted for**: Batch 1 (5) + Batch 2 (1) + Batch 3 (1 fix + 1 no-op) + Batch 4 (7) +
Batch 5 (2) + Batch 6 (2) + the "Active Python interpreter not resolved" sink (no-op, deferred) =
20. Every remaining site now has an explicit classification; none are unaccounted for.

**No two sites are identical in shape.** A single mechanical find/replace could not safely close
all 20 -- each genuinely needed the same "what actually follows, is it doomed or not, where's the
right `goto` target" trace slice 1 performed, or an equivalently careful design for whichever
cross-cutting mechanism is chosen instead. That tracing is now done for all 20; what remains is
landing the batches above in priority order.

---

## Batch Roadmap (decided 2026-08-21)

**Maintainer decision, recorded here per Item 46's own "needs the maintainer's call" process
note:**
1. **End state**: (a) continues as a deliberate *stopgap*, not a permanent architecture. Once the
   remaining inventory is smaller and better understood (i.e., after these 6 batches land), a
   separate, dedicated effort will scope candidate (c) (`:die` itself halts the process) as the
   durable, closes-the-whole-class outcome -- per this doc's own existing guidance: a
   proof-of-concept on 2-3 already-understood sites, explicit multi-run CI soak time, a fresh
   re-audit of `:die`'s call sites at that time (this Finding 3 will be stale by then, since these
   batches will have shrunk the inventory further), and a deliberate decision to update
   `selfapps_entrysmoke_no_interpreter.ps1`'s own encoded contract (the one precisely-identified
   test that hard-depends on the current always-exit-0-on-failure behavior).
2. **Batching**: group by proven/traceable shape rather than one site per PR. The pattern is now
   proven twice (slice 1, and the Bucket B sibling); grouping structurally-identical, already-traced
   sites is a reasonable acceleration that does not increase risk, because each site within a batch
   is still individually traced (this Finding 3), each batch still lands as its own small,
   independently revertable PR, and the same full-matrix-CI-to-completion proof is still required
   before the next batch starts.
3. **Landing order** (priority = realistic exposure x how well-understood the fix is, not file
   order):
   - **Batch 1** (conda-acquisition-probe chain, 5 sites) lands first -- highest realistic exposure
     (a real, if uncommon, "conda never acquired" production scenario), lowest risk (proven shape,
     existing test already reaches it).
   - **Batch 2** (`:conda_create_done`'s "python.exe missing" check) landed next -- low risk, fixes
     a genuinely misleading message.
   - **Batch 4/5** landed after -- see "Implementation Status" below: Batch 4 turned out to need a
     per-site trace of "does skipping intervening code actually cascade into a second `:die`, or is
     it just benign wasted work" before committing to a fix, not a mechanical goto sweep as
     originally scoped; only 1 of the original 7 sites (the `~condarc` staging site) qualified.
     Batch 5 (2 CI-only sites, both inside `:ci_skip_entry`) landed as originally scoped for its own
     genuinely-cascading site (`CI skip: entry helper staging failed`); its sibling (`find_entry
     helper syntax error`) was confirmed already benign, no fix needed.
   - **Batch 3** (the entry-determination double-call, the first `Could not determine entry point`
     site inside `:after_env_mode_selection`) landed -- confirmed safe via a direct read of
     `:determine_entry`'s own subroutine body (errorlevel 1 means the entry-detection MECHANISM
     itself is broken -- helper staging or syntax-verify failed -- not "ambiguous" or "no files
     found," both of which already return 0 and are handled gracefully elsewhere). This closes the
     concern a CodeRabbit review round raised on the Batch 1 PR before Batch 3 itself had landed
     (asking whether the fix "resolves" the second `:determine_entry` call): it does not eliminate
     that second call, and never claimed to -- it only skips the pointless intervening work; if the
     same root cause persists, the second call's own `call :die` still fires, one pause, not zero.
   - **Batch 6** (`:tci_both_failed`'s two sites, `:try_conda_install` coordination) stays deferred
     -- see "Implementation Status" below for why its remaining value shrank further once traced.
   - **The "Active Python interpreter not resolved" sink** (inside `:after_env_mode_selection`)
     stays deferred indefinitely (lowest priority, already-mitigated, no fix currently planned).
4. **This pass's full trace (Finding 3 above) is the roadmap** -- no further blanket re-audit is
   needed before starting Batch 1; each batch's own PR should re-verify its own sites' current line
   numbers and surrounding code (this file's own history shows line numbers drift as unrelated work
   lands) but does not need to re-derive the classification from scratch.

### Implementation Status (2026-08-21, same session as the decision above)

All batches below were implemented, tested (where a test was warranted -- see each entry), and
locally committed on `claude/die-fatal-remediation-srj9jg` in ONE session as a continued research
pass -- **not pushed**. When this does get pushed, it should land as SEPARATE PRs per batch (one
commit per batch in the local history, so this is mechanical), preserving the "one batch lands at a
time, full CI proof before the next" discipline -- implementing several batches' worth of code
locally in one sitting does not change that landing discipline, it just means the design/trace work
for several batches is now already done and waiting.

- **Batch 1 (the 5 sites inside `:after_conda_bat_validation`/`:after_conda_probes`)** --
  implemented exactly as designed. `tests/selfapps_conda_bothfail.ps1` extended with assertions
  proving the chain collapses (no `'conda'`/`'python'`/`'python -V'`/`Conda not found at:`
  messages, reaches the `Active Python interpreter not resolved` sink).
- **Batch 2 (`:conda_create_done`'s "python.exe missing" check)** -- implemented as designed. New
  `missing_python` scenario in `tests/selfapps_die_emit_fallthrough.ps1` (distinct from
  `selfapps_cascade_conda_create_fail.ps1`'s own same-named but CASCADE-re-entry scenario, which
  never reaches this site).
- **Batch 4 -- SCOPE CORRECTED from the original 7-site estimate to 1 site (the `Could not stage
  ~condarc` site, inside `:conda_create_done`), after tracing each of the original 7 individually
  rather than assuming they shared one shape.** The original Finding 3 spot-sample called these
  "low-probability... would almost certainly also break the very next real operation loudly and
  quickly" without verifying WHAT that next operation actually does. A full per-site trace found
  only this ONE genuinely cascades into a SECOND `call :die` (the doomed `copy /y "~condarc" ...`
  right after it, since the source was never staged) -- the same "redundant pause for one root
  cause" shape every other batch targets. The other 6 (`Could not write ~detect_python.py`, `Could
  not write ~print_pyver.py`, `Could not write %ENV_PATH%\.condarc` [reached via ITS OWN direct
  trigger, not the staging site's cascade], `Could not write ~prep_requirements.py`, `Could not
  stage PEP 723 requirements.`, `Could not write ~detect_visa.py`) were each traced and found to
  fall through into either (a) a genuinely benign, silently-degraded continuation (stdout/stderr
  redirected to a file or the log, never the console -- e.g. the `~detect_python.py` site's own
  PYSPEC stays empty, a valid "no constraint" default) with no second `:die` and no misleading
  success claim, or (b) a convergence point the success path already reaches within a few lines
  regardless (the PEP 723 requirements site's own block already falls through to `goto
  :after_pipreqs_run` six lines later even without a fix). Reclassified as the SAME low priority as
  the sink (harmless wasted work, not a redundant-pause bug) -- NOT fixed in this pass; a goto here
  would trim some harmless waste, not close a remaining risk, and picking the WRONG goto target for
  one of these would risk silently skipping legitimate future work for negligible benefit. One
  exception worth a future look, not urgent: the `~detect_visa.py` site's fall-through logs "No
  pyvisa/visa imports detected" even when detection never actually ran -- a real but low-severity
  inaccurate-message case (skips an optional NI-VISA install step silently), same category as
  Batch 2's fix but lower value (optional feature, not a build-blocking path).
  New shared `HP_TEST_FORCE_EMIT_FAIL=<VARNAME>` hook added to `:emit_from_base64` itself (the
  subroutine behind all 7 -- and every other embedded-helper write in the file) to make the
  `~condarc` staging site testable; `condarc` scenario in `tests/selfapps_die_emit_fallthrough.ps1`.
- **Batch 5 (the 2 sites inside `:ci_skip_entry`)** -- SAME correction pattern as Batch 4, applied
  to a 2-site batch instead of 7. `CI skip: entry helper staging failed` (`~find_entry.py` staging)
  genuinely cascades into `find_entry helper syntax error` (`:verify_find_entry_helper` also fails
  against the never-staged file) -- fixed. The syntax-error site, reached via its OWN direct
  trigger (staging succeeded, syntax-verify itself found a problem), falls through to a benign "no
  entry script detected" convergence a few dozen lines later -- confirmed safe, no fix needed.
  `ci_skip_entry` scenario in `tests/selfapps_die_emit_fallthrough.ps1`; also documents a genuine,
  pre-existing, NOT-fixed-by-this-change finding: `:after_env_skip` writes `state=ok`
  unconditionally regardless of an earlier `call :die` in the same run (see
  `docs/agent-ndjson.md`'s new section for the full mechanism) -- near-zero exposure (`HP_CI_SKIP_
  ENV` is test-infrastructure-only) so not fixed here, flagged for a future pass if ever prioritized.
- **Batch 3 (the first of `:determine_entry`'s two per-run `Could not determine entry point`
  sites, inside `:after_env_mode_selection`)** -- implemented as designed, confirmed safe via
  reading `:determine_entry`'s own body directly (its `errorlevel 1` return path is ONLY reached
  when `~find_entry.py` staging fails or `:verify_find_entry_helper` finds a syntax error -- both
  mean the entry-detection MECHANISM is broken, never "ambiguous multiple entries" or "no .py
  files," both of which already return 0 and are handled gracefully elsewhere in this same
  subroutine). `determine_entry` scenario in `tests/selfapps_die_emit_fallthrough.ps1` asserts an
  exact count of 2 for the (identically-worded) die message at both call sites, plus the absence of
  a dependency-install-phase marker proving the large intervening block was genuinely skipped. The
  second call site (inside `:after_env_bootstrap`) is deliberately unchanged and remains reachable
  -- if the same root cause persists, its own `call :die` still fires once, not zero times; the fix
  only removes the pointless intervening work between the two calls, it does not eliminate the
  second call itself.
- **Batch 6 -- traced further, value confirmed lower than originally scoped, REMAINS DEFERRED.**
  `:try_conda_install` (home of `:tci_both_failed`'s two sites) has TWO call sites, not one: the
  main install-if-missing block (near the top of the file) AND a second, independent one inside
  `:cascade_acquire_conda` (the REQ-009 uv-to-conda cascade's own on-demand Miniconda acquisition
  -- see `docs/agent-interconnect.md`'s "Provider cascade execution re-enters env-create" section).
  The second call site's own fall-through (`goto :eof` twice, returning to
  `:cascade_acquire_conda`'s caller) does NOT re-enter the Batch 1 probe chain at all (that chain is
  specific to the first-attempt, non-cascade path) -- it proceeds fairly directly to a conda-create
  attempt that already gotos correctly (Batch 1 slice 1, pre-existing). So the second call site was
  already reasonably contained even before today's session. For the FIRST call site: Batch 1's own
  fix (now implemented) already collapses its fall-through from "the full 5-6-pause probe chain"
  down to "just `:after_conda_bat_validation`'s own first-site single pause" -- confirmed via
  re-tracing, not just asserted. The remaining value of a full Batch 6 fix (a new caller-side
  coordination flag, since a subroutine's own `goto` cannot reach past its `call`-frame return) is
  now down to "save ONE more redundant pause in an already-rare scenario," a smaller win than
  originally scoped and not worth the added coordination-state complexity right now. Deferred, not
  abandoned -- revisit if a future session finds this specific residual pause actually confusing
  real users.

### Finding 4 -- `:die`'s own existing choreography is exactly what any candidate must preserve

`:die` currently, unconditionally, in order: sets `HP_BOOTSTRAP_STATE=error`, logs the message,
writes `~bootstrap.status.json`, releases the concurrent-instance lock, pauses (unless
`HP_CI_LANE` is set) so a real double-click user can read the failure before the window might
close, THEN returns via `exit /b %RC%` -- the pause already precedes the exit, not the other way
around. Every candidate below must not regress any piece of this for any call shape -- this is the
load-bearing behavior Bucket B's own `:warn_build_incomplete` design already had to reason about
carefully (it deliberately skips 3 of these 4 actions, for a specifically non-doomed case).

**This exact ordering was re-verified directly against the current source during this pass
(2026-08-18), prompted by a direct question about why `:die` couldn't simply pause then fully
exit -- it turns out it already does exactly that shape for everything except the final `exit
/b` vs. `exit` choice.** That re-trace also surfaced a real, previously-uncaptured consequence of
candidate (c) specifically (the OS process exit code vs. the self-reported `~bootstrap.status.
json` `exitCode` field are two independent signals, and exactly one currently-gating test hard-
depends on the OLD process-exit-code behavior) -- see `docs/agent-lessons-learned.md`'s `:die`
entry for the full mechanism and verification trail, and candidate (c)'s own section below for
the corrected risk analysis this finding now feeds into.

---

## Candidate Approaches

### (a) Targeted `goto` per site -- continue the slice-by-slice pattern already proven twice

Add a `goto` (or, where a call frame is active and genuinely nothing useful follows, an
`exit /b`) immediately after each remaining `call :die` site, chosen individually via the same
trace-then-fix discipline slice 1 already demonstrated.

**Pros**
- Already proven twice this session (Bucket B's subroutine, slice 1's `goto`) with the same
  review/CI/CodeRabbit workflow already established -- no new process to invent.
- Each fix is small, independently reviewable, independently testable, and independently
  revertable -- matches this repo's own "one thing at a time" iteration rule and Item 46's own
  "EXTREME CAUTION, small slices" process note directly.
- Failure mode of getting ONE slice wrong is contained to that one site, not a class-wide
  regression.
- No new global state, convention, or mental model for future contributors to learn or
  accidentally violate.

**Cons**
- Slow: roughly 15-18 more sites (27 minus the 7 already-safe minus slice 1's own site) at this
  same investigation depth is plausibly 10+ more PRs, each needing its own full trace.
- Repetitive, and easy to under-invest in on slice N the way slice 1 was NOT under-invested in --
  slice 1 caught its own scope-overclaim (goto target relocates the pause, doesn't eliminate it)
  only through careful re-tracing; a future slice done faster/carelessly could ship an inaccurate
  claim the way slice 1 almost did.
- Produces no durable protection for a brand-new `call :die` site added next month by an unrelated
  change -- each fix is per-instance, not structural.

**Value-add**: incremental and compounding -- each slice makes the tool measurably more correct
with a small, provable, easily-reverted blast radius.
**Risk**: LOW per slice, contingent on maintaining the same trace discipline every time.

### (b) A global `HP_FATAL` flag, checked at chosen resumption points

`:die` sets `HP_FATAL=1` (in addition to its existing behavior); a number of checkpoints
throughout the file check `if defined HP_FATAL goto :fatal_exit` (or equivalent) after any
`call :die` that continues.

**Pros**
- One mechanism protects every CURRENT call site at once, and -- if checkpoints are placed
  generically enough -- automatically protects any FUTURE `call :die` site too, with no
  per-addition reminder needed.
- Conceptually simple to describe ("die is now really fatal, the flag just needs one check
  point per resumption shape").

**Cons**
- The real work is entirely in WHERE the checks go, and this file's own history is not
  reassuring on that front: `docs/agent-lessons-learned.md`'s "Provider-cascade dispatch is
  goto-based on purpose" entry and its sibling parse-time-expansion entries document multiple
  real, shipped bugs from exactly this class of "which shape is this call site, and did the fix
  account for it" mistake -- a missed or misplaced `HP_FATAL` check fails exactly as silently as
  a missing `goto` does today, for a different reason.
- Placement granularity is a real tradeoff with no free option: too coarse (a few funnel points)
  reproduces today's gaps under a new name; too fine (checked after nearly every call site) is
  close to as much editing surface as (a), while introducing a new mechanism on top.
- Ongoing tax on all future work: every future edit to `run_setup.bat` now has to also ask "does
  this new/moved code need an `HP_FATAL` check," a standing cost (a) does not impose once a site
  is fixed.
- Different, arguably larger testing burden: (a) is tested by exercising one site; (b) needs
  proof that EVERY meaningfully different resumption shape (top-level, nested one call deep,
  nested inside a parenthesized block, inside a `for /f` loop body) is actually covered -- more
  surface for a subtle gap to hide behind a passing test suite.

**Value-add**: HIGH once complete and genuinely proven across every shape -- closes the class, not
just the currently-known instances, and is durable against future additions.
**Risk**: MEDIUM-HIGH. The failure mode of an incomplete rollout is invisible by construction (it
looks finished, isn't) -- and this exact file has independently demonstrated, more than once (see
the DLL-bundling `%`/`^` sanitizer's three-rounds-of-being-wrong incident in
`docs/agent-lessons-learned.md`), that confident reasoning about this file's own cross-cutting
control flow has been wrong before, caught only by real Windows CI, not by review.

### (c) Make `:die` itself halt the process

Change `:die`'s own final `exit /b %RC%` to a genuine process-terminating `exit %RC%` (drop `/b`),
so it stops the whole run directly instead of returning control to whatever called it.

**Corrected 2026-08-18, via a hand-trace prompted by a direct question ("why can't `:die` just
pause then fully exit?") -- the risk framing below supersedes an earlier, less-verified version of
this section that (and CLAUDE.md's own prior text, which this doc had faithfully but uncritically
carried forward) cited "closes the console before the user can read the message" as the main
concern.** Read `:die`'s actual current body directly: it already does `pause` (when
`HP_CI_LANE` is unset) BEFORE its existing `exit /b %RC%` line. So on the real, interactive,
double-click-user path, the message-reading opportunity is already guaranteed regardless of what
the final exit line does -- swapping `exit /b %RC%` for `exit %RC%` at that exact point loses
nothing there. See `docs/agent-lessons-learned.md`'s `:die` entry for the full corrected
mechanism and the verification trail.

**Pros**
- Structurally the most complete of the three -- one change protects every current and future
  call site with no per-site or per-checkpoint work anywhere else.
- Matches what a reader unfamiliar with this file would likely assume `:die` already does --
  reduces future surprise for the next person who touches this code.
- The originally-cited "closes the window before they read it" risk does not actually apply, per
  the correction above -- the pause already happens first, unconditionally, on the path where it
  matters.
- Cmd.exe's own documented `EXIT` behavior (Microsoft's own help text: `/B` exits the current
  batch script; without it, `EXIT` quits CMD.EXE entirely, regardless of call depth) means a bare
  `exit` genuinely halts the whole process from ANY nesting depth -- the "top-level vs nested, not
  always obvious" framing this doc and CLAUDE.md previously used overstated the ambiguity; halting
  is not actually depth-dependent. (High-confidence from Microsoft's own documentation, not
  independently re-verified against a live Windows cmd.exe in this sandbox pass.)

**Cons**
- **The real, verified risk, found by tracing every `tests/*.ps1` file rather than reasoning about
  it in the abstract**: this repo tracks two independent "exit code" signals -- the real OS-level
  process exit code, and a self-reported `exitCode` JSON field inside `~bootstrap.status.json`
  (written by `:write_status`, unaffected by this change either way). Most `:die` sites today fall
  through to `:success`'s own unconditional `exit /b 0`, so the REAL process exit code is
  currently always `0` regardless of `state`, by design -- a deliberate "did the bootstrapper run
  to completion" vs. "did the product succeed" signal split this repo's own docs call the
  "graceful stop" contract. Converting `:die` to a genuine halt breaks that split for every
  affected call site. Verified exactly how many currently-gating tests actually depend on the OLD
  behavior (not just could theoretically be affected): **one** --
  `tests/selfapps_entrysmoke_no_interpreter.ps1:171` (`($statusState -eq 'error') -and ($runExit
  -eq 0)`) explicitly asserts this as part of its own pass condition. Every other `-eq 0` exit-code
  assertion found in the same sweep across `tests/selftest.ps1`,
  `tests/selfapps_ux_hardening.ps1`, `tests/selfapps_cascade_conda_create_fail.ps1`, and others
  turned out to be paired with a SUCCESS/recovery scenario where `:die` is never reached, so those
  are unaffected; a few other files capture the real exit code for diagnostics without asserting
  it. This is a narrow, precisely-identified breaking change (update one test's own encoded
  contract, a deliberate decision if this candidate is chosen), not a vague, unquantified risk.
- Whether ANYTHING outside this repo's own test suite depends on the current
  always-exit-0-on-failure behavior is genuinely unknown and unauditable from inside this repo
  (a real user's own external automation wrapping `run_setup.bat`, if any exists, is invisible
  here) -- this is a real, unresolved unknown for (c) specifically, not a solved one.
- Widest blast radius of the three -- touches the single subroutine every failure path in the
  entire file funnels through, so a mistake here has the largest possible reach of any of the
  three candidates.
- Hardest to ship incrementally -- (a) ships one goto at a time and (b) can, in principle, roll
  out checkpoint by checkpoint; (c) is much closer to all-or-nothing once `:die`'s own exit
  behavior changes, since every caller is affected simultaneously.

**Value-add**: potentially the HIGHEST of the three (closes the class AND simplifies the mental
model for every future reader), contingent on (i) the pause/lock-release/status-write
choreography (Finding 4) surviving correctly for every one of the ~67 `call`ed labels and every
top-level `goto` chain in the file, and (ii) a deliberate decision to update
`selfapps_entrysmoke_no_interpreter.ps1`'s own contract (now precisely scoped, not a mystery).
**Risk**: MEDIUM -- lower than this doc's own prior draft claimed, now that the sharpest
originally-cited risk is confirmed not to apply and the real remaining risk is precisely bounded
to one known test plus one genuinely-unknown (external-consumer) unknown. Still the riskiest of
the three by blast radius and by that one unresolved unknown, just not for the reason originally
stated.

---

## Recommendation

**Decided 2026-08-21 -- see "Batch Roadmap" above for the full decision and landing order.**
Summary: (a) continues, batched by proven shape (not one site per PR), as a deliberate stopgap;
(b)/(c) are explicitly deferred to a later, separately-scoped effort once the remaining inventory
is smaller, with (c) the more likely eventual candidate per the reasoning below (kept for
context, superseded in priority by the Batch Roadmap's own numbered decision list).

If the maintainer wants the more durable, closes-the-whole-class outcome that (b) or (c) offer,
**the choice between them is closer than this doc's own earlier draft suggested.** (b) remains
additive (never changes `:die`'s own already-correct, already-tested behavior for any existing
caller) where (c) is a direct modification to the one subroutine everything funnels through --
that structural difference still stands, and blast radius still favors (b). But candidate (c)'s
own risk section above was corrected during this pass: its sharpest originally-cited concern
("closes the console before the user reads the message") does not actually apply, given `:die`
already pauses before its existing exit line, and its remaining cost is now precisely bounded (one
test's contract to update, plus one honestly-unresolved external-consumer unknown) rather than the
vague "top-level vs nested, not always obvious" risk previously stated. (c) is genuinely more
viable than this doc first described -- the maintainer's call between (b) and (c) should weigh (b)'s
lower blast radius against (c)'s structural simplicity and now-bounded cost, not treat (c) as
automatically the riskier choice. Either would need to be scoped as its OWN dedicated effort, not
folded into the ongoing slice-by-slice work, with:
- a proof-of-concept on 2-3 already-understood sites (e.g. the ones Finding 3 above already
  traced) before any file-wide rollout,
- explicit multi-run CI soak time before being trusted, matching this item's own established
  process discipline for every other high-risk change in this file,
- and a fresh, complete re-audit of `:die`'s call sites at that time (this doc's Finding 1-3 data
  will be somewhat stale by whenever that work actually starts, since slice-by-slice work under
  (a) will have kept shrinking the remaining count in the meantime).

## Impact of Leaving This Undone

Current state, grounded in Finding 1-3 above: 27 sites total, 7 already effectively safe, roughly
20 remaining with heterogeneous but generally LOW-to-MEDIUM severity. The worst-case realistic
consequence class across the traced sample is a real, unattended user seeing 2-4 redundant
pauses/messages for what is really one root cause -- confusing and wasteful of the user's time,
not silently wrong. No evidence surfaced in this pass of any remaining site risking a FALSE
`state=ok` report or silent data loss -- that specific, more dangerous failure class was already
closed by two earlier, unrelated fixes: `:die`'s own centralized `HP_BOOTSTRAP_STATE=error` set
(closed before Item 46 existed, see `docs/agent-lessons-learned.md`'s `:die` entry) and Item 45's
guard against a doomed PyInstaller build specifically (closed, PR #437).

## Open Questions

**Both resolved 2026-08-21 -- see "Batch Roadmap" above.** Removed from `docs/open-questions.md`
accordingly. Kept here for historical reference only:
1. Which of (a)/(b)/(c) should Bucket A's next slice use -- continue (a), or pause the
   slice-by-slice work to scope (b) or (c) as their own dedicated effort first? **Answered:
   continue (a) as a deliberate stopgap; (c) is the likely eventual target for a separately-scoped
   future effort, not folded into the ongoing batch work.**
2. If continuing with (a): is there a target completion bar (all ~20 remaining sites? only the
   ones demonstrated to risk a redundant-prompt-replay like the `conda.bat not found` site in
   Finding 3? opportunistic, one slice per loop, with no fixed end state)? **Answered: all 20 sites
   are now traced and grouped into 6 batches (see Finding 3 and the Batch Roadmap), landed in
   priority order by exposure x how well-understood the fix is -- not a fixed site-count target,
   but not open-ended either.**
