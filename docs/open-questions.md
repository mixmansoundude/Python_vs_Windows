# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

## 1. Cascade-to-next-provider prompt fires before the user has seen the current build run -- what should happen to the two follow-up offers?

**Status: open, needs a maintainer decision. No code has been changed for this yet.**

### Plain-language summary of what's actually happening

The bootstrapper tries a sequence of ways to get Python and your packages working, in this
order: **uv** (fastest, tried first) -> **conda** (Miniconda) -> a fresh **embedded Python**
download -> a plain **venv** -> whatever Python is **already on the machine** (last resort).
Each of these is called a "provider." Most runs succeed on the first provider (uv) and never
touch any of this.

After building the `.exe` (via PyInstaller, the packaging tool), the bootstrapper checks
PyInstaller's own "this module wasn't found" warnings and tries to install anything obviously
missing, then rebuilds once (this repair step is called "warnfix"). If that repair *still*
can't resolve everything under the CURRENT provider, the bootstrapper can offer to retry the
whole dependency-install step again from scratch under the NEXT provider in the list (e.g. "uv
couldn't get everything working, want to try conda instead?"). That retry offer is called the
**cascade consent prompt**.

Separately, AFTER the `.exe` has been run once to confirm it works ("post-execution", or
**postexec**), there are two more OPTIONAL, purely elective prompts a real (non-CI) user can
see:
- The **postexec checkpoint**: "want to run your program again right now, just to double
  check?"
- The **optimized-build offer** (requirement 9): "want me to also build a second, faster/leaner
  version of your `.exe` using a different build tool (Nuitka)?" -- this one can take a minute
  or more.

### The actual question

Traced directly in the code (`run_setup.bat`, high confidence -- this is a literal read of the
call order, not an inference): the **cascade consent prompt is asked FIRST**, before the `.exe`
is even run to verify it. Then, regardless of whether the user said yes or no to the cascade,
the bootstrapper goes ahead and runs the `.exe` anyway (it always has to, for its own logging),
and then shows BOTH of the postexec prompts above -- for the SAME build the user may have just
said "no thanks, try something else" to. Only after all of that does the bootstrapper actually
act on the cascade answer and retry under the next provider.

So a real interactive user who hits this can see, in order: "Want to try a different way?" ->
(says yes) -> "Want to run this one again?" -> "Want to spend a minute building an optimized
version of this one?" -> *then* it finally moves on to the different way they asked for two
questions ago. See `docs/agent-interconnect.md`'s "Post-execution checkpoint" and "AV-Safe
Build Path requirement 9" sections for the exact subroutine-by-subroutine trace
(`:warnfix_cascade_detect` / `:cascade_consent_gate` -> `:run_exe_smokerun` ->
`:run_postexec_checkpoint` -> `:offer_optimized_build`, with the cascade retry only happening
after all of that returns to the main line).

### Why is the cascade question asked before the user has even seen the current build run?

This is not an oversight so much as an unresolved design tension. The cascade question is
triggered by objective evidence the bootstrapper already has -- warnfix's own repair-install
attempt genuinely failed to resolve a dependency -- not a guess. In that sense, asking early is
defensible: the tool already knows this build probably won't work right, so there's an argument
for offering an alternative before spending more of the user's time on it. The problem isn't
really the early ask; it's that the bootstrapper doesn't *also* remember that answer when it
gets to the two follow-up prompts a few seconds later.

### What actually happens if the user proceeds anyway (today's behavior, unfixed)

Nothing breaks, and nothing is lost -- this is a UX/wasted-time issue, not a correctness bug:
- Declining both follow-up prompts: harmless. Just two extra, confusing y/n prompts to read and
  click through for a build the user just moved on from. Costs a few seconds of attention.
- Accepting "run it again?": harmless. Wastes a few seconds re-running a build already known to
  have an issue; that run's result is tracked separately and never affects the final outcome.
- Accepting "build an optimized version?": the costliest case. Nuitka (the alternate build tool)
  can take a minute or more, and the resulting optimized `.exe` almost certainly has the exact
  same missing-dependency problem, since nothing about the environment has changed yet -- the
  cascade retry hasn't happened. Worse, even if it somehow succeeds, this optimized build gets
  silently overwritten once the cascade to the next provider actually runs and rebuilds from
  scratch -- so accepting it is pure wasted time with zero lasting benefit.

In short: proceeding "wrong" here never produces an incorrect final result or a stuck bootstrap
-- it only burns a real, watching user's time and attention on decisions about a build the tool
has already provisionally written off. This never happens in CI (all these prompts auto-decline
under `HP_CI_LANE`), and it only happens at all when warnfix's own repair genuinely fails to fix
everything -- most runs never reach this path.

### Options and tradeoffs

**(a) Reorder: ask the cascade question AFTER the postexec offers**, so the flow becomes "verify
the current build -> offer to run it again / optimize it -> *then* ask about trying a different
provider."
- Feels more natural: try the current thing, see how it does, then decide whether to move on.
- Bigger, riskier change -- touches the call order across several places in `run_setup.bat`, the
  exact "frail" mechanism there's already reluctance to touch casually.
- Doesn't actually remove the wasted-time problem, just relocates it: the postexec offers are
  still made for a build the tool already suspects is broken. If the user accepts the optimized
  build and THEN says "yes, try a different provider," that optimized build is still thrown away
  moments later -- same waste, different order.

**(b) Gate: keep the cascade question first (as today), but skip both postexec offers whenever
the user already agreed to cascade.**
- Small, self-contained, low-risk fix -- roughly a one-line guard added to two existing
  subroutine call sites.
- Directly removes the actual harm: once the user says "yes, try something else," they are not
  asked two more questions about the thing they're leaving behind.
- The `.exe` verification run itself still happens quietly in the background either way (it's
  needed for the bootstrapper's own logging regardless) -- this only suppresses the two OPTIONAL
  follow-up prompts, not any required plumbing.
- Leaves the "cascade asked before the build is verified" ordering as-is -- but per the
  reasoning above, that ordering is arguably already correct, since it's based on real evidence
  rather than a guess.

### Recommendation

**Option (b).** It is the smaller, safer, more targeted fix -- it removes the actual wasted-time
problem (two unnecessary prompts about an abandoned build) without reordering the trickier call
chain in the part of the file everyone is already cautious about touching. The early cascade ask
isn't really a flaw to fix; asking based on real, already-gathered evidence rather than making
the user watch a near-certain failure play out first is reasonable on its own. The fix that's
actually needed is just making the two later, optional prompts respect an answer the bootstrapper
already has.

If you'd rather have option (a), or a third approach, say so and it can be implemented instead --
nothing has been changed in the code for this yet.
