# ASCII only
# selfapps_caveat_briefing.ps1 - README REQ-016.6 and REQ-016.7: the post-flight briefing of a run whose EXE could not be verified.
#
# The briefing of a run whose EXE was verified is read by self.postflight.runline.verbatim (REQ-016.5). The caveat variant, the one
# a person reads when something went wrong, was reached only by rows about other things (the GUI hint, the --hidden-import repair)
# that keep the number-level tag and never searched it for the command or for the sentences REQ-016.7 names (docs/plan-test-suite-
# gaps.md). One default bootstrap of a program that prints a line and exits with 3: the EXE is built, its verification run fails
# and the briefing says so.
#
#   self.caveat.runline    REQ-016.6  the caveat briefing shows the command that runs the program with the prepared interpreter
#                                     (two quoted paths, the first one an interpreter that exists), and that command, written to a
#                                     .cmd file exactly as printed and run from the program folder, runs the program: its line
#                                     appears and its exit code is 3
#   self.caveat.sentences  REQ-016.7  the caveat says that the environment was set up and that the packaging step completed without
#                                     a fatal error, no sentence of it claims that the dependencies or their installation were
#                                     verified, and the setup log carries the WARN line of the log contract, not the success line
#
# A row passes only on its named sub-checks, and each one also needs the precondition that makes it mean something (the caveat
# variant of the briefing was printed, not the success variant), so a run that never reached the briefing cannot pass. The judging
# lives in functions that take plain values and return a list of problems: tests/test_caveat_briefing.py runs each of them through
# real pwsh on synthetic runs that must be red for every comparison.
#
# derived requirement: ids and req tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell).
#
# Lane: contract-uv only (the lane with the most wall-clock headroom), gating from its first run (AGENTS.md "New tests gate
# immediately"). One bootstrap with the build; no package is installed (the program uses the standard library only).
# Emits: self.caveat.runline, self.caveat.sentences
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
    Write-NdjsonRow ([ordered]@{ id = 'self.caveat.runline'; req = 'REQ-016.6'; pass = $true; desc = 'Caveat briefing shows the run command (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.caveat.sentences'; req = 'REQ-016.7'; pass = $true; desc = 'Caveat briefing sentences (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.caveat.runline'; req = 'REQ-016.6'; pass = $false; desc = 'Caveat briefing shows the run command: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.caveat.sentences'; req = 'REQ-016.7'; pass = $false; desc = 'Caveat briefing sentences: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

# --- pure helpers (no file system, no process): the unit test runs them through real pwsh ---

# The caveat panel of a console text. Found is false when the heading is missing; Ready is true when the success wording of the
# other variant is on the console; Lines is the panel from its heading to the closing rule under SAFE TO DELETE; Caveat is the text
# between the heading and RUNNING YOUR APP, flattened to one line; Printed is the first line under "directly via the interpreter at
# any time:" that starts with a double quote (the command of REQ-016.5), or an empty string.
function Get-CaveatPanel {
    param([string]$Console)
    $all = @($Console -split "`r?`n")
    $ready = [regex]::IsMatch($Console, 'Your standalone application is ready:')
    $start = -1
    for ($i = 0; $i -lt $all.Count; $i++) {
        if ($all[$i] -match 'SETUP COMPLETE -- WITH A CAVEAT') { $start = $i; break }
    }
    if ($start -lt 0) {
        return [pscustomobject][ordered]@{ Found = $false; Ready = $ready; Lines = @(); Caveat = ''; Printed = '' }
    }
    $end = $all.Count - 1
    $safe = -1
    for ($i = $start; $i -lt $all.Count; $i++) {
        if ($all[$i] -match 'SAFE TO DELETE') { $safe = $i; break }
    }
    if ($safe -ge 0) {
        for ($i = $safe; $i -lt $all.Count; $i++) {
            if ($all[$i] -match '^=+\s*$') { $end = $i; break }
        }
    }
    $panel = New-Object System.Collections.ArrayList
    for ($i = $start; $i -le $end; $i++) { [void]$panel.Add([string]$all[$i]) }
    $caveatParts = New-Object System.Collections.ArrayList
    $printed = ''
    $afterDirect = $false
    $inCaveat = $true
    for ($i = 1; $i -lt $panel.Count; $i++) {
        $line = [string]$panel[$i]
        if ($line -match 'RUNNING YOUR APP') { $inCaveat = $false }
        if ($inCaveat -and ($line -notmatch '^=+\s*$')) { [void]$caveatParts.Add($line.Trim()) }
        if ($afterDirect -and (-not $printed) -and $line.TrimStart().StartsWith('"')) { $printed = $line.Trim() }
        if ($line -match 'directly via the interpreter at any time:') { $afterDirect = $true }
    }
    $flat = ((@($caveatParts.ToArray()) -join ' ') -replace '\s+', ' ').Trim()
    return [pscustomobject][ordered]@{ Found = $true; Ready = $ready; Lines = $panel.ToArray(); Caveat = $flat; Printed = $printed }
}

# What is wrong with the claim of REQ-016.6: nothing when the caveat briefing shows the command and the command runs the program.
# $Run holds Finished, Exit, State; $Replay holds Finished, Exit, Output of the printed command run as printed; $ExeExists says
# whether the interpreter path of the printed command exists on disk; $Marker is the line the program prints, $WantExit its exit code.
function Get-CaveatRunlineProblems {
    param($Run, $Panel, $ExeExists, $Replay, [string]$Marker, [int]$WantExit)
    $out = New-Object System.Collections.ArrayList
    if (-not $Run.Finished) { return @('the bootstrap did not finish within the time limit') }
    if (-not $Panel.Found) { return @('no caveat briefing was printed (the heading SETUP COMPLETE -- WITH A CAVEAT is not on the console), so the run never reached the state under test') }
    if ($Panel.Ready) { [void]$out.Add('the console also carries the success wording of the briefing (Your standalone application is ready:), so the variant under test is not the only one printed') }
    if (-not $Panel.Printed) {
        [void]$out.Add('the caveat briefing does not show the command that runs the program with the prepared interpreter (no line starting with a double quote under "directly via the interpreter at any time:")')
        return $out.ToArray()
    }
    if (-not ($Panel.Printed -match '^"([^"]+)"\s+"([^"]+)"$')) {
        [void]$out.Add('the printed command is not an interpreter path and a script path, each in double quotes: ' + $Panel.Printed)
        return $out.ToArray()
    }
    if (-not $ExeExists) { [void]$out.Add('the interpreter named by the printed command does not exist on disk') }
    if (-not $Replay.Finished) {
        [void]$out.Add('the printed command, run as printed, did not finish within the time limit')
    } else {
        if ($Replay.Exit -ne $WantExit) { [void]$out.Add(('the printed command, run as printed, ended with exit code {0}; the program exits with {1}' -f $Replay.Exit, $WantExit)) }
        if (-not ([string]$Replay.Output).Contains($Marker)) { [void]$out.Add('the printed command, run as printed, did not print the program''s own line (' + $Marker + ')') }
    }
    return $out.ToArray()
}

# What is wrong with the claim of REQ-016.7. $Setup is the setup log text of the run.
function Get-CaveatSentenceProblems {
    param($Panel, [string]$Setup)
    $out = New-Object System.Collections.ArrayList
    if (-not $Panel.Found) { return @('no caveat briefing was printed (the heading SETUP COMPLETE -- WITH A CAVEAT is not on the console), so the run never reached the state under test') }
    if (-not [regex]::IsMatch($Panel.Caveat, 'Your Python environment was set up and the packaging step completed without a fatal error\.')) {
        [void]$out.Add('the caveat does not say that the environment was set up and that the packaging step completed without a fatal error')
    }
    foreach ($s in @([regex]::Split([string]$Panel.Caveat, '(?<=[.!?])\s+'))) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $claims = ($s -match '(?i)dependenc|install') -and ($s -match '(?i)verif|confirm|validat|checked')
        $negated = $s -match "(?i)couldn't|could not|cannot|can't|\bnot\b|\bnever\b|\bno\b"
        if ($claims -and (-not $negated)) { [void]$out.Add('a sentence of the caveat claims that the dependencies or their installation were verified: ' + $s.Trim()) }
    }
    if (-not [regex]::IsMatch($Setup, '\[WARN\] REQ-016: Post-flight briefing printed; EXE unverified, advised direct run\.')) {
        [void]$out.Add('the setup log does not carry the WARN line of the log contract (Post-flight briefing printed; EXE unverified, advised direct run.)')
    }
    if ([regex]::IsMatch($Setup, '\[INFO\] REQ-016: Post-flight briefing printed\.')) {
        [void]$out.Add('the setup log carries the success line of the log contract in a run whose EXE could not be verified')
    }
    return $out.ToArray()
}

# A short, printable excerpt of a text for the details of a row: the last lines, ASCII only, so a red row shows what the run said.
function Get-Excerpt {
    param([string]$Text, [int]$Lines = 40)
    $all = @(([string]$Text) -split "`r?`n")
    $tail = @($all | Select-Object -Last $Lines)
    return @($tail | ForEach-Object { (([string]$_) -replace '[^\x20-\x7E]', '?') })
}

# --- the file system and the bootstrapper ---

$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'CAVEAT_APP_RAN'
$wantExit = 3
$program = "import sys`nprint('$marker', flush=True)`nsys.exit($wantExit)`n"
# A hang must be a red row; a bootstrap of a tiny program with the build needs a few minutes at most.
$runTimeoutMs = 15 * 60 * 1000

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
        if ($null -ne $t) { return [string]$t }
    }
    return ''
}

