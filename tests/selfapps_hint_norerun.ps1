# ASCII only
# selfapps_hint_norerun.ps1 - Item 96 (README REQ-018 and REQ-007): the failure hints are read from what the
# failed run already printed; the bootstrapper does not start the program one more time to collect them.
#
# Tags. The two count rows carry the goal REQ-018, not REQ-018.1 or REQ-018.2: they show that no start is silent,
# which the failure hints used to violate. The consent itself (the question before the repair loop's first extra start,
# Item 97) is shown by selfapps_repair_consent.ps1, whose rows carry REQ-018.1 and REQ-018.2.
#
# History. After a failed EXE verification run, :exe_smokerun_hints used to launch dist\<env>.exe again (through
# ~exe_hint_rerun.ps1) only to capture its error text. That start was beyond the single automatic run of REQ-018.1, nobody
# had consented to it (REQ-018.2), and no line announced it, unlike the verification run (:warn_user_code_launch main) and
# the --hidden-import repair loop (:warn_user_code_launch hidden_import). A program that is not safe to run twice, for
# example one that overwrites a file or sends a request, ran again without a word. The launch ledger of gap T1
# (selfapps_launch_ledger.ps1) never saw it because its programs pass, and a passing run never reaches the hint step.
#
# How starts are counted. Each program appends one JSON line per start to a ledger whose ABSOLUTE path comes from the
# environment (HINT_LEDGER): the repair loop starts the EXE from dist\, so a ledger relative to the working directory would
# be split across two folders. Every start must be accounted for by the setup log:
#     starts <= announced + rebuilds
# where announced is the number of "Verifying the built standalone EXE" lines (the verification run and the repair loop each
# announce before they start the program) and rebuilds is the number of "[REPAIR][HIDDEN_IMPORT] Adding --hidden-import="
# lines (the loop makes one run after each rebuild, covered by its announcement). A start beyond that is a silent one.
# Before Items 96 and 97 (main when this script was written): the plain failure started the program 3 times against 2
# announcements, the repaired one 4 against 2 + 1. With the hint fix alone they are 2 against 2 and 3 against 2 + 1; with
# the repair question as well, a non-interactive run declines it, so the plain failure is 1 against 1 and the repaired
# scenario below answers yes through HP_TEST_REPAIR_ANSWER to keep the repair under test.
#
# Scenarios, one fresh folder each (both programs write the ledger first, then fail):
#   plain     the program opens a data file that does not exist (exit 1). Nothing can be repaired; before Item 97 the repair
#             loop made its one diagnostic run and ended, now a non-interactive run declines the question and the program is
#             started once. Rows: self.launch.count.failed_run (starts accounted for), self.hint.datafile.capture (the
#             data-file hint still names the missing file, so the hint is read from real captured text).
#   repaired  the program imports an installed package by a computed name (the same shape as selfapps_hidden_import.ps1), so
#             the first run fails with ModuleNotFoundError, the loop adds --hidden-import and rebuilds, and the rebuilt EXE
#             then fails on the same missing data file. Rows: self.launch.count.repaired_run (starts accounted for),
#             self.hint.final_failure (the hint describes the failure of the repaired EXE, the missing file, and does not
#             repeat the "hidden import likely missing" hint for a module the repair already fixed).
# Each row also needs its precondition (the verification run failed, the program really ran, the repair fired where it
# should), so a bootstrap that never reached the step cannot pass.
#
# derived requirement: ids and req tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and
# the requirement-trace tests scan text, not PowerShell). The skip loop below uses a map on purpose; the real emissions are literal.
#
# Lane: real and conda-full (uv and conda providers), gating from its first run (AGENTS.md "New tests gate immediately").
# Emits: self.launch.count.failed_run, self.hint.datafile.capture, self.launch.count.repaired_run, self.hint.final_failure
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

$allIds = @('self.launch.count.failed_run', 'self.hint.datafile.capture', 'self.launch.count.repaired_run', 'self.hint.final_failure')
$reqOf = @{
    'self.launch.count.failed_run' = 'REQ-018'; 'self.hint.datafile.capture' = 'REQ-007'
    'self.launch.count.repaired_run' = 'REQ-018'; 'self.hint.final_failure' = 'REQ-007'
}
function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = $reqOf[$rowId]; pass = $Pass; desc = $Desc; details = $Details })
    }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'Failure hints without a further start (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'Failure hints without a further start: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# --- pure helpers (kept free of the file system so they can be exercised on their own) ---

