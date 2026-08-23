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

## 3. CLAUDE.md Active Backlog Item 38: which CWD is "correct" for EXE verification -- unify to `dist\`, or leave the two verification points as-is?

Two verification points use different working directories today: `:run_exe_smokerun` (run 1,
fresh build) runs from `pushd dist`; `:try_fast_exe`/`:verify_no_exe_interpreter` (every later
run) run from the app root. A CWD-relative-path app (e.g. `open("config.json")`) can pass on one
and fail on the other with zero code change in between -- see CLAUDE.md's Item 38 for the full
trace, including a real double-clicked EXE's own default launch CWD (`dist\`, per documented
`ShellExecute`/`CreateProcess` behavior).

**Two fix directions, neither pre-decided:**
- **(a) Unify both verification points to the same CWD.** Which one is "more correct" needs its
  own thought -- `dist\` matches a real double-clicked EXE's default launch CWD, so verifying from
  the app root (the CURRENT behavior at 3 of 4 call sites) may be the one that's actually wrong,
  not `dist\`.
- **(b) Leave the two CWDs as-is.** `docs/agent-interconnect.md` already flags this as
  deliberate/load-bearing: `selfapps_exedata_fail.ps1`'s own xfail check depends on
  `:run_exe_smokerun`'s `pushd dist` specifically -- re-verify that test before changing this CWD.

The hint-honesty half of this item (PR #458, merged) is orthogonal and already closed -- it makes
the post-failure ADVICE correct regardless of which CWD answer is chosen. This question is only
about the underlying verification-CWD mismatch itself, still open.

**Needs the maintainer's call** -- picking (a) vs (b) changes real runtime behavior for any
CWD-relative-path app between a first and second run, not just wording; an agent choosing wrong
here silently changes what "works" means for a live feature, not just doc content.

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
