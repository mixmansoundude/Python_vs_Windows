# ASCII only
# selfapps_unc.ps1 - UNC launch path (docs/plan-test-suite-gaps.md gap T9, README REQ-003 limitation).
#
# run_setup.bat prints a UNC warning when it is started from \\server\share and then cannot cd into that folder
# (cmd.exe has no UNC working directory), so it stops with "[ERROR] Workspace path invalid" and exit 1. That
# branch has never run in CI. This script starts a copy of the bootstrapper through the local admin share of
# the runner itself, \\localhost\<drive>$\..., and checks what the user would see.
#
# Two rows:
#   self.warn.unc.probe  does \\localhost\<drive>$\<scratch> reach the SAME folder as the local path? A marker
#                        file written locally is read back through the share. The row only records the answer
#                        (pass is true whenever the probe itself ran): its job is to say whether the next row
#                        can run on this runner image.
#   self.warn.unc        only when the probe reached the folder: the bootstrapper started through the share must
#                        print the UNC warning, print "Workspace path invalid", exit 1, leave no dist folder and
#                        finish inside the time limit. When the share is not reachable the row reports skip with
#                        reason unc-share-unavailable (a skip, not a pass of the behavior).
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py
# scans text, not PowerShell).
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"). One short bootstrap that stops
# at the path check, so it needs neither a network nor a Python.
# Emits: self.warn.unc.probe, self.warn.unc
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

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{
        id = 'self.warn.unc.probe'; req = 'REQ-003'; pass = $true
        desc = 'UNC admin-share probe (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id = 'self.warn.unc'; req = 'REQ-003.4'; pass = $true
        desc = 'UNC launch path (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id = 'self.warn.unc.probe'; req = 'REQ-003'; pass = $false
        desc = 'UNC admin-share probe: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    Write-NdjsonRow ([ordered]@{
        id = 'self.warn.unc'; req = 'REQ-003.4'; pass = $false
        desc = 'UNC launch path: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$root     = Join-Path $here '~selftest_unc'
$evidence = Join-Path $here '~selftest_unc_evidence'
foreach ($p in @($root, $evidence)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
$dir = Join-Path $root 'app'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
Copy-Item -LiteralPath $batchPath -Destination $dir -Force
Set-Content -LiteralPath (Join-Path $dir 'unc_app.py') -Value 'print("unc-app-ran")' -Encoding ASCII

# --- probe: the local folder as seen through \\localhost\<drive>$ ---------------------------------------------------
$localFull = (Resolve-Path -LiteralPath $dir).Path
$uncDir = ''
$driveLetter = ''
if ($localFull -match '^([A-Za-z]):\\(.*)$') {
    $driveLetter = $Matches[1]
    $uncDir = '\\localhost\' + $driveLetter + '$\' + $Matches[2]
}
$marker = [guid]::NewGuid().ToString()
$markerLocal = Join-Path $dir '~unc_marker.txt'
Set-Content -LiteralPath $markerLocal -Value $marker -Encoding ASCII
$probeExists = $false
$markerSeen = $false
$probeError = ''
if ($uncDir) {
    try {
        $probeExists = [bool](Test-Path -LiteralPath $uncDir -ErrorAction Stop)
        if ($probeExists) {
            $seen = (Get-Content -LiteralPath (Join-Path $uncDir '~unc_marker.txt') -Raw -ErrorAction Stop)
            $markerSeen = ([string]$seen).Trim() -ceq $marker
        }
    } catch {
        $probeError = ($_.Exception.Message -replace '[^\x20-\x7E]', '?')
    }
} else {
    $probeError = 'scratch path has no drive letter: ' + ($localFull -replace '[^\x20-\x7E]', '?')
}
Remove-Item -LiteralPath $markerLocal -Force -ErrorAction SilentlyContinue
$reachable = $probeExists -and $markerSeen
Write-NdjsonRow ([ordered]@{
    id = 'self.warn.unc.probe'; req = 'REQ-003'; pass = $true
    desc = 'Probe: the runner admin share \\localhost\<drive>$ reaches the scratch folder (decides whether self.warn.unc can run)'
    details = [ordered]@{
        localPath = $localFull
        uncPath = $uncDir
        shareExists = [bool]$probeExists
        markerReadThroughShare = [bool]$markerSeen
        reachable = [bool]$reachable
        error = $probeError
    }
})

if (-not $reachable) {
    Write-NdjsonRow ([ordered]@{
        id = 'self.warn.unc'; req = 'REQ-003.4'; pass = $true
        desc = 'UNC launch path: not exercised, the runner admin share is unavailable (a skip, not a pass of the behavior)'
        details = [ordered]@{ skip = $true; reason = 'unc-share-unavailable'; uncPath = $uncDir; probeError = $probeError }
    })
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    exit 0
}

# --- launch the copy through the share --------------------------------------------------------------------------
# The batch stops with exit code 1 (REQ-003 limitation: Workspace path invalid).
$expectedExit = 1
$limitMs = 180000

$uncBat = Join-Path $uncDir 'run_setup.bat'
$log = Join-Path $root '~unc_launch.log'
$wrapper = Join-Path $root '~unc_launch.cmd'
# The wrapper lives and logs locally; only the batch itself is reached through the share. cmd.exe is started from a
# local working directory, as a user double-clicking a file on a share would also not have a UNC working directory.
Set-Content -LiteralPath $wrapper -Value @('@echo off', ('call "' + $uncBat + '" > "' + $log + '" 2>&1'), 'exit /b %ERRORLEVEL%') -Encoding ASCII

$envSet = [ordered]@{ HP_SKIP_PIPREQS = '1' }
if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $envSet['HP_CI_LANE'] = 'test' }
$saved = @{}
foreach ($k in @($envSet.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envSet[$k]) }
$exitCode = -1
$timedOut = $false
$sw = [System.Diagnostics.Stopwatch]::StartNew()
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'
    $psi.Arguments = '/d /c call "' + $wrapper + '"'
    $psi.WorkingDirectory = $here
    $psi.UseShellExecute = $false
    $proc = [System.Diagnostics.Process]::Start($psi)
    if (-not $proc.WaitForExit($limitMs)) {
        $timedOut = $true
        & taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null
        $null = $proc.WaitForExit(5000)
    } else {
        $exitCode = $proc.ExitCode
    }
} finally {
    $sw.Stop()
    foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
}

