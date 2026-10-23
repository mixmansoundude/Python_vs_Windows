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

1. **Behaviors the tests check but the README never states** (gap map "Spec gaps", item 5): the console
   message tiering, the `PVW_PYTHON_EXE` and `PVW_WORKSPACE` overrides, the PVW QuickStart workflow, the
   progress heartbeat during long conda and pip steps, and pyserial detection. Which become shalls?
   Default: leave them as unspecified rows in the coverage map until each requirement section is worked.
2. **"Non-interactive" is not one condition** (gap map "Spec gaps", item 3): the optional offers
   auto-decline on `HP_CI_LANE`, `NOINPUT` or `HP_NONINTERACTIVE`; the system-build, cascade and corrupt
   conda gates on `HP_CI_LANE` only; the connectivity retry loop on `NOINPUT` or `HP_NONINTERACTIVE`
   only; `pause` on `HP_CI_LANE` only. The README Terms now define a non-interactive run as any of the
   three set (the documented user controls `NOINPUT` and `HP_NONINTERACTIVE`, plus the CI marker
   `HP_CI_LANE`), and a shall that says "every gate resolves in a non-interactive run" will not hold for
   the gates that read fewer signals. Which gates should read all three? Default: no code change until the
   no-flag default-run scenario (T12) shows how much it matters; word each shall per gate until then.

## From the real-app scenario (Item 75, filed 2026-10-23)

3. **A requirements.txt edit made after the first run is silently superseded by the PEP 723 header the first run wrote.**
   After a fully successful first run (uv lane) the bootstrapper writes a `# /// script` block with the program's
   dependencies into the entry file (README REQ-005.11). On every later run that header outranks `requirements.txt`
   (README REQ-005.1, `run_setup.bat` ~1615: `copy /y "%PEP723_REQ%" "requirements.txt"`), so a user who adds a package to
   `requirements.txt` gets nothing installed, the file is overwritten with the header's list, and the console prints
   `Using requirements.txt for dependencies` followed by `Using dependencies from PEP 723 metadata`. Seen in
   `~realapp_run3.log` of the Item 75 scenario (`self.realapp.edit_rerun`: `recordedSource: "pep723"`,
   `termcolorInstalled: false`, `termcolorInRequirementsAfter: false`). The row asserts the run is consistent with the
   source it names, so it passes whichever way this is decided. Which behavior should a user get?
   (A) Keep the documented precedence and print one line when the two lists differ ("requirements.txt was not used:
   the PEP 723 header in main.py outranks it; edit the header or delete it"). (B) A newer `requirements.txt` than the
   header wins and the header is rewritten from it. (C) Stop writing the header back unless the user asked for it.
   Default meanwhile: no code change. A is reversible and keeps REQ-005.1 as written, so it is what gets built on a yes.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

Q1-Q11 are decided or retired. No field-report question is open.
