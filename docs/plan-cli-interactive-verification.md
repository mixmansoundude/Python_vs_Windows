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
relied on, not assumed from .NET documentation alone. **Update (Finding 6): the fix for the
tee problem below independently requires removing the `for /f` wrapping around the PowerShell
invocation, which resolves this specific worry as a side effect** -- a directly-invoked
(non-command-substitution-wrapped) PowerShell process is a strictly more favorable shape for
stdin inheritance than the current code, confirmed empirically for the analogous simple case in
Finding 5b. The real remaining unknown is narrower: whether cmd.exe's own console/stdin handling
for a plain (non-`for /f`) `powershell -File ...` statement invoked from inside a `.bat` still
behaves as expected when that `.bat` itself was launched via double-click (a fresh console) vs.
`call`ed from another script -- genuinely Windows-specific, cannot be tested in this sandbox.

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

### Finding 5b -- empirical validation (2026-07-23, pwsh in this sandbox): the naive tee fix works, but reveals a second, more serious problem

Tested locally with `pwsh` (available in this sandbox) against a throwaway child script that
prints, sleeps 2s, then prints again -- confirming or refuting each piece of Finding 1/3 with
real execution instead of reasoning alone:

1. **Reproduced the current buffered behavior exactly as Finding 1 describes.** A script mirroring
   `ReadToEndAsync()` + `WaitForExit()` showed zero output until the full 2s elapsed, confirming
   the swallowed-output bug is real, not theoretical.
2. **First tee attempt (`Register-ObjectEvent` on `OutputDataReceived`/`ErrorDataReceived` +
   `BeginOutputReadLine()`/`BeginErrorReadLine()`, then a single blocking `$p.WaitForExit()`)
   FAILED to achieve live echo** -- output still only appeared at t=+2.05s. Root cause: a hard
   blocking, no-argument `.NET WaitForExit()` call does not yield control back to PowerShell's own
   event-dispatch loop, so the registered `-Action` callbacks queue internally but don't actually
   run until `WaitForExit()` returns. This is a genuine gotcha for anyone implementing this pattern
   in PowerShell, not specific to this repo.
3. **Fix: replace the blocking wait with a polling loop** (`while (-not $p.WaitForExit(100)) { }`)
   so the PowerShell engine gets a chance to dispatch queued events between iterations. **Confirmed
   working**: `BEFORE_SLEEP` now appears at t=+0.13s (not t=+2.05s), true near-immediate live echo.
   This is the correct fix shape for requirement 1's "event-driven read" -- a polling
   `WaitForExit(100)` loop, not a single blocking `WaitForExit()`.
4. **Basic stdin inheritance confirmed working, in the simple case.** A grandchild process launched
   with `RedirectStandardInput` left unset (default `$false`, "inherited") and no shell-level
   command-substitution wrapping around the launcher genuinely received piped stdin end-to-end
   (`bash | pwsh -File launcher.ps1` -> `Process.Start` grandchild, all 3 lines of piped input
   reached the grandchild, which echoed and exited cleanly on `quit`). This supports Finding 1's
   "should work per .NET semantics" but only for the *simple, uncaptured* invocation shape --
   see Finding 6 below for why the *actual* production invocation shape breaks this.

### Finding 6 -- CRITICAL: the current `for /f` result-capture mechanism is fundamentally incompatible with live tee, at BOTH P0 call sites

This is a new finding, not in the original research pass, and changes the shape of requirement 1.

Tracing the actual call sites (not just the `ProcessStartInfo` snippet Finding 1 quoted) shows
both `:run_failfast_probe` (`run_setup.bat:2718`) and `:run_exe_smokerun`
(`run_setup.bat:3709`) invoke their PowerShell script/command wrapped in cmd.exe's `for /f`
backtick command-substitution, specifically to capture a SINGLE result value from the script's
own stdout:

