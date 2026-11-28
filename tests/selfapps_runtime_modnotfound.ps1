# ASCII only
# selfapps_runtime_modnotfound.ps1 - CLAUDE.md Item 65 slice 1 (README REQ-018): a
# ModuleNotFoundError named in a run's captured stderr must be reported even when the program
# still exits 0.
#
# Field report 2026-08: a GUI launched from the interpreter, then clicking through it raised
# "ModuleNotFoundError: No module named 'xlsxwriter'". tkinter catches an exception raised in a
# callback, prints the traceback to stderr and keeps running, so the process exits 0 and the
# bootstrapper only ever looked at the exit code. This fixture stands in for that callback without
# tkinter: it catches the ImportError itself, prints the traceback to stderr and exits 0.
#
# Row: self.runtime.modnotfound. One real bootstrap of the fixture (no requirements.txt, and the
# module name is built at run time so neither pipreqs nor PyInstaller sees the import). It first
# proves its own precondition (the run exited 0 AND ~run.err.txt holds the traceback, so a fixture
# that stops reproducing the symptom cannot make the row pass or fail vacuously), then requires
# (a) a console [WARN] that names exactly that module as not installed, and (b) the row the
# bootstrapper writes to HP_NDJSON (self.runtime.module_missing) naming the same module. HP_NDJSON
# points at a private file so the bootstrapper's own rows do not land in the lane artifact twice.
#
# Row self.runtime.modnotfound.pyproject (CodeRabbit finding on PR #487): the same fixture with a
# pyproject.toml that lists a dependency. When pyproject.toml supplies the dependencies the bootstrapper
# overwrites requirements.txt from it on every run, so advice to edit requirements.txt would be lost on
# the next run. The advice must name pyproject.toml (the active dependency source) instead.
#
# Rows self.runtime.scan.skipped and self.runtime.scan.fastpath (Item 124, README REQ-018.13): what the scan must NOT
# report, and the cached-EXE fast path. The shall has two halves and neither had a row (the helper's own rules were
# unit tests of the helper, not something a bootstrap showed).
#   skipped  - one real bootstrap of a program that prints tracebacks to stderr and exits 0, for three names: a package
#              nobody installed (xlsxwriter), a standard library module that Windows does not have (fcntl) and a module
#              that sits next to the script (rtmsibling.py, which the frozen EXE cannot import because the folder is not
#              on its path). The console, the closing reminder and the row written to HP_NDJSON must name xlsxwriter,
#              once, and nothing else. Naming xlsxwriter is also what proves the scan ran, so a scan that was switched
#              off cannot make the row pass. Names are joined at run time, as above. The program imports each name and
#              raises the classic sentence for fcntl by hand as well: Python 3.15 words a missing standard library module
#              "Standard library module 'fcntl' was not found" and not "No module named 'fcntl'" (seen in the frozen EXE of
#              run 45973055196, the first run of this row), the scan reads only the classic sentence, and without it the
#              standard library half of the row passes on a stderr that holds nothing to skip. The judge requires the
#              classic line for each of the three names.
#   fastpath - the second bootstrap of the same folder with HP_TEST_FORCE_INTERACTIVE_PROBE=1. The cached EXE is reused
#              and its traceback reaches the console live, but the scan must not run: the console must say that the
#              cached EXE was launched, show the traceback after that line and hold no [WARN] that names a module, no
#              closing reminder and no row. Without the force flag the fast path redirects the run to files and prints
#              no traceback, which would let the row pass for a scan that never had anything to read.
# Both rows are judged by pure functions (Get-ScanSkipProblems, Get-FastPathScanProblems) that
# tests/test_scan_skip_rows.py runs through a real pwsh on synthetic consoles, one red case for each comparison.
#
# Lane: real only. The scan is provider-independent (it reads the run's captured stderr after the
# EXE verification run), and the fixture needs only the standard library, so it adds a tiny build.
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

