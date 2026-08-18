# Plan: `:die` Non-Halting Fall-Through Remediation (CLAUDE.md Active Backlog Item 46, Bucket A)

**Status:** Research pass complete (2026-08-18), grounded directly against current `run_setup.bat`
source via `tools/audit_batch_exit_paths.py` and manual tracing -- not written from memory or
inference. No new code in this pass; this doc exists to support the maintainer's choice between
three candidate remediation shapes before Bucket A continues past its first slice. See CLAUDE.md's
Item 46 entry for the full incident history (Bucket B, closed; Bucket A slice 1, closed) this plan
picks up from.
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

### Finding 3 -- the remaining ~20 sites are heterogeneous, not one shape repeated 20 times

Spot-traced a representative sample (not all 20 individually, in keeping with this doc's own scope
as a decision-support pass, not a full remediation):

- **Same shape as the one slice 1 already fixed, not yet addressed**: the `conda.bat not found
  after bootstrap` site (~line 806) already calls `:handle_conda_failure` and checks
  `HP_ENV_READY` before its own `call :die` -- structurally identical to `:conda_create_failed`
  pre-slice-1. A real, non-cascade total-tier-exhaustion here falls through into the REQ-020 conda
  warm-up block and then the channel-policy check a few lines later, which itself calls `:die`
  again for the same underlying cause (`CONDA_BAT` still undefined) -- a chain of 2-3 redundant
  `[ERROR]` messages/pauses for one root cause, not a second consent-prompt replay (unlike slice 1's
  own finding) since `:handle_conda_failure` itself is not re-invoked here.
- **Cascading guarded-probe chain**: the `'conda' not found on PATH` / `'python' not found on
  PATH` / `'python -V' failed` trio (~lines 838-852) each independently call `:handle_conda_failure`
  and check `HP_ENV_READY` before falling through to the NEXT probe in the same chain -- similar
  shape to the finding above, same low-to-medium severity (redundant messaging, not silent
  corruption).
- **Backstopped downstream by Item 45**: `:conda_create_done`'s own `python.exe missing from conda
  environment` check (~line 1157) still falls through on a genuine hit, but any resulting broken
  `HP_PY` is now caught by Item 45's guard in `:run_entry_smoke` before a doomed PyInstaller build
  is ever attempted -- the dangerous consequence is already closed; what remains here is a
  redundant/confusing intermediate pause, not an unmitigated risk.
- **CI-only, near-zero production exposure**: two sites inside `:ci_skip_entry` (`~line 1908`,
  `~line 1911`) only execute under `HP_CI_SKIP_ENV=1`, a test-infrastructure-only flag never set by
  a real user or the default bootstrap path.
- **Low-probability "could not write an embedded helper" sites** (7 of the remaining ~20, e.g.
  `~detect_python.py`/`~print_pyver.py`/`~condarc`/`~prep_requirements.py`/`~detect_visa.py`
  staging failures): failure here implies a disk-write problem (permissions, disk full, AV lock)
  that would almost certainly also break the very next real operation loudly and quickly -- lower
  priority than the cascading-chain findings above, though not zero risk.

**No two sites are identical in shape.** A single mechanical find/replace could not safely close
all 20 -- each genuinely needs the same "what actually follows, is it doomed or not, where's the
right `goto` target" trace slice 1 performed, or an equivalently careful design for whichever
cross-cutting mechanism is chosen instead.

### Finding 4 -- `:die`'s own existing choreography is exactly what any candidate must preserve

`:die` currently, unconditionally, in order: sets `HP_BOOTSTRAP_STATE=error`, logs the message,
writes `~bootstrap.status.json`, releases the concurrent-instance lock, pauses (unless
`HP_CI_LANE` is set) so a real double-click user can read the failure before the window might
close, then returns via `exit /b`. Every candidate below must not regress any piece of this for
any call shape -- this is the load-bearing behavior Bucket B's own `:warn_build_incomplete` design
already had to reason about carefully (it deliberately skips 3 of these 4 actions, for a
specifically non-doomed case) -- see `docs/agent-lessons-learned.md`'s `:die` entry for the full
mechanism this finding depends on.

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

Change `:die`'s own final `exit /b` to a genuine process-terminating `exit` (or add a distinct
"fatal" variant it calls into for the doomed cases), so it stops the whole run directly instead of
returning control to whatever called it.

**Pros**
- Structurally the most complete of the three -- one change protects every current and future
  call site with no per-site or per-checkpoint work anywhere else.
- Matches what a reader unfamiliar with this file would likely assume `:die` already does --
  reduces future surprise for the next person who touches this code.

**Cons**
- CLAUDE.md's own Item 46 entry already flags the sharpest risk directly, not as a new concern
  introduced here: "a bare `exit` closes the console window immediately for a double-click user
  with no chance to read the message first" -- this file's whole pause-before-exit convention
  (documented throughout `docs/agent-lessons-learned.md`) exists specifically to prevent that for
  a real, unattended double-click user.
- The top-level-vs-nested distinction matters more here than for (a)/(b): `:die` is invoked from
  both genuinely top-level code (no active call frame -- Finding 2's 5 corruption-handler sites
  are exactly this shape) AND from deep inside nested subroutines
  (`:handle_conda_failure -> :try_venv_fallback -> ...`). Every caller across the whole file would
  need auditing for whether it ever relies on `:die` returning control on purpose (as opposed to
  accidentally, which is the bug) before this change could be trusted.
- Widest blast radius of the three -- touches the single subroutine every failure path in the
  entire file funnels through, so a mistake here has the largest possible reach of any of the
  three candidates.
- Hardest to ship incrementally -- (a) ships one goto at a time and (b) can, in principle, roll
  out checkpoint by checkpoint; (c) is much closer to all-or-nothing once `:die`'s own exit
  behavior changes, since every caller is affected simultaneously.

**Value-add**: potentially the HIGHEST of the three (closes the class AND simplifies the mental
model for every future reader), contingent entirely on the pause/lock-release/status-write
choreography (Finding 4) surviving correctly for every one of the ~67 `call`ed labels and every
top-level `goto` chain in the file.
**Risk**: HIGH -- named as the riskiest option in CLAUDE.md's own existing Item 46 text, not a
new judgment introduced by this doc.

---

## Recommendation

**(a), continued at the same slice-by-slice pace, is the recommended path for the immediate next
slice.** It is the only one of the three that fits Item 46's own already-stated "EXTREME CAUTION,
one slice at a time" constraint without modification -- (b) and (c) are not really "slices" at
all, they are single, larger, harder-to-partially-ship efforts by their own nature. This
recommendation is about the NEXT slice specifically, not a claim that (a) is the permanently
correct end state.

If the maintainer wants the more durable, closes-the-whole-class outcome that (b) or (c) offer,
**(b) is the more conservative of the two** -- it is additive (does not change `:die`'s own
already-correct, already-tested behavior for any existing caller) where (c) is a direct
modification to the one subroutine everything funnels through. Either would need to be scoped as
its OWN dedicated effort, not folded into the ongoing slice-by-slice work, with:
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

Registered in `docs/open-questions.md`:
1. Which of (a)/(b)/(c) should Bucket A's next slice use -- continue (a), or pause the
   slice-by-slice work to scope (b) or (c) as their own dedicated effort first?
2. If continuing with (a): is there a target completion bar (all ~20 remaining sites? only the
   ones demonstrated to risk a redundant-prompt-replay like the `conda.bat not found` site in
   Finding 3? opportunistic, one slice per loop, with no fixed end state)?
