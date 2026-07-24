# :run_exe_smokerun's dedicated helper -- the ONLY place in this file family allowed to
# force-kill (Kill()) the verification run. Unlike ~failfast_probe.ps1 (never kills -- covers
# the untimed fastpath/interpreter/checkpoint call sites), this IS the fresh-build verification
# run itself: nothing else will ever confirm this particular build worked, so an unresponsive
# process here cannot be trusted to eventually finish the way a previously-verified cached
# artifact or interpreter run can.
#
# Reads inputs from env vars (same cmd.exe-quoting-hazard-avoidance reasoning as
# ~failfast_probe.ps1's own header comment): HP_SMOKERUN_EXE (bare filename; caller runs this
# script with CWD already set to dist\, matching :run_exe_smokerun's existing pushd dist
# convention -- REQ-018 2b-A.2, load-bearing for the CWD-relative config.json xfail case, see
# docs/agent-interconnect.md "Single-verification smoke model"). HP_SMOKERUN_OUT/HP_SMOKERUN_ERR
# default to ..\~run.out.txt / ..\~run.err.txt (relative to dist\, matching the pre-existing
# convention). HP_SMOKERUN_RESULT (default ~smokerun_result.txt) is where this script writes its
# exit-code result -- NOT stdout; see ~failfast_probe.ps1's header comment (same reasoning: the
# caller invokes this script directly, no for /f/backtick stdout capture, so live-teed output
# reaches the console instead of being silently swallowed and corrupting result parsing). Caller
# must pre-truncate the output/result files before invoking, same as ~failfast_probe.ps1.
#
# Same live-tee as ~failfast_probe.ps1 -- see that file's header comment for the full rationale
# (self-sequenced StreamReader.ReadLineAsync() polling, NOT Register-ObjectEvent: that dispatches
# via ThreadPool.QueueUserWorkItem, a confirmed, filed PowerShell bug -- PowerShell/PowerShell#11937
# -- that can deliver lines out of order within a single stream when several arrive close
# together; only ever one read in flight per stream here, so no reordering is possible).
#
# derived requirement (Open Question 1, owner decision 2026-07-24): HP_SMOKERUN_KILL_MS (default
# 30000, unchanged) is now a classification checkpoint, not an unconditional deadline -- Kill()
# fires only if $sawOutput is still false at killMs (a fully silent process = presumed hung).
# Once any output line is observed (the best available proxy for "alive / likely at an
# interactive prompt" -- stdin itself isn't observable here, see docs/agent-interconnect.md
# "Activity-aware EXE-smoke kill" for the full rationale and accepted trade-off), the kill is
# skipped and the wait becomes unbounded, mirroring ~failfast_probe.ps1's own philosophy.
#
# This is the canonical source for the HP_EXE_SMOKERUN base64 payload embedded in run_setup.bat.
# After editing, re-encode and paste it into the `set "HP_EXE_SMOKERUN=..."` line;
# tests/test_exe_smokerun.py asserts the embedded payload matches this file (CRLF/LF normalized,
# per the .ps1 PayloadSync convention -- see docs/agent-lessons-learned.md
# "Embedded Helper Update Workflow").
$exe = $env:HP_SMOKERUN_EXE
$killMs = 30000
if ($env:HP_SMOKERUN_KILL_MS) { $killMs = [int]$env:HP_SMOKERUN_KILL_MS }
$outPath = $env:HP_SMOKERUN_OUT
if (-not $outPath) { $outPath = '..\~run.out.txt' }
$errPath = $env:HP_SMOKERUN_ERR
if (-not $errPath) { $errPath = '..\~run.err.txt' }
$resultPath = $env:HP_SMOKERUN_RESULT
if (-not $resultPath) { $resultPath = '~smokerun_result.txt' }

$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName = $exe
$si.UseShellExecute = $false
$si.RedirectStandardOutput = $true
$si.RedirectStandardError = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $si
$p.Start() | Out-Null

$outBuf = New-Object System.Text.StringBuilder
$errBuf = New-Object System.Text.StringBuilder
$outTask = $p.StandardOutput.ReadLineAsync()
$errTask = $p.StandardError.ReadLineAsync()
$outDone = $false
$errDone = $false

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$killed = $false
$sawOutput = $false
while ((-not $p.HasExited) -or (-not $outDone) -or (-not $errDone)) {
    if ((-not $outDone) -and $outTask.IsCompleted) {
        $line = $outTask.Result
        if ($null -eq $line) {
            $outDone = $true
        } else {
            $sawOutput = $true
            Write-Host $line
            $null = $outBuf.Append($line + "`n")
            $outTask = $p.StandardOutput.ReadLineAsync()
        }
    }
    if ((-not $errDone) -and $errTask.IsCompleted) {
        $line = $errTask.Result
        if ($null -eq $line) {
            $errDone = $true
        } else {
            $sawOutput = $true
            [Console]::Error.WriteLine($line)
            $null = $errBuf.Append($line + "`n")
            $errTask = $p.StandardError.ReadLineAsync()
        }
    }
    if ((-not $killed) -and (-not $sawOutput) -and (-not $p.HasExited) -and ($sw.ElapsedMilliseconds -ge $killMs)) {
        try { $p.Kill() } catch {}
        $killed = $true
    }
    Start-Sleep -Milliseconds 20
}
$p.WaitForExit()

$outBuf.ToString() | Set-Content -Path $outPath -Encoding ASCII
$errBuf.ToString() | Set-Content -Path $errPath -Encoding ASCII
if ($killed) {
    "-1" | Set-Content -Path $resultPath -Encoding ASCII
} else {
    "$($p.ExitCode)" | Set-Content -Path $resultPath -Encoding ASCII
}

Get-EventSubscriber -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue
