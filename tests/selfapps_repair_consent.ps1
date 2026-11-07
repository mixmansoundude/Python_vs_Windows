# ASCII only
# selfapps_repair_consent.ps1 - Item 97 (README REQ-018.1 and REQ-018.2): the --hidden-import repair loop asks before it
# starts the program again.
#
# History. After a failed EXE verification run, :hidden_import_recover started dist\<env>.exe again to read the error text,
# then once more after each repair rebuild (at most three), announcing each start with a warning line and asking nothing.
# README REQ-018.1 allows one automatic start per invocation and REQ-018.2 asks for the user's explicit consent, in a
# prompt that names the risk, before any other. A program that is not safe to run twice (it overwrites a file, sends a
# request, appends to a log) ran up to four more times without a question. The maintainer decided (2026-10-31, open
# question 7) on a first pass: ONE question before the loop's first extra start, default No after 30 seconds, no waiting
# and no repair in a non-interactive run, and HP_PVW_KNOWN_IDEMPOTENT (the user's own word that the program is safe to run
# more than once) counts as consent. The user's other elective offers keep their own questions.
#
# Two kinds of rows, because the gate is small and the bootstrap around it is slow:
#   gate rows   cut :hidden_import_consent out of run_setup.bat (up to :run_exe_smokerun), wrap it in a tiny driver batch file
#               with a stub :log, and run it with cmd.exe and closed standard input, one scenario per environment. These
#               prove the decision table without building anything: each non-interactive signal alone declines without
#               reading the console, the control run with no signal takes the interactive branch, a test answer wins over
#               the signals, HP_PVW_KNOWN_IDEMPOTENT asks nothing, and the answer given once is kept for the second call
#               the batch makes after a DLL repair. The driver clears the five variables the block reads and writes them
#               back out after the scenario's own set lines, so a row cannot pass on an environment it did not intend.
#   run rows    two real bootstraps of one small program whose first EXE run fails (ModuleNotFoundError for an installed
#               package imported by name at run time). Each start appends a line to a ledger whose ABSOLUTE path comes from
#               the environment (REPAIR_LEDGER; the repair loop runs the EXE from dist\). declined: a non-interactive run
#               must start the program exactly once, show the question with the risk, rebuild nothing and say it did not
#               ask. accepted: with the test answer yes the extra starts happen, and only AFTER the log says the repair was
#               accepted (the consent line comes before the loop's announcement and before the first --hidden-import).
#               Together they show that an extra start follows consent and nothing else: without it the ledger holds one
#               line. The counts also rest on Item 96 (the failure hint no longer starts the program a third time).
#
# Tags. Row tags are literals at each call site (the requirement-trace tests read text). The two run rows and the gate rows
# carry the README shalls this behavior is, REQ-018.1 and REQ-018.2; the known-idempotent row carries REQ-005.13 (the flag is
# the user's declaration that the script is safe to run more than once). The README does not yet list the repair question
# among the non-interactive declines of REQ-018.9 or the settings of REQ-018.35; the PR text proposes that wording.
#
# derived requirement: ids and tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell). The skip loop below uses a map on purpose; the real emissions are literal.
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"). Ten driver runs (seconds each, the control
# run may wait for the 30 second default of choice) and two default bootstraps.
# Emits: self.repair.gate.noinput, self.repair.gate.nonint, self.repair.gate.cilane, self.repair.gate.control,
#        self.repair.gate.answers, self.repair.gate.idempotent, self.repair.gate.once,
#        self.repair.consent.declined, self.repair.consent.accepted
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

$allIds = @(
    'self.repair.gate.noinput', 'self.repair.gate.nonint', 'self.repair.gate.cilane', 'self.repair.gate.control',
    'self.repair.gate.answers', 'self.repair.gate.idempotent', 'self.repair.gate.once',
    'self.repair.consent.declined', 'self.repair.consent.accepted'
)
$reqOf = @{
    'self.repair.gate.noinput' = 'REQ-018.2'; 'self.repair.gate.nonint' = 'REQ-018.2'; 'self.repair.gate.cilane' = 'REQ-018.2'
    'self.repair.gate.control' = 'REQ-018.2'; 'self.repair.gate.answers' = 'REQ-018.2'; 'self.repair.gate.idempotent' = 'REQ-005.13'
    'self.repair.gate.once' = 'REQ-018.2'; 'self.repair.consent.declined' = 'REQ-018.1, REQ-018.2'; 'self.repair.consent.accepted' = 'REQ-018.2'
}
function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = $reqOf[$rowId]; pass = $Pass; desc = $Desc; details = $Details })
    }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'Repair loop consent (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'Repair loop consent: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------------------------------------------------
