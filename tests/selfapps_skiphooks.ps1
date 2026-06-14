# ASCII only
# selfapps_skiphooks.ps1 - REQ-012 super-user execution-skip hooks.
#
# With HP_SKIP_ENTRY_SMOKE=1 and HP_SKIP_EXE_SMOKERUN=1 set together, the
# bootstrapper must create the env, install deps, and build the PyInstaller EXE,
# but run NO user code (neither the entry-script interpreter smoke nor the EXE).
# entry.py writes a marker only when actually executed; the test asserts the
# marker is ABSENT while the build still completed.
#
# Lane: conda-full only (one real bootstrap; behavior is provider-independent).
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

if (-not $IsWindows) {
    Write-NdjsonRow ([ordered]@{
        id='self.skiphooks.combined'; req='REQ-012'; pass=$true
        desc='Skip hooks run no user code while build proceeds (skipped on non-Windows)'
        details=[ordered]@{ skip=$true; reason='non-windows-host' }
    })
    exit 0
}

$workDir = Join-Path $here '~selftest_skiphooks'
if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $workDir -Force

# Marker is written only if the program is actually executed (interpreter or EXE).
Set-Content -LiteralPath (Join-Path $workDir 'entry.py') -Value @'
import os
if __name__ == "__main__":
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "~ran_marker.txt"), "w") as f:
        f.write("executed\n")
    print("ran")
'@ -Encoding ASCII

$markerPath = Join-Path $workDir '~ran_marker.txt'
$bootstrapLog = '~skiphooks_bootstrap.log'

$prevEntry = if (Test-Path Env:HP_SKIP_ENTRY_SMOKE) { $env:HP_SKIP_ENTRY_SMOKE } else { $null }
$prevExe   = if (Test-Path Env:HP_SKIP_EXE_SMOKERUN) { $env:HP_SKIP_EXE_SMOKERUN } else { $null }
$prevPip   = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_ENTRY_SMOKE = '1'
$env:HP_SKIP_EXE_SMOKERUN = '1'
$env:HP_SKIP_PIPREQS = '1'
$exit = -1
Push-Location -LiteralPath $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $exit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prevEntry) { Remove-Item Env:HP_SKIP_ENTRY_SMOKE -ErrorAction SilentlyContinue } else { $env:HP_SKIP_ENTRY_SMOKE = $prevEntry }
    if ($null -eq $prevExe)   { Remove-Item Env:HP_SKIP_EXE_SMOKERUN -ErrorAction SilentlyContinue } else { $env:HP_SKIP_EXE_SMOKERUN = $prevExe }
    if ($null -eq $prevPip)   { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevPip }
}

$logPath  = Join-Path $workDir $bootstrapLog
$setupLog = Join-Path $workDir '~setup.log'
$logText  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Raw -Encoding ASCII } else { '' }
$setupTxt = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined = $logText + "`n" + $setupTxt

$builtExe       = $combined -match 'PyInstaller produced'
$entrySkipped   = $combined -match 'HP_SKIP_ENTRY_SMOKE set'
$exeSkipped     = $combined -match 'HP_SKIP_EXE_SMOKERUN set'
$ranEntrySmoke  = $combined -match 'Running entry script smoke test'
$ranExeSmoke    = $combined -match 'EXE smokerun: testing'
$markerWritten  = Test-Path -LiteralPath $markerPath

# No user code may have executed (marker absent, neither smoke ran), yet the build ran.
$noUserCode = (-not $ranEntrySmoke) -and (-not $ranExeSmoke) -and (-not $markerWritten)
$pass = ($exit -eq 0) -and $builtExe -and $entrySkipped -and $exeSkipped -and $noUserCode

Write-NdjsonRow ([ordered]@{
    id='self.skiphooks.combined'
    req='REQ-012'
    pass=$pass
    desc='HP_SKIP_ENTRY_SMOKE + HP_SKIP_EXE_SMOKERUN: no user code runs, env/build still proceed'
    details=[ordered]@{
        exitCode      = $exit
        builtExe      = $builtExe
        entrySkipped  = $entrySkipped
        exeSkipped    = $exeSkipped
        ranEntrySmoke = $ranEntrySmoke
        ranExeSmoke   = $ranExeSmoke
        markerWritten = $markerWritten
        log           = $bootstrapLog
    }
})

if (-not $pass) { exit 1 }
exit 0
