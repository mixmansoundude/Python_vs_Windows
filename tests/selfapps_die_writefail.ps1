# ASCII only
# selfapps_die_writefail.ps1 - Item 46 Batch 4 (docs/plan-die-fatal-remediation.md): a file the bootstrapper cannot write
# in the middle of a run must not end the run.
#
# Seven sites call `call :die` after an embedded helper (or a copy) could not be written, and every one of them
# continues with the run: ~detect_python.py, ~print_pyver.py, ~condarc (staging), %ENV_PATH%\.condarc (the copy),
# ~prep_requirements.py, ~detect_visa.py and the dependency list copy of :dm_copy_one. :die is the END of a run: it sets
# state=error, writes the status file, RELEASES THE LOCK and waits for a key press (README REQ-016.8) unless the CI
# marker is set. So a real user who double clicked saw "Press any key to continue" in the middle of a run that then went
# on, a second double click could start while the first was still working (the lock was gone), and the run ended with
# state error although the step was optional (a missing REQ-005.8 augmentation, a missing .condarc: every conda command
# names --override-channels -c conda-forge itself). The NI-VISA detector also logged "No pyvisa/visa imports detected."
# although it never ran, and :die gave the other six sites no honest wording either.
#
# The contract these rows hold (README REQ-024, REQ-016.8 and the per-site requirement):
#   - the site says what could not be done in a [WARN] line (an [ERROR] line only for the dependency list: the packages it
#     names may not be installed, so the final state stays error), and the doomed helper call that followed is not made
#   - the lock folder is still in place when the build starts, and no key press is printed before the end of the run
#   - the final state is the one of a clean run (ok), except for the dependency list, which stays error
#
# Two scenarios (SOFTFAIL_SCENARIO, default uv). Each is a set of full default bootstraps: every HP_*, PVW_* and NOINPUT
# variable is cleared by a wrapper (the CI marker included, because :die pauses only without it) and standard input is
# closed, so `pause` and `set /p` get end-of-file and return at once and a run that really waited would hit the time limit.
# One run is a control (no hook): it shows the observation can tell the difference. The others each fail one site.
#   uv (real lane): a program with requirements.txt (toolz) so the dependency rules run
#     self.softfail.control.uv   the control: lock folder in place at the build marker, no key press before it, exactly the
#                                end-of-run key press, state ok, no [ERROR] line
#     self.softfail.prep         ~prep_requirements.py cannot be written (HP_TEST_FORCE_EMIT_FAIL=HP_PREP_REQUIREMENTS)
#     self.softfail.visa         ~detect_visa.py cannot be written; the log must say the check was skipped and not that no
#                                import was found
#     self.softfail.depstage     requirements.txt is read-only next to a pyproject.toml, so the merge cannot replace it
#                                and the fallback copy fails; the run goes on and ends with state error
#   conda (conda-full lane, HP_FORCE_CONDA_ONLY=1): a program with no dependencies, a real conda create per run
#     self.softfail.control.conda   the same control for the conda path
#     self.softfail.pyspec          ~detect_python.py cannot be written
#     self.softfail.pyver           ~print_pyver.py cannot be written
#     self.softfail.condarc.stage   ~condarc cannot be staged (HP_TEST_FORCE_EMIT_FAIL=HP_CONDARC)
#     self.softfail.condarc.write   the copy into the environment fails (HP_TEST_FORCE_CONDARC_WRITE_FAIL=1)
#
# How a run is observed. The script polls ~setup.log every 100 ms and, the moment the line "Building standalone
# executable" is written (after every site above, before a build that takes tens of seconds), looks once at ~bootstrap.lock.
# The run then goes on to its end. The console is read afterwards: "Press any key" before the build line counts as a key
# press in the middle of the run, and the total must equal the control's (the one at the end of the run).
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text).
# derived requirement: the judging functions take plain values and read no script variable, so tests/test_die_writefail.py
# can run them through real pwsh on synthetic runs; a parameter and a local never differ only by case (PowerShell variable
# names are case-insensitive, see docs/agent-lessons-learned.md).
param()
$ErrorActionPreference = 'Continue'

# ----------------------------------------------------------------------------------------------- judging functions
function Get-TextCount {
    param([string]$Haystack, [string]$Needle)
    if ((-not $Haystack) -or (-not $Needle)) { return 0 }
    $found = 0
    $from = 0
    while ($true) {
        $at = $Haystack.IndexOf($Needle, $from, [System.StringComparison]::Ordinal)
        if ($at -lt 0) { break }
        $found++
        $from = $at + $Needle.Length
    }
    return $found
}