$evidencePath = Join-Path $here '~repair_consent_evidence.txt'
Set-Content -LiteralPath $evidencePath -Value 'selfapps_repair_consent.ps1 evidence (printable ASCII only)' -Encoding Ascii

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

# A few log lines that explain a red row.
function Get-Excerpt {
    param([string]$Text, [string]$Pattern, [int]$Max = 24)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match $Pattern) {
            $clean = ($l -replace '[^\x20-\x7E]', '?')
            if ($clean.Length -gt 160) { $clean = $clean.Substring(0, 160) }
            [void]$keep.Add($clean)
            if ($keep.Count -ge $Max) { break }
        }
    }
    return $keep.ToArray()
}

# The wording the batch shows and logs. tests/test_repair_consent.py pins every one of them to run_setup.bat.
$headingText = 'The check run of your program failed, exit code'
$markerText  = 'running it twice could cause harm'
$promptText  = 'Start your program again to try the repair?'
$logPatterns = [ordered]@{
    auto       = 'Repair loop: not asked in a non-interactive run'
    declined   = 'Repair loop: declined\.'
    accepted   = 'Repair loop: accepted\.'
    idempotent = 'Repair loop: HP_PVW_KNOWN_IDEMPOTENT is set'
    remembered = 'Repair loop: using the answer given earlier in this run'
}

function Get-Count {
    param([string]$Text, [string]$Pattern)
    return [regex]::Matches($Text, $Pattern).Count
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

$allPass = $true

# ---------------------------------------------------------------------------------------------------------------------
# gate rows: the real :hidden_import_consent block, run by cmd.exe in a tiny driver
# ---------------------------------------------------------------------------------------------------------------------
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

$consentBlock = Get-BatBlock -StartLabel ':hidden_import_consent' -EndLabel ':run_exe_smokerun'

# The five variables the block reads, in the order the driver lists them.
$envNames = @('HP_CI_LANE', 'NOINPUT', 'HP_NONINTERACTIVE', 'HP_TEST_REPAIR_ANSWER', 'HP_PVW_KNOWN_IDEMPOTENT')

function Get-EnvString {
    param([hashtable]$State)
    return ('CI:{0};NOINPUT:{1};NONINT:{2};ANSWER:{3};IDEM:{4}' -f $State['HP_CI_LANE'], $State['NOINPUT'], $State['HP_NONINTERACTIVE'], $State['HP_TEST_REPAIR_ANSWER'], $State['HP_PVW_KNOWN_IDEMPOTENT'])
}

# The driver defines what the cut-out block expects (LOG, HP_EXE_EXIT, a :log that only appends to the log), clears the five
# variables, then for each step applies the step's set lines, writes the variables it sees, calls the block and writes
# whether the repair was allowed. Standard input is closed by the launch file.
function New-GateDriver {
    param([string]$Dir, [object[]]$Steps)
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in @(
        '@echo off', 'setlocal',
        ('set "LOG=' + (Join-Path $Dir '~driver.log') + '"'),
        ('set "RESULT=' + (Join-Path $Dir '~driver_result.txt') + '"'),
        'set "HP_EXE_EXIT=1"',
        'set "HP_HIC_ANSWER="', 'set "HP_HIC_ALLOWED="',
        'set "HP_CI_LANE="', 'set "NOINPUT="', 'set "HP_NONINTERACTIVE="', 'set "HP_TEST_REPAIR_ANSWER="', 'set "HP_PVW_KNOWN_IDEMPOTENT="',
        '>"%RESULT%" echo START'
    )) { [void]$lines.Add($l) }
    $n = 0
    foreach ($step in $Steps) {
        $n++
        foreach ($k in $step.Set.Keys) { [void]$lines.Add(('set "{0}={1}"' -f $k, $step.Set[$k])) }
        [void]$lines.Add('>>"%RESULT%" echo ENV' + $n + '=CI:%HP_CI_LANE%;NOINPUT:%NOINPUT%;NONINT:%HP_NONINTERACTIVE%;ANSWER:%HP_TEST_REPAIR_ANSWER%;IDEM:%HP_PVW_KNOWN_IDEMPOTENT%')
        [void]$lines.Add('call :hidden_import_consent')
        [void]$lines.Add('if defined HP_HIC_ALLOWED >>"%RESULT%" echo STEP' + $n + '=allowed')
        [void]$lines.Add('if not defined HP_HIC_ALLOWED >>"%RESULT%" echo STEP' + $n + '=not_allowed')
    }
    foreach ($l in @('>>"%RESULT%" echo END', 'exit /b 0')) { [void]$lines.Add($l) }
    foreach ($l in $consentBlock) { [void]$lines.Add($l) }
    foreach ($l in @(':log', 'setlocal', 'set "MSG=%~1"', '>>"%LOG%" echo %MSG%', 'endlocal', 'exit /b 0')) { [void]$lines.Add($l) }
    return $lines.ToArray()
}

