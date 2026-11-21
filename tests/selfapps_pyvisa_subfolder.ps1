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
# Item 122 (README REQ-008.15): the Python pyvisa package is installed whether the answer to the subfolder question is yes or no.
# self.nivisa.pyvisa.installed reads ~dependency_installed.txt of the declined and of the accepted run (the pip freeze the
# bootstrapper writes after the dependency install, which comes before the NI-VISA step, so the file is there whatever the answer
# was) and requires a pyvisa line in both. Limit, stated so that nobody reads more into the row than it shows: both folders declare
# pyvisa in requirements.txt, so the row shows that the answer does not change which packages are installed; it does not show that
# the import alone would add the package. tests/test_visa_present.py runs the two judging functions below on synthetic lists.
#
# Item 124 (README REQ-008.5 and REQ-008.6): what the scan reads and what it does not take for an import. Two more real bootstraps,
# each with HP_SKIP_NIVISA=1 (a wrong scan must never start a real driver install) and with the program itself not started
# (HP_SKIP_ENTRY_SMOKE, HP_SKIP_EXE_SMOKERUN), and a requirements.txt like the scenarios above. The scanner writes one setup-log line
# per matching file (at most three) and the batch file says what it concluded in an [INFO] line of the console, so both are read.
#   scanskips : one real import three folders down (archive\2019\bench\old_tool.py) next to three files the scan must leave
#               alone: a FILE whose name starts with ~ (~scratch.py, next to run_setup.bat, so taking it would end in a top folder
#               match), a FOLDER that starts with ~ (~old) and a FOLDER that starts with a dot (.hidden). The setup log must name
#               the deep file and nothing else, and the console must say the import sits only in a subfolder.
#   lookalike : a file next to run_setup.bat and a file in a subfolder whose imports only begin with the letters of pyvisa or visa
#               (pyvista, vision, pyviscoelastic). The setup log must name no file and the console must say no import was detected.
#               The lookalike row would also pass for a scan that never ran, so it requires the scan of the first scenario to have
#               named its file (a scan that works, on the same machine, in the same lane).
# The judges (Get-ScanSkipsProblems, Get-ScanLookalikeProblems) take plain values and return a list of problems; tests/test_visa_scan.py
# runs them through a real pwsh on synthetic runs, one red case for each comparison, and runs the real tools/detect_visa.py on the
# same fixture files.
#
# Emits: self.nivisa.subfolder.declined, self.nivisa.subfolder.accepted, self.nivisa.topfolder.noprompt,
#        self.nivisa.subfolder.timeout, self.nivisa.pyvisa.installed, self.nivisa.scan.skips, self.nivisa.scan.lookalike
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
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.pyvisa.installed'; req = 'REQ-008.15'; pass = $true; desc = 'NI-VISA subfolder prompt skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.scan.skips'; req = 'REQ-008.5'; pass = $true; desc = 'NI-VISA scan rows skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.scan.lookalike'; req = 'REQ-008.6'; pass = $true; desc = 'NI-VISA scan rows skipped on non-Windows host'; details = $skipDetails })
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
    $names = @('HP_TEST_VISA_ANSWER', 'HP_TEST_FORCE_INTERACTIVE_VISA', 'HP_SKIP_NIVISA', 'HP_SKIP_PIPREQS', 'HP_VISA_DECISION', 'HP_SKIP_ENTRY_SMOKE', 'HP_SKIP_EXE_SMOKERUN')
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

# Judging for the row self.nivisa.pyvisa.installed: plain values in, a list of problems out (tests/test_visa_present.py runs the
# two functions through a real pwsh on synthetic lists, one red case for each comparison).
function Read-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
    if ($null -eq $t) { return '' }
    return [string]$t
}

