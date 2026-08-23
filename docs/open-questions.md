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
trace, including the reasoning (NOT a confirmed universal fact -- see the caveat below) that a
plain double-click without an explicit "Start in" override commonly lands a launched EXE's CWD at
its own containing folder (`dist\` here), per documented `ShellExecute`/`CreateProcess` behavior.

**Two fix directions, neither pre-decided:**
- **(a) Unify both verification points to the same CWD.** Which one is "more correct" needs its
  own thought -- `dist\` plausibly matches a real double-clicked EXE's default launch CWD (see the
  caveat below), so verifying from the app root (the CURRENT behavior at 3 of 4 call sites) may be
  the one that's actually wrong, not `dist\`.
- **(b) Leave the two CWDs as-is.** `docs/agent-interconnect.md` already flags this as
  deliberate/load-bearing: `selfapps_exedata_fail.ps1`'s own xfail check depends on
  `:run_exe_smokerun`'s `pushd dist` specifically -- re-verify that test before changing this CWD.

**Caveat on the "dist\ is the real double-click default" claim, per CodeRabbit review + Microsoft's
own docs**: `CreateProcess`'s `lpCurrentDirectory`/`ShellExecute`'s `lpDirectory`, when NULL, make
the new process inherit the CALLING process's current directory, not unconditionally the target
EXE's own folder -- and a shortcut's own "Start in" field, when set, overrides this entirely. No CI
lane launches via an actual double-click or shortcut either way. So `dist\` matching a real
double-click is a plausible, commonly-true default, not a guaranteed universal fact -- factor that
uncertainty into whichever CWD answer (a) or (b) above.

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

## 5. CLAUDE.md Active Backlog Item 61: how should the agent get genuine cmd.exe verification for the remaining same-line-paren question, and is it worth a new CI surface to get it cheaply?

Item 61's own "Revised item scope" note says the remaining question -- whether a SAME-LINE,
self-contained `(`/`)` pair nested inside a real open `if`/`for` block is safe, the same way a
top-level one is -- "likely requiring live `cmd.exe` verification per this repo's own established
practice for this hazard class, not static reasoning alone." That practice exists for a reason:
static reasoning about cmd.exe's own paren/quote parsing has been wrong THREE separate times in
this exact hazard class already (see `docs/agent-lessons-learned.md`'s "A literal `(`/`)` inside
`echo` text..." entry) -- reasoning alone is not trusted evidence here, only a real cmd.exe run is.

**The actual hang-up: this sandbox has no Windows/cmd.exe access at all** (Linux-only environment)
-- the only place real cmd.exe exists for this repo is a GitHub Actions Windows runner, reached
today only via `batch-check.yml`'s existing triggers (`push: branches: ['**']` or
`workflow_dispatch`, confirmed by reading the file directly). Both existing triggers run the FULL
8-lane matrix (conda/uv installs, PyInstaller builds, the whole self-test suite) -- historically
50-90+ minutes wall-clock -- to answer one narrow batch-parsing question that needs maybe a few
seconds of real cmd.exe time. A throwaway branch with no PR (pushing triggers the matrix via the
`push` wildcard, no PR needed) WOULD get real cmd.exe verification, but at the cost of a full,
expensive matrix run per iteration -- clumsy for something likely needing a few rounds to nail
down exactly which factor (nesting depth vs. the `>>`-redirection prefix, per Item 61's own
still-unresolved "which factor actually matters was not isolated" note) is the real trigger.

**Recommended alternative, not yet built or agreed to**: a new, SEPARATE workflow file,
`workflow_dispatch`-only (matching this repo's own `workflow-lint.yml` precedent -- a workflow
that exists but is not wired to `push`/`pull_request`), whose one job runs on a Windows runner and
does nothing but execute a handful of crafted `.bat` fixtures (varying nesting depth, with/without
the `>>` redirection prefix) and report cmd.exe's actual parsing behavior for each. This would be
much cheaper per iteration (no conda/PyInstaller/pytest involved, likely under a minute) and
reusable for any future instance of this same hazard class, not just Item 61 -- but it is still a
new CI surface addition, which this repo's own coding guideline flags as something to be careful
with ("Do not change workflow triggers, permissions, or retention settings" on the EXISTING
`batch-check.yml` -- a new, separate file sidesteps that specific guideline, but adding any new
workflow file is still a CI/CD change worth the maintainer's awareness before it's built).

**Needs the maintainer's call**: build the dedicated `workflow_dispatch`-only probe workflow
(reusable, cheap, but a new file in `.github/workflows/`), or use a throwaway branch against the
existing full matrix (no new file, but ~1hr+ per iteration and likely needs a few iterations), or
something else (e.g. asking the maintainer to test a small script by hand on a real Windows
machine, if one is available to them)? Once picked, Item 61's own remaining scope becomes
actionable without further discussion.
