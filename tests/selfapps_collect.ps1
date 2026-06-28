# ASCII only
# selfapps_collect.ps1 - REQ-005.x: pre-build --collect-submodules double-gate.
#
# Verifies that when the user's app imports a curated dynamic-submodule package
# (plotly) AND that package is installed (via requirements.txt), the bootstrapper
# emits "[INFO] Pre-build collect-submodules:--collect-submodules=plotly" before the
# PyInstaller build, and the EXE builds and runs. plotly is the lightest of the
# curated set (sklearn, matplotlib, scipy, plotly) and has no compiled deps.
#
# The double-gate (used-by-source AND installed) is unit-tested exhaustively in
# tests/test_collect_submodules.py; this is the runtime branch-fired proof.
#
# Emits: self.collect.submodules
# Lane: real and conda-full (uv + conda provider coverage).
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
if (-not $IsWindows) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.collect.submodules'
        req     = 'REQ-005'
        pass    = $true
        desc    = 'Pre-build collect-submodules double-gate (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.collect.submodules'
        req     = 'REQ-005'
        pass    = $false
        desc    = 'Pre-build collect-submodules: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_collect'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# requirements.txt pins plotly so it is installed before the build (the "installed"
# gate). The app imports plotly (the "used" gate). Both must hold for the flag to fire.
Set-Content -Path (Join-Path $workDir 'requirements.txt') -Value 'plotly' -Encoding ASCII
$appCode = @'
import plotly
import os as _os
import sys as _sys
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~collect_token.txt'), 'w') as _f:
    _f.write('collect-ok\n')
print('plotly imported ok')
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$bootstrapLog = '~collect_bootstrap.log'
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $run1Exit = $LASTEXITCODE
} finally {
    Pop-Location
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# Exact log phrase from run_setup.bat :compute_collect_flags, plus the specific flag.
$collectLineFired = $combined -match [regex]::Escape('[INFO] Pre-build collect-submodules:')
$collectPlotly    = $combined -match [regex]::Escape('--collect-submodules=plotly')
$infraError       = $combined -match 'Failed to parse|uv error|pip error'

$envLeaf  = Split-Path $workDir -Leaf
$envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_collect' }
$distDir  = Join-Path $workDir 'dist'
$exePath  = Join-Path $distDir "$envName.exe"
$exeExists = Test-Path -LiteralPath $exePath
$exeExit   = -1
$tokenPath = Join-Path $distDir '~collect_token.txt'
$tokenFound = $false

if ($exeExists) {
    try {
        Push-Location -LiteralPath $distDir
        try {
            cmd /c "`"$exePath`"" *> '~collect_exe.log'
            $exeExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $tokenFound = Test-Path -LiteralPath $tokenPath
    } catch {
        $exeExit = -1
    }
}

$collectPass = $exeExists -and ($exeExit -eq 0) -and $tokenFound -and $collectLineFired -and $collectPlotly -and (-not $infraError)
Write-NdjsonRow ([ordered]@{
    id      = 'self.collect.submodules'
    req     = 'REQ-005'
    pass    = $collectPass
    desc    = 'Pre-build --collect-submodules double-gate emitted plotly flag (used+installed); EXE built and ran'
    details = [ordered]@{
        exitCode         = $run1Exit
        exeExists        = $exeExists
        exeExit          = $exeExit
        tokenFound       = $tokenFound
        collectLineFired = $collectLineFired
        collectPlotly    = $collectPlotly
        infraError       = $infraError
        exePath          = $exePath
    }
})

if (-not $collectPass) { exit 1 }
exit 0
