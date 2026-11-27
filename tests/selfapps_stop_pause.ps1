# ASCII only
# selfapps_stop_pause.ps1 - Item 130 (README REQ-016.8): the terminal window stays open at the end of a run, whether the run
# succeeded or failed, until the user presses a key, except in a run that carries the CI marker HP_CI_LANE.
#
# Why a row of its own. Every CI lane carries HP_CI_LANE, so no earlier row ever reached a `pause`: tests/test_req_shall_trace.py
# listed the shall as "inspection" and said it was read from the code. Reading the code found two stops that end with
# `exit /b 1` and no pause at all (the system-folder guard and the stop for a dragged file from another folder, REQ-011), so a
# person who double-clicked run_setup.bat in such a case saw the window close before the message could be read.
#
# Seven rows, fourteen runs. Each run is a real run of run_setup.bat in a folder of its own, started WITHOUT HP_CI_LANE (every HP_,
# PVW_ and NOINPUT variable of the runner is removed from the child's environment first) and with standard input held OPEN, which
# is what a double-click user's window is: cmd.exe `pause` then really waits. The script looks at the console log the run wrote:
#   success  an empty folder (no .py files): the run ends through :success
#   die      PVW_PROVIDER=zzz: the run ends through :die
#   usage    the first argument names no file: the usage stop (it already paused before this item, so it is the control that shows
#            the technique sees a real pause)
#   req011   a file from another folder is dragged on: the REQ-011 stop
#   sysdir   the script sits under %WINDIR%: the system-folder guard
#   unc      the script is started through the runner's own admin share \\localhost\<drive>$ (a person who double-clicks it on a
#            network share): cmd.exe cannot make a UNC folder its working directory, so the run stops with `Workspace path invalid`
# Each must print the stop's own message and then `Press any key to continue . . .`; the run must still be alive five seconds
# after the prompt (it waits for the key, it does not merely print the words), and must end once a key is sent, with the exit code
# of the stop (0 for success, 1 for the others). The seventh row, `marker`, runs the same six folders with HP_CI_LANE set and
# standard input closed: none may print the prompt and each must end by itself with the same exit code, which is the exception the
# shall names and the check that stops the five rows above from passing because a pause is printed whatever the marker says.
#
# Two premises are recorded so that a row cannot pass for the wrong reason: the launch file writes whether HP_CI_LANE was defined
# as the run saw it (`~stop_lane.txt`), and the stop's own message must be in the console (a run that never reached its stop cannot
# show that the stop pauses). The judging function takes plain values and returns a list of problems (tests/test_stop_pause.py
# runs it through a real pwsh on synthetic runs, one red case per comparison).
#
# derived requirement: ids and tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell).
#
# The unc row needs the admin share to reach the scratch folder (tests/selfapps_unc.ps1 shows it does on the runner image); when it
# does not, the row says skip with the reason, which is a skip and not a pass of the behavior. Not covered by a row, pinned as text by
# the unit test: the first of the two `Workspace path invalid` exits (`if not exist "%~dp0"`, a script folder that vanished while the
# file ran), which a test cannot make on a runner, and the two exits after the REQ-011 answer of :determine_entry, which the pre-flight
# stop of the same shall makes unreachable.
#
# Lane: contract-uv (the stops come before any provider work, so every lane would do and no download is made). Gating from its
# first run (AGENTS.md "New tests gate immediately"): a red row holds the aggregate check.
# Emits: self.stoppause.success, .die, .usage, .req011, .sysdir, .unc, .marker
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

# Used when the seven rows share one outcome (a skip, or an input that is missing); the real emissions below are literal too.
function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.success'; req = 'REQ-016.8'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.die'; req = 'REQ-016.8'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.usage'; req = 'REQ-016.8'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.req011'; req = 'REQ-016.8'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.sysdir'; req = 'REQ-016.8'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.unc'; req = 'REQ-016.8'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.marker'; req = 'REQ-016.8'; pass = $Pass; desc = $Desc; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'The window stays open at the end of a run (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'The window stays open at the end of a run: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------------------------------------------------
$evidencePath = Join-Path $here '~stop_pause_evidence.txt'
Set-Content -LiteralPath $evidencePath -Value 'selfapps_stop_pause.ps1 evidence (printable ASCII only)' -Encoding Ascii

function Write-CrLf {
    param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
}

# The console log is still open for writing in the run, so it is read with FileShare.ReadWrite; a file that is not there yet is ''.
function Read-SharedText {
    param([string]$Path)
    try {
        $fs = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::ASCII)
            return [string]$sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return '' }
}

