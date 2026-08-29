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
# Second scenario (self.entry.picker.overflow): 10 non-PREFERRED, no-__main__ files --
# one past :pick_entry_interactive's own >9 GTR-check limit (choice /C only supports the
# 123456789 charset). Asserts the numbered menu is skipped entirely (no
# "Multiple Python files detected" prompt), the overflow log line and its Tip guidance
# both print, and the alphabetically-first file is still chosen -- closes the gap flagged
# in docs/demo-bootstrapper-output.md's picker scenario ("a real coverage gap, not yet a
# dedicated test").
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

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
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

# --- Second scenario: >9 candidates -> numbered menu skipped, Tip guidance still shown ---
$overflowDir = Join-Path $here '~selftest_entry_picker_overflow'
if (Test-Path -LiteralPath $overflowDir) { Remove-Item -LiteralPath $overflowDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $overflowDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $overflowDir -Force
1..10 | ForEach-Object {
    $letter = [char](96 + $_)
    Set-Content -LiteralPath (Join-Path $overflowDir "${letter}_app.py") -Value "print('entry-$letter')`n" -Encoding ASCII
}

$prevForce2 = if (Test-Path Env:HP_TEST_FORCE_PICKER) { $env:HP_TEST_FORCE_PICKER } else { $null }
$prevPip2   = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_TEST_FORCE_PICKER = '1'
$env:HP_SKIP_PIPREQS = '1'
$overflowLog = '~entry_picker_overflow_bootstrap.log'
$overflowExit = -1
Push-Location -LiteralPath $overflowDir
try {
    cmd /c "call run_setup.bat > $overflowLog 2>&1"
    $overflowExit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prevForce2) { Remove-Item Env:HP_TEST_FORCE_PICKER -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PICKER = $prevForce2 }
    if ($null -eq $prevPip2)   { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevPip2 }
}

$overflowLogPath  = Join-Path $overflowDir $overflowLog
$overflowSetupLog = Join-Path $overflowDir '~setup.log'
$overflowLogText  = if (Test-Path $overflowLogPath)  { Get-Content -LiteralPath $overflowLogPath  -Raw -Encoding ASCII } else { '' }
$overflowSetupTxt = if (Test-Path $overflowSetupLog) { Get-Content -LiteralPath $overflowSetupLog -Raw -Encoding ASCII } else { '' }
$overflowCombined = $overflowLogText + "`n" + $overflowSetupTxt

$overflowMenuAbsent = $overflowCombined -notmatch 'Multiple Python files detected'
# :pick_entry_interactive logs %HP_ENTRY% directly here, unlike :record_chosen_entry's separate
# "Chosen entry:" line -- HP_ENTRY at this point is find_entry.py's own bare-filename stdout
# (os.path.normpath() on a bare name adds no ".\" prefix), so no prefix is expected below.
$overflowLimitLogged = $overflowCombined -match [regex]::Escape('candidates exceed picker limit; keeping a_app.py (alphabetical)')
$overflowTipShown = $overflowCombined -match [regex]::Escape('Tip: to avoid the alphabetical fallback next time')
$overflowChosenDefault = $overflowCombined -match 'Chosen entry:.*a_app\.py'

$overflowPass = ($overflowExit -eq 0) -and $overflowMenuAbsent -and $overflowLimitLogged -and $overflowTipShown -and $overflowChosenDefault

Write-NdjsonRow ([ordered]@{
    id='self.entry.picker.overflow'
    req='REQ-002'
    pass=$overflowPass
    desc='More than 9 candidate files skips the numbered menu entirely but still shows Tip guidance, keeping the alphabetical default'
    details=[ordered]@{
        exitCode       = $overflowExit
        menuAbsent     = $overflowMenuAbsent
        limitLogged    = $overflowLimitLogged
        tipShown       = $overflowTipShown
        chosenDefault  = $overflowChosenDefault
        log            = $overflowLog
    }
})

if (-not $overflowPass) { exit 1 }
exit 0
