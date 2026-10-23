# ASCII only
# selfapps_noflag_default.ps1 - the no-flag default run (docs/plan-test-suite-gaps.md gap T12, REQ-019).
#
# Every other scenario in the suite sets HP_CI_LANE (the runner does) and usually more flags, so the
# branches a double-click user really takes are never executed in CI: the elective prompts reach `set /p`
# instead of auto-declining, the end of the run reaches `pause`, and a repeat run takes the interactive
# fast-path probe instead of the plain launch. This script bootstraps a stub program with EVERY HP_*, PVW_*
# and NOINPUT variable removed from the environment and with standard input closed (the console is
# not available to a CI step; a closed stdin is the closest stand-in for "nobody answers"), then a second
# time in the same folder.
#
# Scenario F  fresh folder, no flags, stdin closed, hard time limit
#   - must finish by itself within the time limit (a hang in a loop or a wait on something other than the
#     console would hit it; with stdin closed, `set /p` and `pause` get end-of-file and return at once, so the
#     limit does not prove that no prompt waits, the evidence below does)
#   - must exit 0 with state ok
#   - the two elective prompts and the end-of-run pause must really have been reached (proof the flag-free
#     branches ran, not a CI shortcut) and, unanswered, the prompts must decline: the program runs exactly
#     once (REQ-018)
# Scenario G  the same folder again
#   - the repeat run reuses the EXE through the interactive probe branch (not the plain fast-path line)
#     and runs the program exactly once more
#
# The stub appends one JSON line per launch to ~noflag_ledger.jsonl (same idea as selfapps_launch_ledger.ps1).
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py
# scans text, not PowerShell).
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"). The run is a full default
# bootstrap including the dependency scan, so it takes a few minutes.
# Emits: self.noflag.default.run, self.noflag.default.once, self.noflag.default.rerun
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

# The lane tag is read once, before the flags are scrubbed below, so every row keeps its lane.
$laneTag = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
function Write-NdjsonRow {
    param([hashtable]$Row)
    if ($laneTag -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $laneTag }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

$allIds = @('self.noflag.default.run', 'self.noflag.default.once', 'self.noflag.default.rerun')
$reqOf = @{ 'self.noflag.default.run' = 'REQ-019.1'; 'self.noflag.default.once' = 'REQ-018'; 'self.noflag.default.rerun' = 'REQ-019.3' }
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = $reqOf[$rowId]; pass = $true; desc = 'No-flag default run (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = $reqOf[$rowId]; pass = $false; desc = 'No-flag default run: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    exit 1
}

$dir = Join-Path $here '~selftest_noflag'
$evidence = Join-Path $here '~selftest_noflag_evidence'
foreach ($p in @($dir, $evidence)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
Copy-Item -LiteralPath $batchPath -Destination $dir -Force

$stub = @'
import json
import sys

rec = {"frozen": bool(getattr(sys, "frozen", False)), "argv": sys.argv[1:]}
with open("~noflag_ledger.jsonl", "a") as f:
    f.write(json.dumps(rec) + "\n")
print("noflag-ok")
'@
Set-Content -LiteralPath (Join-Path $dir 'noflag_app.py') -Value $stub -Encoding ASCII

$expectedExit = 0
$expectedLaunchesFresh = 1
$expectedLaunchesAfterRerun = 2

$timeLimitSec = 1800

function Invoke-NoFlagBootstrap {
    param([string]$LogName)
    $wrapper = Join-Path $dir '~noflag_launch.cmd'
    # The wrapper lists the flag-shaped variables of the environment it was started with (`.env0.txt`, diagnostic),
    # clears every flag the job had set with `set "NAME="` (the batch environment is exactly what the bootstrapper
    # inherits, and this is the one removal that is certain to work), then lists again (`.env.txt`); the second list is
    # the verdict: a flag in it reached the run. Only the three flag prefixes are listed, never the whole environment
    # (it can hold tokens). No space before a redirection: a space would become part of the prefix that `set` looks for.
    $envName = $LogName -replace '\.log$', '.env.txt'
    $env0Name = $LogName -replace '\.log$', '.env0.txt'
    $listLines = @("set HP_> $env0Name 2>nul", "set PVW_>> $env0Name 2>nul", "set NOINPUT>> $env0Name 2>nul")
    $clearLines = @($scrubbed.Keys | Where-Object { $_ -match '^[A-Za-z0-9_]+$' } | Sort-Object | ForEach-Object { 'set "' + $_ + '="' })
    $listAfter = @("set HP_> $envName 2>nul", "set PVW_>> $envName 2>nul", "set NOINPUT>> $envName 2>nul")
    Set-Content -LiteralPath $wrapper -Value (@('@echo off') + $listLines + $clearLines + $listAfter + @("call run_setup.bat noflag_app.py > $LogName 2>&1 < nul", 'exit /b %ERRORLEVEL%')) -Encoding ASCII
    $started = Get-Date
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', 'call ~noflag_launch.cmd') -WorkingDirectory $dir -NoNewWindow -PassThru
    $finished = $proc.WaitForExit($timeLimitSec * 1000)
    $code = -1
    if ($finished) {
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } else {
        & taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null
        $null = $proc.WaitForExit(30000)
    }
    $seen = @()
    $seen0 = @()
    $envPath = Join-Path $dir $envName
    $env0Path = Join-Path $dir $env0Name
    if (Test-Path -LiteralPath $envPath) {
        $seen = @(Get-Content -LiteralPath $envPath -Encoding ASCII | ForEach-Object { ($_ -split '=', 2)[0] } |
            Where-Object { $_ -match '^(HP_|PVW_)' -or $_ -ieq 'NOINPUT' })
    }
    if (Test-Path -LiteralPath $env0Path) {
        $seen0 = @(Get-Content -LiteralPath $env0Path -Encoding ASCII | ForEach-Object { ($_ -split '=', 2)[0] } |
            Where-Object { $_ -match '^(HP_|PVW_)' -or $_ -ieq 'NOINPUT' })
    }
    return [pscustomobject]@{ Finished = [bool]$finished; ExitCode = $code; Seconds = [int]((Get-Date) - $started).TotalSeconds; EnvDumped = ((Test-Path -LiteralPath $envPath) -and (Test-Path -LiteralPath $env0Path)); FlagsSeen = $seen; FlagsAtLaunch = $seen0 }
}

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
}

