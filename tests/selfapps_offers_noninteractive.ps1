# ASCII only
# selfapps_offers_noninteractive.ps1 - Item 94b (README REQ-018.9): in a non-interactive run every elective offer
# declines without waiting for input.
#
# REQ-018.9 [critical]: the bootstrapper shall, in a non-interactive run, decline each elective offer (the post-execution
# checkpoint, the optimized build, the missing-package install and the last-chance offer) without waiting for input. A
# non-interactive run is one where NOINPUT, HP_NONINTERACTIVE or HP_CI_LANE is set (README Terms). Until this script nothing
# showed that each of the four offers reads all three signals: every CI lane sets HP_CI_LANE, so a gate that read only that
# one would pass every other row, and gap T12 (selfapps_noflag_default.ps1) runs with none of the three set.
#
# Scenarios, one fresh folder per program (an offer is made only after a FRESH verification run):
#   noinput  only NOINPUT is set
#   nonint   only HP_NONINTERACTIVE is set
#   cilane   only HP_CI_LANE is set
#   control  none of the three is set (the negative control: the same offers must then reach their prompts, otherwise
#            the three rows above could pass because the offers never appear)
# Two programs per scenario, because no single program makes all four offers:
#   rti  standard library only; catches the ImportError of a package whose name it builds at run time, prints the traceback
#        and exits 0. Offers made: the missing-package install, the post-execution checkpoint, the optimized build.
#   lc   standard library only; prints a traceback to stderr and exits 3. Offers made: the post-execution checkpoint and
#        the last-chance offer (the optimized build needs an exit of 0, the missing-package install needs a named module).
#
# What "without waiting" is judged on. Standard input is closed (< nul) because the console of a CI step is not available,
# so a read that did happen would get end-of-file and return at once; the decline line alone cannot tell a skipped read
# from an unanswered one. The interactive read prints its prompt text (set /p, choice /M) and ONLY the interactive branch
# does, so a signal row needs, for each offer: its heading reached, its prompt text absent after the heading, and its
# decline line present. The last-chance offer also logs a different line when it was asked ("neither") than when it was
# skipped ("automated"). A hard time limit per run turns a hang into a red row.
#
# The ledger: each program appends one JSON line per launch to ~offers_ledger.jsonl with frozen=true for the EXE. The
# rti rows need exactly one launch (the EXE verification run) and neither program may have been started through the
# interpreter, which is what an accepted checkpoint or install would do. The total for lc is RECORDED, not asserted: the
# hint re-run of a failed EXE run starts that program a second time (Item 96 in CLAUDE.md), and this script is about the
# offers.
#
# The control run for rti reaches the missing-package prompt through `choice`, whose behavior with closed standard input
# is not asserted: the row records whether its prompt text was shown and how it ended.
#
# Flags are removed the way gap T12 does it: Remove-Item on the Env: drive in this process, then the wrapper clears every
# one again with `set "NAME="` and lists what is left (prefixes only, never the whole environment) BEFORE and AFTER the
# scenario's own `set` line. The list after is the verdict on which signals the bootstrapper started with.
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text, not
# PowerShell). The heading, prompt and decline strings below are pinned to run_setup.bat by tests/test_offers_noninteractive.py.
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"); eight small default bootstraps.
# Emits: self.offers.noinput, self.offers.nonint, self.offers.cilane, self.offers.control
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

