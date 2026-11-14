# ASCII only
# selfapps_choice_cancel.ps1 - Item 105 (README REQ-005.10, REQ-008.11, REQ-018.15 and REQ-018.2): a timed yes/no question that
# the user interrupts with Ctrl+C or Ctrl+Break is a no, never a yes.
#
# History. choice.exe answers errorlevel 1 for the first key it lists (Y), 2 for the second (N), 255 for an error and 0 for
# Ctrl+C or Ctrl+Break; cmd.exe then asks "Terminate batch job (Y/N)?", and a person who answers N lets the batch file go on
# with errorlevel 0. "if errorlevel 2" is true for 2 and above, so it catches 255 and not 0. Three timed gates of
# run_setup.bat sent errorlevel 2 to the decline and every smaller number to the yes, so that interruption was taken for an
# explicit yes to a provider cascade (:cascade_consent_gate), to a 30 to 45 minute NI-VISA driver install (:visa_subfolder_gate)
# and to an install of packages with a rebuild and one more run of the program (:runtime_install_offer). README REQ-018.15 and
# REQ-008.11 name an explicit yes as the only consent, and REQ-005.10 asks for explicit consent before a cascade. The question
# in front of the --hidden-import repair (:hidden_import_consent, Item 97) has a second line, "if not errorlevel 1", and is the
# control of this script.
#
# Four gate rows, one per question. Each cuts the real block out of run_setup.bat (from its label up to the next label this
# script names), wraps it in a small driver batch file and runs it with cmd.exe and closed standard input, once per answer:
# Y (errorlevel 1), N (2), Ctrl+C (0) and an error (255). The one line that reads the console, the line that starts with
# choice, is replaced by a call that records its arguments and answers with the errorlevel of the scenario, so no run waits for
# a person (the technique of selfapps_repair_consent.ps1 and selfapps_runtime_install_edges.ps1). A gate passes when each answer
# has the verdict it must have: only Y accepts, N, Ctrl+C and an error decline, and each decision is logged exactly once. The Y
# run is what gives the others their meaning: it shows the stub reaches the question and that the block accepts when the answer
# is yes, so a Ctrl+C run cannot pass because the block never asked.
#
# Two kinds of evidence per run, so that one cannot vouch for the other: the verdict the driver recorded from the block's own
# result (an exit code, a variable, whether the install step was called, a flag) and the line the block wrote to its log.
#
# derived requirement: ids and tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell), and a judging function takes plain values and returns a list of problems
# (tests/test_choice_cancel.py runs each of them through a real pwsh on synthetic runs).
#
# Lane: contract-uv (the lane with the most wall-clock headroom; the gates are the same on every lane). Gating from its first run
# (AGENTS.md "New tests gate immediately"): a red row holds the aggregate check. Sixteen driver runs, seconds each.
# Emits: self.consent.cancel.cascade, self.consent.cancel.visa, self.consent.cancel.install, self.consent.cancel.repair
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