function Read-Ledger {
    $path = Join-Path $dir '~noflag_ledger.jsonl'
    $out = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $path) {
        foreach ($line in (Get-Content -LiteralPath $path -Encoding ASCII)) {
            if ($line.Trim().Length -eq 0) { continue }
            try { [void]$out.Add(($line | ConvertFrom-Json)) } catch { [void]$out.Add([pscustomobject]@{ parseError = $line }) }
        }
    }
    return ,$out.ToArray()
}

function Save-Evidence {
    param([string[]]$Names)
    foreach ($f in $Names) {
        $src = Join-Path $dir $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $evidence $f) -Force }
    }
}

# --- scrub every flag; remember and restore them afterwards ---
$scrubbed = @{}
foreach ($item in @(Get-ChildItem Env:)) {
    if ($item.Name -match '^(HP_|PVW_)' -or $item.Name -ieq 'NOINPUT') { $scrubbed[$item.Name] = $item.Value }
}
# Two runs of this test (23711765, 28146271) showed that [Environment]::SetEnvironmentVariable($name, $null) leaves the
# job's own variables (HP_ALLOW_SYSTEM_FALLBACK, HP_ALLOW_VENV_FALLBACK, HP_CI_LANE, HP_CI_TEST_CONDA_DL) listed, both
# here and in the launched shell. So the parent is cleared with the Env: drive, and the wrapper clears them again in the
# launched shell; what decides the verdict is the list the launched shell prints after its own clear (FlagsSeen), while
# the list before it (FlagsAtLaunch) and the parent's leftovers stay in the details to show which removal failed.
foreach ($name in @($scrubbed.Keys)) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
$parentStillSet = @($scrubbed.Keys | Where-Object { $null -ne [Environment]::GetEnvironmentVariable($_) } | Sort-Object)

