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
# Live-tees the child's stdout/stderr so a stdin-interactive program's prompts reach a real
# double-clicked user, instead of only writing captured output to disk at exit.
#
# derived requirement: does NOT use Register-ObjectEvent on OutputDataReceived/ErrorDataReceived.
# That was the original design and was found, via this repo's own local pwsh testing, to
# reorder lines WITHIN a single stream (e.g. round 2's output landing before round 1's in the
# captured/teed text, non-deterministically) -- root-caused to a confirmed, filed PowerShell bug
# (PowerShell/PowerShell#11937): those events dispatch via ThreadPool.QueueUserWorkItem, which
# does not guarantee delivery order when several lines arrive close together. Fixed by polling
# StreamReader.ReadLineAsync() directly instead: only ONE read is ever in flight per stream at a
# time (the next read is not issued until the current one is consumed), so there is no possible
# out-of-order delivery for a single stream -- ordering is self-sequenced, not dependent on any
# runtime's callback-scheduling guarantee. Cross-stream (stdout vs stderr) interleaving was never
# guaranteed and still isn't -- that reflects the child's own two independent pipes, not a bug.
#
# Full rationale + citations: docs/plan-cli-interactive-verification.md Findings 5b/6/7/8.
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
$p.Start() | Out-Null

$outBuf = New-Object System.Text.StringBuilder
$errBuf = New-Object System.Text.StringBuilder
$outTask = $p.StandardOutput.ReadLineAsync()
$errTask = $p.StandardError.ReadLineAsync()
$outDone = $false
$errDone = $false

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$exceeded = 0
while ((-not $p.HasExited) -or (-not $outDone) -or (-not $errDone)) {
    if ((-not $outDone) -and $outTask.IsCompleted) {
        $line = $outTask.Result
        if ($null -eq $line) {
            $outDone = $true
        } else {
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
            [Console]::Error.WriteLine($line)
            $null = $errBuf.Append($line + "`n")
            $errTask = $p.StandardError.ReadLineAsync()
        }
    }
    if ((-not $exceeded) -and ($sw.ElapsedMilliseconds -ge $probeMs)) {
        $exceeded = 1
    }
    Start-Sleep -Milliseconds 20
}
$p.WaitForExit()

$outBuf.ToString() | Set-Content -Path $outPath -Encoding ASCII
$errBuf.ToString() | Set-Content -Path $errPath -Encoding ASCII
"$exceeded|$($p.ExitCode)" | Set-Content -Path $resultPath -Encoding ASCII
