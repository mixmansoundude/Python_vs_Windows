# :exe_smokerun_hints' bounded diagnostic re-run helper. Diagnostic-only stdout+stderr snapshot
# for stderr pattern-matching (ModuleNotFoundError/FileNotFoundError); never shown live. Kill is
# UNCONDITIONAL at the deadline (not activity-aware like exe_smokerun.ps1/failfast_probe.ps1) --
# partial output on a hang beats hanging the bootstrap on a run nobody is watching. See CLAUDE.md
# former item 15 / docs/agent-closed-backlog.md for the untimed-rerun gap this closed.
#
# Reads: HP_HINT_RERUN_EXE (a path to the built EXE, e.g. dist\<env>.exe, relative to the current
# working directory (CWD) -- the caller runs this script with CWD set to the app root, matching
# :run_exe_smokerun's own CWD per CLAUDE.md Active Backlog Item 38; see
# docs/agent-interconnect.md "Single-verification smoke model"). HP_HINT_RERUN_OUT (default
# ~exe_out.txt, CWD-relative -- the app root) gets combined stdout+stderr, matching the original
# `2>&1` merge. HP_HINT_RERUN_KILL_MS (default 10000) is a test override, mirroring
# HP_SMOKERUN_KILL_MS.
#
# $killMs is always written to HP_HINT_RERUN_KILLMS_OUT (default ~exe_hint_killms.txt) so tests can
# assert the override was honored directly -- wall-clock elapsed proved unreliable on shared
# real-Windows CI (see docs/agent-lessons-learned.md's "third bounded-launch helper" entry).
#
# Canonical source for the HP_EXE_HINT_RERUN payload in run_setup.bat. After editing:
# `python tools/sync_payload.py HP_EXE_HINT_RERUN tools/exe_hint_rerun.ps1`. PayloadSync in
# tests/test_exe_hint_rerun.py asserts the match (CRLF/LF normalized).
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
# $drainMs bounds taskkill.exe, the post-kill WaitForExit, AND the pipe drain below -- moved up
# so it's defined before first use.
$drainMs = 5000
$exited = $p.WaitForExit($killMs)
if (-not $exited) {
    # Process.Kill() (Win PS 5.1 = .NET Framework, no entireProcessTree overload) only kills $p;
    # a child inheriting the redirected pipes could outlive it and hang ReadToEndAsync forever.
    # taskkill /T kills the whole tree (confirmed exercised on real CI, PR #410).
    #
    # derived requirement: taskkill.exe now runs via its own Process object with a BOUNDED
    # WaitForExit, and the WaitForExit below is bounded too -- both used to be unbounded. Real CI
    # (three runs, 2026-08-07) showed this helper taking 48-60+s against a 500ms test deadline;
    # see docs/agent-lessons-learned.md's "third bounded-launch helper" entry for the full
    # incident. $p has already been sent /F /T plus Kill(), so a slow confirmation just means
    # "stop waiting," not "still alive."
    try {
        $tkInfo = New-Object System.Diagnostics.ProcessStartInfo
        $tkInfo.FileName = 'taskkill.exe'
        $tkInfo.Arguments = "/F /T /PID $($p.Id)"
        $tkInfo.UseShellExecute = $false
        $tkInfo.RedirectStandardOutput = $true
        $tkInfo.RedirectStandardError = $true
        $tk = [System.Diagnostics.Process]::Start($tkInfo)
        if (-not $tk.WaitForExit($drainMs)) { try { $tk.Kill() } catch {} }
    } catch {}
    try { $p.Kill() } catch {}
    $p.WaitForExit($drainMs) | Out-Null
} else {
    $p.WaitForExit()
}

# Bounded final read, not a blind .Result block -- a descendant taskkill/T missed (or some
# exotic handle-inheritance edge case) must not hang this diagnostic-only helper. Task.Wait(ms)
# returns false on timeout without throwing; a stuck pipe degrades to partial/empty output.
$out = ''
$err = ''
if ($outTask.Wait($drainMs)) { try { $out = $outTask.Result } catch {} }
if ($errTask.Wait($drainMs)) { try { $err = $errTask.Result } catch {} }
($out + $err) | Set-Content -Path $outPath -Encoding ASCII
