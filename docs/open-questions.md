# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

## 1. Should total EXE-packaging failure change the final on-screen wording?

When BOTH the PyInstaller build and the Nuitka Tier A fallback fail outright, the bootstrapper
falls through to running the entry script via the interpreter, and if that runs cleanly, the
final line the user sees is `[STATUS] Run Status: SUCCESS (Exit Code: 0)` -- identical to a
genuine clean-EXE run. The only on-screen signal that packaging failed is one `[ERROR]
PyInstaller execution failed.` line printed a few seconds earlier, with no closing summary
reminding the user "by the way, no .exe was produced."

This is intentional, existing, documented design (see CLAUDE.md's "User-code exit-code
semantics are already correctly isolated from bootstrapper status" Known Finding) -- the
internal `~bootstrap.status.json` correctly records `state=error` regardless, so nothing is
silently lost at the machine-readable level, and the design deliberately treats "did your code
run" as a separate question from "did we also manage to produce a double-clickable .exe." The
open question is narrower than "should the bootstrapper ever exit non-zero" (that was decided
long ago, and the reasoning above still holds: a script that ultimately runs fine via the
interpreter fallback IS a real success for the user, even without an EXE) -- it's specifically
whether the console's FINAL summary line should say something more like "your code ran, but no
standalone .exe was produced (see the ERROR above)" instead of a bare "SUCCESS," so a user
skimming only the last line doesn't miss that packaging failed.

**Recommendation:** worth doing -- it's a small, additive change (one extra conditional line at
the very end of the run, gated on packaging having failed) that doesn't touch the actual
success/failure semantics, just closes the "only signal is one line several seconds earlier"
gap. Not implemented yet pending confirmation this is wanted (it's a user-facing wording change
to the final summary, worth a deliberate yes before touching it).

---

## 2. CLI-args-only Python programs (no GUI) -- tabled, needs its own discussion pass

All of this project's design so far (fast-path reuse, the postexec checkpoint, requirement 9's
optional-optimized-build offer, the ~30s verification kill-window) implicitly assumes the target
program either exits on its own or is a long-running/GUI-style app where a bounded verification
run is a reasonable thing to force-kill. A program that requires command-line arguments to do
anything useful is a different shape entirely: the bootstrapper's own verification runs
(`:run_exe_smokerun`, the interpreter fallback, the postexec checkpoint's second run) all invoke
the entry point with NO arguments, so a CLI-args-required program would either exit immediately
with a "missing required argument" error (misread as a build failure) or print a usage/help
message that gets swallowed into the smoke-test capture and treated as ordinary output. No
research done yet on how big a gap this actually is in practice, or what the right fix would
look like (skip verification entirely for such programs? detect argparse/click usage and skip
smoke-run? prompt the user for args once and remember them?). Flagged for a dedicated future
discussion, not sized or scoped yet.