# One entry per elective offer of REQ-018.9. Heading: a line the offer prints before its gate, whatever the signals.
# Prompt: the text only the interactive read prints. Declined: the log line of the decline. Asked: the log line of an
# answered question (last chance only), which a skipped question never logs.
$specs = [ordered]@{
    checkpoint = @{
        Heading  = 'Verification finished -- see the Run Status above.'
        Prompt   = 'Run again via the interpreter now? [Y/N]'
        Declined = 'post-execution checkpoint \((exe|interpreter)\): declined'
    }
    optbuild   = @{
        Heading  = 'Want to build an optimized version too?'
        Prompt   = 'Build the optimized version now? [Y/N]'
        Declined = 'Optimized build: declined'
    }
    runtime    = @{
        Heading  = 'Your program asked for packages that are not installed:'
        Prompt   = 'Install and check?'
        Declined = 'Runtime install: declined\. Nothing was changed'
    }
    lastchance = @{
        Heading  = 'Your program stopped with an error, exit code'
        Prompt   = 'Your choice, W or C or N'
        Declined = 'Last chance: automated run, no question asked; keeping this build'
        Asked    = 'Last chance: neither; keeping this build'
    }
}
$offersOf = @{ rti = @('runtime', 'checkpoint', 'optbuild'); lc = @('checkpoint', 'lastchance') }

# True facts about one offer in one run, read from the console text (headings and prompts) and the logs (decline lines).
function Get-OfferFacts {
    param([string]$Console, [string]$Logs, [hashtable]$Spec)
    $at = $Console.IndexOf($Spec.Heading, [System.StringComparison]::Ordinal)
    $shown = $false
    if ($at -ge 0) { $shown = ($Console.IndexOf($Spec.Prompt, $at, [System.StringComparison]::Ordinal) -ge 0) }
    $asked = $false
    if ($Spec.ContainsKey('Asked')) { $asked = [regex]::IsMatch($Logs, $Spec.Asked) }
    return [ordered]@{
        reached     = ($at -ge 0)
        promptShown = $shown
        declined    = [regex]::IsMatch($Logs, $Spec.Declined)
        asked       = $asked
    }
}

# What is wrong with one run of a scenario, as short sentences; nothing when the run shows what the scenario expects.
# Mode 'signal': every offer was made and declined without its prompt, and no interpreter launch followed.
# Mode 'control': the offers that always ask reached their prompts.
function Get-RunProblems {
    param([string]$Mode, [string]$App, $Run, $Facts, [string[]]$ExpectFlags)
    $out = New-Object System.Collections.ArrayList
    if (-not $Run.Finished) {
        [void]$out.Add("${App}: the run did not finish within the time limit")
        return $out.ToArray()
    }
    if (-not $Run.EnvDumped) { [void]$out.Add("${App}: the environment listing was not written, so the signals are unproven") }
    $seen = (@($Run.FlagsSeen) | Sort-Object) -join ','
    $want = (@($ExpectFlags) | Sort-Object) -join ','
    if ($seen -ine $want) { [void]$out.Add("${App}: the run started with the flags [${seen}], expected [${want}]") }
    $ledger = @($Run.Ledger)
    $viaInterpreter = @($ledger | Where-Object { $_.frozen -eq $false }).Count
    if ($Mode -eq 'signal') {
        foreach ($name in $Facts.Keys) {
            $f = $Facts[$name]
            if (-not $f.reached) { [void]$out.Add("${App}: the ${name} offer was never made, its heading is not in the console"); continue }
            if ($f.promptShown) { [void]$out.Add("${App}: the ${name} offer printed its interactive prompt, so it read the console") }
            if (-not $f.declined) { [void]$out.Add("${App}: the ${name} offer left no decline line in the logs") }
            if ($f.asked) { [void]$out.Add("${App}: the ${name} offer logged the line of an answered question") }
        }
        if ($viaInterpreter -gt 0) { [void]$out.Add("${App}: the program was started through the interpreter ${viaInterpreter} time(s)") }
        if ($App -eq 'rti' -and $ledger.Count -ne 1) { [void]$out.Add("${App}: the program was started $($ledger.Count) time(s), expected 1") }
        if ($App -eq 'lc' -and $ledger.Count -lt 1) { [void]$out.Add("${App}: the ledger is empty, so the program never ran") }
    } else {
        foreach ($name in $Facts.Keys) {
            $f = $Facts[$name]
            if (-not $f.reached) { [void]$out.Add("${App}: the ${name} offer was never made, its heading is not in the console"); continue }
            # The missing-package prompt is a choice with a timeout; its behavior with closed input is recorded only.
            if ($name -ne 'runtime' -and -not $f.promptShown) { [void]$out.Add("${App}: the ${name} offer did not print its prompt although no signal was set") }
        }
        if ($Facts.Contains('lastchance')) {
            $lc = $Facts['lastchance']
            if ($lc.reached -and -not $lc.asked) { [void]$out.Add("${App}: the lastchance offer did not log that it was asked") }
            if ($lc.reached -and $lc.declined) { [void]$out.Add("${App}: the lastchance offer logged the automated line although no signal was set") }
        }
    }
    return $out.ToArray()
}

