# ASCII only
# selfapps_launch_cap.ps1 - Item 124, README REQ-018.6: the verification run of a new build is force-stopped only if it has produced
# no output 30 seconds after it started, and any output, a prompt that waits for input included, keeps it going for as long as it
# needs.
#
# Why two rows. tests/test_exe_smokerun.py proves both halves of the shall on the helper alone (tools/exe_smokerun.ps1), with the wait
# cut to a fraction of a second through a test-only override. No row ran the real thing: the wait production uses (30000 ms, the batch
# file never sets the override), an EXE that the bootstrapper built, and the console the user reads. This script does, in two default
# bootstraps of one-file programs, each in its own folder:
#   silent  a program that prints nothing for 75 seconds. The EXE the runner started must be stopped about 30 seconds after it started,
#           and the console must report the run as exit -1 and TIMED OUT.
#   output  a program that prints a prompt with input() and waits for the answer. The prompt must be on the console, the program is
#           answered 46 seconds after it started (a pipe that this script holds open and writes to once), and the run must end by
#           itself with exit 0 and SUCCESS, with the EXE the runner started alive past the 30 second mark.
#
# What is measured, and why not the length of the whole bootstrap. A PyInstaller onefile EXE is two processes, the bootloader that the
# runner starts and the program the bootloader starts. The runner's Kill() ends the bootloader only, and the runner then reads the
# program's pipes until the program ends (docs/agent-interconnect.md, "The cap on each of the loop's runs", and Active Backlog Item 110
# in CLAUDE.md), so the bootstrapper may keep running well after the stop and its own length says nothing about when the stop
# happened. The runner prints the id of the process it started on the console ("[INFO] Process ID <n>."); this script opens that
# process by id as soon as the line appears and takes its life from the process's own start and end time (the polled time between the
# line and the moment it was seen to have ended is the fallback, and the row says which one it used). That time is the stop. The row
# does NOT say whether the program below the bootloader ends: no shall names it, a later fix of Item 110 that ends the whole tree
# keeps both rows true, and the program's own ledger line after its sleep is only recorded in the details (programSurvivedStop).
#
# The answer. The output scenario needs a standard input that stays silent until well after the cap and then holds one line, which a
# file redirect cannot give (a file at its end answers at once). The bootstrapper is started with System.Diagnostics.Process and a
# redirected standard input that this script keeps; nothing in the chain redirects it away (tests/selfapps_interactive_stdin.ps1
# proves the same chain with a file), the offers that would read it are declined in a lane run (HP_CI_LANE), and the line is written
# 46 seconds after the program's own first ledger line, so the program has waited past the cap by its own clock. The silent scenario
# closes the input at once, like every other script that starts a bootstrap with < nul.
#
# The judging lives in functions that take plain values and return a list of problems (tests/test_launch_cap.py runs each of them
# through real pwsh on synthetic runs that must be red for every comparison, and runs the two programs on a POSIX host).
#
# derived requirement: the id and the req tag stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell).
#
# Lane: contract-uv only (two default uv bootstraps and a few minutes of waiting; the lane with the most wall-clock headroom),
# gating from its first run (AGENTS.md "New tests gate immediately").
# Emits: self.launch.cap.silent, self.launch.cap.output
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
    Write-NdjsonRow ([ordered]@{ id = 'self.launch.cap.silent'; req = 'REQ-018.6'; pass = $true; desc = 'Verification run cap, silent program (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.launch.cap.output'; req = 'REQ-018.6'; pass = $true; desc = 'Verification run cap, program with a prompt (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.launch.cap.silent'; req = 'REQ-018.6'; pass = $false; desc = 'Verification run cap, silent program: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.launch.cap.output'; req = 'REQ-018.6'; pass = $false; desc = 'Verification run cap, program with a prompt: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

# --- pure helpers (no file system, no process): the unit test runs them through real pwsh ---

# The id of the process the smoke runner started, from the line it prints right after Start(). 0 when the console has no such line.
function Get-LaunchCapProcessId {
    param([string]$ConsoleText)
    $m = [regex]::Match($ConsoleText, '\[INFO\] Process ID (\d+)\.')
    if (-not $m.Success) { return 0 }
    # derived requirement: a number too large for an int is not a process id. TryParse leaves 0 in $id then, and 0 reads as "no id";
    # a cast would throw instead and end the script on a console line it could not use.
    $id = 0
    [void][int]::TryParse($m.Groups[1].Value, [ref]$id)
    return $id
}

# What the console says about the verification run: the code of the last "Entry smoke exit=" line (empty when there is none), and
# whether the TIMED OUT and the SUCCESS status lines are there, and the program's own prompt and reply as the runner teed them.
function Get-LaunchCapLogFacts {
    param([string]$ConsoleText, [string]$Prompt, [string]$Reply)
    $exits = [regex]::Matches($ConsoleText, '\[INFO\] Entry smoke exit=(-?\d+)')
    $exitText = ''
    if ($exits.Count -gt 0) { $exitText = $exits[$exits.Count - 1].Groups[1].Value }
    $promptSeen = $false
    if ($Prompt.Length -gt 0) { $promptSeen = $ConsoleText.Contains($Prompt) }
    $replySeen = $false
    if ($Reply.Length -gt 0) { $replySeen = $ConsoleText.Contains($Reply) }
    return [pscustomobject][ordered]@{
        ExitText     = [string]$exitText
        TimedOutLine = [bool]([regex]::IsMatch($ConsoleText, '\[STATUS\] Run Status: TIMED OUT \(hit the ~30s verification cap'))
        SuccessLine  = [bool]([regex]::IsMatch($ConsoleText, '\[STATUS\] Run Status: SUCCESS \(Exit Code: 0\)'))
        PromptSeen   = [bool]$promptSeen
        ReplySeen    = [bool]$replySeen
    }
}

# What the program wrote to its ledger (one JSON object per line, see Read-Ledger): the first start by the built EXE (frozen true),
# when it was answered, and when it woke after its sleep, all on the program's own clock (seconds since 1970, -1 when absent).
function Get-LaunchCapLedgerFacts {
    param($Ledger)
    $started = $false
    $startT = -1.0
    $answeredT = -1.0
    $wokeT = -1.0
    foreach ($entry in @($Ledger)) {
        $names = @($entry.PSObject.Properties.Name)
        if (($names -notcontains 'ev') -or ($names -notcontains 't')) { continue }
        $kind = [string]$entry.ev
        if ($kind -ceq 'start') {
            if ((-not $started) -and ($names -contains 'frozen') -and ($entry.frozen -eq $true)) {
                $started = $true
                $startT = [double]$entry.t
            }
        } elseif ($kind -ceq 'answered') {
            if ($answeredT -lt 0) { $answeredT = [double]$entry.t }
        } elseif ($kind -ceq 'woke') {
            if ($wokeT -lt 0) { $wokeT = [double]$entry.t }
        }
    }
    return [pscustomobject][ordered]@{ Started = [bool]$started; StartT = [double]$startT; AnsweredT = [double]$answeredT; WokeT = [double]$wokeT }
}

# REQ-018.6, first half: what is wrong with the bootstrap of the program that prints nothing; nothing when the EXE the runner started
# was stopped near the cap and the console reports a force-stopped run. LifetimeSeconds is negative when it could not be measured.
function Get-SilentCapProblems {
    param([bool]$Finished, [bool]$Started, [int]$ProcId, [double]$LifetimeSeconds, [string]$ExitText, [bool]$TimedOutLine, [double]$CapSeconds)
    $out = New-Object System.Collections.ArrayList
    if (-not $Finished) { [void]$out.Add('the bootstrap did not finish within the time limit'); return $out.ToArray() }
    $lower = $CapSeconds - 2
    $upper = $CapSeconds + 15
    if (-not $Started) { [void]$out.Add('the program wrote no start line from the built EXE, so no verification run of the EXE happened') }
    if ($ProcId -le 0) {
        [void]$out.Add('the console has no Process ID line of the runner, so the life of the EXE the runner started could not be measured')
    } elseif ($LifetimeSeconds -lt 0) {
        [void]$out.Add('the process the runner started could not be watched, its start and end time could not be read')
    } else {
        $secs = $LifetimeSeconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
        if ($LifetimeSeconds -lt $lower) {
            [void]$out.Add("the EXE the runner started ended $secs s after it started, before the $CapSeconds second mark, so the silent program was stopped too early or ended by itself")
        } elseif ($LifetimeSeconds -gt $upper) {
            [void]$out.Add("the EXE the runner started was still running $secs s after it started, more than $upper s, so the silent program was not force-stopped at $CapSeconds seconds")
        }
    }
    if ($ExitText -eq '') {
        [void]$out.Add('the console has no Entry smoke exit line, so the verification run reported no outcome')
    } elseif ($ExitText -ne '-1') {
        [void]$out.Add("the console says the verification run exited with $ExitText and not -1, the code of a force-stopped run")
    }
    if (-not $TimedOutLine) { [void]$out.Add('the console has no TIMED OUT status line for the verification run') }
    return $out.ToArray()
}

# REQ-018.6, second half: what is wrong with the bootstrap of the program that prints a prompt and waits; nothing when the prompt was
# on the console in time, the program waited past the cap for its answer, the EXE the runner started stayed alive until then and the
# console reports a run that ended by itself with exit 0. AnswerDelaySeconds and PromptSeenSeconds are negative when absent.
function Get-OutputCapProblems {
    param([bool]$Finished, [bool]$Started, [bool]$AnswerSent, [bool]$Answered, [double]$AnswerDelaySeconds, [double]$PromptSeenSeconds, [bool]$ReplySeen, [int]$ProcId, [double]$LifetimeSeconds, [string]$ExitText, [bool]$TimedOutLine, [bool]$SuccessLine, [double]$CapSeconds, [double]$MinWaitSeconds)
    $out = New-Object System.Collections.ArrayList
    if (-not $Finished) {
        if ($AnswerSent -and (-not $Answered)) {
            [void]$out.Add('the bootstrap did not finish within the time limit, and the answer that was written to its standard input never reached the program')
        } else {
            [void]$out.Add('the bootstrap did not finish within the time limit')
        }
        return $out.ToArray()
    }
    if (-not $Started) { [void]$out.Add('the program wrote no start line from the built EXE, so no verification run of the EXE happened') }
    if (-not $Answered) {
        [void]$out.Add('the program was never answered, so it did not get past its prompt')
    } elseif ($AnswerDelaySeconds -lt $MinWaitSeconds) {
        $waited = $AnswerDelaySeconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
        [void]$out.Add("the program was answered only $waited s after it started, less than the $MinWaitSeconds s it has to wait to be past the cap, so the row proved nothing about the cap")
    }
    if ($PromptSeenSeconds -lt 0) {
        [void]$out.Add('the console never showed the prompt the program printed')
    } elseif ($PromptSeenSeconds -gt $CapSeconds) {
        $seen = $PromptSeenSeconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
        [void]$out.Add("the console showed the prompt only $seen s after the program started, after the $CapSeconds second mark")
    }
    if (-not $ReplySeen) { [void]$out.Add('the console never showed the program reply to its answer') }
    if ($ProcId -le 0) {
        [void]$out.Add('the console has no Process ID line of the runner, so the life of the EXE the runner started could not be measured')
    } elseif ($LifetimeSeconds -lt 0) {
        [void]$out.Add('the process the runner started could not be watched, its start and end time could not be read')
    } elseif ($LifetimeSeconds -lt $MinWaitSeconds) {
        $secs = $LifetimeSeconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture)
        [void]$out.Add("the EXE the runner started ended $secs s after it started, before the program had been answered ($MinWaitSeconds s), so the runner stopped a run that had printed a prompt")
    }
    if ($ExitText -eq '') {
        [void]$out.Add('the console has no Entry smoke exit line, so the verification run reported no outcome')
    } elseif ($ExitText -ne '0') {
        [void]$out.Add("the console says the verification run exited with $ExitText and not 0")
    }
    if ($TimedOutLine) { [void]$out.Add('the console says the run TIMED OUT although the program had printed a prompt') }
    if (-not $SuccessLine) { [void]$out.Add('the console has no SUCCESS status line for the verification run') }
    return $out.ToArray()
}

# A few console lines that explain a red row, printable ASCII only and cut short.
function Get-LaunchCapExcerpt {
    param([string]$Text, [int]$Max = 24)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match 'Verifying the built standalone EXE|EXE smokerun|Entry smoke|Process ID|Run Status|\[WARN\]|\[ERROR\]|launch cap') {
            $clean = ($l -replace '[^\x20-\x7E]', '?')
            if ($clean.Length -gt 150) { $clean = $clean.Substring(0, 150) }
            [void]$keep.Add($clean)
            if ($keep.Count -ge $Max) { break }
        }
    }
    return $keep.ToArray()
}

