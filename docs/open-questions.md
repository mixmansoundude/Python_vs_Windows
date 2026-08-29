# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

## 1. CLAUDE.md Active Backlog Item 35: does the agent have (or can it get) the GitHub repo-admin access needed to actually flip a check to gating?

Item 35's real mechanism (an aggregate `selftest-gate` check that could cover every lane with one
required-check entry) is implemented and its precondition has landed, but "gating" in this repo is
a GitHub branch-protection setting, not a YAML edit (confirmed by reading `pr-automerge.yml` -- it
delegates entirely to GitHub's own branch-protection evaluation). Promoting a lane or the aggregate
check to actually block merges needs someone with repo-admin access to add its exact check name to
the required-status-checks list.

Two sub-questions:
- Does this session's GitHub access include repo-admin/branch-protection scope, or does that need
  to be granted separately?
- If not, do you want to make that specific branch-protection edit yourself once a slice is proven
  ready (the agent would flag "ready to gate: `<check name>`" at that point), or is there another
  path to get it done?

Without an answer, Item 35's own soak-then-promote slices can get PREPARED (implemented, tested,
several green runs) but never actually CLOSED -- the last step structurally can't happen without
this.

## 2. CLAUDE.md Active Backlog Item 42, lever 2: is the two-prompt fresh-build flow still worth changing, and if so, reword only or also combine the two prompts?

Lever 1 (console-output tiering) shipped and merged 2026-08-24 (PR #466). Lever 2 -- the two
elective Y/N prompts every successful fresh interactive build shows (`:run_postexec_checkpoint`'s
"Run again via the interpreter now?" and `:offer_optimized_build`'s "Want to build an optimized
version too?") -- remains untouched, per the item's own explicit scoping of lever 1 and lever 2 as
"two independent, separately-implementable levers -- do not conflate them into one change."

Re-reading both prompts' CURRENT wording directly against source (`run_setup.bat`, `:run_
postexec_checkpoint`/`:offer_optimized_build`) before filing this: both already carry a plain-
language one-line rationale before the Y/N line itself (the checkpoint: "You can run your program
again now via the interpreter as an extra diagnostic check."; the optimized build: "It takes a bit
longer to build right now, but it starts up more reliably on Windows and runs faster once it is
built."). This is not the same wording the original 2026-08-14 audit was reacting to -- whether
that's because it was already improved in an intervening pass, or the audit's own phrasing was
simply summarizing rather than quoting verbatim, was not tracked down. Neither prompt currently
uses an explicit "(optional, safe to skip)"-style cue.

**Two open sub-questions, neither pre-decided:**
- Given the current wording already states a concrete, comprehensible tradeoff for each prompt
  (not jargon like "Visual Studio Build Tools" -- that phrase only appears in a `[WARN]`-tier
  post-FAILURE hint, shown to a small subset of users who hit a build error, not in either prompt
  itself), is there still a real gap to close here, or has this already been substantially
  addressed by wording that evolved separately from this item? If still worth doing, is the
  remaining ask as small as adding an explicit "(optional)" cue to both prompts, or something more?
- Should the two prompts stay separate (matching each prompt's own distinct consent-gate mechanism
  and existing test coverage -- `self.checkpoint.accept`/`.decline`, `self.optbuild.offer`'s 4
  scenarios) with wording-only changes, or should they be combined into a single ask as the item's
  own original text floated ("consider combining them into a single, clearly-optional ask")?
  Combining is a materially bigger change (restructures which subroutine owns the prompt, how
  declining one but not the other is expressed, and every test that currently asserts prompt COUNT
  or exact prompt text) than a pure reword, with real risk of a maintainer having a specific
  preference on exactly how the combined flow should read.

**Needs the maintainer's call** -- unlike lever 1 (a single, objectively-correct technical
mechanism: hide diagnostic-tier lines, keep them in the log, add an opt-in flag), lever 2 is
user-facing copy and interaction flow, where a wrong unilateral guess costs a maintainer real
rework rather than just being "one valid implementation among several."
