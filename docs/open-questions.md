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

## From the October 2026 maintenance scan (CLAUDE.md "Periodic Maintenance Checks", filed 2026-10-24)

5. **Dependabot has never opened a pull request here, although six of the nine pinned GitHub Actions had fallen one to
   two majors behind.** `.github/dependabot.yml` (the `github-actions` ecosystem, weekly) was added 2026-08-17. Since then no
   pull request and no `dependabot/*` branch has existed, but the pins in `.github/workflows/*.yml` were behind
   (`checkout` v5 against v7, `cache` v5 against v6, `upload-artifact` v6 against v7, `download-artifact` v6 against
   v8, `github-script` v8 against v9, `codeql-action` v3 against v4), so Dependabot should have had something to
   propose. A session cannot read the repository settings that say why. On github.com, under Settings, Code security
   (or Advanced Security), is "Dependabot version updates" switched on, and does Insights, Dependency graph,
   Dependabot show an error or a last-checked time for `github-actions`? (A) If it is off, switch it on and the first
   pull requests arrive within a week; each is read in CI like any other. (B) If it is on and shows an error, paste the
   error (it names no secret) and the cause gets fixed in `dependabot.yml`. (C) If you would rather not run
   Dependabot, say so and a backlog item bumps the pins by hand, a few actions per pull request with one commit each.
   Default meanwhile: Item 90 bumped every pin by hand to the latest major of 2026-10-30 (`codeql-action` in PR #508,
   the other five in PR #513), which is what C would do anyway, so nothing is urgent; the quarterly scan re-reads the
   majors and bumps by hand until this is answered, and a switched-on Dependabot would only add pull requests for the
   next drift.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

Q1-Q11 are decided or retired. No field-report question is open.