# The first line of a pip freeze list that names the pyvisa package: pyvisa==1.14.1, or PyVISA @ file:///... as conda lists a package
# it installed. A package whose name only begins with those letters (pyvisa-py) is another package. The line is cut to 120 printable
# ASCII characters; empty when there is none.
function Get-PyvisaLine {
    param([string]$FreezeText)
    foreach ($raw in ($FreezeText -split "`r?`n")) {
        $l = $raw.Trim()
        if ($l -match '^pyvisa(\s*==|\s*@|\s|$)') {
            $clean = ($l -replace '[^\x20-\x7E]', '?')
            if ($clean.Length -gt 120) { $clean = $clean.Substring(0, 120) }
            return $clean
        }
    }
    return ''
}

# One run of the row: the answer to the question must be on record (otherwise the package check says nothing about it), the setup log
# must say that the installed packages were captured, and the list must have a pyvisa line.
function Get-PyvisaFreezeProblems {
    param([string]$Label, [bool]$AnswerShown, [string]$SetupText, [string]$FreezeText)
    $out = New-Object System.Collections.ArrayList
    if (-not $AnswerShown) {
        [void]$out.Add("${Label}: the run does not show the answer to the subfolder question, so the package check says nothing about it")
        return $out.ToArray()
    }
    if ($SetupText.IndexOf('DEP_INSTALLED_CAPTURED=1', [System.StringComparison]::Ordinal) -lt 0) {
        [void]$out.Add("${Label}: the setup log does not say that the installed packages were captured, so the list is not this run's")
        return $out.ToArray()
    }
    if ([string]::IsNullOrWhiteSpace($FreezeText)) {
        [void]$out.Add("${Label}: ~dependency_installed.txt is missing or empty")
        return $out.ToArray()
    }
    $line = Get-PyvisaLine -FreezeText $FreezeText
    if (-not $line) {
        [void]$out.Add("${Label}: the list of installed packages has no pyvisa line")
    }
    return $out.ToArray()
}

# ---- Item 124 judges (README REQ-008.5 and REQ-008.6). Each takes plain values and returns a list of problems and uses nothing but its
# parameters, so tests/test_visa_scan.py can run it alone in strict mode on synthetic runs.

# The files the scanner named in the setup log, in order, each as "<path> (<top folder|subfolder>)". The scanner writes one line per
# matching file to stderr, at most three, and the batch file appends that stderr to ~setup.log.
function Get-VisaFoundFiles {
    param([string]$SetupText)
    $out = New-Object System.Collections.ArrayList
    foreach ($raw in ($SetupText -split "`r?`n")) {
        $l = $raw.TrimEnd()
        if ($l -match '\[VISA\] pyvisa/visa import found in: (.+) \((top folder|subfolder)\)$') { [void]$out.Add($Matches[1] + ' (' + $Matches[2] + ')') }
    }
    return $out.ToArray()
}

# How many lines of a console or a log are exactly this text, after the date and time the batch file puts in front of every line it logs
# (or with nothing in front of it): the text is the whole line or follows a space.
function Get-VisaLineCount {
    param([string]$Text, [string]$Line)
    $n = 0
    foreach ($raw in ($Text -split "`r?`n")) {
        $l = $raw.TrimEnd()
        if (-not $l.EndsWith($Line, [System.StringComparison]::Ordinal)) { continue }
        if (($l.Length -eq $Line.Length) -or ($l.Substring($l.Length - $Line.Length - 1, 1) -eq ' ')) { $n++ }
    }
    return $n
}

