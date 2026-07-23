# Slice 2b-C fail-fast probe: launches the caller's program, waits up to HP_FAILFAST_PROBE_MS to
# classify it as "exited fast" (stale/broken cached artifact -- discard+rebuild candidate) vs.
# "still running" (the user's real, possibly long-running program -- never touched again). Never
# calls $p.Kill() -- past the probe window the wait is unbounded so a healthy app is never
# force-stopped.
#
# Inputs via env vars (avoids cmd.exe quoting hazards): HP_PROBE_EXE, HP_PROBE_ARGS (raw,
# unquoted -- SINGLE path argument only; $si.Arguments = '"' + $rawArgs + '"' mis-tokenizes a
# multi-token value), HP_PROBE_CWD, HP_FAILFAST_PROBE_MS, HP_PROBE_OUT/HP_PROBE_ERR (default
# ~run.out.txt/~run.err.txt), HP_PROBE_RESULT (default ~probe_result.txt -- "$exceeded|$exitcode",
# NOT stdout). Caller must pre-truncate output/result files before invoking.
#
# Live-tees the child's stdout/stderr (Register-ObjectEvent) instead of only writing to disk at
# exit, so a stdin-interactive program's prompts reach a real double-clicked user. Uses a POLLING
# `while (-not $p.WaitForExit(100)) {}` loop, never a single blocking WaitForExit() -- that would
# not yield to PowerShell's event dispatch, so -Action scriptblocks would queue but never run
# until it returns (PowerShell/PowerShell#11065).
#
# Does NOT trust ".NET docs say call WaitForExit() twice" alone to mean the async buffers are
# drained -- empirically proven insufficient (a final unflushed-then-exit-flushed line's event can
# fire AFTER both WaitForExit() calls return). Instead each stream's own null-Data EOF event sets
# $outCtx.Done/$errCtx.Done, and a bounded poll waits for both before the buffers are read.
#
# Result goes to $resultPath, not stdout: the caller used to wrap this script in a
# `for /f ('powershell...') do` to capture one final stdout line, but for /f captures the ENTIRE
# stdout, which would swallow every teed line and corrupt the exceeded|exitcode split. The caller
# now invokes this script directly (no for /f) so live output reaches the console, then reads
# $resultPath with a separate, safe (static-file) for /f.
#
# Full rationale + citations: docs/plan-cli-interactive-verification.md Findings 5b/6/7.
#
# This is the canonical source for the HP_FAILFAST_PROBE base64 payload embedded in
# run_setup.bat. After editing, re-encode and paste it into the `set "HP_FAILFAST_PROBE=..."`
# line; tests/test_failfast_probe.py asserts the embedded payload matches this file (with
# CRLF/LF normalized, per the .ps1 PayloadSync convention -- see
# docs/agent-lessons-learned.md "Embedded Helper Update Workflow").
$exe = $env:HP_PROBE_EXE
$rawArgs = $env:HP_PROBE_ARGS
$workDir = $env:HP_PROBE_CWD
$probeMs = [int]$env:HP_FAILFAST_PROBE_MS
$outPath = $env:HP_PROBE_OUT
if (-not $outPath) { $outPath = '~run.out.txt' }
$errPath = $env:HP_PROBE_ERR
if (-not $errPath) { $errPath = '~run.err.txt' }
$resultPath = $env:HP_PROBE_RESULT
if (-not $resultPath) { $resultPath = '~probe_result.txt' }

$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName = $exe
if ($rawArgs) { $si.Arguments = '"' + $rawArgs + '"' }
$si.WorkingDirectory = $workDir
$si.UseShellExecute = $false
$si.RedirectStandardOutput = $true
$si.RedirectStandardError = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $si

$outBuf = New-Object System.Text.StringBuilder
$errBuf = New-Object System.Text.StringBuilder
$outCtx = [PSCustomObject]@{ Buf = $outBuf; Done = $false }
$errCtx = [PSCustomObject]@{ Buf = $errBuf; Done = $false }
Register-ObjectEvent -InputObject $p -EventName OutputDataReceived -MessageData $outCtx -Action {
    if ($null -ne $EventArgs.Data) {
        Write-Host $EventArgs.Data
        $null = $Event.MessageData.Buf.Append($EventArgs.Data + "`n")
    } else {
        $Event.MessageData.Done = $true
    }
} | Out-Null
Register-ObjectEvent -InputObject $p -EventName ErrorDataReceived -MessageData $errCtx -Action {
    if ($null -ne $EventArgs.Data) {
        [Console]::Error.WriteLine($EventArgs.Data)
        $null = $Event.MessageData.Buf.Append($EventArgs.Data + "`n")
    } else {
        $Event.MessageData.Done = $true
    }
} | Out-Null

$p.Start() | Out-Null
$p.BeginOutputReadLine()
$p.BeginErrorReadLine()

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$exceeded = 0
while (-not $p.WaitForExit(100)) {
    if (-not $exceeded -and $sw.ElapsedMilliseconds -ge $probeMs) {
        $exceeded = 1
    }
}
# Documented best practice for async-redirected output (Process.WaitForExit(Int32) Remarks); kept
# as a first attempt, but the explicit drain-wait below is the actual correctness guarantee (see
# header comment).
$p.WaitForExit()

# Deterministic drain-wait: block (bounded) until BOTH streams have signaled their own EOF via a
# null-Data event, not just until WaitForExit() has returned. Start-Sleep yields to PowerShell's
# event-dispatch loop the same way the polling WaitForExit(100) loop above does.
$drainSw = [System.Diagnostics.Stopwatch]::StartNew()
while ((-not $outCtx.Done -or -not $errCtx.Done) -and $drainSw.ElapsedMilliseconds -lt 5000) {
    Start-Sleep -Milliseconds 20
}

$outBuf.ToString() | Set-Content -Path $outPath -Encoding ASCII
$errBuf.ToString() | Set-Content -Path $errPath -Encoding ASCII
"$exceeded|$($p.ExitCode)" | Set-Content -Path $resultPath -Encoding ASCII

Get-EventSubscriber -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue
