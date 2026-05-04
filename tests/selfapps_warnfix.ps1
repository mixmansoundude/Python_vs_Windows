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
#   real  - openpyxl app with pandas in requirements.txt; Req 5.1 heuristic pre-installs
#           openpyxl so warnfix does NOT fire. EXE succeeds. HP_DISABLE_HEURISTICS not set.
#           Emits: self.exe.warnfix.real
#
#   real_warnfix - xlrd app; xlrd is NOT covered by any heuristic so warnfix MUST fire.
#           EXE succeeds after warnfix installs xlrd and rebuilds. Validates REQ-007
#           warnfix path remains functional alongside REQ-005 heuristic path.
#           Emits: self.exe.warnfix.real_warnfix
#
#   real_warnfix_delayed - xlrd app (function-scoped import); PyInstaller 6.x emits
#           (delayed) qualifier in warn file. parse_warn v3 must process (delayed) entries
#           and warnfix must install xlrd and rebuild. Validates delayed-import branch.
#           Emits: self.exe.warnfix.real_warnfix_delayed
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

# Separate workDir per scenario so all can run in the same CI job without clobbering.
# pass uses the historical name to keep existing artifact paths valid.
$workDirName = switch ($scenario) {
    'xfail'        { '~selftest_warnfix_xfail' }
    'real'         { '~selftest_warnfix_real' }
    'real_warnfix'         { '~selftest_warnfix_real_warnfix' }
    'real_warnfix_delayed' { '~selftest_warnfix_real_warnfix_delayed' }
    default                { '~selftest_warnfix' }
}
$bootstrapLog = switch ($scenario) {
    'xfail'                { '~warnfix_xfail_bootstrap.log' }
    'real'                 { '~warnfix_real_bootstrap.log' }
    'real_warnfix'         { '~warnfix_real_warnfix_bootstrap.log' }
    'real_warnfix_delayed' { '~warnfix_real_warnfix_delayed_bootstrap.log' }
    default                { '~warnfix_bootstrap.log' }
}

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
    } elseif ($scenario -eq 'real') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.warnfix.real'
            req     = 'REQ-005'
            pass    = $true
            desc    = 'Heuristic pre-installed openpyxl; warnfix not triggered (skipped on non-Windows)'
            details = [ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' }
        })
    } elseif ($scenario -eq 'real_warnfix') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.warnfix.real_warnfix'
            req     = 'REQ-007'
            pass    = $true
            desc    = 'Warnfix installed xlrd (not heuristic-covered); EXE succeeded (skipped on non-Windows)'
            details = [ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' }
        })
    } elseif ($scenario -eq 'real_warnfix_delayed') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.warnfix.real_warnfix_delayed'
            req     = 'REQ-007'
            pass    = $true
            desc    = 'Warnfix processed delayed xlrd import; installed xlrd; EXE succeeded (skipped on non-Windows)'
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
    } elseif ($scenario -eq 'real') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.warnfix.real'
            req     = 'REQ-005'
            pass    = $false
            desc    = 'Warnfix REAL: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    } elseif ($scenario -eq 'real_warnfix') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.warnfix.real_warnfix'
            req     = 'REQ-007'
            pass    = $false
            desc    = 'Warnfix REAL_WARNFIX: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    } elseif ($scenario -eq 'real_warnfix_delayed') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.warnfix.real_warnfix_delayed'
            req     = 'REQ-007'
            pass    = $false
            desc    = 'Warnfix REAL_WARNFIX_DELAYED: run_setup.bat not found'
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
} elseif ($scenario -eq 'real') {
    # derived requirement: pandas in requirements.txt triggers Req 5.1 heuristic which
    # pre-installs openpyxl before PyInstaller runs. HP_DISABLE_HEURISTICS is NOT set
    # so the heuristic fires; HP_SKIP_PIPREQS=1 ensures pipreqs does not independently
    # discover openpyxl, isolating the heuristic as the sole install path.
    # Validation: warnfix must NOT fire (openpyxl was pre-installed) and EXE must succeed.
    Set-Content -Path (Join-Path $workDir 'requirements.txt') -Value 'pandas' -Encoding ASCII
    $appCode = @'
import openpyxl
import os as _os
import sys as _sys
wb = openpyxl.Workbook()
wb.active['A1'] = 'heuristic-ok'
wb.save('out.xlsx')
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~warnfix_token.txt'), 'w') as _f:
    _f.write('heuristic-ok\n')
print('wrote out.xlsx')
'@
} elseif ($scenario -eq 'real_warnfix') {
    # derived requirement: xlrd is not covered by any heuristic; no requirements.txt is
    # created so there is nothing for prep_requirements to process. HP_SKIP_PIPREQS=1
    # ensures xlrd is absent when PyInstaller first runs. warnfix must fire to install
    # xlrd and rebuild. Validates that warnfix still works for deps not covered by any
    # heuristic (REQ-007 path remains functional alongside REQ-005 heuristic path).
    $appCode = @'
import xlrd
import os as _os
import sys as _sys
_ = xlrd.__version__
assert callable(xlrd.open_workbook), 'xlrd.open_workbook not accessible'
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~warnfix_token.txt'), 'w') as _f:
    _f.write('real-warnfix-ok\n')
print('xlrd ok')
'@
} elseif ($scenario -eq 'real_warnfix_delayed') {
    # derived requirement: xlrd imported inside do_work() forces PyInstaller 6.x to
    # emit "(delayed)" qualifier in warn file. parse_warn v3 must process (delayed)
    # entries; warnfix installs xlrd and rebuilds. No requirements.txt created.
    $appCode = @'
import os as _os
import sys as _sys

def do_work():
    import xlrd
    _ = xlrd.__version__
    assert callable(xlrd.open_workbook), 'xlrd.open_workbook not accessible'
    _here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
    with open(_os.path.join(_here, '~warnfix_token.txt'), 'w') as _f:
        _f.write('real-warnfix-delayed-ok\n')
    print('xlrd ok (delayed)')

if __name__ == '__main__':
    do_work()
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
# real: ensures openpyxl is only installed via the heuristic (pandas in requirements.txt).
$prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'
# HP_DISABLE_HEURISTICS=1 for pass/xfail so warnfix is the only repair path.
# real: leave heuristics enabled so the Req 5.1 heuristic can pre-install openpyxl.
# real_warnfix/real_warnfix_delayed: heuristics enabled but xlrd is not heuristic-covered
# so enabling/disabling makes no difference; warnfix is still the only repair path for xlrd.
$prevDisableH = if (Test-Path Env:HP_DISABLE_HEURISTICS) { $env:HP_DISABLE_HEURISTICS } else { $null }
if ($scenario -eq 'pass' -or $scenario -eq 'xfail') {
    $env:HP_DISABLE_HEURISTICS = '1'
} else {
    Remove-Item Env:HP_DISABLE_HEURISTICS -ErrorAction SilentlyContinue
}

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
    if ($null -eq $prevDisableH) {
        Remove-Item Env:HP_DISABLE_HEURISTICS -ErrorAction SilentlyContinue
    } else {
        $env:HP_DISABLE_HEURISTICS = $prevDisableH
    }
    Pop-Location
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# derived requirement: exact log phrases from run_setup.bat warnfix block.
$warnInstallPhrase = '[REPAIR] missing modules detected; installing and rebuilding.'
$warnRebuildPhrase = '[REPAIR] rebuild complete after warnfix.'
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

if ($scenario -eq 'real') {
    # derived requirement: ~prep_requirements.py emits '[HEURISTIC] pandas->openpyxl' to stderr
    # (redirected to ~setup.log via '2>> %LOG%'). Checking this phrase is more robust than
    # checking (-not $warnInstallFired) because warnfix can legitimately fire for unrelated
    # modules (e.g. typing_extensions) even when openpyxl was correctly pre-installed.
    $heuristicFired = $combined -match [regex]::Escape('[HEURISTIC] pandas->openpyxl')
    $realPass = $exeExists -and ($exeExit -eq 0) -and $tokenFound -and $heuristicFired -and (-not $infraError)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.warnfix.real'
        req     = 'REQ-005'
        pass    = $realPass
        desc    = 'Heuristic pre-installed openpyxl via pandas heuristic; EXE succeeded'
        details = [ordered]@{
            scenario         = $scenario
            exitCode         = $run1Exit
            exeExists        = $exeExists
            exeExit          = $exeExit
            tokenFound       = $tokenFound
            heuristicFired   = $heuristicFired
            warnInstallFired = $warnInstallFired
            infraError       = $infraError
            exePath          = $exePath
        }
    })
    if (-not $realPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'real_warnfix') {
    # Warnfix must fire (xlrd not heuristic-covered) and EXE must succeed.
    $rwPass = $exeExists -and ($exeExit -eq 0) -and $tokenFound -and $warnInstallFired -and $warnRebuildFired -and (-not $infraError)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.warnfix.real_warnfix'
        req     = 'REQ-007'
        pass    = $rwPass
        desc    = 'Warnfix installed xlrd (not heuristic-covered); EXE succeeded'
        details = [ordered]@{
            scenario         = $scenario
            exitCode         = $run1Exit
            exeExists        = $exeExists
            exeExit          = $exeExit
            tokenFound       = $tokenFound
            warnInstallFired = $warnInstallFired
            warnRebuildFired = $warnRebuildFired
            infraError       = $infraError
            exePath          = $exePath
        }
    })
    if (-not $rwPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'real_warnfix_delayed') {
    # Warnfix must fire for (delayed) xlrd import and EXE must succeed.
    $rwdPass = $exeExists -and ($exeExit -eq 0) -and $tokenFound -and $warnInstallFired -and $warnRebuildFired -and (-not $infraError)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.warnfix.real_warnfix_delayed'
        req     = 'REQ-007'
        pass    = $rwdPass
        desc    = 'Warnfix processed delayed xlrd import; installed xlrd; EXE succeeded'
        details = [ordered]@{
            scenario         = $scenario
            exitCode         = $run1Exit
            exeExists        = $exeExists
            exeExit          = $exeExit
            tokenFound       = $tokenFound
            warnInstallFired = $warnInstallFired
            warnRebuildFired = $warnRebuildFired
            infraError       = $infraError
            exePath          = $exePath
        }
    })
    if (-not $rwdPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'xfail') {
    # xfail verdict: EXE must exist, fail at runtime, produce a module error, no infra error.
    # Also require the warnfix path to have actually executed: install and rebuild phrases must
    # fire and repair must have failed for fake_pkg_xyz123 -- without these guards a regression
    # that disables warn extraction still yields exeExit!=0 + moduleError and fakes a pass.
    $xfailPass = $exeExists -and (-not ($exeExit -eq 0)) -and (-not $tokenFound) -and $moduleError -and (-not $infraError) -and $warnInstallFired -and $warnRebuildFired -and $repairFailuresDetected

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
