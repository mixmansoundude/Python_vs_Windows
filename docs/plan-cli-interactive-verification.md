# Plan: CLI-Args and Stdin-Interactive Python Program Support

## Research Findings

### Finding 1 -- the redirect-and-buffer pattern is universal across every verification launch point

Every place this bootstrapper launches the user's program to verify it (`:run_exe_smokerun`,
the shared `:run_failfast_probe` used by the cached-EXE fast path / interpreter fallback /
postexec checkpoint) uses the same .NET `ProcessStartInfo` shape:

```powershell
$si.UseShellExecute = $false
$si.RedirectStandardOutput = $true
$si.RedirectStandardError = $true
$p = [System.Diagnostics.Process]::Start($si)
$so = $p.StandardOutput.ReadToEndAsync()
$se = $p.StandardError.ReadToEndAsync()
$p.WaitForExit(...)
$so.Result | Set-Content -Path '~run.out.txt' -Encoding ASCII
```

`ReadToEndAsync()` buffers everything in memory and only writes it to `~run.out.txt`/
`~run.err.txt` **after the process exits**. Nothing reaches the visible console while the child
is running. Confirmed by reading the actual code, not inferred -- `tools/failfast_probe.ps1` and
the inline PowerShell in `:run_exe_smokerun` both do this identically.

`RedirectStandardInput` is never set on either `ProcessStartInfo` (defaults to `false`, meaning
"inherited from the current process" per .NET semantics). Whether that inheritance survives the
actual invocation chain here (`cmd.exe` -> `for /f` capturing PowerShell's own stdout -> PowerShell
-> `Process.Start` of the grandchild) is **not verified** -- `for /f "usebackq delims=" %%X in
('powershell ...') do ...` is specifically designed to capture the command's stdout, and cmd.exe's
own internals for stdin propagation through that construct to a grandchild are exactly the kind
of quirk `docs/agent-lessons-learned.md` is full of. This needs a real Windows test before being
relied on, not assumed from .NET documentation alone.

### Finding 2 -- the two program "shapes" need genuinely different fixes

There are two independent axes here, easy to conflate but requiring different remedies:

1. **Argv-required at launch**: the program needs `sys.argv`/flags to do anything useful.
   Launching with zero arguments either exits immediately (misread as a build failure) or prints
   a usage message that gets captured, not shown.
2. **Stdin-interactive after launch**: the program starts fine with zero arguments, then prompts
   for input (`input()`/similar) and loops until the user types a quit command. This is the
   owner's actual original target shape for this repo (setup questions, then a
   prompt-until-`quit`/`exit` loop).

