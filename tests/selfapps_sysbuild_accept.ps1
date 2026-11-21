# ASCII only
# selfapps_sysbuild_accept.ps1 - Item 123 (README REQ-007.17 and REQ-007.20): the answer Y to the system-Python build question builds
# the EXE the way every other provider does, and every message of that run about the build, the check run or the failure of the
# executable says EXE or names the tool, so a reader can tell that the message is about the optional one-file program and not about
# the environment, which is already installed.
#
# Why rows of their own. The rows of selfapps_sysbuild.ps1 answer N (self.sysbuild.decline, .nuitka_prompt) or let the CI marker decline
# (.ci_marker), so the README said that no scenario answers yes to the system-Python build question (REQ-007.17) and that no check reads
# every message of REQ-007.20. Nothing ran PyInstaller under the system tier, so the accepted path (the consent, the build, the check
# run of the EXE, the post-flight panel) was only ever run under the other providers.
#
# One real bootstrap, two rows.
#   The run. A private virtual environment, made from the runner's python in a folder of its own, plays the system Python: its Scripts
#   folder is put first on PATH, so `where python` in the bootstrapper finds it, and PyInstaller is installed into it and not into the
#   runner's global interpreter (a real system Python differs only in the path; the bootstrapper takes sys.executable of whatever
#   python it finds first). The program is one stdlib-only file in a folder named ~selftest_sysbuild_accept, so the EXE is
#   _selftest_sysbuild_accept.exe (the folder name goes through the same -replace as in the batch file, Item 111). The run starts
#   with every HP_, PVW_ and NOINPUT variable of the runner cleared and then sets only: HP_OFFLINE_MODE (no uv, no Miniconda download,
#   no embedded Python download), HP_TEST_FORCE_CONDA_FAIL and HP_TEST_FORCE_VENV_FAIL (the other tiers fail by decree),
#   HP_TEST_SYSCON_ANSWER=Y (the REQ-014 question), HP_TEST_SYSBUILD_ANSWER=Y (the REQ-007.16 question this row is about) and
#   HP_CI_LANE (the elective offers after the build decline without waiting). Standard input is closed. A watchdog ends a run that
#   hangs (taskkill of the whole process tree), so a regression is a red row and not a held job.
#   The run has a PUBLIC of its own. The bootstrapper puts %PUBLIC%\Documents\Miniconda3 (and its condabin, Scripts and Library\bin
#   folders) first on PATH whether or not that folder exists, and the system tier takes the first python that `where python` finds, so
#   a Miniconda that an earlier scenario of the job left in the runner's shared Public folder would be taken for the system Python (run
#   44708489835: the interpreter line named C:\Users\Public\Documents\Miniconda3\python.exe and the row was red for that alone). The
#   launch file therefore sets PUBLIC to an empty folder next to the program folder (~selftest_sysbuild_accept_public, made fresh before
#   the run), records the value the bootstrapper saw (~accept_public.txt) and self.sysbuild.accept requires it to be that folder
#   (Get-IsolationProblems), the way tests/selfapps_embed_version.ps1 does it since Item 120.
#   self.sysbuild.accept (REQ-007.17). The console of the run must show, in this order: the system tier was tried, the REQ-014
#   consent was accepted, the interpreter the run used is the private one, the provider line says System Python, the REQ-007 build
#   consent was accepted, the build started, PyInstaller produced dist\<exe>, the check run went through the packaged EXE, exited 0
#   and reported success; and none of the lines of the declined path (declined, not consented, the interpreter check in place of the
#   EXE check). Then: the EXE exists, the post-flight panel names it on the line under "Your standalone application is ready:", the
#   program's own line is in ~run.out.txt, the status file says degraded_env with exit code 0, the run ended with exit code 0, and
#   the EXE started on its own (outside the bootstrapper) exits 0 and prints the line.
#   self.sysbuild.wording (REQ-007.20). The same console, line by line, through tools/exe_wording.py `console`: every timestamped
#   line that talks about building, bundling, packaging or verifying names the artifact or the tool (EXE, executable, standalone,
#   PyInstaller, Nuitka) or matches an entry of tests/exe_wording_exempt.txt. The row also requires that the judge ran and read
#   enough of the run (lines, lines about the build, lines that name the EXE, at least one exempt line), so it cannot pass on a
#   console that never reached the build. tests/test_exe_wording.py holds every message of run_setup.bat to the same rule without
#   running anything; this row is the part that sees what is built at run time.
#
# Limits, stated so that nobody reads more into the rows than they show: the interpreter is a venv of the runner's python, not the
# python.org installer's layout; the messages of a failing build (the Nuitka fallback, the repair loops) are held to the rule by the
# static test and by the rows that reach them (selfapps_pyinstaller_fail.ps1, selfapps_hidden_import.ps1), not by this run.
#
# derived requirement: ids and tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell), and the judging functions take plain values and return a list of problems
# (tests/test_sysbuild_accept.py runs them through a real pwsh in strict mode on synthetic runs).
#
# Lane: contract-uv. Gating from its first run (AGENTS.md "New tests gate immediately"): a red row holds the aggregate check.
# One bootstrap with a real PyInstaller build (a few minutes) and two short helper runs.
# Emits: self.sysbuild.accept, self.sysbuild.wording
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

