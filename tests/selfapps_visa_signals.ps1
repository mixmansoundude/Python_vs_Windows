# ASCII only
# selfapps_visa_signals.ps1 - Item 111 (README REQ-008.14): in a run with NOINPUT or HP_NONINTERACTIVE set, the question of
# REQ-008.7 (install the NI-VISA driver although every import of pyvisa or visa is in a subfolder) is answered with no, without
# waiting.
#
# Why a row of its own. :visa_subfolder_gate tests four signals in a fixed order before it reads the console: a test answer, the
# CI marker HP_CI_LANE, NOINPUT and HP_NONINTERACTIVE. tests/selfapps_pyvisa_subfolder.ps1 runs real bootstraps, and every one of
# them is a CI run that carries HP_CI_LANE (the script sets it when none is set), so only the CI marker was ever shown to skip the
# wait; the two other signals could be deleted from the batch file and no row would turn red. tests/selfapps_offers_noninteractive.ps1
# does the same one signal at a time for the four elective offers of REQ-018.9, and the NI-VISA question is not one of them.
#
# Three rows, one driver each. The real block is cut out of run_setup.bat (from :visa_subfolder_gate up to :dll_bundle_recover),
# wrapped in a small batch file and run with cmd.exe and closed standard input, with every variable the block reads cleared first
# (a variable inherited from the runner could decide for it) and exactly one signal set:
#   noinput  NOINPUT=1 alone          -> the block must decline and must not read the console
#   nonint   HP_NONINTERACTIVE=1 alone -> the block must decline and must not read the console
#   control  no signal                -> the block must read the console exactly once, with a wait of 30 seconds that defaults to N
# The one line that reads the console, the line that starts with choice, is replaced by a call that records its arguments and
# answers Y (errorlevel 1). That answer is what gives the two signal rows their meaning: if the block read the console in spite of
# the signal it would take the Y, accept and say so, and the control shows that without a signal the same stub is reached and its
# Y is honored, so a signal row cannot pass because the block never asked in any case. A stub that answered N would make a block
# that waits and a block that does not wait end in the same decline.
#
# Two kinds of evidence per run, so that one cannot vouch for the other: what the driver recorded from the block's own result
# (NEED_VISA and HP_VISA_DECISION after the call, and how many times the console was read) and the line the block wrote to its log.
#
# derived requirement: ids and tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell), and the judging function takes plain values and returns a list of problems
# (tests/test_visa_signals.py runs it through a real pwsh on synthetic runs).
#
# Limit, stated so that nobody reads more into the rows than they show: the rows prove the gate. That the main flow calls the gate
# whenever the scan answered 2 is shown by tests/selfapps_pyvisa_subfolder.ps1 (a real bootstrap, with the CI marker).
#
# Lane: contract-uv (the lane with the most wall-clock headroom; the gate is the same on every lane). Gating from its first run
# (AGENTS.md "New tests gate immediately"): a red row holds the aggregate check. Three driver runs, seconds each.
# Emits: self.nivisa.signals.noinput, self.nivisa.signals.nonint, self.nivisa.signals.control
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