# Non-Windows skip (parity with other selfapps tests).
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.modnotfound'
        req     = 'REQ-018'
        pass    = $true
        desc    = 'a runtime ModuleNotFoundError in stderr is reported although the run exits 0 (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.modnotfound.pyproject'
        req     = 'REQ-018'
        pass    = $true
        desc    = 'the missing-module advice names pyproject.toml when it is the dependency source (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.scan.skipped'
        req     = 'REQ-018.13'
        pass    = $true
        desc    = 'the scan names a missing package and not a standard library module or a module next to the script (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.scan.fastpath'
        req     = 'REQ-018.13'
        pass    = $true
        desc    = 'the scan is skipped on the cached-EXE fast path (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.modnotfound'
        req     = 'REQ-018'
        pass    = $false
        desc    = 'runtime ModuleNotFoundError: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

# The module name is joined at run time: a literal import_module("xlsxwriter") could be seen by a
# future static scan and installed up front, which would remove the failure this test needs.
$appCode = @'
import importlib
import traceback


def on_click():
    # Stand-in for a GUI callback: the exception is caught, its traceback goes to stderr, and the
    # program carries on and exits 0.
    name = "".join(("xlsx", "writer"))
    try:
        importlib.import_module(name)
    except ImportError:
        traceback.print_exc()


if __name__ == "__main__":
    on_click()
    print("runtime app ok")
'@