# REQ-008.5. WantFile is the one import the scan has to find (three folders down), NotFiles are the files and folders it has to skip,
# MissingFiles are the files of the fixture that are no longer in the folder after the run. The three [INFO] lines are the batch file's
# own conclusions after the scan: only in a subfolder (2), next to run_setup.bat (1), nothing (0). The scanner prints every character
# outside letters, digits and . _ - space \ as an underscore (a path is echoed unquoted), so a ~scratch.py that was taken is in the
# setup log as _scratch.py: the judge looks for that printed form and names the file as it was planted.
function Get-ScanSkipsProblems {
    param([string]$SetupText, [string]$ConsoleText, [string]$WantFile, [string[]]$NotFiles, [string[]]$MissingFiles)
    $problems = New-Object System.Collections.ArrayList
    foreach ($m in $MissingFiles) {
        [void]$problems.Add("precondition: the folder of the run no longer holds $m, so the scan had nothing to read or to skip")
    }
    $found = @(Get-VisaFoundFiles -SetupText $SetupText)
    $wantLine = $WantFile + ' (subfolder)'
    if (-not ($found -ccontains $wantLine)) {
        [void]$problems.Add("the scan did not name $wantLine, so it did not read a subfolder three levels down")
    }
    foreach ($f in $found) {
        if ($f -ceq $wantLine) { continue }
        $known = $false
        foreach ($n in $NotFiles) {
            $printed = [regex]::Replace($n, '[^A-Za-z0-9._\- \\]', '_')
            if ($f.StartsWith($printed + ' (', [System.StringComparison]::Ordinal)) {
                $known = $true
                [void]$problems.Add("the scan took $n for an import, and a file whose name starts with ~ and a folder whose name starts with ~ or a dot are skipped")
            }
        }
        if (-not $known) { [void]$problems.Add("the scan named a file nobody planted as a match: $f") }
    }
    $only = '[INFO] Detected pyvisa/visa import only in a subfolder; the NI-VISA install needs your OK.'
    $top = '[INFO] Detected pyvisa/visa import; NI-VISA install may be required.'
    $none = '[INFO] No pyvisa/visa imports detected.'
    $nOnly = Get-VisaLineCount -Text $ConsoleText -Line $only
    if ($nOnly -ne 1) {
        [void]$problems.Add("the console shows the line '$only' $nOnly time(s), expected 1")
    }
    if ((Get-VisaLineCount -Text $ConsoleText -Line $top) -gt 0) {
        [void]$problems.Add("the console says an import sits next to run_setup.bat, so a skipped file was taken for an import: '$top'")
    }
    if ((Get-VisaLineCount -Text $ConsoleText -Line $none) -gt 0) {
        [void]$problems.Add("the console says no import was detected although $WantFile holds one: '$none'")
    }
    $nDisabled = Get-VisaLineCount -Text $ConsoleText -Line '[VISA] skipped (disabled)'
    if ($nDisabled -ne 1) {
        [void]$problems.Add("precondition: the console shows '[VISA] skipped (disabled)' $nDisabled time(s), expected 1, so the run did not stop at the install step as asked")
    }
    return $problems.ToArray()
}

