# ASCII only
# selfapps_workdir.ps1 - Item 101 (README REQ-003.6): every run of the user's program the bootstrapper makes starts with
# the folder that holds the program's entry file as the working folder.
#
# Why it matters. A program that opens a file by a relative name (open("config.json") next to the script) must see the same
# files in every run. Item 38 moved the verification run, the cached-EXE run and the interpreter runs to the app folder, but
# two starts still ran from dist\ (pushd dist): the verification run of the optimized build (:offer_optimized_build) and the
# runs of the --hidden-import repair loop (:hidden_import_recover). In those runs the program could not see its own data
# file, so a repair could fail or succeed for a reason the real run does not share, and a user's program was judged by a
# folder it never runs in. The bootstrapper never changes the folder the user double-clicked from, and the entry file is
# always in that folder (REQ-002 lists only the app folder), so "the folder that holds the entry file" is the app folder.
#
# How starts are observed. The program appends one JSON line per start to a ledger whose ABSOLUTE path comes from the
# environment (WORKDIR_LEDGER): a ledger relative to the working directory would be split over several folders, which is the
# very fault under test. The line says whether the working directory IS the entry folder (os.path.samefile against
# WORKDIR_EXPECT, so a short 8.3 name or letter case cannot fool it), and whether a data file that sits next to the .py file
# can be opened by its relative name. The program writes the line first, so a start that fails at once is still seen.
#
# Scenarios, one fresh folder each (the program, workdir_data.txt and run_setup.bat; nothing else is needed):
#   verify       default bootstrap with the post-execution checkpoint answered yes (HP_TEST_CHECKPOINT_ANSWER=Y): the verification
#                run of the fresh EXE and the checkpoint run through the interpreter. Row: self.workdir.verify
#   fastpath     the same folder bootstrapped again: the cached EXE is reused and started. Row: self.workdir.fastpath
#   interpreter  PyInstaller and Nuitka forced to fail (HP_TEST_FORCE_PYINSTALLER_FAIL, HP_TEST_FORCE_NUITKA_FAIL): no EXE exists,
#                so the interpreter runs the program. Row: self.workdir.interpreter
#   repair       a program that reads workdir_data.txt first and then imports an installed package by a computed name, so the
#                first run fails with ModuleNotFoundError. The repair loop (consent given through HP_TEST_REPAIR_ANSWER=Y) starts
#                the EXE to read the error and again after the rebuild; each of those starts must see the data file. Before the fix
#                the loop's first start ran from dist\, failed on the missing data file and the repair never happened.
#                Row: self.workdir.repair
#   optbuild     PVW_BUILDER=both with a stub nuitka.py next to app.py that "builds" by copying the EXE PyInstaller built: the
#                optimized build is verified by one more start, which must be in the entry folder. Row: self.workdir.optbuild
# verify, fastpath and interpreter are controls that pass before and after the fix: they show the ledger sees a correct start
# as correct and keep Item 38's folders from regressing. repair and optbuild are red until the two pushd dist lines are gone.
# Each row also needs its preconditions (the step was reached: the repair line, the swap line, the number of starts), so a
# bootstrap that never got to the step cannot pass.
#
# derived requirement: ids and req tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell). The skip loop below uses a map on purpose; the real emissions are literal.
#
# Lane: conda-full (gating from its first run, AGENTS.md "New tests gate immediately"). The two launch sites are batch code shared
# by every provider, so one lane proves them; conda-full has the most wall-clock headroom (CLAUDE.md, "CI wall-clock duration"),
# and five fresh bootstraps are too heavy for the lanes that already set the pace. The optimized build installs the real Nuitka
# package before the stub shadows it, the same as the deterministic scenarios of selfapps_pvw_builder.ps1.
# Emits: self.workdir.verify, self.workdir.fastpath, self.workdir.interpreter, self.workdir.repair, self.workdir.optbuild
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