$gateWork = Join-Path $here '~selftest_repairgate'
if (Test-Path -LiteralPath $gateWork) { Remove-Item -LiteralPath $gateWork -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $gateWork | Out-Null

# What each scenario must show. Steps are applied in order to one driver run; Allowed has one entry per step; Headings is how
# many times the question's heading is printed; Prompt 'absent' means the interactive prompt text must not be printed and
# 'record' means it is only recorded (choice with closed standard input is not asserted); Logs is the exact count of each log line.
function New-Step { param([hashtable]$Set) return [ordered]@{ Set = $Set } }
$none = @{ auto = 0; declined = 0; accepted = 0; idempotent = 0; remembered = 0 }
function New-Logs { param([hashtable]$Over) $h = @{}; foreach ($k in $none.Keys) { $h[$k] = $none[$k] }; foreach ($k in $Over.Keys) { $h[$k] = $Over[$k] }; return $h }
$gateScenarios = @(
    @{ Name = 'noinput'; Steps = @(New-Step @{ NOINPUT = '1' }); Allowed = @('not_allowed'); Headings = 1; Prompt = 'absent'; Logs = (New-Logs @{ auto = 1 }) },
    @{ Name = 'nonint'; Steps = @(New-Step @{ HP_NONINTERACTIVE = '1' }); Allowed = @('not_allowed'); Headings = 1; Prompt = 'absent'; Logs = (New-Logs @{ auto = 1 }) },
    @{ Name = 'cilane'; Steps = @(New-Step @{ HP_CI_LANE = 'repair' }); Allowed = @('not_allowed'); Headings = 1; Prompt = 'absent'; Logs = (New-Logs @{ auto = 1 }) },
    @{ Name = 'control'; Steps = @(New-Step @{}); Allowed = @('not_allowed'); Headings = 1; Prompt = 'record'; Logs = (New-Logs @{ declined = 1 }) },
    @{ Name = 'answer_yes'; Steps = @(New-Step @{ HP_TEST_REPAIR_ANSWER = 'Y' }); Allowed = @('allowed'); Headings = 1; Prompt = 'absent'; Logs = (New-Logs @{ accepted = 1 }) },
    @{ Name = 'answer_no'; Steps = @(New-Step @{ HP_TEST_REPAIR_ANSWER = 'N' }); Allowed = @('not_allowed'); Headings = 1; Prompt = 'absent'; Logs = (New-Logs @{ declined = 1 }) },
    @{ Name = 'answer_beats_signal'; Steps = @(New-Step @{ HP_CI_LANE = 'repair'; NOINPUT = '1'; HP_NONINTERACTIVE = '1'; HP_TEST_REPAIR_ANSWER = 'Y' }); Allowed = @('allowed'); Headings = 1; Prompt = 'absent'; Logs = (New-Logs @{ accepted = 1 }) },
    @{ Name = 'idempotent'; Steps = @(New-Step @{ HP_CI_LANE = 'repair'; HP_PVW_KNOWN_IDEMPOTENT = '1' }); Allowed = @('allowed'); Headings = 0; Prompt = 'absent'; Logs = (New-Logs @{ idempotent = 1 }) },
    @{ Name = 'once_yes'; Steps = @((New-Step @{ HP_TEST_REPAIR_ANSWER = 'Y' }), (New-Step @{ HP_TEST_REPAIR_ANSWER = ''; HP_CI_LANE = 'repair' })); Allowed = @('allowed', 'allowed'); Headings = 1; Prompt = 'absent'; Logs = (New-Logs @{ accepted = 1; remembered = 1 }) },
    @{ Name = 'once_no'; Steps = @((New-Step @{ HP_CI_LANE = 'repair' }), (New-Step @{ HP_CI_LANE = ''; HP_TEST_REPAIR_ANSWER = 'Y' })); Allowed = @('not_allowed', 'not_allowed'); Headings = 1; Prompt = 'absent'; Logs = (New-Logs @{ auto = 1; remembered = 1 }) }
)

function Invoke-GateScenario {
    param($Scenario)
    $dir = Join-Path $gateWork $Scenario.Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines (New-GateDriver -Dir $dir -Steps $Scenario.Steps)
    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines @('@echo off', 'call ~driver.bat > ~driver_console.txt 2>&1 < nul', 'exit /b %ERRORLEVEL%')
    $launch = Invoke-Launch -Dir $dir -LaunchName '~driver_launch.cmd' -LimitMs 180000
    return [pscustomobject]@{
        Name = $Scenario.Name; Finished = $launch.Finished; ExitCode = $launch.ExitCode; Seconds = $launch.Seconds; Error = $launch.Error
        Console = (Read-Text (Join-Path $dir '~driver_console.txt')); Log = (Read-Text (Join-Path $dir '~driver.log')); Result = (Read-Text (Join-Path $dir '~driver_result.txt'))
    }
}

# What is wrong with one gate run, as short sentences; nothing when the run shows what the scenario expects.
function Get-GateProblems {
    param($Scenario, $Run)
    $out = New-Object System.Collections.ArrayList
    $name = $Scenario.Name
    if (-not $Run.Finished) { [void]$out.Add("${name}: the driver did not finish within the time limit"); return $out.ToArray() }
    if ($Run.Result -notmatch 'END') { [void]$out.Add("${name}: the driver did not reach its end, so the block ended the run early (exit code $($Run.ExitCode))"); return $out.ToArray() }
    # the environment the block really saw, step by step
    $state = @{}
    foreach ($k in $envNames) { $state[$k] = '' }
    $n = 0
    foreach ($step in $Scenario.Steps) {
        $n++
        foreach ($k in $step.Set.Keys) { $state[$k] = [string]$step.Set[$k] }
        $want = Get-EnvString $state
        $m = [regex]::Match($Run.Result, "(?m)^ENV${n}=(.*?)\s*$")
        if (-not $m.Success) { [void]$out.Add("${name}: step ${n} wrote no environment line"); continue }
        if ($m.Groups[1].Value -ne $want) { [void]$out.Add("${name}: step ${n} started with [$($m.Groups[1].Value)], expected [$want]") }
        $a = [regex]::Match($Run.Result, "(?m)^STEP${n}=(\w+)\s*$")
        if (-not $a.Success) { [void]$out.Add("${name}: step ${n} wrote no verdict"); continue }
        if ($a.Groups[1].Value -ne $Scenario.Allowed[$n - 1]) { [void]$out.Add("${name}: step ${n} was $($a.Groups[1].Value), expected $($Scenario.Allowed[$n - 1])") }
    }
    $headings = Get-Count $Run.Console ([regex]::Escape($headingText))
    if ($headings -ne $Scenario.Headings) { [void]$out.Add("${name}: the question's heading was printed ${headings} time(s), expected $($Scenario.Headings)") }
    if ($Scenario.Headings -ge 1 -and $headings -ge 1) {
        $at = $Run.Console.IndexOf($headingText)
        if ($Run.Console.IndexOf($markerText, $at) -lt 0) { [void]$out.Add("${name}: the question does not say '${markerText}' after its heading") }
    }
    $promptShown = $Run.Console.Contains($promptText)
    if ($Scenario.Prompt -eq 'absent' -and $promptShown) { [void]$out.Add("${name}: the interactive prompt was printed, so the block read the console") }
    foreach ($key in $logPatterns.Keys) {
        $count = Get-Count $Run.Log $logPatterns[$key]
        if ($count -ne $Scenario.Logs[$key]) { [void]$out.Add("${name}: the log holds ${count} line(s) for '${key}', expected $($Scenario.Logs[$key])") }
    }
    return $out.ToArray()
}

function Get-GateDetails {
    param($Scenario, $Run, [string[]]$Problems)
    $details = [ordered]@{
        scenario = $Scenario.Name; finished = [bool]$Run.Finished; seconds = $Run.Seconds; driverExit = $Run.ExitCode
        headings = (Get-Count $Run.Console ([regex]::Escape($headingText))); promptShown = [bool]$Run.Console.Contains($promptText)
    }
    foreach ($key in $logPatterns.Keys) { $details['log_' + $key] = (Get-Count $Run.Log $logPatterns[$key]) }
    if ($Run.Error) { $details['error'] = $Run.Error }
    if (@($Problems).Count -gt 0) { $details['problems'] = @($Problems); $details['result'] = @(($Run.Result -split "`r?`n") | Where-Object { $_ }) }
    return $details
}

$gateResults = @{}
foreach ($s in $gateScenarios) {
    if ($null -eq $consentBlock) {
        $gateResults[$s.Name] = [pscustomobject]@{ Problems = @('the label :hidden_import_consent (up to :run_exe_smokerun) is not in run_setup.bat, so the repair loop asks no question'); Details = ([ordered]@{ scenario = $s.Name; blockFound = $false }) }
        continue
    }
    $run = Invoke-GateScenario $s
    $problems = @(Get-GateProblems -Scenario $s -Run $run)
    Add-Evidence -Title ('gate ' + $s.Name + ' (' + $run.Seconds + ' s, driver exit ' + $run.ExitCode + ')') -Text ("--- result`n" + $run.Result + "`n--- log`n" + $run.Log + "`n--- console`n" + $run.Console) -MaxLines 60
    $gateResults[$s.Name] = [pscustomobject]@{ Problems = $problems; Details = (Get-GateDetails -Scenario $s -Run $run -Problems $problems) }
}
function Get-GateRow {
    param([string[]]$Names)
    $problems = New-Object System.Collections.ArrayList
    $details = [ordered]@{}
    foreach ($nm in $Names) {
        foreach ($p in @($gateResults[$nm].Problems)) { [void]$problems.Add($p) }
        $details[$nm] = $gateResults[$nm].Details
    }
    return [pscustomobject]@{ Pass = [bool]($problems.Count -eq 0); Details = $details }
}

$row = Get-GateRow -Names @('noinput')
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.gate.noinput'; req = 'REQ-018.2'; pass = $row.Pass
    desc = 'REQ-018.2: with NOINPUT set the repair question is made, declined without reading the console, and the program is not started again'
    details = $row.Details
})
$row = Get-GateRow -Names @('nonint')
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.gate.nonint'; req = 'REQ-018.2'; pass = $row.Pass
    desc = 'REQ-018.2: with HP_NONINTERACTIVE set the repair question is made, declined without reading the console, and the program is not started again'
    details = $row.Details
})
$row = Get-GateRow -Names @('cilane')
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.gate.cilane'; req = 'REQ-018.2'; pass = $row.Pass
    desc = 'REQ-018.2: with HP_CI_LANE set the repair question is made, declined without reading the console, and the program is not started again'
    details = $row.Details
})
$row = Get-GateRow -Names @('control')
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.gate.control'; req = 'REQ-018.2'; pass = $row.Pass
    desc = 'REQ-018.2 control: with none of the three signals set the repair question takes the interactive branch (no automatic decline), and an unanswered question is a no'
    details = $row.Details
})
$row = Get-GateRow -Names @('answer_yes', 'answer_no', 'answer_beats_signal')
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.gate.answers'; req = 'REQ-018.2'; pass = $row.Pass
    desc = 'REQ-018.2: the test answer decides (Y allows, N declines) and wins over the non-interactive signals, so CI can drive the repair on purpose'
    details = $row.Details
})
$row = Get-GateRow -Names @('idempotent')
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.gate.idempotent'; req = 'REQ-005.13'; pass = $row.Pass
    desc = 'REQ-005.13: HP_PVW_KNOWN_IDEMPOTENT, the user declaring the script safe to run more than once, allows the repair without a question, even in a non-interactive run'
    details = $row.Details
})
$row = Get-GateRow -Names @('once_yes', 'once_no')
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.gate.once'; req = 'REQ-018.2'; pass = $row.Pass
    desc = 'REQ-018.2: the answer is asked once per bootstrap; a second call (after a DLL repair, or in the next provider tier) keeps it and asks nothing, whether it was yes or no'
    details = $row.Details
})