A program can be one, the other, both, or neither (a batch script that runs once and exits
cleanly needs no fix at all -- that's the case everything today already handles). Fixing #2
(live echo + confirmed stdin passthrough) does nothing for #1, and vice versa.

### Finding 3 -- the primary EXE verification's 30s kill is specifically hostile to shape #2

`:run_exe_smokerun` calls `$p.Kill()` if the process hasn't exited within 30 seconds. A program
correctly waiting on its very first `input()` prompt looks identical, from the parent's
perspective, to a hung/broken EXE for that entire window -- and gets force-killed before the user
(who can't see the prompt anyway, per Finding 1) has any chance to respond. The untimed fallback
paths (`:run_failfast_probe`) never kill, so they don't have this specific problem, but still
inherit the visibility problem.

### Finding 4 -- detection heuristics for shape #1 are each incomplete on their own

Two approaches were discussed, neither is a clean win by itself:

- **Output-pattern matching** (grep captured stderr for "usage:", "required argument", etc. after
  a failed run): cheap, but `argparse`'s own wording is fairly standard while `click`'s differs
  and a hand-rolled `if len(sys.argv) < 2: print("Usage: ..."); sys.exit(1)` is free-form and
  unmatchable. Reactive only (informs you after wasting a build+verify cycle).
- **AST-parsing the entry file** for `argparse.ArgumentParser()`, `@click.command()`, direct
  `sys.argv[N]` indexing, `docopt` usage: proactive (can inform behavior *before* the first
  verification attempt), and fits this repo's existing precedent (`collect_submodules.py`,
  `hidden_import_scan.py`, `find_entry.py` are all AST-based static scans already). Still
  incomplete -- can't catch every possible way a script might read `sys.argv`, and a
  false-negative just means the gap isn't detected, not that anything breaks worse than today.

Neither approach *fixes* the problem on its own -- both are signals that could inform what to do
once a program is known/suspected to need args. The actual fix for shape #1, independent of
detection, is giving the user a way to supply the args at all.

### Finding 5 -- argv passthrough into the bootstrapper is a clean, detection-free escape hatch

Today `run_setup.bat` accepts exactly one positional argument (`%~1`, the dragged-and-dropped or
typed entry-file path) via REQ-002 entry selection. Extending this to forward any *additional*
trailing arguments straight through to the target program at every launch site (smoke test, EXE
run, interpreter run, checkpoint's second run) is architecturally clean: a single variable set
once near entry detection, referenced at each launch site, purely additive (zero args still means
zero args for everyone else). This needs no detection at all -- it's for a user who already knows
their program needs `--foo bar` and can type `run_setup.bat myapp.py --foo bar` or drag-and-drop
then add args via a shortcut/manual invocation.

## Problem Statement

The bootstrapper's automatic verification step assumes the target program either exits on its
own with no interaction, or is a long-running GUI/server process where a bounded kill-on-timeout
is reasonable. Two common real-world shapes fall outside that assumption -- programs that need
launch arguments, and programs whose entire UI is a stdin prompt loop -- and today both either
get silently mis-verified (output swallowed, or a working program looks "hung" or gets killed) or
require the user to already understand the bootstrapper's internals well enough to route around
it manually.

## Goals

- A stdin-interactive program (owner's actual target shape) can be verified with its prompts
  visible and its responses actually reachable, without being killed mid-conversation.
- A user who already knows their program needs launch arguments has a documented, working way to
  supply them, without the bootstrapper needing to detect anything.
- When the bootstrapper genuinely cannot tell whether a run succeeded (nonzero exit or timeout on
  a program shape it doesn't fully understand), the messaging is honest about what it does and
  doesn't know, and gives the user a clear next step -- rather than a bare ambiguous status line.

## Non-Goals (this pass)

- Perfect, generic detection of "does this program need argv" -- both heuristics in Finding 4 are
  signals, not proof; this plan does not commit to either as a hard gate on behavior.
- Solving the harder ambiguity of "nonzero exit because of an unresolved dependency" vs "nonzero
  exit because of a real bug in the user's code" vs "nonzero exit because it was killed while
  waiting on stdin" as one unified message. See Open Question 3 below -- these need to stay
  separable, not collapsed into one generic prompt.
- Any change to `:die`, the diagnostics site, or the REQ-009 provider cascade's own dispatch
  logic. This plan only touches the verification-launch and messaging layer.

## Requirements

### P0 -- fixes the owner's actual target shape (stdin-interactive)

1. **Live echo (tee) instead of buffer-then-write.** Replace `ReadToEndAsync()` with an
   event-driven read (`OutputDataReceived`/`ErrorDataReceived`, or an equivalent incremental read
   loop) that both prints each line to the console *as it arrives* and still accumulates the full
   text for the existing `~run.out.txt`/`~run.err.txt` capture (existing tests grep that file for
   tokens like `smoke-ok`; the capture itself must not go away, only stop being buffer-only).
   Applies to both `tools/failfast_probe.ps1` and `:run_exe_smokerun`'s inline PowerShell.
2. **Confirm stdin actually reaches the child on real Windows CI**, not assumed from .NET docs.
   If it doesn't reach through cleanly given the `for /f`-capture nesting (Finding 1), that's a
   separate, likely harder fix (e.g. restructuring how the probe's result is captured so it isn't
   nested inside a stdout-capturing `for /f` at all).
3. **Revisit `:run_exe_smokerun`'s 30s kill for this case.** Once output is live, a human watching
   the console can *see* a prompt and knows to respond -- which resolves most of the practical
   problem even without solving "detect blocked-on-stdin vs. hung" in the abstract. Whether the
   30s cap should be removed, lengthened, or replaced with something closer to the fail-fast
   probe's own "classify fast-exit, then never kill" philosophy is an open design question (see
   below), not a decided part of this requirement.

### P1 -- argv passthrough escape hatch (shape #1, no detection needed)

4. Accept trailing arguments after the entry-file argument on `run_setup.bat`'s own command line
   and/or drag-and-drop-plus-typed-args flow, and forward them verbatim to the target program at
   every launch site (smoke test, EXE run, interpreter run, checkpoint's second run). Document in
   the README/postflight briefing how to use it.

### P2 -- honest messaging for the residual ambiguous case

5. When a verification run ends ambiguously (nonzero exit, or the interpreter-fallback path with
   no argv-passthrough and no confirmed stdin support), replace the bare `[STATUS]` line with
   something closer to: "the environment appears to be set up correctly, but since your program
   didn't exit cleanly we can't tell if it actually worked. You can run it yourself now (here's
   how), or [if applicable] let us try a deeper dependency-resolution pass." The "deeper pass"
   offer should only appear when it could plausibly help (see Open Question 3) -- not as a
   default reflex offered for every ambiguous exit.

### Explicitly NOT attempted here

- Detection heuristics from Finding 4 (output-pattern matching, AST scanning for argv usage) --
  real, discussed, deliberately deferred. If P1 (argv passthrough) turns out to be insufficient
  in practice (users don't know their program needs it, or don't know how to supply it), that's
  the trigger to revisit detection as a way to proactively *suggest* the passthrough flag rather
  than requiring the user to already know about it.

## Open Questions

### 1. What should the 30s kill become for `:run_exe_smokerun`?

Options, none decided: (a) lengthen it substantially (e.g. to match how long a person might take
to notice a prompt and respond -- but any fixed number is still a guess); (b) adopt the fail-fast
probe's "classify fast-exit within N ms, then never kill" pattern here too, accepting that a
genuinely-hung EXE would then hang the bootstrap rather than being caught -- a real trade-off, not
a free win; (c) something conditional on whether the program is suspected interactive (circles
back to detection, which this plan explicitly defers). Needs a decision before requirement 3 can
be implemented.

### 2. Terminology

This doc uses "argv-required" and "stdin-interactive" for the two shapes. Open to better terms if
the owner has a preference -- these aren't standardized industry terms as far as this research
found ("CLI program" is ambiguous between the two in common usage, which is part of what made
this hard to discuss precisely in the first place).

### 3. How does the P2 messaging avoid conflating three different root causes?

A nonzero/ambiguous exit could mean: (a) a real bug in the user's own code, (b) an unresolved
dependency that a deeper solve (the REQ-009 provider cascade, already-existing warnfix logic)
might fix, or (c) the program was correctly waiting on stdin input and got killed or looked hung.
Offering "try a deeper solve?" is only sensible for (b) -- offering it reflexively for (a) or (c)
would be confusing/unhelpful. The owner's own framing (if uv and conda already installed and
activated correctly, embedded/venv/system don't add solving power, they only matter when uv/conda
can't run at all) is accurate and matches how REQ-009's cascade already works -- but distinguishing
which of (a)/(b)/(c) actually happened is not solved by this plan. Likely sequencing: ship P0
first (removes most of (c) as a source of false ambiguity for the owner's actual use case), then
revisit this messaging question with a narrower, cleaner problem.

## Notes from Claude

Recommended sequencing: P0 first, since it's the owner's actual original target shape for this
repo and is a confirmed bug (not speculative) with a fix shape that's clear (tee) and only
partially open (stdin confirmation, the 30s-kill question). P1 (argv passthrough) is independent,
lower-risk, and could ship in parallel or after -- it's a pure additive capability with no
detection/false-positive risk. P2 (messaging) should wait until after P0 ships, both because it's
explicitly lower-value while (c) is still a live source of ambiguity, and because "what should
this message say" is much easier to answer once the interactive case no longer muddies the signal.

Not sized into loops/slices yet -- this doc exists to fix the shared understanding and terminology
before implementation starts, per the owner's own request to plan first rather than solve inline.