$allIds = @('self.workdir.verify', 'self.workdir.fastpath', 'self.workdir.interpreter', 'self.workdir.repair', 'self.workdir.optbuild')
function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-003'; pass = $Pass; desc = $Desc; details = $Details })
    }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'Working folder of every start (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'Working folder of every start: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# --- pure helpers (kept free of the file system so they can be exercised on their own) ---

# The end of a path, enough to tell dist from the app folder without writing a runner's whole directory layout into a row.
function Get-ShortPath {
    param([string]$Path)
    if (-not $Path) { return '(empty)' }
    $clean = ($Path -replace '[^\x20-\x7E]', '?')
    $parts = @($clean -split '[\\/]' | Where-Object { $_ })
    if ($parts.Count -le 2) { return $clean }
    return '...\' + ($parts[($parts.Count - 2)..($parts.Count - 1)] -join '\')
}

# What is wrong with one site's starts, as short sentences; nothing when every start was in the entry folder and the site was reached.
# $Proofs holds the sentences for preconditions the caller found missing (a log line that shows the step ran).
function Get-WorkdirProblems {
    param([string]$Site, [bool]$Finished, $Ledger, [int]$MinStarts, [string[]]$Proofs)
    $out = New-Object System.Collections.ArrayList
    if (-not $Finished) { [void]$out.Add("${Site}: a bootstrap did not finish within the time limit"); return $out.ToArray() }
    foreach ($p in @($Proofs)) { if ($p) { [void]$out.Add("${Site}: $p") } }
    $lines = @($Ledger | Where-Object { $null -ne $_ })
    if ($lines.Count -lt $MinStarts) { [void]$out.Add("${Site}: the ledger shows $($lines.Count) start(s) but at least $MinStarts are expected, so the launch site was not reached") }
    $k = 0
    foreach ($e in $lines) {
        $k++
        if ($e.PSObject.Properties.Name -notcontains 'same') { [void]$out.Add("${Site}: start $k is not a readable ledger line"); continue }
        if ($e.same -ne $true) { [void]$out.Add("${Site}: start $k ran in $(Get-ShortPath ([string]$e.cwd)), not in the folder that holds the program's entry file") }
        if ($e.dataFound -ne $true) { [void]$out.Add("${Site}: start $k could not open workdir_data.txt, which sits next to the program's .py file, by its relative name") }
    }
    return $out.ToArray()
}

# How many ledger lines are of a kind: frozen (the EXE started the program) or not (the interpreter did).
function Get-StartKinds {
    param($Ledger)
    $lines = @($Ledger | Where-Object { $null -ne $_ -and $_.PSObject.Properties.Name -contains 'frozen' })
    return [ordered]@{
        frozen      = @($lines | Where-Object { $_.frozen -eq $true }).Count
        interpreter = @($lines | Where-Object { $_.frozen -eq $false }).Count
        outside     = @($lines | Where-Object { $_.same -ne $true }).Count
        noData      = @($lines | Where-Object { $_.dataFound -ne $true }).Count
    }
}

# The sentence for a precondition that is missing, or an empty string when the log shows it.
function Get-ProofGap {
    param([string]$Text, [string]$Pattern, [string]$Sentence)
    if ([regex]::IsMatch($Text, $Pattern)) { return '' }
    return $Sentence
}

