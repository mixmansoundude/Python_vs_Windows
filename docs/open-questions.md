# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use
if it is still unanswered when that item is picked up.

- **Q2 (Item 65 slice 2) -- When your program's own run names a missing package (for example
  `No module named 'xlsxwriter'`), may the bootstrapper install it, add it to
  `requirements.txt`, and rebuild automatically?** It would NOT re-run your program unasked
  (REQ-018). **Default: ship slice 1 (name the package clearly) first; hold slice 2 for an answer.**
- **Q3 (Item 66) -- Should forcing conda become a supported super-user switch?**
  `HP_FORCE_CONDA_ONLY` is CI scaffolding today (REQ-019). Options: rely on Item 66 (remember the
  provider that worked), or also add a `PVW_PROVIDER=conda` override. **Default: Item 66 only.**
- **Q4 (Item 63) -- What else was in the Aug app folder?** Specifically: any `.py` files besides
  `main.py`/`adjacent.py` (for example files extracted from the shipped EXE, which would explain
  `pyimod02_importers`), and any emoji or other non-English characters in the source. These are
  hypotheses: extra `.py` files or non-English text are harmless on their own, but a file pipreqs
  cannot read in the locale encoding, or one that fails to parse, aborts its whole scan so it
  reports nothing. Not blocking; Item 63's fix is right either way.
- **Q5 (Item 69) -- Where did you paste the post-flight "run it yourself" command that failed
  with quotes: Command Prompt or PowerShell / Windows Terminal?** If PowerShell, the fix is to
  also print a `& "..." "main.py"` form, not to drop the quotes. **Default: show both forms.**
- **Q6 (Item 71) -- Builder choice: super-user override only, or also a prompt?** **Default:
  `PVW_BUILDER` override only**, no new prompt on the default double-click path.
- **Q7 -- What did "Dep source should be ~?" mean?** Best guess: `dependency_source.txt` (and
  maybe `requirements.auto.txt`) should get the `~` prefix like other generated files. Note that
  on current code it always says `dependency_source=unknown` for pipreqs-only apps (Item 68).
  **Default: no rename until answered.**