$logText = ''
if (Test-Path -LiteralPath $log) { $logText = Get-Content -LiteralPath $log -Raw -Encoding ASCII }
if ($null -eq $logText) { $logText = '' }
$warnFound = $logText -match 'WARNING: UNC/network paths detected'
$invalidFound = $logText -match 'Workspace path invalid'
$noDist = -not (Test-Path -LiteralPath (Join-Path $dir 'dist'))
$noSetupLog = -not (Test-Path -LiteralPath (Join-Path $dir '~setup.log'))
$tail = @((($logText -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -Last 12) | ForEach-Object { ($_ -replace '[^\x20-\x7E]', '?') })

foreach ($f in @('~unc_launch.log')) {
    $src = Join-Path $root $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $evidence $f) -Force }
}
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue

$pass = (-not $timedOut) -and ($exitCode -eq $expectedExit) -and $warnFound -and $invalidFound -and $noDist
Write-NdjsonRow ([ordered]@{
    id = 'self.warn.unc'; req = 'REQ-003.4'; pass = [bool]$pass
    desc = 'REQ-003 limitation: started through \\localhost\<drive>$ the bootstrapper warns about the UNC path, reports Workspace path invalid and exits 1 without hanging'
    details = [ordered]@{
        uncPath = $uncBat
        exitCode = $exitCode
        expectedExit = $expectedExit
        timedOut = [bool]$timedOut
        elapsedSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        warningPrinted = [bool]$warnFound
        workspaceInvalidPrinted = [bool]$invalidFound
        noDistFolder = [bool]$noDist
        noSetupLog = [bool]$noSetupLog
        logTail = @($tail)
    }
})
if (-not $pass) { exit 1 }
exit 0
# TEMP PROBE (Item 35, registry check gating; removed in the next commit): id = 'probe.registry.unregistered'
