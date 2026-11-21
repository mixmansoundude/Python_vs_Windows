# ASCII only
# selfapps_optbuild_cap.ps1 - Item 110 (README REQ-018.36): the verification run of the optimized build ends after 30 seconds,
# whatever the program prints, and nothing of the program is left running.
#
# Why a row. The prompt of :offer_optimized_build and the log line of PVW_BUILDER=both tell the user that building starts the program
# once more "for up to 30 seconds". The one inline PowerShell line that does the run waits 30 seconds, calls Process.Kill() on the
# process it started and then reads the output without a limit. A Nuitka onefile EXE is two processes, the bootstrap that is started
# and the program it starts. Kill() ends only the first, the second keeps the output pipes open, and the read waits until the program
# ends by itself, so a program that keeps printing (a long loop, a server) held the bootstrapper for as long as it ran, and the
# program was left running behind a bootstrapper that had already given up. The repair loop's line had exactly this defect until
# Item 106 (tests/selfapps_repair_cap.ps1, run 43532440009); this line was found with it and left (CLAUDE.md Item 110).
#
# Two scenarios, one driver each. The real lines are cut out of run_setup.bat (from the line that sets HP_OPTBUILD_VERIFY_EXIT to -1
# up to the line that tests it against 0), wrapped in a small batch file and run with cmd.exe and closed standard input. The program
# is a stand-in with the same shape as the real one: a .cmd file (the process the line starts) that runs a PowerShell script (the
# program it starts) which writes a line a second to the output pipe and, to a ledger at an absolute path, a line with its own clock.
#   cap   the program prints for 100 seconds: the line must return -1, the ledger must show the program ran for about 30 seconds and
#         never reached its last line, and no process of the program may be left running when the driver has returned
#   exit  the program prints three lines and ends by itself with exit code 0: the line must return 0 and the ledger must reach its
#         last line (the control: a line that returned -1 for everything, or a stand-in that cannot end by itself, would pass cap)
#
# Judged by the program's own clock and the process list, not by the driver's word: the driver is the real line plus two echo lines.
#
# derived requirement: ids and tags stay literal at the Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell), and the judging function takes plain values and returns a list of problems
# (tests/test_optbuild_cap.py runs it through a real pwsh on synthetic runs).
#
# Limit, stated so that nobody reads more into the row than it shows: the stand-in is a .cmd and a PowerShell script, not a Nuitka
# EXE (a real Nuitka build takes minutes and the shape that matters, a started process whose child holds the pipes, is the same);
# that the offer calls this line is shown by tests/selfapps_optimized_build.ps1 (uv lane) and tests/selfapps_workdir.ps1 (optbuild).
#
# Lane: contract-uv (the lane with the most wall-clock headroom). Gating from its first run (AGENTS.md "New tests gate immediately"):
# a red row holds the aggregate check. Two driver runs, about one minute for the first and seconds for the second.
# Emits: self.optbuild.cap
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
    Write-NdjsonRow ([ordered]@{ id = 'self.optbuild.cap'; req = 'REQ-018.36'; pass = $true
        desc = 'Optimized-build verification run ends at the cap (skipped on non-Windows)'; details = ([ordered]@{ skip = $true; reason = 'non-windows-host' }) })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.optbuild.cap'; req = 'REQ-018.36'; pass = $false
        desc = 'Optimized-build verification run ends at the cap: run_setup.bat not found'; details = ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }) })
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------------------------------------------------
$evidencePath = Join-Path $here '~optbuild_cap_evidence.txt'
Set-Content -LiteralPath $evidencePath -Value 'selfapps_optbuild_cap.ps1 evidence (printable ASCII only)' -Encoding Ascii

function Read-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
    if ($null -eq $t) { return '' }
    return [string]$t
}

function Write-CrLf {
    param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
}

# Appends a titled block to the evidence file the workflow uploads; non-ASCII becomes '?', long texts are cut to their start and end.
function Add-Evidence {
    param([string]$Title, [string]$Text, [int]$MaxLines = 60)
    $all = @($Text -split "`r?`n")
    $keep = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($all.Count -gt $MaxLines -and $i -ge ($MaxLines / 2) -and $i -lt ($all.Count - ($MaxLines / 2))) {
            if ($i -eq ($MaxLines / 2)) { [void]$keep.Add('... (lines left out) ...') }
            continue
        }
        $clean = ($all[$i] -replace '[^\x20-\x7E]', '?')
        if ($clean.Length -gt 220) { $clean = $clean.Substring(0, 220) }
        [void]$keep.Add($clean)
    }
    Add-Content -LiteralPath $evidencePath -Value @('', ('=== ' + $Title + ' ==='), $keep.ToArray()) -Encoding Ascii
}

