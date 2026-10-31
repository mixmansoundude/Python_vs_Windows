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

## From the Item 90 follow-up (Dependabot, filed 2026-10-31)

6. **Should Dependabot's pull requests merge themselves?** Dependabot could not read `.github/dependabot.yml` until
   2026-10-31 (the option `open-pull-request-limit` is spelled `open-pull-requests-limit`, and a file with one unknown
   option is rejected), which is why it opened no pull request in ten weeks; the first one arrives when an action
   releases a major newer than its pin. `pr-automerge.yml` arms auto-merge for every same-repo pull request that does
   not carry `no-automerge`, so a Dependabot pull request would merge itself once "Aggregate self-test verdicts" is
   green (every row of every lane, but not the annotations Item 90 read before each bump). (A) Keep what the file sets
   now: the label `no-automerge` on every Dependabot pull request, so each stays open until a session has read its runs
   and merges it. (B) Delete `labels:` from the file, and they merge by themselves like any other pull request.
   Default meanwhile: A.

## From the Aug-Sep 2026 field report (`docs/plan-field-report-2026-10.md`, filed 2026-10-08)

Each question names the backlog item it blocks and the default an implementing agent should use

Q1-Q11 are decided or retired. No field-report question is open.