function Get-StatusState {
    param([string]$Dir)
    $p = Join-Path $Dir '~bootstrap.status.json'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { return [string]((Get-Content -LiteralPath $p -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { return '' }
}

# One bootstrap of the folder; never throws. The variables the run needs are set in the launched shell and cleared again after it:
# every one that could start, skip or answer for the program is named, so the runner's own settings cannot decide the result.
function Invoke-Run {
    param([string]$Dir)
    $res = [ordered]@{ Finished = $false; Exit = -1; State = ''; Console = ''; Setup = ''; Error = '' }
    try {
        $logName = '~cv_console.log'
        $wrapper = Join-Path $Dir '~cv_launch.cmd'
        $vars = [ordered]@{
            HP_SKIP_PIPREQS = '1'; HP_SKIP_AUTOPEP_DISCOVERY = '1'; HP_SKIP_NIVISA = '1'
            HP_SKIP_ENTRY_SMOKE = ''; HP_SKIP_EXE_SMOKERUN = ''; HP_TEST_FORCE_EMIT_FAIL = ''; HP_TEST_REPAIR_ANSWER = ''
            HP_TEST_LASTCHANCE_ANSWER = ''; HP_TEST_CHECKPOINT_ANSWER = ''; HP_TEST_RTM_ANSWER = ''; HP_PVW_KNOWN_IDEMPOTENT = ''
            PVW_BUILDER = ''; PVW_PROVIDER = ''
        }
        if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('@echo off')
        foreach ($k in @($vars.Keys)) {
            if ($k -notmatch '^[A-Za-z0-9_]+$' -or ([string]$vars[$k]) -notmatch '^[A-Za-z0-9_.=-]*$') { throw "unsafe variable $k" }
            [void]$lines.Add(('set "{0}={1}"' -f $k, $vars[$k]))
        }
        [void]$lines.Add("call run_setup.bat app.py > $logName 2>&1 < nul")
        [void]$lines.Add('exit /b %ERRORLEVEL%')
        Set-Content -LiteralPath $wrapper -Value $lines.ToArray() -Encoding ASCII
        $saved = @{}
        foreach ($k in @($vars.Keys)) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            if ([string]$vars[$k] -eq '') { Remove-Item -LiteralPath ('Env:' + $k) -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, [string]$vars[$k]) }
        }
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'call ~cv_launch.cmd') -WorkingDirectory $Dir -NoNewWindow -PassThru
            $null = $p.Handle   # keeps ExitCode readable after WaitForExit(ms)
            if ($p.WaitForExit($runTimeoutMs)) {
                $res.Finished = $true
                $res.Exit = $p.ExitCode
            } else {
                & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
                $null = $p.WaitForExit(30000)
            }
        } finally {
            foreach ($k in @($saved.Keys)) {
                if ($null -eq $saved[$k]) { Remove-Item -LiteralPath ('Env:' + $k) -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, [string]$saved[$k]) }
            }
        }
        $res.Console = Read-Text (Join-Path $Dir $logName)
        $res.Setup = Read-Text (Join-Path $Dir '~setup.log')
        $res.State = Get-StatusState $Dir
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

