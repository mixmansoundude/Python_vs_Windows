# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

Q1-Q8 are decided or retired. One question is open:

### Q9 -- Which `.py` files count as "the app" for the NI-VISA install? (blocks the scan-scope part of Item 78)

Asked 2026-10-09 after a real run installed NI-VISA because an archived subfolder held an
`import visa`, while the program being run did not use it. The maintainer's words: "in a subfolder
there is a .py that has an import visa in it (saved in an archived folder so I can easily switch
between what program I am testing), maybe it found it there."

Today: `tools/detect_visa.py` walks every subfolder (it skips only `~`- and `.`-prefixed directories),
so any `import visa` or `import pyvisa` line anywhere under the folder starts a driver install that
can run 30-45 minutes and may fail. README REQ-008 says only "If the app imports `pyvisa` or
`visa`", without saying which files are the app.

Options: (1) only the entry file and the local files it imports can start the install;
(2) the same limit for all dependency discovery, not just VISA; (3) keep the whole folder and
document it in REQ-008. **Default until answered: change nothing about scanning.** Recommended:
option 1. The answer is also recorded in the thread's decision card.
