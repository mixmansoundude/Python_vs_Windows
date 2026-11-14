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
# Third scenario (self.entry.picker.number): the answer 2 is piped to the prompt. It must select b_app.py, be asked
# for once only, and the program that runs must be b_app.py (Item 109: the question used to be asked twice per run and
# the second, unanswered question took the default).
#
# Fourth scenario (self.entry.picker.metafile): a file named like a macOS metadata file (starts with ._) is not listed
# (README REQ-002.13, Item 108).
#
# Lane: conda-full only (one real bootstrap per scenario; behavior is provider-independent).
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
        id='self.entry.picker'; req='REQ-002.14, REQ-002.22'; pass=$true
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

# REQ-002.14: the list is numbered and holds both candidates, the file that is used when nothing is
# typed is named, and the three ways to avoid the question are printed. The texts are the batch
# file's own echo lines (:pick_entry_interactive); a reworded line is a change to this row too.
$listNumbered   = ($combined -match '\[1\] a_app\.py') -and ($combined -match '\[2\] b_app\.py')
$defaultNamed   = $combined -match [regex]::Escape('If you do nothing, the alphabetically-first file is used: a_app.py')
$tipHeading     = $combined -match [regex]::Escape('Tip: to skip this question next time')
$tipDrop        = $combined -match [regex]::Escape('Drag a .py file onto run_setup.bat')
$tipRename      = $combined -match [regex]::Escape('Rename your main script to one of: main.py, app.py, run.py, or cli.py.')
$tipGuard       = $combined -match [regex]::Escape('Give exactly one script an')
$threeWays      = $tipHeading -and $tipDrop -and $tipRename -and $tipGuard

# Picker ran, showed the menu, and degraded to the alphabetical default with no console
# (no hang -> exit 0).
$pass = ($exit -eq 0) -and $menuShown -and $pickerResolved -and $chosenDefault -and $listNumbered -and $defaultNamed -and $threeWays

