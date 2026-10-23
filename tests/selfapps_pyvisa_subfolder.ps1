# ASCII only
# selfapps_pyvisa_subfolder.ps1 - CLAUDE.md Item 78 slice 2 / README REQ-008: an `import visa` that sits only
# in a SUBFOLDER (an archived older program, say) asks before it starts a 30 to 45 minute NI-VISA driver
# install, and the log always names the file that triggered the install branch.
#
# Field report 2026-10-09: the program being run did not use VISA, but an archived subfolder held a file with
# `import visa`; the driver install started, ran, and failed (installer exit code -125202). tools/detect_visa.py
# now prints 0 (nothing), 1 (a match next to run_setup.bat) or 2 (matches only below a subfolder), writes the
# first matching path to ~visa.where, and logs up to three matches. The batch asks only for 2, through a gate
# built like :cascade_consent_gate (answer override, CI auto-decline, timed choice that defaults to no).
#
# Four real runs, each in its own folder (a second run in one folder would take the cached-EXE fast path and
# never reach the VISA step). The gate sits after the HP_SKIP_NIVISA and already-installed checks, so a runner
# without NI-VISA reaches it. The accepted scenario really enters the install branch, the same as
# selfapps_pyvisa.ps1 does for a top-level import; whichever way that install ends (download blocked, installer
# refused, installed) it counts, because the point is only that the answer let the run through.
#   declined : CI lane auto-decline -> the prompt is echoed, `[VISA] skipped (subfolder_only)`, no install step.
#              Runs with HP_VISA_DECISION=Y inherited from the caller: the run must clear it at startup, or the
#              stale answer would stand in for the user's and the question would never be asked.
#   accepted : HP_TEST_VISA_ANSWER=Y -> an install-branch line appears, no subfolder_only. Runs LAST: it may
#              really install NI-VISA on the runner, and every scenario after a real install would see
#              `[VISA] present` and skip the prompt it is meant to exercise.
#   topfolder: the import is next to run_setup.bat -> no prompt, today's behavior (HP_SKIP_NIVISA=1 keeps it
#              from installing; `skipped (disabled)` shows it went straight to the install branch checks)
#   timeout  : HP_TEST_FORCE_INTERACTIVE_VISA=1 reaches the timed `choice` prompt (2s) and nobody answers
#
# Emits: self.nivisa.subfolder.declined, self.nivisa.subfolder.accepted, self.nivisa.topfolder.noprompt,
#        self.nivisa.subfolder.timeout
#
# Lanes: real and conda-full (gating), wired in batch-check.yml next to the existing pyvisa step.
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
    $skipDetails = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.subfolder.declined'; req = 'REQ-008'; pass = $true; desc = 'NI-VISA subfolder prompt skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.subfolder.accepted'; req = 'REQ-008'; pass = $true; desc = 'NI-VISA subfolder prompt skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.topfolder.noprompt'; req = 'REQ-008'; pass = $true; desc = 'NI-VISA subfolder prompt skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.subfolder.timeout';  req = 'REQ-008'; pass = $true; desc = 'NI-VISA subfolder prompt skipped on non-Windows host'; details = $skipDetails })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.subfolder.declined'; req = 'REQ-008'; pass = $false; desc = 'run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

