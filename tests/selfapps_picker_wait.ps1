# ASCII only
# selfapps_picker_wait.ps1 - Item 133 (README REQ-002.15 and REQ-002.22): the entry picker waits 30 seconds for a number and
# then takes the alphabetical default.
#
# REQ-002.15 [minor]: after the numbered list of REQ-002.14 the bootstrapper shall wait 30 seconds for a number.
# REQ-002.22 [minor]: when no number is typed within that wait it shall use the alphabetical default of REQ-002.12.
# Until this script no row waited the full time: every picker row sets the test setting HP_TEST_FORCE_PICKER, which shortens
# the wait to 2 seconds and is the only way past the CI marker, so the 30 seconds were read from the batch file only
# (tests/test_picker_gate.py, class PickerWait). This script bootstraps a folder with two ambiguous programs with NONE of the
# three non-interactivity signals and no test setting, so the picker is reached the way a person's double-click reaches it,
# types nothing, and measures how long the question stays open.
#
# What the measurement is. The harness reads the console log of the bootstrapper while it runs. The clock starts when the
# line "If you do nothing, the alphabetically-first file is used: a_app.py" first shows up (the batch file echoes it directly
# before the line that reads the answer) and stops when the setup log first holds "Picker entry selected: a_app.py" (the line
# written directly after the answer). Both are seen by polling every 200 ms, so the figure is the wait plus at most half a
# second. The program is stopped a second later with taskkill /F /T: the point of the row is the wait, and the run would
# otherwise go on to a build and to the pause at the end of the run, which a console that nobody types into never ends.
#
# Why a console. choice.exe reads the keyboard, and what it does with standard input that is a closed file or a pipe nobody
# writes to was never measured in this repository (selfapps_cascade_timed.ps1 only says it "degrades to its default"). A person
# double-clicking has a console of their own, so the harness gives the bootstrapper one: method `console` starts cmd.exe with a
# new hidden console window (its standard input is the console's input buffer, silent unless someone types) and method `pipe`
# starts it with standard input redirected to a pipe that stays open and silent. Each method is first calibrated with a bare
# `choice /T 5 /D 1`: it must still be waiting after 4 seconds and return the default 1. The first method that passes is used
# for both bootstraps, and both calibrations are recorded in the row. If neither holds the wait, both rows are red and say so:
# a wait that cannot be held open cannot be measured, so the row is not skipped and not green.
#
# Rows:
#   self.entry.picker.wait.control  the calibration, and the same bootstrap with HP_TEST_FORCE_PICKER set: the test setting
#                                   shortens the wait to 2 seconds, and the harness must measure about 2 seconds and read
#                                   "wait 2s" in the prompt. That shows the measurement follows the batch file's own setting,
#                                   so the 30 seconds of the next row are the product's and not something the harness adds.
#   self.entry.picker.wait          no signal, no test setting: the prompt says "wait 30s", about 30 seconds pass (29 to 38)
#                                   with nothing typed, and the alphabetical default a_app.py is the file the picker selects.
#
# derived requirement: the ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text, not
# PowerShell), and the judging functions take plain values and return a list of problems, so tests/test_picker_wait.py runs
# each of them through real pwsh on synthetic runs, one red case for each comparison. The strings the script looks for are the
# batch file's own and are pinned to it by that test. A parameter and a local never differ only by case (PowerShell variable
# names ignore case: Item 99).
#
# Lane: contract-uv (the lane with the most headroom), gating from its first run (AGENTS.md, "New tests gate immediately").
# Emits: self.entry.picker.wait.control, self.entry.picker.wait
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

# What the harness looks for in the console and the setup log. Each text is the batch file's own (:pick_entry_interactive).
$menuMarker     = 'Multiple Python files detected'
$startMarker    = 'If you do nothing, the alphabetically-first file is used: a_app.py'
$selectedMarker = 'Picker entry selected: '

# The judging functions. Plain values in, a list of sentences out; nothing when the run shows what the row expects.

