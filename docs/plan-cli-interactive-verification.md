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

### Finding 8 -- CRITICAL: `Register-ObjectEvent` itself reorders lines within a single stream; requirement 1's actual shipped mechanism is `ReadLineAsync()` polling, not event handlers

Found 2026-07-24, directly as a result of building the interactive round-trip test the owner
asked for (a script mirroring the owner's real target shape: `input()` for a name, then a
`ping`/`exit` loop) to gain confidence in requirement 1. The test initially failed
non-deterministically (2 out of 5 local runs) with output from a LATER round of the conversation
appearing BEFORE an EARLIER round's output in the captured/teed text -- e.g. round 2's `"pong"`
landing ahead of round 1's `"Hello, Alice!"`. This is not a hang or a dropped line; it is a pure
reordering, which is a materially different (and more dangerous) failure mode than anything
Findings 1-7 anticipated: a human watching the live tee would see their own conversation printed
out of sequence.

Root-caused to a confirmed, filed upstream bug:
**[PowerShell/PowerShell#11937](https://github.com/PowerShell/PowerShell/issues/11937)**.
`Register-ObjectEvent` on `OutputDataReceived`/`ErrorDataReceived` dispatches each event via
`ThreadPool.QueueUserWorkItem` internally -- the .NET thread pool provides no ordering guarantee
between queued work items, so when two lines arrive close together (a common case for any script
that prints two or three lines back-to-back, e.g. a prompt immediately followed by its own
response), their `-Action` callbacks can run in either order. This is a real, documented
limitation of the mechanism requirement 1 shipped with, not an artifact of this sandbox.

**Fix: replace `Register-ObjectEvent` entirely with self-sequenced `StreamReader.ReadLineAsync()`
polling.** Both `tools/failfast_probe.ps1` and `tools/exe_smokerun.ps1` were rewritten to issue
only ONE async read per stream at a time: check `.IsCompleted`, consume `.Result`, print it, then
immediately issue the next `ReadLineAsync()` call for that same stream. Because there is never
more than one outstanding read racing against itself, a single stream's lines cannot be delivered
out of order -- ordering is enforced by construction (each read literally cannot start until the
previous one's result has been consumed), not by hoping the runtime's own callback scheduler
happens to preserve it. Cross-stream (stdout vs. stderr) interleaving was never guaranteed and
still isn't -- that reflects the child's own two independent OS pipes, not a defect.

Verified the fix with 20 repeated local runs of the new interactive round-trip test (0/20
failures, versus 2/5 failures before) plus 5 repeated full-suite runs (`tests/test_failfast_probe.py`,
`tests/test_exe_smokerun.py`), all clean. This also simplified the code: no
`Register-ObjectEvent`/`Unregister-Event`/`Get-EventSubscriber` bookkeeping, no separate EOF-flag
tracking for the drain-wait race documented in `docs/agent-lessons-learned.md`'s ".NET Process
async-redirected-output" entry (`ReadLineAsync()` returning `$null` on a completed task IS the
EOF signal, with no separate polled-wait-after-`WaitForExit()` step needed) -- the new mechanism
is strictly simpler as well as strictly more correct. `docs/agent-lessons-learned.md`'s existing
async-output-drain entry was left in place since its core lesson (don't trust `WaitForExit()`'s
own documented "call it twice" guidance blindly) remains true and instructive, even though the
specific implementation it was written against has since been replaced by this fix.

**A new test closes the remaining confirmation gap for requirement 2 (partially, pending real CI):**
`tests/selfapps_interactive_stdin.ps1` (new, uv lane, non-gating) builds a real PyInstaller EXE
from a multi-round `input()`-driven stub app mirroring the owner's actual target shape (no launch
args, ask a setup question, loop on stdin until a quit command) and pipes a scripted answer
sequence into `cmd.exe`'s own stdin for the FULL real chain: `cmd.exe -> :run_exe_smokerun ->
the emitted ~exe_smokerun.ps1 helper -> the built EXE`. It asserts ordering (not just presence)
via `IndexOf` comparisons on the bootstrap log, that the EXE was genuinely built, and that the
bootstrap reports `state=ok`. This is provider-agnostic by construction (`:run_exe_smokerun`/
`~exe_smokerun.ps1` behave identically regardless of which REQ-009 tier built the environment),
so one passing run in one lane represents the mechanism working across every lane -- a
per-provider repeat would exercise the same code path, not a different one. It does not, and
cannot, prove a live human's own typing timing -- see requirement 2's own text below for what
remains open after this test's first real CI run confirms the mechanism.

### Finding 9 -- CRITICAL, newly discovered 2026-07-24: `ReadLineAsync()` is line-buffered, so a prompt with no trailing newline is INVISIBLE until something else flushes a line -- affects both the merged live-tee (requirement 1) and the just-shipped activity-aware kill (requirement 3)

Found during a requested research/refinement pass on the already-shipped work, not while building
a new feature -- confirmed empirically with a local `pwsh` + Python repro (not reasoned about),
following this repo's own established practice of never trusting an assumption about async I/O
behavior without a direct test.

**The problem:** Python's canonical `input(prompt)` idiom -- the exact pattern this entire plan is
built around (`name = input("Enter your name: ")`) -- writes the prompt text to stdout and flushes
it, but WITHOUT a trailing newline (the cursor is meant to stay on the same line waiting for typed
input). `StreamReader.ReadLineAsync()` (the read primitive both `tools/failfast_probe.ps1` and
`tools/exe_smokerun.ps1` use, per the Finding 8 rewrite) does not return ANYTHING for a given
stream until it has accumulated a full newline-terminated line, or the stream reaches EOF. A
direct repro confirmed this precisely: a child process that writes `"Enter your name: "` (no `\n`)
and then blocks on stdin produces **zero** completed `ReadLineAsync()` reads for at least 2 full
seconds of silence -- the bytes ARE sitting in the OS pipe (confirmed via `CanRead`), but our
reading mechanism will not surface them. They only appear once EITHER (a) the program's own LATER
output includes a newline (at which point the prompt and that later text arrive concatenated as
ONE "line" -- e.g. `"Enter your name: Hello, Alice!"` as a single chunk, not two), or (b) the
process exits (confirmed separately: `ReadLineAsync()` DOES return a final partial/unterminated
line at EOF, so the content is never permanently lost -- only delayed).

**Consequence for requirement 1 (live-tee, already merged in #374):** a real user watching the
console during verification of a program whose first action is `input("some prompt")` sees
**nothing** until after they've already blindly typed an answer and pressed Enter -- at which
point the prompt and the program's next line of output suddenly appear together, out of order
relative to when they were actually meant to be seen. This significantly undercuts the stated goal
of requirement 1 ("a stdin-interactive program can be verified with its prompts visible") for the
single most common way Python programs prompt for input.

**Consequence for requirement 3 (activity-aware kill, just shipped in #375):** `$sawOutput` is
driven by the exact same `ReadLineAsync()`-completion signal, so it ALSO stays `$false` while a
process is sitting at an `input()` prompt with no later newline yet -- meaning the 30s kill can
still fire for the canonical target scenario (a program silently waiting at its very first
prompt), which is the exact case requirement 3 was written to protect. The existing
`tests/test_exe_smokerun.py::ActivityAwareStop` test does NOT catch this, because its script uses
`print(..., flush=True)` (a newline-terminated line) rather than `input(prompt)` -- it validates
the mechanism correctly for output that ends in a newline, but doesn't exercise the no-newline
prompt case at all.

**Why the existing interactive-round-trip tests (local unit test AND the new real-CI
`selfapps_interactive_stdin.ps1`) didn't catch this:** both feed the ENTIRE scripted answer
sequence through stdin essentially instantly (no simulated human typing delay), so the
prompt-then-response round-trip completes in well under a second regardless of the buffering
behavior described above -- the concatenated "line" still contains both substrings in the right
relative order, so substring/ordering assertions pass. This is a real blind spot in test coverage,
not a flaw in those tests' own design: they correctly prove the plumbing doesn't drop or reorder
data, which was their stated goal, but they cannot and do not model realistic human-speed typing
latency, which is exactly the condition under which this bug actually bites a real user.

**Fix shape: SHIPPED 2026-07-24, owner-authorized ("if you think the raw character read is the
fix then go for it and test locally and let CI confirm").** Replaced the line-based
`ReadLineAsync()` polling with raw character-based reads
(`StreamReader.ReadAsync(char[], int, int)` on a 4096-char buffer, same one-read-in-flight polling
shape Finding 8 already established) in BOTH `tools/failfast_probe.ps1` and
`tools/exe_smokerun.ps1`, so ANY available bytes are surfaced and displayed the moment they arrive,
without waiting for a delimiter -- matching how a real terminal actually behaves. `[Console]::Out
.Write($chunk)`/`[Console]::Error.Write($chunk)` (no newline appended) replace `Write-Host
$line`/`[Console]::Error.WriteLine($line)`, since chunks now arrive at arbitrary boundaries, not
line boundaries. EOF is now a 0-length read (`$n -eq 0`), not a null result. `$sawOutput` (the
activity-aware kill's proxy, requirement 3) is now set on any non-empty chunk, immediately fixing
the exact gap this finding describes.

**Empirically validated BOTH ways before and after the fix**, matching this repo's own established
practice: confirmed the fix works (a no-newline prompt is now readable within single-digit
milliseconds, vs. never within 2s under the old reader) via a standalone `pwsh` repro; then wrote
two new regression tests targeting the EXACT gap this finding describes (a no-newline chunk, not
just any output) --
`tests/test_failfast_probe.py::NoNewlinePromptVisibility` (drives stdin itself via a live,
test-controlled pipe -- not a pre-loaded answers file, which cannot distinguish the timing bug at
all -- and asserts the prompt is readable from the probe's own live output BEFORE any answer is
sent) and `tests/test_exe_smokerun.py::ActivityAwareStop::test_output_with_no_trailing_newline_
still_prevents_kill` (a script that writes an unterminated chunk, sleeps well past a short kill
window, then completes normally) -- and confirmed BOTH new tests genuinely fail against the
pre-fix implementation (checked out from the merge commits directly) and pass against the fix,
so they are proven regression tests, not just new tests that happen to pass. Full existing suite
(19 tests across both files, including the pre-existing 20/20-clean interactive round-trip test)
re-verified clean with the new read primitive; no regressions. This closes the last open gap in P0.

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

**Requirement 1: SHIPPED (2026-07-23), mechanism replaced 2026-07-24 (Finding 8).** Both helper
scripts (`tools/failfast_probe.ps1`, `tools/exe_smokerun.ps1`) live-tee + write results to a
file, invoked directly (no `for /f` capture) by `run_setup.bat`. Two races were found and fixed
during implementation, in two separate passes: the original `WaitForExit()`-twice drain race
(see `docs/agent-lessons-learned.md`'s ".NET Process async-redirected-output" entry) was fixed
first, then a SECOND, more serious bug -- `Register-ObjectEvent` reordering lines within a single
stream, a confirmed upstream PowerShell bug (Finding 8 above) -- was found while building the
interactive round-trip test requested for requirement 2's confirmation, and led to replacing
`Register-ObjectEvent` entirely with self-sequenced `StreamReader.ReadLineAsync()` polling (which
also subsumes and simplifies away the original drain-race fix, see Finding 8 for detail).
Requirement 2 has a real-Windows CI test now in place (see Finding 8's last paragraph) but is not
yet CLOSED pending that test's first real CI run. **Requirement 3 SHIPPED 2026-07-24** (see its
own entry below) -- all of P0 now has an implementation; P1 and P2 remain to be implemented.

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
   **`tests/selfapps_interactive_stdin.ps1` (new, uv lane, non-gating, see Finding 8) now exists
   to provide exactly this confirmation** -- it pipes scripted answers into `cmd.exe`'s own stdin
   and asserts a multi-round `input()` conversation is received correctly, in order, through the
   FULL real chain (`cmd.exe -> :run_exe_smokerun -> ~exe_smokerun.ps1 -> the built EXE`), not a
   simplified proxy. This requirement moves from "open" to "verification test shipped, pending its
   first real Windows CI run" -- it is not fully CLOSED until that run is observed passing, since
   nothing in this sandbox can execute `run_setup.bat`/a real cmd.exe console end-to-end.
3. **SHIPPED (2026-07-24), resolves Open Question 1.** Owner decision: "don't change the timeout
   if they were told at the beginning that it was timed; at best, if interactive input was
   received then extend or stop the timeout." Implemented in `tools/exe_smokerun.ps1`: the
   `HP_SMOKERUN_KILL_MS` window (still 30000ms, unchanged) is now a classification checkpoint, not
   an unconditional deadline -- `Kill()` fires only if the process has produced ZERO output by
   that point. The parent cannot observe stdin directly (redirecting it would reintroduce the
   exact risk the live-tee redesign just fixed), so "interactive input was received" is
   approximated by the best available proxy: any output observed at all, since Python's own
   `input(prompt)` flushes stdout before blocking (confirmed, see
   `docs/agent-lessons-learned.md`) -- a process at its first prompt has already printed
   something. Chosen behavior once output is seen: **stop** (unbounded wait, mirroring
   `~failfast_probe.ps1`'s own "classify once, then never kill" pattern) rather than a fixed
   extension, since a bounded extension just relocates the same ambiguity to a later deadline.
   Accepted trade-off, per the owner's own direction: a process that prints something and then
   genuinely deadlocks for a non-stdin reason now hangs the bootstrap rather than being caught at
   30s -- see `docs/agent-interconnect.md` "Activity-aware EXE-smoke kill" for the full mechanism
   and `:warn_user_code_launch`'s updated messaging (now accurately describes the conditional
   behavior instead of overclaiming an unconditional 30s kill).
   **Gap found and fixed same day (Finding 9): the `$sawOutput` proxy originally inherited
   `ReadLineAsync()`'s line-buffering limitation**, so it did not actually detect the canonical
   `input("prompt")` case (no trailing newline) until something else flushed a line -- meaning the
   kill could still fire for the exact scenario this requirement targets. Fixed by switching both
   helper scripts to chunk-based reads (see Finding 9 above); `$sawOutput` now sets on any
   non-empty chunk, closing the gap for real.

### P1 -- argv passthrough escape hatch (shape #1, no detection needed) -- SHIPPED 2026-07-24

4. **SHIPPED.** Accept trailing arguments after the entry-file argument on `run_setup.bat`'s own
   command line and forward them verbatim to the target program at every real launch site (EXE
   smoke, cached-EXE fast-path reuse, interpreter run, checkpoint's second run). Implemented as
   `HP_APP_ARGS`, captured once near the very top of the file from `%2`-`%9` (no `shift`, since
   that would also shift `%~1` -- the entry file -- which several later call sites read directly;
   practical limit of 8 extra arguments as a result). Each present token is individually
   re-quoted at capture time so a token containing spaces survives as one argv element.
   Documented in README `[REQ-026]` and both postflight briefing panels.

   **Required changing `HP_PROBE_ARGS`'s own contract** (`tools/failfast_probe.ps1`, shared by
   the fastpath/interpreter/checkpoint launch sites): it used to be a single bare path that the
   script itself wrapped in one extra pair of quotes (`$si.Arguments = '"' + $rawArgs + '"'`) --
   fine for exactly one argument, but wrapping a multi-token string the same way collapses it
   into ONE literal argv element instead of several. Changed to `$si.Arguments = $rawArgs`
   directly: the caller (`run_setup.bat`) is now responsible for providing a fully-quoted,
   ready-to-use Windows Arguments string. `tools/exe_smokerun.ps1` gained the equivalent
   `HP_SMOKERUN_ARGS` (the EXE is self-contained, so no separate entry-file prefix is needed
   there, just the forwarded extra args or nothing). Both existing test suites needed updating to
   match: `tests/test_failfast_probe.py`'s old `ArgsIsSingleArgumentOnly` class documented the
   OLD misparse-as-one-token behavior as correct -- replaced with `ArgvPassthrough`, which proves
   multiple pre-quoted tokens ARE now forwarded as separate argv elements, and that an unquoted
   token containing a space is the CALLER's responsibility to quote (the child's own argv parser
   splits it, same as typing it unquoted at a real command line -- not a bug in this script).
   `tests/test_exe_smokerun.py` gained its own `ArgvPassthrough` class; its test harness launches
   `sys.executable` with the actual test program fed via inherited stdin (see that file's module
   docstring), which has no spare "script path" slot to hang extra CLI args off of the normal
   way -- solved with CPython's own `python - arg1 arg2` form (a literal `-` as the script name
   means "read the program from stdin," with everything after it becoming `sys.argv[1:]`),
   confirmed directly (`python3 - --foo "bar baz" < script.py` prints `ARGV:--foo|bar baz`)
   before relying on it in the test.

   Deliberately does NOT forward into the two internal, bounded repair/optimization verification
   loops (`--hidden-import` auto-recovery's own re-run, the elective optimized build's internal
   verify launch) -- both are diagnostic checks against an already-confirmed-working build, not
   the user's primary run, matching how those subroutines already scope themselves (see
   `docs/agent-interconnect.md`'s own established precedent for this class of scoping decision).
   The `HP_CI_SKIP_ENV=1` CI-only test path (`:ci_skip_entry`'s system-Python launch) was also
   left out of scope -- it is test infrastructure, not one of the plan's four named real launch
   sites, and there is no interactive terminal in CI to benefit from it.

### P2 -- honest messaging for the residual ambiguous case -- SHIPPED 2026-07-24

5. **SHIPPED, narrower in scope than originally sketched -- see Open Question 3's own resolution
   note below for why.** Tracing the actual control flow (both P0 and P1 already shipped by this
   point) found that the "let us try a deeper dependency-resolution pass" offer already exists
   and already fires at its own natural point earlier in the flow (`:warnfix_cascade_detect` +
   `:cascade_consent_gate`, build-time, triggered by warnfix's own missing-module detection) --
   by the time the FINAL `[STATUS]` line prints, that offer (if applicable at all) has already
   been made and resolved once. Re-offering it again post-hoc would need much more plumbing (the
   whole dependency-install phase re-run from a point after the program has already executed) for
   uncertain benefit, and would risk exactly the "reflex offered for every ambiguous exit" the
   plan's own text warned against. So P2 shipped as MESSAGING ONLY, per its own name -- no new
   consent gate, no new "try again" mechanism -- targeting the two call sites that traced out as
   genuinely having no honest signal at all:
   - **A real, pre-existing bug in `:print_no_exe_briefing`**: its header text unconditionally
     claimed "your code ran successfully just now" whenever no EXE was produced, with ZERO
     awareness of whether the interpreter fallback that runs immediately before this panel
     (`:verify_no_exe_interpreter`) actually exited 0. A new flag, `HP_NOEXE_VERIFY_FAILED` (set
     in both of that subroutine's branches whenever `HP_SMOKE_RC` is nonzero, mirroring the
     already-existing `HP_EXE_VERIFY_FAILED` pattern for the EXE path), now gates a caveat
     variant of the panel's header -- honest about not knowing whether the failure is a bug in
     the user's own code or something this bootstrapper missed, per Open Question 3's own (a)/
     (b)/(c) framing, without asserting which.
   - **A genuine, previously-unsignaled gap for the fast-path-kept-despite-failure case**: when
     the fail-fast probe classifies a reused cached EXE as alive/healthy (so it is kept, not
     discarded+rebuilt -- see requirement-3-era work) and it later exits non-zero, the postflight
     briefing was skipped ENTIRELY (`if not defined HP_FASTPATH_USED` gates both existing
     panels) -- the only signal was one WARN log line among other console output. A new plain
     informational panel, `:print_fastpath_ambiguous_note`, closes this without adding a PROMPT
     (a print-only panel does not violate the fast path's own "zero friction" design requirement,
     which is specifically about not adding consent gates/questions to that path).
   - Both new panels are deliberately modest about root cause (never claim which of (a)/(b)/(c)
     happened), give the user the direct-run command so they can see full output themselves, and
     for the fastpath case, note that deleting the cached EXE and re-running forces a genuinely
     fresh dependency check if the user wants to rule out an environment issue.
   - New CI coverage: `tests/selfapps_pyinstaller_fail.ps1` gained a third scenario
     (`execfail_runtimefail`) proving the no-EXE caveat fires correctly; `tests/
     selfapps_failfast_probe.ps1`'s existing `self.failfast.probe.alive` scenario (which already
     produces the exact "kept cached EXE, later exits non-zero" condition) was extended with an
     assertion for the new fastpath note.

### Explicitly NOT attempted here

- Detection heuristics from Finding 4 (output-pattern matching, AST scanning for argv usage) --
  real, discussed, deliberately deferred. If P1 (argv passthrough) turns out to be insufficient
  in practice (users don't know their program needs it, or don't know how to supply it), that's
  the trigger to revisit detection as a way to proactively *suggest* the passthrough flag rather
  than requiring the user to already know about it.

## Open Questions

### 1. What should the 30s kill become for `:run_exe_smokerun`? -- RESOLVED 2026-07-24

Owner decision: don't change the fixed 30s number itself (keep the messaging that this run is
timed), but if the process shows evidence of being alive/interacting before the deadline, extend
or stop the kill rather than force-stopping it. Implemented as option (b)'s "stop" variant,
gated on output having been observed (the closest available proxy for "interactive input was
received" given stdin itself isn't observable by the parent) -- see requirement 3 above and
`docs/agent-interconnect.md` "Activity-aware EXE-smoke kill" for the shipped mechanism and its
accepted trade-off (a silently-deadlocked-after-printing-something process now hangs the
bootstrap rather than being caught). A bounded "extend by N seconds" variant was considered and
not implemented (a fixed extension just relocates the same ambiguity to a later deadline) -- if
this trade-off proves wrong in practice, that's the natural fallback to revisit.

### 2. Terminology

This doc uses "argv-required" and "stdin-interactive" for the two shapes. Open to better terms if
the owner has a preference -- these aren't standardized industry terms as far as this research
found ("CLI program" is ambiguous between the two in common usage, which is part of what made
this hard to discuss precisely in the first place).

### 3. How does the P2 messaging avoid conflating three different root causes? -- RESOLVED 2026-07-24

A nonzero/ambiguous exit could mean: (a) a real bug in the user's own code, (b) an unresolved
dependency that a deeper solve (the REQ-009 provider cascade, already-existing warnfix logic)
might fix, or (c) the program was correctly waiting on stdin input and got killed or looked hung.
Offering "try a deeper solve?" is only sensible for (b) -- offering it reflexively for (a) or (c)
would be confusing/unhelpful. The owner's own framing (if uv and conda already installed and
activated correctly, embedded/venv/system don't add solving power, they only matter when uv/conda
can't run at all) is accurate and matches how REQ-009's cascade already works -- but distinguishing
which of (a)/(b)/(c) actually happened is still not solved by this plan, and P2 as shipped does
not attempt to. Resolved by NOT trying to answer "which of (a)/(b)/(c) happened" at all: (c) is
now genuinely rare (P0's activity-aware kill + live tee remove most of it), and (b)'s own "try a
deeper solve" offer already exists and already fires at its own natural point earlier in the flow
(`:warnfix_cascade_detect`, build-time) -- by the time the final `[STATUS]` line prints, that
offer has already happened if it was ever going to. So P2's two new messages (see requirement 5's
own SHIPPED note above) never claim to know which cause applies -- they only state plainly that
the outcome is ambiguous and point the user at running it themselves, which is honest regardless
of which of (a)/(b)/(c) is the real explanation.

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

**What's still untested, and can only be confirmed by watching real Windows CI:** whether stdin
genuinely reaches a grandchild process through the *actual* production shape (a `.bat` launched
via `cmd.exe`, invoking `powershell -File ...` directly per the Finding 6 redesign, launching a
further grandchild via `Process.Start`) -- the Linux-sandbox proxy (bash pipe -> pwsh -> python3)
validates the .NET-level mechanism but not cmd.exe's own console/stdin semantics end-to-end.
**This is no longer a gap with no test plan**: `tests/selfapps_interactive_stdin.ps1` (added
2026-07-24, see Finding 8) is exactly the "non-gating Windows CI lane exercising the redesigned
probe end-to-end" this paragraph previously called for -- it pipes a canned multi-round answer
sequence into a real bootstrap run and asserts the built EXE's own prompts/responses appear in
order in the captured output. What remains is watching its first real CI run; a human's own live
typing timing still can't be automated (and isn't attempted here), but the plumbing question this
plan opened with now has a concrete, automated answer pending confirmation, not just a proposal.

**Answering a question this plan didn't originally ask: does any of this differ across CI
lanes/providers, or between `run_setup.bat`'s own verification and the separate "PVW QuickStart"
(`HP_PVW_KNOWN_IDEMPOTENT`, REQ-005.13) execute-mode discovery path?** No, for two different
reasons. `run_setup.bat`'s own verification chain (`:run_exe_smokerun`/`~exe_smokerun.ps1`,
`:run_failfast_probe`/`~failfast_probe.ps1`) is provider-agnostic by construction -- see Finding
8's last paragraph -- so the new CI test's single uv-lane run is representative of every REQ-009
tier (uv/conda/embed/venv/system alike), not just the lane it happens to run in. Separately,
`tools/pvw_known_idempotent.py`'s `run_script()` (the QuickStart/Tier-2 execute-mode discovery
helper) was NEVER part of this bug at all: it invokes `uvx autopep723 <entry>` via a plain
`subprocess.run(..., timeout=120)` call with full stdio inheritance and zero redirection --
neither `Register-ObjectEvent` nor any tee mechanism sits in that path, so both the Finding-8
reordering bug and its fix are irrelevant to it; its output and input were always passed straight
through to the console/terminal unmodified. That helper does carry its own, unrelated
`timeout=120` risk (a genuinely slow interactive session could be killed by the discovery pass's
own timeout) -- noted here as a distinct, not-yet-actioned observation, not folded into this
plan's scope.

Not sized into loops/slices yet -- this doc exists to fix the shared understanding and terminology
before implementation starts, per the owner's own request to plan first rather than solve inline.
Requirement 1 (including its Finding-8 mechanism replacement) and the requirement-2 verification
test are both implemented; requirement 3 (the 30s-kill question) and P1/P2 remain their own
follow-up passes.