# Run one scenario in its own folder and return the captured console text, the setup log text and the folder.
# $files maps a relative path to its text; $envSet maps variable names to values for this run only.
function Invoke-VisaScenario {
    param([string]$Name, [hashtable]$Files, [hashtable]$EnvSet)
    $work = Join-Path $here ('~selftest_pyvisa_sub_' + $Name)
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Copy-Item -LiteralPath $batchPath -Destination $work -Force
    foreach ($rel in $Files.Keys) {
        $target = Join-Path $work $rel
        $parent = Split-Path -Path $target -Parent
        if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        Set-Content -LiteralPath $target -Value $Files[$rel] -Encoding Ascii
    }
    $names = @('HP_TEST_VISA_ANSWER', 'HP_TEST_FORCE_INTERACTIVE_VISA', 'HP_SKIP_NIVISA', 'HP_SKIP_PIPREQS', 'HP_VISA_DECISION')
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $null) }
    foreach ($k in $EnvSet.Keys) { [Environment]::SetEnvironmentVariable($k, $EnvSet[$k]) }
    # A local run without a CI lane would reach the real interactive prompt and wait for a person.
    $addedLane = $false
    if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $env:HP_CI_LANE = 'selfapps_pyvisa_subfolder'; $addedLane = $true }
    $consoleName = '~pyvisa_sub_' + $Name + '.log'
    $exit = -1
    Push-Location -LiteralPath $work
    try {
        cmd /c "call run_setup.bat > $consoleName 2>&1"
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        if ($addedLane) { Remove-Item Env:HP_CI_LANE -ErrorAction SilentlyContinue }
    }
    $consolePath = Join-Path $work $consoleName
    $setupPath = Join-Path $work '~setup.log'
    $console = if (Test-Path -LiteralPath $consolePath) { Get-Content -LiteralPath $consolePath -Raw -Encoding Ascii } else { '' }
    $setup = if (Test-Path -LiteralPath $setupPath) { Get-Content -LiteralPath $setupPath -Raw -Encoding Ascii } else { '' }
    return [pscustomobject]@{ Exit = $exit; Console = $console; Setup = $setup; Work = $work }
}

$mainPlain = "print('pyvisa-subfolder-main-ran')"
$archived = "import visa`r`nprint('archived program')"
$subFiles = @{ 'main.py' = $mainPlain; 'archive\old_tool.py' = $archived; 'requirements.txt' = 'pyvisa' }
$topFiles = @{ 'main.py' = "import pyvisa`r`nprint('pyvisa-top-main-ran')"; 'requirements.txt' = 'pyvisa' }

$promptText = 'NI-VISA driver looks needed only by a file in a subfolder'
$foundSub = [regex]::Escape('[VISA] pyvisa/visa import found in: archive\old_tool.py (subfolder)')
$foundTop = [regex]::Escape('[VISA] pyvisa/visa import found in: main.py (top folder)')
$noInstallStep = { param($text) -not (($text -match [regex]::Escape('[VISA] download method')) -or ($text -match [regex]::Escape('[VISA] present')) -or ($text -match [regex]::Escape('[VISA] install_'))) }

# ---- declined: the CI lane auto-decline -------------------------------------------------------------
$d = Invoke-VisaScenario -Name 'declined' -Files $subFiles -EnvSet @{ HP_VISA_DECISION = 'Y' }
$dFound = $d.Setup -match $foundSub
$dPrompt = $d.Console -match [regex]::Escape($promptText)
$dSkipped = $d.Console -match [regex]::Escape('[VISA] skipped (subfolder_only)')
$dNoInstall = (& $noInstallStep $d.Console) -and (& $noInstallStep $d.Setup) -and (-not (Test-Path -LiteralPath (Join-Path $d.Work '~ni-visa-runtime.exe')))
$dPass = $dFound -and $dPrompt -and $dSkipped -and $dNoInstall
Write-NdjsonRow ([ordered]@{
    id      = 'self.nivisa.subfolder.declined'
    req     = 'REQ-008'
    pass    = $dPass
    desc    = 'An import visa that sits only in a subfolder is logged by path, the prompt is shown, and a non-interactive run declines without an install step even when a consent answer is inherited from the caller'
    details = [ordered]@{ exit = $d.Exit; foundLine = $dFound; promptEchoed = $dPrompt; skippedSubfolderOnly = $dSkipped; noInstallStep = $dNoInstall }
})