# What one calibration run of a bare timed choice shows about the harness.
function Get-CalibrationProblems {
    param([string]$Method, [bool]$Finished, [double]$Seconds, [string]$RcText)
    $out = New-Object System.Collections.ArrayList
    if (-not $Finished) {
        [void]$out.Add("${Method}: the calibration choice did not return within its time limit")
        return $out.ToArray()
    }
    if ($Seconds -lt 4.0) { [void]$out.Add("${Method}: the calibration choice returned after ${Seconds} s, so it did not wait for the 5 seconds it was given") }
    if ($Seconds -gt 20.0) { [void]$out.Add("${Method}: the calibration choice took ${Seconds} s for a wait of 5 seconds") }
    if ($RcText.Trim() -ne '1') { [void]$out.Add("${Method}: the calibration choice left the answer [${RcText}], expected the default 1") }
    return $out.ToArray()
}

# The facts one bootstrap's console and setup log show, as plain values.
function Get-PickerFacts {
    param([string]$Console, [string]$SetupLog, [int]$ExpectedWait, [string]$MenuMarker, [string]$StartMarker, [string]$SelectedMarker)
    $promptText = 'or wait ' + $ExpectedWait + 's for the default [1]'
    $chosen = ''
    $at = $SetupLog.IndexOf($SelectedMarker, [System.StringComparison]::Ordinal)
    if ($at -ge 0) {
        $rest = $SetupLog.Substring($at + $SelectedMarker.Length)
        $m = [regex]::Match($rest, '^[^\r\n]*')
        $chosen = $m.Value.Trim()
    }
    return [ordered]@{
        menuSeen    = ($Console.IndexOf($MenuMarker, [System.StringComparison]::Ordinal) -ge 0)
        defaultLine = ($Console.IndexOf($StartMarker, [System.StringComparison]::Ordinal) -ge 0)
        promptSeen  = ($Console.IndexOf($promptText, [System.StringComparison]::Ordinal) -ge 0)
        selected    = $chosen
    }
}

# What is wrong with one bootstrap of the picker. WaitSec is -1 when the clock never started or never stopped.
function Get-WaitProblems {
    param([string]$Label, [bool]$HarnessOk, [bool]$EnvDumped, [string[]]$FlagsSeen, [string[]]$ExpectFlags,
          [bool]$MenuSeen, [bool]$PromptSeen, [string]$Selected, [string]$ExpectSelected, [double]$WaitSec, [int]$Expected, [bool]$TimedOut)
    $out = New-Object System.Collections.ArrayList
    if (-not $HarnessOk) {
        [void]$out.Add("${Label}: no harness method held a timed choice open in the calibration, so the wait could not be measured")
        return $out.ToArray()
    }
    if (-not $EnvDumped) { [void]$out.Add("${Label}: the environment listing was not written, so the signals are unproven") }
    $seenFlags = (@($FlagsSeen) | Sort-Object) -join ','
    $wantFlags = (@($ExpectFlags) | Sort-Object) -join ','
    if ($seenFlags -ine $wantFlags) { [void]$out.Add("${Label}: the run started with the flags [${seenFlags}], expected [${wantFlags}]") }
    if (-not $MenuSeen) { [void]$out.Add("${Label}: the numbered list was never printed, so the picker was not reached") }
    if (-not $PromptSeen) { [void]$out.Add("${Label}: the prompt of the choice does not say that it waits ${Expected} seconds for the default") }
    if ($Selected -ne $ExpectSelected) { [void]$out.Add("${Label}: the picker selected [${Selected}], expected the alphabetical default [${ExpectSelected}]") }
    if ($WaitSec -lt 0) {
        if ($TimedOut) { [void]$out.Add("${Label}: the picker had not answered within the time limit, so the wait was never measured") }
        else { [void]$out.Add("${Label}: the run ended before the picker's wait could be measured") }
    } else {
        if ($WaitSec -lt ($Expected - 1)) { [void]$out.Add("${Label}: the question was open for ${WaitSec} s, expected about ${Expected} s (at least $($Expected - 1))") }
        if ($WaitSec -gt ($Expected + 8)) { [void]$out.Add("${Label}: the question was open for ${WaitSec} s, expected about ${Expected} s (at most $($Expected + 8))") }
    }
    return $out.ToArray()
}