# ---------------------------------------------------------------------------------------------------------------------
# run rows: two real bootstraps of one program whose first EXE run fails
# ---------------------------------------------------------------------------------------------------------------------
# colorama is installed (requirements.txt) but imported by a runtime name PyInstaller does not see, so the first EXE run fails
# with ModuleNotFoundError and the repair loop has something to repair; after the repair the same program passes. The ledger
# line comes first so a start that fails at once is still counted.
$appCode = @'
import importlib
import json
import os
import sys

with open(os.environ["REPAIR_LEDGER"], "a") as f:
    f.write(json.dumps({"scenario": "repair", "frozen": bool(getattr(sys, "frozen", False)), "cwd": os.getcwd()}) + "\n")

mod = importlib.import_module('colorama')
print("repair-ok", mod.__name__)
'@

$runTimeoutMs = 15 * 60 * 1000

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

# Bootstraps the program in a fresh folder; never throws. Answer is Y for the accepted scenario and empty otherwise. The launch
# file clears the two variables that would change the answer itself, with cmd's own set, which is reliable where removing a
# variable from this process is not (gap T12).
function Invoke-RepairScenario {
    param([string]$Scenario, [string]$Answer)
    $res = [ordered]@{ Scenario = $Scenario; Finished = $false; ExitCode = -1; Seconds = 0; Dir = ''; Setup = ''; Console = ''; Ledger = @(); Error = '' }
    try {
        $dir = Join-Path $here ('~selftest_repair_' + $Scenario)
        $res.Dir = $dir
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath $batchPath -Destination $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value $appCode -Encoding ASCII
        Set-Content -LiteralPath (Join-Path $dir 'requirements.txt') -Value 'colorama' -Encoding ASCII
        $consoleName = '~repair_' + $Scenario + '.log'
        $launch = @('@echo off', 'set "HP_PVW_KNOWN_IDEMPOTENT="', 'set "HP_TEST_REPAIR_ANSWER="')
        if ($Answer) { $launch += ('set "HP_TEST_REPAIR_ANSWER=' + $Answer + '"') }
        $launch += @("call run_setup.bat > $consoleName 2>&1 < nul", 'exit /b %ERRORLEVEL%')
        Write-CrLf -Path (Join-Path $dir '~repair_launch.cmd') -Lines $launch
        $vars = [ordered]@{ HP_SKIP_PIPREQS = '1'; REPAIR_LEDGER = (Join-Path $dir '~repair_ledger.jsonl') }
        if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
        $saved = @{}
        foreach ($k in @($vars.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$vars[$k]) }
        try {
            $l = Invoke-Launch -Dir $dir -LaunchName '~repair_launch.cmd' -LimitMs $runTimeoutMs
            $res.Finished = $l.Finished; $res.ExitCode = $l.ExitCode; $res.Seconds = $l.Seconds
            if ($l.Error) { $res.Error = $l.Error }
        } finally {
            foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
        }
        $res.Console = Read-Text (Join-Path $dir $consoleName)
        $res.Setup = Read-Text (Join-Path $dir '~setup.log')
        $res.Ledger = @(Read-Ledger (Join-Path $dir '~repair_ledger.jsonl'))
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

# The facts one run's logs give. Indexes are character positions in the setup log (-1 when the line is absent), which is the
# one file every :log line reaches exactly once, in order.
function Get-RunFacts {
    param($Run)
    $s = [string]$Run.Setup
    return [ordered]@{
        failedRun = [regex]::IsMatch($s, 'EXE smokerun: exited -?[1-9][0-9]* \(non-zero\)')
        announced = (Get-Count $s 'Verifying the built standalone EXE')
        rebuilds  = (Get-Count $s '\[REPAIR\]\[HIDDEN_IMPORT\] Adding --hidden-import=')
        autoAt    = ([regex]::Match($s, $logPatterns['auto'])).Index
        acceptedAt = ([regex]::Match($s, $logPatterns['accepted'])).Index
        autoSeen  = [regex]::IsMatch($s, $logPatterns['auto'])
        acceptedSeen = [regex]::IsMatch($s, $logPatterns['accepted'])
        loopAnnouncedAt = $s.IndexOf('even if running perfectly')
        addingAt  = $s.IndexOf('[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama')
        verified  = $s.Contains('EXE verified after hidden-import recovery')
        headingInConsole = ([string]$Run.Console).Contains($headingText)
        markerAfterHeading = $(if (([string]$Run.Console).Contains($headingText)) { ([string]$Run.Console).IndexOf($markerText, ([string]$Run.Console).IndexOf($headingText)) -ge 0 } else { $false })
    }
}

function Get-RunProblems {
    param([string]$Scenario, $Run, $Facts)
    $out = New-Object System.Collections.ArrayList
    if (-not $Run.Finished) { [void]$out.Add("${Scenario}: the bootstrap did not finish within the time limit"); return $out.ToArray() }
    $starts = @($Run.Ledger).Count
    if (-not $Facts.failedRun) { [void]$out.Add("${Scenario}: the EXE verification run did not fail, so the repair loop was never reached") }
    if ($starts -lt 1) { [void]$out.Add("${Scenario}: the ledger is empty, so the program never ran") }
    if (-not $Facts.headingInConsole) { [void]$out.Add("${Scenario}: the repair question was never made, its heading is not in the console") }
    elseif (-not $Facts.markerAfterHeading) { [void]$out.Add("${Scenario}: the repair question does not say '${markerText}'") }
    if ($Scenario -eq 'declined') {
        if (-not $Facts.autoSeen) { [void]$out.Add("${Scenario}: the log has no line saying the question was not asked in a non-interactive run") }
        if ($Facts.rebuilds -gt 0) { [void]$out.Add("${Scenario}: the EXE was rebuilt $($Facts.rebuilds) time(s) although nobody consented") }
        if ($starts -ne 1) { [void]$out.Add("${Scenario}: the program was started ${starts} time(s), expected exactly the one check run (the repair loop's extra starts need consent; the failure hint must not start it either)") }
    } else {
        if (-not $Facts.acceptedSeen) { [void]$out.Add("${Scenario}: the log never says the repair was accepted") }
        if ($Facts.rebuilds -lt 1) { [void]$out.Add("${Scenario}: no hidden-import repair happened, so the extra starts were not the repair") }
        if ($Facts.acceptedSeen -and $Facts.loopAnnouncedAt -ge 0 -and $Facts.acceptedAt -gt $Facts.loopAnnouncedAt) { [void]$out.Add("${Scenario}: the loop announced its start before the log says the repair was accepted") }
        if ($Facts.acceptedSeen -and $Facts.addingAt -ge 0 -and $Facts.acceptedAt -gt $Facts.addingAt) { [void]$out.Add("${Scenario}: the first --hidden-import repair came before the log says the repair was accepted") }
        if (-not $Facts.verified) { [void]$out.Add("${Scenario}: the repaired EXE was not verified, so accepting did not keep the repair working") }
        if ($starts -lt 2) { [void]$out.Add("${Scenario}: the program was started ${starts} time(s); accepting should have started it again") }
        $allowed = $Facts.announced + $Facts.rebuilds
        if ($starts -gt $allowed) { [void]$out.Add("${Scenario}: the program was started ${starts} time(s) but the log accounts for ${allowed} ($($Facts.announced) announced + $($Facts.rebuilds) after rebuilds)") }
    }
    return $out.ToArray()
}

function Get-RunDetails {
    param($Run, $Facts, [string[]]$Problems)
    $details = [ordered]@{
        finished = [bool]$Run.Finished; seconds = $Run.Seconds; exitCode = $Run.ExitCode; starts = @($Run.Ledger).Count
        startsFromDist = @(@($Run.Ledger) | Where-Object { ([string]$_.cwd) -match '[\\/]dist$' }).Count
        failedRun = [bool]$Facts.failedRun; announced = $Facts.announced; rebuilds = $Facts.rebuilds
        headingInConsole = [bool]$Facts.headingInConsole; markerAfterHeading = [bool]$Facts.markerAfterHeading
        autoSeen = [bool]$Facts.autoSeen; acceptedSeen = [bool]$Facts.acceptedSeen; verified = [bool]$Facts.verified
        acceptedAt = $Facts.acceptedAt; loopAnnouncedAt = $Facts.loopAnnouncedAt; addingAt = $Facts.addingAt
    }
    if ($Run.Error) { $details['error'] = $Run.Error }
    if (@($Problems).Count -gt 0) {
        $details['problems'] = @($Problems)
        $details['excerpt'] = @(Get-Excerpt -Text $Run.Setup -Pattern 'Verifying the built standalone EXE|EXE smokerun|Entry smoke|Repair loop|\[REPAIR\]|\[HINT\]|\[ERROR\]|\[STATUS\]')
    }
    return $details
}

# ---------------------------------------------------------------- declined: a non-interactive run, no answer given
$declined = Invoke-RepairScenario -Scenario 'declined' -Answer ''
$declinedFacts = Get-RunFacts $declined
$declinedProblems = @(Get-RunProblems -Scenario 'declined' -Run $declined -Facts $declinedFacts)
Add-Evidence -Title ('run declined (' + $declined.Seconds + ' s, starts ' + @($declined.Ledger).Count + ')') -Text ((Get-Excerpt -Text $declined.Setup -Pattern 'Verifying the built standalone EXE|EXE smokerun|Entry smoke|Repair loop|\[REPAIR\]|\[HINT\]|\[ERROR\]|\[STATUS\]' -Max 60) -join "`n")
if ($declinedProblems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.consent.declined'; req = 'REQ-018.1, REQ-018.2'; pass = [bool]($declinedProblems.Count -eq 0)
    desc = 'REQ-018.1 and REQ-018.2: after a failed EXE verification run in a non-interactive run, the repair loop makes its question (naming the risk), is not allowed to start the program again, rebuilds nothing, and the program has been started exactly once'
    details = (Get-RunDetails -Run $declined -Facts $declinedFacts -Problems $declinedProblems)
})

# ---------------------------------------------------------------- accepted: the test answers yes
$accepted = Invoke-RepairScenario -Scenario 'accepted' -Answer 'Y'
$acceptedFacts = Get-RunFacts $accepted
$acceptedProblems = @(Get-RunProblems -Scenario 'accepted' -Run $accepted -Facts $acceptedFacts)
Add-Evidence -Title ('run accepted (' + $accepted.Seconds + ' s, starts ' + @($accepted.Ledger).Count + ')') -Text ((Get-Excerpt -Text $accepted.Setup -Pattern 'Verifying the built standalone EXE|EXE smokerun|Entry smoke|Repair loop|\[REPAIR\]|\[HINT\]|\[ERROR\]|\[STATUS\]' -Max 60) -join "`n")
if ($acceptedProblems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.repair.consent.accepted'; req = 'REQ-018.2'; pass = [bool]($acceptedProblems.Count -eq 0)
    desc = 'REQ-018.2: with consent the repair loop starts the program again and repairs the EXE, and the log says the repair was accepted before the loop announces its first start or adds the first --hidden-import'
    details = (Get-RunDetails -Run $accepted -Facts $acceptedFacts -Problems $acceptedProblems)
})

if (-not $allPass) { exit 1 }
exit 0