# The accounting of one bootstrap: how many starts the ledger shows and how many the setup log accounts for.
function Get-Accounting {
    param([int]$Starts, [int]$Announced, [int]$Rebuilds)
    $allowed = $Announced + $Rebuilds
    return [ordered]@{
        starts      = $Starts
        announced   = $Announced
        rebuilds    = $Rebuilds
        allowed     = $allowed
        unannounced = [Math]::Max(0, $Starts - $allowed)
    }
}

# Counts of the log lines the accounting rests on. The setup log is the one file every :log line reaches exactly once.
function Get-LogCounts {
    param([string]$SetupText)
    return [ordered]@{
        announced = [regex]::Matches($SetupText, 'Verifying the built standalone EXE').Count
        rebuilds  = [regex]::Matches($SetupText, '\[REPAIR\]\[HIDDEN_IMPORT\] Adding --hidden-import=').Count
        failedRun = [regex]::IsMatch($SetupText, 'EXE smokerun: exited -?[1-9][0-9]* \(non-zero\)')
        repairColorama = [regex]::IsMatch($SetupText, '\[REPAIR\]\[HIDDEN_IMPORT\] Adding --hidden-import=colorama')
        dataFileHint = [regex]::IsMatch($SetupText, '\[HINT\]\[DATA_FILE\] Missing data file detected: hint_missing_data\.json')
        importHint = [regex]::IsMatch($SetupText, '\[HINT\]\[HIDDEN_IMPORT\]')
    }
}

# What is wrong with one starts row, as short sentences; nothing when the run shows what the scenario expects.
function Get-StartProblems {
    param([string]$Scenario, $Run, $Counts, $Accounting)
    $out = New-Object System.Collections.ArrayList
    if (-not $Run.Finished) { [void]$out.Add("${Scenario}: the bootstrap did not finish within the time limit"); return $out.ToArray() }
    if (-not $Counts.failedRun) { [void]$out.Add("${Scenario}: the EXE verification run did not fail, so there was nothing to explain") }
    if ($Accounting.starts -lt 1) { [void]$out.Add("${Scenario}: the ledger is empty, so the program never ran") }
    if ($Accounting.announced -lt 1) { [void]$out.Add("${Scenario}: no announcement of the verification run was logged, so the counts prove nothing") }
    if ($Scenario -eq 'plain' -and $Accounting.rebuilds -ne 0) { [void]$out.Add("${Scenario}: the repair loop rebuilt $($Accounting.rebuilds) time(s), expected none") }
    if ($Scenario -eq 'repaired' -and -not $Counts.repairColorama) { [void]$out.Add("${Scenario}: the repair loop never added --hidden-import=colorama, so the second failure was not reached") }
    if ($Accounting.unannounced -gt 0) {
        [void]$out.Add("${Scenario}: the program was started $($Accounting.starts) time(s) but the log accounts for $($Accounting.allowed) ($($Accounting.announced) announced + $($Accounting.rebuilds) after rebuilds): $($Accounting.unannounced) start(s) nobody announced")
    }
    return $out.ToArray()
}

# What is wrong with one hint row.
function Get-HintProblems {
    param([string]$Scenario, $Run, $Counts, [bool]$RequireNoImportHint)
    $out = New-Object System.Collections.ArrayList
    if (-not $Run.Finished) { [void]$out.Add("${Scenario}: the bootstrap did not finish within the time limit"); return $out.ToArray() }
    if (-not $Counts.failedRun) { [void]$out.Add("${Scenario}: the EXE verification run did not fail, so no hint is expected") }
    if ($Scenario -eq 'repaired' -and -not $Counts.repairColorama) { [void]$out.Add("${Scenario}: the repair loop never added --hidden-import=colorama, so the hint cannot describe a repaired EXE") }
    if (-not $Counts.dataFileHint) { [void]$out.Add("${Scenario}: the data-file hint naming hint_missing_data.json is not in the setup log") }
    if ($RequireNoImportHint -and $Counts.importHint) { [void]$out.Add("${Scenario}: the log still says a hidden import is likely missing, for a module the repair had already added") }
    return $out.ToArray()
}

# A few log lines that explain a red row, printable ASCII only and cut short.
function Get-Excerpt {
    param([string]$Text, [int]$Max = 24)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match 'Verifying the built standalone EXE|EXE smokerun|Entry smoke|\[HINT\]|\[REPAIR\]|\[ERROR\]|\[STATUS\]') {
            $clean = ($l -replace '[^\x20-\x7E]', '?')
            if ($clean.Length -gt 150) { $clean = $clean.Substring(0, 150) }
            [void]$keep.Add($clean)
            if ($keep.Count -ge $Max) { break }
        }
    }
    return $keep.ToArray()
}

