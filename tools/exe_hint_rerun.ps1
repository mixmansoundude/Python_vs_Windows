# :exe_smokerun_hints' bounded diagnostic re-run helper. Unlike exe_smokerun.ps1/failfast_probe.ps1
# (activity-aware -- once a process has printed anything, the kill is skipped and the wait becomes
# unbounded, since those cover REAL verification runs worth waiting on), this re-run is diagnostic
# ONLY: its sole purpose is a stdout+stderr snapshot for stderr pattern-matching (ModuleNotFoundError/
# FileNotFoundError signatures), never shown live to the user. Partial output on a hang is fine and
# strictly preferred over hanging the whole bootstrap a second time on a run nobody is watching --
# so the kill here is UNCONDITIONAL at the deadline, not activity-aware. See CLAUDE.md's former
# Active Backlog item 15 / docs/agent-closed-backlog.md for the gap this closes: the prior inline
# ":exe_smokerun_hints" body did a plain, untimed `"%ENVNAME%.exe" > "~exe_out.txt" 2>&1` -- the
# ONE user-code launch point in this file with no timeout at all, on the theory that a genuine
# ModuleNotFoundError/FileNotFoundError always exits immediately. That theory holds for a
# DETERMINISTIC failure, but this is a fresh re-run of the same binary; any non-determinism (a
# race, an environment check that sometimes succeeds, anything that occasionally blocks on
# inherited stdin instead of exiting fast) could hang this second, untimed invocation even though
# the FIRST invocation legitimately classified as "fast, real, non-hang failure".
#
# Reads: HP_HINT_RERUN_EXE (bare filename; caller runs this with CWD already set to dist\, mirroring
# exe_smokerun.ps1's own convention). HP_HINT_RERUN_OUT (default ~exe_out.txt, relative to dist\)
# is where combined stdout+stderr is written -- matching the ORIGINAL `2>&1` merge-into-one-file
# behavior exactly, since the existing findstr hint-matching in :exe_smokerun_hints only checks for
# substring presence in that one file, never which stream a line came from. HP_HINT_RERUN_KILL_MS
# (default 10000 -- a diagnostic capture on an already-failed run does not need the full 30s
# primary-verification budget) is a test-only override point, mirroring HP_SMOKERUN_KILL_MS's
# established pattern.
#
# derived requirement: the resolved $killMs is ALWAYS written to HP_HINT_RERUN_KILLMS_OUT (default
# ~exe_hint_killms.txt) right after it's computed, unconditionally -- production callers never read
# this file, so it costs nothing there. It exists so tests can assert the override was actually
# honored by reading this DIRECT value, instead of inferring it from wall-clock elapsed time (which
# proved unreliable on shared real-Windows CI runners -- the same test measured 9.2s, 13.5s, 14.6s,
# and 16.3s of overhead across four different real-CI runs for the identical 500ms override, a
# moving target that no fixed bound could chase; see docs/agent-lessons-learned.md).
#
# This is the canonical source for the HP_EXE_HINT_RERUN base64 payload embedded in run_setup.bat.
# After editing, run `python tools/sync_payload.py HP_EXE_HINT_RERUN tools/exe_hint_rerun.ps1`;
# tests/test_exe_hint_rerun.py asserts the embedded payload matches this file (CRLF/LF normalized,
# per the .ps1 PayloadSync convention -- see docs/agent-lessons-learned.md
# "Embedded Helper Update Workflow").
$exe = $env:HP_HINT_RERUN_EXE
$outPath = $env:HP_HINT_RERUN_OUT
if (-not $outPath) { $outPath = '~exe_out.txt' }
$killMs = 10000
if ($env:HP_HINT_RERUN_KILL_MS) { $killMs = [int]$env:HP_HINT_RERUN_KILL_MS }
$killMsOutPath = $env:HP_HINT_RERUN_KILLMS_OUT
if (-not $killMsOutPath) { $killMsOutPath = '~exe_hint_killms.txt' }
"$killMs" | Set-Content -Path $killMsOutPath -Encoding ASCII

$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName = $exe
$si.UseShellExecute = $false
$si.RedirectStandardOutput = $true
$si.RedirectStandardError = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $si
$p.Start() | Out-Null

$outTask = $p.StandardOutput.ReadToEndAsync()
$errTask = $p.StandardError.ReadToEndAsync()
$exited = $p.WaitForExit($killMs)
if (-not $exited) {
    # derived requirement: Process.Kill() (the parameterless overload -- Windows PowerShell 5.1
    # targets .NET Framework, which has no Process.Kill(entireProcessTree) overload; that's
    # .NET 5+ only) terminates ONLY $p itself. A PyInstaller onefile bootloader (or any program)
    # that spawns a child inheriting the redirected stdout/stderr handles can leave that child
    # running after $p is killed -- the pipe then never reaches EOF, and an unbounded
    # ReadToEndAsync().Result would hang forever, defeating the entire point of this bounded
    # helper. taskkill /T terminates the whole process tree, not just $p. NOT independently
    # verified on real Windows CI that a genuine descendant-holds-the-pipe scenario is fully
    # covered by this (no Windows environment available to construct that repro) -- the bounded
    # final read below is a second, independent safety net for exactly that residual risk.
    try { & taskkill.exe /F /T /PID $p.Id 2>$null 1>$null } catch {}
    try { $p.Kill() } catch {}
}
$p.WaitForExit()

# Bounded final read, NOT a blind .Result block: even after killing the process tree, a
# descendant taskkill /T did not catch (or some other exotic handle-inheritance edge case)
# should not be able to hang this diagnostic-only helper indefinitely. Task.Wait(ms) returns
# false on timeout without throwing, so a stuck pipe degrades to partial/empty output instead
# of an unbounded wait.
$drainMs = 5000
$out = ''
$err = ''
if ($outTask.Wait($drainMs)) { try { $out = $outTask.Result } catch {} }
if ($errTask.Wait($drainMs)) { try { $err = $errTask.Result } catch {} }
($out + $err) | Set-Content -Path $outPath -Encoding ASCII
