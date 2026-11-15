# ASCII only
# selfapps_repair_cap.ps1 - Item 106, README REQ-018.7: the re-verification run inside the --hidden-import auto-recovery loop
# ends after 30 seconds, whatever output the run produces.
#
# Why a row. The loop (:hidden_import_recover) starts the EXE after every repair rebuild with an inline PowerShell that waits 30
# seconds, stops the process it started and reads what it printed. The README says the run ends after 30 seconds "whatever
# output the run produces", which is different from the main verification run (REQ-018.6), where any output keeps the program
# alive. No row ever ran a program that keeps printing through the loop, so the one inline line that carries the shall had no
# test. A PyInstaller onefile EXE is two processes, the bootloader that was started and the program it starts. The first run of
# this row (run 43532440009) showed what that does to the first version of the line, which called Kill() on the process it
# started and then read both pipes without a limit: Kill() ended the bootloader only, the program kept the pipes open, the
# read waited for it, and the program's own clock ran its whole 100 seconds. The line now ends the process tree with taskkill
# /F /T, keeps Kill() as the fallback and reads each pipe for at most 5 seconds; this row is what holds it to that on Windows.
#
# The scenario. One folder, one program, one default bootstrap with HP_TEST_REPAIR_ANSWER=Y (the loop asks before it starts the
# program again, Item 97, and a non-interactive run declines):
#   requirements.txt = colorama, app.py imports colorama by a runtime string, so PyInstaller does not bundle it
#   start 1  the EXE verification run: ModuleNotFoundError, exit 1
#   start 2  the loop's first run: the same failure, the scan names colorama, the loop rebuilds with --hidden-import=colorama
#   start 3  the run after the rebuild: colorama imports, and the program prints one line a second for 100 seconds
# Every start appends JSON lines to a ledger at an absolute path (CAP_LEDGER): start, imported, a tick per second, done. The cap
# is measured from the program's own clock, not the batch file's: the seconds between its start line and its last tick must be
# near 30 (more than 10 and at most 45), it must never reach done, and when the bootstrap has returned no process may still run
# from the scenario's dist folder (the process list is read through CIM; a leftover is stopped and reported). Preconditions are
# part of the verdict: the repair really rebuilt (the log has the [REPAIR][HIDDEN_IMPORT] line for colorama), the loop's last
# run was reported as a timeout after that line, and one start of the EXE did get past the import. A bootstrap that never
# reached the loop cannot pass.
#
# The judging lives in functions that take plain values and return a list of problems (tests/test_repair_cap.py runs each of
# them through real pwsh on synthetic runs that must be red for every comparison).
#
# derived requirement: the id and the req tag stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py
# and the requirement-trace tests scan text, not PowerShell).
#
# Lane: contract-uv only (a default uv bootstrap with two builds and a 100 second program; the lane with the most wall-clock
# headroom), gating from its first run (AGENTS.md "New tests gate immediately").
# Emits: self.repair.cap
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

