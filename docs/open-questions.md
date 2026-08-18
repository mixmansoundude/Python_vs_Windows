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