# A few log lines that explain a red row, printable ASCII only and cut short.
function Get-Excerpt {
    param([string]$Text, [int]$Max = 24)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match 'Verifying the built standalone EXE|EXE smokerun|Entry smoke|checkpoint|Fast path|Repair loop|\[REPAIR\]|Optimized build|PVW_BUILDER|\[ERROR\]|\[STATUS\]|Chosen entry') {
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

# One object per ledger line (a line that is not JSON becomes an object with a parseError field, still one start). The callers
# wrap the call in @( ) so an empty ledger is an empty array and a single line is still an array.
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

# --- the programs; both write the ledger FIRST, from an absolute path, so a start that fails at once is still seen ---
$appCode = @{}
$appCode['ledger'] = @'
import json
import os
import sys

expect = os.environ.get("WORKDIR_EXPECT", "")
cwd = os.getcwd()
try:
    same = bool(expect) and os.path.samefile(cwd, expect)
except OSError:
    same = False
rec = {
    "scenario": os.environ.get("WORKDIR_SCENARIO", ""),
    "frozen": bool(getattr(sys, "frozen", False)),
    "cwd": cwd,
    "same": same,
    "dataFound": os.path.isfile("workdir_data.txt"),
}
with open(os.environ["WORKDIR_LEDGER"], "a") as f:
    f.write(json.dumps(rec) + "\n")
print("workdir-ok")
'@
# colorama is installed (requirements.txt) but imported by a runtime string, so PyInstaller does not bundle it and the first
# run fails with ModuleNotFoundError. The data file is read BEFORE the import: from any other folder the program dies on the
# missing file, which is not an error the repair loop can act on.
$appCode['repair'] = @'
import importlib
import json
import os
import sys

expect = os.environ.get("WORKDIR_EXPECT", "")
cwd = os.getcwd()
try:
    same = bool(expect) and os.path.samefile(cwd, expect)
except OSError:
    same = False
rec = {
    "scenario": os.environ.get("WORKDIR_SCENARIO", ""),
    "frozen": bool(getattr(sys, "frozen", False)),
    "cwd": cwd,
    "same": same,
    "dataFound": os.path.isfile("workdir_data.txt"),
}
with open(os.environ["WORKDIR_LEDGER"], "a") as f:
    f.write(json.dumps(rec) + "\n")

with open("workdir_data.txt", "r") as f:
    data = f.read().strip()
mod = importlib.import_module('colorama')
print(mod.__name__, data)
'@
# python -m nuitka finds this file first (the current folder is on sys.path for -m), so the optimized build "builds" by copying
# the EXE PyInstaller already built to the name it was asked for. app.py wins entry selection (REQ-002), so this is never the program.
$stubNuitka = @'
import glob
import os
import shutil
import sys

args = sys.argv[1:]
out = ""
outdir = "."
for i, a in enumerate(args):
    if a == "-o" and i + 1 < len(args):
        out = args[i + 1]
    if a.startswith("--output-dir="):
        outdir = a.split("=", 1)[1]
if not out:
    print("stub nuitka: no -o name was given")
    sys.exit(2)
sources = [p for p in glob.glob(os.path.join(outdir, "*.exe")) if os.path.basename(p) != out]
if not sources:
    print("stub nuitka: no EXE to copy in " + outdir)
    sys.exit(3)
shutil.copyfile(sources[0], os.path.join(outdir, out))
print("stub nuitka: copied " + os.path.basename(sources[0]) + " to " + out)
'@

# A hang must be a red row; a default bootstrap of a tiny program needs a few minutes at most.
$runTimeoutMs = 15 * 60 * 1000

function New-WorkdirFolder {
    param([string]$Scenario, [string]$AppKind, [string]$Requirements, [string]$StubCode)
    $dir = Join-Path $here ('~selftest_workdir_' + $Scenario)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $batchPath -Destination $dir -Force
    Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value $appCode[$AppKind] -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $dir 'workdir_data.txt') -Value 'present' -Encoding ASCII
    if ($Requirements) { Set-Content -LiteralPath (Join-Path $dir 'requirements.txt') -Value $Requirements -Encoding ASCII }
    if ($StubCode) { Set-Content -LiteralPath (Join-Path $dir 'nuitka.py') -Value $StubCode -Encoding ASCII }
    return $dir
}

