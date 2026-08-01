# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

**1. Is the `cache` CI lane's self-perpetuating-corruption bug (CLAUDE.md Active Backlog item 19)
worth fixing, given the lane is explicitly non-gating/informational by design?** Diagnosed
2026-07-31: once a restored cache is flagged corrupted, the lane has no code path that ever
produces a fresh valid cache again (the one step that could do a fresh install is skipped
whenever corruption is detected, and the save step is gated on the same flag) -- so it likely
never recovers on its own, consistent with the maintainer's own report that it "never works."
A concrete fix is reasoned through in item 19's own writeup (treat a `restore-keys` prefix-match
corruption the same as a genuine cache miss: delete the bad directory, let a fresh install and
fresh save proceed normally) but verifying it needs multiple real cache-lane CI cycles to observe
"does a fresh cache finally get saved," which is slower and more failure-prone to get right than
a typical code fix. Since this lane exists purely to save ~99 MB of download time and is
deliberately excluded from PR-merge gating either way, is it worth the multi-cycle verification
effort, or should it stay as documented, low-priority backlog debt? No strong reason not to
attempt it in a dedicated future loop either way -- flagging so the priority call is explicit
rather than assumed.