# One real bootstrap of the fixture in its own folder; returns everything the rows need. HP_NDJSON
# points at a private file so the bootstrapper's own rows do not land in the lane artifact.
# Item 124: the optional parameters serve scenario 3 below (another program, extra files, a second bootstrap of the same folder
# with an extra environment variable, its own log and row file); a call without them is the call of scenario 1 and 2 as before.
function Invoke-ModNotFoundScenario {
    param([string]$FolderName, [string]$Pyproject, [string]$AppText = $appCode, [hashtable]$ExtraFiles = @{},
          [switch]$Again, [string]$LogName = '', [string]$NdjsonName = '~sub.ndjson', [hashtable]$EnvVars = @{})
    $workDir = Join-Path $here $FolderName
    if (-not $Again) {
        if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Copy-Item -Path $batchPath -Destination $workDir -Force
        Set-Content -Path (Join-Path $workDir 'app.py') -Value $AppText -Encoding ASCII
        foreach ($extraName in $ExtraFiles.Keys) {
            Set-Content -Path (Join-Path $workDir $extraName) -Value $ExtraFiles[$extraName] -Encoding ASCII
        }
        if ($Pyproject) { Set-Content -Path (Join-Path $workDir 'pyproject.toml') -Value $Pyproject -Encoding ASCII }
    }

    $bootstrapLog = if ($LogName) { $LogName } elseif ($Pyproject) { '~modnotfound_pyproject_bootstrap.log' } else { '~modnotfound_bootstrap.log' }
    $subNdjson    = Join-Path $workDir $NdjsonName
    $savedNdjson  = [Environment]::GetEnvironmentVariable('HP_NDJSON')
    $savedEnv     = @{}
    foreach ($envName in $EnvVars.Keys) { $savedEnv[$envName] = [Environment]::GetEnvironmentVariable($envName) }
    Push-Location $workDir
    try {
        [Environment]::SetEnvironmentVariable('HP_NDJSON', $subNdjson)
        foreach ($envName in $EnvVars.Keys) { [Environment]::SetEnvironmentVariable($envName, [string]$EnvVars[$envName]) }
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('HP_NDJSON', $savedNdjson)
        foreach ($envName in $EnvVars.Keys) { [Environment]::SetEnvironmentVariable($envName, $savedEnv[$envName]) }
        Pop-Location
    }

    $logPath   = Join-Path $workDir $bootstrapLog
    $setupLog  = Join-Path $workDir '~setup.log'
    $errPath   = Join-Path $workDir '~run.err.txt'
    $logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
    $setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
    $errText   = if (Test-Path $errPath)  { Get-Content -LiteralPath $errPath  -Raw -Encoding ASCII } else { '' }

    $rowModules = @()
    $rowIds = @()
    if (Test-Path -LiteralPath $subNdjson) {
        foreach ($line in (Get-Content -LiteralPath $subNdjson -Encoding ASCII)) {
            if (-not $line.Trim()) { continue }
            try { $obj = $line | ConvertFrom-Json } catch { continue }
            if ($obj.id) { $rowIds += [string]$obj.id }
            if ($obj.id -eq 'self.runtime.module_missing' -and $obj.details -and $obj.details.module) {
                $rowModules += [string]$obj.details.module
            }
        }
    }
    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusState = $null
    if (Test-Path -LiteralPath $statusPath) {
        try { $statusState = (Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { $statusState = $null }
    }
    [pscustomobject]@{
        RunExit     = $runExit
        LogLines    = $logLines
        Console     = ($logLines -join "`n")
        SetupText   = $setupText
        ErrText     = $errText
        RowIds      = $rowIds
        RowModules  = $rowModules
        StatusState = $statusState
    }
}

# ---- scenario 1: no dependency file (pipreqs finds nothing); the advice names requirements.txt ----
$r = Invoke-ModNotFoundScenario -FolderName '~selftest_runtime_modnotfound' -Pyproject $null
$runExit = $r.RunExit
$logLines = $r.LogLines
$consoleText = $r.Console

# Precondition: the program ran, exited 0, and its stderr holds the traceback. Without this the
# row could pass or fail for a reason that has nothing to do with the new report.
$smokeExit0     = $r.SetupText -match 'Entry smoke exit=0'
$stderrHasTrace = $r.ErrText -match "ModuleNotFoundError: No module named 'xlsxwriter'"
$symptomReproduced = $smokeExit0 -and $stderrHasTrace

# (a) The console names the module as not installed. Matched on the [WARN] tag plus the module
# name and the words "not installed", so a harmless rewording of the rest of the line cannot turn
# the row red.
$moduleLine = $null
foreach ($line in $logLines) {
    if ($line -match '\[WARN\].*\bxlsxwriter\b.*not installed') { $moduleLine = $line; break }
}
$consoleNamesModule = [bool]$moduleLine
# Exactly one module is named, once: the only missing module is xlsxwriter and it is reported once
# per bootstrap run (CodeRabbit finding on PR #487: a duplicate report must fail the row).
$namedModules = @()
foreach ($m in [regex]::Matches($consoleText, '\[WARN\] Your program needed the module (\S+)')) {
    $namedModules += $m.Groups[1].Value
}
$onlyThatModule = ($namedModules.Count -eq 1) -and ($namedModules[0] -eq 'xlsxwriter')

# (b) The bootstrapper's own row, written because HP_NDJSON was set for this run: exactly one.
$rowModules = @($r.RowModules)
$rowNamesModule = ($rowModules.Count -eq 1) -and ($rowModules[0] -eq 'xlsxwriter')

$modPass = ($runExit -eq 0) -and $symptomReproduced -and $consoleNamesModule -and $onlyThatModule -and
           $rowNamesModule -and ($r.StatusState -eq 'ok')

Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.modnotfound'
    req     = 'REQ-018.10'
    pass    = $modPass
    desc    = 'a ModuleNotFoundError in the run''s stderr is reported by name although the program exits 0'
    details = [ordered]@{
        exitCode           = $runExit
        smokeExit0         = $smokeExit0
        stderrHasTrace     = $stderrHasTrace
        symptomReproduced  = $symptomReproduced
        consoleNamesModule = $consoleNamesModule
        consoleLine        = $moduleLine
        namedModules       = @($namedModules)
        onlyThatModule     = $onlyThatModule
        rowIds             = @($r.RowIds)
        rowModules         = @($rowModules)
        rowNamesModule     = $rowNamesModule
        statusState        = $r.StatusState
    }
})

