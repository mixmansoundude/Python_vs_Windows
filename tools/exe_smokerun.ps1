# :run_exe_smokerun's dedicated helper -- the ONLY place in this file family allowed to
# force-kill (Kill()) the verification run, after a hard 30s cap. Unlike ~failfast_probe.ps1
# (never kills -- covers the untimed fastpath/interpreter/checkpoint call sites), this IS the
# fresh-build verification run itself: nothing else will ever confirm this particular build
# worked, so an unresponsive process here cannot be trusted to eventually finish the way a
# previously-verified cached artifact or interpreter run can.
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
# Same live-tee (Register-ObjectEvent + Write-Host/[Console]::Error.WriteLine) and deterministic
# EOF-flag drain-wait as ~failfast_probe.ps1 -- see that file's header comment for the full
# rationale (a blocking WaitForExit() prevents PowerShell's own event dispatch from running;
# Microsoft's documented "call WaitForExit() twice" guidance for async-redirected output was
# empirically proven insufficient on its own, so both streams' own null-Data EOF events are
# tracked explicitly and waited on before the accumulated buffers are considered final). The one
# behavioral difference from ~failfast_probe.ps1: after HP_SMOKERUN_KILL_MS (env var, default
# 30000 when unset -- run_setup.bat never sets it, so production behavior is unchanged from the
# prior inline -Command implementation's hardcoded 30s; the override exists purely so a test can
# exercise the Kill() branch without a real 30s wait), this script calls $p.Kill() --
# :run_exe_smokerun is the sole verification pass for a build that has never been confirmed
# working, unlike the untimed call sites ~failfast_probe.ps1 covers. The 30s default and the
# Kill() behavior itself are UNCHANGED from the prior inline -Command implementation -- this
# helper only changes HOW output is captured/shown and HOW the result is signaled back, per
# docs/plan-cli-interactive-verification.md's Non-Goals (revisiting the 30s cap itself is
# Open Question 1 in that doc, not decided here).
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
$killed = $false
while (-not $p.WaitForExit(100)) {
    if ($sw.ElapsedMilliseconds -ge $killMs) {
        try { $p.Kill() } catch {}
        $killed = $true
        break
    }
}
$p.WaitForExit()

$drainSw = [System.Diagnostics.Stopwatch]::StartNew()
while ((-not $outCtx.Done -or -not $errCtx.Done) -and $drainSw.ElapsedMilliseconds -lt 5000) {
    Start-Sleep -Milliseconds 20
}

$outBuf.ToString() | Set-Content -Path $outPath -Encoding ASCII
$errBuf.ToString() | Set-Content -Path $errPath -Encoding ASCII
if ($killed) {
    "-1" | Set-Content -Path $resultPath -Encoding ASCII
} else {
    "$($p.ExitCode)" | Set-Content -Path $resultPath -Encoding ASCII
}

Get-EventSubscriber -ErrorAction SilentlyContinue | Unregister-Event -ErrorAction SilentlyContinue