# The last lines of a log, printable ASCII only and cut short, so a red row says what the console showed.
function Get-Tail {
    param([string]$Text, [int]$Max = 25)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l.Trim().Length -eq 0) { continue }
        $clean = ($l -replace '[^\x20-\x7E]', '?')
        if ($clean.Length -gt 140) { $clean = $clean.Substring(0, 140) }
        [void]$keep.Add($clean)
    }
    $all = $keep.ToArray()
    if ($all.Count -le $Max) { return ,$all }
    return ,@($all[($all.Count - $Max)..($all.Count - 1)])
}

# The file may be open for writing in the bootstrapper while it is read: open it for sharing and give nothing back on an error.
function Read-Shared {
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::ASCII)
            return [string]$sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

function Get-FlagNames {
    param([string]$Path)
    $names = @()
    if (Test-Path -LiteralPath $Path) {
        $names = @(Get-Content -LiteralPath $Path -Encoding ASCII | ForEach-Object { ($_ -split '=', 2)[0] } |
            Where-Object { $_ -match '^(HP_|PVW_)' -or $_ -ieq 'NOINPUT' })
    }
    return ,$names
}

$allIds = @('self.entry.picker.wait.control', 'self.entry.picker.wait')
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-002.15'; pass = $true; desc = 'Entry picker wait (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-002.15'; pass = $false; desc = 'Entry picker wait: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    exit 1
}

