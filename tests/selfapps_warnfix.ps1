# ASCII only
# selfapps_warnfix.ps1 - Test PyInstaller warn-file driven missing-module install + rebuild.
#
# Design: HP_SKIP_PIPREQS=1 prevents conda install from running so openpyxl is not
# pre-installed. App uses a direct "import openpyxl" so PyInstaller's static analysis
# detects the reference and flags it in warn-<envname>.txt as a missing module.
# The warnfix step then installs openpyxl via conda and rebuilds the EXE.
#
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
            req     = 'REQ-007'
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
            id = $id; req = 'REQ-007'; pass = $false
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

# derived requirement: use a direct "import openpyxl" so PyInstaller's static analysis
# can find the reference and include it in warn-<envname>.txt when the module is absent.
# HP_SKIP_PIPREQS=1 prevents conda install from running, ensuring openpyxl is not
# installed before PyInstaller runs. The warnfix step then installs it and rebuilds.
# The smoke test will fail (exit=1) because openpyxl is missing, but run_setup.bat
# continues to PyInstaller after a smoke failure.
$appCode = @'
import openpyxl
import os as _os
import sys as _sys

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

# Set HP_SKIP_PIPREQS=1 so pipreqs does not run and openpyxl is not pre-installed.
# This ensures openpyxl shows up in the PyInstaller warn file as a missing module.
$prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'

Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $run1Exit = $LASTEXITCODE
} finally {
    if ($null -eq $prev) {
        Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PIPREQS = $prev
    }
    Pop-Location
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# derived requirement: exact log phrases from run_setup.bat warnfix block.
$warnInstallPhrase = 'PyInstaller flagged missing modules; installing and rebuilding.'
$warnRebuildPhrase = 'PyInstaller rebuild after missing module install complete.'
$warnInstallFired  = $combined -match [regex]::Escape($warnInstallPhrase)
$warnRebuildFired  = $combined -match [regex]::Escape($warnRebuildPhrase)
$repairFailuresDetected = $combined -match [regex]::Escape('[WARN] Repair failed:')

# EXE run: verify the rebuilt EXE has openpyxl bundled and succeeds
$envLeaf  = Split-Path $workDir -Leaf
$envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_warnfix' }
$distDir  = Join-Path $workDir 'dist'
$exePath  = Join-Path $distDir "$envName.exe"
$exeExists = Test-Path -LiteralPath $exePath
$exeExit   = -1
$tokenPath = Join-Path $distDir '~warnfix_token.txt'
$tokenFound = $false

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

$successPass = $exeExists -and ($exeExit -eq 0) -and $tokenFound

# installPass: warnfix fired; also fails if repair failures caused runtime breakage
$installPass = $warnInstallFired -and $warnRebuildFired -and -not ($repairFailuresDetected -and -not $successPass)

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.warnfix.install'
    req     = 'REQ-007'
    pass    = $installPass
    desc    = 'PyInstaller warn file had missing modules; conda install ran'
    details = [ordered]@{
        exitCode               = $run1Exit
        warnInstallFired       = $warnInstallFired
        warnRebuildFired       = $warnRebuildFired
        repairFailuresDetected = $repairFailuresDetected
        log                    = $bootstrapLog
    }
})

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.warnfix.success'
    req     = 'REQ-007'
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
