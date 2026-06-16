# ASCII only
# selfapps_entry_picker.ps1 - REQ-002 interactive entry picker (timed) coverage.
#
# Two non-PREFERRED files with no __main__ -> find_entry takes the ambiguous
# 'fallback' (alphabetical-first = a_app.py) and writes ~find_entry.reason=fallback,
# so run_setup.bat offers the timed picker. HP_TEST_FORCE_PICKER=1 forces the picker
# path even under HP_CI_LANE (which would otherwise gate it off; unsetting HP_CI_LANE
# would trigger the end-of-run pause and hang CI). With no interactive console the
# `choice` prompt degrades to its default (the alphabetical pick) within ~2s, so the
# test verifies the picker runs, shows the menu, and resolves to the default without
# hanging. True human selection needs a console and is out of CI scope.
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
        id='self.entry.picker'; req='REQ-002'; pass=$true
        desc='Timed entry picker degrades to alphabetical default (skipped on non-Windows)'
        details=[ordered]@{ skip=$true; reason='non-windows-host' }
    })
    exit 0
}

$workDir = Join-Path $here '~selftest_entry_picker'
if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $workDir -Force
# Neither file is PREFERRED and neither has a __main__ guard -> ambiguous fallback.
Set-Content -LiteralPath (Join-Path $workDir 'a_app.py') -Value "print('entry-a')`n" -Encoding ASCII
Set-Content -LiteralPath (Join-Path $workDir 'b_app.py') -Value "print('entry-b')`n" -Encoding ASCII

$prevForce = if (Test-Path Env:HP_TEST_FORCE_PICKER) { $env:HP_TEST_FORCE_PICKER } else { $null }
$prevPip   = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_TEST_FORCE_PICKER = '1'
$env:HP_SKIP_PIPREQS = '1'
$bootstrapLog = '~entry_picker_bootstrap.log'
$exit = -1
Push-Location -LiteralPath $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $exit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prevForce) { Remove-Item Env:HP_TEST_FORCE_PICKER -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PICKER = $prevForce }
    if ($null -eq $prevPip)   { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevPip }
}

$logPath  = Join-Path $workDir $bootstrapLog
$setupLog = Join-Path $workDir '~setup.log'
$logText  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Raw -Encoding ASCII } else { '' }
$setupTxt = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined = $logText + "`n" + $setupTxt

$menuShown      = $combined -match 'Multiple Python files detected'
$pickerResolved = $combined -match [regex]::Escape('Picker entry selected: a_app.py')
# :record_chosen_entry prepends '.\' to a bare filename, so the log reads ".\a_app.py".
$chosenDefault  = $combined -match 'Chosen entry:.*a_app\.py'

# Picker ran, showed the menu, and degraded to the alphabetical default with no console
# (no hang -> exit 0).
$pass = ($exit -eq 0) -and $menuShown -and $pickerResolved -and $chosenDefault

Write-NdjsonRow ([ordered]@{
    id='self.entry.picker'
    req='REQ-002'
    pass=$pass
    desc='Timed entry picker shows menu and resolves to the alphabetical default with no console'
    details=[ordered]@{
        exitCode       = $exit
        menuShown      = $menuShown
        pickerResolved = $pickerResolved
        chosenDefault  = $chosenDefault
        log            = $bootstrapLog
    }
})

if (-not $pass) { exit 1 }
exit 0