# Appends a titled block to the evidence file the workflow uploads; non-ASCII becomes '?', long texts are cut.
function Add-Evidence {
    param([string]$Title, [string]$Text, [int]$MaxLines = 60)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        $clean = ($l -replace '[^\x20-\x7E]', '?')
        if ($clean.Length -gt 220) { $clean = $clean.Substring(0, 220) }
        [void]$keep.Add($clean)
        if ($keep.Count -ge $MaxLines) { break }
    }
    Add-Content -LiteralPath $evidencePath -Value @('', ('=== ' + $Title + ' ==='), $keep.ToArray()) -Encoding Ascii
}

# ---------------------------------------------------------------------------------------------------------------------
# the judge: plain values in, a list of problems out (run through a real pwsh by tests/test_stop_pause.py)
# ---------------------------------------------------------------------------------------------------------------------
# ExpectPause says whether this run is one that must wait for a key (no marker) or one that must not (marker). WantLane is what the
# launch file must have recorded about HP_CI_LANE. Finished says the run ended (by itself, or after the key). AliveAfterPause says the
# run was still running five seconds after the prompt appeared. A problem is one sentence that names the run.
function Get-StopPauseProblems {
    param(
        [string]$Name, [bool]$ExpectPause, [string]$StopPattern, [string]$ConsoleText, [string]$LaneText, [string]$WantLane,
        [bool]$Finished, [bool]$PauseSeen, [bool]$AliveAfterPause, $ExitCode, [int]$WantExit
    )
    $out = New-Object System.Collections.ArrayList
    $tag = $Name
    $seenLane = ([string]$LaneText).Trim()
    if ($seenLane -ne $WantLane) {
        [void]$out.Add("${tag}: the run saw HP_CI_LANE as '${seenLane}', expected '${WantLane}', so the run is not the one the row means")
    }
    $stop = [regex]::Match([string]$ConsoleText, $StopPattern)
    if (-not $stop.Success) {
        [void]$out.Add("${tag}: the console does not hold the stop's own message, so the run never reached the stop")
    }
    $pauseAt = ([string]$ConsoleText).IndexOf('Press any key to continue')
    if ($ExpectPause) {
        if (-not $PauseSeen) {
            if ($Finished) {
                [void]$out.Add("${tag}: the run ended with no 'Press any key to continue', so the window would close before the message can be read")
            } else {
                [void]$out.Add("${tag}: the run neither ended nor paused within the limit")
            }
        } else {
            if ($stop.Success -and ($pauseAt -ge 0) -and ($pauseAt -lt $stop.Index)) {
                [void]$out.Add("${tag}: the pause comes before the stop's message")
            }
            if (-not $AliveAfterPause) {
                [void]$out.Add("${tag}: the run was no longer running five seconds after the prompt, so it did not wait for a key")
            }
            if (-not $Finished) {
                [void]$out.Add("${tag}: the run did not end after a key was sent")
            }
        }
    } else {
        if ($pauseAt -ge 0) {
            [void]$out.Add("${tag}: the console holds 'Press any key to continue' although the run carries the CI marker")
        }
        if (-not $Finished) {
            [void]$out.Add("${tag}: the run did not end by itself within the limit")
        }
    }
    if ($Finished) {
        if (([string]$ExitCode) -ne ([string]$WantExit)) {
            [void]$out.Add("${tag}: the exit code is '${ExitCode}', expected ${WantExit}")
        }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# the scenarios
# ---------------------------------------------------------------------------------------------------------------------
$work = Join-Path $here '~selftest_stoppause'
$extDir = Join-Path $work '~ext'
$winTemp = $null
if ($env:WINDIR) { $winTemp = Join-Path $env:WINDIR 'Temp' }
foreach ($d in @($work)) {
    if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}
New-Item -ItemType Directory -Force -Path $work | Out-Null
New-Item -ItemType Directory -Force -Path $extDir | Out-Null
Set-Content -LiteralPath (Join-Path $extDir 'external.py') -Value 'print("external")' -Encoding Ascii

# Kind says what the folder holds, Arguments what follows run_setup.bat, Extra the variables set after the scrub, Pattern a regular
# expression for the stop's own message, WantExit the exit code of the stop. tests/test_stop_pause.py pins every text to run_setup.bat.
$scenarios = @(
    @{ Name = 'success'; Kind = 'empty'; Arguments = ''; Extra = @{}; Pattern = 'No Python files detected'; WantExit = 0 }
    @{ Name = 'die'; Kind = 'program'; Arguments = ''; Extra = @{ PVW_PROVIDER = 'zzz' }; Pattern = 'PVW_PROVIDER has a value this bootstrapper does not accept'; WantExit = 1 }
    @{ Name = 'usage'; Kind = 'program'; Arguments = 'nosuchfile'; Extra = @{}; Pattern = 'The first argument must be one of your Python files'; WantExit = 1 }
    @{ Name = 'req011'; Kind = 'program'; Arguments = ('"' + (Join-Path $extDir 'external.py') + '"'); Extra = @{}; Pattern = 'REQ-011: Dragged files must reside in the bootstrapper root folder'; WantExit = 1 }
    @{ Name = 'sysdir'; Kind = 'sysdir'; Arguments = ''; Extra = @{}; Pattern = 'located inside a Windows system folder'; WantExit = 1 }
    @{ Name = 'unc'; Kind = 'unc'; Arguments = ''; Extra = @{}; Pattern = 'Workspace path invalid'; WantExit = 1 }
)

# One run of run_setup.bat in a folder of its own. Marker $false: no HP_CI_LANE, standard input open, a key is sent when the prompt
# has been seen and five seconds have passed. Marker $true: HP_CI_LANE set, standard input closed at once, nothing is sent.
function Invoke-StopRun {
    param($Scenario, [bool]$Marker)
    $res = [ordered]@{ Dir = ''; Console = ''; Lane = ''; Finished = $false; PauseSeen = $false; AliveAfterPause = $false; ExitCode = -1; Seconds = 0; Error = ''
        Skipped = $false; SkipReason = ''; UncDir = '' }
    try {
        $suffix = if ($Marker) { '_ci' } else { '' }
        if ($Scenario.Kind -eq 'sysdir') {
            if (-not $winTemp) { throw 'WINDIR is not set, so there is no system folder to run from' }
            $dir = Join-Path $winTemp ('~selftest_stoppause_sysdir' + $suffix)
        } else {
            $dir = Join-Path $work ($Scenario.Name + $suffix)
        }
        $res.Dir = $dir
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath $batchPath -Destination $dir -Force
        if (($Scenario.Kind -eq 'program') -or ($Scenario.Kind -eq 'unc')) {
            Set-Content -LiteralPath (Join-Path $dir 'main.py') -Value 'print("hello-stoppause")' -Encoding Ascii
        }
        $argText = ''
        if ($Scenario.Arguments) { $argText = ' ' + $Scenario.Arguments }
        $batchCall = 'run_setup.bat'
        if ($Scenario.Kind -eq 'unc') {
            # The bootstrapper is reached through the admin share of this machine; the launch file, its working folder and the console
            # log stay local, as for a person whose own folder is local and whose script is on a share. A marker file written here and
            # read back through the share proves the share reaches this very folder.
            $resolved = (Resolve-Path -LiteralPath $dir).Path
            $uncDir = ''
            if ($resolved -match '^([A-Za-z]):\\(.*)$') { $uncDir = '\\localhost\' + $Matches[1] + '$\' + $Matches[2] }
            $res.UncDir = $uncDir
            $reached = $false
            if ($uncDir) {
                $token = [guid]::NewGuid().ToString()
                Set-Content -LiteralPath (Join-Path $dir '~unc_marker.txt') -Value $token -Encoding Ascii
                try {
                    $seen = Get-Content -LiteralPath (Join-Path $uncDir '~unc_marker.txt') -Raw -ErrorAction Stop
                    $reached = ([string]$seen).Trim() -ceq $token
                } catch { $res.Error = '' }
                Remove-Item -LiteralPath (Join-Path $dir '~unc_marker.txt') -Force -ErrorAction SilentlyContinue
            }
            if (-not $reached) {
                $res.Skipped = $true
                $res.SkipReason = 'unc-share-unavailable'
                return [pscustomobject]$res
            }
            $batchCall = '"' + (Join-Path $uncDir 'run_setup.bat') + '"'
        }
        Write-CrLf -Path (Join-Path $dir '~stop_launch.cmd') -Lines @(
            '@echo off',
            'set "STOP_LANE=undefined"',
            'if defined HP_CI_LANE set "STOP_LANE=defined"',
            '>"~stop_lane.txt" echo %STOP_LANE%',
            ('call ' + $batchCall + $argText + ' > ~stop_console.txt 2>&1'),
            'exit /b %ERRORLEVEL%'
        )
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'cmd.exe'
        $psi.Arguments = '/c call ~stop_launch.cmd'
        $psi.WorkingDirectory = $dir
        $psi.UseShellExecute = $false
        $psi.RedirectStandardInput = $true
        $psi.CreateNoWindow = $true
        # Every variable that could decide for the run is removed from the child's environment, so the runner's own settings (it sets
        # HP_CI_LANE and others) cannot answer for it; the launch file records what the child really saw.
        $names = @($psi.EnvironmentVariables.Keys | ForEach-Object { [string]$_ })
        foreach ($n in $names) {
            if (($n -like 'HP_*') -or ($n -like 'PVW_*') -or ($n -eq 'NOINPUT')) { $psi.EnvironmentVariables.Remove($n) }
        }
        if ($Marker) { $psi.EnvironmentVariables['HP_CI_LANE'] = 'test' }
        foreach ($k in $Scenario.Extra.Keys) { $psi.EnvironmentVariables[[string]$k] = [string]$Scenario.Extra[$k] }
        $consolePath = Join-Path $dir '~stop_console.txt'
        $started = Get-Date
        $p = [System.Diagnostics.Process]::Start($psi)
        $null = $p.Handle   # keeps ExitCode readable after WaitForExit(ms)
        if ($Marker) { $p.StandardInput.Close() }
        $deadline = $started.AddMilliseconds(240000)
        while ((Get-Date) -lt $deadline) {
            if ($p.HasExited) { break }
            if (-not $Marker) {
                if ((Read-SharedText -Path $consolePath) -match 'Press any key to continue') { $res.PauseSeen = $true; break }
            }
            Start-Sleep -Milliseconds 500
        }
        if ($res.PauseSeen) {
            Start-Sleep -Seconds 5
            $res.AliveAfterPause = (-not $p.HasExited)
            if ($res.AliveAfterPause) {
                try { $p.StandardInput.WriteLine(''); $p.StandardInput.Flush(); $p.StandardInput.Close() } catch { $res.Error = [string]$_.Exception.Message }
                if ($p.WaitForExit(60000)) { $res.Finished = $true }
            } else {
                $res.Finished = $true
            }
        } elseif ($p.HasExited) {
            $res.Finished = $true
        }
        if ($res.Finished) {
            $res.ExitCode = $p.ExitCode
        } else {
            & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
            $null = $p.WaitForExit(30000)
        }
        $res.Seconds = [int]((Get-Date) - $started).TotalSeconds
        $res.Console = Read-SharedText -Path $consolePath
        $res.Lane = Read-SharedText -Path (Join-Path $dir '~stop_lane.txt')
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

# One scenario in one mode: the run, its problems and the details of the row.
function Get-StopResult {
    param($Scenario, [bool]$Marker)
    $run = Invoke-StopRun -Scenario $Scenario -Marker $Marker
    if ($run.Skipped) {
        $skipDetails = [ordered]@{ scenario = $Scenario.Name; marker = $Marker; skip = $true; reason = [string]$run.SkipReason; uncPath = [string]$run.UncDir }
        return [pscustomobject]@{ Problems = @(); Details = $skipDetails; Dir = $run.Dir; Skipped = $true }
    }
    $wantLane = if ($Marker) { 'defined' } else { 'undefined' }
    $problems = @(Get-StopPauseProblems -Name ($Scenario.Name + $(if ($Marker) { ' (marker)' } else { '' })) -ExpectPause (-not $Marker) `
        -StopPattern $Scenario.Pattern -ConsoleText $run.Console -LaneText $run.Lane -WantLane $wantLane `
        -Finished ([bool]$run.Finished) -PauseSeen ([bool]$run.PauseSeen) -AliveAfterPause ([bool]$run.AliveAfterPause) `
        -ExitCode $run.ExitCode -WantExit ([int]$Scenario.WantExit))
    if ($run.Error) { $problems += ('the run could not be started or read: ' + $run.Error) }
    Add-Evidence -Title ($Scenario.Name + $(if ($Marker) { ' with the marker' } else { ' without the marker' }) + ' (' + $run.Seconds + ' s, exit ' + $run.ExitCode + ')') -Text $run.Console
    $details = [ordered]@{
        scenario = $Scenario.Name; marker = $Marker; finished = [bool]$run.Finished; pauseSeen = [bool]$run.PauseSeen
        aliveAfterPause = [bool]$run.AliveAfterPause; exitCode = $run.ExitCode; seconds = $run.Seconds; laneSeen = ([string]$run.Lane).Trim()
    }
    if ($problems.Count -gt 0) {
        $details['problems'] = @($problems)
        $tail = @(([string]$run.Console -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 6 | ForEach-Object { ($_ -replace '[^\x20-\x7E]', '?') })
        $details['consoleTail'] = $tail
    }
    return [pscustomobject]@{ Problems = $problems; Details = $details; Dir = $run.Dir; Skipped = $false }
}

$allPass = $true

$success = Get-StopResult -Scenario $scenarios[0] -Marker $false
$die     = Get-StopResult -Scenario $scenarios[1] -Marker $false
$usage   = Get-StopResult -Scenario $scenarios[2] -Marker $false
$req011  = Get-StopResult -Scenario $scenarios[3] -Marker $false
$sysdir  = Get-StopResult -Scenario $scenarios[4] -Marker $false
$unc     = Get-StopResult -Scenario $scenarios[5] -Marker $false

$markerRuns = @()
foreach ($s in $scenarios) { $markerRuns += , (Get-StopResult -Scenario $s -Marker $true) }
$markerProblems = @()
$markerList = New-Object System.Collections.ArrayList
foreach ($m in $markerRuns) {
    $markerProblems += @($m.Problems)
    if ($m.Skipped) {
        [void]$markerList.Add([ordered]@{ scenario = $m.Details.scenario; skip = $true; reason = $m.Details.reason })
    } else {
        [void]$markerList.Add([ordered]@{
            scenario = $m.Details.scenario; finished = $m.Details.finished; pauseSeen = $m.Details.pauseSeen; exitCode = $m.Details.exitCode; laneSeen = $m.Details.laneSeen
        })
    }
}
$markerDetails = [ordered]@{ runs = $markerList.ToArray() }
if ($markerProblems.Count -gt 0) { $markerDetails['problems'] = @($markerProblems) }

$pass = [bool](@($success.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.success'; req = 'REQ-016.8'; pass = $pass
    desc = 'A run that ends through :success without the CI marker prints the key prompt and waits for a key'; details = $success.Details })

$pass = [bool](@($die.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.die'; req = 'REQ-016.8'; pass = $pass
    desc = 'A run that ends through :die without the CI marker prints the key prompt after the error and waits for a key'; details = $die.Details })

$pass = [bool](@($usage.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.usage'; req = 'REQ-016.8'; pass = $pass
    desc = 'The usage stop for a first argument that names no file waits for a key without the CI marker (the control)'; details = $usage.Details })

$pass = [bool](@($req011.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.req011'; req = 'REQ-016.8'; pass = $pass
    desc = 'The stop for a dragged file from another folder (REQ-011) prints the key prompt after the error and waits for a key'; details = $req011.Details })

$pass = [bool](@($sysdir.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.sysdir'; req = 'REQ-016.8'; pass = $pass
    desc = 'The system-folder guard prints the key prompt after the error and waits for a key'; details = $sysdir.Details })

$pass = [bool](@($unc.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.unc'; req = 'REQ-016.8'; pass = $pass
    desc = 'A script started from a network share (UNC path) stops with Workspace path invalid, prints the key prompt after the error and waits for a key'; details = $unc.Details })

$pass = [bool]($markerProblems.Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.stoppause.marker'; req = 'REQ-016.8'; pass = $pass
    desc = 'With HP_CI_LANE set none of the six runs prints the key prompt and each ends by itself with the exit code of its stop (the exception of the shall)'; details = $markerDetails })

foreach ($d in @($sysdir.Dir, $markerRuns[4].Dir)) {
    if ($d -and ($d -like '*~selftest_stoppause_sysdir*')) { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue }
}

if (-not $allPass) { exit 1 }
exit 0