# The few log lines that explain a red row, printable ASCII only and cut short, so the row says WHY without the log files.
function Get-Excerpt {
    param([string]$Text, [int]$Max = 16)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match 'Verification finished|optimized version|asked for packages|stopped with an error|Run again via|Install and check|Your choice, W|declined|Last chance|Runtime install|Optimized build|Entry smoke|\[STATUS\]|\[ERROR\]|\[WARN\]') {
            $clean = ($l -replace '[^\x20-\x7E]', '?')
            if ($clean.Length -gt 140) { $clean = $clean.Substring(0, 140) }
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

function Read-Ledger {
    param([string]$Path)
    $out = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in (Get-Content -LiteralPath $Path -Encoding ASCII)) {
            if ($line.Trim().Length -eq 0) { continue }
            try { [void]$out.Add(($line | ConvertFrom-Json)) } catch { [void]$out.Add([pscustomobject]@{ parseError = $line }) }
        }
    }
    return ,$out.ToArray()
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

$allIds = @('self.offers.noinput', 'self.offers.nonint', 'self.offers.cilane', 'self.offers.control')
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-018.9'; pass = $true; desc = 'Elective offers in a non-interactive run (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-018.9'; pass = $false; desc = 'Elective offers in a non-interactive run: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    exit 1
}

# The module name is joined at run time: a literal import_module("xlsxwriter") could be seen by a future static scan and
# installed up front, which would remove the failure this program needs (same fixture as selfapps_runtime_install.ps1).
$appCode = @{}
$appCode['rti'] = @'
import importlib
import json
import sys
import traceback

with open("~offers_ledger.jsonl", "a") as f:
    f.write(json.dumps({"app": "rti", "frozen": bool(getattr(sys, "frozen", False))}) + "\n")

name = "".join(("xlsx", "writer"))
try:
    importlib.import_module(name)
except ImportError:
    traceback.print_exc()
print("offers rti app ok")
'@
$appCode['lc'] = @'
import json
import sys

with open("~offers_ledger.jsonl", "a") as f:
    f.write(json.dumps({"app": "lc", "frozen": bool(getattr(sys, "frozen", False))}) + "\n")

print("offers lc app starting")
print("Traceback (most recent call last):", file=sys.stderr)
print('  File "app.py", line 12, in <module>', file=sys.stderr)
print("RuntimeError: simulated environment problem", file=sys.stderr)
sys.exit(3)
'@

# Each run is a default bootstrap of a small program; the limit only has to catch a hang.
$timeLimitSec = 600

# --- scrub every flag; remember and restore them afterwards (see the header and gap T12 for why this is done twice) ---
$scrubbed = @{}
foreach ($item in @(Get-ChildItem Env:)) {
    if ($item.Name -match '^(HP_|PVW_)' -or $item.Name -ieq 'NOINPUT') { $scrubbed[$item.Name] = $item.Value }
}
foreach ($name in @($scrubbed.Keys)) { Remove-Item -LiteralPath ('Env:' + $name) -ErrorAction SilentlyContinue }
$parentStillSet = @($scrubbed.Keys | Where-Object { $null -ne [Environment]::GetEnvironmentVariable($_) } | Sort-Object)

