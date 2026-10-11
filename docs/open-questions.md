# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

Q1-Q9 are decided or retired. One question is open, from Item 82 (filed 2026-10-11):

- **Q10 -- Item 82: record a window app's pass on the conda run?** A window app's check run is
  stopped after about 30 silent seconds (exit `-1`), so on a cascade-reached conda run it can never
  end in a clean exit 0 and so never counts as a verified pass for Item 66's provider memory.
  Options: (a) ask once on that conda run only, "Your window app was still running when the check
  stopped it. Did it open and work? [Y/N]", and record a yes as `user_confirmed`; (b) never ask,
  record nothing, and leave `PVW_PROVIDER=conda` (Item 66) as the manual route; (c) count a silent
  timeout on the conda run as a pass without asking. Maintainer's quote that prompted it: "after I got
  it to run after the cascade to conda, then modifying requirements.txt to add xlsxwriter and running
  bootstrapper again it tries UV and goes deep down the rabbit hole". Agent recommendation: (a).
  **Default until answered: (b)**, no extra prompt, nothing recorded for a window app.
