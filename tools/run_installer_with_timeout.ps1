# Runs an external installer executable with a generous, configurable timeout ceiling.
#
# Closes CLAUDE.md Active Backlog item 14: the three "start "" /wait" external-installer
# launches (Miniconda AllUsers, Miniconda JustMe, NI-VISA) previously had no process-level
# timeout at all, unlike this file's deliberately-wrapped user-code launches -- a genuinely
# stuck installer (a silently-blocking UAC/reboot prompt, a wedged sub-installer) could hang
# the whole bootstrap forever with zero recourse.
#
# Deliberately NOT modeled on tools/exe_smokerun.ps1's ~30s aggressive kill window -- these are
# REAL installer processes, and killing one too early (while it's still legitimately writing
# files/registry keys) risks a worse outcome than a slow-but-succeeding install: a genuinely
# corrupted half-installed target. The timeout here is a generous safety CEILING against a truly
# hung process, not a responsiveness check -- see the per-call-site timeout values in
# run_setup.bat's own comments for the real-world research behind each number (documented
# Miniconda/NI-VISA install-time reports, not guesses).
#
# Inputs via env vars (avoids cmd.exe quoting hazards, matches ~failfast_probe.ps1's contract):
#   HP_INSTALLER_EXE          - path to the installer executable.
#   HP_INSTALLER_ARGS         - a single, already-prepared Arguments string (caller's
#                                responsibility to quote/join tokens; matches HP_PROBE_ARGS's
#                                own "caller provides a ready string" contract).
#   HP_INSTALLER_TIMEOUT_MS   - timeout in milliseconds before the process is force-killed.
#   HP_INSTALLER_RESULT       - output result file path (default ~installer_result.txt),
#                                written as "<exitcode>|<timedout:0/1>".
#
# UseShellExecute=$true (not $false) is deliberate: it preserves the same UAC-elevation-via-
# manifest behavior "start "" /wait" already had (ShellExecute is what supports an exe's own
# "requireAdministrator" manifest shim transparently). No stdout/stderr redirection is needed --
# these installers run silently (/S, --quiet) -- so this doesn't cost anything my caller needs.
#
# On timeout, uses taskkill /F /T (not $p.Kill()) deliberately: Windows PowerShell 5.1's
# System.Diagnostics.Process.Kill() (.NET Framework) has no "kill the whole process tree"
# overload -- that's a .NET Core 3.0+ addition this runtime doesn't have -- so it would only
# kill the direct process, potentially orphaning child sub-installer processes (this repo's own
# NI-VISA comment already notes "NI installers may spawn child processes"). taskkill's /T flag
# kills the full process tree regardless of .NET runtime version.
#
# This is the canonical source for the HP_INSTALLER_TIMEOUT base64 payload embedded in
# run_setup.bat. After editing, re-sync with tools/sync_payload.py; tests/test_run_installer_
# with_timeout.py asserts the embedded payload matches this file (CRLF/LF normalized, per the
# .ps1 PayloadSync convention).
#
# derived requirement: a real Windows CI run caught a genuine bug this repo's other emitted
# .ps1 helpers never hit: when a native EXE invoked via the "&" call operator (taskkill.exe
# here -- the ONLY native-command invocation in this file; exe_smokerun.ps1/failfast_probe.ps1
# only ever launch their monitored process via .NET's Process API, which does not set
# $LASTEXITCODE) sets $LASTEXITCODE to a nonzero value, pwsh -File silently inherits that as
# ITS OWN process exit code when the script ends without an explicit "exit" statement -- even
# though taskkill was not the last statement executed and its own failure was already caught
# and swallowed by try/catch. This is a well-known PowerShell gotcha, not specific to taskkill:
# any earlier native-command failure can leak through as the whole script's exit code unless
# explicitly reset. taskkill can legitimately return nonzero here (e.g. the timed-out process
# already exited on its own in the race between WaitForExit(timeoutMs) returning false and
# taskkill actually running) without that being a real problem -- the result FILE (not the
# script's own process exit code) is this script's real contract with its caller, so the fix is
# an explicit "exit 0" as the script's last statement, guaranteeing pwsh's own exit code is
# always clean regardless of what $LASTEXITCODE happened to be left holding.
$exe = $env:HP_INSTALLER_EXE
$argStr = $env:HP_INSTALLER_ARGS
$timeoutMs = [int]$env:HP_INSTALLER_TIMEOUT_MS
$resultPath = $env:HP_INSTALLER_RESULT
if (-not $resultPath) { $resultPath = '~installer_result.txt' }

$si = New-Object System.Diagnostics.ProcessStartInfo
$si.FileName = $exe
if ($argStr) { $si.Arguments = $argStr }
$si.UseShellExecute = $true
$p = New-Object System.Diagnostics.Process
$p.StartInfo = $si
$p.Start() | Out-Null

if ($p.WaitForExit($timeoutMs)) {
    "$($p.ExitCode)|0" | Set-Content -Path $resultPath -Encoding ASCII
} else {
    try { & taskkill.exe /F /T /PID $p.Id 2>$null | Out-Null } catch {}
    "1|1" | Set-Content -Path $resultPath -Encoding ASCII
}
exit 0
