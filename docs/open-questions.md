# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

- **Q7 -- What does "Dep source should be ~?" mean?** Field note, verbatim (single line, nothing
  after it): "Dep source should be ~?" The line before it is about `main.py` importing
  `adjacent.py`, and the line after mentions `~pipreqs.diff.txt`. Best guess: the `~` prefix
  should apply to `dependency_source.txt` like the other generated files. **Default: no rename
  until answered.**