# One bootstrap in a prepared folder; never throws. Standard input is closed so nothing can wait for an answer.
function Invoke-WorkdirPass {
    param([string]$Dir, [string]$Scenario, [string]$Pass, [System.Collections.IDictionary]$Vars)
    $res = [ordered]@{ Pass = $Pass; Finished = $false; ExitCode = -1; Seconds = 0; Console = ''; SetupBefore = 0; Error = '' }
    try {
        $consoleName = '~workdir_' + $Scenario + '_' + $Pass + '.log'
        $launch = '~workdir_launch_' + $Pass + '.cmd'
        Set-Content -LiteralPath (Join-Path $Dir $launch) -Value @('@echo off', "call run_setup.bat > $consoleName 2>&1 < nul", 'exit /b %ERRORLEVEL%') -Encoding ASCII
        $setupPath = Join-Path $Dir '~setup.log'
        if (Test-Path -LiteralPath $setupPath) { $res.SetupBefore = (Get-Item -LiteralPath $setupPath).Length }
        $all = [ordered]@{ HP_SKIP_PIPREQS = '1'; WORKDIR_SCENARIO = $Scenario; WORKDIR_LEDGER = (Join-Path $Dir '~workdir_ledger.jsonl'); WORKDIR_EXPECT = $Dir }
        if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $all['HP_CI_LANE'] = 'test' }
        foreach ($k in @($Vars.Keys)) { $all[$k] = $Vars[$k] }
        $saved = @{}
        foreach ($k in @($all.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, [string]$all[$k]) }
        $started = Get-Date
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('call ' + $launch)) -WorkingDirectory $Dir -NoNewWindow -PassThru
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
        $res.Console = Read-Text (Join-Path $Dir $consoleName)
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

# The part of ~setup.log that one pass appended (the log is only rotated past 10 MB, so it holds earlier passes too).
function Read-SetupSince {
    param([string]$Dir, [long]$Offset)
    $path = Join-Path $Dir '~setup.log'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    $all = Read-Text $path
    if ($Offset -le 0 -or $Offset -ge $all.Length) { return $all }
    return $all.Substring([int]$Offset)
}

function Show-Evidence {
    param([string]$Title, $Ledger, [string]$Setup)
    Write-Host ("=== working folder: {0} ===" -f $Title)
    foreach ($e in @($Ledger)) {
        if ($e.PSObject.Properties.Name -contains 'same') {
            Write-Host ("ledger: frozen={0} same={1} dataFound={2} cwd={3}" -f $e.frozen, $e.same, $e.dataFound, (Get-ShortPath ([string]$e.cwd)))
        } else { Write-Host ("ledger: unreadable line {0}" -f $e.parseError) }
    }
    foreach ($l in @(Get-Excerpt $Setup)) { Write-Host ("setup: " + $l) }
}

function Get-Details {
    param($Passes, $Ledger, [string[]]$Problems, [string]$Setup)
    $kinds = Get-StartKinds $Ledger
    $details = [ordered]@{
        finished = [bool](@($Passes | Where-Object { -not $_.Finished }).Count -eq 0)
        seconds = [int](($Passes | Measure-Object -Property Seconds -Sum).Sum)
        exitCodes = @($Passes | ForEach-Object { $_.ExitCode })
        starts = @($Ledger).Count; frozenStarts = $kinds.frozen; interpreterStarts = $kinds.interpreter
        startsOutsideEntryFolder = $kinds.outside; startsWithoutData = $kinds.noData
    }
    $err = @($Passes | Where-Object { $_.Error } | ForEach-Object { $_.Error })
    if ($err.Count -gt 0) { $details['error'] = $err }
    if (@($Problems).Count -gt 0) { $details['problems'] = @($Problems); $details['excerpt'] = @(Get-Excerpt $Setup) }
    return $details
}

$allPass = $true

# ---------------------------------------------------------------- verify and fastpath: one folder, two bootstraps
$vDir = New-WorkdirFolder -Scenario 'verify' -AppKind 'ledger' -Requirements '' -StubCode ''
$vA = Invoke-WorkdirPass -Dir $vDir -Scenario 'verify' -Pass 'a' -Vars ([ordered]@{ HP_TEST_CHECKPOINT_ANSWER = 'Y' })
$vLedgerA = @(Read-Ledger (Join-Path $vDir '~workdir_ledger.jsonl'))
$vSetupA = Read-SetupSince -Dir $vDir -Offset $vA.SetupBefore
$vB = Invoke-WorkdirPass -Dir $vDir -Scenario 'fastpath' -Pass 'b' -Vars ([ordered]@{})
$vLedgerAll = @(Read-Ledger (Join-Path $vDir '~workdir_ledger.jsonl'))
$vLedgerB = @($vLedgerAll | Select-Object -Skip $vLedgerA.Count)
Show-Evidence -Title 'fresh build, verification run and post-execution checkpoint' -Ledger $vLedgerA -Setup $vSetupA
Show-Evidence -Title 'second bootstrap, cached EXE' -Ledger $vLedgerB -Setup $vB.Console

