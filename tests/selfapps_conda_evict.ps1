# ASCII only
# selfapps_conda_evict.ps1 - Item 122 (README REQ-020.5 and REQ-020.9): after the user answers Y to the question about a damaged
# conda installation, the installation is deleted, a fresh Miniconda is installed in its place and the run continues; when no conda
# installation exists after that, the run stops with exit code 4 and says that the fresh install failed.
#
# Why rows of their own. The README said, until this item, that both shalls are "shown by inspection of run_setup.bat": the
# existing rows reach the answer Y only through the test flag HP_TEST_SKIP_EVICT (selftest.ps1 self.corrupt.conda.heal.accept), which
# skips the deletion and the download so that the CI Miniconda stays intact, and through a locked file (self.corrupt.conda.real_locked,
# REQ-020.6), which stops before the install. Nothing ran the deletion followed by the install, and nothing ran the exit code 4.
#
# Three driver scenarios and one real run.
#   The block :evict_and_rebuild (up to :conda_bulk_install) and the subroutine :select_conda_bat (up to :download_miniconda_exe) are
#   cut out of run_setup.bat and wrapped in a small batch file that runs under cmd.exe with closed standard input. The driver defines
#   what the block reaches: a :log and a :die that write to a ledger, a :download_miniconda_exe that records whether the folder of
#   the damaged installation is already gone and leaves an installer file in the private TEMP folder, and a :try_conda_install that
#   records the same and either creates a fresh condabin\conda.bat (answers errorlevel 0) or creates nothing. The real Miniconda
#   installer is not run: it is a download of about 100 MB, and the regular conda lanes (conda-full) already run the same two
#   subroutines for the first install of every bootstrap.
#     evict    the damaged installation (a conda.bat that exits 1, a marker file and a nested folder, in a private PUBLIC folder) is
#              deleted by the block's own rmdir, the download and the install start with the folder gone, the run continues at
#              :after_conda_bat_validation with CONDA_BAT pointing at the fresh conda.bat (which exits 0), HP_CONDA_JUST_INSTALLED
#              set, and no leftover of the damaged installation  (REQ-020.5)
#     control  the same with HP_TEST_SKIP_EVICT set: nothing is deleted, the stub subroutines are never called and conda.bat is
#              still the damaged one (exits 1), so the evict scenario's result comes from the block and not from the driver
#     nofresh  the install leaves no conda.bat: the block calls :die with the message that the fresh install failed and the code 4,
#              and ends with exit code 4 without reaching the line after it  (REQ-020.9)
#   One more run starts the real bootstrapper in a folder of its own (private PUBLIC with a damaged conda.bat that exits 1, private
#   TEMP, HP_FORCE_CONDA_ONLY=1, HP_TEST_HEAL_ANSWER=Y and HP_OFFLINE_MODE=1, every other HP_ or PVW_ variable cleared): the real
#   health check fails, the answer Y deletes the installation, the offline mode skips the Miniconda download, and the run must stop
#   with exit code 4 after the four log lines of the contract, in order  (REQ-020.9, the whole bootstrap and not only the block).
#
# derived requirement: ids and tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell), and the judging functions take plain values and return a list of problems
# (tests/test_conda_evict.py runs them through a real pwsh on synthetic runs).
#
# Limit, stated so that nobody reads more into the rows than they show: REQ-020.5 says "install a fresh Miniconda in its place";
# the rows show that the block deletes, then calls the installation subroutines with the folder gone, then continues with whatever
# conda.bat those leave. That the installer really produces a working Miniconda is shown by the conda-full lane, which runs the
# same subroutines on every bootstrap.
#
# Lane: contract-uv. Gating from its first run (AGENTS.md "New tests gate immediately"): a red row holds the aggregate check.
# Three driver runs of seconds each and one real bootstrap that stops before any download.
# Emits: self.corrupt.conda.evict.install, self.corrupt.conda.evict.installfail
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
    Write-NdjsonRow ([ordered]@{ id = 'self.corrupt.conda.evict.install'; req = 'REQ-020.5'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.corrupt.conda.evict.installfail'; req = 'REQ-020.9'; pass = $Pass; desc = $Desc; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'conda eviction followed by a fresh install (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'conda eviction followed by a fresh install: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------------------------------------------------
$evidencePath = Join-Path $here '~conda_evict_evidence.txt'
Set-Content -LiteralPath $evidencePath -Value 'selfapps_conda_evict.ps1 evidence (printable ASCII only)' -Encoding Ascii

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

$batLines = [System.IO.File]::ReadAllLines($batchPath)

# Lines from the line that is exactly StartLabel up to, not including, the line that is exactly EndLabel.
function Get-BatBlock {
    param([string]$StartLabel, [string]$EndLabel)
    $start = -1
    for ($i = 0; $i -lt $batLines.Length; $i++) {
        if ($batLines[$i].Trim() -eq $StartLabel) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = -1
    for ($j = $start + 1; $j -lt $batLines.Length; $j++) {
        if ($batLines[$j].Trim() -eq $EndLabel) { $end = $j; break }
    }
    if ($end -lt 0) { return $null }
    return $batLines[$start..($end - 1)]
}

# set "NAME=" for every HP_, PVW_ and NOINPUT variable of this process: a setting of the runner could otherwise decide for the
# bootstrapper. The names are validated, because they end up in a batch file.
function Get-ClearLines {
    $names = @(Get-ChildItem Env: | ForEach-Object { $_.Name } | Where-Object { ($_ -match '^(HP_|PVW_)' -or $_ -eq 'NOINPUT') -and $_ -match '^[A-Za-z0-9_]+$' })
    return @($names | ForEach-Object { 'set "' + $_ + '="' })
}

# ---------------------------------------------------------------------------------------------------------------------
# the scenarios of the driver
# ---------------------------------------------------------------------------------------------------------------------
# Skip says whether the driver sets HP_TEST_SKIP_EVICT (the control), Install what the stub of :try_conda_install does. The texts
# below are pinned to run_setup.bat by tests/test_conda_evict.py.
$scenarios = @(
    [pscustomobject]@{ Name = 'evict'; Kind = 'evict'; Skip = $false; Install = 'creates' },
    [pscustomobject]@{ Name = 'control'; Kind = 'control'; Skip = $true; Install = 'creates' },
    [pscustomobject]@{ Name = 'nofresh'; Kind = 'nofresh'; Skip = $false; Install = 'nothing' }
)
$failMessage = '[ERROR] Fresh Miniconda install failed after self-healing eviction.'

# ---------------------------------------------------------------------------------------------------------------------
# judging: plain values in, a list of problems out (nothing when the run shows what the scenario must show)
# ---------------------------------------------------------------------------------------------------------------------
# The index of the first line of Lines that equals Text (case blind), or -1.
function Get-LineIndex {
    param([string[]]$Lines, [string]$Text)
    for ($i = 0; $i -lt $Lines.Length; $i++) {
        if ($Lines[$i] -ieq $Text) { return $i }
    }
    return -1
}

# One driver run. The ledger holds one line per fact the driver recorded, in the order it happened.
function Get-EvictProblems {
    param([string]$Kind, [bool]$Finished, [string]$ExitText, [string]$LedgerText, [string]$CondaMainPath, [string]$RootPath)
    $out = New-Object System.Collections.ArrayList
    $tag = "conda eviction ${Kind}"
    if (-not $Finished) { [void]$out.Add("${tag}: the driver did not finish within the time limit"); return $out.ToArray() }
    $lines = @(($LedgerText -replace "`r", '') -split "`n" | Where-Object { $_ -ne '' })
    $count = { param($text) @($lines | Where-Object { $_ -ieq $text }).Count }
    if ((& $count 'START') -ne 1) {
        [void]$out.Add("${tag}: the driver did not write START exactly once, so the block was not entered")
        return $out.ToArray()
    }
    $exit = $ExitText.Trim()
    $wantExit = '0'
    if ($Kind -eq 'nofresh') { $wantExit = '4' }
    if ($exit -ne $wantExit) { [void]$out.Add("${tag}: the driver ended with exit code '${exit}', expected ${wantExit}") }
    # the scenario's own precondition: the damaged installation was there before the block ran
    foreach ($pre in @('PRE damaged=present', 'PRE nested=present')) {
        if ((& $count $pre) -ne 1) { [void]$out.Add("${tag}: the precondition '${pre}' is not in the ledger exactly once, so the run proves nothing") }
    }
    $evictedLine = 'LOG [INFO] Self-healing: corrupt conda evicted from ' + $RootPath + '.'
    $nEvicted = & $count $evictedLine
    if ($nEvicted -ne 1) { [void]$out.Add("${tag}: the log holds ${nEvicted} line(s) saying the corrupt conda was evicted from the folder, expected 1") }
    $iEvicted = Get-LineIndex -Lines $lines -Text $evictedLine
    $nDie = @($lines | Where-Object { $_ -like 'DIE *' }).Count
    $nCalls = @($lines | Where-Object { $_ -like 'DOWNLOAD *' -or $_ -like 'INSTALL *' }).Count
    if ($Kind -eq 'control') {
        # no deletion and no install: the stubs are never reached and the damaged conda.bat is still the one in use
        if ($nCalls -ne 0) { [void]$out.Add("${tag}: the download or install subroutine was called ${nCalls} time(s) although nothing was evicted") }
    } else {
        foreach ($call in @('DOWNLOAD root=absent', 'INSTALL root=absent', 'INSTALL installer=present')) {
            if ((& $count $call) -ne 1) { [void]$out.Add("${tag}: the ledger does not hold '${call}' exactly once (the download and the install must start with the damaged folder gone and the installer in place)") }
        }
        $iDownload = Get-LineIndex -Lines $lines -Text 'DOWNLOAD root=absent'
        $iInstall = Get-LineIndex -Lines $lines -Text 'INSTALL root=absent'
        if ($iEvicted -ge 0 -and $iDownload -ge 0 -and $iInstall -ge 0) {
            if (-not ($iEvicted -lt $iDownload -and $iDownload -lt $iInstall)) { [void]$out.Add("${tag}: the order is not eviction, download, install") }
        }
    }
    if ($Kind -eq 'nofresh') {
        $dieLine = 'DIE code=4 msg=' + '[ERROR] Fresh Miniconda install failed after self-healing eviction.'
        if ((& $count $dieLine) -ne 1) { [void]$out.Add("${tag}: the run did not stop once with the failure of the fresh install and the code 4") }
        if ($nDie -ne 1) { [void]$out.Add("${tag}: the block called :die ${nDie} time(s), expected 1") }
        $iDie = Get-LineIndex -Lines $lines -Text $dieLine
        $iInstall2 = Get-LineIndex -Lines $lines -Text 'INSTALL root=absent'
        if ($iDie -ge 0 -and $iInstall2 -ge 0 -and $iDie -lt $iInstall2) { [void]$out.Add("${tag}: the failure was reported before the install was tried") }
        if ((& $count 'CONTINUED') -ne 0 -or (& $count 'END') -ne 0) { [void]$out.Add("${tag}: the run went on after the failure of the fresh install instead of stopping") }
        return $out.ToArray()
    }
    if ($nDie -ne 0) { [void]$out.Add("${tag}: the block called :die ${nDie} time(s), expected none") }
    if ((& $count 'CONTINUED') -ne 1 -or (& $count 'END') -ne 1) {
        [void]$out.Add("${tag}: the run did not continue at the line after the block exactly once")
        return $out.ToArray()
    }
    if ($Kind -eq 'evict') {
        $iContinued = Get-LineIndex -Lines $lines -Text 'CONTINUED'
        $iInstall3 = Get-LineIndex -Lines $lines -Text 'INSTALL root=absent'
        if ($iInstall3 -ge 0 -and $iContinued -lt $iInstall3) { [void]$out.Add("${tag}: the run continued before the install was tried") }
    }
    if ((& $count ('CONDA_BAT=' + $CondaMainPath)) -ne 1) { [void]$out.Add("${tag}: the run did not continue with CONDA_BAT set to ${CondaMainPath}") }
    if ((& $count 'JUST_INSTALLED=1') -ne 1) { [void]$out.Add("${tag}: HP_CONDA_JUST_INSTALLED is not 1 after the block, so the health check would run again on the fresh installation") }
    if ((& $count 'ENV_STATE_RESULT=') -ne 1) { [void]$out.Add("${tag}: HP_ENV_STATE_RESULT was not cleared, so a state of the deleted installation could be reused") }
    $wantDamaged = 'absent'
    $wantFresh = 'present'
    $wantInfo = '0'
    if ($Kind -eq 'control') { $wantDamaged = 'present'; $wantFresh = 'absent'; $wantInfo = '1' }
    foreach ($post in @(('POST damaged=' + $wantDamaged), ('POST nested=' + $wantDamaged), ('POST fresh=' + $wantFresh), 'POST installer=absent')) {
        if ((& $count $post) -ne 1) { [void]$out.Add("${tag}: the ledger does not hold '${post}' exactly once") }
    }
    if ((& $count ('INFO_RC=' + $wantInfo)) -ne 1) { [void]$out.Add("${tag}: conda.bat info after the block did not answer ${wantInfo}, so the run continued with the wrong conda.bat") }
    return $out.ToArray()
}

# The real bootstrap with the damaged installation, the answer Y and no network: it must stop with exit code 4 after the log lines
# of the contract, in this order, and leave nothing of the installation behind.
function Get-OfflineEvictProblems {
    param([bool]$Finished, [string]$ExitText, [string]$ConsoleText, [string]$SetupText, [string]$FakeBatPath, [string]$RootPath,
          [bool]$RootExists, [bool]$StubExists, [bool]$InstallerExists)
    $out = New-Object System.Collections.ArrayList
    $tag = 'conda eviction real offline run'
    if (-not $Finished) { [void]$out.Add("${tag}: the bootstrapper did not finish within the time limit"); return $out.ToArray() }
    $exit = $ExitText.Trim()
    if ($exit -ne '4') { [void]$out.Add("${tag}: the run ended with exit code '${exit}', expected 4") }
    $ordinal = [System.StringComparison]::OrdinalIgnoreCase
    $wanted = @(
        @('the damaged installation is named', ('Corrupt conda binary detected at: ' + $FakeBatPath)),
        @('the eviction is logged', ('Self-healing: corrupt conda evicted from ' + $RootPath + '.')),
        @('the missing download is logged', 'Offline mode: skipping Miniconda download.'),
        @('the failure of the fresh install is reported', 'Fresh Miniconda install failed after self-healing eviction.')
    )
    $last = -1
    foreach ($w in $wanted) {
        $first = $SetupText.IndexOf($w[1], $ordinal)
        $n = 0
        if ($first -ge 0) { $n = ([regex]::Matches($SetupText, [regex]::Escape($w[1]), 'IgnoreCase')).Count }
        if ($n -ne 1) {
            [void]$out.Add("${tag}: the setup log holds ${n} line(s) for $($w[0]), expected 1")
        } elseif ($first -lt $last) {
            [void]$out.Add("${tag}: in the setup log $($w[0]) comes before the step that precedes it")
        }
        if ($first -ge 0) { $last = $first }
    }
    if ($ConsoleText.IndexOf('Fresh Miniconda install failed after self-healing eviction.', $ordinal) -lt 0) {
        [void]$out.Add("${tag}: the console does not show that the fresh install failed")
    }
    if ($SetupText.IndexOf('Could not delete corrupt conda dir', $ordinal) -ge 0) {
        [void]$out.Add("${tag}: the setup log says files may be locked, although nothing was held open")
    }
    if ($SetupText.IndexOf('user declined rebuild', $ordinal) -ge 0) {
        [void]$out.Add("${tag}: the setup log says the user declined, although the answer was Y")
    }
    if ($RootExists) { [void]$out.Add("${tag}: the folder of the damaged installation is still there after the run") }
    if ($StubExists) { [void]$out.Add("${tag}: the damaged conda.bat is still there after the run") }
    if ($InstallerExists) { [void]$out.Add("${tag}: an installer file is left in the private temp folder, so a download was started") }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# the damaged installation, the driver and the runs
# ---------------------------------------------------------------------------------------------------------------------
$work = Join-Path $here '~selftest_condaevict'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

# A private PUBLIC folder with a Miniconda that cannot start (conda.bat exits 1), a marker file and a nested folder, and a private
# TEMP folder. Returns the folder of the installation.
function New-DamagedInstall {
    param([string]$Dir)
    $root = Join-Path $Dir 'pub\Documents\Miniconda3'
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'condabin') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $root 'pkgs\sub') | Out-Null
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'tmp') | Out-Null
    Write-CrLf -Path (Join-Path $root 'condabin\conda.bat') -Lines @('@exit /b 1')
    Write-CrLf -Path (Join-Path $root 'marker_damaged.txt') -Lines @('file of the damaged installation')
    Write-CrLf -Path (Join-Path $root 'pkgs\sub\deep.txt') -Lines @('file in a nested folder')
    return $root
}

# The driver: the two real pieces of run_setup.bat, a ledger, and stubs for what the block calls. The driver clears every variable
# the block reads before it sets its own, so none comes from the runner. The block is entered with goto, as the real flow enters it
# from :heal_prompt, so its exit /b 4 ends the driver, as it ends the bootstrapper.
function New-EvictDriver {
    param([string]$Dir, $Scenario, [string[]]$EvictBlock, [string[]]$SelectBlock)
    $root = Join-Path $Dir 'pub\Documents\Miniconda3'
    $skip = ''
    if ($Scenario.Skip) { $skip = '1' }
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in @(
        '@echo off', 'setlocal',
        ('set "LEDGER=' + (Join-Path $Dir '~driver_ledger.txt') + '"'),
        ('set "TEMP=' + (Join-Path $Dir 'tmp') + '"'),
        ('set "TMP=' + (Join-Path $Dir 'tmp') + '"'),
        ('set "MINICONDA_ROOT=' + $root + '"'),
        'set "CONDA_MAIN=%MINICONDA_ROOT%\condabin\conda.bat"',
        'set "CONDA_ALT=%MINICONDA_ROOT%\Scripts\conda.bat"',
        'set "CONDA_BAT=%CONDA_MAIN%"',
        'set "HP_CONDA_JUST_INSTALLED="',
        'set "HP_ENV_STATE_RESULT=stale"',
        ('set "HP_TEST_SKIP_EVICT=' + $skip + '"'),
        ('set "STUB_INSTALL=' + $Scenario.Install + '"'),
        '>"%LEDGER%" echo START',
        'if exist "%MINICONDA_ROOT%\marker_damaged.txt" >>"%LEDGER%" echo PRE damaged=present',
        'if not exist "%MINICONDA_ROOT%\marker_damaged.txt" >>"%LEDGER%" echo PRE damaged=absent',
        'if exist "%MINICONDA_ROOT%\pkgs\sub\deep.txt" >>"%LEDGER%" echo PRE nested=present',
        'if not exist "%MINICONDA_ROOT%\pkgs\sub\deep.txt" >>"%LEDGER%" echo PRE nested=absent',
        'goto :evict_and_rebuild'
    )) { [void]$lines.Add($l) }
    foreach ($l in $EvictBlock) { [void]$lines.Add($l) }
    foreach ($l in @(
        ':after_conda_bat_validation',
        '>>"%LEDGER%" echo CONTINUED',
        '>>"%LEDGER%" echo CONDA_BAT=%CONDA_BAT%',
        '>>"%LEDGER%" echo JUST_INSTALLED=%HP_CONDA_JUST_INSTALLED%',
        '>>"%LEDGER%" echo ENV_STATE_RESULT=%HP_ENV_STATE_RESULT%',
        'if exist "%MINICONDA_ROOT%\marker_damaged.txt" >>"%LEDGER%" echo POST damaged=present',
        'if not exist "%MINICONDA_ROOT%\marker_damaged.txt" >>"%LEDGER%" echo POST damaged=absent',
        'if exist "%MINICONDA_ROOT%\pkgs\sub\deep.txt" >>"%LEDGER%" echo POST nested=present',
        'if not exist "%MINICONDA_ROOT%\pkgs\sub\deep.txt" >>"%LEDGER%" echo POST nested=absent',
        'if exist "%MINICONDA_ROOT%\marker_fresh.txt" >>"%LEDGER%" echo POST fresh=present',
        'if not exist "%MINICONDA_ROOT%\marker_fresh.txt" >>"%LEDGER%" echo POST fresh=absent',
        'if exist "%TEMP%\miniconda.exe" >>"%LEDGER%" echo POST installer=present',
        'if not exist "%TEMP%\miniconda.exe" >>"%LEDGER%" echo POST installer=absent',
        'call "%CONDA_BAT%" info >nul 2>&1',
        '>>"%LEDGER%" echo INFO_RC=%ERRORLEVEL%',
        '>>"%LEDGER%" echo END',
        'exit /b 0'
    )) { [void]$lines.Add($l) }
    foreach ($l in $SelectBlock) { [void]$lines.Add($l) }
    foreach ($l in @(
        ':log',
        'setlocal',
        'set "MSG=%~1"',
        '>>"%LEDGER%" echo LOG %MSG%',
        'endlocal',
        'exit /b 0',
        ':die',
        '>>"%LEDGER%" echo DIE code=%~2 msg=%~1',
        'exit /b 0',
        ':download_miniconda_exe',
        'if exist "%MINICONDA_ROOT%" >>"%LEDGER%" echo DOWNLOAD root=present',
        'if not exist "%MINICONDA_ROOT%" >>"%LEDGER%" echo DOWNLOAD root=absent',
        '>"%TEMP%\miniconda.exe" echo stub installer',
        'exit /b 0',
        ':try_conda_install',
        'if exist "%MINICONDA_ROOT%" >>"%LEDGER%" echo INSTALL root=present',
        'if not exist "%MINICONDA_ROOT%" >>"%LEDGER%" echo INSTALL root=absent',
        'if exist "%TEMP%\miniconda.exe" >>"%LEDGER%" echo INSTALL installer=present',
        'if not exist "%TEMP%\miniconda.exe" >>"%LEDGER%" echo INSTALL installer=absent',
        'if "%STUB_INSTALL%"=="creates" call :stub_fresh',
        'exit /b 0',
        ':stub_fresh',
        'mkdir "%MINICONDA_ROOT%\condabin"',
        '>"%MINICONDA_ROOT%\condabin\conda.bat" echo @exit /b 0',
        '>"%MINICONDA_ROOT%\marker_fresh.txt" echo fresh',
        'exit /b 0'
    )) { [void]$lines.Add($l) }
    return $lines.ToArray()
}

# One driver scenario: builds the damaged installation and the driver, runs it, judges the ledger. Returns the problems and the
# details of the scenario.
function Get-DriverScenarioResult {
    param($Scenario)
    $problems = New-Object System.Collections.ArrayList
    $details = [ordered]@{ scenario = $Scenario.Name }
    $evictBlock = Get-BatBlock -StartLabel ':evict_and_rebuild' -EndLabel ':conda_bulk_install'
    $selectBlock = Get-BatBlock -StartLabel ':select_conda_bat' -EndLabel ':download_miniconda_exe'
    if (($null -eq $evictBlock) -or ($null -eq $selectBlock)) {
        [void]$problems.Add('the label :evict_and_rebuild (up to :conda_bulk_install) or :select_conda_bat (up to :download_miniconda_exe) is not in run_setup.bat, so there is no block to test')
        $details['blockFound'] = $false
        return [pscustomobject]@{ Problems = @($problems); Details = $details }
    }
    $dir = Join-Path $work $Scenario.Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $root = New-DamagedInstall -Dir $dir
    $conda = Join-Path $root 'condabin\conda.bat'
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines (New-EvictDriver -Dir $dir -Scenario $Scenario -EvictBlock $evictBlock -SelectBlock $selectBlock)
    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines @('@echo off', 'call ~driver.bat > ~driver_console.txt 2>&1 < nul', '>"~driver_exit.txt" echo %ERRORLEVEL%', 'exit /b 0')
    $launch = Invoke-Launch -Dir $dir -LaunchName '~driver_launch.cmd' -LimitMs 180000
    $ledger = Read-Text (Join-Path $dir '~driver_ledger.txt')
    $exitText = Read-Text (Join-Path $dir '~driver_exit.txt')
    $console = Read-Text (Join-Path $dir '~driver_console.txt')
    $found = @(Get-EvictProblems -Kind $Scenario.Kind -Finished ([bool]$launch.Finished) -ExitText $exitText -LedgerText $ledger -CondaMainPath $conda -RootPath $root)
    Add-Evidence -Title ($Scenario.Name + ' (' + $launch.Seconds + ' s, launch exit ' + $launch.ExitCode + ', driver exit ' + $exitText.Trim() + ')') `
        -Text ("--- ledger`n" + $ledger + "`n--- console`n" + $console) -MaxLines 70
    foreach ($f in $found) { [void]$problems.Add($f) }
    $details['finished'] = [bool]$launch.Finished
    $details['seconds'] = $launch.Seconds
    $details['driverExit'] = $exitText.Trim()
    $details['ledgerLines'] = @(($ledger -split "`r?`n") | Where-Object { $_ }).Count
    if ($launch.Error) { $details['error'] = $launch.Error }
    if ($found.Count -gt 0) { $details['problems'] = @($found); $details['ledger'] = @(($ledger -split "`r?`n") | Where-Object { $_ }) }
    return [pscustomobject]@{ Problems = @($problems); Details = $details }
}

# The real bootstrap: a folder of its own, the damaged installation in a private PUBLIC, a private TEMP, conda only, the answer Y
# and offline mode. Returns the problems and the details.
function Get-OfflineScenarioResult {
    $problems = New-Object System.Collections.ArrayList
    $details = [ordered]@{ scenario = 'offline' }
    $dir = Join-Path $work 'offline'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $root = New-DamagedInstall -Dir $dir
    $fakeBat = Join-Path $root 'condabin\conda.bat'
    Copy-Item -LiteralPath $batchPath -Destination (Join-Path $dir 'run_setup.bat') -Force
    Write-CrLf -Path (Join-Path $dir 'app.py') -Lines @('print("conda-evict-offline-app")')
    $ciLaneValue = 'selftest'
    if ($env:HP_CI_LANE -and ($env:HP_CI_LANE -match '^[A-Za-z0-9_.-]+$')) { $ciLaneValue = $env:HP_CI_LANE }
    $launchLines = New-Object System.Collections.ArrayList
    [void]$launchLines.Add('@echo off')
    foreach ($l in (Get-ClearLines)) { [void]$launchLines.Add($l) }
    foreach ($l in @(
        ('set "PUBLIC=' + (Join-Path $dir 'pub') + '"'),
        ('set "TEMP=' + (Join-Path $dir 'tmp') + '"'),
        ('set "TMP=' + (Join-Path $dir 'tmp') + '"'),
        'set "HP_FORCE_CONDA_ONLY=1"',
        'set "HP_OFFLINE_MODE=1"',
        'set "HP_TEST_HEAL_ANSWER=Y"',
        ('set "HP_CI_LANE=' + $ciLaneValue + '"'),
        'call run_setup.bat > ~driver_console.txt 2>&1 < nul',
        '>"~driver_exit.txt" echo %ERRORLEVEL%',
        'exit /b 0'
    )) { [void]$launchLines.Add($l) }
    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines $launchLines.ToArray()
    $launch = Invoke-Launch -Dir $dir -LaunchName '~driver_launch.cmd' -LimitMs 480000
    $console = Read-Text (Join-Path $dir '~driver_console.txt')
    $setup = Read-Text (Join-Path $dir '~setup.log')
    $exitText = Read-Text (Join-Path $dir '~driver_exit.txt')
    $status = Read-Text (Join-Path $dir '~bootstrap.status.json')
    $rootExists = Test-Path -LiteralPath $root
    $stubExists = Test-Path -LiteralPath $fakeBat
    $installerExists = Test-Path -LiteralPath (Join-Path $dir 'tmp\miniconda.exe')
    $found = @(Get-OfflineEvictProblems -Finished ([bool]$launch.Finished) -ExitText $exitText -ConsoleText $console -SetupText $setup `
        -FakeBatPath $fakeBat -RootPath $root -RootExists ([bool]$rootExists) -StubExists ([bool]$stubExists) -InstallerExists ([bool]$installerExists))
    Add-Evidence -Title ('offline (' + $launch.Seconds + ' s, launch exit ' + $launch.ExitCode + ', run exit ' + $exitText.Trim() + ')') `
        -Text ("--- status`n" + $status + "`n--- setup log`n" + $setup + "`n--- console`n" + $console) -MaxLines 90
    foreach ($f in $found) { [void]$problems.Add($f) }
    $details['finished'] = [bool]$launch.Finished
    $details['seconds'] = $launch.Seconds
    $details['runExit'] = $exitText.Trim()
    $details['status'] = ([string]$status).Trim()
    $details['rootExists'] = [bool]$rootExists
    if ($launch.Error) { $details['error'] = $launch.Error }
    if ($found.Count -gt 0) { $details['problems'] = @($found) }
    return [pscustomobject]@{ Problems = @($problems); Details = $details }
}

$allPass = $true

$evict   = Get-DriverScenarioResult -Scenario $scenarios[0]
$control = Get-DriverScenarioResult -Scenario $scenarios[1]
$nofresh = Get-DriverScenarioResult -Scenario $scenarios[2]
$offline = Get-OfflineScenarioResult

$installProblems = @($evict.Problems) + @($control.Problems)
$pass = [bool](@($installProblems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.corrupt.conda.evict.install'; req = 'REQ-020.5'; pass = $pass
    desc = 'REQ-020.5: after the answer Y the damaged conda is deleted, the install starts with the folder gone and the run continues with the fresh conda.bat'
    details = [ordered]@{ evict = $evict.Details; control = $control.Details } })

$failProblems = @($nofresh.Problems) + @($offline.Problems)
$pass = [bool](@($failProblems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.corrupt.conda.evict.installfail'; req = 'REQ-020.9'; pass = $pass
    desc = 'REQ-020.9: when no conda exists after the fresh install the run stops with exit code 4 and reports that the fresh install failed'
    details = [ordered]@{ nofresh = $nofresh.Details; offline = $offline.Details } })

if (-not $allPass) { exit 1 }
exit 0