function Read-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
    if ($null -eq $t) { return '' }
    return [string]$t
}

# One object per ledger line (a line that is not JSON becomes an object with a parseError field, still one start). The
# callers wrap the call in @( ) so an empty ledger is an empty array and a single line is still an array; a leading comma
# here would make that wrapper hold the whole array as ONE element and every ledger would count as one start.
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

# --- the two programs; both write the ledger FIRST, so a start that fails at once is still counted ---
$appCode = @{}
$appCode['plain'] = @'
import json
import os
import sys

with open(os.environ["HINT_LEDGER"], "a") as f:
    f.write(json.dumps({"scenario": "plain", "frozen": bool(getattr(sys, "frozen", False)), "cwd": os.getcwd()}) + "\n")

with open("hint_missing_data.json", "r") as f:
    print(f.read())
'@
# colorama is installed (requirements.txt) but imported by a runtime string, so PyInstaller does not bundle it and the
# first run fails with ModuleNotFoundError; after the repair the same program reaches the missing data file.
$appCode['repaired'] = @'
import importlib
import json
import os
import sys

with open(os.environ["HINT_LEDGER"], "a") as f:
    f.write(json.dumps({"scenario": "repaired", "frozen": bool(getattr(sys, "frozen", False)), "cwd": os.getcwd()}) + "\n")

mod = importlib.import_module('colorama')
with open("hint_missing_data.json", "r") as f:
    print(mod.__name__, f.read())
'@

# A hang must be a red row; a default bootstrap of a tiny program needs a few minutes at most.
$runTimeoutMs = 15 * 60 * 1000