# Used when the two rows share one outcome (a skip, or an input that is missing); the real emissions below are literal too.
function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    Write-NdjsonRow ([ordered]@{ id = 'self.sysbuild.accept'; req = 'REQ-007.17'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.sysbuild.wording'; req = 'REQ-007.20'; pass = $Pass; desc = $Desc; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'system-Python EXE build accepted (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'system-Python EXE build accepted: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------------------------------------------------
$evidencePath = Join-Path $here '~sysbuild_accept_evidence.txt'
Set-Content -LiteralPath $evidencePath -Value 'selfapps_sysbuild_accept.ps1 evidence (printable ASCII only)' -Encoding Ascii

function Read-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
    if ($null -eq $t) { return '' }
    return [string]$t
}

function Write-CrLf {
    param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
}

# Appends a titled block to the evidence file the workflow uploads; non-ASCII becomes '?', long texts are cut.
function Add-Evidence {
    param([string]$Title, [string]$Text, [int]$MaxLines = 120)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        $clean = ($l -replace '[^\x20-\x7E]', '?')
        if ($clean.Length -gt 220) { $clean = $clean.Substring(0, 220) }
        [void]$keep.Add($clean)
        if ($keep.Count -ge $MaxLines) { break }
    }
    Add-Content -LiteralPath $evidencePath -Value @('', ('=== ' + $Title + ' ==='), $keep.ToArray()) -Encoding Ascii
}

# Runs one cmd launch file in a working folder with a hard limit; a hang is a red row, not a held job.
function Invoke-Launch {
    param([string]$Dir, [string]$LaunchName, [int]$LimitMs)
    $res = [ordered]@{ Finished = $false; ExitCode = -1; Seconds = 0; Error = '' }
    try {
        $started = Get-Date
        $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', ('call ' + $LaunchName)) -WorkingDirectory $Dir -NoNewWindow -PassThru
        $null = $p.Handle   # keeps ExitCode readable after WaitForExit(ms)
        if ($p.WaitForExit($LimitMs)) {
            $res.Finished = $true
            $res.ExitCode = $p.ExitCode
        } else {
            & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
            $null = $p.WaitForExit(30000)
        }
        $res.Seconds = [int]((Get-Date) - $started).TotalSeconds
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return $res
}

# Starts one program on its own (not through the bootstrapper) with its output in a file and a hard limit.
function Invoke-DirectRun {
    param([string]$ExePath, [string]$Dir, [string]$OutPath, [int]$LimitMs)
    $res = [ordered]@{ Finished = $false; ExitCode = -1; Error = '' }
    try {
        $p = Start-Process -FilePath $ExePath -WorkingDirectory $Dir -NoNewWindow -PassThru -RedirectStandardOutput $OutPath -RedirectStandardError ($OutPath + '.err')
        $null = $p.Handle
        if ($p.WaitForExit($LimitMs)) {
            $res.Finished = $true
            $res.ExitCode = $p.ExitCode
        } else {
            & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
            $null = $p.WaitForExit(30000)
        }
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return $res
}

# set "NAME=" for every HP_, PVW_ and NOINPUT variable of this process: a setting of the runner could otherwise decide for the
# bootstrapper. The names are validated, because they end up in a batch file.
function Get-ClearLines {
    $names = @(Get-ChildItem Env: | ForEach-Object { $_.Name } | Where-Object { ($_ -match '^(HP_|PVW_)' -or $_ -eq 'NOINPUT') -and $_ -match '^[A-Za-z0-9_]+$' })
    return @($names | ForEach-Object { 'set "' + $_ + '="' })
}

# ---------------------------------------------------------------------------------------------------------------------
# judging: plain values in, a list of problems out (nothing when the run shows what the row must show)
# ---------------------------------------------------------------------------------------------------------------------
# The index of the first line of Lines, from index From on, that contains Fragment (case blind, literal), or -1.
function Find-ConsoleLine {
    param([string[]]$Lines, [string]$Fragment, [int]$From)
    for ($i = $From; $i -lt $Lines.Length; $i++) {
        if ($Lines[$i].IndexOf($Fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { return $i }
    }
    return -1
}

# How many lines of Lines contain Fragment (case blind, literal).
function Measure-ConsoleLines {
    param([string[]]$Lines, [string]$Fragment)
    $n = 0
    foreach ($line in $Lines) {
        if ($line.IndexOf($Fragment, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) { $n++ }
    }
    return $n
}

# REQ-007.17: the run of the accepted build. ConsoleText is what the bootstrapper printed, StatusText its ~bootstrap.status.json,
# RunOutText the stdout the check run of the EXE left in ~run.out.txt, DirectOutText what the EXE printed when started on its own.
function Get-AcceptProblems {
    param([bool]$Finished, [string]$ExitText, [string]$ConsoleText, [string]$StatusText, [string]$RunOutText, [string]$VenvLeaf,
          [string]$ExeName, [string]$ProgramLine, [bool]$ExeExists, [bool]$DirectFinished, [string]$DirectExitText, [string]$DirectOutText)
    $out = New-Object System.Collections.ArrayList
    $tag = 'system-Python EXE build accepted'
    if (-not $Finished) { [void]$out.Add("${tag}: the bootstrapper did not finish within the time limit"); return $out.ToArray() }
    $exit = $ExitText.Trim()
    if ($exit -ne '0') { [void]$out.Add("${tag}: the run ended with exit code '${exit}', expected 0") }
    $lines = @(($ConsoleText -replace "`r", '') -split "`n")
    # The console lines the run must show, in this order. The third item says whether the line must be there exactly once (a second
    # one would be a second build or a second consent) or at least once.
    $sequence = @(
        @('the system tier was tried', '[WARN] Attempting system Python fallback (degraded)...', $true),
        @('the REQ-014 consent was accepted', '[INFO] REQ-014: System Python consent: user accepted.', $true),
        @('the system tier was selected', '[INFO] System fallback using ', $true),
        @('the provider line says System Python', '[BOOT] REQ-009: Selected Python provider: System Python (degraded).', $true),
        @('the REQ-007 build consent was accepted', '[INFO] REQ-007: system-Python EXE build consent: accepted.', $true),
        @('the build started', '[INFO] Building standalone executable -- this may take a minute or two...', $true),
        @('PyInstaller produced the EXE', ('[INFO] PyInstaller produced dist\' + $ExeName), $true),
        @('the check run went through the packaged EXE', '[INFO] Running entry script smoke test via packaged EXE.', $true),
        @('the check run exited 0', '[INFO] Entry smoke exit=0', $false),
        @('the check run reported success', '[STATUS] Run Status: SUCCESS (Exit Code: 0)', $false)
    )
    $prev = -1
    foreach ($step in $sequence) {
        $label = [string]$step[0]
        $fragment = [string]$step[1]
        $once = [bool]$step[2]
        $n = Measure-ConsoleLines -Lines $lines -Fragment $fragment
        if ($n -lt 1) {
            [void]$out.Add("${tag}: the console has no line for ${label} (expected '${fragment}')")
            continue
        }
        if ($once -and $n -ne 1) { [void]$out.Add("${tag}: the console has ${n} lines for ${label}, expected exactly 1 ('${fragment}')") }
        $at = Find-ConsoleLine -Lines $lines -Fragment $fragment -From 0
        if ($at -le $prev) { [void]$out.Add("${tag}: ${label} comes before the step that precedes it on the console") } else { $prev = $at }
    }
    # the interpreter the run took as the system Python must be the private one, or the run did not go where the row says
    $fallbackAt = Find-ConsoleLine -Lines $lines -Fragment '[INFO] System fallback using ' -From 0
    if (($fallbackAt -ge 0) -and ($lines[$fallbackAt].IndexOf($VenvLeaf, [System.StringComparison]::OrdinalIgnoreCase) -lt 0)) {
        [void]$out.Add("${tag}: the system interpreter of the run is not the private one (the line does not name ${VenvLeaf})")
    }
    # none of the lines of the declined path
    $never = @(
        @('the build consent was declined', 'system-Python EXE build consent: declined.'),
        @('the build was skipped as not consented', 'system-Python EXE build not consented'),
        @('the program was only checked through the interpreter', 'Running entry script smoke test via system interpreter.'),
        @('the check run failed', '[STATUS] Run Status: FAILED'),
        @('the panel is the caveat panel', 'SETUP COMPLETE -- WITH A CAVEAT')
    )
    foreach ($item in $never) {
        $n = Measure-ConsoleLines -Lines $lines -Fragment ([string]$item[1])
        if ($n -gt 0) { [void]$out.Add("${tag}: the console has ${n} line(s) saying $([string]$item[0]) ('$([string]$item[1])')") }
    }
    # the post-flight panel names the EXE on the line under the ready line
    $readyAt = -1
    for ($i = 0; $i -lt $lines.Length; $i++) {
        if ($lines[$i].Trim() -ieq 'Your standalone application is ready:') { $readyAt = $i; break }
    }
    if ($readyAt -lt 0) {
        [void]$out.Add("${tag}: the console has no post-flight panel line 'Your standalone application is ready:'")
    } else {
        $next = ''
        for ($j = $readyAt + 1; $j -lt $lines.Length; $j++) {
            if ($lines[$j].Trim() -ne '') { $next = $lines[$j].Trim(); break }
        }
        $want = 'dist\' + $ExeName
        if ($next -ine $want) { [void]$out.Add("${tag}: the line under the ready line of the panel is '${next}', expected '${want}'") }
    }
    if (-not $ExeExists) { [void]$out.Add("${tag}: dist\${ExeName} does not exist after the run") }
    if ($RunOutText.IndexOf($ProgramLine, [System.StringComparison]::Ordinal) -lt 0) {
        [void]$out.Add("${tag}: ~run.out.txt does not hold the program's line '${ProgramLine}', so the check run did not run the program")
    }
    # the status file: the state of a build under the system provider is degraded_env, and an error here would be a lie
    $state = ''
    $code = ''
    if ($StatusText.Trim() -ne '') {
        try {
            $st = $StatusText | ConvertFrom-Json -ErrorAction Stop
            if ($null -ne $st) { $state = [string]$st.state; $code = [string]$st.exitCode }
        } catch {
            $state = ''
        }
    }
    if ($state -ne 'degraded_env') { [void]$out.Add("${tag}: ~bootstrap.status.json says state '${state}', expected degraded_env") }
    if ($code -ne '0') { [void]$out.Add("${tag}: ~bootstrap.status.json says exitCode '${code}', expected 0") }
    # the EXE on its own
    if (-not $DirectFinished) {
        [void]$out.Add("${tag}: the EXE started on its own did not finish within the time limit")
    } else {
        if ($DirectExitText.Trim() -ne '0') { [void]$out.Add("${tag}: the EXE started on its own exited with '$($DirectExitText.Trim())', expected 0") }
        if ($DirectOutText.IndexOf($ProgramLine, [System.StringComparison]::Ordinal) -lt 0) {
            [void]$out.Add("${tag}: the EXE started on its own did not print the program's line '${ProgramLine}'")
        }
    }
    return $out.ToArray()
}

# The system tier takes the first python on PATH, and the bootstrapper puts %PUBLIC%\Documents\Miniconda3 first on PATH whether or not that
# folder exists, so a Miniconda in the PUBLIC the run inherits is found by `where python` before the private interpreter (run
# 44708489835: an earlier scenario of the lane had installed one into the runner's shared Public folder after a uv failure, and its
# python.exe was the system Python of this row). The run therefore needs a PUBLIC of its own, and the launch file records the PUBLIC
# the bootstrapper saw. PublicRecord is the text of that record (PUBLIC=<folder>), PublicWanted the folder the run was meant to get.
function Get-IsolationProblems {
    param([string]$PublicRecord, [string]$PublicWanted)
    $out = New-Object System.Collections.ArrayList
    $tag = 'system-Python EXE build accepted'
    $seen = ''
    $m = [regex]::Match($PublicRecord, '(?m)^PUBLIC=(.*?)\s*$')
    if ($m.Success) { $seen = $m.Groups[1].Value.Trim() }
    $want = $PublicWanted.Trim()
    if ($seen -eq '') {
        [void]$out.Add("${tag}: the launch file recorded no PUBLIC, so it is not known where the bootstrapper looked for a Miniconda")
    } elseif ($seen -ine $want) {
        [void]$out.Add("${tag}: the bootstrapper saw PUBLIC '${seen}', expected '${want}' (a folder of its own), so a Miniconda that an earlier scenario left in the runner's shared Public folder could be found and taken as the system Python")
    }
    return $out.ToArray()
}

# REQ-007.20: the answer of tools/exe_wording.py console about the console of that run. JudgeRan is false when the judge could not be
# started (JudgeError says why); JsonText is the one line it prints.
function Get-WordingProblems {
    param([bool]$JudgeRan, [string]$JudgeError, [int]$JudgeExit, [string]$JsonText,
          [int]$MinTimestamped, [int]$MinTriggered, [int]$MinNamed, [int]$MinExempt)
    $out = New-Object System.Collections.ArrayList
    $tag = 'console wording of the accepted build'
    if (-not $JudgeRan) { [void]$out.Add("${tag}: the judge did not run: ${JudgeError}"); return $out.ToArray() }
    $parsed = $null
    if ($JsonText.Trim() -ne '') {
        try { $parsed = $JsonText | ConvertFrom-Json -ErrorAction Stop } catch { $parsed = $null }
    }
    if (($null -eq $parsed) -or ($null -eq $parsed.PSObject.Properties['stats']) -or ($null -eq $parsed.PSObject.Properties['ok'])) {
        [void]$out.Add("${tag}: the judge printed no result it could be read from (exit code ${JudgeExit})")
        return $out.ToArray()
    }
    $stats = $parsed.stats
    $got = [ordered]@{ timestamped = 0; triggered = 0; named = 0; exempt = 0; violations = 0 }
    foreach ($key in @('timestamped', 'triggered', 'named', 'exempt', 'violations')) {
        if ($null -ne $stats.PSObject.Properties[$key]) { $got[$key] = [int]$stats.$key }
    }
    $problems = @()
    if ($null -ne $parsed.PSObject.Properties['problems']) { $problems = @($parsed.problems) }
    if (($parsed.ok -eq $true) -and ($JudgeExit -ne 0)) { [void]$out.Add("${tag}: the judge says ok and exits with ${JudgeExit}") }
    if (($parsed.ok -ne $true) -and ($problems.Count -eq 0)) { [void]$out.Add("${tag}: the judge says not ok and names no line") }
    $shown = 0
    foreach ($p in $problems) {
        if ($shown -ge 20) { [void]$out.Add("${tag}: ... and $($problems.Count - 20) more"); break }
        [void]$out.Add("${tag}: $([string]$p)")
        $shown++
    }
    # the run must have shown the judge enough: a console that never reached the build proves nothing
    if ($got.timestamped -lt $MinTimestamped) { [void]$out.Add("${tag}: the judge read $($got.timestamped) log lines, expected at least ${MinTimestamped}, so the console is not that of a run") }
    if ($got.triggered -lt $MinTriggered) { [void]$out.Add("${tag}: the judge found $($got.triggered) lines about the build, expected at least ${MinTriggered}, so the run did not reach the build") }
    if ($got.named -lt $MinNamed) { [void]$out.Add("${tag}: $($got.named) of the lines about the build name the EXE or the tool, expected at least ${MinNamed}") }
    if ($got.exempt -lt $MinExempt) { [void]$out.Add("${tag}: $($got.exempt) of the lines about the build matched an exempt entry, expected at least ${MinExempt}, so the exempt list was not exercised") }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# the private interpreter, the folder of the program and the run
# ---------------------------------------------------------------------------------------------------------------------
$appName     = '~selftest_sysbuild_accept'
$venvName    = '~selftest_sysbuild_accept_venv'
$appDir      = Join-Path $here $appName
$venvDir     = Join-Path $here $venvName
$publicDir   = $appDir + '_public'
$exeName     = ($appName -replace '[^A-Za-z0-9_-]', '_') + '.exe'
$programLine = 'sysbuild-accept-app-line-7731'
$consoleName = '~sysbuild_accept.log'

# floors of the wording row: about two thirds of what the first real run showed (48 timestamped lines, 9 about the build, 7 that name
# the EXE once the messages were reworded, 2 exempt), so a console that stops before the build or before its closing messages fails
$minTimestamped = 30
$minTriggered   = 6
$minNamed       = 4
$minExempt      = 1

# The runner's python: the first one on PATH, asked for its real path (a Microsoft Store alias would print nothing).
$basePython = ''
$baseNote = ''
$cmd = Get-Command python -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $cmd) {
    $baseNote = 'no python on PATH'
} else {
    try {
        $printed = @(& $cmd.Source -c 'import sys; print(sys.executable)' 2>$null)
        if (($LASTEXITCODE -eq 0) -and ($printed.Count -gt 0)) { $basePython = ([string]$printed[0]).Trim() }
        if (-not $basePython) { $baseNote = 'python on PATH printed no executable path (exit ' + $LASTEXITCODE + ')' }
    } catch {
        $baseNote = [string]$_.Exception.Message
    }
}
if ((-not $basePython) -or (-not (Test-Path -LiteralPath $basePython))) {
    Write-AllRows -Pass $false -Desc 'system-Python EXE build accepted: no python to make the private interpreter from' -Details ([ordered]@{ error = 'no usable python on the runner'; note = $baseNote; basePython = $basePython })
    exit 1
}

if (Test-Path -LiteralPath $venvDir) { Remove-Item -LiteralPath $venvDir -Recurse -Force -ErrorAction SilentlyContinue }
$venvOut = @(& $basePython -m venv $venvDir 2>&1)
$venvRc = $LASTEXITCODE
$venvPython = Join-Path $venvDir 'Scripts\python.exe'
if (($venvRc -ne 0) -or (-not (Test-Path -LiteralPath $venvPython))) {
    Add-Evidence -Title 'private interpreter could not be made' -Text (($venvOut | ForEach-Object { [string]$_ }) -join "`n")
    Write-AllRows -Pass $false -Desc 'system-Python EXE build accepted: the private interpreter could not be made' -Details ([ordered]@{ error = 'python -m venv failed'; exit = $venvRc; basePython = $basePython })
    exit 1
}

if (Test-Path -LiteralPath $appDir) { Remove-Item -LiteralPath $appDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $appDir | Out-Null
if (Test-Path -LiteralPath $publicDir) { Remove-Item -LiteralPath $publicDir -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $publicDir | Out-Null
Copy-Item -LiteralPath $batchPath -Destination (Join-Path $appDir 'run_setup.bat') -Force
Write-CrLf -Path (Join-Path $appDir 'app.py') -Lines @('print("' + $programLine + '")')

$ciLaneValue = 'selftest'
if ($env:HP_CI_LANE -and ($env:HP_CI_LANE -match '^[A-Za-z0-9_.-]+$')) { $ciLaneValue = $env:HP_CI_LANE }
$launchLines = New-Object System.Collections.ArrayList
[void]$launchLines.Add('@echo off')
foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }
foreach ($l in @(
    ('set "PATH=' + (Join-Path $venvDir 'Scripts') + ';%PATH%"'),
    'set "HP_OFFLINE_MODE=1"',
    'set "HP_TEST_FORCE_CONDA_FAIL=1"',
    'set "HP_TEST_FORCE_VENV_FAIL=1"',
    'set "HP_TEST_SYSCON_ANSWER=Y"',
    'set "HP_TEST_SYSBUILD_ANSWER=Y"',
    ('set "HP_CI_LANE=' + $ciLaneValue + '"'),
    ('set "PUBLIC=' + $publicDir + '"'),
    '>"~accept_public.txt" echo PUBLIC=%PUBLIC%',
    ('call run_setup.bat > ' + $consoleName + ' 2>&1 < nul'),
    '>"~accept_exit.txt" echo %ERRORLEVEL%',
    'exit /b 0'
)) { [void]$launchLines.Add($l) }
Write-CrLf -Path (Join-Path $appDir '~accept_launch.cmd') -Lines $launchLines.ToArray()
$launch = Invoke-Launch -Dir $appDir -LaunchName '~accept_launch.cmd' -LimitMs 900000

$consolePath = Join-Path $appDir $consoleName
$console   = Read-Text $consolePath
$exitText  = Read-Text (Join-Path $appDir '~accept_exit.txt')
$statusTxt = Read-Text (Join-Path $appDir '~bootstrap.status.json')
$runOut    = Read-Text (Join-Path $appDir '~run.out.txt')
$setupLog  = Read-Text (Join-Path $appDir '~setup.log')
$publicRecord = Read-Text (Join-Path $appDir '~accept_public.txt')
$exePath   = Join-Path $appDir ('dist\' + $exeName)
$exeExists = Test-Path -LiteralPath $exePath

# the EXE on its own, outside the bootstrapper
$direct = [ordered]@{ Finished = $false; ExitCode = -1; Error = '' }
$directOutPath = Join-Path $appDir '~direct_run_out.txt'
if ($exeExists) { $direct = Invoke-DirectRun -ExePath $exePath -Dir $appDir -OutPath $directOutPath -LimitMs 60000 }
$directOut = Read-Text $directOutPath

$distListing = ''
if (Test-Path -LiteralPath (Join-Path $appDir 'dist')) {
    $distListing = (Get-ChildItem -LiteralPath (Join-Path $appDir 'dist') | ForEach-Object { $_.Name + ' ' + $_.Length }) -join "`n"
}

$acceptProblems = @(Get-AcceptProblems -Finished ([bool]$launch.Finished) -ExitText $exitText -ConsoleText $console -StatusText $statusTxt -RunOutText $runOut `
    -VenvLeaf $venvName -ExeName $exeName -ProgramLine $programLine -ExeExists ([bool]$exeExists) -DirectFinished ([bool]$direct.Finished) `
    -DirectExitText ([string]$direct.ExitCode) -DirectOutText $directOut)
$isolationProblems = @(Get-IsolationProblems -PublicRecord $publicRecord -PublicWanted $publicDir)
$acceptProblems = @($isolationProblems) + @($acceptProblems)

# the wording judge over the same console
$toolPath = Join-Path $repo 'tools\exe_wording.py'
$judgeRan = $false
$judgeError = ''
$judgeExit = -1
$judgeJson = ''
$judgeErrPath = Join-Path $appDir '~wording_judge.err.txt'
if (-not (Test-Path -LiteralPath $toolPath)) {
    $judgeError = 'tools\exe_wording.py is missing'
} elseif (-not (Test-Path -LiteralPath $consolePath)) {
    $judgeError = 'the console log of the run does not exist'
} else {
    try {
        $judgeOut = @(& $basePython -I $toolPath console --file $consolePath 2>$judgeErrPath)
        $judgeExit = $LASTEXITCODE
        $judgeJson = ($judgeOut | ForEach-Object { [string]$_ }) -join "`n"
        $judgeRan = $true
    } catch {
        $judgeError = [string]$_.Exception.Message
    }
}
$wordingProblems = @(Get-WordingProblems -JudgeRan ([bool]$judgeRan) -JudgeError $judgeError -JudgeExit ([int]$judgeExit) -JsonText $judgeJson `
    -MinTimestamped $minTimestamped -MinTriggered $minTriggered -MinNamed $minNamed -MinExempt $minExempt)

Add-Evidence -Title ('the run (' + $launch.Seconds + ' s, launch exit ' + $launch.ExitCode + ', run exit ' + $exitText.Trim() + ')') `
    -Text ("--- status`n" + $statusTxt + "`n--- dist`n" + $distListing + "`n--- console`n" + $console) -MaxLines 230
Add-Evidence -Title 'the program as the check run printed it (~run.out.txt)' -Text $runOut -MaxLines 20
Add-Evidence -Title ('the EXE started on its own (exit ' + $direct.ExitCode + ')') -Text $directOut -MaxLines 20
Add-Evidence -Title ('the wording judge (exit ' + $judgeExit + ')') -Text ($judgeJson + "`n" + (Read-Text $judgeErrPath)) -MaxLines 60
Add-Evidence -Title 'setup log of the run (first lines)' -Text $setupLog -MaxLines 60
Add-Evidence -Title 'the PUBLIC the bootstrapper saw (~accept_public.txt)' -Text ($publicRecord + "`nwanted: " + $publicDir) -MaxLines 5

$allPass = $true

$pass = [bool](@($acceptProblems).Count -eq 0)
if (-not $pass) { $allPass = $false }
$acceptDetails = [ordered]@{
    finished = [bool]$launch.Finished; seconds = $launch.Seconds; runExit = $exitText.Trim(); basePython = $basePython
    status = $statusTxt.Trim(); exeExists = [bool]$exeExists; directFinished = [bool]$direct.Finished; directExit = $direct.ExitCode
    publicRecord = $publicRecord.Trim(); publicWanted = $publicDir
}
if ($launch.Error) { $acceptDetails['error'] = $launch.Error }
if (-not $pass) { $acceptDetails['problems'] = @($acceptProblems) }
Write-NdjsonRow ([ordered]@{ id = 'self.sysbuild.accept'; req = 'REQ-007.17'; pass = $pass
    desc = 'REQ-007.17: the answer Y to the system-Python build question builds the EXE like every other provider, checks it through the packaged EXE and ends ok'
    details = $acceptDetails })

$pass = [bool](@($wordingProblems).Count -eq 0)
if (-not $pass) { $allPass = $false }
$wordingDetails = [ordered]@{ judgeRan = [bool]$judgeRan; judgeExit = $judgeExit; consoleBytes = $console.Length; judge = $judgeJson.Trim() }
if ($judgeError) { $wordingDetails['error'] = $judgeError }
if (-not $pass) { $wordingDetails['problems'] = @($wordingProblems) }
Write-NdjsonRow ([ordered]@{ id = 'self.sysbuild.wording'; req = 'REQ-007.20'; pass = $pass
    desc = 'REQ-007.20: every log line of the accepted system-Python build that talks about building or verifying names the EXE or the tool'
    details = $wordingDetails })

if (-not $allPass) { exit 1 }
exit 0