# ---- scenario 2: pyproject.toml supplies the dependencies; the advice must name it, not requirements.txt ----
# The bootstrapper copies pyproject.toml's dependencies over requirements.txt on every run, so an edit
# to requirements.txt would be overwritten. six is a tiny pure-Python package, only here so the
# dependency list is not empty (an empty list is not treated as a dependency source).
$pyprojectText = @'
[project]
name = "rtmfixture"
version = "0.0.0"
dependencies = ["six"]
'@
$p = Invoke-ModNotFoundScenario -FolderName '~selftest_runtime_modnotfound_pyproject' -Pyproject $pyprojectText
$pSmokeExit0     = $p.SetupText -match 'Entry smoke exit=0'
$pStderrHasTrace = $p.ErrText -match "ModuleNotFoundError: No module named 'xlsxwriter'"
$pSourceIsPyproject = $p.SetupText -match 'DEP_SOURCE=pyproject'
$pSymptomReproduced = $pSmokeExit0 -and $pStderrHasTrace -and $pSourceIsPyproject
# The advice sits on the second [WARN] line and again in the closing reminder. Both must name
# pyproject.toml, and neither may send the user to requirements.txt.
$pAdviceLines = @($p.LogLines | Where-Object { $_ -match '\[WARN\] The program may have kept running' -or $_ -match '^\*\*\* Add them, or the packages that provide them' })
$pAdviceNamesPyproject = ($pAdviceLines.Count -eq 2) -and (@($pAdviceLines | Where-Object { $_ -notmatch 'pyproject\.toml' }).Count -eq 0)
$pAdviceNoRequirements = (@($pAdviceLines | Where-Object { $_ -match 'requirements\.txt' }).Count -eq 0)
$pPass = ($p.RunExit -eq 0) -and $pSymptomReproduced -and $pAdviceNamesPyproject -and $pAdviceNoRequirements -and
         ($p.StatusState -eq 'ok')
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.modnotfound.pyproject'
    req     = 'REQ-018.11'
    pass    = $pPass
    desc    = 'with pyproject.toml as the dependency source, the missing-module advice names pyproject.toml and not requirements.txt'
    details = [ordered]@{
        exitCode              = $p.RunExit
        smokeExit0            = $pSmokeExit0
        stderrHasTrace        = $pStderrHasTrace
        sourceIsPyproject     = $pSourceIsPyproject
        symptomReproduced     = $pSymptomReproduced
        adviceLines           = @($pAdviceLines)
        adviceNamesPyproject  = $pAdviceNamesPyproject
        adviceNoRequirements  = $pAdviceNoRequirements
        statusState           = $p.StatusState
    }
})

# ---- scenario 3 (Item 124, README REQ-018.13): what the scan must not report, then the cached-EXE fast path ----
# Judges. Each takes plain values and returns a list of problems, and uses nothing but its parameters: tests/test_scan_skip_rows.py
# runs them alone and in strict mode through a real pwsh on consoles built from the batch file's own echo lines.

# The module of each "[WARN] Your program needed the module X ..." line of a console, in order.
function Get-NamedModules {
    param([string]$ConsoleText)
    $names = New-Object System.Collections.ArrayList
    foreach ($m in [regex]::Matches($ConsoleText, '\[WARN\] Your program needed the module (\S+)')) { [void]$names.Add($m.Groups[1].Value) }
    return $names.ToArray()
}

# The modules the closing reminder lists, in order: its lines of the form "***   name" under the heading, up to the first other line.
function Get-HeadsUpModules {
    param([string]$ConsoleText)
    $names = New-Object System.Collections.ArrayList
    $inside = $false
    foreach ($raw in ($ConsoleText -split "`r?`n")) {
        $line = $raw.TrimEnd()
        if ($line -match '^\*\*\* HEADS UP: while your program ran it asked for modules that are not installed: \*\*\*$') { $inside = $true; continue }
        if ($inside) {
            if ($line -match '^\*\*\*   (\S+)$') { [void]$names.Add($Matches[1]) } else { $inside = $false }
        }
    }
    return $names.ToArray()
}

