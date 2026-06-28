# ASCII only
# selfapps_hidden_import.ps1 - REQ-016 Slice 2: strict --hidden-import auto-recovery.
#
# Builds an app that imports an installed module DYNAMICALLY
# (importlib.import_module('colorama')). PyInstaller's static analysis cannot see
# the string argument, so colorama is neither bundled nor listed in the warn file
# -- warnfix cannot catch it. The frozen EXE therefore fails at runtime with
# ModuleNotFoundError: No module named 'colorama'. Because colorama IS installed
# (requirements.txt), the strict double-gate fires: --hidden-import=colorama is
# added, the EXE is rebuilt, and it then runs. colorama is tiny + pure-Python.
#
# The decision logic (ModuleNotFoundError + installed gate, typo/ImportError
# rejection, 3-iter cap) is unit-tested in tests/test_hidden_import_scan.py;
# this is the runtime branch-fired proof.
#
# Emits: self.exe.hidden_import
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

if (-not $IsWindows) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.hidden_import'
        req     = 'REQ-016'
        pass    = $true
        desc    = 'Strict --hidden-import auto-recovery (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.hidden_import'
        req     = 'REQ-016'
        pass    = $false
        desc    = 'Hidden-import recovery: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_hidden_import'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# colorama installed (the "installed" gate) but imported only via a runtime string
# (so PyInstaller misses it and warnfix never sees it).
Set-Content -Path (Join-Path $workDir 'requirements.txt') -Value 'colorama' -Encoding ASCII
$appCode = @'
import importlib
import os as _os
import sys as _sys
_mod = importlib.import_module('colorama')
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~hidden_token.txt'), 'w') as _f:
    _f.write('hidden-ok\n')
print('colorama via importlib ok:', _mod.__name__)
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$bootstrapLog = '~hidden_bootstrap.log'
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

$addingFired    = $combined -match [regex]::Escape('[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama')
$recoveredFired = $combined -match [regex]::Escape('[REPAIR][HIDDEN_IMPORT] EXE verified after hidden-import recovery')
$infraError     = $combined -match 'Failed to parse|uv error|pip error'

$envLeaf  = Split-Path $workDir -Leaf
$envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_hidden' }
$distDir  = Join-Path $workDir 'dist'
$exePath  = Join-Path $distDir "$envName.exe"
$exeExists = Test-Path -LiteralPath $exePath
$exeExit   = -1
$tokenPath = Join-Path $distDir '~hidden_token.txt'
$tokenFound = $false

if ($exeExists) {
    try {
        Push-Location -LiteralPath $distDir
        try {
            cmd /c "`"$exePath`"" *> '~hidden_exe.log'
            $exeExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $tokenFound = Test-Path -LiteralPath $tokenPath
    } catch {
        $exeExit = -1
    }
}

$hiddenPass = $exeExists -and ($exeExit -eq 0) -and $tokenFound -and $addingFired -and $recoveredFired -and (-not $infraError)
Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.hidden_import'
    req     = 'REQ-016'
    pass    = $hiddenPass
    desc    = 'EXE failed on a dynamically-imported installed module; strict --hidden-import recovery rebuilt and verified it'
    details = [ordered]@{
        exitCode       = $run1Exit
        exeExists      = $exeExists
        exeExit        = $exeExit
        tokenFound     = $tokenFound
        addingFired    = $addingFired
        recoveredFired = $recoveredFired
        infraError     = $infraError
        exePath        = $exePath
    }
})

if (-not $hiddenPass) { exit 1 }
exit 0