# One bootstrap has to reach the picker (uv and Python come first), wait 30 seconds and be stopped; the limit only catches a hang.
$timeLimitSec = 900
$workRoot = Join-Path $here '~selftest_picker_wait'
if (Test-Path -LiteralPath $workRoot) { Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $workRoot | Out-Null

# --- scrub every flag; remember and restore them afterwards (see tests/selfapps_offers_noninteractive.ps1 for why this is done twice) ---
$scrubbed = @{}
foreach ($item in @(Get-ChildItem Env:)) {
    if ($item.Name -match '^(HP_|PVW_)' -or $item.Name -ieq 'NOINPUT') { $scrubbed[$item.Name] = $item.Value }
}
foreach ($name in @($scrubbed.Keys)) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
$parentStillSet = @($scrubbed.Keys | Where-Object { $null -ne [Environment]::GetEnvironmentVariable($_) } | Sort-Object)

# Starts cmd.exe on a batch file in a folder. console: a new hidden console window, so standard input is the console's own
# input buffer. pipe: standard input is a pipe that this process keeps open and never writes to. The object returned holds the
# process and, for the pipe, the stream that must stay open until the process is stopped.
function Start-HarnessProcess {
    param([string]$Method, [string]$Dir, [string]$CmdName)
    $holder = $null
    if ($Method -eq 'console') {
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', ('call ' + $CmdName)) -WorkingDirectory $Dir -WindowStyle Hidden -PassThru
    } else {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/c call ' + $CmdName
        $psi.WorkingDirectory = $Dir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        $proc = [System.Diagnostics.Process]::Start($psi)
        $holder = $proc.StandardInput
    }
    return [pscustomobject]@{ Proc = $proc; Holder = $holder }
}

function Stop-HarnessProcess {
    param($Started)
    if ($null -eq $Started -or $null -eq $Started.Proc) { return }
    if (-not $Started.Proc.HasExited) {
        & taskkill.exe /F /T /PID $Started.Proc.Id 2>&1 | Out-Null
        $null = $Started.Proc.WaitForExit(30000)
    }
    if ($null -ne $Started.Holder) { try { $Started.Holder.Dispose() } catch { } }
}

# A bare timed choice in the harness: how long does it stay open, and which answer does it leave?
function Invoke-Calibration {
    param([string]$Method)
    $dir = Join-Path $workRoot ('cal_' + $Method)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $lines = @('@echo off', 'choice /C 123456789 /N /T 5 /D 1 /M "cal: " > ~cal.out 2>&1', 'echo %ERRORLEVEL% > ~cal.rc')
    Set-Content -LiteralPath (Join-Path $dir '~cal.cmd') -Value $lines -Encoding ASCII
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $started = $null
    $finished = $false
    try {
        $started = Start-HarnessProcess -Method $Method -Dir $dir -CmdName '~cal.cmd'
        $finished = $started.Proc.WaitForExit(40000)
    } catch {
        $err = [string]$_.Exception.Message
        return [pscustomobject]@{ Method = $Method; Finished = $false; Seconds = -1.0; RcText = ''; Problems = @("${Method}: the harness could not start the process: $err"); Error = $err }
    } finally {
        $seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Stop-HarnessProcess $started
    }
    $rc = ''
    $rcPath = Join-Path $dir '~cal.rc'
    if (Test-Path -LiteralPath $rcPath) { $rc = [string](Get-Content -LiteralPath $rcPath -Raw -Encoding ASCII) }
    $problems = @(Get-CalibrationProblems -Method $Method -Finished ([bool]$finished) -Seconds ([double]$seconds) -RcText $rc)
    return [pscustomobject]@{ Method = $Method; Finished = [bool]$finished; Seconds = $seconds; RcText = $rc.Trim(); Problems = $problems; Error = '' }
}

$appA = "print('entry-a')`n"
$appB = "print('entry-b')`n"

# Bootstraps the two ambiguous programs with exactly the flags in $SetLines (none for the real row) and measures the wait.
function Invoke-PickerRun {
    param([string]$Scenario, [string]$Method, [string[]]$SetLines, [int]$Expected)
    $dir = Join-Path $workRoot $Scenario
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $batchPath -Destination $dir -Force
    # Neither file is PREFERRED and neither has a __main__ guard: find_entry takes the ambiguous alphabetical fallback (a_app.py),
    # which is what makes run_setup.bat offer the picker (same pair as tests/selfapps_entry_picker.ps1).
    Set-Content -LiteralPath (Join-Path $dir 'a_app.py') -Value $appA -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $dir 'b_app.py') -Value $appB -Encoding ASCII

    # The wrapper lists the flag-shaped variables it started with (diagnostic), clears every flag the job had set, applies the
    # scenario's own setting, then lists again (the verdict). No space before a redirection: a space would become part of the
    # prefix that `set` looks for. Standard input is NOT redirected: the question must be open on a real console or pipe.
    $listBefore = @('set HP_> ~pw_env0.txt 2>nul', 'set PVW_>> ~pw_env0.txt 2>nul', 'set NOINPUT>> ~pw_env0.txt 2>nul')
    $clearLines = @($scrubbed.Keys | Where-Object { $_ -match '^[A-Za-z0-9_]+$' } | Sort-Object | ForEach-Object { 'set "' + $_ + '="' })
    $listAfter = @('set HP_> ~pw_env.txt 2>nul', 'set PVW_>> ~pw_env.txt 2>nul', 'set NOINPUT>> ~pw_env.txt 2>nul')
    $wrapperLines = @('@echo off') + $listBefore + $clearLines + $SetLines + $listAfter + @('call run_setup.bat > ~pw_console.log 2>&1', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $dir '~pw_launch.cmd') -Value $wrapperLines -Encoding ASCII

    $consolePath = Join-Path $dir '~pw_console.log'
    $setupPath   = Join-Path $dir '~setup.log'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tStart = -1.0
    $tStop = -1.0
    $timedOut = $false
    $started = $null
    $startError = ''
    try {
        $started = Start-HarnessProcess -Method $Method -Dir $dir -CmdName '~pw_launch.cmd'
        while ($true) {
            if ($sw.Elapsed.TotalSeconds -ge $timeLimitSec) { $timedOut = $true; break }
            $con = Read-Shared $consolePath
            if ($tStart -lt 0 -and $con.IndexOf($startMarker, [System.StringComparison]::Ordinal) -ge 0) { $tStart = $sw.Elapsed.TotalSeconds }
            if ($tStart -ge 0) {
                $setupNow = Read-Shared $setupPath
                if ($setupNow.IndexOf($selectedMarker, [System.StringComparison]::Ordinal) -ge 0) { $tStop = $sw.Elapsed.TotalSeconds; break }
            }
            if ($started.Proc.HasExited) { break }
            Start-Sleep -Milliseconds 200
        }
        # One more second so that the lines written right after the answer are on disk, then the run is stopped: what follows
        # the picker (the build, the pause that ends a run) is not what this row is about.
        if ($tStop -ge 0) { Start-Sleep -Seconds 1 }
    } catch {
        $startError = [string]$_.Exception.Message
    } finally {
        $totalSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Stop-HarnessProcess $started
    }
    $waitSec = -1.0
    if ($tStart -ge 0 -and $tStop -ge 0) { $waitSec = [math]::Round($tStop - $tStart, 1) }
    $consoleText = Read-Shared $consolePath
    $setupText = Read-Shared $setupPath
    $envPath  = Join-Path $dir '~pw_env.txt'
    $env0Path = Join-Path $dir '~pw_env0.txt'
    $facts = Get-PickerFacts -Console $consoleText -SetupLog $setupText -ExpectedWait $Expected -MenuMarker $menuMarker -StartMarker $startMarker -SelectedMarker $selectedMarker
    return [pscustomobject]@{
        Scenario  = $Scenario
        Method    = $Method
        TimedOut  = $timedOut
        Seconds   = $totalSeconds
        WaitSec   = $waitSec
        EnvDumped = ((Test-Path -LiteralPath $envPath) -and (Test-Path -LiteralPath $env0Path))
        FlagsSeen = (Get-FlagNames $envPath)
        Facts     = $facts
        Tail      = (Get-Tail $consoleText)
        StartErr  = $startError
    }
}