# Runs one cmd launch file in a working folder with a hard limit; a hang is a red row, not a held job.
function Invoke-Launch {
    param([string]$Dir, [string]$LaunchName, [int]$LimitMs)
    $res = [ordered]@{ Finished = $false; ExitCode = -1; Seconds = 0; Error = '' }
    try {
        $started = Get-Date
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('call ' + $LaunchName)) -WorkingDirectory $Dir -NoNewWindow -PassThru
        $null = $p.Handle   # keeps ExitCode readable after WaitForExit(ms)
        if ($p.WaitForExit($LimitMs)) {
            $res.Finished = $true
            $res.ExitCode = $p.ExitCode
        } else {
            & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
            $null = $p.WaitForExit(30000)
        }
        $res.Seconds = [int]((Get-Date) - $started).TotalSeconds
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return $res
}

$batLines = [System.IO.File]::ReadAllLines($batchPath)

# Lines from the line that is exactly StartLine up to, not including, the line that is exactly EndLine.
function Get-BatBlock {
    param([string]$StartLine, [string]$EndLine)
    $start = -1
    for ($i = 0; $i -lt $batLines.Length; $i++) {
        if ($batLines[$i].Trim() -eq $StartLine) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = -1
    for ($j = $start + 1; $j -lt $batLines.Length; $j++) {
        if ($batLines[$j].Trim() -eq $EndLine) { $end = $j; break }
    }
    if ($end -lt 0) { return $null }
    return $batLines[$start..($end - 1)]
}

# ---------------------------------------------------------------------------------------------------------------------
# the scenarios, and what each run must show
# ---------------------------------------------------------------------------------------------------------------------
# Ticks is how many lines the program prints (one a second), ExpectExit the value the line must leave in HP_OPTBUILD_VERIFY_EXIT,
# ExpectDone whether the program must reach its last ledger line. The span limits are seconds on the program's own clock between its
# first and its last tick: the cap is 30 seconds from the start of the run, the first tick comes after PowerShell has started, and the
# stop adds a few seconds at most, so 15 to 50 separates a run that was ended at the cap (about 28) from one that was waited for (99).
$scenarios = @(
    [pscustomobject]@{ Name = 'cap'; Ticks = 100; ExpectExit = '-1'; ExpectDone = $false; MinTicks = 10; MinSpan = 15; MaxSpan = 50; MaxSeconds = 75 },
    [pscustomobject]@{ Name = 'exit'; Ticks = 3; ExpectExit = '0'; ExpectDone = $true; MinTicks = 3; MinSpan = 0; MaxSpan = 20; MaxSeconds = 60 }
)

# ---------------------------------------------------------------------------------------------------------------------
# judging: plain values in, a list of problems out (nothing when the run shows what the scenario must show)
# ---------------------------------------------------------------------------------------------------------------------
function Get-OptCapProblems {
    param([string]$Scenario, [bool]$Finished, [int]$Seconds, [string]$ResultText, [string]$LedgerText, [bool]$LeftoverChecked,
          [string[]]$Leftover, [string]$ExpectExit, [bool]$ExpectDone, [int]$MinTicks, [double]$MinSpan, [double]$MaxSpan, [int]$MaxSeconds)
    $out = New-Object System.Collections.ArrayList
    $tag = "optimized-build verification run ${Scenario}"
    if (-not $Finished) { [void]$out.Add("${tag}: the driver did not finish within the time limit, so the line did not return"); return $out.ToArray() }
    if ($ResultText -notmatch '(?m)^END\s*$') { [void]$out.Add("${tag}: the driver did not reach its end"); return $out.ToArray() }
    $exitMatch = [regex]::Match($ResultText, '(?m)^VERIFY_EXIT=(-?\d+)\s*$')
    if (-not $exitMatch.Success) {
        [void]$out.Add("${tag}: the line left no exit code in HP_OPTBUILD_VERIFY_EXIT")
    } elseif ($exitMatch.Groups[1].Value -ne $ExpectExit) {
        [void]$out.Add("${tag}: the line gave the exit code $($exitMatch.Groups[1].Value), expected ${ExpectExit}")
    }
    $ticks = @([regex]::Matches($LedgerText, '(?m)^tick (\d+) (\d+)\s*$'))
    if ($ticks.Count -lt $MinTicks) {
        [void]$out.Add("${tag}: the program printed $($ticks.Count) line(s) on its own clock, expected at least ${MinTicks}, so it did not run as the scenario needs")
    }
    $done = [bool]($LedgerText -match '(?m)^done \d+\s*$')
    if ($ExpectDone -and -not $done) {
        [void]$out.Add("${tag}: the program never reached its last line, so it was stopped although it ends by itself")
    }
    if ((-not $ExpectDone) -and $done) {
        [void]$out.Add("${tag}: the program reached its last line, so nothing ended it at the cap and it ran to its end")
    }
    if ($ticks.Count -ge 2) {
        $first = [double]$ticks[0].Groups[2].Value
        $last = [double]$ticks[$ticks.Count - 1].Groups[2].Value
        $span = ($last - $first) / 1000.0
        if ($span -gt $MaxSpan) { [void]$out.Add("${tag}: the program ran for ${span} seconds on its own clock, more than the ${MaxSpan} seconds the cap and the stop allow") }
        if ((-not $ExpectDone) -and $span -lt $MinSpan) { [void]$out.Add("${tag}: the program ran for only ${span} seconds on its own clock, less than ${MinSpan}, so it was not the cap that ended it") }
    }
    if ($Seconds -gt $MaxSeconds) { [void]$out.Add("${tag}: the driver took ${Seconds} seconds, more than the ${MaxSeconds} the cap and the stop allow") }
    if (-not $LeftoverChecked) {
        [void]$out.Add("${tag}: the process list could not be read, so nothing is known about what was left running")
    } elseif ($Leftover.Count -gt 0) {
        [void]$out.Add("${tag}: $($Leftover.Count) process(es) of the program were still running after the line returned: $($Leftover -join ', ')")
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# the driver: the real lines in a small batch file around the stand-in program
# ---------------------------------------------------------------------------------------------------------------------
$work = Join-Path $here '~selftest_optbuildcap'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

# The processes whose command line names the holder script of this scenario's folder; each is stopped so that the next scenario
# starts clean, and the list says what a defective line would have left behind. Checked is false when the list cannot be read.
function Get-LeftoverProcesses {
    param([string]$Marker)
    $found = New-Object System.Collections.ArrayList
    $checked = $true
    try {
        foreach ($proc in @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop)) {
            $cl = [string]$proc.CommandLine
            if ($cl -and $cl.Contains($Marker) -and ($proc.ProcessId -ne $PID)) {
                [void]$found.Add(('' + $proc.ProcessId + ' ' + $proc.Name))
                try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch { }
            }
        }
    } catch {
        $checked = $false
    }
    return [pscustomobject]@{ Checked = $checked; Found = @($found) }
}

function Invoke-OptCapScenario {
    param($Scenario, [string[]]$Block)
    $dir = Join-Path $work $Scenario.Name
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'dist') | Out-Null
    $holder = Join-Path $dir '~optcap_holder.ps1'
    $ledger = Join-Path $dir '~optcap_ledger.txt'
    Write-CrLf -Path $holder -Lines @(
        '$ledger = $env:OPTCAP_LEDGER',
        '$ticks = [int]$env:OPTCAP_TICKS',
        'function Get-Stamp { return [string][long]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) }',
        'Add-Content -LiteralPath $ledger -Value (''start '' + $PID + '' '' + (Get-Stamp)) -Encoding Ascii',
        'for ($i = 1; $i -le $ticks; $i++) {',
        '    [Console]::Out.WriteLine(''tick '' + $i)',
        '    [Console]::Out.Flush()',
        '    Add-Content -LiteralPath $ledger -Value (''tick '' + $i + '' '' + (Get-Stamp)) -Encoding Ascii',
        '    Start-Sleep -Seconds 1',
        '}',
        'Add-Content -LiteralPath $ledger -Value (''done '' + (Get-Stamp)) -Encoding Ascii',
        'exit 0'
    )
    # the process the line starts: a .cmd that runs the holder as its own child and waits for it, so killing the .cmd alone leaves
    # the holder running with both pipes, which is what ending a Nuitka onefile bootstrap alone leaves
    Write-CrLf -Path (Join-Path $dir 'dist\optcap_stand_in.cmd') -Lines @(
        '@echo off',
        'powershell -NoProfile -ExecutionPolicy Bypass -File "%OPTCAP_HOLDER%"',
        'exit /b %ERRORLEVEL%'
    )
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in @(
        '@echo off', 'setlocal',
        ('set "RESULT=' + (Join-Path $dir '~driver_result.txt') + '"'),
        ('set "OPTCAP_LEDGER=' + $ledger + '"'),
        ('set "OPTCAP_HOLDER=' + $holder + '"'),
        ('set "OPTCAP_TICKS=' + $Scenario.Ticks + '"'),
        'set "HP_OPTBUILD_VERIFY_EXIT="', 'set "HP_OPTBUILD_EXE="', 'set "HP_APP_ARGS="',
        'set "HP_OPTBUILD_TMP=optcap_stand_in.cmd"',
        '>"%RESULT%" echo START'
    )) { [void]$lines.Add($l) }
    foreach ($l in $Block) { [void]$lines.Add($l) }
    foreach ($l in @(
        '>>"%RESULT%" echo VERIFY_EXIT=%HP_OPTBUILD_VERIFY_EXIT%',
        '>>"%RESULT%" echo END',
        'exit /b 0'
    )) { [void]$lines.Add($l) }
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines $lines.ToArray()
    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines @('@echo off', 'call ~driver.bat > ~driver_console.txt 2>&1 < nul', 'exit /b %ERRORLEVEL%')
    $launch = Invoke-Launch -Dir $dir -LaunchName '~driver_launch.cmd' -LimitMs 150000
    $left = Get-LeftoverProcesses -Marker $holder
    return [pscustomobject]@{
        Finished = $launch.Finished; ExitCode = $launch.ExitCode; Seconds = $launch.Seconds; Error = $launch.Error
        Console = (Read-Text (Join-Path $dir '~driver_console.txt')); Result = (Read-Text (Join-Path $dir '~driver_result.txt'))
        Ledger = (Read-Text $ledger); LeftoverChecked = $left.Checked; Leftover = $left.Found
    }
}

