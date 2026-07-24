# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

_No open items right now._ The CLI / stdin-interactive Python program work that used to be
tracked here (item 1, live-echo + stdin passthrough + the 30s-kill question) is now fully
resolved through P0 -- see `docs/plan-cli-interactive-verification.md`, `CLAUDE.md`'s Closed
Backlog, and `docs/agent-interconnect.md`'s "Live-echo redesign" / "Activity-aware EXE-smoke
kill" sections. P1 (argv passthrough) and P2 (honest ambiguous-exit messaging) are still open
*implementation* work, but not open *questions* -- the owner has already approved trying both
("P1 and p2 at least look good enough to try", 2026-07-24), so they're tracked as Active Backlog
work in `CLAUDE.md`, not here.
