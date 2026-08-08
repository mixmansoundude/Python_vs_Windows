# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

## 1. Should the post-flight caveat panel surface a DLL-specific hint once the new repair loop's own detection signal exists?

README.md's REQ-016 spec (confirmed current, correctly implemented today) already guarantees the
post-flight briefing always shows the direct interpreter-run command regardless of EXE
verification outcome, and separately shows a generic "couldn't fully verify it runs as a
standalone program" caveat when the EXE smoke run failed -- this generic caveat deliberately never
asserts a root cause (an explicit, already-settled design decision from REQ-027 P2, see
`docs/agent-interconnect.md`'s "Honest ambiguous-exit messaging" section: "Neither panel asserts a
root cause... Open Question 3 explicitly leaves root-cause distinction unsolved").

This is a narrower question than reopening that settled one: once the Item 24 repair loop's own
detection mechanism exists (a build-time `Library not found: could not resolve` warning, or a
runtime DLL-load-failure signature -- see the PRD's Finding 5), that SAME signal is a concrete,
specific, already-computed fact the bootstrapper doesn't have today -- not a general root-cause
guess. This stays fully in scope of the already-decided "no general root-cause claims" principle
-- it surfaces a fact the new mechanism computes anyway, not a guess about causes the bootstrapper
can't actually determine.

**Correction from an earlier draft of this question (a review pass on PR #414 correctly caught
this): detection and repair are NOT the same event, so any wording needs at least three distinct
states, not one.** Per the PRD's own Requirement 3, the repair ACTION is a no-op under any
non-conda provider (detection stays provider-agnostic and cheap; only the actual DLL-bundling
attempt is conda-gated); per Requirement 6, it is also skipped for a Nuitka-built EXE
(`HP_NUITKA_FALLBACK_USED`). So the detection signal can fire with NO repair attempt ever made:

- **Detected, repair skipped** (non-conda provider, or Nuitka-built EXE): the caveat panel must
  NOT say "attempted to fix it automatically" here -- nothing was attempted. Detection-only
  wording only (e.g. "we detected a missing native library").
- **Detected, repair attempted and failed**: the loop tried and the DLL still isn't resolved (or a
  transitive dependency chain wasn't fully walked). "We detected and attempted to fix" is accurate
  here.
- **Detected, repair attempted and succeeded**: the EXE should now actually work, so this caveat
  panel (which only fires on an EXE verification failure) likely never reaches this state in
  practice for the SAME run that succeeded -- worth confirming once the loop exists, not assumed.

Any eventual wording change must model these as distinct states (or at minimum gate the
"attempted" language on a real "repair was attempted" flag, not just "detection fired"), not
collapse them into one caveat sentence.

**Update 2026-08-04: the repair loop itself now exists** (`:dll_bundle_recover` in
`run_setup.bat`, CLAUDE.md Item 24), so this question is no longer blocked on a future
mechanism -- the three states above map directly onto real, already-emitted log lines
(`[REPAIR][DLL_BUNDLE] Bundling native DLL dependency: ...` for attempted, `[REPAIR][DLL_BUNDLE]
Native-DLL bundling complete` for attempted-and-succeeded, absence of either for
detected-but-skipped). Still not urgent enough to implement speculatively ahead of
`self.layered_e2e.chain`'s own real-CI confirmation that the loop works end-to-end (see Item 24's
own "NOT YET CONFIRMED in real CI" note) -- revisit once that lands.