# Bootstraps one program in a fresh folder; never throws. Returns what the verdicts read.
function Invoke-HintScenario {
    param([string]$Scenario, [string]$Requirements)
    $res = [ordered]@{ Scenario = $Scenario; Finished = $false; ExitCode = -1; Seconds = 0; Dir = ''; Setup = ''; Console = ''; Ledger = @(); Error = '' }
    try {
        $dir = Join-Path $here ('~selftest_hint_' + $Scenario)
        $res.Dir = $dir
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Copy-Item -LiteralPath $batchPath -Destination $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value $appCode[$Scenario] -Encoding ASCII
        if ($Requirements) { Set-Content -LiteralPath (Join-Path $dir 'requirements.txt') -Value $Requirements -Encoding ASCII }
        $consoleName = '~hint_' + $Scenario + '.log'
        Set-Content -LiteralPath (Join-Path $dir '~hint_launch.cmd') -Value @('@echo off', "call run_setup.bat > $consoleName 2>&1 < nul", 'exit /b %ERRORLEVEL%') -Encoding ASCII
        $vars = [ordered]@{ HP_SKIP_PIPREQS = '1'; HINT_LEDGER = (Join-Path $dir '~hint_ledger.jsonl') }
        # Item 97: the repair loop asks before it starts the program again and a non-interactive run declines. The repaired
        # scenario is about what the hint says AFTER a repair, so it consents; the plain scenario keeps the default answer.
        if ($Scenario -eq 'repaired') { $vars['HP_TEST_REPAIR_ANSWER'] = 'Y' }
        if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
        $saved = @{}
        foreach ($k in @($vars.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$vars[$k]) }
        $started = Get-Date
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'call ~hint_launch.cmd') -WorkingDirectory $dir -NoNewWindow -PassThru
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
        $res.Console = Read-Text (Join-Path $dir $consoleName)
        $res.Setup = Read-Text (Join-Path $dir '~setup.log')
        $res.Ledger = @(Read-Ledger (Join-Path $dir '~hint_ledger.jsonl'))
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

function Show-Evidence {
    param([string]$Title, $Run, $Counts, $Accounting)
    Write-Host ("=== hint without a further start: {0} ===" -f $Title)
    foreach ($e in @($Run.Ledger)) {
        if ($e.PSObject.Properties.Name -contains 'scenario') { Write-Host ("ledger: scenario={0} frozen={1} cwd={2}" -f $e.scenario, $e.frozen, $e.cwd) } else { Write-Host ("ledger: unreadable line {0}" -f $e.parseError) }
    }
    Write-Host ("starts={0} announced={1} rebuilds={2} allowed={3} unannounced={4}" -f $Accounting.starts, $Accounting.announced, $Accounting.rebuilds, $Accounting.allowed, $Accounting.unannounced)
    foreach ($l in @(Get-Excerpt $Run.Setup)) { Write-Host ("setup: " + $l) }
}

function Get-Details {
    param($Run, $Counts, $Accounting, [string[]]$Problems)
    $ledger = @($Run.Ledger)
    $details = [ordered]@{
        finished = [bool]$Run.Finished; seconds = $Run.Seconds; exitCode = $Run.ExitCode
        starts = $Accounting.starts; announced = $Accounting.announced; rebuilds = $Accounting.rebuilds
        allowed = $Accounting.allowed; unannounced = $Accounting.unannounced
        startsFromDist = @($ledger | Where-Object { ([string]$_.cwd) -match '[\\/]dist$' }).Count
        interpreterStarts = @($ledger | Where-Object { $_.frozen -eq $false }).Count
        failedRun = [bool]$Counts.failedRun; repairColorama = [bool]$Counts.repairColorama
        dataFileHint = [bool]$Counts.dataFileHint; importHint = [bool]$Counts.importHint
    }
    if ($Run.Error) { $details['error'] = $Run.Error }
    if (@($Problems).Count -gt 0) { $details['problems'] = @($Problems); $details['excerpt'] = @(Get-Excerpt $Run.Setup) }
    return $details
}

$allPass = $true

# ---------------------------------------------------------------- plain: nothing can be repaired
$plain = Invoke-HintScenario -Scenario 'plain' -Requirements ''
$plainCounts = Get-LogCounts $plain.Setup
$plainAcc = Get-Accounting -Starts @($plain.Ledger).Count -Announced $plainCounts.announced -Rebuilds $plainCounts.rebuilds
Show-Evidence -Title 'plain failure' -Run $plain -Counts $plainCounts -Accounting $plainAcc

$startProblems = @(Get-StartProblems -Scenario 'plain' -Run $plain -Counts $plainCounts -Accounting $plainAcc)
if ($startProblems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.count.failed_run'; req = 'REQ-018'; pass = [bool]($startProblems.Count -eq 0)
    desc = 'REQ-018: after a failed EXE verification run every start of the program is announced; the failure hints do not start it again'
    details = (Get-Details -Run $plain -Counts $plainCounts -Accounting $plainAcc -Problems $startProblems)
})
$hintProblems = @(Get-HintProblems -Scenario 'plain' -Run $plain -Counts $plainCounts -RequireNoImportHint $false)
if ($hintProblems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.hint.datafile.capture'; req = 'REQ-007'; pass = [bool]($hintProblems.Count -eq 0)
    desc = 'REQ-007: the data-file hint after a failed EXE run still names the missing file, read from the output the failed run printed'
    details = (Get-Details -Run $plain -Counts $plainCounts -Accounting $plainAcc -Problems $hintProblems)
})

# ---------------------------------------------------------------- repaired: a hidden-import repair, then a second failure
$rep = Invoke-HintScenario -Scenario 'repaired' -Requirements 'colorama'
$repCounts = Get-LogCounts $rep.Setup
$repAcc = Get-Accounting -Starts @($rep.Ledger).Count -Announced $repCounts.announced -Rebuilds $repCounts.rebuilds
Show-Evidence -Title 'hidden-import repair, then a missing data file' -Run $rep -Counts $repCounts -Accounting $repAcc

$startProblems = @(Get-StartProblems -Scenario 'repaired' -Run $rep -Counts $repCounts -Accounting $repAcc)
if ($startProblems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.count.repaired_run'; req = 'REQ-018'; pass = [bool]($startProblems.Count -eq 0)
    desc = 'REQ-018: after a hidden-import repair and a second failure every start is announced or is the run after a rebuild; the hints do not start the program again'
    details = (Get-Details -Run $rep -Counts $repCounts -Accounting $repAcc -Problems $startProblems)
})
$hintProblems = @(Get-HintProblems -Scenario 'repaired' -Run $rep -Counts $repCounts -RequireNoImportHint $true)
if ($hintProblems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.hint.final_failure'; req = 'REQ-007'; pass = [bool]($hintProblems.Count -eq 0)
    desc = 'REQ-007: after a hidden-import repair the hint describes the failure of the repaired EXE (the missing data file), not the module the repair already added'
    details = (Get-Details -Run $rep -Counts $repCounts -Accounting $repAcc -Problems $hintProblems)
})

if (-not $allPass) { exit 1 }
exit 0