# REQ-008.6. ScanShownWorking is true when the scan of the scanskips run named its file; without it this row would also pass for a scan
# that never ran.
function Get-ScanLookalikeProblems {
    param([string]$SetupText, [string]$ConsoleText, [string[]]$MissingFiles, [bool]$ScanShownWorking)
    $problems = New-Object System.Collections.ArrayList
    foreach ($m in $MissingFiles) {
        [void]$problems.Add("precondition: the folder of the run no longer holds $m, so the scan had nothing to read")
    }
    if (-not $ScanShownWorking) {
        [void]$problems.Add('precondition: the scan of self.nivisa.scan.skips did not name its file, so this row would pass for a scan that did not run')
    }
    foreach ($f in @(Get-VisaFoundFiles -SetupText $SetupText)) {
        [void]$problems.Add("the scan took $f for an import of pyvisa or visa, and a module whose name only begins with those letters is not one")
    }
    $none = '[INFO] No pyvisa/visa imports detected.'
    $nNone = Get-VisaLineCount -Text $ConsoleText -Line $none
    if ($nNone -ne 1) {
        [void]$problems.Add("the console shows the line '$none' $nNone time(s), expected 1")
    }
    foreach ($text in @('[INFO] Detected pyvisa/visa import; NI-VISA install may be required.', '[INFO] Detected pyvisa/visa import only in a subfolder; the NI-VISA install needs your OK.')) {
        if ((Get-VisaLineCount -Text $ConsoleText -Line $text) -gt 0) {
            [void]$problems.Add("the console says an import was detected: '$text'")
        }
    }
    $nReq = Get-VisaLineCount -Text $ConsoleText -Line '[VISA] skipped (not_required)'
    if ($nReq -ne 1) {
        [void]$problems.Add("the console shows '[VISA] skipped (not_required)' $nReq time(s), expected 1")
    }
    return $problems.ToArray()
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
$dPathInPrompt = $d.Console -match [regex]::Escape('looks needed only by a file in a subfolder: archive\old_tool.py')
$dNoInstall = (& $noInstallStep $d.Console) -and (& $noInstallStep $d.Setup) -and (-not (Test-Path -LiteralPath (Join-Path $d.Work '~ni-visa-runtime.exe')))
$dPass = $dFound -and $dPrompt -and $dPathInPrompt -and $dSkipped -and $dNoInstall
Write-NdjsonRow ([ordered]@{
    id      = 'self.nivisa.subfolder.declined'
    req     = 'REQ-008.7, REQ-008.8, REQ-008.9, REQ-008.11, REQ-008.13'
    pass    = $dPass
    desc    = 'An import visa that sits only in a subfolder is logged by path, the prompt is shown, and a non-interactive run declines without an install step even when a consent answer is inherited from the caller'
    details = [ordered]@{ exit = $d.Exit; foundLine = $dFound; promptEchoed = $dPrompt; pathInPrompt = $dPathInPrompt; skippedSubfolderOnly = $dSkipped; noInstallStep = $dNoInstall }
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
    req     = 'REQ-008.16'
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
    req     = 'REQ-008.11'
    pass    = $oPass
    desc    = 'With the timed prompt forced and nobody answering, the subfolder-only NI-VISA install is declined after the timeout'
    details = [ordered]@{ exit = $o.Exit; foundLine = $oFound; timedPromptShown = $oTimedPrompt; skippedSubfolderOnly = $oSkipped; noInstallStep = $oNoInstall }
})

# ---- scan: what the scan skips (REQ-008.5) and what it does not take for an import (REQ-008.6) ---------------------------------------
# Two bootstraps with HP_SKIP_NIVISA=1 and without starting the program, before the accepted run (which may really install the driver).
$scanEnv = @{ HP_SKIP_NIVISA = '1'; HP_SKIP_ENTRY_SMOKE = '1'; HP_SKIP_EXE_SMOKERUN = '1' }
$deepFile = 'archive\2019\bench\old_tool.py'
$skipPaths = @('~scratch.py', '~old\tool.py', '.hidden\tool.py')
$scanFiles = @{
    'main.py'          = $mainPlain
    'requirements.txt' = 'pyvisa'
    $deepFile          = $archived
    '~scratch.py'      = "import pyvisa`r`nprint('skipped file')"
    '~old\tool.py'     = "import pyvisa`r`nprint('skipped folder')"
    '.hidden\tool.py'  = "import visa`r`nprint('skipped dot folder')"
}
$lookFiles = @{
    'main.py'          = $mainPlain
    'requirements.txt' = 'pyvisa'
    'lookalikes.py'    = "import pyvista`r`nimport vision`r`nimport pyviscoelastic`r`nfrom pyvista import Plotter`r`nprint('lookalikes')"
    'plots\view.py'    = "import pyvista as pv`r`nprint('plots')"
}

$sk = Invoke-VisaScenario -Name 'scanskips' -Files $scanFiles -EnvSet $scanEnv
$skMissing = @(foreach ($rel in $scanFiles.Keys) { if (-not (Test-Path -LiteralPath (Join-Path $sk.Work $rel))) { $rel } })
$skProblems = @(Get-ScanSkipsProblems -SetupText $sk.Setup -ConsoleText $sk.Console -WantFile $deepFile -NotFiles $skipPaths -MissingFiles $skMissing)
$scanPass = [bool](@($skProblems).Count -eq 0)
Write-NdjsonRow ([ordered]@{
    id      = 'self.nivisa.scan.skips'
    req     = 'REQ-008.5'
    pass    = $scanPass
    desc    = 'The NI-VISA scan reads a subfolder three levels down and skips a file and a folder whose names start with ~ and a folder whose name starts with a dot'
    details = [ordered]@{ exit = $sk.Exit; foundFiles = @(Get-VisaFoundFiles -SetupText $sk.Setup); problems = @($skProblems) }
})

$lk = Invoke-VisaScenario -Name 'lookalike' -Files $lookFiles -EnvSet $scanEnv
$lkMissing = @(foreach ($rel in $lookFiles.Keys) { if (-not (Test-Path -LiteralPath (Join-Path $lk.Work $rel))) { $rel } })
$scanWorked = [bool](@(Get-VisaFoundFiles -SetupText $sk.Setup) -ccontains ($deepFile + ' (subfolder)'))
$lkProblems = @(Get-ScanLookalikeProblems -SetupText $lk.Setup -ConsoleText $lk.Console -MissingFiles $lkMissing -ScanShownWorking $scanWorked)
$lookPass = [bool](@($lkProblems).Count -eq 0)
Write-NdjsonRow ([ordered]@{
    id      = 'self.nivisa.scan.lookalike'
    req     = 'REQ-008.6'
    pass    = $lookPass
    desc    = 'An import of pyvista, vision or pyviscoelastic is not taken for an import of pyvisa or visa'
    details = [ordered]@{ exit = $lk.Exit; foundFiles = @(Get-VisaFoundFiles -SetupText $lk.Setup); scanShownWorking = $scanWorked; problems = @($lkProblems) }
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
    req     = 'REQ-008.10'
    pass    = $aPass
    desc    = 'Answering yes to the subfolder prompt lets the run into the NI-VISA install branch'
    details = [ordered]@{ exit = $a.Exit; foundLine = $aFound; promptEchoed = $aPrompt; acceptedLogged = $aAcceptedLine; reachedInstallBranch = $aReachedBranch; notDeclined = $aNotDeclined }
})

# ---- pyvisa: the Python package is installed whichever way the question was answered (REQ-008.15) ----------------
# The list is the pip freeze of the run, taken before the NI-VISA step; both folders declare pyvisa in requirements.txt.
$dFreeze = Read-Text (Join-Path $d.Work '~dependency_installed.txt')
$aFreeze = Read-Text (Join-Path $a.Work '~dependency_installed.txt')
$pyProblems = @(Get-PyvisaFreezeProblems -Label 'declined' -AnswerShown ([bool]$dSkipped) -SetupText $d.Setup -FreezeText $dFreeze) + @(Get-PyvisaFreezeProblems -Label 'accepted' -AnswerShown ([bool]($aAcceptedLine -and $aNotDeclined)) -SetupText $a.Setup -FreezeText $aFreeze)
$pyPass = [bool](@($pyProblems).Count -eq 0)
Write-NdjsonRow ([ordered]@{
    id      = 'self.nivisa.pyvisa.installed'
    req     = 'REQ-008.15'
    pass    = $pyPass
    desc    = 'The Python pyvisa package is installed whether the subfolder question was answered yes or no'
    details = [ordered]@{ declinedLine = (Get-PyvisaLine -FreezeText $dFreeze); acceptedLine = (Get-PyvisaLine -FreezeText $aFreeze); problems = @($pyProblems) }
})

if (-not ($scanPass -and $lookPass)) { exit 1 }
if (-not ($dPass -and $aPass -and $tPass -and $oPass -and $pyPass)) { exit 1 }
exit 0