# --- the file system, the processes and the bootstrapper ---

# A file another process may be writing: opened for reading with every kind of sharing, '' when it cannot be read just now.
function Read-TextShared {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::ASCII)
            return [string]$sr.ReadToEnd()
        } finally {
            $fs.Dispose()
        }
    } catch {
        return ''
    }
}

# One object per ledger line (a line that is not JSON becomes an object with a parseError field). The caller wraps the call in @( ).
function Read-Ledger {
    param([string]$Path)
    $out = New-Object System.Collections.ArrayList
    foreach ($line in ((Read-TextShared $Path) -split "`r?`n")) {
        if ($line.Trim().Length -eq 0) { continue }
        try { [void]$out.Add(($line | ConvertFrom-Json)) } catch { [void]$out.Add([pscustomobject]@{ parseError = $line }) }
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

# The two programs. Each writes a ledger line first, from the program's own clock, so a start is counted even when nothing else
# happens; LC_LEDGER is an absolute path in the environment of the bootstrap. Nothing is imported that is not in the standard library.
$silentCode = @'
import json
import os
import sys
import time

LEDGER = os.environ["LC_LEDGER"]


def note(event, **more):
    row = {"ev": event, "t": time.time()}
    row.update(more)
    with open(LEDGER, "a") as f:
        f.write(json.dumps(row) + "\n")


note("start", frozen=bool(getattr(sys, "frozen", False)))
time.sleep(75)
note("woke")
'@

$outputCode = @'
import json
import os
import sys
import time

LEDGER = os.environ["LC_LEDGER"]


def note(event, **more):
    row = {"ev": event, "t": time.time()}
    row.update(more)
    with open(LEDGER, "a") as f:
        f.write(json.dumps(row) + "\n")


note("start", frozen=bool(getattr(sys, "frozen", False)))
name = input("Launch cap name? ")
note("answered", name=name)
print("Launch cap reply: " + name, flush=True)
note("done")
'@
$promptText = 'Launch cap name? '
$replyText = 'Launch cap reply: Sample'
$answerText = 'Sample'

# A hang must be a red row; one default build and the wait need a few minutes at most.
$runTimeoutMs = 15 * 60 * 1000
$capSeconds = 30
$answerAfterSeconds = 46
$minWaitSeconds = 44

# Bootstraps one program in a fresh folder, watches the process the runner starts and, when $Answer is given, writes it to the
# bootstrap's standard input $answerAfterSeconds after the program's first ledger line. Never throws. Returns what the verdict reads.
function Invoke-LaunchCapRun {
    param([string]$Name, [string]$AppCode, [string]$Answer)
    $res = [ordered]@{
        Finished = $false; ExitCode = -1; Seconds = 0; Dir = ''; Console = ''; Setup = ''; Ledger = @(); ProcId = 0
        LifetimeSeconds = -1.0; LifetimeSource = ''; PromptSeenSeconds = -1.0; AnswerSent = $false; LeftoverStopped = 0
        LeftoverCheckRan = $false; Error = ''
    }
    try {
        $dir = Join-Path $here ('~selftest_launchcap_' + $Name)
        $res.Dir = $dir
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath $batchPath -Destination $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value $AppCode -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $dir '~lc_launch.cmd') -Value @('@echo off', 'call run_setup.bat > ~lc_console.log 2>&1', 'exit /b %ERRORLEVEL%') -Encoding ASCII
        $consolePath = Join-Path $dir '~lc_console.log'
        $ledgerPath = Join-Path $dir '~lc_ledger.jsonl'
        $vars = [ordered]@{
            HP_SKIP_PIPREQS = '1'; HP_SKIP_AUTOPEP_DISCOVERY = '1'; HP_SKIP_NIVISA = '1'; LC_LEDGER = $ledgerPath
        }
        if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
        $saved = @{}
        foreach ($k in @($vars.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$vars[$k]) }
        # The test-only wait override must not be there: the row is about the wait production uses.
        $killMsBefore = [Environment]::GetEnvironmentVariable('HP_SMOKERUN_KILL_MS')
        if ($null -ne $killMsBefore) { Remove-Item -LiteralPath 'Env:HP_SMOKERUN_KILL_MS' -ErrorAction SilentlyContinue }
        $needInput = -not [string]::IsNullOrEmpty($Answer)
        $started = Get-Date
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $proc = $null
        $handle = $null
        $pidMs = -1
        $startMs = -1
        $promptMs = -1
        $exitMs = -1
        $answerWritten = $false
        $timedOut = $false
        try {
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = 'cmd.exe'
            $psi.Arguments = '/c call ~lc_launch.cmd'
            $psi.WorkingDirectory = $dir
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardInput = $true
            try { $psi.StandardInputEncoding = [System.Text.Encoding]::ASCII } catch { }
            $proc = [System.Diagnostics.Process]::Start($psi)
            $null = $proc.Handle   # keeps ExitCode readable after WaitForExit(ms)
            if (-not $needInput) { $proc.StandardInput.Close() }
            while ($true) {
                if ($proc.WaitForExit(200)) { $res.Finished = $true; $res.ExitCode = $proc.ExitCode; break }
                $nowMs = $sw.ElapsedMilliseconds
                if ($nowMs -gt $runTimeoutMs) { $timedOut = $true; break }
                if (($null -eq $handle) -and ($res.ProcId -eq 0)) {
                    $id = Get-LaunchCapProcessId (Read-TextShared $consolePath)
                    if ($id -gt 0) {
                        $res.ProcId = $id
                        $pidMs = $nowMs
                        try {
                            $handle = [System.Diagnostics.Process]::GetProcessById($id)
                            $null = $handle.StartTime
                        } catch {
                            $res.Error = 'the process of the Process ID line could not be opened: ' + $_.Exception.Message
                        }
                    }
                }
                if (($null -ne $handle) -and ($exitMs -lt 0)) {
                    if ($handle.HasExited) { $exitMs = $nowMs }
                }
                if ($startMs -lt 0) {
                    $f = Get-LaunchCapLedgerFacts -Ledger @(Read-Ledger $ledgerPath)
                    if ($f.Started) { $startMs = $nowMs }
                }
                if ($needInput -and ($promptMs -lt 0)) {
                    if ((Read-TextShared $consolePath).Contains($promptText)) { $promptMs = $nowMs }
                }
                if ($needInput -and (-not $answerWritten) -and ($startMs -ge 0) -and ($nowMs -ge ($startMs + ($answerAfterSeconds * 1000)))) {
                    $answerWritten = $true
                    try {
                        $proc.StandardInput.WriteLine($Answer)
                        $proc.StandardInput.Flush()
                        $proc.StandardInput.Close()
                        $res.AnswerSent = $true
                    } catch {
                        $res.Error = 'the answer could not be written to the standard input of the bootstrap: ' + $_.Exception.Message
                    }
                }
            }
            if ($timedOut) {
                & taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null
                $null = $proc.WaitForExit(30000)
            }
        } finally {
            foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            if ($null -ne $killMsBefore) { [Environment]::SetEnvironmentVariable('HP_SMOKERUN_KILL_MS', $killMsBefore) }
        }
        $res.Seconds = [int]((Get-Date) - $started).TotalSeconds
        if ($null -ne $handle) {
            if (($exitMs -lt 0) -and $handle.HasExited) { $exitMs = $sw.ElapsedMilliseconds }
            $life = -1.0
            try {
                if ($handle.HasExited) {
                    $life = ($handle.ExitTime - $handle.StartTime).TotalSeconds
                    $res.LifetimeSource = 'process times'
                }
            } catch { $life = -1.0 }
            if (($life -lt 0) -and ($exitMs -ge 0) -and ($pidMs -ge 0)) {
                $life = ($exitMs - $pidMs) / 1000.0
                $res.LifetimeSource = 'polled'
            }
            $res.LifetimeSeconds = [double]$life
        }
        $res.Console = Read-TextShared $consolePath
        # The line may have been missed while the console file was being written; the finished file has it. The life of that process
        # cannot be measured any more then, and the verdict says so (a Process ID with no lifetime) instead of "no Process ID line".
        if ($res.ProcId -le 0) { $res.ProcId = Get-LaunchCapProcessId $res.Console }
        $res.Setup = Read-TextShared (Join-Path $dir '~setup.log')
        $res.Ledger = @(Read-Ledger $ledgerPath)
        if (($startMs -ge 0) -and ($promptMs -ge 0)) { $res.PromptSeenSeconds = [math]::Max(0.0, ($promptMs - $startMs) / 1000.0) }
        # A program the force stop left alive is stopped here so it cannot disturb the next scenario.
        $left = Get-ProcessesUnder -Folder (Join-Path $dir 'dist')
        $res.LeftoverCheckRan = [bool]$left.Ran
        foreach ($o in @($left.Found)) {
            try { Stop-Process -Id $o.ProcessId -Force -ErrorAction Stop; $res.LeftoverStopped = [int]$res.LeftoverStopped + 1 } catch { }
        }
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

$silentRun = Invoke-LaunchCapRun -Name 'silent' -AppCode $silentCode -Answer ''
$outputRun = Invoke-LaunchCapRun -Name 'output' -AppCode $outputCode -Answer $answerText

$silentFacts = Get-LaunchCapLogFacts -ConsoleText $silentRun.Console -Prompt '' -Reply ''
$silentLedger = Get-LaunchCapLedgerFacts -Ledger @($silentRun.Ledger)
$outputFacts = Get-LaunchCapLogFacts -ConsoleText $outputRun.Console -Prompt $promptText -Reply $replyText
$outputLedger = Get-LaunchCapLedgerFacts -Ledger @($outputRun.Ledger)
$answerDelay = -1.0
if (($outputLedger.AnsweredT -ge 0) -and ($outputLedger.StartT -ge 0)) { $answerDelay = $outputLedger.AnsweredT - $outputLedger.StartT }

Write-Host '=== launch cap, silent program ==='
Write-Host ("finished={0} exit={1} seconds={2} procId={3} lifetimeSeconds={4} via {5} started={6} consoleExit={7} timedOutLine={8} programWoke={9}" -f $silentRun.Finished, $silentRun.ExitCode, $silentRun.Seconds, $silentRun.ProcId, [math]::Round($silentRun.LifetimeSeconds, 1), $silentRun.LifetimeSource, $silentLedger.Started, $silentFacts.ExitText, $silentFacts.TimedOutLine, ($silentLedger.WokeT -ge 0))
foreach ($l in @(Get-LaunchCapExcerpt $silentRun.Console)) { Write-Host ('console: ' + $l) }
if ($silentRun.Error) { Write-Host ('error: ' + $silentRun.Error) }
Write-Host '=== launch cap, program with a prompt ==='
Write-Host ("finished={0} exit={1} seconds={2} procId={3} lifetimeSeconds={4} via {5} started={6} promptSeenSeconds={7} answerSent={8} answerDelaySeconds={9} replySeen={10} consoleExit={11} timedOutLine={12} successLine={13}" -f $outputRun.Finished, $outputRun.ExitCode, $outputRun.Seconds, $outputRun.ProcId, [math]::Round($outputRun.LifetimeSeconds, 1), $outputRun.LifetimeSource, $outputLedger.Started, [math]::Round($outputRun.PromptSeenSeconds, 1), $outputRun.AnswerSent, [math]::Round($answerDelay, 1), $outputFacts.ReplySeen, $outputFacts.ExitText, $outputFacts.TimedOutLine, $outputFacts.SuccessLine)
foreach ($l in @(Get-LaunchCapExcerpt $outputRun.Console)) { Write-Host ('console: ' + $l) }
if ($outputRun.Error) { Write-Host ('error: ' + $outputRun.Error) }

$silentProblems = @(Get-SilentCapProblems -Finished ([bool]$silentRun.Finished) -Started ([bool]$silentLedger.Started) -ProcId ([int]$silentRun.ProcId) -LifetimeSeconds ([double]$silentRun.LifetimeSeconds) -ExitText ([string]$silentFacts.ExitText) -TimedOutLine ([bool]$silentFacts.TimedOutLine) -CapSeconds $capSeconds)
$outputProblems = @(Get-OutputCapProblems -Finished ([bool]$outputRun.Finished) -Started ([bool]$outputLedger.Started) -AnswerSent ([bool]$outputRun.AnswerSent) -Answered ([bool]($outputLedger.AnsweredT -ge 0)) -AnswerDelaySeconds ([double]$answerDelay) -PromptSeenSeconds ([double]$outputRun.PromptSeenSeconds) -ReplySeen ([bool]$outputFacts.ReplySeen) -ProcId ([int]$outputRun.ProcId) -LifetimeSeconds ([double]$outputRun.LifetimeSeconds) -ExitText ([string]$outputFacts.ExitText) -TimedOutLine ([bool]$outputFacts.TimedOutLine) -SuccessLine ([bool]$outputFacts.SuccessLine) -CapSeconds $capSeconds -MinWaitSeconds $minWaitSeconds)
$silentPass = ($silentProblems.Count -eq 0)
$outputPass = ($outputProblems.Count -eq 0)

$silentDetails = [ordered]@{
    finished = [bool]$silentRun.Finished; seconds = $silentRun.Seconds; exitCode = $silentRun.ExitCode; capSeconds = $capSeconds
    started = [bool]$silentLedger.Started; processId = $silentRun.ProcId; lifetimeSeconds = [math]::Round($silentRun.LifetimeSeconds, 1)
    lifetimeSource = $silentRun.LifetimeSource; consoleExit = $silentFacts.ExitText; timedOutLine = [bool]$silentFacts.TimedOutLine
    programSurvivedStop = [bool]($silentLedger.WokeT -ge 0); leftoverCheckRan = [bool]$silentRun.LeftoverCheckRan; leftoverStopped = $silentRun.LeftoverStopped
}
if ($silentRun.Error) { $silentDetails['error'] = $silentRun.Error }
if (-not $silentPass) { $silentDetails['problems'] = @($silentProblems); $silentDetails['excerpt'] = @(Get-LaunchCapExcerpt $silentRun.Console) }
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.cap.silent'; req = 'REQ-018.6'; pass = [bool]$silentPass
    desc = 'REQ-018.6: the verification run of a program that prints nothing is force-stopped about 30 seconds after it started, and the console reports it as exit -1 and TIMED OUT'
    details = $silentDetails
})

$outputDetails = [ordered]@{
    finished = [bool]$outputRun.Finished; seconds = $outputRun.Seconds; exitCode = $outputRun.ExitCode; capSeconds = $capSeconds
    started = [bool]$outputLedger.Started; processId = $outputRun.ProcId; lifetimeSeconds = [math]::Round($outputRun.LifetimeSeconds, 1)
    lifetimeSource = $outputRun.LifetimeSource; promptSeenSeconds = [math]::Round($outputRun.PromptSeenSeconds, 1)
    answerSent = [bool]$outputRun.AnswerSent; answerDelaySeconds = [math]::Round($answerDelay, 1); replySeen = [bool]$outputFacts.ReplySeen
    consoleExit = $outputFacts.ExitText; timedOutLine = [bool]$outputFacts.TimedOutLine; successLine = [bool]$outputFacts.SuccessLine
    leftoverCheckRan = [bool]$outputRun.LeftoverCheckRan; leftoverStopped = $outputRun.LeftoverStopped
}
if ($outputRun.Error) { $outputDetails['error'] = $outputRun.Error }
if (-not $outputPass) { $outputDetails['problems'] = @($outputProblems); $outputDetails['excerpt'] = @(Get-LaunchCapExcerpt $outputRun.Console) }
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.cap.output'; req = 'REQ-018.6'; pass = [bool]$outputPass
    desc = 'REQ-018.6: the verification run of a program that prints a prompt and waits for input is not force-stopped at 30 seconds; it goes on until the program is answered and ends by itself with exit 0'
    details = $outputDetails
})

if ((-not $silentPass) -or (-not $outputPass)) { exit 1 }
exit 0
