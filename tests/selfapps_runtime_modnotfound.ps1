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
function Invoke-ModNotFoundScenario {
    param([string]$FolderName, [string]$Pyproject)
    $workDir = Join-Path $here $FolderName
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Copy-Item -Path $batchPath -Destination $workDir -Force
    Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII
    if ($Pyproject) { Set-Content -Path (Join-Path $workDir 'pyproject.toml') -Value $Pyproject -Encoding ASCII }

    $bootstrapLog = if ($Pyproject) { '~modnotfound_pyproject_bootstrap.log' } else { '~modnotfound_bootstrap.log' }
    $subNdjson    = Join-Path $workDir '~sub.ndjson'
    $savedNdjson  = [Environment]::GetEnvironmentVariable('HP_NDJSON')
    Push-Location $workDir
    try {
        [Environment]::SetEnvironmentVariable('HP_NDJSON', $subNdjson)
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('HP_NDJSON', $savedNdjson)
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

if (-not ($modPass -and $pPass)) { exit 1 }
exit 0
