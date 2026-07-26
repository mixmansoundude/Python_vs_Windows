# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

_No open items right now._ The cascade-consent design question (was item 1: whether the cascade
decision should remain an interruptive consent prompt at all, given `HP_CASCADE_CANDIDATE`'s own
mixed reliability) is now resolved -- kept exactly as shipped, no code change. See CLAUDE.md's
Known Findings entry for the decision and `docs/agent-interconnect.md`'s "Cascade signal
reliability" subsection (under "Post-execution checkpoint") for the full truth-table analysis
that informed it.
