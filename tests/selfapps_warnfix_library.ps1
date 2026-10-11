# ASCII only
# selfapps_warnfix_library.ps1 - CLAUDE.md Item 64 slice 2 (README REQ-005.9): warnfix must not
# install the optional backends of a library the program only uses.
#
# One real bootstrap of a program whose only third-party import is pandas. PyInstaller's pandas
# hook pulls in the whole package, so the build's warn file lists dozens of modules that pandas
# imports lazily or under a guard (pyarrow, numba, numexpr, sqlalchemy, tables, matplotlib, scipy,
# the Excel and HTML readers, qtpy and PyQt4 for the clipboard, ...). Field report 2026-08/09:
# warnfix installed most of them, took more than 30 minutes, raised the provider-cascade prompt
# and once failed the build with two Qt bindings installed together.
#
# Row: self.warnfix.noise.library. It first proves its own precondition (the warn file really lists
# modules imported by pandas, so a PyInstaller that stops printing them cannot make the row pass
# vacuously), then requires: no "Attempting to install" line at all, no failed repair, no cascade
# candidate, and an EXE that was built and ran. Nothing the program imports is missing, so nothing
# may be installed by warnfix; pandas and its required dependencies come from the up-front install.
#
# Lane: real only. The filter is provider-independent (tools/parse_warn.py), the stdlib scenario
# next to it (selfapps_warnfix_noise.ps1) already covers both repair-install paths, and a pandas
# build under conda-forge would add a long solve to the slowest lane.
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
        id      = 'self.warnfix.noise.library'
        req     = 'REQ-005'
        pass    = $true
        desc    = 'warnfix installs nothing for a library''s optional backends (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.warnfix.noise.library'
        req     = 'REQ-005'
        pass    = $false
        desc    = 'warnfix library noise: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_warnfix_library'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# No requirements.txt on purpose: pipreqs finds pandas from this import, the way a real user's
# first run goes. Nothing else is imported, so nothing else is missing from the program's view.
$appCode = @'
import os
import sys

import pandas as pd

if __name__ == "__main__":
    df = pd.DataFrame({"a": [1, 2, 3], "b": [4, 5, 6]})
    total = int(df["a"].sum() + df["b"].sum())
    here = os.path.dirname(os.path.abspath(sys.argv[0]))
    with open(os.path.join(here, "~library_token.txt"), "w") as f:
        f.write("library-ok %d\n" % total)
    print("library app ok", total)
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$bootstrapLog = '~library_bootstrap.log'
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

# Precondition: the build's own warn file lists modules that pandas itself imports. Without this
# the row could pass because PyInstaller stopped printing them, which would prove nothing.
$pandasLines = [regex]::Matches($warnText, '(?m)^missing module named \S+ - imported by [^\r\n]*\bpandas\.')
$warnHasPandasImports = $pandasLines.Count -gt 0

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
if (-not $envName) { $envName = '_library' }
$distDir  = Join-Path $workDir 'dist'
$exePath  = Join-Path $distDir "$envName.exe"
$exeExists = Test-Path -LiteralPath $exePath
$exeExit   = -1
$tokenPath = Join-Path $distDir '~library_token.txt'
$tokenFound = $false

if ($exeExists) {
    try {
        Push-Location -LiteralPath $distDir
        try {
            cmd /c "`"$exePath`"" *> '~library_exe.log'
            $exeExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $tokenFound = Test-Path -LiteralPath $tokenPath
    } catch {
        $exeExit = -1
    }
}

$libraryPass = ($run1Exit -eq 0) -and $warnHasPandasImports -and ($attempted.Count -eq 0) -and
               ($repairFailed -eq 0) -and (-not $repairBlockRan) -and (-not $cascadeCandidate) -and
               $exeExists -and ($exeExit -eq 0) -and $tokenFound -and (-not $infraError)

Write-NdjsonRow ([ordered]@{
    id      = 'self.warnfix.noise.library'
    req     = 'REQ-005'
    pass    = $libraryPass
    desc    = 'warnfix installs nothing for the optional backends of an installed library; no cascade candidate; EXE built and ran'
    details = [ordered]@{
        exitCode             = $run1Exit
        warnHasPandasImports = $warnHasPandasImports
        pandasWarnLineCount  = $pandasLines.Count
        attempted            = @($attempted)
        attemptedCount       = $attempted.Count
        repairFailed         = $repairFailed
        repairBlockRan       = $repairBlockRan
        cascadeCandidate     = $cascadeCandidate
        exeExists            = $exeExists
        exeExit              = $exeExit
        tokenFound           = $tokenFound
        infraError           = $infraError
        exePath              = $exePath
    }
})

if (-not $libraryPass) { exit 1 }
exit 0
