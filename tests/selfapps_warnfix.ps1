# ASCII only
# selfapps_warnfix.ps1 - Test PyInstaller warn-file driven missing-module install + rebuild.
#
# Scenarios (controlled by WARNFIX_SCENARIO env var; default: pass):
#
#   pass  - openpyxl app: warnfix installs the missing module and rebuild succeeds.
#           Emits: self.exe.warnfix.install, self.exe.warnfix.pass
#
#   xfail - fake_pkg_xyz123 app: warnfix fires but install fails (nonexistent package).
#           EXE is rebuilt without the module and fails at runtime with ModuleNotFoundError.
#           Infra errors (Failed to parse / uv error / pip error) must not appear.
#           Emits: self.exe.warnfix.xfail
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

$scenario = if ($env:WARNFIX_SCENARIO) { $env:WARNFIX_SCENARIO.ToLower() } else { 'pass' }

# Separate workDir per scenario so both can run in the same CI job without clobbering.
# pass uses the historical name to keep existing artifact paths valid.
$workDirName  = if ($scenario -eq 'xfail') { '~selftest_warnfix_xfail' } else { '~selftest_warnfix' }
$bootstrapLog = if ($scenario -eq 'xfail') { '~warnfix_xfail_bootstrap.log' } else { '~warnfix_bootstrap.log' }

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    if ($scenario -eq 'xfail') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.warnfix.xfail'
            req     = 'REQ-007'
            pass    = $true
            desc    = 'EXE warnfix XFAIL: module error after unfixable warn (skipped on non-Windows)'
            details = [ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' }
        })
    } else {
        foreach ($id in @('self.exe.warnfix.install', 'self.exe.warnfix.pass')) {
            Write-NdjsonRow ([ordered]@{
                id      = $id
                req     = 'REQ-007'
                pass    = $true
                desc    = if ($id -eq 'self.exe.warnfix.install') {
                              'PyInstaller warn file had missing modules; conda install ran'
                          } else {
                              'EXE succeeded after warn-driven rebuild; no infra errors'
                          }
                details = [ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' }
            })
        }
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    if ($scenario -eq 'xfail') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.warnfix.xfail'
            req     = 'REQ-007'
            pass    = $false
            desc    = 'Warnfix XFAIL: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    } else {
        foreach ($id in @('self.exe.warnfix.install', 'self.exe.warnfix.pass')) {
            Write-NdjsonRow ([ordered]@{
                id      = $id
                req     = 'REQ-007'
                pass    = $false
                desc    = 'Warnfix: run_setup.bat not found'
                details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
            })
        }
    }
    exit 1
}

$workDir = Join-Path $here $workDirName
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

if ($scenario -eq 'xfail') {
    # derived requirement: use a static "import fake_pkg_xyz123" so PyInstaller's static
    # analysis detects the reference and writes it to warn-<envname>.txt. The module does
    # not exist on conda-forge, so warnfix fires, install fails ([WARN] Repair failed:),
    # the EXE is rebuilt without the module, and the EXE fails at runtime with
    # ModuleNotFoundError. The test validates this is a module error, not an infra error.
    $appCode = @'
import fake_pkg_xyz123
import os as _os
import sys as _sys
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~warnfix_token.txt'), 'w') as _f:
    _f.write('warnfix-xfail-ok\n')
print('wrote token')
'@
} else {
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
}
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

# Set HP_SKIP_PIPREQS=1 so pipreqs does not run and no module is pre-installed.
# pass: ensures openpyxl is not in the conda env, forcing it into the warn file.
# xfail: fake_pkg_xyz123 would never install via pipreqs anyway, but keep consistent.
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

# EXE run: verify the rebuilt EXE outcome
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

# Read EXE output for failure classification.
# moduleError: EXE failed because a Python module could not be imported (expected for xfail).
# infraError: EXE or bootstrap failed due to tooling issue -- must not count as valid xfail.
$exeLogPath    = Join-Path $distDir '~warnfix_exe.log'
$exeLogContent = if (Test-Path $exeLogPath) { Get-Content -LiteralPath $exeLogPath -Raw -Encoding ASCII } else { '' }
$moduleError   = $exeLogContent -match 'ModuleNotFoundError|ImportError'
$infraError    = $exeLogContent -match 'Failed to parse|uv error|pip error'

if ($scenario -eq 'xfail') {
    # xfail verdict: EXE must exist, fail at runtime, produce a module error, no infra error.
    # Requiring exeExists ensures we detect build failures and do not silently skip the check.
    $xfailPass = $exeExists -and (-not ($exeExit -eq 0)) -and (-not $tokenFound) -and $moduleError -and (-not $infraError)

    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.warnfix.xfail'
        req     = 'REQ-007'
        pass    = $xfailPass
        desc    = 'EXE failed with module error after warnfix could not fix missing module'
        details = [ordered]@{
            scenario               = $scenario
            exitCode               = $run1Exit
            exeExists              = $exeExists
            exeExit                = $exeExit
            tokenFound             = $tokenFound
            moduleError            = $moduleError
            infraError             = $infraError
            warnInstallFired       = $warnInstallFired
            warnRebuildFired       = $warnRebuildFired
            repairFailuresDetected = $repairFailuresDetected
            exePath                = $exePath
        }
    })

    if (-not $xfailPass) { exit 1 }
    exit 0
}

# pass scenario
$successPass = $exeExists -and ($exeExit -eq 0) -and $tokenFound -and (-not $infraError)

# installPass: warnfix fired; also fails if repair failures caused runtime breakage
$installPass = $warnInstallFired -and $warnRebuildFired -and -not ($repairFailuresDetected -and -not $successPass)

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.warnfix.install'
    req     = 'REQ-007'
    pass    = $installPass
    desc    = 'PyInstaller warn file had missing modules; conda install ran'
    details = [ordered]@{
        scenario               = $scenario
        exitCode               = $run1Exit
        warnInstallFired       = $warnInstallFired
        warnRebuildFired       = $warnRebuildFired
        repairFailuresDetected = $repairFailuresDetected
        log                    = $bootstrapLog
    }
})

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.warnfix.pass'
    req     = 'REQ-007'
    pass    = $successPass
    desc    = 'EXE succeeded after warn-driven rebuild; no infra errors'
    details = [ordered]@{
        scenario    = $scenario
        exitCode    = $run1Exit
        exeExists   = $exeExists
        exeExit     = $exeExit
        tokenFound  = $tokenFound
        moduleError = $moduleError
        infraError  = $infraError
        exePath     = $exePath
    }
})

if (-not $installPass -or -not $successPass) { exit 1 }
exit 0
