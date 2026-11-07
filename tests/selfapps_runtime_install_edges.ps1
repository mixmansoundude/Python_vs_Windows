# ASCII only
# selfapps_runtime_install_edges.ps1 - Item 99 (README REQ-018.14, REQ-018.16, REQ-018.20, REQ-018.21 and REQ-018.22): the
# edges of the consented install of a package a program asked for at run time.
#
# selfapps_runtime_install.ps1 shows the main road (a yes installs, edits requirements.txt, rebuilds and the check run is clean;
# a no changes nothing). Six shalls of the same offer had no row that could fail for them (docs/plan-test-suite-gaps.md,
# tests/test_req_shall_trace.py): the question is asked once per invocation and before any change, within 30 seconds (REQ-018.14);
# it is not made for a system Python, for no provider or for an EXE built by the fallback build system, and the log says so
# (REQ-018.16); the check run's answer when the module is STILL missing (REQ-018.20, the verified branch is the accept row of the
# other script); a failed install or a failed rebuild stops that step without a provider cascade (REQ-018.21); the prompt lists
# every package, naming the one that provides cv2 and PIL (REQ-018.22).
#
# Two kinds of rows, because the question is small and the bootstrap around it is slow:
#   gate rows   cut the real :runtime_install_offer block out of run_setup.bat (up to :rti_install_one), wrap it in a tiny driver
#               batch file with stubs for what it calls (:log, :rti_row, :emit_from_base64 and the choice line), and run it with
#               cmd.exe and closed standard input, one scenario per environment. They prove the decision table without building
#               anything: a system Python, no provider and a Nuitka-built EXE are not offered the question and the log says so
#               (the control run with a uv provider IS asked, so a driver that never offers cannot pass); a second call in the
#               same bootstrap, as a later provider tier makes, asks nothing; with no test answer and none of the three
#               non-interactive signals the block takes the console branch, whose choice line (recorded, then answered with a
#               no by the stub) is bounded by /T 30 and defaults to N; and the prompt lists the packages (cv2 is opencv-python,
#               PIL is pillow, any other module is its own package), run through the real helper (tools/runtime_module_scan.py,
#               the same file as the embedded payload) under the runner's python.
#   run rows    three real default bootstraps whose program catches its own ImportError, prints the traceback and exits 0 (the
#               module names are joined at run time, so no static scan installs them first). The answer is yes through
#               HP_TEST_RTM_ANSWER. stillmissing: one name is a real package (xlsxwriter), the other cannot be installed (a name
#               with a trailing underscore, which uv refuses before it asks any index), so after the install and the rebuild the
#               check run still names a module and the log must say so, not "verified". failed: the only name cannot be
#               installed, so nothing else may happen (no edit, no rebuild, no check run). rebuildfailed: the package installs
#               and HP_TEST_FORCE_RTI_REBUILD_FAIL makes the rebuild fail (PyInstaller refuses an option it does not know), so
#               the check run must not start. None of the three may start a provider cascade.
#
# Tags. Row tags are literals at each call site (the requirement-trace tests read text). The skip rows use a map on purpose.
#
# derived requirement: ids and tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell), and every judging function below takes plain values only, so
# tests/test_edge_rows.py can run each of them through a real pwsh on synthetic runs.
#
# Lane: contract-uv (the lane with the most wall-clock headroom; the offer and its provider are the same on every uv lane).
# Gating from its first run (AGENTS.md "New tests gate immediately"): a red row holds the aggregate check. Seven driver runs
# (seconds each) and three default bootstraps, each limited to 20 minutes.
# Emits: self.runtime.install.once, self.runtime.install.notoffered, self.runtime.install.listing,
#        self.runtime.install.stillmissing, self.runtime.install.failed, self.runtime.install.rebuildfailed
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
    'self.runtime.install.once', 'self.runtime.install.notoffered', 'self.runtime.install.listing',
    'self.runtime.install.stillmissing', 'self.runtime.install.failed', 'self.runtime.install.rebuildfailed'
)
$reqOf = @{
    'self.runtime.install.once' = 'REQ-018.14'; 'self.runtime.install.notoffered' = 'REQ-018.16'; 'self.runtime.install.listing' = 'REQ-018.22'
    'self.runtime.install.stillmissing' = 'REQ-018.20'; 'self.runtime.install.failed' = 'REQ-018.21'; 'self.runtime.install.rebuildfailed' = 'REQ-018.21'
}
function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = $reqOf[$rowId]; pass = $Pass; desc = $Desc; details = $Details })
    }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'Runtime install edges (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath  = Join-Path $repo 'run_setup.bat'
