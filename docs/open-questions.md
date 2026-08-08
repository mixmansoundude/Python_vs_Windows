# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

## 1. Should the post-flight caveat panel surface a DLL-specific hint now that the repair loop exists and its real-CI confirmation has landed?

**Status: UNBLOCKED, ready for a decision as of 2026-08-08.** This question was deliberately left
sitting until `self.layered_e2e.chain`'s own real-CI confirmation landed (see
`docs/agent-closed-backlog.md`'s Item 24/28/29 entries) -- that has now happened (`chainPass:true`,
PR #421 merge). Nothing further is blocking a decision; this is purely a product/UX call for the
maintainer, not something to settle unilaterally.

**Background**: README.md's REQ-016 spec (current, correctly implemented) already guarantees the
post-flight briefing always shows the direct interpreter-run command regardless of EXE
verification outcome, and separately shows a generic "couldn't fully verify it runs as a
standalone program" caveat when the EXE smoke run failed -- deliberately never asserting a root
cause (an already-settled design decision from REQ-027 P2; see `docs/agent-interconnect.md`'s
"Honest ambiguous-exit messaging" section).

**The question**: `:dll_bundle_recover` (CLAUDE.md's closed Item 24) now computes a concrete,
specific fact the bootstrapper didn't have before -- whether a missing native-DLL dependency was
detected, and whether a repair was attempted and succeeded/failed. Should the post-flight caveat
panel surface this fact when relevant, instead of staying purely generic? This would still be
in scope of the "no general root-cause guessing" principle (it's a real signal the mechanism
already computes, not a guess), but is new user-facing wording that has never shipped.

**If yes, any wording must model three distinct states, not one** (a review pass on PR #414
caught this): detection and repair are NOT the same event, and repair is a no-op under a
non-conda provider or a Nuitka-built EXE (Item 24 Requirements 3/6), so detection can fire with
no repair ever attempted. Real, already-emitted log lines back all three states:
- **Detected, repair skipped** (`[INFO][DLL_BUNDLE] Detected native-DLL warning...skipping.`) --
  wording must NOT claim "attempted to fix it automatically."
- **Detected, repair attempted and failed** (no `Native-DLL bundling complete` line despite a
  `Bundling native DLL dependency` attempt) -- "we detected and attempted to fix" is accurate.
- **Detected, repair attempted and succeeded** (`Native-DLL bundling complete`) -- this caveat
  panel only fires on an EXE verification FAILURE, so this state likely never co-occurs with the
  panel firing in practice; worth confirming against real evidence before assuming it's dead code.

**Decision needed**: implement this new caveat wording (and if so, in this loop or backlogged),
or leave the caveat panel purely generic indefinitely and close this question as "declined"?