# Bootstraps one program in a fresh folder with exactly the signals in $SetLines and returns what the verdict reads.
function Invoke-OffersRun {
    param([string]$Scenario, [string]$App, [string[]]$SetLines)
    $dir = Join-Path $here ('~selftest_offers_' + $Scenario + '_' + $App)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $batchPath -Destination $dir -Force
    Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value $appCode[$App] -Encoding ASCII

    # The wrapper lists the flag-shaped variables it started with (~offers_env0.txt, diagnostic), clears every flag the job
    # had set, applies the scenario's own signal, then lists again (~offers_env.txt, the verdict). No space before a
    # redirection: a space would become part of the prefix that `set` looks for.
    $listBefore = @('set HP_> ~offers_env0.txt 2>nul', 'set PVW_>> ~offers_env0.txt 2>nul', 'set NOINPUT>> ~offers_env0.txt 2>nul')
    $clearLines = @($scrubbed.Keys | Where-Object { $_ -match '^[A-Za-z0-9_]+$' } | Sort-Object | ForEach-Object { 'set "' + $_ + '="' })
    $listAfter = @('set HP_> ~offers_env.txt 2>nul', 'set PVW_>> ~offers_env.txt 2>nul', 'set NOINPUT>> ~offers_env.txt 2>nul')
    $wrapperLines = @('@echo off') + $listBefore + $clearLines + $SetLines + $listAfter + @('call run_setup.bat > ~offers_console.log 2>&1 < nul', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $dir '~offers_launch.cmd') -Value $wrapperLines -Encoding ASCII

    $started = Get-Date
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', 'call ~offers_launch.cmd') -WorkingDirectory $dir -NoNewWindow -PassThru
    $finished = $proc.WaitForExit($timeLimitSec * 1000)
    $code = -1
    if ($finished) {
        $proc.WaitForExit()
        $code = $proc.ExitCode
    } else {
        & taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null
        $null = $proc.WaitForExit(30000)
    }

    $envPath  = Join-Path $dir '~offers_env.txt'
    $env0Path = Join-Path $dir '~offers_env0.txt'
    $state = ''
    $statusPath = Join-Path $dir '~bootstrap.status.json'
    if (Test-Path -LiteralPath $statusPath) {
        try { $state = [string]((Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { $state = 'unparseable' }
    }
    $console = Read-Text (Join-Path $dir '~offers_console.log')
    $setup = Read-Text (Join-Path $dir '~setup.log')
    return [pscustomobject]@{
        Finished      = [bool]$finished
        ExitCode      = $code
        Seconds       = [int]((Get-Date) - $started).TotalSeconds
        EnvDumped     = ((Test-Path -LiteralPath $envPath) -and (Test-Path -LiteralPath $env0Path))
        FlagsSeen     = (Get-FlagNames $envPath)
        FlagsAtLaunch = (Get-FlagNames $env0Path)
        Console       = $console
        Logs          = ($console + "`n" + $setup)
        Ledger        = (Read-Ledger (Join-Path $dir '~offers_ledger.jsonl'))
        Status        = $state
    }
}

# Runs both programs of one scenario and returns the verdict with the details of the row.
function Get-ScenarioResult {
    param([string]$Mode, [string[]]$ExpectFlags, [string]$Scenario, [string[]]$SetLines)
    $details = [ordered]@{
        signalsSet = ($ExpectFlags -join ',')
        flagsScrubbed = $scrubbed.Count
        parentStillSet = @($parentStillSet)
        timeLimitSec = $timeLimitSec
    }
    $problems = @()
    foreach ($app in @('rti', 'lc')) {
        $run = Invoke-OffersRun -Scenario $Scenario -App $app -SetLines $SetLines
        $facts = [ordered]@{}
        foreach ($name in $offersOf[$app]) { $facts[$name] = Get-OfferFacts -Console $run.Console -Logs $run.Logs -Spec $specs[$name] }
        $found = @(Get-RunProblems -Mode $Mode -App $app -Run $run -Facts $facts -ExpectFlags $ExpectFlags)
        $problems += $found
        $ledger = @($run.Ledger)
        $perApp = [ordered]@{
            finished = $run.Finished; seconds = $run.Seconds; exitCode = $run.ExitCode; statusState = $run.Status
            flagsSeen = @($run.FlagsSeen); flagsAtLaunch = @($run.FlagsAtLaunch); envDumped = [bool]$run.EnvDumped
            ledgerLines = $ledger.Count; interpreterLaunches = @($ledger | Where-Object { $_.frozen -eq $false }).Count
            offers = $facts
        }
        if ($found.Count -gt 0) { $perApp['excerpt'] = @(Get-Excerpt $run.Console) }
        $details[$app] = $perApp
    }
    $details['problems'] = @($problems)
    return [pscustomobject]@{ Pass = ($problems.Count -eq 0); Details = $details }
}

function Get-ErrorResult {
    param($ErrorRecord)
    return [pscustomobject]@{ Pass = $false; Details = [ordered]@{ error = [string]$ErrorRecord.Exception.Message } }
}

$allPass = $true
try {
    # ------------------------------------------------------------ only NOINPUT
    try { $r = Get-ScenarioResult -Mode 'signal' -ExpectFlags @('NOINPUT') -Scenario 'noinput' -SetLines @('set "NOINPUT=1"') } catch { $r = Get-ErrorResult $_ }
    if (-not $r.Pass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id = 'self.offers.noinput'; req = 'REQ-018.9'; pass = [bool]$r.Pass
        desc = 'REQ-018.9: with only NOINPUT set, the post-execution checkpoint, the optimized build, the missing-package install and the last-chance offer decline without reading the console, and no interpreter run follows'
        details = $r.Details
    })

    # ------------------------------------------------------------ only HP_NONINTERACTIVE
    try { $r = Get-ScenarioResult -Mode 'signal' -ExpectFlags @('HP_NONINTERACTIVE') -Scenario 'nonint' -SetLines @('set "HP_NONINTERACTIVE=1"') } catch { $r = Get-ErrorResult $_ }
    if (-not $r.Pass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id = 'self.offers.nonint'; req = 'REQ-018.9'; pass = [bool]$r.Pass
        desc = 'REQ-018.9: with only HP_NONINTERACTIVE set, the post-execution checkpoint, the optimized build, the missing-package install and the last-chance offer decline without reading the console, and no interpreter run follows'
        details = $r.Details
    })

    # ------------------------------------------------------------ only HP_CI_LANE
    try { $r = Get-ScenarioResult -Mode 'signal' -ExpectFlags @('HP_CI_LANE') -Scenario 'cilane' -SetLines @('set "HP_CI_LANE=offers"') } catch { $r = Get-ErrorResult $_ }
    if (-not $r.Pass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id = 'self.offers.cilane'; req = 'REQ-018.9'; pass = [bool]$r.Pass
        desc = 'REQ-018.9: with only HP_CI_LANE set, the post-execution checkpoint, the optimized build, the missing-package install and the last-chance offer decline without reading the console, and no interpreter run follows'
        details = $r.Details
    })

    # ------------------------------------------------------------ none of the three: the negative control
    try { $r = Get-ScenarioResult -Mode 'control' -ExpectFlags @() -Scenario 'control' -SetLines @() } catch { $r = Get-ErrorResult $_ }
    if (-not $r.Pass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id = 'self.offers.control'; req = 'REQ-018.9'; pass = [bool]$r.Pass
        desc = 'REQ-018.9 control: with none of the three signals set, the same offers reach their interactive prompts, so the rows above cannot pass because the offers never appear'
        details = $r.Details
    })
} finally {
    foreach ($name in @($scrubbed.Keys)) { [Environment]::SetEnvironmentVariable($name, $scrubbed[$name]) }
}

if (-not $allPass) { exit 1 }
exit 0