# The printed command, written to a .cmd file exactly as printed and run from the program folder (a .cmd file is parsed the way
# a pasted Command Prompt line is). The file's last line prints the errorlevel the command left (PVW_RC=n), which is the exit code
# of the program itself: reading it from the output does not depend on how the exit code of `cmd /c` is carried. Never throws.
function Invoke-Replay {
    param([string]$Dir, [string]$Line)
    $res = [ordered]@{ Finished = $false; Exit = -1; Output = '' }
    try {
        $cmdPath = Join-Path $Dir '~cv_runline.cmd'
        $outPath = Join-Path $Dir '~cv_runline.out.txt'
        $errPath = Join-Path $Dir '~cv_runline.err.txt'
        Set-Content -LiteralPath $cmdPath -Value @('@echo off', $Line, 'echo PVW_RC=%errorlevel%') -Encoding ASCII
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'call ~cv_runline.cmd') -WorkingDirectory $Dir -NoNewWindow -PassThru -RedirectStandardOutput $outPath -RedirectStandardError $errPath
        $null = $p.Handle
        if ($p.WaitForExit(120000)) {
            $res.Finished = $true
        } else {
            & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
            $null = $p.WaitForExit(30000)
        }
        $res.Output = (Read-Text $outPath) + (Read-Text $errPath)
        $m = [regex]::Match([string]$res.Output, '(?m)^PVW_RC=(-?\d+)\s*$')
        if ($res.Finished -and $m.Success) { $res.Exit = [int]$m.Groups[1].Value }
    } catch {
        $res.Output = 'replay error: ' + [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

$dir = Join-Path $here '~selftest_caveat'
if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -LiteralPath $batchPath -Destination $dir -Force
[System.IO.File]::WriteAllText((Join-Path $dir 'app.py'), $program, $utf8)

$run = Invoke-Run -Dir $dir
$panel = Get-CaveatPanel $run.Console
Write-Host '=== caveat briefing: the bootstrap ==='
Write-Host ("finished={0} exit={1} state={2} caveatFound={3} printed=[{4}]" -f $run.Finished, $run.Exit, $run.State, $panel.Found, $panel.Printed)
foreach ($l in @(Get-Excerpt $run.Console 30)) { Write-Host ('console: ' + $l) }
if ($run.Error) { Write-Host ('error: ' + $run.Error) }

$exePath = ''
$replay = [pscustomobject]@{ Finished = $false; Exit = -1; Output = '' }
$exeExists = $false
if ($panel.Found -and $panel.Printed -and ($panel.Printed -match '^"([^"]+)"\s+"([^"]+)"$')) {
    $exePath = $Matches[1]
    $exeExists = Test-Path -LiteralPath $exePath
    $replay = Invoke-Replay -Dir $dir -Line $panel.Printed
    Write-Host ("replay: finished={0} exit={1} output=[{2}]" -f $replay.Finished, $replay.Exit, ((@(Get-Excerpt $replay.Output 5)) -join ' | '))
}

$runlineProblems = @(Get-CaveatRunlineProblems -Run $run -Panel $panel -ExeExists $exeExists -Replay $replay -Marker $marker -WantExit $wantExit)
$sentenceProblems = @(Get-CaveatSentenceProblems -Panel $panel -Setup $run.Setup)
$anyRed = $false

$runlinePass = ($runlineProblems.Count -eq 0)
if (-not $runlinePass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id      = 'self.caveat.runline'
    req     = 'REQ-016.6'
    pass    = $runlinePass
    desc    = 'A run whose EXE could not be verified still shows the command that runs the program with the prepared interpreter, and the command runs the program'
    details = [ordered]@{
        problems = @($runlineProblems); finished = [bool]$run.Finished; exitCode = $run.Exit; state = $run.State
        caveatFound = [bool]$panel.Found; printed = [string]$panel.Printed; interpreterExists = [bool]$exeExists
        replayFinished = [bool]$replay.Finished; replayExit = $replay.Exit; replayOutput = @(Get-Excerpt $replay.Output 5)
        excerpt = $(if ($runlinePass) { @() } else { @(Get-Excerpt $run.Console 40) })
    }
})

$sentencePass = ($sentenceProblems.Count -eq 0)
if (-not $sentencePass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id      = 'self.caveat.sentences'
    req     = 'REQ-016.7'
    pass    = $sentencePass
    desc    = 'The caveat briefing says the environment was set up and packaging finished without a fatal error, and never claims the dependency installation was verified'
    details = [ordered]@{
        problems = @($sentenceProblems); finished = [bool]$run.Finished; caveatFound = [bool]$panel.Found; caveat = [string]$panel.Caveat
        excerpt = $(if ($sentencePass) { @() } else { @(Get-Excerpt $run.Setup 40) })
    }
})

if ($anyRed) { exit 1 }
exit 0
