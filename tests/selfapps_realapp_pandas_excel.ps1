# ASCII only
# selfapps_realapp_pandas_excel.ps1 - CLAUDE.md Item 75 (a) and (b): a multi-file pandas + Excel app run the way a
# real user runs it, three times in one folder.
#
# The app is a small stand-in for the maintainer's field runs: main.py imports pandas, one sibling module and one
# sibling package (both with names that no PyPI project uses), and writes an .xlsx file next to the EXE, reads it
# back with pandas and writes a token file. There is no requirements.txt, no pyproject.toml and no PEP 723 header,
# so the whole default path runs: pipreqs scan, the pandas -> openpyxl/xlsxwriter heuristics, the autopep723
# discovery merge (REQ-005.12), the uv install, the PEP 723 write-back (REQ-005.11), the PyInstaller build and the
# verification run of the EXE. No skip hook is set on purpose; every row below is about what that default run does.
#
#   run 1  first run                                    -> rows first_run, deps_discovered, local_modules
#   run 2  nothing changed                              -> row fastpath_rerun
#   run 3  a line appended to requirements.txt          -> row edit_rerun
#
# (c) of the Item 75 text, a first argument that is not a file, is already covered by selfapps_entryarg.ps1.
#
# What each row asserts (the reason it passes, not only the exit code; every sub-check is a named detail):
#   first_run       exit 0, status ok, EXE built, the EXE's own verification run exited 0, the program's token file and
#                   the .xlsx it wrote are in dist\
#   deps_discovered pandas, openpyxl and xlsxwriter installed, the pandas heuristic logged, the recorded dependency
#                   source is pipreqs, and warnfix had nothing to repair (discovery was complete)
#   local_modules   the app's own module and package names are in neither requirements.txt nor the installed set, the
#                   install did not fail, and the precondition holds (autopep723 ran and its merge was logged)
#   fastpath_rerun  the unchanged folder reuses the EXE (log line, same EXE timestamp, no reinstall, no pipreqs scan)
#                   and the EXE really ran again (its token file was deleted first and is written again)
#   edit_rerun      an edit to requirements.txt is noticed (the log says the cached EXE is not reused), the EXE is
#                   rebuilt and runs, the run records the dependency source it used, and what was installed matches
#                   that source (termcolor, the appended line, is installed exactly when the source is requirements.txt)
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text).
#
# Lane: real only, gating from its first run (AGENTS.md "New tests gate immediately"). It needs PyPI like every
# other real-lane scenario and adds two pandas builds, so it is kept off conda-full (the slowest lane).
# Emits: self.realapp.first_run, .deps_discovered, .local_modules, .fastpath_rerun, .edit_rerun
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
    'self.realapp.first_run', 'self.realapp.deps_discovered', 'self.realapp.local_modules',
    'self.realapp.fastpath_rerun', 'self.realapp.edit_rerun'
)
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-001'; pass = $true; desc = 'Real-app pandas + Excel scenario (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-001'; pass = $false; desc = 'Real-app pandas + Excel scenario: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    exit 1
}

# Expected values. The red-test run planted a wrong value for each (total=33, source requirements.txt, EXE changed,
# not-reusing absent) to prove the rows can fail; the real values below are what the first run read back.
$expectedToken    = 'realapp-ok total=32 rows=3'
$expectedSource   = 'pipreqs'
$expectExeChanged = $false   # the unchanged re-run keeps the same EXE
$expectNotReusing = $true    # the edited requirements.txt makes the cached EXE stale

# Names that no PyPI project uses (checked 2026-10-23: pypi.org/simple answers 404), so a stray install attempt
# fails loudly instead of fetching a stranger's package.
$localNames = @('pvw-realapp-sheetio', 'pvw-realapp-report')

$mainPy = @'
import os
import sys

import pandas as pd

import pvw_realapp_sheetio
from pvw_realapp_report import summary


def main():
    here = os.path.dirname(os.path.abspath(sys.argv[0]))
    frame = pvw_realapp_sheetio.sample_frame()
    out_path = os.path.join(here, "~realapp_out.xlsx")
    frame.to_excel(out_path, index=False)
    back = pd.read_excel(out_path)
    total, rows = summary.totals(back)
    with open(os.path.join(here, "~realapp_token.txt"), "w") as handle:
        handle.write("realapp-ok total=%d rows=%d\n" % (total, rows))
    print("realapp ok", total, rows)