# Key presses in a console log: all of them, and those printed before the build marker (null when the marker is missing).
function Get-PauseCounts {
    param([string]$ConsoleText, [string]$MarkerText)
    $pauseText = 'Press any key'
    $totalCount = Get-TextCount $ConsoleText $pauseText
    $beforeCount = $null
    if ($ConsoleText) {
        $markerAt = $ConsoleText.IndexOf($MarkerText, [System.StringComparison]::Ordinal)
        if ($markerAt -ge 0) { $beforeCount = Get-TextCount $ConsoleText.Substring(0, $markerAt) $pauseText }
    }
    return [pscustomobject]@{ Total = $totalCount; Before = $beforeCount }
}

# The [ERROR] lines of a setup log, one string each.
function Get-ErrorLines {
    param([string]$SetupText)
    $lines = @()
    if ($SetupText) {
        foreach ($oneLine in ($SetupText -split "`r?`n")) {
            if ($oneLine.Contains('[ERROR]')) { $lines += $oneLine }
        }
    }
    return ,([string[]]$lines)
}

# Problems of the control run, as a string array (empty: the control is clean).
function Get-ControlProblems {
    param([pscustomobject]$Run, [string]$MarkerText)
    $problemList = New-Object System.Collections.ArrayList
    if (-not $Run.Finished) { [void]$problemList.Add('the run did not finish within the time limit') }
    if (-not $Run.Sampled) {
        [void]$problemList.Add('the build line never appeared, so the lock folder was never looked at')
    } elseif ($Run.LockAtMarker -ne $true) {
        [void]$problemList.Add('the lock folder was missing when the build started')
    }
    $pauseInfo = Get-PauseCounts $Run.Console $MarkerText
    if ($null -eq $pauseInfo.Before) {
        [void]$problemList.Add('the build line is not in the console log')
    } elseif ($pauseInfo.Before -ne 0) {
        [void]$problemList.Add('a key press was printed before the build started')
    }
    if ($pauseInfo.Total -lt 1) { [void]$problemList.Add('no end-of-run key press was printed, so the counter cannot see one') }
    if ($Run.State -ne 'ok') { [void]$problemList.Add('the status file says state ' + [string]$Run.State + ', not ok') }
    $errorLines = Get-ErrorLines $Run.Setup
    if ($errorLines.Count -gt 0) { [void]$problemList.Add('the clean run logged an [ERROR] line') }
    return ,([string[]]$problemList.ToArray())
}

