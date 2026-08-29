# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

## 1. CLAUDE.md Active Backlog Item 46 (Bucket A): which remediation shape for the remaining `:die` non-halting fall-through sites?

Full research, pros/cons/value-add/risk writeup: `docs/plan-die-fatal-remediation.md` (2026-08-18).
Three candidates, none pre-decided:

- **(a) Targeted `goto` per site** -- continue the slice-by-slice pattern already shipped twice
  (Bucket B's `:warn_build_incomplete`, Bucket A slice 1's `goto`). Lowest risk, slowest, no
  durable protection against a future un-gotoed `call :die` site.
- **(b) A global `HP_FATAL` flag** -- one mechanism, checked at chosen resumption points, protects
  current AND future sites. Higher value if done right; real risk the checkpoint placement itself
  is incomplete or wrong, invisibly.
- **(c) Make `:die` itself halt the process** -- most complete. **Corrected 2026-08-18** (via a
  direct hand-trace, prompted by a maintainer question): the originally-suspected "breaks the
  pause-before-exit convention" risk does NOT apply -- `:die` already pauses before its existing
  exit line. The real, precisely-bounded risk instead: this repo tracks the OS process exit code
  separately from `~bootstrap.status.json`'s own `exitCode` field, and exactly one currently
  -gating test (`tests/selfapps_entrysmoke_no_interpreter.ps1`) hard-depends on the OLD
  always-exit-0-on-failure behavior. Genuinely more viable than first assessed, though still the
  widest-blast-radius option of the three.

The plan doc's own recommendation: continue (a) for the immediate next slice regardless (only
option that fits Item 46's "EXTREME CAUTION, one slice at a time" constraint as-is); if the
durable close-the-whole-class outcome is wanted, the choice between (b) and (c) is now closer than
first assessed (see the plan doc's corrected candidate-(c) section) and should be scoped as its
own dedicated effort with a small proof-of-concept and CI soak time, not folded into the ongoing
slice work.

**Needs the maintainer's call, not something an agent should pick unilaterally** -- this is
exactly the kind of decision Item 46's own process notes flag as requiring EXTREME CAUTION, and
the three options have genuinely different risk/durability tradeoffs rather than one obviously
dominating.

## 2. If (a) is chosen for Item 46: is there a target completion bar for Bucket A?

All ~20 remaining sites (see the plan doc's Finding 1-3 for the current count and severity
breakdown)? Only the ones demonstrated to risk a redundant fallback-chain/consent-prompt replay
(the plan doc's Finding 3 already identifies the `conda.bat not found after bootstrap` site as
structurally identical to the one slice 1 already fixed)? Or opportunistic, one slice per loop
indefinitely, with no fixed end state? Secondary to question 1 -- only needs an answer once (a) is
confirmed as the path forward.

## 4. CLAUDE.md Active Backlog Item 35: does the agent have (or can it get) the GitHub repo-admin access needed to actually flip a check to gating?

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

## 5. CLAUDE.md Active Backlog Item 42, lever 2: is the two-prompt fresh-build flow still worth changing, and if so, reword only or also combine the two prompts?

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

