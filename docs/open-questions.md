# Open Questions for the Maintainer

Unresolved questions that need a human decision, not something the agent can settle unilaterally.
This file holds ONLY currently-open items -- once a question is answered/decided, remove it from
here and fold the outcome into wherever it actually belongs (CLAUDE.md's Active/Closed Backlog,
`docs/agent-interconnect.md`, `docs/agent-lessons-learned.md`, the demo doc, etc.). Do not let
answered questions accumulate here as history; that's what the other docs' own Closed Backlog /
changelog-style sections are for.

---

## 1. Should the cascade decision remain an interruptive consent prompt at all?

**Status: open, needs a maintainer decision. No code changed for this specific question.**

**Context**: the original version of this item (cascade prompt firing before the postexec
offers, wasting the user's time on a build they'd already opted away from) is now RESOLVED and
shipped -- see CLAUDE.md's Closed Backlog "Cascade-vs-postexec fix" entry and
`docs/agent-interconnect.md`'s matching subsection for what changed (option (b) was implemented:
the two elective postexec offers are now skipped once cascade is approved; the smoke run itself
is deliberately still always run, since skipping it too would leave a kept-on-exhaustion build
unverified). This item is the narrower, harder question that surfaced while investigating that
fix: should the underlying signal (`HP_CASCADE_CANDIDATE`) keep triggering an interruptive
consent prompt at all, given how mixed its reliability actually is once traced through?

### What "couldn't get everything working" actually means, precisely

Two build-time, static signals, BOTH required before a cascade is even offered (`:warnfix_
cascade_detect` in `run_setup.bat`):
- **Signal A**: PyInstaller's own warn file (a list of imports its static analyzer couldn't
  resolve while building the `.exe`) still lists something, even AFTER a repair-install attempt
  and a rebuild.
- **Signal B**: at least one specific `pip install <package>` / `conda install <package>` repair
  command, during that same repair round, itself returned a real, nonzero exit code.

This is **never based on running the `.exe`** -- the cascade decision happens entirely before
the app is ever launched. It's also **narrower than "any warnfix repair failure"**: most apps
that need any repair at all get fixed cleanly by a single install (case 1 below) -- the
requirement for BOTH signals together is what makes this genuinely uncommon, not the base rate
of warnfix repairs needed.

### Truth table: what each combination means and how confident the signal actually is

| Signal A (still unresolved) | Signal B (an install genuinely failed) | Cascade offered? | What it usually means | Est. odds the `.exe` still runs fine |
|---|---|---|---|---|
| No | No | No | Repair fully worked, or nothing was needed. The common case. | Very high (~95%+) |
| No | Yes | No | An install command failed, but the rebuild's own scan came back clean anyway -- either that import was a false positive PyInstaller flags but doesn't actually need, or something else in the same round resolved it. Matches the "the failure flag was wrong / it wasn't actually needed" scenario directly. | High (~80-90%) |
| Yes | No | No | A real gap the design doesn't catch: the repair round's OWN installs can pull in a brand-new import PyInstaller now also flags, which the repair loop never targeted (so nothing "failed" for it) -- the confidence gate doesn't distinguish this from noise. | Medium (~60-70%) |
| Yes | Yes | **Yes** | The actual trigger: a real install failure AND a persistent static-analysis gap. The strongest available signal, but still not proof the app will crash. | Lower, and audience-dependent (~25-40% -- see below) |

### Row 4 in more depth (the one that actually reaches the user)

**Could the `.exe` still succeed even with a genuine (A=yes, B=yes) signal?** Yes, plausibly --
PyInstaller's warn file is a whole-codebase static scan, not proof a specific code path
executes. An optional feature behind `try/except ImportError`, a rarely-used branch, or a
type-checking-only import would all trigger this signal without the main flow ever needing it.
Against that: this bootstrapper's own stated audience is beginners with straightforward scripts,
where a top-level, unconditionally-used import is common -- so an outright crash is plausibly
MORE likely than not, just not overwhelming. These percentages are informed estimates from
reasoning through the mechanism, not measured production telemetry -- there's no real usage data
to check them against.

**Could the NEXT provider actually help, given this signal?** It depends entirely on WHICH hop,
and the bootstrapper has no way to tell which:
- **uv -> conda**: the one hop with real, mechanism-level justification. conda-forge is a
  genuinely different package index from PyPI, with different maintainers and (crucially)
  pre-built binaries for some native-extension packages that are notoriously hard to get right
  via pip on Windows. A meaningfully better chance here, though 0% if the package is genuinely
  absent from every index (a translation-table bug, or a nonexistent/private package name).
- **conda -> embed -> venv -> system**: all of these still install via plain pip against PyPI
  once bootstrapped -- functionally the SAME resolution mechanism uv already tried, just in a
  fresh environment. They only help if the root cause was environment-specific (a stale cache, a
  `PYTHONPATH`/`VIRTUAL_ENV` conflict, a uv-specific bug), not genuine package unavailability --
  and if uv AND conda have BOTH already reached this exact state, that's some evidence against a
  simple environment glitch. Meaningfully lower odds of success on these later hops.

This directly supports (with a real mechanism behind it, not just intuition) the "extra credit"
idea floated alongside the original question: telling the user conda has a decent, justified
chance while later tiers don't. **Deliberately not implemented in this pass** -- it was flagged
as possibly too risky to be wrong and too complex to be robust, and this analysis doesn't fully
resolve that concern: it supports the GENERAL, qualitative claim (a different package index has
real value; retrying the same one doesn't), but the bootstrapper still has no way to know the
TRUE root cause for any specific package, so a stronger per-package claim would be overreach.

### The actual open question

Given how mixed row 4's own reliability is (an estimated 60-75% chance of a real problem, not a
certainty), is an INTERRUPTIVE consent prompt still the right mechanism for this signal? Three
shapes this could take, roughly in order of how much they change from today:
1. **Keep it exactly as-is** (current shipped state): a timed, decline-by-default consent
   prompt, with the "dependencies may be incomplete" note now added for the decline path (see
   the Closed Backlog entry). Simple, already shipped, but still asks a yes/no question based on
   a signal that's wrong roughly a quarter to two-fifths of the time.
2. **Auto-cascade without asking**, at least for the highest-value uv->conda hop specifically,
   since that hop has real mechanism-level justification and conda is the strongest solver this
   bootstrapper has. Removes an interruption for a genuinely-likely-to-help case, but takes away
   the user's chance to say "no, I know this is fine, don't waste time redoing the whole
   dependency install."
3. **Downgrade to a passive note only**, never a prompt: build once, tell the user honestly that
   dependencies may be incomplete and cascading MIGHT help, and let them decide to re-run with an
   explicit opt-in flag if they want the cascade tried, rather than interrupting the default flow
   at all.

No recommendation is made here on this specific question -- unlike the now-resolved postexec
question, this one trades off real things (interruption cost vs. informed consent vs. wasted
compute on a cascade that might not help) without an obviously-safer default the way skipping
two elective prompts was. Says so explicitly rather than picking one to avoid presenting a
guess as a recommendation.