# Problems of a run that fails one site. $Want keys (all optional except State):
#   Hook          text the setup log must hold (the test hook announcing itself)
#   Site          regex the setup log must match (the line that says what could not be done)
#   ErrorAllowed  regex every [ERROR] line must match (default: no [ERROR] line at all)
#   Present       regexes the setup log must match
#   Absent        regexes the setup log must NOT match
#   State         'control' (the control's state) or 'error'
function Get-SoftfailProblems {
    param([pscustomobject]$Run, [pscustomobject]$Ctl, [hashtable]$Want, [string]$MarkerText)
    $problemList = New-Object System.Collections.ArrayList
    $ctlProblems = Get-ControlProblems $Ctl $MarkerText
    if ($ctlProblems.Count -gt 0) { [void]$problemList.Add('the control run was not clean: ' + ($ctlProblems -join '; ')) }
    if (-not $Run.Finished) { [void]$problemList.Add('the run did not finish within the time limit') }
    $setupText = [string]$Run.Setup
    if ($Want.ContainsKey('Hook')) {
        if (-not $setupText.Contains([string]$Want['Hook'])) { [void]$problemList.Add('the test hook line is not in the setup log') }
    }
    if ($Want.ContainsKey('Site')) {
        if ($setupText -notmatch [string]$Want['Site']) { [void]$problemList.Add('the line that names the failed step is not in the setup log') }
    }
    $errorLines = Get-ErrorLines $setupText
    foreach ($errorLine in $errorLines) {
        if ($Want.ContainsKey('ErrorAllowed')) {
            if ($errorLine -notmatch [string]$Want['ErrorAllowed']) { [void]$problemList.Add('an unexpected [ERROR] line: ' + $errorLine.Trim()) }
        } else {
            [void]$problemList.Add('an [ERROR] line where a [WARN] line belongs: ' + $errorLine.Trim())
        }
    }
    if ($Want.ContainsKey('Present')) {
        foreach ($wantedPattern in $Want['Present']) {
            if ($setupText -notmatch $wantedPattern) { [void]$problemList.Add('missing from the setup log: ' + $wantedPattern) }
        }
    }
    if ($Want.ContainsKey('Absent')) {
        foreach ($unwantedPattern in $Want['Absent']) {
            if ($setupText -match $unwantedPattern) { [void]$problemList.Add('found in the setup log: ' + $unwantedPattern) }
        }
    }
    if (-not $Run.Sampled) {
        [void]$problemList.Add('the build line never appeared, so the lock folder was never looked at')
    } elseif ($Run.LockAtMarker -ne $true) {
        [void]$problemList.Add('the lock folder was released in the middle of the run')
    }
    $pauseInfo = Get-PauseCounts $Run.Console $MarkerText
    $ctlPauseInfo = Get-PauseCounts $Ctl.Console $MarkerText
    if ($null -eq $pauseInfo.Before) {
        [void]$problemList.Add('the build line is not in the console log')
    } elseif ($pauseInfo.Before -ne 0) {
        [void]$problemList.Add('a key press was printed before the build started')
    }
    if ($pauseInfo.Total -ne $ctlPauseInfo.Total) {
        [void]$problemList.Add('key presses in the whole run: ' + [string]$pauseInfo.Total + ', the control has ' + [string]$ctlPauseInfo.Total)
    }
    $wantState = [string]$Ctl.State
    if ([string]$Want['State'] -eq 'error') { $wantState = 'error' }
    if ([string]$Run.State -ne $wantState) {
        [void]$problemList.Add('the status file says state ' + [string]$Run.State + ', expected ' + $wantState)
    }
    return ,([string[]]$problemList.ToArray())
}

# ------------------------------------------------------------------------------------------------------------- setup
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

