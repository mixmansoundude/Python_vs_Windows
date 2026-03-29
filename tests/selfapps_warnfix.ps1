# ASCII only
# selfapps_warnfix.ps1 - Test PyInstaller warn-file driven missing-module install + rebuild.
# Creates an app that uses importlib.import_module('openpyxl') so pipreqs misses the dep
# but PyInstaller flags it in the warn file. Verifies that the warn-driven rebuild fires.
# Lane: conda-full and real only.
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

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    foreach ($id in @('self.exe.warnfix.install','self.exe.warnfix.success')) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            pass    = $true
            desc    = if ($id -eq 'self.exe.warnfix.install') {
                          'PyInstaller warn file had missing modules; conda install ran'
                      } else {
                          'EXE succeeded after warn-driven rebuild'
                      }
            details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
        })
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($id in @('self.exe.warnfix.install','self.exe.warnfix.success')) {
        Write-NdjsonRow ([ordered]@{
            id = $id; pass = $false
            desc = 'Warnfix: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    }
    exit 1
}

$workDir = Join-Path $here '~selftest_warnfix'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# derived requirement: use importlib.import_module so pipreqs cannot see the dep
# statically, but PyInstaller's analysis flags it in the warn file. openpyxl is
# available on conda-forge and the translation table maps it to 'openpyxl' (identity).
$appCode = @'
import importlib
import os as _os
import sys as _sys

openpyxl = importlib.import_module('openpyxl')
wb = openpyxl.Workbook()
wb.active['A1'] = 'warnfix-ok'
wb.save('out.xlsx')
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~warnfix_token.txt'), 'w') as _f:
    _f.write('warnfix-ok\n')
print('wrote out.xlsx')
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$bootstrapLog = '~warnfix_bootstrap.log'

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

# derived requirement: exact log phrases from run_setup.bat warnfix block.
$warnInstallPhrase  = 'PyInstaller flagged missing modules; installing and rebuilding.'
$warnRebuildPhrase  = 'PyInstaller rebuild after missing module install complete.'
$warnInstallFired   = $combined -match [regex]::Escape($warnInstallPhrase)
$warnRebuildFired   = $combined -match [regex]::Escape($warnRebuildPhrase)

# Token file is written by the EXE next to itself (in dist/)
$distDir   = Join-Path $workDir 'dist'
$tokenPath = Join-Path $distDir '~warnfix_token.txt'
$tokenFound = Test-Path -LiteralPath $tokenPath

# Run the EXE if it exists
$exeName   = 'app'  # ENVNAME is derived from the workdir folder name
# derive envname the same way run_setup.bat does (alphanum + underscore only)
$envLeaf   = Split-Path $workDir -Leaf
$envName   = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_warnfix' }
$exePath   = Join-Path $distDir "$envName.exe"
$exeExists = Test-Path -LiteralPath $exePath
$exeExit   = -1

if ($exeExists) {
    try {
        Push-Location -LiteralPath $distDir
        try {
            cmd /c "`"$exePath`"" *> '~warnfix_exe.log'
            $exeExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $tokenFound = Test-Path -LiteralPath $tokenPath
    } catch {
        $exeExit = -1
    }
}

$installPass = ($run1Exit -eq 0) -and $warnInstallFired -and $warnRebuildFired
$successPass = ($run1Exit -eq 0) -and $exeExists -and ($exeExit -eq 0) -and $tokenFound

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.warnfix.install'
    pass    = $installPass
    desc    = 'PyInstaller warn file had missing modules; conda install ran'
    details = [ordered]@{
        exitCode           = $run1Exit
        warnInstallFired   = $warnInstallFired
        warnRebuildFired   = $warnRebuildFired
        log                = $bootstrapLog
    }
})

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.warnfix.success'
    pass    = $successPass
    desc    = 'EXE succeeded after warn-driven rebuild'
    details = [ordered]@{
        exitCode    = $run1Exit
        exeExists   = $exeExists
        exeExit     = $exeExit
        tokenFound  = $tokenFound
        exePath     = $exePath
    }
})

if (-not $installPass -or -not $successPass) { exit 1 }
exit 0
