# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

- **Q5 (Item 69) -- Where did you paste the post-flight "run it yourself" command that failed
  with quotes: Command Prompt or PowerShell / Windows Terminal?** If PowerShell, the fix is to
  also print a `& "..." "main.py"` form, not to drop the quotes. **Default: show both forms.**
- **Q6 (Item 71) -- Builder choice: super-user override only, or also a prompt?** **Default:
  `PVW_BUILDER` override only**, no new prompt on the default double-click path.
- **Q7 -- What did "Dep source should be ~?" mean?** Best guess: `dependency_source.txt` (and
  maybe `requirements.auto.txt`) should get the `~` prefix like other generated files. Note that
  on current code it always says `dependency_source=unknown` for pipreqs-only apps (Item 68).
  **Default: no rename until answered.**