if __name__ == "__main__":
    main()
'@
$sheetioPy = @'
import pandas as pd


def sample_frame():
    return pd.DataFrame({"item": ["a", "b", "c"], "qty": [1, 2, 3], "price": [4, 5, 6]})
'@
$reportInitPy = '"""Report helpers for the real-app scenario."""' + "`n"
$summaryPy = @'
def totals(frame):
    return int((frame["qty"] * frame["price"]).sum()), len(frame)
'@

$workDir = Join-Path $here '~selftest_realapp'
if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $workDir 'pvw_realapp_report') | Out-Null
Copy-Item -LiteralPath $batchPath -Destination $workDir -Force
$utf8 = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $workDir 'main.py'), $mainPy, $utf8)
[System.IO.File]::WriteAllText((Join-Path $workDir 'pvw_realapp_sheetio.py'), $sheetioPy, $utf8)
[System.IO.File]::WriteAllText((Join-Path $workDir 'pvw_realapp_report\__init__.py'), $reportInitPy, $utf8)
[System.IO.File]::WriteAllText((Join-Path $workDir 'pvw_realapp_report\summary.py'), $summaryPy, $utf8)

$envName = ((Split-Path $workDir -Leaf) -replace '[^A-Za-z0-9_-]', '_')
$distDir = Join-Path $workDir 'dist'
$exePath = Join-Path $distDir "$envName.exe"
$tokenPath = Join-Path $distDir '~realapp_token.txt'
$xlsxPath = Join-Path $distDir '~realapp_out.xlsx'
$setupPath = Join-Path $workDir '~setup.log'
$reqPath = Join-Path $workDir 'requirements.txt'

# Every skip hook and test override a leaked environment could carry is cleared, in this process and again in the
# launched shell (clearing through SetEnvironmentVariable(name, $null) alone is not trusted, see
# docs/agent-lessons-learned.md). HP_CI_LANE stays: it is what makes the optional prompts resolve without a keyboard.
$clearVars = @(
    'HP_SKIP_ENTRY_SMOKE', 'HP_SKIP_EXE_SMOKERUN', 'HP_SKIP_PEP723_WRITEBACK', 'HP_SKIP_AUTOPEP_DISCOVERY',
    'HP_SKIP_PIPREQS', 'HP_FORCE_CONDA_ONLY', 'PVW_PROVIDER', 'HP_DISABLE_HEURISTICS'
)

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
}

function Get-FileLength {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [long](Get-Item -LiteralPath $Path).Length }
    return [long]0
}

# ~setup.log is only rotated past 10 MB, so it accumulates across the three runs in this folder: read only the bytes
# one run appended, or an earlier run's line is read as this run's (docs/agent-lessons-learned.md).
function Read-Tail {
    param([string]$Path, [long]$From)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        [void]$fs.Seek($From, [System.IO.SeekOrigin]::Begin)
        $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::ASCII)
        return $sr.ReadToEnd()
    } finally {
        $fs.Dispose()
    }
}

function Get-InstalledNames {
    param([string]$Dir)
    $names = New-Object System.Collections.ArrayList
    $path = Join-Path $Dir '~dependency_installed.txt'
    # No comma operator on either return: with @(Get-InstalledNames ...) at the call site a leading comma wraps the
    # array in another array, and every membership test then sees one element holding the whole list.
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    foreach ($line in (Get-Content -LiteralPath $path -Encoding ASCII)) {
        $m = [regex]::Match($line.Trim(), '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(==|@|\s|$)')
        if ($m.Success) { [void]$names.Add((Format-Name $m.Groups[1].Value)) }
    }
    return $names.ToArray()
}

# Package names compare case-insensitively with runs of - _ . treated as one separator (PEP 503).
function Format-Name {
    param([string]$Name)
    return (($Name.ToLowerInvariant()) -replace '[-_.]+', '-')
}

# Requirement names from a requirements.txt or from the quoted lines of autopep723's header-shaped output.
function Get-ListedNames {
    param([string]$Path, [switch]$Quoted)
    $names = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    foreach ($line in (Get-Content -LiteralPath $Path -Encoding ASCII)) {
        $t = $line.Trim()
        if ($Quoted) {
            $m = [regex]::Match($t, '^#\s*"([A-Za-z0-9][A-Za-z0-9._-]*)')
        } else {
            $m = [regex]::Match($t, '^([A-Za-z0-9][A-Za-z0-9._-]*)')
        }
        if ($m.Success) { [void]$names.Add((Format-Name $m.Groups[1].Value)) }
    }
    return $names.ToArray()
}