$kindsA = Get-StartKinds $vLedgerA
$proofs = @(
    (Get-ProofGap -Text $vSetupA -Pattern 'post-execution checkpoint \(exe\): accepted' -Sentence 'the post-execution checkpoint was not accepted, so its run was never made'),
    $(if ($kindsA.frozen -lt 1) { 'no start of the EXE was recorded, so the verification run did not happen' } else { '' }),
    $(if ($kindsA.interpreter -lt 1) { 'no start through the interpreter was recorded, so the checkpoint run did not happen' } else { '' })
)
$problems = @(Get-WorkdirProblems -Site 'verify' -Finished ([bool]$vA.Finished) -Ledger $vLedgerA -MinStarts 2 -Proofs $proofs)
if ($problems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.workdir.verify'; req = 'REQ-003'; pass = [bool]($problems.Count -eq 0)
    desc = 'REQ-003.6: the verification run of a fresh EXE and the post-execution checkpoint run start the program in the folder that holds its entry file'
    details = (Get-Details -Passes @($vA) -Ledger $vLedgerA -Problems $problems -Setup $vSetupA)
})

$kindsB = Get-StartKinds $vLedgerB
$proofs = @(
    (Get-ProofGap -Text $vB.Console -Pattern 'Fast path: reusing' -Sentence 'the second bootstrap did not reuse the cached EXE, so the fast path was not taken'),
    $(if ($kindsB.frozen -lt 1) { 'no start of the cached EXE was recorded' } else { '' })
)
$problems = @(Get-WorkdirProblems -Site 'fastpath' -Finished ([bool]($vA.Finished -and $vB.Finished)) -Ledger $vLedgerB -MinStarts 1 -Proofs $proofs)
if ($problems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.workdir.fastpath'; req = 'REQ-003'; pass = [bool]($problems.Count -eq 0)
    desc = 'REQ-003.6: the run of the cached EXE on the fast path starts the program in the folder that holds its entry file'
    details = (Get-Details -Passes @($vB) -Ledger $vLedgerB -Problems $problems -Setup $vB.Console)
})

# ---------------------------------------------------------------- interpreter: no EXE can be built
$iDir = New-WorkdirFolder -Scenario 'interpreter' -AppKind 'ledger' -Requirements '' -StubCode ''
$iRun = Invoke-WorkdirPass -Dir $iDir -Scenario 'interpreter' -Pass 'a' -Vars ([ordered]@{ HP_TEST_FORCE_PYINSTALLER_FAIL = '1'; HP_TEST_FORCE_NUITKA_FAIL = '1' })
$iLedger = @(Read-Ledger (Join-Path $iDir '~workdir_ledger.jsonl'))
$iSetup = Read-SetupSince -Dir $iDir -Offset $iRun.SetupBefore
Show-Evidence -Title 'no EXE, the interpreter runs the program' -Ledger $iLedger -Setup $iSetup
$kindsI = Get-StartKinds $iLedger
$proofs = @(
    $(if ($kindsI.interpreter -lt 1) { 'no start through the interpreter was recorded' } else { '' }),
    $(if ($kindsI.frozen -gt 0) { 'an EXE started the program although both builders were forced to fail' } else { '' })
)
$problems = @(Get-WorkdirProblems -Site 'interpreter' -Finished ([bool]$iRun.Finished) -Ledger $iLedger -MinStarts 1 -Proofs $proofs)
if ($problems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.workdir.interpreter'; req = 'REQ-003'; pass = [bool]($problems.Count -eq 0)
    desc = 'REQ-003.6: the run through the Python interpreter starts the program in the folder that holds its entry file'
    details = (Get-Details -Passes @($iRun) -Ledger $iLedger -Problems $problems -Setup $iSetup)
})