# The verdict and the details of one bootstrap, written as the details of its row.
function Get-RunResult {
    param($Run, [string]$Label, [bool]$HarnessOk, [string[]]$ExpectFlags, [int]$Expected)
    if ($null -eq $Run) {
        # No bootstrap ran: either the harness could not hold a choice open (that sentence), or it threw and the caller says so.
        $p = @()
        if (-not $HarnessOk) {
            $p = @(Get-WaitProblems -Label $Label -HarnessOk $false -EnvDumped $false -FlagsSeen @() -ExpectFlags $ExpectFlags -MenuSeen $false -PromptSeen $false -Selected '' -ExpectSelected 'a_app.py' -WaitSec -1.0 -Expected $Expected -TimedOut $false)
        }
        return [ordered]@{ problems = $p; ran = $false }
    }
    $p = @(Get-WaitProblems -Label $Label -HarnessOk $HarnessOk -EnvDumped ([bool]$Run.EnvDumped) -FlagsSeen @($Run.FlagsSeen) -ExpectFlags $ExpectFlags `
        -MenuSeen ([bool]$Run.Facts.menuSeen) -PromptSeen ([bool]$Run.Facts.promptSeen) -Selected ([string]$Run.Facts.selected) -ExpectSelected 'a_app.py' `
        -WaitSec ([double]$Run.WaitSec) -Expected $Expected -TimedOut ([bool]$Run.TimedOut))
    if ($Run.StartErr) { $p += "${Label}: the harness could not run the bootstrap: $($Run.StartErr)" }
    $d = [ordered]@{
        ran = $true; method = $Run.Method; waitSec = $Run.WaitSec; expectedSec = $Expected; totalSec = $Run.Seconds; timedOut = $Run.TimedOut
        flagsSeen = @($Run.FlagsSeen); envDumped = [bool]$Run.EnvDumped; facts = $Run.Facts
        problems = $p
    }
    if ($p.Count -gt 0) { $d['consoleTail'] = @($Run.Tail) }
    return $d
}

