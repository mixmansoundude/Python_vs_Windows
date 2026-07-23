# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

## 1. CLI / stdin-interactive Python programs -- design doc in progress

Two genuinely different program "shapes" this bootstrapper's verification runs don't yet handle
well, confirmed real by tracing the actual `ProcessStartInfo` code (not hypothesized):

1. **Argv-required at launch** -- a program that needs command-line arguments to do anything
   useful (e.g. `argparse`/`click`-driven tools). No fix shape agreed yet.
2. **Stdin-interactive after launch** -- a program that starts with zero arguments but then
   prompts for input via `input()`/similar and runs a loop until the user types a quit command.
   Confirmed bug: every verification launch point redirects the child's stdout/stderr into an
   in-memory buffer only written to disk after the process exits (`RedirectStandardOutput` /
   `RedirectStandardError = $true`, then `ReadToEndAsync()`), so prompts never reach the visible
   console. The primary EXE verification (`:run_exe_smokerun`) additionally force-kills after a
   hard 30s, which would kill a program correctly waiting on its first prompt.

Owner-agreed direction (2026-07-22): live-echo the redirected output (tee to console, not just
buffer-then-write) to fix prompt visibility; verify stdin actually reaches the child process on
real Windows before relying on it; separately consider an argv-passthrough escape hatch for the
launch-args case. Full design write-up: `docs/plan-cli-interactive-verification.md`. Not
implemented yet -- that doc is where the phased scope and open sub-decisions live now.