# The first bootstrap of scenario 3: three modules named in stderr, one of them reportable.
function Get-ScanSkipProblems {
    param([string]$ConsoleText, [string]$StderrText, [string[]]$RowModules)
    $problems = New-Object System.Collections.ArrayList
    foreach ($want in @('xlsxwriter', 'fcntl', 'rtmsibling')) {
        if ($StderrText -notmatch ("ModuleNotFoundError: No module named '" + $want + "'")) {
            [void]$problems.Add("precondition: the run's stderr holds no 'ModuleNotFoundError: No module named' line for $want, so the program no longer shows the symptom this row needs (the scan reads only that sentence)")
        }
    }
    $named = @(Get-NamedModules -ConsoleText $ConsoleText)
    $xlsxCount = @($named | Where-Object { $_ -ceq 'xlsxwriter' }).Count
    if ($xlsxCount -ne 1) {
        [void]$problems.Add("the console names xlsxwriter as missing $xlsxCount time(s), expected 1: the scan did not run or it repeated itself")
    }
    foreach ($other in @($named | Where-Object { $_ -cne 'xlsxwriter' })) {
        if ($other -ceq 'fcntl') { [void]$problems.Add('the console reports fcntl, a standard library module, as a missing module') }
        elseif ($other -ceq 'rtmsibling') { [void]$problems.Add('the console reports rtmsibling, a module that sits next to the script, as a missing module') }
        else { [void]$problems.Add("the console reports an unexpected module as missing: $other") }
    }
    $listedText = (@(Get-HeadsUpModules -ConsoleText $ConsoleText) -join ',')
    if ($listedText -cne 'xlsxwriter') {
        [void]$problems.Add("the closing reminder lists '$listedText', expected only xlsxwriter")
    }
    $rowText = (@($RowModules) -join ',')
    if ($rowText -cne 'xlsxwriter') {
        [void]$problems.Add("the rows the bootstrapper wrote to HP_NDJSON name '$rowText', expected only xlsxwriter")
    }
    return $problems.ToArray()
}

# The second bootstrap of scenario 3: the cached EXE is reused and prints its traceback, and nothing is reported.
function Get-FastPathScanProblems {
    param([string]$ConsoleText, [string[]]$RowModules)
    $problems = New-Object System.Collections.ArrayList
    $consoleLines = @(($ConsoleText -split "`r?`n") | ForEach-Object { $_.TrimEnd() })
    $launchAt = -1
    $launches = 0
    for ($i = 0; $i -lt $consoleLines.Count; $i++) {
        if ($consoleLines[$i] -match '\[INFO\] Launching your program now via the cached standalone EXE \(PyInstaller build\): dist\\\S+\.exe$') {
            $launches++
            if ($launchAt -lt 0) { $launchAt = $i }
        }
    }
    if ($launches -ne 1) {
        [void]$problems.Add("precondition: the console says $launches time(s) that the cached EXE is launched, expected 1, so this run was not the cached-EXE fast path")
    }
    if ($ConsoleText -match 'discarding cached EXE and rebuilding') {
        [void]$problems.Add('precondition: the cached EXE was discarded and rebuilt, and a scan after a rebuild is allowed')
    }
    $traceAt = -1
    for ($i = $launchAt + 1; $i -lt $consoleLines.Count; $i++) {
        if ($consoleLines[$i] -match "ModuleNotFoundError: No module named 'xlsxwriter'") { $traceAt = $i; break }
    }
    if ($traceAt -lt 0) {
        [void]$problems.Add('precondition: the traceback of the cached EXE run (No module named xlsxwriter) is not on the console after the launch line, so the scan had nothing to read')
    }
    foreach ($named in @(Get-NamedModules -ConsoleText $ConsoleText)) {
        [void]$problems.Add("the cached-EXE run reported the module $named as missing, and the scan has to be skipped on the fast path")
    }
    if ($ConsoleText -match 'HEADS UP: while your program ran it asked for modules') {
        [void]$problems.Add('the cached-EXE run printed the closing reminder about missing modules')
    }
    $rowText = (@($RowModules) -join ',')
    if ($rowText -ne '') {
        [void]$problems.Add("the cached-EXE run wrote self.runtime.module_missing rows for '$rowText'")
    }
    return $problems.ToArray()
}