function Write-NdjsonRow {
    param([hashtable]$Row)
    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{ id = 'self.repair.cap'; req = 'REQ-018.7'; pass = $true; desc = 'Repair loop run cap (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.repair.cap'; req = 'REQ-018.7'; pass = $false; desc = 'Repair loop run cap: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

# --- pure helpers (no file system, no process): the unit test runs them through real pwsh ---

# The two log facts the verdict rests on: the repair rebuilt with colorama, and the last run of the loop was reported as a timeout
# after that line (the status line is written when the loop ends with exit -1, the code of a run that hit the cap).
function Get-CapLogFacts {
    param([string]$SetupText)
    $repair = [regex]::Match($SetupText, '\[REPAIR\]\[HIDDEN_IMPORT\] Adding --hidden-import=colorama')
    $timeout = [regex]::Match($SetupText, '\[STATUS\] Run Status: TIMED OUT \(hit the ~30s verification cap')
    return [pscustomobject][ordered]@{
        repairLogged        = [bool]$repair.Success
        timedOutAfterRepair = [bool]($repair.Success -and $timeout.Success -and ($timeout.Index -gt $repair.Index))
    }
}

# One summary per start of the program. A start is a process id that wrote lines to the ledger, in the order the starts began.
# Lines that are not ledger lines (a parseError entry, a line without ev, pid and t) are skipped.
function Get-CapStarts {
    param($Ledger)
    $byPid = [ordered]@{}
    foreach ($entry in @($Ledger)) {
        $names = @($entry.PSObject.Properties.Name)
        if (($names -notcontains 'ev') -or ($names -notcontains 'pid') -or ($names -notcontains 't')) { continue }
        $key = [string]$entry.pid
        if (-not $byPid.Contains($key)) {
            $byPid[$key] = [ordered]@{ ProcessId = [int]$entry.pid; Frozen = $false; Imported = $false; Ticks = 0; Done = $false; FirstT = [double]$entry.t; LastT = [double]$entry.t }
        }
        $acc = $byPid[$key]
        $acc['LastT'] = [double]$entry.t
        $kind = [string]$entry.ev
        if ($kind -ceq 'start') {
            if (($names -contains 'frozen') -and ($entry.frozen -eq $true)) { $acc['Frozen'] = $true }
        } elseif ($kind -ceq 'imported') {
            $acc['Imported'] = $true
        } elseif ($kind -ceq 'tick') {
            $acc['Ticks'] = [int]$acc['Ticks'] + 1
        } elseif ($kind -ceq 'done') {
            $acc['Done'] = $true
        }
    }
    $out = New-Object System.Collections.ArrayList
    foreach ($key in @($byPid.Keys)) {
        $acc = $byPid[$key]
        [void]$out.Add([pscustomobject][ordered]@{
            ProcessId = $acc['ProcessId']; Frozen = [bool]$acc['Frozen']; Imported = [bool]$acc['Imported']; Ticks = [int]$acc['Ticks']
            Done = [bool]$acc['Done']; Span = [double]($acc['LastT'] - $acc['FirstT'])
        })
    }
    return $out.ToArray()
}

# REQ-018.7: what is wrong with the one bootstrap; nothing when the loop's run was ended near the cap and left nothing running.
function Get-RepairCapProblems {
    param([bool]$Finished, $Starts, [bool]$RepairLogged, [bool]$TimedOutAfterRepair, [bool]$OrphanCheckRan, $Orphans, [double]$CapSeconds)
    $out = New-Object System.Collections.ArrayList
    if (-not $Finished) { [void]$out.Add('the bootstrap did not finish within the time limit'); return $out.ToArray() }
    $upper = $CapSeconds + 15
    $lower = $CapSeconds - 20
    $runs = @($Starts | Where-Object { ($_.Frozen -eq $true) -and ($_.Imported -eq $true) })
    if (-not $RepairLogged) { [void]$out.Add('the setup log has no [REPAIR][HIDDEN_IMPORT] line for colorama, so the loop never rebuilt the EXE and the run the cap applies to never happened') }
    if ($runs.Count -eq 0) { [void]$out.Add('no start of the EXE got past the import of colorama, so there was no re-verification run that keeps printing') }
    if ($RepairLogged -and (-not $TimedOutAfterRepair)) { [void]$out.Add('the setup log does not report the loop as timed out after the repair, so the loop did not end the run at its cap') }
    foreach ($run in $runs) {
        $secs = ([double]$run.Span).ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($run.Done -eq $true) {
            [void]$out.Add("the program printed all $($run.Ticks) lines and ended by itself ($secs s after its first line), so nothing stopped it after $CapSeconds seconds")
        } elseif ($run.Span -gt $upper) {
            [void]$out.Add("the program was still printing $secs s after its first line, more than $upper s, so the run was not ended after $CapSeconds seconds")
        } elseif ($run.Span -lt $lower) {
            [void]$out.Add("the program stopped printing only $secs s after its first line, less than $lower s, so the cap was not what ended it")
        }
    }
    if (-not $OrphanCheckRan) {
        [void]$out.Add('the list of running processes could not be read, so a process left behind by the force stop was not looked for')
    } elseif (@($Orphans).Count -gt 0) {
        [void]$out.Add("$(@($Orphans).Count) process(es) of the program were still running after the bootstrapper had finished, so the force stop left the program itself alive")
    }
    return $out.ToArray()
}

# A few log lines that explain a red row, printable ASCII only and cut short.
function Get-CapExcerpt {
    param([string]$Text, [int]$Max = 24)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match 'Verifying the built standalone EXE|EXE smokerun|Entry smoke|\[REPAIR\]|\[HINT\]|\[HIDDEN_IMPORT\]|Run Status|\[ERROR\]') {
            $clean = ($l -replace '[^\x20-\x7E]', '?')
            if ($clean.Length -gt 150) { $clean = $clean.Substring(0, 150) }
            [void]$keep.Add($clean)
            if ($keep.Count -ge $Max) { break }
        }
    }
    return $keep.ToArray()
}