$allPass = $true
# derived requirement: a script that stops before it writes a row leaves nothing for the gate to read, and an absent row cannot be red
# (the expected-row lists only protect an id after green runs have listed it), so every id this script has not written by the time the
# main block ends, normally or by an unexpected error, is written as a failing row below.
$rowsWritten = @{}
$crashMessage = ''
try {
    # ------------------------------------------------------------ the harness: which method holds a timed choice open?
    $cals = @()
    foreach ($m in @('console', 'pipe')) { $cals += Invoke-Calibration -Method $m }
    $method = ''
    foreach ($c in $cals) { if ($method -eq '' -and @($c.Problems).Count -eq 0) { $method = $c.Method } }
    $harnessOk = ($method -ne '')
    $calDetails = @($cals | ForEach-Object { [ordered]@{ method = $_.Method; finished = $_.Finished; seconds = $_.Seconds; answer = $_.RcText; problems = @($_.Problems) } })
    # When no method held a choice open, the calibration sentences say why and are part of both rows' problems.
    $calProblems = @()
    if (-not $harnessOk) { $calProblems = @($cals | ForEach-Object { @($_.Problems) }) }

    # ------------------------------------------------------------ the control: the test setting shortens the wait to 2 seconds
    $forced = $null
    if ($harnessOk) {
        try { $forced = Invoke-PickerRun -Scenario 'forced' -Method $method -SetLines @('set "HP_TEST_FORCE_PICKER=1"') -Expected 2 } catch { $forced = $null; $forcedError = [string]$_.Exception.Message }
    }
    $fd = Get-RunResult -Run $forced -Label 'forced' -HarnessOk $harnessOk -ExpectFlags @('HP_TEST_FORCE_PICKER') -Expected 2
    $controlProblems = @($fd.problems) + @($calProblems)
    if ($harnessOk -and $null -eq $forced) { $controlProblems += "forced: the harness failed before the bootstrap ended: $forcedError" }
    $controlPass = [bool]($harnessOk -and $controlProblems.Count -eq 0)
    if (-not $controlPass) { $allPass = $false }
    $details = [ordered]@{ harnessMethod = $method; calibrations = $calDetails; flagsScrubbed = $scrubbed.Count; parentStillSet = @($parentStillSet); timeLimitSec = $timeLimitSec }
    foreach ($k in $fd.Keys) { $details[$k] = $fd[$k] }
    $details['problems'] = @($controlProblems)
    Write-NdjsonRow ([ordered]@{
        id = 'self.entry.picker.wait.control'; req = 'REQ-002.15'; pass = $controlPass
        desc = 'REQ-002.15 control: the harness keeps a timed choice open for its full time, and with the test setting that shortens the wait the picker is measured at about 2 seconds, so the 30 seconds of the next row are the product setting and not the harness'
        details = $details
    })
    $rowsWritten['self.entry.picker.wait.control'] = $true

    # ------------------------------------------------------------ the row: no signal, no test setting, nothing typed
    $real = $null
    if ($harnessOk) {
        try { $real = Invoke-PickerRun -Scenario 'real' -Method $method -SetLines @() -Expected 30 } catch { $real = $null; $realError = [string]$_.Exception.Message }
    }
    $rd = Get-RunResult -Run $real -Label 'real' -HarnessOk $harnessOk -ExpectFlags @() -Expected 30
    $rowProblems = @($rd.problems) + @($calProblems)
    if ($harnessOk -and $null -eq $real) { $rowProblems += "real: the harness failed before the bootstrap ended: $realError" }
    $rowPass = [bool]($harnessOk -and $rowProblems.Count -eq 0)
    if (-not $rowPass) { $allPass = $false }
    $details = [ordered]@{ harnessMethod = $method; calibrations = $calDetails; flagsScrubbed = $scrubbed.Count; parentStillSet = @($parentStillSet); timeLimitSec = $timeLimitSec }
    foreach ($k in $rd.Keys) { $details[$k] = $rd[$k] }
    $details['problems'] = @($rowProblems)
    Write-NdjsonRow ([ordered]@{
        id = 'self.entry.picker.wait'; req = 'REQ-002.15, REQ-002.22'; pass = $rowPass
        desc = 'REQ-002.15 and REQ-002.22: with none of the three non-interactivity signals and no test setting, the entry picker keeps its question open for about 30 seconds with nothing typed and then selects the alphabetical default'
        details = $details
    })
    $rowsWritten['self.entry.picker.wait'] = $true
} catch {
    $crashMessage = ('{0} (script line {1})' -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
    $allPass = $false
} finally {
    foreach ($name in @($scrubbed.Keys)) { [Environment]::SetEnvironmentVariable($name, $scrubbed[$name]) }
}

# Every id that was not written above is written now as a red row that says why, so a stop before the rows is never silent.
foreach ($rowId in $allIds) {
    if (-not $rowsWritten.ContainsKey($rowId)) {
        $allPass = $false
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-002.15'; pass = $false; desc = 'Entry picker wait: the script stopped before this row was written'; details = [ordered]@{ error = 'the script stopped before this row was written'; crash = $crashMessage } })
    }
}

if (-not $allPass) { exit 1 }
exit 0
