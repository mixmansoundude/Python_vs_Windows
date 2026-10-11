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

$workDir = Join-Path $here '~selftest_runtime_modnotfound'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

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
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$bootstrapLog = '~modnotfound_bootstrap.log'
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
$consoleText = ($logLines -join "`n")

# Precondition: the program ran, exited 0, and its stderr holds the traceback. Without this the
# row could pass or fail for a reason that has nothing to do with the new report.
$smokeExit0     = $setupText -match 'Entry smoke exit=0'
$stderrHasTrace = $errText -match "ModuleNotFoundError: No module named 'xlsxwriter'"
$symptomReproduced = $smokeExit0 -and $stderrHasTrace

# (a) The console names the module as not installed. Matched on the [WARN] tag plus the module
# name and the words "not installed", so a harmless rewording of the rest of the line cannot turn
# the row red.
$moduleLine = $null
foreach ($line in $logLines) {
    if ($line -match '\[WARN\].*\bxlsxwriter\b.*not installed') { $moduleLine = $line; break }
}
$consoleNamesModule = [bool]$moduleLine
# Nothing else may be named: the only missing module is xlsxwriter.
$namedModules = @()
foreach ($m in [regex]::Matches($consoleText, '\[WARN\] Your program needed the module (\S+)')) {
    $namedModules += $m.Groups[1].Value
}
$onlyThatModule = ($namedModules.Count -ge 1) -and (@($namedModules | Where-Object { $_ -ne 'xlsxwriter' }).Count -eq 0)

# (b) The bootstrapper's own row, written because HP_NDJSON was set for this run.
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
$rowNamesModule = ($rowModules.Count -ge 1) -and (@($rowModules | Where-Object { $_ -ne 'xlsxwriter' }).Count -eq 0)

$statusPath = Join-Path $workDir '~bootstrap.status.json'
$statusState = $null
if (Test-Path -LiteralPath $statusPath) {
    try { $statusState = (Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { $statusState = $null }
}

$modPass = ($runExit -eq 0) -and $symptomReproduced -and $consoleNamesModule -and $onlyThatModule -and
           $rowNamesModule -and ($statusState -eq 'ok')

Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.modnotfound'
    req     = 'REQ-018'
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
        rowIds             = @($rowIds)
        rowModules         = @($rowModules)
        rowNamesModule     = $rowNamesModule
        statusState        = $statusState
    }
})

if (-not $modPass) { exit 1 }
exit 0