# One program with three names in stderr. xlsxwriter is a package nobody installed, fcntl is a standard library module that
# Windows does not have, rtmsibling is the module file written next to it. The names are joined at run time (see above) and the
# frozen EXE cannot import rtmsibling: the folder it sits in is not on the EXE's path, and nothing in the build names it.
# The import of fcntl prints whatever the interpreter prints (Python 3.15: "Standard library module 'fcntl' was not found", seen
# in the frozen EXE of run 45973055196; 3.12 and 3.13 print "No module named" for a missing standard library module), and the
# last block raises the classic sentence by hand, so the stderr always holds the text the scan has a rule for.
$skipApp = @'
import importlib
import traceback


def on_click():
    # Stand-in for a GUI callback: each exception is caught, its traceback goes to stderr, and the program carries on and exits 0.
    package, stdlib, sibling = "".join(("xlsx", "writer")), "".join(("fc", "ntl")), "".join(("rtm", "sibling"))
    for name in (package, stdlib, sibling):
        try:
            importlib.import_module(name)
        except ImportError:
            traceback.print_exc()
    # Python 3.15 words a missing standard library module differently (no "No module named" at all); the scan reads the classic
    # sentence, which older Pythons print for it, so print that one as well.
    try:
        raise ModuleNotFoundError("No module named '" + stdlib + "'")
    except ImportError:
        traceback.print_exc()


if __name__ == "__main__":
    on_click()
    print("runtime app ok")
'@
$skipFirst = @{ FolderName = '~selftest_runtime_scan_skips'; AppText = $skipApp; ExtraFiles = @{ 'rtmsibling.py' = 'VALUE = 1' }; LogName = '~sk_run1.log' }
$k1 = Invoke-ModNotFoundScenario @skipFirst
# The second bootstrap of the same folder: the EXE the first one built is fresh, so the fast path takes it. The force flag makes
# that path launch the EXE through the probe, which live-tees the program's output to the console (the plain fast path in CI
# redirects it to files), so the traceback is on the console and the scan has something to read.
$skipSecond = @{ FolderName = '~selftest_runtime_scan_skips'; Again = $true; LogName = '~sk_run2.log'; NdjsonName = '~sub2.ndjson'; EnvVars = @{ HP_TEST_FORCE_INTERACTIVE_PROBE = '1' } }
$k2 = Invoke-ModNotFoundScenario @skipSecond

$k1Problems = @(Get-ScanSkipProblems -ConsoleText $k1.Console -StderrText $k1.ErrText -RowModules @($k1.RowModules))
$skipPass = ($k1.RunExit -eq 0) -and ($k1.StatusState -eq 'ok') -and ($k1Problems.Count -eq 0)
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.scan.skipped'
    req     = 'REQ-018.13'
    pass    = $skipPass
    desc    = 'the scan names a missing package and not a standard library module or a module that sits next to the script'
    details = [ordered]@{
        exitCode      = $k1.RunExit
        statusState   = $k1.StatusState
        problems      = @($k1Problems)
        namedModules  = @(Get-NamedModules -ConsoleText $k1.Console)
        listedModules = @(Get-HeadsUpModules -ConsoleText $k1.Console)
        rowModules    = @($k1.RowModules)
        stdlibLines   = @(($k1.ErrText -split "`r?`n") | Where-Object { $_ -match '^(ModuleNotFoundError|ImportError):.*fcntl' } | ForEach-Object { $_.Trim() })
        log           = '~sk_run1.log'
    }
})

$k2Problems = @(Get-FastPathScanProblems -ConsoleText $k2.Console -RowModules @($k2.RowModules))
$fastPass = ($k2.RunExit -eq 0) -and ($k2.StatusState -eq 'ok') -and ($k2Problems.Count -eq 0)
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.scan.fastpath'
    req     = 'REQ-018.13'
    pass    = $fastPass
    desc    = 'the scan is skipped on the cached-EXE fast path: the run prints its traceback and nothing is reported'
    details = [ordered]@{
        exitCode     = $k2.RunExit
        statusState  = $k2.StatusState
        problems     = @($k2Problems)
        namedModules = @(Get-NamedModules -ConsoleText $k2.Console)
        rowModules   = @($k2.RowModules)
        log          = '~sk_run2.log'
    }
})

if (-not ($modPass -and $pPass -and $skipPass -and $fastPass)) { exit 1 }
exit 0