# --- the file system and the bootstrapper ---

function Read-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
    if ($null -eq $t) { return '' }
    return [string]$t
}

# One object per ledger line (a line that is not JSON becomes an object with a parseError field). The caller wraps the call in @( ).
function Read-Ledger {
    param([string]$Path)
    $out = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path -Encoding ASCII)) {
            if ($line.Trim().Length -eq 0) { continue }
            try { [void]$out.Add(($line | ConvertFrom-Json)) } catch { [void]$out.Add([pscustomobject]@{ parseError = $line }) }
        }
    }
    return $out.ToArray()
}

# Processes whose image is a file under the folder (the built EXE and the program it started). Ran is false when the process
# list could not be read, so the caller does not take an empty answer for "nothing left".
function Get-ProcessesUnder {
    param([string]$Folder)
    $prefix = $Folder.TrimEnd('\') + '\'
    $found = New-Object System.Collections.ArrayList
    $ran = $true
    try {
        foreach ($proc in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
            $path = [string]$proc.ExecutablePath
            if ($path -and $path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                [void]$found.Add([pscustomobject]@{ ProcessId = [int]$proc.ProcessId; Name = [string]$proc.Name })
            }
        }
    } catch {
        $ran = $false
    }
    return [pscustomobject]@{ Ran = $ran; Found = $found.ToArray() }
}

# The program, a ledger line first so a start that stops at once is still counted. colorama is installed (requirements.txt) but
# imported by a runtime string, so PyInstaller does not bundle it: the first runs fail with ModuleNotFoundError and the loop
# rebuilds with --hidden-import=colorama. After that the program prints a line a second for 100 seconds, far past the cap.
$appCode = @'
import importlib
import json
import os
import sys
import time

LEDGER = os.environ["CAP_LEDGER"]
PID = os.getpid()


def note(event, **more):
    row = {"ev": event, "pid": PID, "t": time.time()}
    row.update(more)
    with open(LEDGER, "a") as f:
        f.write(json.dumps(row) + "\n")


note("start", frozen=bool(getattr(sys, "frozen", False)))
mod = importlib.import_module('colorama')
note("imported", name=mod.__name__)
for i in range(1, 101):
    print("tick", i, flush=True)
    note("tick", n=i)
    time.sleep(1)
note("done")
'@

# A hang must be a red row; two builds and a 100 second program need a few minutes at most.
$runTimeoutMs = 15 * 60 * 1000
$capSeconds = 30

# Bootstraps the program in a fresh folder; never throws. Returns what the verdict reads.
function Invoke-CapRun {
    $res = [ordered]@{ Finished = $false; ExitCode = -1; Seconds = 0; Dir = ''; Setup = ''; Console = ''; Ledger = @(); OrphanCheckRan = $false; Orphans = @(); Error = '' }
    try {
        $dir = Join-Path $here '~selftest_repaircap'
        $res.Dir = $dir
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath $batchPath -Destination $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value $appCode -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $dir 'requirements.txt') -Value 'colorama' -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $dir '~cap_launch.cmd') -Value @('@echo off', 'call run_setup.bat > ~cap_console.log 2>&1 < nul', 'exit /b %ERRORLEVEL%') -Encoding ASCII
        $vars = [ordered]@{
            HP_SKIP_PIPREQS = '1'; HP_SKIP_AUTOPEP_DISCOVERY = '1'; HP_SKIP_NIVISA = '1'
            HP_TEST_REPAIR_ANSWER = 'Y'; CAP_LEDGER = (Join-Path $dir '~cap_ledger.jsonl')
        }
        if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
        $saved = @{}
        foreach ($k in @($vars.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$vars[$k]) }
        $started = Get-Date
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'call ~cap_launch.cmd') -WorkingDirectory $dir -NoNewWindow -PassThru
            $null = $p.Handle   # keeps ExitCode readable after WaitForExit(ms)
            if ($p.WaitForExit($runTimeoutMs)) {
                $res.Finished = $true
                $res.ExitCode = $p.ExitCode
            } else {
                & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
                $null = $p.WaitForExit(30000)
            }
        } finally {
            foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        $res.Seconds = [int]((Get-Date) - $started).TotalSeconds
        # Read what is still running BEFORE anything else happens: a program the force stop left alive goes on printing and is
        # not a reading of this moment otherwise. A leftover is stopped afterwards so it cannot disturb the next step.
        $left = Get-ProcessesUnder -Folder (Join-Path $dir 'dist')
        $res.OrphanCheckRan = [bool]$left.Ran
        $res.Orphans = @($left.Found)
        $res.Console = Read-Text (Join-Path $dir '~cap_console.log')
        $res.Setup = Read-Text (Join-Path $dir '~setup.log')
        $res.Ledger = @(Read-Ledger (Join-Path $dir '~cap_ledger.jsonl'))
        foreach ($o in @($left.Found)) { try { Stop-Process -Id $o.ProcessId -Force -ErrorAction Stop } catch { } }
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

$run = Invoke-CapRun
$facts = Get-CapLogFacts $run.Setup
$starts = @(Get-CapStarts $run.Ledger)

Write-Host '=== repair loop run cap ==='
Write-Host ("finished={0} exit={1} seconds={2} ledgerLines={3} orphansAfter={4} orphanCheckRan={5}" -f $run.Finished, $run.ExitCode, $run.Seconds, @($run.Ledger).Count, @($run.Orphans).Count, $run.OrphanCheckRan)
foreach ($s in $starts) { Write-Host ("start: pid={0} frozen={1} imported={2} ticks={3} done={4} spanSeconds={5}" -f $s.ProcessId, $s.Frozen, $s.Imported, $s.Ticks, $s.Done, [math]::Round($s.Span, 1)) }
foreach ($l in @(Get-CapExcerpt $run.Setup)) { Write-Host ('setup: ' + $l) }
if ($run.Error) { Write-Host ('error: ' + $run.Error) }

$problems = @(Get-RepairCapProblems -Finished ([bool]$run.Finished) -Starts $starts -RepairLogged ([bool]$facts.repairLogged) -TimedOutAfterRepair ([bool]$facts.timedOutAfterRepair) -OrphanCheckRan ([bool]$run.OrphanCheckRan) -Orphans @($run.Orphans) -CapSeconds $capSeconds)
$pass = ($problems.Count -eq 0)
$details = [ordered]@{
    finished = [bool]$run.Finished; seconds = $run.Seconds; exitCode = $run.ExitCode; capSeconds = $capSeconds
    repairLogged = [bool]$facts.repairLogged; timedOutAfterRepair = [bool]$facts.timedOutAfterRepair
    starts = @($starts | ForEach-Object { [ordered]@{ pid = $_.ProcessId; frozen = $_.Frozen; imported = $_.Imported; ticks = $_.Ticks; done = $_.Done; spanSeconds = [math]::Round($_.Span, 1) } })
    orphanCheckRan = [bool]$run.OrphanCheckRan; orphansAfterBootstrap = @($run.Orphans).Count
}
if ($run.Error) { $details['error'] = $run.Error }
if (-not $pass) { $details['problems'] = @($problems); $details['excerpt'] = @(Get-CapExcerpt $run.Setup) }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.cap'; req = 'REQ-018.7'; pass = [bool]$pass
    desc = 'REQ-018.7: the re-verification run inside the --hidden-import repair loop is ended after 30 seconds although the program keeps printing, and no process of the program is left running'
    details = $details
})

if (-not $pass) { exit 1 }
exit 0