# ---- topfolder: a match next to run_setup.bat keeps today's behavior --------------------------------
$t = Invoke-VisaScenario -Name 'topfolder' -Files $topFiles -EnvSet @{ HP_SKIP_NIVISA = '1' }
$tFound = $t.Setup -match $foundTop
$tNoPrompt = -not ($t.Console -match [regex]::Escape($promptText))
$tDisabled = $t.Console -match [regex]::Escape('[VISA] skipped (disabled)')
$tNoSubfolderSkip = -not ($t.Console -match [regex]::Escape('[VISA] skipped (subfolder_only)'))
$tPass = $tFound -and $tNoPrompt -and $tDisabled -and $tNoSubfolderSkip
Write-NdjsonRow ([ordered]@{
    id      = 'self.nivisa.topfolder.noprompt'
    req     = 'REQ-008'
    pass    = $tPass
    desc    = 'An import pyvisa next to run_setup.bat is logged as a top folder match and goes straight to the install branch with no prompt'
    details = [ordered]@{ exit = $t.Exit; foundLine = $tFound; noPrompt = $tNoPrompt; reachedInstallBranch = $tDisabled; noSubfolderSkip = $tNoSubfolderSkip }
})

# ---- timeout: the timed choice prompt, nobody answers ------------------------------------------------
$o = Invoke-VisaScenario -Name 'timeout' -Files $subFiles -EnvSet @{ HP_TEST_FORCE_INTERACTIVE_VISA = '1' }
$oFound = $o.Setup -match $foundSub
$oTimedPrompt = $o.Console -match [regex]::Escape('Install the NI-VISA driver now?')
$oSkipped = $o.Console -match [regex]::Escape('[VISA] skipped (subfolder_only)')
$oNoInstall = (& $noInstallStep $o.Console) -and (& $noInstallStep $o.Setup)
$oPass = $oFound -and $oTimedPrompt -and $oSkipped -and $oNoInstall
Write-NdjsonRow ([ordered]@{
    id      = 'self.nivisa.subfolder.timeout'
    req     = 'REQ-008'
    pass    = $oPass
    desc    = 'With the timed prompt forced and nobody answering, the subfolder-only NI-VISA install is declined after the timeout'
    details = [ordered]@{ exit = $o.Exit; foundLine = $oFound; timedPromptShown = $oTimedPrompt; skippedSubfolderOnly = $oSkipped; noInstallStep = $oNoInstall }
})

# ---- accepted: the answer override says yes ---------------------------------------------------------
$a = Invoke-VisaScenario -Name 'accepted' -Files $subFiles -EnvSet @{ HP_TEST_VISA_ANSWER = 'Y' }
$aFound = $a.Setup -match $foundSub
$aPrompt = $a.Console -match [regex]::Escape($promptText)
$aAcceptedLine = $a.Console -match [regex]::Escape('[INFO] NI-VISA install for a subfolder-only import: accepted.')
$aReachedBranch = ($a.Console -match [regex]::Escape('[VISA] download method')) -or ($a.Console -match [regex]::Escape('[VISA] present')) -or ($a.Console -match '\[VISA\] install_')
$aNotDeclined = -not ($a.Console -match [regex]::Escape('[VISA] skipped (subfolder_only)'))
$aPass = $aFound -and $aPrompt -and $aAcceptedLine -and $aReachedBranch -and $aNotDeclined
Write-NdjsonRow ([ordered]@{
    id      = 'self.nivisa.subfolder.accepted'
    req     = 'REQ-008'
    pass    = $aPass
    desc    = 'Answering yes to the subfolder prompt lets the run into the NI-VISA install branch'
    details = [ordered]@{ exit = $a.Exit; foundLine = $aFound; promptEchoed = $aPrompt; acceptedLogged = $aAcceptedLine; reachedInstallBranch = $aReachedBranch; notDeclined = $aNotDeclined }
})

if (-not ($dPass -and $aPass -and $tPass -and $oPass)) { exit 1 }
exit 0