$helperPath = Join-Path $repo 'tools\runtime_module_scan.py'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'Runtime install edges: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}
if (-not (Test-Path $helperPath)) {
    Write-AllRows -Pass $false -Desc 'Runtime install edges: tools\runtime_module_scan.py not found' -Details ([ordered]@{ error = 'helper not found at ' + $helperPath })
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# shared helpers and the texts the batch shows and logs (tests/test_edge_rows.py pins each of them to run_setup.bat)
# ---------------------------------------------------------------------------------------------------------------------
$evidencePath = Join-Path $here '~runtime_install_edges_evidence.txt'
Set-Content -LiteralPath $evidencePath -Value 'selfapps_runtime_install_edges.ps1 evidence (printable ASCII only)' -Encoding Ascii

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

# The judging functions below take plain values and nothing from the script scope: the texts they look for are written in
# them, and tests/test_edge_rows.py pins each text to a live line of run_setup.bat.

function Get-Count {
    param([string]$Text, [string]$Pattern)
    return [regex]::Matches($Text, $Pattern).Count
}

# A few log lines that explain a red row, printable ASCII only and cut short.
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

# The package names the prompt lists: the lines "***   name" between its heading and its question, names only (sorted).
# Nothing when either marker is missing, so a prompt that moved or lost its heading cannot pass.
function Get-PromptPackages {
    param([string]$Console)
    $names = New-Object System.Collections.ArrayList
    $a = $Console.IndexOf('Your program asked for packages that are not installed:', [System.StringComparison]::Ordinal)
    if ($a -lt 0) { return $names.ToArray() }
    $b = $Console.IndexOf('Install them now?', $a, [System.StringComparison]::Ordinal)
    if ($b -lt 0) { return $names.ToArray() }
    foreach ($l in ($Console.Substring($a, $b - $a) -split "`r?`n")) {
        $m = [regex]::Match($l, '^\*\*\*\s{3}(\S+)\s*$')
        if ($m.Success) { [void]$names.Add($m.Groups[1].Value) }
    }
    return @($names.ToArray() | Sort-Object)
}

# What is wrong with one driver run of the real block; nothing when the run shows what the scenario expects. Headings is how many
# times the question's heading is printed, NotOffered and Declined how many times the log (and the recorded row state) says so,
# Calls how many calls of the block the driver made, Packages the packages the prompt must list (joined by |, empty = not
# judged) and ChoiceRead whether the console branch must have reached its choice line (the stub records the arguments).
function Get-GateProblems {
    param([string]$Name, [bool]$Finished, [string]$Result, [string]$Log, [string]$Console, [string]$ChoiceArgs,
          [int]$Headings, [int]$NotOffered, [int]$Declined, [int]$Calls, [string]$Packages, [bool]$ChoiceRead)
    $out = New-Object System.Collections.ArrayList
    if (-not $Finished) { [void]$out.Add("${Name}: the driver did not finish within the time limit"); return $out.ToArray() }
    if ($Result -notmatch '(?m)^END\s*$') { [void]$out.Add("${Name}: the driver did not reach its end, so the block ended the run early"); return $out.ToArray() }
    # derived requirement: PowerShell variable names are not case sensitive, so a local named like a parameter (calls and Calls)
    # would overwrite it and every comparison below would read true; the measured values carry a Seen suffix.
    $callsSeen = Get-Count $Result '(?m)^CALL\d+ '
    if ($callsSeen -ne $Calls) { [void]$out.Add("${Name}: the driver made ${callsSeen} call(s) of the block, expected ${Calls}") }
    $headingsSeen = Get-Count $Console ([regex]::Escape('Your program asked for packages that are not installed:'))
    if ($headingsSeen -ne $Headings) { [void]$out.Add("${Name}: the question's heading was printed ${headingsSeen} time(s), expected ${Headings}") }
    $logNot = Get-Count $Log ([regex]::Escape('Runtime install: not offered for this build or provider.'))
    if ($logNot -ne $NotOffered) { [void]$out.Add("${Name}: the log says the offer was not made ${logNot} time(s), expected ${NotOffered}") }
    $rowNot = Get-Count $Result '(?m)^ROW=not_offered\s*$'
    if ($rowNot -ne $NotOffered) { [void]$out.Add("${Name}: the row state not_offered was recorded ${rowNot} time(s), expected ${NotOffered}") }
    $logDec = Get-Count $Log ([regex]::Escape('Runtime install: declined. Nothing was changed.'))
    if ($logDec -ne $Declined) { [void]$out.Add("${Name}: the log says the offer was declined ${logDec} time(s), expected ${Declined}") }
    $rowDec = Get-Count $Result '(?m)^ROW=declined\s*$'
    if ($rowDec -ne $Declined) { [void]$out.Add("${Name}: the row state declined was recorded ${rowDec} time(s), expected ${Declined}") }
    $rowAll = Get-Count $Result '(?m)^ROW='
    if ($rowAll -ne ($NotOffered + $Declined)) { [void]$out.Add("${Name}: ${rowAll} row state(s) were recorded, expected $($NotOffered + $Declined), so the block went somewhere the scenario does not expect") }
    if ($ChoiceRead) {
        if ([string]::IsNullOrWhiteSpace($ChoiceArgs)) {
            [void]$out.Add("${Name}: the console branch never reached its choice line")
        } else {
            if ($ChoiceArgs -notmatch '(?i)/T\s+30(\s|$)') { [void]$out.Add("${Name}: the choice line does not wait for 30 seconds (/T 30): $($ChoiceArgs.Trim())") }
            if ($ChoiceArgs -notmatch '(?i)/D\s+N(\s|$)') { [void]$out.Add("${Name}: the choice line does not default to N after the wait (/D N): $($ChoiceArgs.Trim())") }
            if ($ChoiceArgs -notmatch '(?i)/C\s+YN(\s|$)') { [void]$out.Add("${Name}: the choice line does not offer exactly Y and N (/C YN): $($ChoiceArgs.Trim())") }
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($ChoiceArgs)) {
        [void]$out.Add("${Name}: the console was read (choice ran) although a test answer or a signal decides")
    }
    if ($Packages) {
        $want = @($Packages -split '\|' | Sort-Object)
        $got = @(Get-PromptPackages $Console)
        if (($want -join '|') -ne ($got -join '|')) { [void]$out.Add("${Name}: the prompt lists [$($got -join ', ')], expected [$($want -join ', ')]") }
    }
    return $out.ToArray()
}

# The question comes before anything the yes changes, and is made once: the heading appears once in the console of a run that
# answered yes, and the install, the requirements edit and the rebuild are announced after it.
function Get-OrderProblems {
    param([string]$Console)
    $out = New-Object System.Collections.ArrayList
    $heading = 'Your program asked for packages that are not installed:'
    $headings = Get-Count $Console ([regex]::Escape($heading))
    if ($headings -ne 1) { [void]$out.Add("the question's heading was printed ${headings} time(s) in the whole run, expected once"); return $out.ToArray() }
    $at = $Console.IndexOf($heading, [System.StringComparison]::Ordinal)
    $first = $Console.IndexOf('Runtime install: installing ', [System.StringComparison]::Ordinal)
    if ($first -lt 0) { [void]$out.Add('the run never says it installs a package, so the order cannot be judged') }
    elseif ($first -lt $at) { [void]$out.Add('a package was installed before the question was asked') }
    $edit = $Console.IndexOf('Runtime install: added ', [System.StringComparison]::Ordinal)
    if ($edit -lt 0) { [void]$out.Add('the run never says it adds a package to requirements.txt, so the order cannot be judged') }
    elseif ($edit -lt $at) { [void]$out.Add('requirements.txt was edited before the question was asked') }
    $build = $Console.IndexOf('Runtime install: rebuilding the standalone EXE', [System.StringComparison]::Ordinal)
    if ($build -lt 0) { [void]$out.Add('the run never says it rebuilds the EXE, so the order cannot be judged') }
    elseif ($build -lt $at) { [void]$out.Add('the EXE was rebuilt before the question was asked') }
    return $out.ToArray()
}

# What is wrong with one real bootstrap of the runtime-install fixtures; nothing when the run shows what the kind expects.
# Good is the installable package the program asks for (empty when there is none), Ghost the name that cannot be installed.
function Get-RunProblems {
    param([string]$Kind, [string]$Good, [string]$Ghost, [bool]$Finished, [string]$Console, [string]$Setup, [string]$ErrText,
          [string]$ReqText, [string]$RowState, [string]$RowSite, [int]$SmokeRuns, [bool]$EnvHasGood)
    $out = New-Object System.Collections.ArrayList
    if (-not $Finished) { [void]$out.Add("${Kind}: the bootstrap did not finish within the time limit"); return $out.ToArray() }
    # the fixture reproduces the symptom: the first run named every module the program asks for, and the question listed them
    $asked = New-Object System.Collections.ArrayList
    if ($Good) { [void]$asked.Add($Good) }
    if ($Ghost) { [void]$asked.Add($Ghost) }
    foreach ($m in $asked) {
        if ($Setup -notmatch ('Your program needed the module ' + [regex]::Escape($m) + ' while it was running')) { [void]$out.Add("${Kind}: the first run never named the missing module ${m}, so the fixture does not reproduce the symptom") }
    }
    $listed = @(Get-PromptPackages $Console)
    $wantList = @($asked.ToArray() | Sort-Object)
    if (($listed -join '|') -ne ($wantList -join '|')) { [void]$out.Add("${Kind}: the question lists [$($listed -join ', ')], expected [$($wantList -join ', ')]") }
    if ($Setup -notmatch 'Runtime install: accepted\.') { [void]$out.Add("${Kind}: the log never says the question was answered yes") }
    # no provider cascade, however the step ended
    foreach ($pattern in @('REQ-009: cascading provider', 'REQ-009: cascade approved', 'REQ-009: cascade consent: accepted', 'Last chance: cascade approved')) {
        if ($Setup -match [regex]::Escape($pattern)) { [void]$out.Add("${Kind}: the log shows a provider cascade ($pattern)") }
    }
    if ($Good) {
        if ($Setup -notmatch ('Runtime install: installed ' + [regex]::Escape($Good) + '\.')) { [void]$out.Add("${Kind}: the log never says ${Good} was installed") }
        if ($Setup -notmatch ('Runtime install: added ' + [regex]::Escape($Good) + ' to requirements\.txt\.')) { [void]$out.Add("${Kind}: the log never says ${Good} was added to requirements.txt") }
        if ($ReqText -notmatch ('(?m)^\s*' + [regex]::Escape($Good) + '\s*$')) { [void]$out.Add("${Kind}: requirements.txt has no ${Good} line") }
        if (-not $EnvHasGood) { [void]$out.Add("${Kind}: ${Good} is not in the program's environment") }
    }
    if ($Ghost) {
        if ($Setup -notmatch ('Runtime install: could not install ' + [regex]::Escape($Ghost) + '\.')) { [void]$out.Add("${Kind}: the log never says ${Ghost} could not be installed") }
        if ($ReqText -match [regex]::Escape($Ghost)) { [void]$out.Add("${Kind}: requirements.txt holds ${Ghost}, which was never installed") }
    }
    $rebuildSaid = $Setup -match 'Runtime install: rebuilding the standalone EXE'
    $rebuilt = $Setup -match '\[REPAIR\] rebuild complete after runtime install'
    $checkSaid = $Setup -match 'Runtime install: running your program once more to check'
    $verified = $Setup -match 'Runtime install: verified'
    $stillSaid = $Setup -match 'Runtime install: the program still reports a missing module after the install'
    if ($Kind -eq 'stillmissing') {
        if (-not $rebuilt) { [void]$out.Add("${Kind}: the EXE was not rebuilt after the install") }
        if (-not $checkSaid) { [void]$out.Add("${Kind}: the log never says the program runs once more to check") }
        if (-not $stillSaid) { [void]$out.Add("${Kind}: the log does not say the program still reports a missing module") }
        if ($verified) { [void]$out.Add("${Kind}: the log says verified although the program still asks for ${Ghost}") }
        if ($RowState -ne 'still_missing') { [void]$out.Add("${Kind}: the recorded state is [${RowState}], expected still_missing") }
        if ($RowSite -ne 'exe') { [void]$out.Add("${Kind}: the offer was made at the [${RowSite}] site, expected exe") }
        if ($SmokeRuns -lt 2) { [void]$out.Add("${Kind}: the program ran ${SmokeRuns} time(s), expected the first run and the check run") }
        if ($ErrText -notmatch ("No module named '" + [regex]::Escape($Ghost) + "'")) { [void]$out.Add("${Kind}: the check run's error output does not name ${Ghost}") }
        if ($Good -and $ErrText -match ("No module named '" + [regex]::Escape($Good) + "'")) { [void]$out.Add("${Kind}: the check run still misses ${Good}, so the rebuild did not carry it") }
    } elseif ($Kind -eq 'failed') {
        if ($Setup -notmatch 'Runtime install: no package could be installed\. Nothing else was changed\.') { [void]$out.Add("${Kind}: the log does not say that no package could be installed and nothing else was changed") }
        if ($RowState -ne 'install_failed') { [void]$out.Add("${Kind}: the recorded state is [${RowState}], expected install_failed") }
        if ($rebuildSaid -or $rebuilt) { [void]$out.Add("${Kind}: the EXE was rebuilt after the install failed") }
        if ($checkSaid -or $verified -or $stillSaid) { [void]$out.Add("${Kind}: the program ran again after the install failed") }
        if ($SmokeRuns -ne 1) { [void]$out.Add("${Kind}: the program ran ${SmokeRuns} time(s), expected exactly the first run") }
    } elseif ($Kind -eq 'rebuildfailed') {
        if ($Setup -notmatch 'HP_TEST_FORCE_RTI_REBUILD_FAIL') { [void]$out.Add("${Kind}: the log never shows the test hook that makes the rebuild fail, so the failure is not the one asked for") }
        if (-not $rebuildSaid) { [void]$out.Add("${Kind}: the log never says the EXE is rebuilt") }
        if ($Setup -notmatch '\[ERROR\] Runtime install: the rebuild failed') { [void]$out.Add("${Kind}: the log does not report the failed rebuild") }
        if ($rebuilt) { [void]$out.Add("${Kind}: the log says the rebuild completed") }
        if ($RowState -ne 'rebuild_failed') { [void]$out.Add("${Kind}: the recorded state is [${RowState}], expected rebuild_failed") }
        if ($checkSaid -or $verified -or $stillSaid) { [void]$out.Add("${Kind}: the program ran again after the rebuild failed") }
        if ($SmokeRuns -ne 1) { [void]$out.Add("${Kind}: the program ran ${SmokeRuns} time(s), expected exactly the first run") }
    } else {
        [void]$out.Add("${Kind}: unknown kind")
    }
    return $out.ToArray()
}

$allPass = $true

# ---------------------------------------------------------------------------------------------------------------------
# gate rows: the real :runtime_install_offer block, run by cmd.exe in a tiny driver
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

$offerBlock = Get-BatBlock -StartLabel ':runtime_install_offer' -EndLabel ':rti_install_one'

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

# The driver defines what the cut-out block calls and clears every variable it reads, then applies the scenario's set lines and
# calls the block once per site. Stubs: :log appends to a file, :rti_row records the state, :emit_from_base64 copies the helper
# (the file the embedded payload is made from), and the console read, the one line that starts with choice, is replaced by a call
# that records its arguments and answers with errorlevel 2 (a no). Standard input is closed by the launch file.
function New-OfferDriver {
    param([string]$Dir, $Scenario, [string]$Python)
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in @(
        '@echo off', 'setlocal',
        ('set "LOG=' + (Join-Path $Dir '~driver.log') + '"'),
        ('set "RESULT=' + (Join-Path $Dir '~driver_result.txt') + '"'),
        ('set "CHOICE_ARGS=' + (Join-Path $Dir '~choice_args.txt') + '"'),
        ('set "SCAN_MASTER=' + (Join-Path $Dir '~scan_master.py') + '"'),
        ('set "HP_PY=' + $Python + '"'),
        'set "HP_RTI_OFFERED="', 'set "HP_RTI_VERIFYING="', 'set "HP_NUITKA_FALLBACK_USED="',
        'set "HP_ENV_MODE="', 'set "HP_TEST_RTM_ANSWER="', 'set "HP_CI_LANE="', 'set "NOINPUT="', 'set "HP_NONINTERACTIVE="',
        'set "HP_RTM_FOUND=1"',
        '>"%RESULT%" echo START'
    )) { [void]$lines.Add($l) }
    foreach ($k in $Scenario.Set.Keys) { [void]$lines.Add(('set "{0}={1}"' -f $k, $Scenario.Set[$k])) }
    $n = 0
    foreach ($site in $Scenario.Sites) {
        $n++
        [void]$lines.Add('call :runtime_install_offer ' + $site)
        [void]$lines.Add('>>"%RESULT%" echo CALL' + $n + ' site=' + $site + ' offered=%HP_RTI_OFFERED%')
    }
    foreach ($l in @('>>"%RESULT%" echo END', 'exit /b 0')) { [void]$lines.Add($l) }
    foreach ($l in $offerBlock) {
        if ($l -match '^\s*choice\s') { [void]$lines.Add(($l -replace '^(\s*)choice\s+', '$1call :choice_stub ')) } else { [void]$lines.Add($l) }
    }
    foreach ($l in @(
        ':log', 'setlocal', 'set "MSG=%~1"', '>>"%LOG%" echo %MSG%', 'endlocal', 'exit /b 0',
        ':rti_row', '>>"%RESULT%" echo ROW=%~1', 'exit /b 0',
        ':emit_from_base64', 'copy /y "%SCAN_MASTER%" "%~1" >nul 2>&1', 'exit /b 0',
        ':choice_stub', '>"%CHOICE_ARGS%" echo %*', 'exit /b 2'
    )) { [void]$lines.Add($l) }
    return $lines.ToArray()
}

$gateWork = Join-Path $here '~selftest_rtiedge_gate'
if (Test-Path -LiteralPath $gateWork) { Remove-Item -LiteralPath $gateWork -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $gateWork | Out-Null

# What each scenario must show. Set is applied after the driver cleared the variables the block reads; every scenario that is
# not the console one answers N through the test answer, so a block that offers when it should not leaves a clean red row
# (a prompt and a declined state) and never reaches the install.
function New-Gate {
    param([string]$Name, [string[]]$Sites, [System.Collections.IDictionary]$Set, [string[]]$Modules,
          [int]$Headings, [int]$NotOffered, [int]$Declined, [string]$Packages = '', [bool]$ChoiceRead = $false)
    return [pscustomobject]@{ Name = $Name; Sites = $Sites; Set = $Set; Modules = $Modules; Headings = $Headings; NotOffered = $NotOffered
                              Declined = $Declined; Packages = $Packages; ChoiceRead = $ChoiceRead }
}
$gateScenarios = @(
    (New-Gate -Name 'system_exe' -Sites @('exe') -Set ([ordered]@{ HP_ENV_MODE = 'system'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 0 -NotOffered 1 -Declined 0),
    (New-Gate -Name 'system_interp' -Sites @('interpreter') -Set ([ordered]@{ HP_ENV_MODE = 'system'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 0 -NotOffered 1 -Declined 0),
    (New-Gate -Name 'nointerp_exe' -Sites @('exe') -Set ([ordered]@{ HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 0 -NotOffered 1 -Declined 0),
    (New-Gate -Name 'fallback_exe' -Sites @('exe') -Set ([ordered]@{ HP_ENV_MODE = 'uv'; HP_NUITKA_FALLBACK_USED = '1'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 0 -NotOffered 1 -Declined 0),
    (New-Gate -Name 'control_offered' -Sites @('exe') -Set ([ordered]@{ HP_ENV_MODE = 'uv'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 1 -NotOffered 0 -Declined 1 -Packages 'xlsxwriter'),
    (New-Gate -Name 'once' -Sites @('exe', 'interpreter') -Set ([ordered]@{ HP_ENV_MODE = 'uv'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('xlsxwriter') -Headings 1 -NotOffered 0 -Declined 1),
    (New-Gate -Name 'console' -Sites @('exe') -Set ([ordered]@{ HP_ENV_MODE = 'uv' }) -Modules @('xlsxwriter') -Headings 1 -NotOffered 0 -Declined 1 -ChoiceRead $true),
    (New-Gate -Name 'listing' -Sites @('exe') -Set ([ordered]@{ HP_ENV_MODE = 'uv'; HP_TEST_RTM_ANSWER = 'N' }) -Modules @('cv2', 'PIL', 'pvw_listing_other_') -Headings 1 -NotOffered 0 -Declined 1 -Packages 'opencv-python|pillow|pvw_listing_other_')
)

function Invoke-GateScenario {
    param($Scenario)
    $dir = Join-Path $gateWork $Scenario.Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $helperPath -Destination (Join-Path $dir '~scan_master.py') -Force
    Write-CrLf -Path (Join-Path $dir '~runtime_missing_modules.txt') -Lines $Scenario.Modules
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines (New-OfferDriver -Dir $dir -Scenario $Scenario -Python $runnerPython)
    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines @('@echo off', 'call ~driver.bat > ~driver_console.txt 2>&1 < nul', 'exit /b %ERRORLEVEL%')
    $launch = Invoke-Launch -Dir $dir -LaunchName '~driver_launch.cmd' -LimitMs 180000
    return [pscustomobject]@{
        Name = $Scenario.Name; Finished = $launch.Finished; ExitCode = $launch.ExitCode; Seconds = $launch.Seconds; Error = $launch.Error
        Console = (Read-Text (Join-Path $dir '~driver_console.txt')); Log = (Read-Text (Join-Path $dir '~driver.log'))
        Result = (Read-Text (Join-Path $dir '~driver_result.txt')); ChoiceArgs = (Read-Text (Join-Path $dir '~choice_args.txt'))
    }
}

$gateResults = @{}
foreach ($s in $gateScenarios) {
    if ($null -eq $offerBlock) {
        $gateResults[$s.Name] = [pscustomobject]@{ Problems = @('the label :runtime_install_offer (up to :rti_install_one) is not in run_setup.bat, so the program is never offered the install'); Details = ([ordered]@{ scenario = $s.Name; blockFound = $false }) }
        continue
    }
    if (-not $runnerPython) {
        $gateResults[$s.Name] = [pscustomobject]@{ Problems = @('no python on the runner could run the helper, so the block cannot list packages'); Details = ([ordered]@{ scenario = $s.Name; pythonFound = $false }) }
        continue
    }
    $run = Invoke-GateScenario $s
    $problems = @(Get-GateProblems -Name $s.Name -Finished ([bool]$run.Finished) -Result $run.Result -Log $run.Log -Console $run.Console -ChoiceArgs $run.ChoiceArgs `
        -Headings $s.Headings -NotOffered $s.NotOffered -Declined $s.Declined -Calls @($s.Sites).Count -Packages $s.Packages -ChoiceRead ([bool]$s.ChoiceRead))
    Add-Evidence -Title ('gate ' + $s.Name + ' (' + $run.Seconds + ' s, driver exit ' + $run.ExitCode + ')') -Text ("--- result`n" + $run.Result + "`n--- log`n" + $run.Log + "`n--- choice args`n" + $run.ChoiceArgs + "`n--- console`n" + $run.Console) -MaxLines 70
    $details = [ordered]@{
        scenario = $s.Name; finished = [bool]$run.Finished; seconds = $run.Seconds; driverExit = $run.ExitCode
        headings = (Get-Count $run.Console ([regex]::Escape('Your program asked for packages that are not installed:')))
        notOfferedLogged = (Get-Count $run.Log ([regex]::Escape('Runtime install: not offered for this build or provider.')))
        declinedLogged = (Get-Count $run.Log ([regex]::Escape('Runtime install: declined. Nothing was changed.')))
        choiceArgs = ([string]$run.ChoiceArgs).Trim()
        packagesListed = @(Get-PromptPackages $run.Console)
    }
    if ($run.Error) { $details['error'] = $run.Error }
    if ($problems.Count -gt 0) { $details['problems'] = @($problems); $details['result'] = @(($run.Result -split "`r?`n") | Where-Object { $_ }) }
    $gateResults[$s.Name] = [pscustomobject]@{ Problems = $problems; Details = $details }
}
function Get-GateRow {
    param([string[]]$Names, [string[]]$ExtraProblems = @(), $ExtraDetails = $null)
    $problems = New-Object System.Collections.ArrayList
    $details = [ordered]@{}
    foreach ($nm in $Names) {
        foreach ($p in @($gateResults[$nm].Problems)) { [void]$problems.Add($p) }
        $details[$nm] = $gateResults[$nm].Details
    }
    foreach ($p in @($ExtraProblems)) { if ($p) { [void]$problems.Add($p) } }
    if ($null -ne $ExtraDetails) { foreach ($k in $ExtraDetails.Keys) { $details[$k] = $ExtraDetails[$k] } }
    return [pscustomobject]@{ Pass = [bool]($problems.Count -eq 0); Details = $details }
}

# ---------------------------------------------------------------------------------------------------------------------
# run rows: three real default bootstraps whose program asks for modules by a name built at run time
# ---------------------------------------------------------------------------------------------------------------------
# The program catches its own ImportError, prints the traceback to stderr and exits 0, like a GUI callback that carries on. The
# names are joined at run time so neither pipreqs nor PyInstaller sees an import and installs them up front. xlsxwriter is a real
# package (the one the other script uses); a name with a trailing underscore is refused by uv before any index is asked, so its
# install fails the same way on every run, with no dependence on what an index holds.
$appCodes = @{}
$appCodes['stillmissing'] = @'
import importlib
import traceback


def on_click():
    # Stand-in for a GUI callback: each exception is caught, its traceback goes to stderr, and the program carries on and exits 0.
    for parts in (("xlsx", "writer"), ("pvw_still_missing", "_")):
        try:
            importlib.import_module("".join(parts))
        except ImportError:
            traceback.print_exc()


if __name__ == "__main__":
    on_click()
    print("edge app ok")
'@
$appCodes['failed'] = @'
import importlib
import traceback


def on_click():
    # Stand-in for a GUI callback: the exception is caught, its traceback goes to stderr, and the program carries on and exits 0.
    for parts in (("pvw_ghost", "_pkg_"),):
        try:
            importlib.import_module("".join(parts))
        except ImportError:
            traceback.print_exc()


if __name__ == "__main__":
    on_click()
    print("edge app ok")
'@
$appCodes['rebuildfailed'] = @'
import importlib
import traceback


def on_click():
    # Stand-in for a GUI callback: the exception is caught, its traceback goes to stderr, and the program carries on and exits 0.
    for parts in (("xlsx", "writer"),):
        try:
            importlib.import_module("".join(parts))
        except ImportError:
            traceback.print_exc()


if __name__ == "__main__":
    on_click()
    print("edge app ok")
'@

$runTimeoutMs = 20 * 60 * 1000

# Bootstraps the program in a fresh folder with the answer yes; never throws. ExtraSet holds set lines the launch file adds
# (cmd's own set, which is reliable where removing a variable from this process is not, gap T12).
function Invoke-EdgeBootstrap {
    param([string]$Kind, [string[]]$ExtraSet = @())
    $res = [ordered]@{ Kind = $Kind; Finished = $false; ExitCode = -1; Seconds = 0; Dir = ''; Console = ''; Setup = ''; ErrText = ''
                       ReqText = ''; RowState = ''; RowSite = ''; SmokeRuns = 0; EnvHasGood = $false; StatusState = ''; Error = '' }
    try {
        $dir = Join-Path $here ('~selftest_rtiedge_' + $Kind)
        $res.Dir = $dir
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath $batchPath -Destination $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value $appCodes[$Kind] -Encoding ASCII
        $consoleName = '~edge_' + $Kind + '.log'
        $subNdjson = Join-Path $dir '~sub.ndjson'
        $launch = @('@echo off', 'set "HP_PVW_KNOWN_IDEMPOTENT="', 'set "HP_TEST_FORCE_RTI_REBUILD_FAIL="', 'set "HP_TEST_RTM_ANSWER=Y"', ('set "HP_NDJSON=' + $subNdjson + '"'))
        if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $launch += 'set "HP_CI_LANE=test"' }
        foreach ($l in $ExtraSet) { $launch += $l }
        $launch += @("call run_setup.bat > $consoleName 2>&1 < nul", 'exit /b %ERRORLEVEL%')
        Write-CrLf -Path (Join-Path $dir '~edge_launch.cmd') -Lines $launch
        $l = Invoke-Launch -Dir $dir -LaunchName '~edge_launch.cmd' -LimitMs $runTimeoutMs
        $res.Finished = $l.Finished; $res.ExitCode = $l.ExitCode; $res.Seconds = $l.Seconds
        if ($l.Error) { $res.Error = $l.Error }
        $res.Console = Read-Text (Join-Path $dir $consoleName)
        $res.Setup = Read-Text (Join-Path $dir '~setup.log')
        $res.ErrText = Read-Text (Join-Path $dir '~run.err.txt')
        $res.ReqText = Read-Text (Join-Path $dir 'requirements.txt')
        $res.SmokeRuns = (Get-Count $res.Setup 'Entry smoke exit=')
        $pyPath = Join-Path $dir '.uv_env\Scripts\python.exe'
        if (Test-Path -LiteralPath $pyPath) {
            & $pyPath -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('xlsxwriter') else 1)" 2>$null
            $res.EnvHasGood = ($LASTEXITCODE -eq 0)
        }
        if (Test-Path -LiteralPath $subNdjson) {
            foreach ($line in (Get-Content -LiteralPath $subNdjson -Encoding ASCII)) {
                if (-not $line.Trim()) { continue }
                try { $row = ($line | ConvertFrom-Json) } catch { continue }
                if ($row.id -eq 'self.runtime.install') { $res.RowState = [string]$row.details.state; $res.RowSite = [string]$row.details.site }
            }
        }
        $statusPath = Join-Path $dir '~bootstrap.status.json'
        if (Test-Path -LiteralPath $statusPath) {
            try { $res.StatusState = [string](Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { $res.StatusState = '' }
        }
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

function Get-RunRow {
    param([string]$Kind, [string]$Good, [string]$Ghost, $Run, [string[]]$ExtraProblems = @())
    $problems = New-Object System.Collections.ArrayList
    foreach ($p in @(Get-RunProblems -Kind $Kind -Good $Good -Ghost $Ghost -Finished ([bool]$Run.Finished) -Console $Run.Console -Setup $Run.Setup -ErrText $Run.ErrText `
            -ReqText $Run.ReqText -RowState $Run.RowState -RowSite $Run.RowSite -SmokeRuns ([int]$Run.SmokeRuns) -EnvHasGood ([bool]$Run.EnvHasGood))) { [void]$problems.Add($p) }
    foreach ($p in @($ExtraProblems)) { if ($p) { [void]$problems.Add($p) } }
    $details = [ordered]@{
        finished = [bool]$Run.Finished; seconds = $Run.Seconds; exitCode = $Run.ExitCode; statusState = $Run.StatusState
        rowState = $Run.RowState; rowSite = $Run.RowSite; smokeRuns = $Run.SmokeRuns; envHasGood = [bool]$Run.EnvHasGood
        headings = (Get-Count $Run.Console ([regex]::Escape('Your program asked for packages that are not installed:')))
        packagesListed = @(Get-PromptPackages $Run.Console)
    }
    if ($Run.Error) { $details['error'] = $Run.Error }
    if ($problems.Count -gt 0) {
        $details['problems'] = @($problems.ToArray())
        $details['excerpt'] = @(Get-Excerpt -Text $Run.Setup -Pattern 'Runtime install|Your program needed|Entry smoke|EXE smokerun|REQ-009|Last chance|\[REPAIR\]|\[ERROR\]|\[TEST\]|\[STATUS\]')
        $details['stderrTail'] = @(Get-Excerpt -Text $Run.ErrText -Pattern 'Error|No module' -Max 6)
    }
    return [pscustomobject]@{ Pass = [bool]($problems.Count -eq 0); Details = $details; Problems = @($problems.ToArray()) }
}

# ---------------------------------------------------------------- stillmissing: the check run still names a module
$smRun = Invoke-EdgeBootstrap -Kind 'stillmissing'
$smRow = Get-RunRow -Kind 'stillmissing' -Good 'xlsxwriter' -Ghost 'pvw_still_missing_' -Run $smRun
Add-Evidence -Title ('run stillmissing (' + $smRun.Seconds + ' s, smoke runs ' + $smRun.SmokeRuns + ', state ' + $smRun.RowState + ')') -Text ((Get-Excerpt -Text $smRun.Setup -Pattern 'Runtime install|Your program needed|Entry smoke|EXE smokerun|REQ-009|Last chance|\[REPAIR\]|\[ERROR\]|\[TEST\]|\[STATUS\]' -Max 70) -join "`n")

# ---------------------------------------------------------------- failed: nothing can be installed
$fdRun = Invoke-EdgeBootstrap -Kind 'failed'
$fdRow = Get-RunRow -Kind 'failed' -Good '' -Ghost 'pvw_ghost_pkg_' -Run $fdRun
Add-Evidence -Title ('run failed (' + $fdRun.Seconds + ' s, smoke runs ' + $fdRun.SmokeRuns + ', state ' + $fdRun.RowState + ')') -Text ((Get-Excerpt -Text $fdRun.Setup -Pattern 'Runtime install|Your program needed|Entry smoke|EXE smokerun|REQ-009|Last chance|\[REPAIR\]|\[ERROR\]|\[TEST\]|\[STATUS\]' -Max 70) -join "`n")

# ---------------------------------------------------------------- rebuildfailed: the install works, the rebuild does not
$rbRun = Invoke-EdgeBootstrap -Kind 'rebuildfailed' -ExtraSet @('set "HP_TEST_FORCE_RTI_REBUILD_FAIL=1"')
$rbRow = Get-RunRow -Kind 'rebuildfailed' -Good 'xlsxwriter' -Ghost '' -Run $rbRun
Add-Evidence -Title ('run rebuildfailed (' + $rbRun.Seconds + ' s, smoke runs ' + $rbRun.SmokeRuns + ', state ' + $rbRun.RowState + ', status ' + $rbRun.StatusState + ')') -Text ((Get-Excerpt -Text $rbRun.Setup -Pattern 'Runtime install|Your program needed|Entry smoke|EXE smokerun|REQ-009|Last chance|\[REPAIR\]|\[ERROR\]|\[TEST\]|\[STATUS\]' -Max 70) -join "`n")

# ---------------------------------------------------------------------------------------------------------------------
# the rows
# ---------------------------------------------------------------------------------------------------------------------
# once (REQ-018.14): the question is asked once per invocation, before anything the yes changes, and the console read is bounded.
# The second call of the block (a later provider tier verifies again and calls it again) asks nothing; the console branch has a
# choice line limited to 30 seconds that defaults to N; and in the real yes run of stillmissing the question stands once in the
# whole console, ahead of the install, the requirements edit and the rebuild.
$orderProblems = @(Get-OrderProblems $smRun.Console)
$row = Get-GateRow -Names @('once', 'console') -ExtraProblems $orderProblems -ExtraDetails ([ordered]@{ orderInRealRun = [ordered]@{ problems = $orderProblems; headings = (Get-Count $smRun.Console ([regex]::Escape('Your program asked for packages that are not installed:'))) } })
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.runtime.install.once'; req = 'REQ-018.14'; pass = $row.Pass
    desc = 'REQ-018.14: the install question is asked once per invocation (a second call of the offer asks nothing), before the install, the requirements edit and the rebuild, and its console read waits at most 30 seconds and defaults to no'
    details = $row.Details
})

# notoffered (REQ-018.16): a system Python, no provider and an EXE built by the fallback build system are not offered the
# question, and the log says so; the control run with a uv provider is asked, so the driver can offer at all.
$row = Get-GateRow -Names @('system_exe', 'system_interp', 'nointerp_exe', 'fallback_exe', 'control_offered')
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.runtime.install.notoffered'; req = 'REQ-018.16'; pass = $row.Pass
    desc = 'REQ-018.16: with a system Python, no selected provider or an EXE built by the fallback build system the install question is not made and the log says it was not offered; a uv provider is asked'
    details = $row.Details
})

# listing (REQ-018.22): the prompt names every package it would install (cv2 is opencv-python, PIL is pillow, another module is
# its own package), run through the real helper.
$row = Get-GateRow -Names @('listing')
if (-not $row.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.runtime.install.listing'; req = 'REQ-018.22'; pass = $row.Pass
    desc = 'REQ-018.22: the install question lists every package it would install, naming opencv-python for cv2 and pillow for PIL and using any other module name as the package name'
    details = $row.Details
})

if (-not $smRow.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.runtime.install.stillmissing'; req = 'REQ-018.20'; pass = $smRow.Pass
    desc = 'REQ-018.20: after a yes, when the check run still names a missing module the log says so and not verified (one package installs, one cannot, no provider cascade follows)'
    details = $smRow.Details
})

if (-not $fdRow.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.runtime.install.failed'; req = 'REQ-018.21'; pass = $fdRow.Pass
    desc = 'REQ-018.21: when no package can be installed the step stops there (no requirements edit, no rebuild, no second run) and no provider cascade starts'
    details = $fdRow.Details
})

if (-not $rbRow.Pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.runtime.install.rebuildfailed'; req = 'REQ-018.21'; pass = $rbRow.Pass
    desc = 'REQ-018.21: when the rebuild after the install fails the step stops there (the check run does not start) and no provider cascade starts'
    details = $rbRow.Details
})

if (-not $allPass) { exit 1 }
exit 0
