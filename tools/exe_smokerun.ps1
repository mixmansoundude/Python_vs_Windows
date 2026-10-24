# :run_exe_smokerun's helper -- the ONLY place in this file family allowed to force-kill (Kill()) the verification
# run: nothing else will confirm a fresh build worked, so a silent process here is presumed hung.
#
# Item 82 slice 2: ~smokerun_killed.txt is written when (and only when) Kill() really stops a silent process. Exit -1
# alone is not proof: a failed launch or a program that exits -1 reads the same.
# Item 87: when Start() fails (a stub, empty or cut-off EXE), ~launch_failed.txt gets the reason, one line of
# printable ASCII, the result is -1 and the script returns. Without it the poll loop below never ends.
#
# Inputs come from env vars (no cmd.exe quoting hazards): HP_SMOKERUN_EXE is the CWD-relative or absolute EXE path
# (CWD = app root); HP_SMOKERUN_OUT/ERR default to ~run.out.txt / ~run.err.txt and HP_SMOKERUN_RESULT to
# ~smokerun_result.txt. The exit code goes to the result file, NOT stdout, because the caller runs this script
# directly so the live-teed output reaches the console (see ~failfast_probe.ps1). The caller pre-truncates the files.
# HP_SMOKERUN_ARGS is a full, already-quoted Arguments string (REQ-026), used verbatim.
#
# Chunk reads via StreamReader.ReadAsync(char[], int, int), one in flight per stream: not Register-ObjectEvent or
# ReadLineAsync (PowerShell/PowerShell#11937, docs/plan-cli-interactive-verification.md Finding 9).
#
# derived requirement: HP_SMOKERUN_KILL_MS (default 30000) is a classification checkpoint, not a deadline: Kill() fires
# only if no byte was seen on either stream by then, and any output makes the wait unbounded (docs/agent-interconnect.md
# "Activity-aware EXE-smoke kill").
#
# Canonical source of the HP_EXE_SMOKERUN payload in run_setup.bat; re-sync with tools/sync_payload.py.
$exe = $env:HP_SMOKERUN_EXE
$killMs = 30000
if ($env:HP_SMOKERUN_KILL_MS) { $killMs = [int]$env:HP_SMOKERUN_KILL_MS }
$argsRaw = $env:HP_SMOKERUN_ARGS
$outPath = $env:HP_SMOKERUN_OUT
if (-not $outPath) { $outPath = '~run.out.txt' }
$errPath = $env:HP_SMOKERUN_ERR
if (-not $errPath) { $errPath = '~run.err.txt' }
$resultPath = $env:HP_SMOKERUN_RESULT
if (-not $resultPath) { $resultPath = '~smokerun_result.txt' }

$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName = $exe
if ($argsRaw) { $si.Arguments = $argsRaw }
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
    '-1' | Set-Content -Path $resultPath -Encoding ASCII
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
$killed = $false
$sawOutput = $false
while ((-not $p.HasExited) -or (-not $outDone) -or (-not $errDone)) {
    if ((-not $outDone) -and $outTask.IsCompleted) {
        $n = $outTask.Result
        if ($n -eq 0) {
            $outDone = $true
        } else {
            $sawOutput = $true
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
            $sawOutput = $true
            $chunk = [string]::new($errChunkBuf, 0, $n)
            [Console]::Error.Write($chunk)
            $null = $errBuf.Append($chunk)
            $errTask = $p.StandardError.ReadAsync($errChunkBuf, 0, $errChunkBuf.Length)
        }
    }
    if ((-not $killed) -and (-not $sawOutput) -and (-not $p.HasExited) -and ($sw.ElapsedMilliseconds -ge $killMs)) {
        try { $p.Kill(); '1' | Set-Content -Path '~smokerun_killed.txt' -Encoding ASCII } catch {}
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