# Used when the four rows share one outcome (a skip, or an input that is missing); the real emissions below are literal too.
function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    Write-NdjsonRow ([ordered]@{ id = 'self.consent.cancel.cascade'; req = 'REQ-005.10'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.consent.cancel.visa'; req = 'REQ-008.11'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.consent.cancel.install'; req = 'REQ-018.15'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.consent.cancel.repair'; req = 'REQ-018.2'; pass = $Pass; desc = $Desc; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'Ctrl+C at a timed question (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'Ctrl+C at a timed question: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}
$helperPath = Join-Path $repo 'tools\runtime_module_scan.py'
if (-not (Test-Path $helperPath)) {
    Write-AllRows -Pass $false -Desc 'Ctrl+C at a timed question: tools\runtime_module_scan.py not found' -Details ([ordered]@{ error = 'helper not found at ' + $helperPath })
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------------------------------------------------
$evidencePath = Join-Path $here '~choice_cancel_evidence.txt'
Set-Content -LiteralPath $evidencePath -Value 'selfapps_choice_cancel.ps1 evidence (printable ASCII only)' -Encoding Ascii

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

# A python that can run the helper the install question lists packages with (the block runs it through HP_PY).
function Find-RunnerPython {
    foreach ($name in @('python', 'python3')) {
        $c = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($c -and $c.Source) {
            & $c.Source -c 'import sys; sys.exit(0)' 2>$null
            if ($LASTEXITCODE -eq 0) { return [string]$c.Source }
        }
    }
    return ''
}
$runnerPython = Find-RunnerPython

# ---------------------------------------------------------------------------------------------------------------------
# what is asked, and what each answer must do
# ---------------------------------------------------------------------------------------------------------------------
# The four questions. Start and End are the labels the block is cut between; Heading is the line the block prints before it
# asks (a regular expression); Accepted and Declined are the log lines of the two decisions (regular expressions);
# Setup clears every variable the block reads (a variable inherited from the runner could decide for it) and Call runs the
# block and records the verdict the block itself produces. tests/test_choice_cancel.py pins every text to run_setup.bat.
$gates = @(
    [pscustomobject]@{
        Key = 'cascade'; Start = ':cascade_consent_gate'; End = ':visa_subfolder_gate'
        Heading = 'Some dependencies could not be installed under the current Python provider\.'
        Accepted = 'REQ-009: cascade consent: accepted\.'; Declined = 'REQ-009: cascade consent: declined\.'
        Setup = @('set "HP_CASCADE_CHOICE="', 'set "HP_CASCADE_RAW="', 'set "HP_CASCADE_T="', 'set "HP_TEST_CASCADE_ANSWER="',
                  'set "HP_TEST_FORCE_INTERACTIVE_CASCADE="', 'set "HP_CI_LANE="')
        Call = @('call :cascade_consent_gate', '>>"%RESULT%" echo RC=%ERRORLEVEL%')
    },
    [pscustomobject]@{
        Key = 'visa'; Start = ':visa_subfolder_gate'; End = ':dll_bundle_recover'
        Heading = 'The NI-VISA driver looks needed only by a file in a subfolder:'
        Accepted = 'NI-VISA install for a subfolder-only import: accepted\.'; Declined = '\[VISA\] skipped \(subfolder_only\)'
        Setup = @('set "NEED_VISA=2"', 'set "HP_VISA_DECISION="', 'set "HP_VISA_WHERE=subfolder\old_program.py"', 'set "HP_VISA_CHOICE="',
                  'set "HP_VISA_RAW="', 'set "HP_VISA_T="', 'set "HP_TEST_VISA_ANSWER="', 'set "HP_TEST_FORCE_INTERACTIVE_VISA="',
                  'set "HP_CI_LANE="', 'set "NOINPUT="', 'set "HP_NONINTERACTIVE="')
        Call = @('call :visa_subfolder_gate', '>>"%RESULT%" echo NEED_VISA=%NEED_VISA%')
    },
    [pscustomobject]@{
        Key = 'install'; Start = ':runtime_install_offer'; End = ':rti_install_one'
        Heading = 'Your program asked for packages that are not installed:'
        Accepted = 'Runtime install: accepted\.'; Declined = 'Runtime install: declined\. Nothing was changed\.'
        Setup = @('set "HP_ENV_MODE=uv"', 'set "HP_RTM_FOUND=1"', 'set "HP_RTI_OFFERED="', 'set "HP_RTI_VERIFYING="',
                  'set "HP_NUITKA_FALLBACK_USED="', 'set "HP_RTI_CHOICE="', 'set "HP_RTI_RAW="', 'set "HP_TEST_RTM_ANSWER="',
                  'set "HP_CI_LANE="', 'set "NOINPUT="', 'set "HP_NONINTERACTIVE="', 'set "HP_RTI_REBUILD_FAILED="')
        Call = @('call :runtime_install_offer exe', '>>"%RESULT%" echo OFFERED=%HP_RTI_OFFERED%')
    },
    [pscustomobject]@{
        Key = 'repair'; Start = ':hidden_import_consent'; End = ':run_exe_smokerun'
        Heading = 'The check run of your program failed, exit code'
        Accepted = 'Repair loop: accepted\.'; Declined = 'Repair loop: declined\.'
        Setup = @('set "HP_EXE_EXIT=1"', 'set "HP_HIC_ANSWER="', 'set "HP_HIC_ALLOWED="', 'set "HP_HIC_CHOICE="', 'set "HP_HIC_RAW="',
                  'set "HP_CI_LANE="', 'set "NOINPUT="', 'set "HP_NONINTERACTIVE="', 'set "HP_TEST_REPAIR_ANSWER="', 'set "HP_PVW_KNOWN_IDEMPOTENT="')
        Call = @('call :hidden_import_consent', 'if defined HP_HIC_ALLOWED >>"%RESULT%" echo ALLOWED=yes', 'if not defined HP_HIC_ALLOWED >>"%RESULT%" echo ALLOWED=no')
    }
)

# The answers choice.exe can leave: 1 for the first key it lists (Y), 2 for the second (N, also what the 30 second default
# gives), 0 for Ctrl+C or Ctrl+Break and 255 for an error. Only Y may accept.
$answers = @(
    [pscustomobject]@{ Name = 'yes'; Rc = 1; Accept = $true },
    [pscustomobject]@{ Name = 'no'; Rc = 2; Accept = $false },
    [pscustomobject]@{ Name = 'cancel'; Rc = 0; Accept = $false },
    [pscustomobject]@{ Name = 'error'; Rc = 255; Accept = $false }
)

# ---------------------------------------------------------------------------------------------------------------------
# judging: plain values in, a list of problems out (nothing when the run shows what the answer must show)
# ---------------------------------------------------------------------------------------------------------------------
# The decision the block itself produced, from what the driver recorded: accepted, declined or unknown. Every question leaves
# its verdict somewhere different (an exit code, a variable, whether the install step was called, a flag).
function Get-Decision {
    param([string]$GateKey, [string]$ResultText)
    if ($GateKey -eq 'cascade') {
        if ($ResultText -match '(?m)^RC=0\s*$') { return 'accepted' }
        if ($ResultText -match '(?m)^RC=1\s*$') { return 'declined' }
    } elseif ($GateKey -eq 'visa') {
        if ($ResultText -match '(?m)^NEED_VISA=1\s*$') { return 'accepted' }
        if ($ResultText -match '(?m)^NEED_VISA=2\s*$') { return 'declined' }
    } elseif ($GateKey -eq 'install') {
        if ($ResultText -match '(?m)^INSTALL_ONE\b') { return 'accepted' }
        if ($ResultText -match '(?m)^OFFERED=1\s*$') { return 'declined' }
    } elseif ($GateKey -eq 'repair') {
        if ($ResultText -match '(?m)^ALLOWED=yes\s*$') { return 'accepted' }
        if ($ResultText -match '(?m)^ALLOWED=no\s*$') { return 'declined' }
    }
    return 'unknown'
}

function Get-ChoiceProblems {
    param([string]$GateKey, [string]$Scenario, [bool]$Finished, [string]$ResultText, [string]$LogText, [string]$ConsoleText,
          [string]$ChoiceArgsText, [string]$HeadingPattern, [string]$AcceptedPattern, [string]$DeclinedPattern, [bool]$ExpectAccepted)
    $out = New-Object System.Collections.ArrayList
    $tag = "${GateKey} ${Scenario}"
    if (-not $Finished) { [void]$out.Add("${tag}: the driver did not finish within the time limit"); return $out.ToArray() }
    if ($ResultText -notmatch '(?m)^END\s*$') { [void]$out.Add("${tag}: the driver did not reach its end, so the block ended the run early"); return $out.ToArray() }
    if ($ResultText -match '(?m)^REACHED\s') { [void]$out.Add("${tag}: the block went on to a step this driver does not run (a rebuild or a check run)") }
    $headings = [regex]::Matches($ConsoleText, $HeadingPattern).Count
    if ($headings -ne 1) { [void]$out.Add("${tag}: the question's heading was printed ${headings} time(s), expected 1") }
    $readLines = @(($ChoiceArgsText -split "`r?`n") | Where-Object { $_.Trim() })
    if ($readLines.Count -eq 0) {
        [void]$out.Add("${tag}: the block never reached its choice line, so no answer was read")
    } elseif ($readLines.Count -ne 1) {
        [void]$out.Add("${tag}: the block read the console $($readLines.Count) times, expected once")
    } else {
        if ($readLines[0] -notmatch '(?i)/C\s+YN(\s|$)') { [void]$out.Add("${tag}: the choice line does not offer exactly Y and N (/C YN): $($readLines[0].Trim())") }
        if ($readLines[0] -notmatch '(?i)/T\s+30(\s|$)') { [void]$out.Add("${tag}: the choice line does not wait for 30 seconds (/T 30): $($readLines[0].Trim())") }
        if ($readLines[0] -notmatch '(?i)/D\s+N(\s|$)') { [void]$out.Add("${tag}: the choice line does not default to N after the wait (/D N): $($readLines[0].Trim())") }
    }
    $decision = Get-Decision -GateKey $GateKey -ResultText $ResultText
    $want = 'declined'
    if ($ExpectAccepted) { $want = 'accepted' }
    if ($decision -ne $want) {
        if ($Scenario -eq 'cancel' -and $decision -eq 'accepted') {
            [void]$out.Add("${tag}: errorlevel 0 (Ctrl+C or Ctrl+Break) was taken for a yes: the gate accepted")
        } else {
            [void]$out.Add("${tag}: the gate ${decision}, expected ${want}")
        }
    }
    $acceptedLines = [regex]::Matches($LogText, $AcceptedPattern).Count
    $declinedLines = [regex]::Matches($LogText, $DeclinedPattern).Count
    $wantAccepted = 0
    $wantDeclined = 1
    if ($ExpectAccepted) { $wantAccepted = 1; $wantDeclined = 0 }
    if ($acceptedLines -ne $wantAccepted) { [void]$out.Add("${tag}: the log holds ${acceptedLines} accepted line(s), expected ${wantAccepted}") }
    if ($declinedLines -ne $wantDeclined) { [void]$out.Add("${tag}: the log holds ${declinedLines} declined line(s), expected ${wantDeclined}") }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# the driver: the real block in a small batch file with stubs for what it calls
# ---------------------------------------------------------------------------------------------------------------------
# The driver defines what the cut-out block expects (LOG, RESULT, a :log that only appends to the log), clears every variable
# the block reads, calls the block and records the verdict. The console read, the one line that starts with choice, becomes a
# call of a stub that appends its arguments to a file and answers with the errorlevel of the scenario. The install question
# also calls the helper that lists packages (copied by :emit_from_base64, run by the runner's Python) and, only on a yes, the
# install of one package, which the driver records and does not run (the stub leaves no file of installed packages, so the
# block ends at its install_failed state; the labels after it, the rebuild and the two check runs, are stubs that only record
# that they were reached, and the judge counts that as a problem). Standard input is closed by the launch file.
function New-ChoiceDriver {
    param([string]$Dir, $Gate, $Answer, [string]$Python, [string[]]$Block)
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in @(
        '@echo off', 'setlocal',
        ('set "LOG=' + (Join-Path $Dir '~driver.log') + '"'),
        ('set "RESULT=' + (Join-Path $Dir '~driver_result.txt') + '"'),
        ('set "CHOICE_ARGS=' + (Join-Path $Dir '~choice_args.txt') + '"'),
        ('set "SCAN_MASTER=' + (Join-Path $Dir '~scan_master.py') + '"'),
        ('set "CHOICE_RC=' + [string]$Answer.Rc + '"'),
        ('set "HP_PY=' + $Python + '"')
    )) { [void]$lines.Add($l) }
    foreach ($l in $Gate.Setup) { [void]$lines.Add($l) }
    [void]$lines.Add('>"%RESULT%" echo START')
    foreach ($l in $Gate.Call) { [void]$lines.Add($l) }
    foreach ($l in @('>>"%RESULT%" echo END', 'exit /b 0')) { [void]$lines.Add($l) }
    foreach ($l in $Block) {
        if ($l -match '^\s*choice\s') { [void]$lines.Add(($l -replace '^(\s*)choice\s+', '$1call :choice_stub ')) } else { [void]$lines.Add($l) }
    }
    foreach ($l in @(
        ':log', 'setlocal', 'set "MSG=%~1"', '>>"%LOG%" echo %MSG%', 'endlocal', 'exit /b 0',
        ':rti_row', '>>"%RESULT%" echo ROW=%~1', 'exit /b 0',
        ':rti_install_one', '>>"%RESULT%" echo INSTALL_ONE %*', 'exit /b 0',
        ':rti_rebuild', '>>"%RESULT%" echo REACHED rti_rebuild', 'exit /b 0',
        ':run_exe_smokerun', '>>"%RESULT%" echo REACHED run_exe_smokerun', 'exit /b 0',
        ':verify_no_exe_interpreter', '>>"%RESULT%" echo REACHED verify_no_exe_interpreter', 'exit /b 0',
        ':emit_from_base64', 'copy /y "%SCAN_MASTER%" "%~1" >nul 2>&1', 'exit /b 0',
        ':choice_stub', '>>"%CHOICE_ARGS%" echo %*', 'exit /b %CHOICE_RC%'
    )) { [void]$lines.Add($l) }
    return $lines.ToArray()
}

$work = Join-Path $here '~selftest_choicecancel'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

function Invoke-ChoiceScenario {
    param($Gate, $Answer, [string[]]$Block)
    $dir = Join-Path $work ($Gate.Key + '_' + $Answer.Name)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $helperPath -Destination (Join-Path $dir '~scan_master.py') -Force
    Write-CrLf -Path (Join-Path $dir '~runtime_missing_modules.txt') -Lines @('pvw_cancel_probe_')
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines (New-ChoiceDriver -Dir $dir -Gate $Gate -Answer $Answer -Python $runnerPython -Block $Block)
    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines @('@echo off', 'call ~driver.bat > ~driver_console.txt 2>&1 < nul', 'exit /b %ERRORLEVEL%')
    $launch = Invoke-Launch -Dir $dir -LaunchName '~driver_launch.cmd' -LimitMs 180000
    return [pscustomobject]@{
        Finished = $launch.Finished; ExitCode = $launch.ExitCode; Seconds = $launch.Seconds; Error = $launch.Error
        Console = (Read-Text (Join-Path $dir '~driver_console.txt')); Log = (Read-Text (Join-Path $dir '~driver.log'))
        Result = (Read-Text (Join-Path $dir '~driver_result.txt')); ChoiceArgs = (Read-Text (Join-Path $dir '~choice_args.txt'))
    }
}

# One gate: every answer, one driver run each. Returns the problems and the details of the gate's row.
function Get-GateResult {
    param($Gate)
    $problems = New-Object System.Collections.ArrayList
    $details = [ordered]@{ gate = $Gate.Key }
    $block = Get-BatBlock -StartLabel $Gate.Start -EndLabel $Gate.End
    if ($null -eq $block) {
        [void]$problems.Add("the label $($Gate.Start) (up to $($Gate.End)) is not in run_setup.bat, so there is no question to test")
        $details['blockFound'] = $false
        return [pscustomobject]@{ Problems = @($problems); Details = $details }
    }
    if ($Gate.Key -eq 'install' -and -not $runnerPython) {
        [void]$problems.Add('no python on the runner could run the helper, so the install question cannot list packages')
        $details['pythonFound'] = $false
        return [pscustomobject]@{ Problems = @($problems); Details = $details }
    }
    foreach ($a in $answers) {
        $run = Invoke-ChoiceScenario -Gate $Gate -Answer $a -Block $block
        $found = @(Get-ChoiceProblems -GateKey $Gate.Key -Scenario $a.Name -Finished ([bool]$run.Finished) -ResultText $run.Result -LogText $run.Log -ConsoleText $run.Console `
            -ChoiceArgsText $run.ChoiceArgs -HeadingPattern $Gate.Heading -AcceptedPattern $Gate.Accepted -DeclinedPattern $Gate.Declined -ExpectAccepted ([bool]$a.Accept))
        Add-Evidence -Title ($Gate.Key + ' ' + $a.Name + ' (choice answers ' + $a.Rc + ', ' + $run.Seconds + ' s, driver exit ' + $run.ExitCode + ')') `
            -Text ("--- result`n" + $run.Result + "`n--- log`n" + $run.Log + "`n--- choice args`n" + $run.ChoiceArgs + "`n--- console`n" + $run.Console) -MaxLines 70
        foreach ($f in $found) { [void]$problems.Add($f) }
        $one = [ordered]@{
            choiceAnswers = [int]$a.Rc; finished = [bool]$run.Finished; seconds = $run.Seconds; driverExit = $run.ExitCode
            decision = (Get-Decision -GateKey $Gate.Key -ResultText $run.Result)
            expected = $(if ($a.Accept) { 'accepted' } else { 'declined' })
            choiceArgs = ([string]$run.ChoiceArgs).Trim()
        }
        if ($run.Error) { $one['error'] = $run.Error }
        if ($found.Count -gt 0) { $one['problems'] = @($found); $one['result'] = @(($run.Result -split "`r?`n") | Where-Object { $_ }) }
        $details[$a.Name] = $one
    }
    return [pscustomobject]@{ Problems = @($problems); Details = $details }
}

$allPass = $true

$cascade = Get-GateResult -Gate $gates[0]
$visa    = Get-GateResult -Gate $gates[1]
$install = Get-GateResult -Gate $gates[2]
$repair  = Get-GateResult -Gate $gates[3]

$pass = [bool](@($cascade.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.consent.cancel.cascade'; req = 'REQ-005.10'; pass = $pass
    desc = 'Ctrl+C at the provider-cascade question is a no: only Y accepts, and N, Ctrl+C and an error decline'; details = $cascade.Details })

$pass = [bool](@($visa.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.consent.cancel.visa'; req = 'REQ-008.11'; pass = $pass
    desc = 'Ctrl+C at the NI-VISA question is a no: only Y installs the driver, and N, Ctrl+C and an error do not'; details = $visa.Details })

$pass = [bool](@($install.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.consent.cancel.install'; req = 'REQ-018.15'; pass = $pass
    desc = 'Ctrl+C at the runtime-install question is a no: only Y installs, and N, Ctrl+C and an error change nothing'; details = $install.Details })

$pass = [bool](@($repair.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.consent.cancel.repair'; req = 'REQ-018.2'; pass = $pass
    desc = 'Ctrl+C at the repair-loop question is a no: only Y allows the repair, and N, Ctrl+C and an error do not (the control)'; details = $repair.Details })

if (-not $allPass) { exit 1 }
exit 0
