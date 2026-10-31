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

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

Q1-Q11 are decided or retired. No field-report question is open.

## From the Item 96 review (filed 2026-10-31)

Asked in chat on 2026-10-31, with a longer explanation that includes the history of how the run-once rule came to be
broken (kept in the project files as `item97/item97-explained.md`).

7. **May the `--hidden-import` repair loop start the program again, and does it have to ask first?** (Item 97; blocks the
   consent question in `:hidden_import_recover` and its README wording.) README REQ-018.1 allows one automatic start of the
   user's program per run, REQ-018.2 requires a question that names the risk before any other start, and REQ-018.7 accepts
   a 30 second check run inside the repair loop, so the README says two things about the same starts.
   What the user sees today, for a program that loads one package by name at the end (the EXE builder cannot see it) and
   stops with `ModuleNotFoundError`: start 1 is the check run, announced as a throwaway. Start 2 is the loop starting the
   EXE again from `dist\` with a one-line warning and no question, only to read the same error that `~run.err.txt` already
   holds. Then the loop rebuilds with `--hidden-import=X` and start 3 checks the repair; up to three rebuilds, so up to five
   starts. A program that fails for another reason gets start 2 as well, and on main today a third start from the failure
   hints (Item 96 removes that one). A script that is not safe to run twice (it appends a suffix to every row, sends a
   message) repeats its work each time, and from `dist\` it may not even find its input files.
   Options: (A) read the saved output of the first run to find the package, so the loop needs no start to learn the error,
   and start the program once after each rebuild to check the repair, announced; the README would still have to allow that
   check start. (B) Keep the code and amend the README so REQ-018.1 allows the loop's starts. (C) Keep the loop exactly as it
   is and ask once before its first extra start: default No, 30 seconds, the same gate as the other four elective offers.
   The user would see a warning that names the risk and the line `Run your program again to try to repair it? [y/N]`; Yes
   behaves as today, No leaves one start and prints the usual hint for adding the package by hand. Starts for the example
   program: today 3; A 2; C 3 on Yes and 1 on No (after Item 96).
   Maintainer's lean (2026-10-31): C as a first pass with nothing else changed, no question when `HP_PVW_KNOWN_IDEMPOTENT` is
   set or in a non-interactive run (REQ-018.9); later, read the saved output first and ask only when it names a package that
   can be added, and add a third answer "do not ask again for the next N runs" to the consent gates. Default meanwhile:
   nothing changes in the loop. The option A build is paused and unpushed. Needs one yes or no from the maintainer on the
   first pass before it is built.
