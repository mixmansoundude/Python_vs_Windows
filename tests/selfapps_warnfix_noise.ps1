# ASCII only
# selfapps_warnfix_noise.ps1 - CLAUDE.md Item 64 (README REQ-005.9): warnfix must never try to
# install a name that cannot be installed.
#
# One real bootstrap of a program that imports nothing third-party but whose PyInstaller build
# still lists noise in its warn file, exactly like every real build does:
#   - `from multiprocessing import Pool, freeze_support` -> "missing module named multiprocessing.Pool"
#     (a stdlib package; the attribute is created at import time, so PyInstaller cannot see it),
#   - `import pkgutil` -> PyInstaller's own runtime hook -> "missing module named pyimod02_importers",
#   - `import platform` -> "missing module named java" and "vms_lib" (other interpreters' branches).
# Field report 2026-10-09: warnfix tried to install multiprocessing (an unrelated Python 2 backport
# from PyPI, which cannot build) and pyimod02_importers (on no index), both failed, and the failed
# repair raised the provider-cascade prompt.
#
# Row: self.warnfix.noise.stdlib. It first proves its own precondition (the warn file really lists
# the noise, so a PyInstaller that stops printing it cannot make the row pass vacuously), then
# requires: no "Attempting to install" line at all, no failed repair, no cascade candidate, and an
# EXE that was built and runs.
#
# Lane: real and conda-full (uv and conda repair-install paths).
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
        id      = 'self.warnfix.noise.stdlib'
        req     = 'REQ-005'
        pass    = $true
        desc    = 'warnfix never installs stdlib or never-installable names (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.warnfix.noise.stdlib'
        req     = 'REQ-005'
        pass    = $false
        desc    = 'warnfix noise: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_warnfix_noise'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# No requirements.txt on purpose: every import below is stdlib, so nothing should ever be installed.
$appCode = @'
import os
import pkgutil
import platform
import sys
from multiprocessing import Pool, freeze_support

if __name__ == "__main__":
    freeze_support()
    here = os.path.dirname(os.path.abspath(sys.argv[0]))
    with open(os.path.join(here, "~noise_token.txt"), "w") as f:
        f.write("noise-ok\n")
    print("noise app ok", platform.system(), Pool is not None, pkgutil.__name__)
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$bootstrapLog = '~noise_bootstrap.log'
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $run1Exit = $LASTEXITCODE
} finally {
    Pop-Location
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$warnPath  = Join-Path $workDir '~warnfile.txt'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$warnText  = if (Test-Path $warnPath) { Get-Content -LiteralPath $warnPath -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# Precondition: the build's own warn file lists the noise. Without this the row could pass
# because PyInstaller stopped printing it, which would prove nothing.
$warnHasMultiprocessing = $warnText -match 'missing module named multiprocessing\.'
$warnHasPyimod          = $warnText -match 'missing module named pyimod02_importers'

# Every install the repair step tried, in order ("[INFO] Attempting to install: <name>").
$attempted = @()
foreach ($m in [regex]::Matches($combined, 'Attempting to install: (\S+)')) {
    $attempted += $m.Groups[1].Value
}
$repairFailed     = [regex]::Matches($combined, '\[WARN\] Repair failed:').Count
$repairBlockRan   = $combined -match [regex]::Escape('[REPAIR] missing modules detected')
$cascadeCandidate = $combined -match [regex]::Escape('REQ-009: cascade candidate detected')
$infraError       = $combined -match 'Failed to parse|uv error|pip error'

$envLeaf  = Split-Path $workDir -Leaf
$envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_noise' }
$distDir  = Join-Path $workDir 'dist'
$exePath  = Join-Path $distDir "$envName.exe"
$exeExists = Test-Path -LiteralPath $exePath
$exeExit   = -1
$tokenPath = Join-Path $distDir '~noise_token.txt'
$tokenFound = $false

if ($exeExists) {
    try {
        Push-Location -LiteralPath $distDir
        try {
            cmd /c "`"$exePath`"" *> '~noise_exe.log'
            $exeExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $tokenFound = Test-Path -LiteralPath $tokenPath
    } catch {
        $exeExit = -1
    }
}

$noisePass = $warnHasMultiprocessing -and $warnHasPyimod -and ($attempted.Count -eq 0) -and
             ($repairFailed -eq 0) -and (-not $repairBlockRan) -and (-not $cascadeCandidate) -and
             $exeExists -and ($exeExit -eq 0) -and $tokenFound -and (-not $infraError)

Write-NdjsonRow ([ordered]@{
    id      = 'self.warnfix.noise.stdlib'
    req     = 'REQ-005'
    pass    = $noisePass
    desc    = 'warnfix installs nothing for stdlib and never-installable names; no cascade candidate; EXE built and ran'
    details = [ordered]@{
        exitCode               = $run1Exit
        warnHasMultiprocessing = $warnHasMultiprocessing
        warnHasPyimod          = $warnHasPyimod
        attempted              = @($attempted)
        attemptedCount         = $attempted.Count
        repairFailed           = $repairFailed
        repairBlockRan         = $repairBlockRan
        cascadeCandidate       = $cascadeCandidate
        exeExists              = $exeExists
        exeExit                = $exeExit
        tokenFound             = $tokenFound
        infraError             = $infraError
        exePath                = $exePath
    }
})

if (-not $noisePass) { exit 1 }
exit 0