try {
    # ------------------------------------------------------------ Scenario F: fresh, no flags
    $runF = Invoke-NoFlagBootstrap -LogName '~noflag_f.log'
    $linesF = Read-Ledger
    $logF = Read-Text (Join-Path $dir '~noflag_f.log')
    $setupF = Read-Text (Join-Path $dir '~setup.log')
    $statusF = ''
    $statusPath = Join-Path $dir '~bootstrap.status.json'
    if (Test-Path -LiteralPath $statusPath) {
        try { $statusF = [string]((Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { $statusF = 'unparseable' }
    }
    Save-Evidence @('~noflag_f.log', '~setup.log', '~noflag_ledger.jsonl', '~bootstrap.status.json')
    Write-Host '=== no-flag evidence: F fresh run ==='
    foreach ($l in (($logF -split "`r?`n") | Where-Object { $_ -match 'Y/N|Entry smoke|checkpoint|Optimized build|\[ERROR\]|Press any key|\[STATUS\]' } | Select-Object -First 30)) { Write-Host $l }
    foreach ($l in (Read-Text (Join-Path $dir '~noflag_ledger.jsonl')) -split "`r?`n") { if ($l) { Write-Host ('ledger: ' + $l) } }

    $checkpointPromptShown = $logF -match 'Run again via the interpreter now\? \[Y/N\]'
    $optbuildPromptShown = $logF -match 'Build the optimized version now\? \[Y/N\]'
    $pauseShown = $logF -match 'Press any key to continue'
    $checkpointDeclined = ($logF + $setupF) -match 'post-execution checkpoint \((exe|interpreter)\): declined'
    $optbuildDeclined = ($logF + $setupF) -match 'Optimized build: declined'

    $runPass = $runF.EnvDumped -and ($runF.FlagsSeen.Count -eq 0) -and $runF.Finished -and ($runF.ExitCode -eq $expectedExit) -and ($statusF -eq 'ok') -and $checkpointPromptShown -and $optbuildPromptShown -and $pauseShown
    Write-NdjsonRow ([ordered]@{
        id = 'self.noflag.default.run'; req = 'REQ-019.1'; pass = [bool]$runPass
        desc = 'REQ-019: a run with no HP_*, PVW_* or NOINPUT variable and no console input finishes by itself with state ok, through the flag-free prompt branches'
        details = [ordered]@{
            flagsSeenByRun = @($runF.FlagsSeen); flagsAtLaunch = @($runF.FlagsAtLaunch); envDumped = [bool]$runF.EnvDumped; flagsScrubbed = $scrubbed.Count; scrubbedNames = @($scrubbed.Keys | Sort-Object); parentStillSet = @($parentStillSet)
            finished = $runF.Finished; seconds = $runF.Seconds; timeLimitSec = $timeLimitSec
            exitCode = $runF.ExitCode; expectedExit = $expectedExit; statusState = $statusF
            checkpointPromptShown = [bool]$checkpointPromptShown; optbuildPromptShown = [bool]$optbuildPromptShown; pauseShown = [bool]$pauseShown
        }
    })
    $oncePass = $runF.Finished -and ($linesF.Count -eq $expectedLaunchesFresh) -and $checkpointDeclined -and $optbuildDeclined -and ($linesF.Count -ge 1) -and ($linesF[0].frozen -eq $true)
    Write-NdjsonRow ([ordered]@{
        id = 'self.noflag.default.once'; req = 'REQ-018'; pass = [bool]$oncePass
        desc = 'REQ-018: unanswered elective prompts decline, so the fresh run starts the program exactly once'
        details = [ordered]@{
            ledgerLines = $linesF.Count; expectedLaunches = $expectedLaunchesFresh
            firstFrozen = if ($linesF.Count -ge 1) { $linesF[0].frozen } else { $null }
            checkpointDeclined = [bool]$checkpointDeclined; optbuildDeclined = [bool]$optbuildDeclined
        }
    })

    # ------------------------------------------------------------ Scenario G: repeat run, no flags
    $runG = Invoke-NoFlagBootstrap -LogName '~noflag_g.log'
    $linesG = Read-Ledger
    $logG = Read-Text (Join-Path $dir '~noflag_g.log')
    Save-Evidence @('~noflag_g.log', '~noflag_ledger.jsonl')
    Write-Host '=== no-flag evidence: G repeat run ==='
    foreach ($l in (($logG -split "`r?`n") | Where-Object { $_ -match 'Launching your program|Fast path|Entry smoke|\[ERROR\]|Press any key|\[STATUS\]' } | Select-Object -First 20)) { Write-Host $l }

    $probeBranch = $logG -match 'Launching your program now via the cached standalone EXE'
    $plainFastLine = $logG -match 'Fast path: reusing'
    $g1 = if ($linesG.Count -ge 2) { $linesG[1] } else { $null }
    $rerunPass = $runG.EnvDumped -and ($runG.FlagsSeen.Count -eq 0) -and $runG.Finished -and ($runG.ExitCode -eq 0) -and ($linesG.Count -eq $expectedLaunchesAfterRerun) -and $probeBranch -and (-not $plainFastLine) -and ($null -ne $g1) -and ($g1.frozen -eq $true)
    Write-NdjsonRow ([ordered]@{
        id = 'self.noflag.default.rerun'; req = 'REQ-019.3'; pass = [bool]$rerunPass
        desc = 'REQ-019: a repeat run with no flags reuses the EXE through the interactive probe and starts the program once more'
        details = [ordered]@{
            finished = $runG.Finished; seconds = $runG.Seconds; exitCode = $runG.ExitCode
            flagsSeenByRun = @($runG.FlagsSeen); flagsAtLaunch = @($runG.FlagsAtLaunch); envDumped = [bool]$runG.EnvDumped
            ledgerLines = $linesG.Count; expectedLedgerLines = $expectedLaunchesAfterRerun
            interactiveProbeBranch = [bool]$probeBranch; plainFastPathLine = [bool]$plainFastLine
            secondFrozen = if ($g1) { $g1.frozen } else { $null }
        }
    })
} finally {
    foreach ($name in @($scrubbed.Keys)) { [Environment]::SetEnvironmentVariable($name, $scrubbed[$name]) }
}

if (-not ($runPass -and $oncePass -and $rerunPass)) { exit 1 }
exit 0
