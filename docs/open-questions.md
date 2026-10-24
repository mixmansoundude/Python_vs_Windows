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

## From the build-tool override (Item 71, filed 2026-10-23)

4. **`PVW_BUILDER=both` builds the optimized EXE without the question README REQ-018.2 requires.** With `both`, the
   bootstrapper builds the Nuitka EXE straight after the PyInstaller EXE passes verification and asks nothing, because
   the setting is the request. The new EXE's own verification starts the program once more for up to 30 seconds (the
   log line says so), and it does so even when `HP_CI_LANE`, `NOINPUT` or `HP_NONINTERACTIVE` is set. README REQ-018.2
   [critical] says every run beyond the single automatic one needs explicit consent in a prompt that names the risk, and
   REQ-018.9 says every elective offer is declined without waiting in a non-interactive run. Same shape as
   `HP_PVW_KNOWN_IDEMPOTENT`, whose name is its own consent. (A) Keep it and add one sentence to REQ-018.2: a super-user
   setting whose documented purpose is that run counts as the consent. (B) Ask the question under `both` as well, so a
   non-interactive run declines and `both` only builds the optimized EXE when someone answers. Default meanwhile: no code
   change; README REQ-009.20 carries a note pointing here. A is reversible and is what gets written on a yes.

## From the October 2026 maintenance scan (CLAUDE.md "Periodic Maintenance Checks", filed 2026-10-24)

5. **Dependabot has never opened a pull request here, while six of the nine pinned GitHub Actions are one to two
   majors behind.** `.github/dependabot.yml` (the `github-actions` ecosystem, weekly) was added 2026-08-17. Since then no
   pull request and no `dependabot/*` branch has existed, but the pins in `.github/workflows/*.yml` are behind
   (`checkout` v5 against v7, `cache` v5 against v6, `upload-artifact` v6 against v7, `download-artifact` v6 against
   v8, `github-script` v8 against v9, `codeql-action` v3 against v4), so Dependabot should have had something to
   propose. A session cannot read the repository settings that say why. On github.com, under Settings, Code security
   (or Advanced Security), is "Dependabot version updates" switched on, and does Insights, Dependency graph,
   Dependabot show an error or a last-checked time for `github-actions`? (A) If it is off, switch it on and the first
   pull requests arrive within a week; each is read in CI like any other. (B) If it is on and shows an error, paste the
   error (it names no secret) and the cause gets fixed in `dependabot.yml`. (C) If you would rather not run
   Dependabot, say so and a backlog item bumps the pins by hand, one action per pull request. Default meanwhile: the
   pins are bumped by hand, one action per pull request (CLAUDE.md Item 90, started with `codeql-action`), which is
   what C would do anyway; the runner forces the Node.js 20 actions onto Node.js 24, so nothing is urgent.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

Q1-Q11 are decided or retired. No field-report question is open.