# Used when the three rows share one outcome (a skip, or an input that is missing); the real emissions below are literal too.
function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.signals.noinput'; req = 'REQ-008.14'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.signals.nonint'; req = 'REQ-008.14'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.signals.control'; req = 'REQ-008.14'; pass = $Pass; desc = $Desc; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'NI-VISA question with NOINPUT or HP_NONINTERACTIVE (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'NI-VISA question with NOINPUT or HP_NONINTERACTIVE: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------------------------------------------------
$evidencePath = Join-Path $here '~visa_signals_evidence.txt'
Set-Content -LiteralPath $evidencePath -Value 'selfapps_visa_signals.ps1 evidence (printable ASCII only)' -Encoding Ascii

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

# Appends a titled block to the evidence file the workflow uploads; non-ASCII becomes '?', long texts are cut.
function Add-Evidence {
    param([string]$Title, [string]$Text, [int]$MaxLines = 120)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        $clean = ($l -replace '[^\x20-\x7E]', '?')
        if ($clean.Length -gt 220) { $clean = $clean.Substring(0, 220) }
        [void]$keep.Add($clean)
        if ($keep.Count -ge $MaxLines) { break }
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

# Lines from the line that is exactly StartLabel up to, not including, the line that is exactly EndLabel.
function Get-BatBlock {
    param([string]$StartLabel, [string]$EndLabel)
    $start = -1
    for ($i = 0; $i -lt $batLines.Length; $i++) {
        if ($batLines[$i].Trim() -eq $StartLabel) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = -1
    for ($j = $start + 1; $j -lt $batLines.Length; $j++) {
        if ($batLines[$j].Trim() -eq $EndLabel) { $end = $j; break }
    }
    if ($end -lt 0) { return $null }
    return $batLines[$start..($end - 1)]
}

# ---------------------------------------------------------------------------------------------------------------------
# the scenarios, and what the block must do in each
# ---------------------------------------------------------------------------------------------------------------------
# Signal is the one line the driver adds to set the signal (nothing for the control), ExpectRead says whether the block may
# reach the console. tests/test_visa_signals.py pins every text below to run_setup.bat.
$headingPattern  = 'The NI-VISA driver looks needed only by a file in a subfolder:'
$acceptedPattern = 'NI-VISA install for a subfolder-only import: accepted\.'
$declinedPattern = '\[VISA\] skipped \(subfolder_only\)'

$scenarios = @(
    [pscustomobject]@{ Name = 'noinput'; Signal = 'set "NOINPUT=1"'; ExpectRead = $false },
    [pscustomobject]@{ Name = 'nonint'; Signal = 'set "HP_NONINTERACTIVE=1"'; ExpectRead = $false },
    [pscustomobject]@{ Name = 'control'; Signal = ''; ExpectRead = $true }
)

# ---------------------------------------------------------------------------------------------------------------------
# judging: plain values in, a list of problems out (nothing when the run shows what the scenario must show)
# ---------------------------------------------------------------------------------------------------------------------
# The decision the block itself produced, from what the driver recorded after the call: accepted (NEED_VISA is 1), declined
# (NEED_VISA is still 2) or unknown.
function Get-VisaDecision {
    param([string]$ResultText)
    if ($ResultText -match '(?m)^NEED_VISA=1\s*$') { return 'accepted' }
    if ($ResultText -match '(?m)^NEED_VISA=2\s*$') { return 'declined' }
    return 'unknown'
}

function Get-SignalProblems {
    param([string]$Scenario, [bool]$Finished, [string]$ResultText, [string]$LogText, [string]$ConsoleText, [string]$ChoiceArgsText,
          [string]$HeadingPattern, [string]$AcceptedPattern, [string]$DeclinedPattern, [bool]$ExpectRead)
    $out = New-Object System.Collections.ArrayList
    $tag = "NI-VISA question ${Scenario}"
    if (-not $Finished) { [void]$out.Add("${tag}: the driver did not finish within the time limit"); return $out.ToArray() }
    if ($ResultText -notmatch '(?m)^END\s*$') { [void]$out.Add("${tag}: the driver did not reach its end, so the block ended the run early"); return $out.ToArray() }
    $headings = [regex]::Matches($ConsoleText, $HeadingPattern).Count
    if ($headings -ne 1) { [void]$out.Add("${tag}: the question's heading was printed ${headings} time(s), expected 1") }
    $readLines = @(($ChoiceArgsText -split "`r?`n") | Where-Object { $_.Trim() })
    $decision = Get-VisaDecision -ResultText $ResultText
    $acceptedLines = [regex]::Matches($LogText, $AcceptedPattern).Count
    $declinedLines = [regex]::Matches($LogText, $DeclinedPattern).Count
    if ($ExpectRead) {
        # the control: no signal, so the console is read once, for at most 30 seconds, and the stub's Y is honored
        if ($readLines.Count -eq 0) {
            [void]$out.Add("${tag}: with no signal the block never reached its choice line, so the signal rows prove nothing")
        } elseif ($readLines.Count -ne 1) {
            [void]$out.Add("${tag}: the block read the console $($readLines.Count) times, expected once")
        } else {
            if ($readLines[0] -notmatch '(?i)/C\s+YN(\s|$)') { [void]$out.Add("${tag}: the choice line does not offer exactly Y and N (/C YN): $($readLines[0].Trim())") }
            if ($readLines[0] -notmatch '(?i)/T\s+30(\s|$)') { [void]$out.Add("${tag}: the choice line does not wait for 30 seconds (/T 30): $($readLines[0].Trim())") }
            if ($readLines[0] -notmatch '(?i)/D\s+N(\s|$)') { [void]$out.Add("${tag}: the choice line does not default to N after the wait (/D N): $($readLines[0].Trim())") }
        }
        if ($decision -ne 'accepted') { [void]$out.Add("${tag}: the answer Y was not honored: the gate ${decision}, expected accepted") }
        if ($ResultText -notmatch '(?m)^DECISION=Y\s*$') { [void]$out.Add("${tag}: the remembered decision is not Y") }
        if ($acceptedLines -ne 1) { [void]$out.Add("${tag}: the log holds ${acceptedLines} accepted line(s), expected 1") }
        if ($declinedLines -ne 0) { [void]$out.Add("${tag}: the log holds ${declinedLines} declined line(s), expected 0") }
    } else {
        # a signal: no console read at all (so no wait), and the decline, once, with nothing accepted
        if ($readLines.Count -gt 0) {
            [void]$out.Add("${tag}: the block read the console $($readLines.Count) time(s) in spite of the signal, so it would have waited: $($readLines[0].Trim())")
        }
        if ($decision -ne 'declined') {
            if ($decision -eq 'accepted') {
                [void]$out.Add("${tag}: the gate accepted although a signal says nobody can answer")
            } else {
                [void]$out.Add("${tag}: the gate ${decision}, expected declined")
            }
        }
        if ($ResultText -notmatch '(?m)^DECISION=N\s*$') { [void]$out.Add("${tag}: the remembered decision is not N") }
        if ($declinedLines -ne 1) { [void]$out.Add("${tag}: the log holds ${declinedLines} declined line(s), expected 1") }
        if ($acceptedLines -ne 0) { [void]$out.Add("${tag}: the log holds ${acceptedLines} accepted line(s), expected 0") }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# the driver: the real block in a small batch file with stubs for what it calls
# ---------------------------------------------------------------------------------------------------------------------
# The driver defines what the cut-out block expects (LOG, RESULT, a :log that only appends to the log), clears every variable the
# block reads, sets the scenario's one signal, calls the block and records the verdict. The console read, the one line that starts
# with choice, becomes a call of a stub that appends its arguments to a file and answers 1 (Y). Standard input is closed by the
# launch file. The real `where choice` line runs unchanged: choice.exe is part of Windows, and a machine without it would show
# in the control as a block that never reached its choice line.
function New-SignalDriver {
    param([string]$Dir, $Scenario, [string[]]$Block)
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in @(
        '@echo off', 'setlocal',
        ('set "LOG=' + (Join-Path $Dir '~driver.log') + '"'),
        ('set "RESULT=' + (Join-Path $Dir '~driver_result.txt') + '"'),
        ('set "CHOICE_ARGS=' + (Join-Path $Dir '~choice_args.txt') + '"'),
        'set "CHOICE_RC=1"',
        'set "NEED_VISA=2"', 'set "HP_VISA_DECISION="', 'set "HP_VISA_WHERE=subfolder\old_program.py"', 'set "HP_VISA_CHOICE="',
        'set "HP_VISA_RAW="', 'set "HP_VISA_T="', 'set "HP_TEST_VISA_ANSWER="', 'set "HP_TEST_FORCE_INTERACTIVE_VISA="',
        'set "HP_CI_LANE="', 'set "NOINPUT="', 'set "HP_NONINTERACTIVE="'
    )) { [void]$lines.Add($l) }
    if ($Scenario.Signal) { [void]$lines.Add($Scenario.Signal) }
    foreach ($l in @(
        '>"%RESULT%" echo START',
        'call :visa_subfolder_gate',
        '>>"%RESULT%" echo NEED_VISA=%NEED_VISA%',
        '>>"%RESULT%" echo DECISION=%HP_VISA_DECISION%',
        '>>"%RESULT%" echo END',
        'exit /b 0'
    )) { [void]$lines.Add($l) }
    foreach ($l in $Block) {
        if ($l -match '^\s*choice\s') { [void]$lines.Add(($l -replace '^(\s*)choice\s+', '$1call :choice_stub ')) } else { [void]$lines.Add($l) }
    }
    foreach ($l in @(
        ':log', 'setlocal', 'set "MSG=%~1"', '>>"%LOG%" echo %MSG%', 'endlocal', 'exit /b 0',
        ':choice_stub', '>>"%CHOICE_ARGS%" echo %*', 'exit /b %CHOICE_RC%'
    )) { [void]$lines.Add($l) }
    return $lines.ToArray()
}

$work = Join-Path $here '~selftest_visasignals'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Invoke-SignalScenario {
    param($Scenario, [string[]]$Block)
    $dir = Join-Path $work $Scenario.Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines (New-SignalDriver -Dir $dir -Scenario $Scenario -Block $Block)
    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines @('@echo off', 'call ~driver.bat > ~driver_console.txt 2>&1 < nul', 'exit /b %ERRORLEVEL%')
    $launch = Invoke-Launch -Dir $dir -LaunchName '~driver_launch.cmd' -LimitMs 180000
    return [pscustomobject]@{
        Finished = $launch.Finished; ExitCode = $launch.ExitCode; Seconds = $launch.Seconds; Error = $launch.Error
        Console = (Read-Text (Join-Path $dir '~driver_console.txt')); Log = (Read-Text (Join-Path $dir '~driver.log'))
        Result = (Read-Text (Join-Path $dir '~driver_result.txt')); ChoiceArgs = (Read-Text (Join-Path $dir '~choice_args.txt'))
    }
}

# One scenario: one driver run. Returns the problems and the details of the scenario's row.
function Get-ScenarioResult {
    param($Scenario)
    $problems = New-Object System.Collections.ArrayList
    $details = [ordered]@{ scenario = $Scenario.Name }
    $block = Get-BatBlock -StartLabel ':visa_subfolder_gate' -EndLabel ':dll_bundle_recover'
    if ($null -eq $block) {
        [void]$problems.Add('the label :visa_subfolder_gate (up to :dll_bundle_recover) is not in run_setup.bat, so there is no question to test')
        $details['blockFound'] = $false
        return [pscustomobject]@{ Problems = @($problems); Details = $details }
    }
    $run = Invoke-SignalScenario -Scenario $Scenario -Block $block
    $found = @(Get-SignalProblems -Scenario $Scenario.Name -Finished ([bool]$run.Finished) -ResultText $run.Result -LogText $run.Log -ConsoleText $run.Console `
        -ChoiceArgsText $run.ChoiceArgs -HeadingPattern $headingPattern -AcceptedPattern $acceptedPattern -DeclinedPattern $declinedPattern -ExpectRead ([bool]$Scenario.ExpectRead))
    Add-Evidence -Title ($Scenario.Name + ' (' + $run.Seconds + ' s, driver exit ' + $run.ExitCode + ')') `
        -Text ("--- result`n" + $run.Result + "`n--- log`n" + $run.Log + "`n--- choice args`n" + $run.ChoiceArgs + "`n--- console`n" + $run.Console) -MaxLines 70
    foreach ($f in $found) { [void]$problems.Add($f) }
    $details['finished'] = [bool]$run.Finished
    $details['seconds'] = $run.Seconds
    $details['driverExit'] = $run.ExitCode
    $details['decision'] = (Get-VisaDecision -ResultText $run.Result)
    $details['consoleReads'] = @(($run.ChoiceArgs -split "`r?`n") | Where-Object { $_.Trim() }).Count
    $details['choiceArgs'] = ([string]$run.ChoiceArgs).Trim()
    if ($run.Error) { $details['error'] = $run.Error }
    if ($found.Count -gt 0) { $details['problems'] = @($found); $details['result'] = @(($run.Result -split "`r?`n") | Where-Object { $_ }) }
    return [pscustomobject]@{ Problems = @($problems); Details = $details }
}

$allPass = $true

$noinput = Get-ScenarioResult -Scenario $scenarios[0]
$nonint  = Get-ScenarioResult -Scenario $scenarios[1]
$control = Get-ScenarioResult -Scenario $scenarios[2]

$pass = [bool](@($noinput.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.signals.noinput'; req = 'REQ-008.14'; pass = $pass
    desc = 'NOINPUT alone answers the NI-VISA subfolder question with no and the console is not read'; details = $noinput.Details })

$pass = [bool](@($nonint.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.signals.nonint'; req = 'REQ-008.14'; pass = $pass
    desc = 'HP_NONINTERACTIVE alone answers the NI-VISA subfolder question with no and the console is not read'; details = $nonint.Details })

$pass = [bool](@($control.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.signals.control'; req = 'REQ-008.14'; pass = $pass
    desc = 'With no signal the NI-VISA subfolder question reads the console once, for 30 seconds at most, and honors Y (the control)'; details = $control.Details })

if (-not $allPass) { exit 1 }
exit 0