function Get-ScenarioResult {
    param($Scenario)
    $problems = New-Object System.Collections.ArrayList
    $details = [ordered]@{ scenario = $Scenario.Name }
    $block = Get-BatBlock -StartLine 'set "HP_OPTBUILD_VERIFY_EXIT=-1"' -EndLine 'if not "%HP_OPTBUILD_VERIFY_EXIT%"=="0" ('
    if ($null -eq $block) {
        [void]$problems.Add('the lines that run the optimized build verification are not in run_setup.bat, so there is no run to test')
        $details['blockFound'] = $false
        return [pscustomobject]@{ Problems = @($problems); Details = $details }
    }
    $run = Invoke-OptCapScenario -Scenario $Scenario -Block $block
    $found = @(Get-OptCapProblems -Scenario $Scenario.Name -Finished ([bool]$run.Finished) -Seconds ([int]$run.Seconds) -ResultText $run.Result `
        -LedgerText $run.Ledger -LeftoverChecked ([bool]$run.LeftoverChecked) -Leftover @($run.Leftover) -ExpectExit $Scenario.ExpectExit `
        -ExpectDone ([bool]$Scenario.ExpectDone) -MinTicks ([int]$Scenario.MinTicks) -MinSpan ([double]$Scenario.MinSpan) -MaxSpan ([double]$Scenario.MaxSpan) `
        -MaxSeconds ([int]$Scenario.MaxSeconds))
    Add-Evidence -Title ($Scenario.Name + ' (' + $run.Seconds + ' s, driver exit ' + $run.ExitCode + ')') `
        -Text ("--- result`n" + $run.Result + "`n--- ledger`n" + $run.Ledger + "`n--- left running`n" + (@($run.Leftover) -join "`n") + "`n--- console`n" + $run.Console)
    foreach ($f in $found) { [void]$problems.Add($f) }
    $ticks = @([regex]::Matches($run.Ledger, '(?m)^tick (\d+) (\d+)\s*$'))
    $span = 0.0
    if ($ticks.Count -ge 2) { $span = ([double]$ticks[$ticks.Count - 1].Groups[2].Value - [double]$ticks[0].Groups[2].Value) / 1000.0 }
    $details['finished'] = [bool]$run.Finished
    $details['seconds'] = $run.Seconds
    $details['driverExit'] = $run.ExitCode
    $details['ticks'] = $ticks.Count
    $details['programSeconds'] = [math]::Round($span, 1)
    $details['reachedLastLine'] = [bool]($run.Ledger -match '(?m)^done \d+\s*$')
    $details['verifyExit'] = (([regex]::Match($run.Result, '(?m)^VERIFY_EXIT=(-?\d+)\s*$')).Groups[1].Value)
    $details['leftRunning'] = @($run.Leftover).Count
    if ($run.Error) { $details['error'] = $run.Error }
    if ($found.Count -gt 0) { $details['problems'] = @($found) }
    return [pscustomobject]@{ Problems = @($problems); Details = $details }
}

$capRun  = Get-ScenarioResult -Scenario $scenarios[0]
$exitRun = Get-ScenarioResult -Scenario $scenarios[1]

$problemsAll = @(@($capRun.Problems) + @($exitRun.Problems))
$pass = [bool]($problemsAll.Count -eq 0)
$details = [ordered]@{ cap = $capRun.Details; exit = $exitRun.Details }
if (-not $pass) { $details['problems'] = @($problemsAll) }
Write-NdjsonRow ([ordered]@{ id = 'self.optbuild.cap'; req = 'REQ-018.36'; pass = $pass
    desc = 'The verification run of the optimized build ends after 30 seconds whatever the program prints, ends the program it started, and passes a program that ends by itself'
    details = $details })

if (-not $pass) { exit 1 }
exit 0
