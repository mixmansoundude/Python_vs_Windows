# Slice 2b-C fail-fast probe: launches the caller's program, waits up to HP_FAILFAST_PROBE_MS to
# classify it as "exited fast" (a stale/broken cached artifact -- candidate for discard+rebuild)
# vs. "still running" (the user's real, possibly long-running program -- never touched again).
# Never calls $p.Kill() -- once the probe window is exceeded, the second WaitForExit() is
# unbounded so a healthy long-running app is never force-stopped.
#
# Reads all inputs from env vars set by the caller (no positional args) to avoid any cmd.exe
# quoting hazard: HP_PROBE_EXE, HP_PROBE_ARGS (raw, unquoted -- single path argument only, see
# below), HP_PROBE_CWD, HP_FAILFAST_PROBE_MS. Output-path env vars (HP_PROBE_OUT/HP_PROBE_ERR,
# defaulting to ~run.out.txt/~run.err.txt) were added in the 2b-C checkpoint slice so the
# elective secondary run (:run_postexec_checkpoint) never overwrites the primary verification
# run's captured files. Caller must pre-truncate the output files before invoking (this script
# only writes them once, at process exit, so a stale prior run's content would otherwise linger
# for the full unbounded-wait duration).
#
# derived requirement: $si.Arguments is built via '"' + $rawArgs + '"', which only works
# correctly for a SINGLE path argument -- HP_PROBE_ARGS must not be repurposed for a multi-token
# command line without revisiting this quoting.
#
# Prints "$exceeded|$($p.ExitCode)" to stdout on completion (caller parses via a for /f split).
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
$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName = $exe
if ($rawArgs) { $si.Arguments = '"' + $rawArgs + '"' }
$si.WorkingDirectory = $workDir
$si.UseShellExecute = $false
$si.RedirectStandardOutput = $true
$si.RedirectStandardError = $true
$p = [System.Diagnostics.Process]::Start($si)
$so = $p.StandardOutput.ReadToEndAsync()
$se = $p.StandardError.ReadToEndAsync()
$fast = $p.WaitForExit($probeMs)
$exceeded = 0
if (-not $fast) {
    $exceeded = 1
    $p.WaitForExit()
}
$so.Result | Set-Content -Path $outPath -Encoding ASCII
$se.Result | Set-Content -Path $errPath -Encoding ASCII
"$exceeded|$($p.ExitCode)"