```batch
for /f "usebackq delims=" %%X in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%HP_PROBE_PS%"`) do (
  for /f "tokens=1,2 delims=|" %%A in ("%%X") do (
    set "HP_PROBE_EXCEEDED=%%A"
    set "HP_SMOKE_RC=%%B"
  )
)
```

`~failfast_probe.ps1`'s own last line prints exactly one line, `"$exceeded|$($p.ExitCode)"`, for
this to capture. `:run_exe_smokerun`'s inline `-Command` does the same via PowerShell's
implicit-last-expression-is-output behavior (`if($done){$p.ExitCode}else{-1}` as the final
statement).

**`for /f "... in ('command') do (...)"` captures the ENTIRE stdout of the wrapped command --
every line -- and the `do` body runs once per line. It does not also display anything to the
console; the output is consumed, not shown.** This is not a cmd.exe-specific mystery; it's the
same universal shell command-substitution behavior as bash `$(...)`/backticks. Confirmed directly
in this sandbox with a bash proxy of the identical shape (a pwsh script writing several "live"
lines followed by a final `0|42` result line, consumed via `while read -r line; do ... done < <(command)`,
bash's closest analog to `for /f ... in ('command') do (...)`): **none of the intermediate lines
reached the terminal**, and the do-body ran once per line (three times total), which for the real
`for /f ... tokens=1,2 delims=|` parser would mean `HP_PROBE_EXCEEDED`/`HP_SMOKE_RC` get
overwritten by every line of live output, landing on garbage (or nothing, if a line doesn't
contain `|`) instead of the real final result.

**Consequence: naively adding `Register-ObjectEvent`/`Write-Host` tee logic inside
`~failfast_probe.ps1` or `:run_exe_smokerun`'s inline command, as originally envisioned in
requirement 1, would not just fail to show the user anything -- it would actively break result
parsing**, since the tee'd lines would land in the same stdout stream `for /f` is consuming for
the exit-code/exceeded-flag signal.

**Fix shape (supersedes the original "just add event-driven read" framing of requirement 1):**
stop passing the result value through stdout+`for /f` capture. Instead:
1. Invoke the PowerShell script/file **directly, without any `for /f`/backtick wrapping** --
   `powershell -NoProfile -ExecutionPolicy Bypass -File "%HP_PROBE_PS%"` as a plain statement.
   Its stdout (now carrying live teed output) flows straight to the console uncaptured, and --
   per Finding 5b point 4 -- its stdin is inherited from cmd.exe directly rather than being nested
   inside a command-substitution construct, which is a *more* favorable shape for stdin passthrough
   than the current code, not a less favorable one.
2. Have the script write its small structured result (`exceeded|exitcode`) to a dedicated result
   **file** (mirroring the existing `HP_PROBE_OUT`/`HP_PROBE_ERR` convention already used for
   captured stdout/stderr) instead of printing it as the last stdout line.
3. After the direct call returns, read that result file with a separate `for /f` -- safe here
   because the file is fully written and static by the time cmd.exe reads it; there's no
   live-stream/multiple-lines-during-execution hazard for a post-hoc file read.
4. `:run_exe_smokerun`'s inline `-Command "..."` one-liner needs converting to an emitted `.ps1`
   helper file regardless of this finding (per `docs/agent-lessons-learned.md`'s existing
   "prefer an emitted `.ps1` file over inline `-Command` with literal quotes" rule -- 
   `Register-ObjectEvent`'s `-Action { ... }` scriptblock needs quoted strings inside it, the same
   hazard that drove `~failfast_probe.ps1` to be a real file instead of an inline command
   originally) -- so this finding adds a second, independent reason for that same conversion, not
   a new piece of scope on its own.

This does not change the P0 requirement's *goal*, but it does mean requirement 1 is a larger,
more structural change than "add event handlers to the existing script" -- it touches how BOTH
call sites signal their result back to the caller, not just how they read child output. Flagged
here rather than silently expanding scope mid-implementation.

### Finding 7 -- external research corroborates both Finding 5b's fix and Finding 6's diagnosis

Checked the local, empirical findings above against primary sources rather than relying on the
sandbox repro alone:

- **[PowerShell/PowerShell#11065](https://github.com/PowerShell/PowerShell/issues/11065)**
  ("Waiting on C# Events Causes Deadlocks", filed against the official PowerShell repo): confirms
  that `Register-ObjectEvent` event actions do not fire while the main thread is blocked in a
  synchronous wait (`Task.Wait()`/equivalent to a blocking `WaitForExit()`) -- this is a known,
  filed limitation, not an artifact of this sandbox's specific pwsh version. Directly backs the
  polling `while (-not $p.WaitForExit(100)) { }` fix validated in Finding 5b as the correct
  pattern, not a workaround for a local quirk.
- **[dotnet/runtime#1147](https://github.com/dotnet/runtime/issues/1147)**: `RedirectStandardInput
  = false` (the default, "inherited") does **not** guarantee the child receives a live console
  handle -- it inherits whatever stdin-redirection *state* the parent process itself has
  (`Console.IsInputRedirected`). This gives a concrete mechanism for Finding 1's original worry:
  it's not that `for /f`-wrapped invocation is vaguely "risky," it's that the parent PowerShell
  process's own `Console.IsInputRedirected` state (set by however cmd.exe launched it) propagates
  straight down to the grandchild, with no way for `RedirectStandardInput = false` on the
  grandchild to override it.
- Community accounts (multiple, informal but consistent) describe exactly this failure mode for
  `for /f "..." in ('powershell ...') do ...` wrapping a script that calls `Read-Host`: the
  interactive read hangs or fails because the `for /f` construct's own child cmd.exe does not
  connect a real, interactive console to the wrapped process. This corroborates Finding 6's
  diagnosis independently of the tee/capture-conflict angle -- removing the `for /f` wrapper is
  not just required to stop swallowing tee'd output, it is independently the standard, known fix
  for interactive-input-through-`for /f` failures generally.

**Net effect on confidence**: the Finding 6 redesign (direct invocation, no `for /f`/backtick
wrapping, result passed via a file) is now supported by three independent lines of evidence
(local empirical repro, this sandbox's bash-proxy demonstration of the capture conflict, and
primary-source confirmation of both the event-dispatch blocking issue and the stdin-inheritance
mechanism) rather than reasoning alone. What remains genuinely unconfirmed -- because it depends
on the specific, real ancestor chain of a double-clicked `.bat` file's own console, which no
Linux sandbox can reproduce -- is whether `run_setup.bat`'s own top-level console (when launched
by an actual double-click, not `cmd /c` from a test harness or CI runner) has an unredirected
stdin all the way down once the `for /f` wrapper is removed. The mechanism now points the right
direction; only a real Windows run confirms the full chain.

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

1. **Live echo (tee) instead of buffer-then-write, AND stop passing the result value through
   `for /f`-captured stdout (Finding 6).** Two changes that must ship together, not
   independently -- shipping the tee alone without the result-passing change would break both
   call sites' exit-code/exceeded-flag parsing:
   - Replace `ReadToEndAsync()` with an event-driven read (`Register-ObjectEvent` on
     `OutputDataReceived`/`ErrorDataReceived` + `BeginOutputReadLine()`/`BeginErrorReadLine()`,
     using a **polling `while (-not $p.WaitForExit(100)) { }` loop, not a single blocking
     `WaitForExit()`** -- confirmed empirically in Finding 5b that a blocking wait prevents
     PowerShell's event dispatch from running until it returns, defeating the whole point) that
     both prints each line to the console *as it arrives* and still accumulates the full text for
     the existing `~run.out.txt`/`~run.err.txt` capture (existing tests grep that file for tokens
     like `smoke-ok`; the capture itself must not go away, only stop being buffer-only).
   - Move the small `exceeded|exitcode` result signal from "print as the last stdout line, capture
     via `for /f`" to "write to a dedicated result file, invoke the script directly (no `for /f`
     wrapping), then read the result file with a separate, safe (post-hoc, static-file) `for /f`."
   - `:run_exe_smokerun`'s inline `-Command "..."` one-liner needs converting to an emitted `.ps1`
     helper file (via the existing `:emit_from_base64` mechanism, mirroring
     `tools/failfast_probe.ps1`) -- required regardless of the tee work, both because
     `Register-ObjectEvent`'s `-Action { ... }` needs literal-quote-containing PowerShell that an
     inline `-Command` string can't safely hold (`docs/agent-lessons-learned.md`'s existing rule),
     and because of the same `for /f`-capture conflict.
   - Applies to both `tools/failfast_probe.ps1` and `:run_exe_smokerun`'s (now-to-be-emitted)
     PowerShell helper.
2. **Confirm stdin actually reaches the child on real Windows CI**, not assumed from .NET docs.
   Finding 5b empirically confirmed the underlying .NET mechanism works for the simple
   (non-`for /f`-wrapped) case in this sandbox; Finding 6's fix removes the `for /f` wrapping as a
   byproduct, which should make production stdin passthrough at least as favorable as the tested
   case -- but the exact cmd.exe/console behavior for a real double-clicked `.bat` still needs a
   real Windows confirmation (see Finding 1's update), not just the Linux-sandbox proxy result.
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

**Local empirical testing (2026-07-23, pwsh in this sandbox) is now done and folded into Findings
5b/6 above.** It validated the core tee mechanism (with a real, non-obvious gotcha: a blocking
`WaitForExit()` blocks PowerShell's own event dispatch too -- fixed via a polling loop) and, more
importantly, surfaced a genuine architectural conflict (Finding 6) that the original research pass
missed: the current `for /f`-captures-stdout result-passing mechanism at BOTH P0 call sites is
incompatible with live tee as originally envisioned, and needs its own fix (direct invocation +
result file) shipped as part of requirement 1, not layered on top of it later. This changes
requirement 1's shape from "add event handlers" to "add event handlers AND restructure how the
result is signaled back to the caller" -- still P0, still one requirement, but a bigger diff than
the original wording implied.

**What's still untested, and can only be tested on real Windows:** whether stdin genuinely reaches
a grandchild process through the *actual* production shape (a `.bat` launched via double-click,
invoking `powershell -File ...` directly per the Finding 6 redesign, launching a further
grandchild via `Process.Start`) -- the Linux-sandbox proxy (bash pipe -> pwsh -> python3) validates
the .NET-level mechanism but not cmd.exe's own console/stdin semantics for a batch file's fresh
console window. A non-gating Windows CI lane exercising the redesigned probe end-to-end (piping a
canned answer sequence into a stdin-interactive stub app, asserting the app's own prompts appear
in the captured/live output and that it receives and acts on the piped answers) would be the
natural next validation step once the redesign is actually implemented -- not before, since there's
no code to exercise yet. This matches the owner's own suggested fallback ("CI as non-gating
experimenting") for exactly the piece that can't be resolved locally.

Not sized into loops/slices yet -- this doc exists to fix the shared understanding and terminology
before implementation starts, per the owner's own request to plan first rather than solve inline.
Given the added complexity Finding 6 surfaced, implementation is still recommended as its own
follow-up pass, not folded into this planning turn.