# ---------------------------------------------------------------- repair: the --hidden-import loop starts the EXE from the app folder
$rDir = New-WorkdirFolder -Scenario 'repair' -AppKind 'repair' -Requirements 'colorama' -StubCode ''
$rRun = Invoke-WorkdirPass -Dir $rDir -Scenario 'repair' -Pass 'a' -Vars ([ordered]@{ HP_TEST_REPAIR_ANSWER = 'Y' })
$rLedger = @(Read-Ledger (Join-Path $rDir '~workdir_ledger.jsonl'))
$rSetup = Read-SetupSince -Dir $rDir -Offset $rRun.SetupBefore
Show-Evidence -Title 'hidden-import repair loop' -Ledger $rLedger -Setup $rSetup
$kindsR = Get-StartKinds $rLedger
$proofs = @(
    (Get-ProofGap -Text $rSetup -Pattern 'Repair loop: accepted' -Sentence 'the repair loop was not accepted, so it never started the program'),
    (Get-ProofGap -Text $rSetup -Pattern '\[REPAIR\]\[HIDDEN_IMPORT\] Adding --hidden-import=colorama' -Sentence 'the repair loop never added --hidden-import=colorama, so the rebuilt EXE was never started'),
    $(if ($kindsR.frozen -lt 3) { "only $($kindsR.frozen) start(s) of the EXE were recorded, expected the check run, the loop's own run and the run after the rebuild" } else { '' })
)
$problems = @(Get-WorkdirProblems -Site 'repair' -Finished ([bool]$rRun.Finished) -Ledger $rLedger -MinStarts 3 -Proofs $proofs)
if ($problems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.workdir.repair'; req = 'REQ-003'; pass = [bool]($problems.Count -eq 0)
    desc = 'REQ-003.6: every start of the --hidden-import repair loop is in the folder that holds the program entry file, so a program that opens a file by a relative name sees it'
    details = (Get-Details -Passes @($rRun) -Ledger $rLedger -Problems $problems -Setup $rSetup)
})

# ---------------------------------------------------------------- optbuild: the optimized build is verified from the app folder
$oDir = New-WorkdirFolder -Scenario 'optbuild' -AppKind 'ledger' -Requirements '' -StubCode $stubNuitka
$oRun = Invoke-WorkdirPass -Dir $oDir -Scenario 'optbuild' -Pass 'a' -Vars ([ordered]@{ PVW_BUILDER = 'both' })
$oLedger = @(Read-Ledger (Join-Path $oDir '~workdir_ledger.jsonl'))
$oSetup = Read-SetupSince -Dir $oDir -Offset $oRun.SetupBefore
Show-Evidence -Title 'optimized build verification' -Ledger $oLedger -Setup $oSetup
$kindsO = Get-StartKinds $oLedger
$proofs = @(
    (Get-ProofGap -Text $oSetup -Pattern 'PVW_BUILDER=both: building the optimized version now without asking' -Sentence 'the optimized build was not started, so its verification run was never made'),
    (Get-ProofGap -Text $oSetup -Pattern 'Optimized build succeeded and verified' -Sentence 'the optimized build was not verified and swapped in, so its verification run did not pass'),
    $(if ($kindsO.frozen -lt 2) { "only $($kindsO.frozen) start(s) of an EXE were recorded, expected the check run and the verification run of the optimized build" } else { '' })
)
$problems = @(Get-WorkdirProblems -Site 'optbuild' -Finished ([bool]$oRun.Finished) -Ledger $oLedger -MinStarts 2 -Proofs $proofs)
if ($problems.Count -gt 0) { $allPass = $false }
Write-NdjsonRow ([ordered]@{
    id = 'self.workdir.optbuild'; req = 'REQ-003'; pass = [bool]($problems.Count -eq 0)
    desc = 'REQ-003.6: the verification run of the optimized build starts the program in the folder that holds its entry file'
    details = (Get-Details -Passes @($oRun) -Ledger $oLedger -Problems $problems -Setup $oSetup)
})

if (-not $allPass) { exit 1 }
exit 0
