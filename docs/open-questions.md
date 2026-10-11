# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

## From the test-suite gap map (`docs/plan-test-suite-gaps.md`, filed 2026-10-11)

Each question names what it blocks and the default an implementing agent should use meanwhile. Asked in
chat one at a time; the later ones wait their turn.

1. **REQ-018.2 versus the optimized-build offer** (asked in chat 2026-10-11). `:offer_optimized_build`
   (`run_setup.bat`, about line 3441) asks "Want to build an optimized version too? ..." and, on yes,
   starts the new program once more for up to 30 seconds to verify it before swapping it in. README
   REQ-018 requires consent that names the risk of running the program twice for any run beyond the single
   automatic one; the prompt does not name it. Options: (A) add one sentence to the prompt saying it
   starts the program once more for up to 30 seconds, (B) exempt the optimized build in the README,
   (C) swap without verifying (rejected). Default: A. Blocks: the REQ-018 rewrite and a `self.optbuild.*`
   prompt-text row.
2. **Behaviors the tests check but the README never states** (gap map "Spec gaps", item 5): the console
   message tiering, the `PVW_PYTHON_EXE` and `PVW_WORKSPACE` overrides, the PVW QuickStart workflow, the
   progress heartbeat during long conda and pip steps, and pyserial detection. Which become shalls?
   Default: leave them as unspecified rows in the coverage map until each requirement section is worked.
3. **"Non-interactive" is not one condition** (gap map "Spec gaps", item 3): the optional offers
   auto-decline on `HP_CI_LANE`, `NOINPUT` or `HP_NONINTERACTIVE`; the system-build, cascade and corrupt
   conda gates on `HP_CI_LANE` only; the connectivity retry loop on `NOINPUT` or `HP_NONINTERACTIVE`
   only; `pause` on `HP_CI_LANE` only. Which signals should README REQ-018 treat as "non-interactive"?
   Default: no change until the no-flag default-run scenario (T12) shows how much it matters.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

No questions are open for this report. Q1-Q10 are decided or retired.