Write-NdjsonRow ([ordered]@{
    id='self.entry.picker'
    req='REQ-002.14, REQ-002.22'
    pass=$pass
    desc='Timed entry picker shows menu and resolves to the alphabetical default with no console'
    details=[ordered]@{
        exitCode       = $exit
        menuShown      = $menuShown
        pickerResolved = $pickerResolved
        chosenDefault  = $chosenDefault
        listNumbered   = $listNumbered
        defaultNamed   = $defaultNamed
        threeWays      = $threeWays
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
# REQ-002.17: the three ways to avoid the question are all printed, not only the heading of the tip.
$overflowThreeWays = ($overflowCombined -match [regex]::Escape('Drag a .py file onto run_setup.bat')) -and ($overflowCombined -match [regex]::Escape('Rename your main script to one of: main.py, app.py, run.py, or cli.py.')) -and ($overflowCombined -match [regex]::Escape('Give exactly one script an'))

$overflowPass = ($overflowExit -eq 0) -and $overflowMenuAbsent -and $overflowLimitLogged -and $overflowTipShown -and $overflowThreeWays -and $overflowChosenDefault

Write-NdjsonRow ([ordered]@{
    id='self.entry.picker.overflow'
    req='REQ-002.17, REQ-002.23, REQ-002.24'
    pass=$overflowPass
    desc='More than 9 candidate files skips the numbered menu entirely but still shows Tip guidance, keeping the alphabetical default'
    details=[ordered]@{
        exitCode       = $overflowExit
        menuAbsent     = $overflowMenuAbsent
        limitLogged    = $overflowLimitLogged
        tipShown       = $overflowTipShown
        threeWays      = $overflowThreeWays
        chosenDefault  = $overflowChosenDefault
        log            = $overflowLog
    }
})

# --- Third scenario: the user types a number within the wait (REQ-002.16) ---
# Three candidates, none preferred, no __main__ guard: the alphabetical default is a_app.py (number 1).
# The answer 2 is piped to standard input of the bootstrapper, which the timed `choice` prompt reads.
# If choice did not read the pipe, the prompt would run out its 2 second test wait and take the default,
# so the row passes only when b_app.py is the entry AND the program that ran printed entry-b.
$numberDir = Join-Path $here '~selftest_entry_picker_number'
if (Test-Path -LiteralPath $numberDir) { Remove-Item -LiteralPath $numberDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $numberDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $numberDir -Force
foreach ($letter in 'a', 'b', 'c') {
    Set-Content -LiteralPath (Join-Path $numberDir "${letter}_app.py") -Value "print('entry-$letter')`n" -Encoding ASCII
}

$prevForce3 = if (Test-Path Env:HP_TEST_FORCE_PICKER) { $env:HP_TEST_FORCE_PICKER } else { $null }
$prevPip3   = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_TEST_FORCE_PICKER = '1'
$env:HP_SKIP_PIPREQS = '1'
$numberLog = '~entry_picker_number_bootstrap.log'
$numberExit = -1
Push-Location -LiteralPath $numberDir
try {
    cmd /c "echo 2| call run_setup.bat > $numberLog 2>&1"
    $numberExit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prevForce3) { Remove-Item Env:HP_TEST_FORCE_PICKER -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PICKER = $prevForce3 }
    if ($null -eq $prevPip3)   { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevPip3 }
}

$numberLogPath  = Join-Path $numberDir $numberLog
$numberSetupLog = Join-Path $numberDir '~setup.log'
$numberRunOut   = Join-Path $numberDir '~run.out.txt'
$numberLogText  = if (Test-Path $numberLogPath)  { Get-Content -LiteralPath $numberLogPath  -Raw -Encoding ASCII } else { '' }
$numberSetupTxt = if (Test-Path $numberSetupLog) { Get-Content -LiteralPath $numberSetupLog -Raw -Encoding ASCII } else { '' }
$numberRunText  = if (Test-Path $numberRunOut)   { Get-Content -LiteralPath $numberRunOut   -Raw -Encoding ASCII } else { '' }
$numberCombined = $numberLogText + "`n" + $numberSetupTxt

$numberMenuShown = ($numberCombined -match 'Multiple Python files detected') -and ($numberCombined -match '\[1\] a_app\.py') -and ($numberCombined -match '\[3\] c_app\.py')
$numberPickedB   = $numberCombined -match [regex]::Escape('Picker entry selected: b_app.py')
$numberPickedA   = $numberCombined -match [regex]::Escape('Picker entry selected: a_app.py')
$numberRanB      = ($numberRunText -match 'entry-b') -and ($numberRunText -notmatch 'entry-a')
# Item 109: the question is asked once per run and the typed answer is the one that is used. Counted from the
# console log (one heading per question) and from the setup log (one line per question that was resolved).
$numberAsked      = [regex]::Matches($numberLogText, 'Multiple Python files detected').Count
$numberPickerRuns = [regex]::Matches($numberSetupTxt, [regex]::Escape('Picker entry selected:')).Count
$numberPass = ($numberExit -eq 0) -and $numberMenuShown -and $numberPickedB -and $numberRanB -and ($numberAsked -eq 1) -and ($numberPickerRuns -eq 1)

Write-NdjsonRow ([ordered]@{
    id='self.entry.picker.number'
    req='REQ-002.16, REQ-002.19, REQ-002.26'
    pass=$numberPass
    desc='The number of a listed file typed at the picker selects that file, and that file is the program that runs'
    details=[ordered]@{
        exitCode       = $numberExit
        menuShown      = $numberMenuShown
        pickedB        = $numberPickedB
        pickedDefaultA = $numberPickedA
        asked          = $numberAsked
        pickerRuns     = $numberPickerRuns
        ranB           = $numberRanB
        runOutTail     = $(if ($numberRunText.Length -gt 200) { $numberRunText.Substring(0, 200) } else { $numberRunText })
        log            = $numberLog
    }
})

# --- Fourth scenario: a file that starts with ._ is not a candidate (REQ-002.13, Item 108) ---
# macOS leaves ._name.py next to name.py on a copy through a network share or a zip. find_entry.py skips such a
# file; the picker built its own list with `dir` and offered it. Two real candidates and one metadata file: the list
# must hold the two real files only, so the number of the second one is 2 whatever the metadata file is called.
$metaDir = Join-Path $here '~selftest_entry_picker_metafile'
if (Test-Path -LiteralPath $metaDir) { Remove-Item -LiteralPath $metaDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $metaDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $metaDir -Force
foreach ($metaName in 'a_app.py', 'b_app.py', '._a_app.py') {
    Set-Content -LiteralPath (Join-Path $metaDir $metaName) -Value "print('entry')`n" -Encoding ASCII
}

$prevForce4 = if (Test-Path Env:HP_TEST_FORCE_PICKER) { $env:HP_TEST_FORCE_PICKER } else { $null }
$prevPip4   = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_TEST_FORCE_PICKER = '1'
$env:HP_SKIP_PIPREQS = '1'
$metaLog = '~entry_picker_metafile_bootstrap.log'
$metaExit = -1
Push-Location -LiteralPath $metaDir
try {
    cmd /c "call run_setup.bat > $metaLog 2>&1"
    $metaExit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prevForce4) { Remove-Item Env:HP_TEST_FORCE_PICKER -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PICKER = $prevForce4 }
    if ($null -eq $prevPip4)   { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevPip4 }
}

$metaLogPath = Join-Path $metaDir $metaLog
$metaLogText = if (Test-Path $metaLogPath) { Get-Content -LiteralPath $metaLogPath -Raw -Encoding ASCII } else { '' }
$metaMenuShown   = $metaLogText -match 'Multiple Python files detected'
# The premise: both real files are listed, with whatever numbers they were given.
$metaRealListed  = ($metaLogText -match '\[\d\] a_app\.py') -and ($metaLogText -match '\[\d\] b_app\.py')
# The finding: a list entry for the metadata file, with whatever number it was given.
$metaMetaListed  = $metaLogText -match '\[\d\] \._a_app\.py'
# The result: the two real files are the whole list, so they are entries 1 and 2.
$metaNumbered    = ($metaLogText -match '\[1\] a_app\.py') -and ($metaLogText -match '\[2\] b_app\.py')
$metaPass = ($metaExit -eq 0) -and $metaMenuShown -and $metaRealListed -and (-not $metaMetaListed) -and $metaNumbered

Write-NdjsonRow ([ordered]@{
    id='self.entry.picker.metafile'
    req='REQ-002.13'
    pass=$metaPass
    desc='A file whose name starts with ._ is not offered by the entry picker'
    details=[ordered]@{
        exitCode      = $metaExit
        menuShown     = $metaMenuShown
        realListed    = $metaRealListed
        metaListed    = $metaMetaListed
        numbered      = $metaNumbered
        log           = $metaLog
    }
})

if (-not $overflowPass -or -not $numberPass -or -not $metaPass) { exit 1 }
exit 0