# The lane tag is read once, before the flags are cleared for the child runs.
$laneTag = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
function Write-NdjsonRow {
    param([hashtable]$Row)
    if ($laneTag -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $laneTag }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

$scenario = [Environment]::GetEnvironmentVariable('SOFTFAIL_SCENARIO')
if (-not $scenario) { $scenario = 'uv' }
if (($scenario -ne 'uv') -and ($scenario -ne 'conda')) {
    Write-Host ('SOFTFAIL_SCENARIO must be uv or conda, got: ' + $scenario)
    exit 1
}

# Rows for a run that cannot start (not Windows, run_setup.bat missing). The ids stay literal here too, at the call site.
function Write-PreflightRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    if ($scenario -eq 'uv') {
        Write-NdjsonRow ([ordered]@{ id = 'self.softfail.control.uv'; req = 'REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
        Write-NdjsonRow ([ordered]@{ id = 'self.softfail.prep'; req = 'REQ-005.8, REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
        Write-NdjsonRow ([ordered]@{ id = 'self.softfail.visa'; req = 'REQ-008, REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
        Write-NdjsonRow ([ordered]@{ id = 'self.softfail.depstage'; req = 'REQ-005.1, REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
        return
    }
    Write-NdjsonRow ([ordered]@{ id = 'self.softfail.control.conda'; req = 'REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.softfail.pyspec'; req = 'REQ-004, REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.softfail.pyver'; req = 'REQ-004, REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.softfail.condarc.stage'; req = 'REQ-006, REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.softfail.condarc.write'; req = 'REQ-006, REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-PreflightRows -Pass $true -Desc 'A file the bootstrapper cannot write does not end the run (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path -LiteralPath $batchPath)) {
    Write-PreflightRows -Pass $false -Desc 'A file the bootstrapper cannot write does not end the run: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

$markerText = 'Building standalone executable'
$timeLimitSec = 1200

$evidence = Join-Path $here '~selftest_softfail_evidence'
if (Test-Path -LiteralPath $evidence) { Remove-Item -LiteralPath $evidence -Recurse -Force }
New-Item -ItemType Directory -Force -Path $evidence | Out-Null

# Reads a file another process may be appending to; $null when it cannot be read right now.
function Read-Shared {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs, [System.Text.Encoding]::ASCII)
            return $sr.ReadToEnd()
        } finally { $fs.Dispose() }
    } catch { return $null }
}

function ConvertTo-AsciiLine {
    param([string]$Text, [int]$Max = 400)
    if (-not $Text) { return '' }
    $flat = ($Text -replace '\s+', ' ').Trim()
    $flat = [regex]::Replace($flat, '[^\x20-\x7E]', '?')
    if ($flat.Length -gt $Max) { $flat = $flat.Substring(0, $Max) }
    return $flat
}

$flagNames = @()
foreach ($item in @(Get-ChildItem Env:)) {
    if ((($item.Name -match '^(HP_|PVW_)') -or ($item.Name -ieq 'NOINPUT')) -and ($item.Name -match '^[A-Za-z0-9_]+$')) { $flagNames += $item.Name }
}
$flagNames = @($flagNames | Sort-Object)

# One full default bootstrap in its own folder. $Files maps a file name to its text, $ReadOnly lists files made read-only
# before the run, $EnvSet the variables the run gets (after the wrapper cleared every flag of the job).
function Invoke-SoftfailRun {
    param([string]$Name, [hashtable]$Files, [string[]]$ReadOnly, [hashtable]$EnvSet)
    $dir = Join-Path $here ('~selftest_softfail_' + $Name)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $batchPath -Destination $dir -Force
    foreach ($fileName in $Files.Keys) {
        Set-Content -LiteralPath (Join-Path $dir $fileName) -Value ([string]$Files[$fileName]) -Encoding ASCII
    }
    foreach ($fileName in $ReadOnly) {
        Set-ItemProperty -LiteralPath (Join-Path $dir $fileName) -Name IsReadOnly -Value $true
    }
    # The wrapper clears every flag the job set with `set "NAME="` (the batch environment is exactly what the bootstrapper
    # inherits), then sets this run's own variables. Standard input is closed.
    $lines = @('@echo off')
    foreach ($n in $flagNames) { $lines += ('set "' + $n + '="') }
    foreach ($k in $EnvSet.Keys) {
        if (($k -match '^[A-Za-z0-9_]+$') -and ([string]$EnvSet[$k] -match '^[A-Za-z0-9_.=-]+$')) { $lines += ('set "' + $k + '=' + [string]$EnvSet[$k] + '"') }
    }
    $lines += 'call run_setup.bat > ~console.log 2>&1 < nul'
    $lines += 'exit /b %ERRORLEVEL%'
    Set-Content -LiteralPath (Join-Path $dir '~softfail_launch.cmd') -Value $lines -Encoding ASCII

    $setupPath = Join-Path $dir '~setup.log'
    $lockDir = Join-Path $dir '~bootstrap.lock'
    $started = Get-Date
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', 'call ~softfail_launch.cmd') -WorkingDirectory $dir -NoNewWindow -PassThru
    $sampled = $false
    $lockAtMarker = $null
    $deadline = $started.AddSeconds($timeLimitSec)
    while (((Get-Date) -lt $deadline) -and (-not $proc.HasExited)) {
        if (-not $sampled) {
            $t = Read-Shared $setupPath
            if ($t -and $t.Contains($markerText)) {
                # The line is written after every step this script fails, and the build that follows takes tens of seconds,
                # so this one look is of the state the rest of the run goes on in.
                $lockAtMarker = [bool](Test-Path -LiteralPath $lockDir)
                $sampled = $true
            }
        }
        Start-Sleep -Milliseconds 100
    }
    $finished = $proc.HasExited
    $exitCode = $null
    if ($finished) {
        $proc.WaitForExit()
        $exitCode = $proc.ExitCode
    } else {
        & taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null
        $null = $proc.WaitForExit(30000)
    }
    Start-Sleep -Milliseconds 500
    foreach ($fileName in $ReadOnly) {
        $roPath = Join-Path $dir $fileName
        if (Test-Path -LiteralPath $roPath) { Set-ItemProperty -LiteralPath $roPath -Name IsReadOnly -Value $false -ErrorAction SilentlyContinue }
    }
    foreach ($evName in @('~console.log', '~setup.log', '~bootstrap.status.json')) {
        $src = Join-Path $dir $evName
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $evidence ($Name + '_' + ($evName -replace '^~', ''))) -Force }
    }
    $state = $null
    $statusPath = Join-Path $dir '~bootstrap.status.json'
    if (Test-Path -LiteralPath $statusPath) {
        try { $state = [string]((Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { $state = 'unparseable' }
    }
    return [pscustomobject]@{
        Name = $Name; Console = (Read-Shared (Join-Path $dir '~console.log')); Setup = (Read-Shared $setupPath)
        State = $state; Sampled = $sampled; LockAtMarker = $lockAtMarker; Finished = [bool]$finished
        ExitCode = $exitCode; Seconds = [int]((Get-Date) - $started).TotalSeconds
    }
}

function Get-RowDetails {
    param([pscustomobject]$Run, [pscustomobject]$Ctl, [string[]]$Problems)
    $pc = Get-PauseCounts $Run.Console $markerText
    $cpc = Get-PauseCounts $Ctl.Console $markerText
    $siteLines = @()
    if ($Run.Setup) {
        foreach ($oneLine in ($Run.Setup -split "`r?`n")) {
            if ($oneLine -match '\[WARN\] Could not|\[ERROR\]|\[VISA\] skipped|could not be merged|HP_TEST_FORCE_') { $siteLines += (ConvertTo-AsciiLine $oneLine 220) }
        }
    }
    return [ordered]@{
        problems = @($Problems); finished = $Run.Finished; seconds = $Run.Seconds; exitCode = $Run.ExitCode; statusState = $Run.State
        controlState = $Ctl.State; sampled = $Run.Sampled; lockAtBuild = $Run.LockAtMarker
        pausesBeforeBuild = $pc.Before; pausesTotal = $pc.Total; controlPausesTotal = $cpc.Total
        siteLines = @($siteLines | Select-Object -First 12)
    }
}

# The conda scenario forces conda-only mode (no uv, no fallbacks), the way the conda-full lane does for every script.
function Get-CondaEnv {
    param([hashtable]$Extra)
    $merged = @{ HP_FORCE_CONDA_ONLY = '1' }
    foreach ($k in $Extra.Keys) { $merged[$k] = $Extra[$k] }
    return $merged
}

$allPass = $true
$appText = 'print("softfail app")'

# ------------------------------------------------------------------------------------------------------- uv scenario
if ($scenario -eq 'uv') {
    $baseFiles = @{ 'app.py' = $appText; 'requirements.txt' = "toolz`r`n" }
    $pyproject = "[project]`r`nname = `"softfail-app`"`r`nversion = `"0.1.0`"`r`ndependencies = [`"toolz`"]`r`n"

    $ctl = Invoke-SoftfailRun -Name 'control_uv' -Files $baseFiles -ReadOnly @() -EnvSet @{}
    $ctlProblems = Get-ControlProblems $ctl $markerText
    $ctlRowPass = ($ctlProblems.Count -eq 0)
    Write-NdjsonRow ([ordered]@{
        id = 'self.softfail.control.uv'; req = 'REQ-024'; pass = [bool]$ctlRowPass
        desc = 'control for the soft-fail rows: a clean default run keeps the lock folder until the build, prints no key press before the end and ends with state ok'
        details = (Get-RowDetails $ctl $ctl $ctlProblems)
    })
    if (-not $ctlRowPass) { $allPass = $false }

    $prep = Invoke-SoftfailRun -Name 'prep' -Files $baseFiles -ReadOnly @() -EnvSet @{ HP_TEST_FORCE_EMIT_FAIL = 'HP_PREP_REQUIREMENTS' }
    $prepProblems = Get-SoftfailProblems $prep $ctl @{
        Hook = 'HP_TEST_FORCE_EMIT_FAIL=HP_PREP_REQUIREMENTS: simulating embedded helper write failure'
        Site = '\[WARN\] Could not write ~prep_requirements\.py'
        Absent = @("can't open file[^\r\n]*~prep_requirements")
        State = 'control'
    } $markerText
    Write-NdjsonRow ([ordered]@{
        id = 'self.softfail.prep'; req = 'REQ-005.8, REQ-024'; pass = [bool]($prepProblems.Count -eq 0)
        desc = 'a ~prep_requirements.py that cannot be written is a warning: the dependency rules are skipped, the lock is kept, no key press, state as a clean run'
        details = (Get-RowDetails $prep $ctl $prepProblems)
    })
    if ($prepProblems.Count -gt 0) { $allPass = $false }

    $visa = Invoke-SoftfailRun -Name 'visa' -Files $baseFiles -ReadOnly @() -EnvSet @{ HP_TEST_FORCE_EMIT_FAIL = 'HP_DETECT_VISA' }
    $visaProblems = Get-SoftfailProblems $visa $ctl @{
        Hook = 'HP_TEST_FORCE_EMIT_FAIL=HP_DETECT_VISA: simulating embedded helper write failure'
        Site = '\[WARN\] Could not write ~detect_visa\.py'
        Present = @('\[VISA\] skipped \(detector_unavailable\)')
        Absent = @('No pyvisa/visa imports detected', "can't open file[^\r\n]*~detect_visa")
        State = 'control'
    } $markerText
    Write-NdjsonRow ([ordered]@{
        id = 'self.softfail.visa'; req = 'REQ-008, REQ-024'; pass = [bool]($visaProblems.Count -eq 0)
        desc = 'a ~detect_visa.py that cannot be written is a warning and the log says the NI-VISA check was skipped, never that no import was found'
        details = (Get-RowDetails $visa $ctl $visaProblems)
    })
    if ($visaProblems.Count -gt 0) { $allPass = $false }

    $depFiles = @{ 'app.py' = $appText; 'requirements.txt' = "toolz`r`n"; 'pyproject.toml' = $pyproject }
    $dep = Invoke-SoftfailRun -Name 'depstage' -Files $depFiles -ReadOnly @('requirements.txt') -EnvSet @{}
    $depProblems = Get-SoftfailProblems $dep $ctl @{
        Site = '\[ERROR\] Could not (stage|copy) the dependency list'
        ErrorAllowed = 'Could not (stage|copy) the dependency list'
        Present = @('The dependency lists could not be merged')
        State = 'error'
    } $markerText
    Write-NdjsonRow ([ordered]@{
        id = 'self.softfail.depstage'; req = 'REQ-005.1, REQ-024'; pass = [bool]($depProblems.Count -eq 0)
        desc = 'a dependency list that cannot be copied into requirements.txt is reported and the run goes on: lock kept, no key press, the final state stays error'
        details = (Get-RowDetails $dep $ctl $depProblems)
    })
    if ($depProblems.Count -gt 0) { $allPass = $false }

    Write-Host '=== softfail evidence (uv): lines that name a failed step, per run ==='
    foreach ($r in @($ctl, $prep, $visa, $dep)) {
        Write-Host ('--- ' + $r.Name + ': state=' + $r.State + ' lockAtBuild=' + $r.LockAtMarker + ' finished=' + $r.Finished + ' seconds=' + $r.Seconds)
        foreach ($oneLine in ((Get-RowDetails $r $ctl @()).siteLines)) { Write-Host $oneLine }
    }
}

# ---------------------------------------------------------------------------------------------------- conda scenario
if ($scenario -eq 'conda') {
    $condaFiles = @{ 'app.py' = $appText }

    $ctl = Invoke-SoftfailRun -Name 'control_conda' -Files $condaFiles -ReadOnly @() -EnvSet (Get-CondaEnv @{})
    $ctlProblems = Get-ControlProblems $ctl $markerText
    $ctlRowPass = ($ctlProblems.Count -eq 0)
    Write-NdjsonRow ([ordered]@{
        id = 'self.softfail.control.conda'; req = 'REQ-024'; pass = [bool]$ctlRowPass
        desc = 'control for the soft-fail rows on the conda path: a clean default run keeps the lock folder until the build, prints no key press before the end and ends with state ok'
        details = (Get-RowDetails $ctl $ctl $ctlProblems)
    })
    if (-not $ctlRowPass) { $allPass = $false }

    $pyspec = Invoke-SoftfailRun -Name 'pyspec' -Files $condaFiles -ReadOnly @() -EnvSet (Get-CondaEnv @{ HP_TEST_FORCE_EMIT_FAIL = 'HP_DETECT_PY' })
    $pyspecProblems = Get-SoftfailProblems $pyspec $ctl @{
        Hook = 'HP_TEST_FORCE_EMIT_FAIL=HP_DETECT_PY: simulating embedded helper write failure'
        Site = '\[WARN\] Could not write ~detect_python\.py'
        Absent = @("can't open file[^\r\n]*~detect_python")
        State = 'control'
    } $markerText
    Write-NdjsonRow ([ordered]@{
        id = 'self.softfail.pyspec'; req = 'REQ-004, REQ-024'; pass = [bool]($pyspecProblems.Count -eq 0)
        desc = 'a ~detect_python.py that cannot be written is a warning: no Python version request is applied, the lock is kept, no key press, state as a clean run'
        details = (Get-RowDetails $pyspec $ctl $pyspecProblems)
    })
    if ($pyspecProblems.Count -gt 0) { $allPass = $false }

    $pyver = Invoke-SoftfailRun -Name 'pyver' -Files $condaFiles -ReadOnly @() -EnvSet (Get-CondaEnv @{ HP_TEST_FORCE_EMIT_FAIL = 'HP_PRINT_PYVER' })
    $pyverProblems = Get-SoftfailProblems $pyver $ctl @{
        Hook = 'HP_TEST_FORCE_EMIT_FAIL=HP_PRINT_PYVER: simulating embedded helper write failure'
        Site = '\[WARN\] Could not write ~print_pyver\.py'
        Absent = @("can't open file[^\r\n]*~print_pyver")
        State = 'control'
    } $markerText
    Write-NdjsonRow ([ordered]@{
        id = 'self.softfail.pyver'; req = 'REQ-004, REQ-024'; pass = [bool]($pyverProblems.Count -eq 0)
        desc = 'a ~print_pyver.py that cannot be written is a warning: runtime.txt is not written, the lock is kept, no key press, state as a clean run'
        details = (Get-RowDetails $pyver $ctl $pyverProblems)
    })
    if ($pyverProblems.Count -gt 0) { $allPass = $false }

    $stage = Invoke-SoftfailRun -Name 'condarc_stage' -Files $condaFiles -ReadOnly @() -EnvSet (Get-CondaEnv @{ HP_TEST_FORCE_EMIT_FAIL = 'HP_CONDARC' })
    $stageProblems = Get-SoftfailProblems $stage $ctl @{
        Hook = 'HP_TEST_FORCE_EMIT_FAIL=HP_CONDARC: simulating embedded helper write failure'
        Site = '\[WARN\] Could not stage ~condarc'
        Present = @('\[BOOT\] REQ-009: Selected Python provider: Conda \(Portable\)\.')
        Absent = @('Could not write [^\r\n]*\.condarc')
        State = 'control'
    } $markerText
    Write-NdjsonRow ([ordered]@{
        id = 'self.softfail.condarc.stage'; req = 'REQ-006, REQ-024'; pass = [bool]($stageProblems.Count -eq 0)
        desc = 'a ~condarc that cannot be staged is a warning: the doomed copy is not tried, the provider line is still written, the lock is kept, no key press, state as a clean run'
        details = (Get-RowDetails $stage $ctl $stageProblems)
    })
    if ($stageProblems.Count -gt 0) { $allPass = $false }

    $write = Invoke-SoftfailRun -Name 'condarc_write' -Files $condaFiles -ReadOnly @() -EnvSet (Get-CondaEnv @{ HP_TEST_FORCE_CONDARC_WRITE_FAIL = '1' })
    $writeProblems = Get-SoftfailProblems $write $ctl @{
        Hook = 'HP_TEST_FORCE_CONDARC_WRITE_FAIL: the .condarc copy gets a destination that cannot be written.'
        Site = '\[WARN\] Could not write [^\r\n]*\.condarc'
        Present = @('\[BOOT\] REQ-009: Selected Python provider: Conda \(Portable\)\.')
        State = 'control'
    } $markerText
    Write-NdjsonRow ([ordered]@{
        id = 'self.softfail.condarc.write'; req = 'REQ-006, REQ-024'; pass = [bool]($writeProblems.Count -eq 0)
        desc = 'a .condarc that cannot be copied into the environment is a warning: the provider line is still written, the lock is kept, no key press, state as a clean run'
        details = (Get-RowDetails $write $ctl $writeProblems)
    })
    if ($writeProblems.Count -gt 0) { $allPass = $false }

    Write-Host '=== softfail evidence (conda): lines that name a failed step, per run ==='
    foreach ($r in @($ctl, $pyspec, $pyver, $stage, $write)) {
        Write-Host ('--- ' + $r.Name + ': state=' + $r.State + ' lockAtBuild=' + $r.LockAtMarker + ' finished=' + $r.Finished + ' seconds=' + $r.Seconds)
        foreach ($oneLine in ((Get-RowDetails $r $ctl @()).siteLines)) { Write-Host $oneLine }
    }
}

if (-not $allPass) { exit 1 }
exit 0