function Get-RecordedSource {
    param([string]$Dir)
    $p = Join-Path $Dir '~dependency_source.txt'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    $m = [regex]::Match((Get-Content -LiteralPath $p -Raw -Encoding ASCII), 'dependency_source=([A-Za-z0-9._-]+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-LastSmokeExit {
    param([string]$Text)
    $all = [regex]::Matches($Text, 'Entry smoke exit=(-?\d+)')
    if ($all.Count -eq 0) { return $null }
    return [int]$all[$all.Count - 1].Groups[1].Value
}

function Get-StatusState {
    param([string]$Dir)
    $m = [regex]::Match((Read-Text (Join-Path $Dir '~bootstrap.status.json')), '"state"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

function Get-ExeTicks {
    if (Test-Path -LiteralPath $exePath) { return [long](Get-Item -LiteralPath $exePath).LastWriteTimeUtc.Ticks }
    return [long]0
}

# One bootstrap of the folder exactly as a user starts it: no argument, no skip hook.
function Invoke-Run {
    param([string]$Label)
    $logName = "~realapp_$Label.log"
    $wrapperName = "~realapp_launch_$Label.cmd"
    $lines = @('@echo off')
    foreach ($n in $clearVars) { $lines += ('set "' + $n + '="') }
    $lines += "call run_setup.bat > $logName 2>&1"
    $lines += 'exit /b %ERRORLEVEL%'
    Set-Content -LiteralPath (Join-Path $workDir $wrapperName) -Value $lines -Encoding ASCII
    $vars = [ordered]@{}
    foreach ($n in $clearVars) { $vars[$n] = $null }
    if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
    $saved = @{}
    foreach ($k in @($vars.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    $setupFrom = Get-FileLength $setupPath
    $exitCode = -1
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Push-Location -LiteralPath $workDir
    try {
        cmd /c "call $wrapperName" | Out-Null
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $sw.Stop()
    $console = Read-Text (Join-Path $workDir $logName)
    $tail = Read-Tail $setupPath $setupFrom
    Write-Host ("=== real-app run {0}: exit {1}, {2:n0} s ===" -f $Label, $exitCode, $sw.Elapsed.TotalSeconds)
    foreach ($l in (($console -split "`r?`n") | Where-Object { $_ -match 'DEP_SOURCE|dep source selected|Fast path|REQ-005\.1[12]|HEURISTIC|REPAIR|UV_FALLBACK|install.*failed|Entry smoke exit|\[ERROR\]' } | Select-Object -First 30)) { Write-Host $l }
    return [pscustomobject]@{
        Label = $Label; Exit = $exitCode; Seconds = [int]$sw.Elapsed.TotalSeconds
        Console = $console; Tail = $tail; Text = ($console + "`n" + $tail)
    }
}

$anyRed = $false

# ---- run 1: the first run of a folder nobody has prepared
$run1 = Invoke-Run -Label 'run1'
$state1 = Get-StatusState $workDir
$exe1Ticks = Get-ExeTicks
$exe1Exists = Test-Path -LiteralPath $exePath
$smoke1 = Get-LastSmokeExit $run1.Text
$token1 = (Read-Text $tokenPath).Trim()
$xlsx1 = Test-Path -LiteralPath $xlsxPath
$installed1 = @(Get-InstalledNames -Dir $workDir)
$source1 = Get-RecordedSource -Dir $workDir
$reqNames1 = @(Get-ListedNames -Path $reqPath)
$autopepPath = Join-Path $workDir '~requirements.autopep.txt'
$autopepNames = @(Get-ListedNames -Path $autopepPath -Quoted)
$headerAfter1 = (Read-Text (Join-Path $workDir 'main.py')) -match '(?m)^#\s*///\s*script'

# ---- row 1: first_run
$tokenMatches1 = ($token1 -ceq $expectedToken)
$pass = ($run1.Exit -eq 0) -and ($state1 -ceq 'ok') -and $exe1Exists -and ($smoke1 -eq 0) -and $tokenMatches1 -and $xlsx1
if (-not $pass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id = 'self.realapp.first_run'; req = 'REQ-001'; pass = [bool]$pass
    desc = 'A multi-file pandas + Excel app with no dependency file runs end to end on the default path: EXE built, verified, and the program wrote its token and its .xlsx'
    details = [ordered]@{
        exitCode = $run1.Exit; seconds = $run1.Seconds; state = $state1; exeExists = [bool]$exe1Exists
        smokeExit = $smoke1; token = $token1; expectedToken = $expectedToken; tokenMatches = [bool]$tokenMatches1
        xlsxWritten = [bool]$xlsx1
    }
})

# ---- row 2: deps_discovered
$has = { param($list, $name) @($list) -contains $name }
$pandas1 = & $has $installed1 'pandas'
$openpyxl1 = & $has $installed1 'openpyxl'
$xlsxwriter1 = & $has $installed1 'xlsxwriter'
$heuristic1 = $run1.Text -match [regex]::Escape('[HEURISTIC] pandas->openpyxl')
$repairRan1 = $run1.Text -match [regex]::Escape('[REPAIR] missing modules detected')
$attempted1 = @([regex]::Matches($run1.Text, 'Attempting to install: (\S+)') | ForEach-Object { $_.Groups[1].Value })
$pandasDeclared1 = & $has $reqNames1 'pandas'
$sourceOk1 = ($source1 -ceq $expectedSource)
$pass = $pandas1 -and $openpyxl1 -and $xlsxwriter1 -and $heuristic1 -and $sourceOk1 -and (-not $repairRan1) -and ($attempted1.Count -eq 0) -and $pandasDeclared1
if (-not $pass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id = 'self.realapp.deps_discovered'; req = 'REQ-005.8'; pass = [bool]$pass
    desc = 'The pipreqs scan and the pandas heuristics supply pandas, openpyxl and xlsxwriter, the source is recorded as pipreqs, and warnfix has nothing to repair'
    details = [ordered]@{
        pandasInstalled = [bool]$pandas1; openpyxlInstalled = [bool]$openpyxl1; xlsxwriterInstalled = [bool]$xlsxwriter1
        heuristicLogged = [bool]$heuristic1; recordedSource = $source1; expectedSource = $expectedSource; sourceOk = [bool]$sourceOk1
        pandasInRequirements = [bool]$pandasDeclared1; repairBlockRan = [bool]$repairRan1; attempted = @($attempted1)
        requirementsNames = @($reqNames1); installedCount = $installed1.Count
    }
})

# ---- row 3: local_modules
$autopepRan = Test-Path -LiteralPath $autopepPath
$autopepMerged = $run1.Text -match [regex]::Escape('REQ-005.12: autopep723 discovery merge complete')
$installFailed1 = $run1.Text -match [regex]::Escape('uv pip install -r requirements.txt failed')
$localInReq = @($localNames | Where-Object { $reqNames1 -contains $_ })
$localInstalled = @($localNames | Where-Object { $installed1 -contains $_ })
$localReported = @($localNames | Where-Object { $autopepNames -contains $_ })
# The merge must also say which names it skipped: without this a run where autopep723 never listed the local names would pass for the wrong reason.
$localSkipped = $run1.Text -match [regex]::Escape('skipped local:')
$pass = $autopepRan -and $autopepMerged -and ($localReported.Count -eq $localNames.Count) -and $localSkipped -and ($localInReq.Count -eq 0) -and ($localInstalled.Count -eq 0) -and (-not $installFailed1)
if (-not $pass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id = 'self.realapp.local_modules'; req = 'REQ-005.12'; pass = [bool]$pass
    desc = 'The names of the program''s own sibling module and package are never added to requirements.txt or installed, and the install does not fail because of them'
    details = [ordered]@{
        autopepRan = [bool]$autopepRan; autopepMerged = [bool]$autopepMerged; autopepReportedLocal = @($localReported); skippedLocalLogged = [bool]$localSkipped
        localInRequirements = @($localInReq); localInstalled = @($localInstalled); installFailedWarn = [bool]$installFailed1
        requirementsNames = @($reqNames1); autopepNames = @($autopepNames)
    }
})

# ---- run 2: nothing changed. The token file is deleted first so a pass proves the EXE ran again.
if (Test-Path -LiteralPath $tokenPath) { Remove-Item -LiteralPath $tokenPath -Force }
$run2 = Invoke-Run -Label 'run2'
$state2 = Get-StatusState $workDir
$exe2Ticks = Get-ExeTicks
$smoke2 = Get-LastSmokeExit $run2.Text
$token2 = (Read-Text $tokenPath).Trim()
$reused2 = $run2.Text -match [regex]::Escape('Fast path: reusing')
$notReusing2 = $run2.Text -match [regex]::Escape('Fast path: not reusing')
$reinstall2 = $run2.Text -match [regex]::Escape('UV_USED=1')
$pipreqsRan2 = $run2.Text -match [regex]::Escape('pipreqs (direct) command')
$exeChanged2 = ($exe2Ticks -ne $exe1Ticks)
$exeOk2 = ($exeChanged2 -eq $expectExeChanged)
$pass = ($run2.Exit -eq 0) -and ($state2 -ceq 'ok') -and $reused2 -and (-not $notReusing2) -and $exeOk2 -and ($smoke2 -eq 0) -and ($token2 -ceq 'realapp-ok total=32 rows=3') -and (-not $reinstall2) -and (-not $pipreqsRan2)
if (-not $pass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id = 'self.realapp.fastpath_rerun'; req = 'REQ-007'; pass = [bool]$pass
    desc = 'Running the unchanged folder again reuses the cached EXE without a rescan or reinstall, and the EXE runs again'
    details = [ordered]@{
        exitCode = $run2.Exit; seconds = $run2.Seconds; state = $state2; reusedLogged = [bool]$reused2; notReusingLogged = [bool]$notReusing2
        exeChanged = [bool]$exeChanged2; expectExeChanged = $expectExeChanged; exeOk = [bool]$exeOk2
        smokeExit = $smoke2; token = $token2; reinstallLogged = [bool]$reinstall2; pipreqsRan = [bool]$pipreqsRan2
        headerWrittenByRun1 = [bool]$headerAfter1
    }
})

# ---- run 3: the user adds a line to requirements.txt
$reqBefore = Read-Text $reqPath
$sep = if (($reqBefore.Length -gt 0) -and (-not $reqBefore.EndsWith("`n"))) { "`n" } else { '' }
[System.IO.File]::WriteAllText($reqPath, ($reqBefore + $sep + "termcolor`n"), $utf8)
if (Test-Path -LiteralPath $tokenPath) { Remove-Item -LiteralPath $tokenPath -Force }
$run3 = Invoke-Run -Label 'run3'
$state3 = Get-StatusState $workDir
$exe3Ticks = Get-ExeTicks
$smoke3 = Get-LastSmokeExit $run3.Text
$token3 = (Read-Text $tokenPath).Trim()
$installed3 = @(Get-InstalledNames -Dir $workDir)
$source3 = Get-RecordedSource -Dir $workDir
$notReusing3 = $run3.Text -match [regex]::Escape('Fast path: not reusing')
$notReusingOk = ($notReusing3 -eq $expectNotReusing)
$rebuilt3 = ($exe3Ticks -gt $exe2Ticks)
$termcolor3 = $installed3 -contains 'termcolor'
$headerAfter3 = (Read-Text (Join-Path $workDir 'main.py')) -match '(?m)^#\s*///\s*script'
$editConsistent = ($termcolor3 -eq ($source3 -ceq 'requirements.txt'))
$reqNames3 = @(Get-ListedNames -Path $reqPath)
$pass = ($run3.Exit -eq 0) -and ($state3 -ceq 'ok') -and $notReusingOk -and $rebuilt3 -and ($smoke3 -eq 0) -and ($token3 -ceq 'realapp-ok total=32 rows=3') -and ($source3 -ne '') -and $editConsistent
if (-not $pass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id = 'self.realapp.edit_rerun'; req = 'REQ-007'; pass = [bool]$pass
    desc = 'After requirements.txt is edited the cached EXE is not reused, the EXE is rebuilt and runs, and what is installed matches the dependency source the run recorded'
    details = [ordered]@{
        exitCode = $run3.Exit; seconds = $run3.Seconds; state = $state3; notReusingLogged = [bool]$notReusing3; expectNotReusing = $expectNotReusing
        rebuilt = [bool]$rebuilt3; smokeExit = $smoke3; token = $token3; recordedSource = $source3
        termcolorInstalled = [bool]$termcolor3; editConsistent = [bool]$editConsistent
        termcolorInRequirementsAfter = [bool]($reqNames3 -contains 'termcolor'); headerPresentInMainPy = [bool]$headerAfter3
    }
})

if ($anyRed) { exit 1 }
exit 0
