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
# (self-sequenced chunk reads via StreamReader.ReadAsync(char[], int, int), NOT
# Register-ObjectEvent or ReadLineAsync() -- PowerShell/PowerShell#11937 and Finding 9,
# docs/plan-cli-interactive-verification.md, cover why).
#
# derived requirement (Open Question 1, owner decision 2026-07-24): HP_SMOKERUN_KILL_MS (default
# 30000, unchanged) is a classification checkpoint, not an unconditional deadline -- Kill() fires
# only if $sawOutput is still false at killMs (fully silent = presumed hung). Any bytes observed
# on either stream skips the kill and the wait becomes unbounded, mirroring
# ~failfast_probe.ps1's philosophy -- see docs/agent-interconnect.md "Activity-aware EXE-smoke
# kill" for the full rationale/trade-off. Chunk-based (not line-based) reads are what make this
# actually fire for the canonical `input("prompt")` case -- see Finding 9 in the plan doc above.
#
# This is the canonical source for the HP_EXE_SMOKERUN base64 payload embedded in run_setup.bat.
# After editing, re-encode and paste it into the `set "HP_EXE_SMOKERUN=..."` line;
# tests/test_exe_smokerun.py asserts the embedded payload matches this file (CRLF/LF normalized,
# per the .ps1 PayloadSync convention -- see docs/agent-lessons-learned.md
# "Embedded Helper Update Workflow").
#
# derived requirement ([REQ-026] argv passthrough): HP_SMOKERUN_ARGS, if set, is a full,
# already-quoted Windows Arguments string (the EXE is self-contained, so no separate entry-file
# argv is needed here -- just any forwarded extra args). Used verbatim, no re-quoting.
$exe = $env:HP_SMOKERUN_EXE
$killMs = 30000
if ($env:HP_SMOKERUN_KILL_MS) { $killMs = [int]$env:HP_SMOKERUN_KILL_MS }
$argsRaw = $env:HP_SMOKERUN_ARGS
$outPath = $env:HP_SMOKERUN_OUT
if (-not $outPath) { $outPath = '..\~run.out.txt' }
$errPath = $env:HP_SMOKERUN_ERR
if (-not $errPath) { $errPath = '..\~run.err.txt' }
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
$p.Start() | Out-Null
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
