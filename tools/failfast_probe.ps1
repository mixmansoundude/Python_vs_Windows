# Slice 2b-C fail-fast probe: launches the caller's program, waits up to HP_FAILFAST_PROBE_MS to classify it as
# "exited fast" (stale/broken cached artifact: discard+rebuild candidate) vs. "still running" (the user's real,
# possibly long-running program: never touched again). Never calls $p.Kill(); past the probe window the wait is
# unbounded so a healthy app is never force-stopped.
#
# Item 87: when Start() fails (a stub, empty or cut-off EXE), ~launch_failed.txt gets the reason, one line of
# printable ASCII, the result is 0|-1 (not exceeded, exit -1: the cached-EXE caller discards and rebuilds on that)
# and the script returns. Without it the poll loop below never ends.
#
# Inputs via env vars (no cmd.exe quoting hazards): HP_PROBE_EXE, HP_PROBE_ARGS, HP_PROBE_CWD, HP_FAILFAST_PROBE_MS,
# HP_PROBE_OUT/HP_PROBE_ERR (default ~run.out.txt/~run.err.txt), HP_PROBE_RESULT (default ~probe_result.txt, the
# line "$exceeded|$exitcode", NOT stdout). The caller pre-truncates the output and result files.
# HP_PROBE_ARGS is a full, already-quoted Arguments string (REQ-026), used verbatim; the caller quotes each token.
#
# The child's stdout/stderr are live-teed so a stdin-interactive program's prompts reach a double-clicked user.
# Reads are chunk-based, StreamReader.ReadAsync(char[], int, int), with ONE read in flight per stream: not
# Register-ObjectEvent (reorders lines within a stream, PowerShell/PowerShell#11937) and not ReadLineAsync (a prompt
# with no trailing newline stays invisible, Finding 9). EOF is a 0-length read. Cross-stream interleaving was never
# guaranteed. Rationale: docs/plan-cli-interactive-verification.md Findings 5b/6/7/8/9.
#
# Canonical source of the HP_FAILFAST_PROBE payload in run_setup.bat; re-sync with tools/sync_payload.py.
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
if ($rawArgs) { $si.Arguments = $rawArgs }
$si.WorkingDirectory = $workDir
$si.UseShellExecute = $false
$si.RedirectStandardOutput = $true
$si.RedirectStandardError = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $si
try { $p.Start() | Out-Null } catch {
    $e = $_.Exception
    if ($e.InnerException) { $e = $e.InnerException }
    $why = ($e.Message -replace '[^\x20-\x7E]', '?')
    if ($why.Length -gt 200) { $why = $why.Substring(0, 200) }
    $why | Set-Content -Path '~launch_failed.txt' -Encoding ASCII
    Write-Host '[WARN] The program could not be started, so it was not run.'
    '' | Set-Content -Path $outPath -Encoding ASCII
    '' | Set-Content -Path $errPath -Encoding ASCII
    '0|-1' | Set-Content -Path $resultPath -Encoding ASCII
    exit 0
}
Write-Host "[INFO] Process ID $($p.Id). If it seems stuck: Task Manager > Details tab > find this PID > End Task (this window stays open)."

$outBuf = New-Object System.Text.StringBuilder
$errBuf = New-Object System.Text.StringBuilder
$outChunkBuf = New-Object char[] 4096
$errChunkBuf = New-Object char[] 4096
$outTask = $p.StandardOutput.ReadAsync($outChunkBuf, 0, $outChunkBuf.Length)
$errTask = $p.StandardError.ReadAsync($errChunkBuf, 0, $errChunkBuf.Length)
$outDone = $false
$errDone = $false

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$exceeded = 0
while ((-not $p.HasExited) -or (-not $outDone) -or (-not $errDone)) {
    if ((-not $outDone) -and $outTask.IsCompleted) {
        $n = $outTask.Result
        if ($n -eq 0) {
            $outDone = $true
        } else {
            $chunk = [string]::new($outChunkBuf, 0, $n)
            [Console]::Out.Write($chunk)
            $null = $outBuf.Append($chunk)
            $outTask = $p.StandardOutput.ReadAsync($outChunkBuf, 0, $outChunkBuf.Length)
        }
    }
    if ((-not $errDone) -and $errTask.IsCompleted) {
        $n = $errTask.Result
        if ($n -eq 0) {
            $errDone = $true
        } else {
            $chunk = [string]::new($errChunkBuf, 0, $n)
            [Console]::Error.Write($chunk)
            $null = $errBuf.Append($chunk)
            $errTask = $p.StandardError.ReadAsync($errChunkBuf, 0, $errChunkBuf.Length)
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
