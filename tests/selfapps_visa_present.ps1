# ASCII only
# selfapps_visa_present.ps1 - Item 122 (README REQ-008.2): an NI-VISA driver that is already installed is neither downloaded nor
# installed again.
#
# Why a row of its own. run_setup.bat looks for the driver in the registry (HKLM\SOFTWARE\National Instruments\NI-VISA, value
# CurrentVersion) before it does anything else about the driver, and logs "[VISA] present" and goes on when the value exists. No row
# ever took that branch: the hosted runners do not have the driver, and a real install attempt there ends with installer exit code
# -125202 (install_failed), so only the failing path was run. Writing the value would need a write to HKLM, which is permanent on a
# hosted runner and needs administrator rights. The shall-level trace test (tests/test_req_shall_trace.py) listed the shall as a gap
# for that reason, and the branch was left untested.
#
# The block between :visa_wanted and :visa_done reads the registry only through two lines that start with reg query (the check
# before the install and the poll after it). The driver replaces both by a call of a stub that answers from the scenario, replaces
# the two download lines (curl, and the PowerShell second method) and the installer call by recording stubs, and replaces the
# subfolder question (:visa_subfolder_gate) by a recording stub, so nothing is downloaded, nothing is installed and nobody is asked
# on the runner. Everything else of the block runs as it is, in a batch file under cmd.exe with closed standard input.
#
# Three rows, one driver each:
#   noinstall  NEED_VISA=1, the registry value is there from the start   -> one "[VISA] present" line, no download, no installer, no skip
#   subfolder  NEED_VISA=2 (the import is only in a subfolder), value there -> the same, and the question of REQ-008.7 is not asked:
#              the check for a present driver comes before the question, so nobody is asked about a step that will not run
#   control    NEED_VISA=1, the value is absent at the first look and there after the installer stub ran -> the same block downloads
#              (curl, once), starts the installer (once), looks again and logs install_success; this is what the first two rows are
#              compared with, so they cannot pass because the block never installs anything
# The ledger of one run is one file the driver, the stubs and the block's own log lines write in order, so the order of the calls is
# the evidence, and the two kinds of text (what a stub recorded, what the block logged) cannot vouch for each other.
#
# Limit, stated so that nobody reads more into the rows than they show: the registry answer is the scenario's, so the rows prove what
# the block does after each answer. That the two lines look at the key and the value the driver of NI-VISA writes is pinned as text
# in tests/test_visa_present.py, and the main flow's call of the block is shown by tests/selfapps_pyvisa_subfolder.ps1 (real
# bootstraps). The real installer is not run (the hosted runners cannot install it).
#
# derived requirement: ids and tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell), and the judging functions take plain values and return a list of problems
# (tests/test_visa_present.py runs them through a real pwsh on synthetic runs).
#
# Lane: contract-uv (the lane with the most wall-clock headroom; the block is the same on every lane). Gating from its first run
# (AGENTS.md "New tests gate immediately"): a red row holds the aggregate check. Three driver runs, seconds each.
# Emits: self.nivisa.present.noinstall, self.nivisa.present.subfolder, self.nivisa.present.control
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

# Used when the three rows share one outcome (a skip, or an input that is missing); the real emissions below are literal too.
function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.present.noinstall'; req = 'REQ-008.2'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.present.subfolder'; req = 'REQ-008.2'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.present.control'; req = 'REQ-008.2'; pass = $Pass; desc = $Desc; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'NI-VISA driver already installed (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'NI-VISA driver already installed: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# ---------------------------------------------------------------------------------------------------------------------
# shared helpers
# ---------------------------------------------------------------------------------------------------------------------
$evidencePath = Join-Path $here '~visa_present_evidence.txt'
Set-Content -LiteralPath $evidencePath -Value 'selfapps_visa_present.ps1 evidence (printable ASCII only)' -Encoding Ascii

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

# ---------------------------------------------------------------------------------------------------------------------
# the scenarios
# ---------------------------------------------------------------------------------------------------------------------
# NeedVisa is the value the main flow hands the block (1: an import next to run_setup.bat, 2: only in a subfolder), RegMode says
# how the stub answers for the registry value: present always, or absent at the first look and present afterwards. Kind says which
# judge applies. tests/test_visa_present.py pins every text below to run_setup.bat.
$scenarios = @(
    [pscustomobject]@{ Name = 'noinstall'; Kind = 'present'; NeedVisa = '1'; RegMode = 'present' },
    [pscustomobject]@{ Name = 'subfolder'; Kind = 'present'; NeedVisa = '2'; RegMode = 'present' },
    [pscustomobject]@{ Name = 'control'; Kind = 'install'; NeedVisa = '1'; RegMode = 'absent_then_present' }
)

# ---------------------------------------------------------------------------------------------------------------------
# judging: plain values in, a list of problems out (nothing when the run shows what the scenario must show)
# ---------------------------------------------------------------------------------------------------------------------
# The calls of the driver's stubs, in order, from the ledger: REG (a look at the registry), CURL, PSDL (the PowerShell download),
# INSTALL (the installer), GATE (the subfolder question). The arguments of a call are not part of its token.
function Get-StubCalls {
    param([string]$LedgerText)
    $calls = New-Object System.Collections.ArrayList
    foreach ($raw in ($LedgerText -split "`r?`n")) {
        $l = $raw.Trim()
        if (($l -eq 'REG') -or ($l -eq 'PSDL') -or ($l -eq 'GATE')) {
            [void]$calls.Add($l)
        } elseif (($l -eq 'CURL') -or ($l -like 'CURL *')) {
            [void]$calls.Add('CURL')
        } elseif (($l -eq 'INSTALL') -or ($l -like 'INSTALL *')) {
            [void]$calls.Add('INSTALL')
        }
    }
    return $calls.ToArray()
}

function Get-PresentProblems {
    param([string]$Scenario, [string]$Kind, [bool]$Finished, [string]$LedgerText, [string]$NeedVisa)
    $out = New-Object System.Collections.ArrayList
    $tag = "NI-VISA present ${Scenario}"
    if (-not $Finished) { [void]$out.Add("${tag}: the driver did not finish within the time limit"); return $out.ToArray() }
    $lines = @(($LedgerText -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $nStart = @($lines | Where-Object { $_ -eq 'START' }).Count
    if ($nStart -ne 1) { [void]$out.Add("${tag}: the driver did not write START exactly once"); return $out.ToArray() }
    $nEnd = @($lines | Where-Object { $_ -eq 'END' }).Count
    if ($nEnd -ne 1) { [void]$out.Add("${tag}: the driver did not reach its end, so the block ended the run early"); return $out.ToArray() }
    $calls = @(Get-StubCalls -LedgerText $LedgerText)
    $nReg = @($calls | Where-Object { $_ -eq 'REG' }).Count
    $nCurl = @($calls | Where-Object { $_ -eq 'CURL' }).Count
    $nPsdl = @($calls | Where-Object { $_ -eq 'PSDL' }).Count
    $nInstall = @($calls | Where-Object { $_ -eq 'INSTALL' }).Count
    $nGate = @($calls | Where-Object { $_ -eq 'GATE' }).Count
    $nPresent = @($lines | Where-Object { $_ -eq 'LOG [VISA] present' }).Count
    $nFileGone = @($lines | Where-Object { $_ -eq 'INSTALLER_FILE=absent' }).Count
    $wantFinished = 'FINISHED NEED_VISA=' + $NeedVisa
    $nFinished = @($lines | Where-Object { $_ -eq $wantFinished }).Count
    if ($nFinished -ne 1) { [void]$out.Add("${tag}: the ledger does not hold '${wantFinished}' exactly once, so NEED_VISA changed or the block ended elsewhere") }
    if ($nGate -ne 0) { [void]$out.Add("${tag}: the block asked the question of the subfolder gate ${nGate} time(s), expected none") }
    if ($nFileGone -ne 1) { [void]$out.Add("${tag}: the installer file ~ni-visa-runtime.exe is left after the block, expected it gone") }
    if ($Kind -eq 'present') {
        # the driver is there: one look at the registry, the log says so once, and nothing is downloaded, started or skipped
        if ($nReg -ne 1) { [void]$out.Add("${tag}: the block looked at the registry ${nReg} time(s), expected once") }
        if ($nPresent -ne 1) { [void]$out.Add("${tag}: the log holds ${nPresent} '[VISA] present' line(s), expected 1") }
        if ($nCurl -ne 0) { [void]$out.Add("${tag}: the block downloaded the installer with curl ${nCurl} time(s) although the driver is installed") }
        if ($nPsdl -ne 0) { [void]$out.Add("${tag}: the block downloaded the installer with PowerShell ${nPsdl} time(s) although the driver is installed") }
        if ($nInstall -ne 0) { [void]$out.Add("${tag}: the block started the installer ${nInstall} time(s) although the driver is installed") }
        $said = @($lines | Where-Object { $_ -match '^LOG \[VISA\] (download method|installer|install_|skipped)' })
        if ($said.Count -gt 0) { [void]$out.Add("${tag}: the log says the driver was downloaded, installed or skipped although it was present: $($said[0])") }
    } else {
        # the control: absent at first, so the block downloads once, starts the installer once, looks again and logs the success
        $calledSeq = ($calls -join ' ')
        if ($calledSeq -ne 'REG CURL INSTALL REG') { [void]$out.Add("${tag}: the block's calls were '${calledSeq}', expected 'REG CURL INSTALL REG'") }
        if ($nPresent -ne 0) { [void]$out.Add("${tag}: the log holds ${nPresent} '[VISA] present' line(s) although the registry answered absent at the first look") }
        $nMethod = @($lines | Where-Object { $_ -eq 'LOG [VISA] download method: curl' }).Count
        if ($nMethod -ne 1) { [void]$out.Add("${tag}: the log holds ${nMethod} 'download method: curl' line(s), expected 1") }
        $nRc = @($lines | Where-Object { $_ -eq 'LOG [VISA] installer exit code: 0' }).Count
        if ($nRc -ne 1) { [void]$out.Add("${tag}: the log holds ${nRc} 'installer exit code: 0' line(s), expected 1") }
        $nSuccess = @($lines | Where-Object { $_ -eq 'LOG [VISA] install_success' }).Count
        if ($nSuccess -ne 1) { [void]$out.Add("${tag}: the log holds ${nSuccess} 'install_success' line(s), expected 1") }
        $nFailed = @($lines | Where-Object { $_ -like 'LOG [[]VISA] install_failed*' }).Count
        if ($nFailed -ne 0) { [void]$out.Add("${tag}: the log holds ${nFailed} 'install_failed' line(s), expected none") }
        $regAt = New-Object System.Collections.ArrayList
        $successAt = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -eq 'REG') { [void]$regAt.Add($i) }
            if (($successAt -lt 0) -and ($lines[$i] -eq 'LOG [VISA] install_success')) { $successAt = $i }
        }
        if (($regAt.Count -eq 2) -and ($successAt -ge 0) -and ($successAt -lt $regAt[1])) {
            [void]$out.Add("${tag}: the success was logged before the second look at the registry")
        }
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------------------------------------------------
# the driver: the real block in a small batch file with stubs for what it reaches
# ---------------------------------------------------------------------------------------------------------------------
# Two lines that start with reg query become a call of :stub_reg_query, the curl line becomes a call of :stub_curl with the same
# arguments, the one line that starts a PowerShell download (Invoke-WebRequest) becomes a call of :stub_ps_download. The PowerShell
# line that only reads the first two bytes of the downloaded file stays real. A line that does not match changes nothing, and the
# counts say how many lines were replaced, so a driver that would have run a real registry query or a real download is not run.
function Convert-VisaBlock {
    param([string[]]$Block)
    $out = New-Object System.Collections.ArrayList
    $counts = [ordered]@{ reg = 0; curl = 0; psdl = 0 }
    foreach ($l in $Block) {
        if ($l -match '^\s*reg\s+query\s') {
            $counts['reg'] = $counts['reg'] + 1
            [void]$out.Add('call :stub_reg_query')
        } elseif ($l -match '^curl\s') {
            $counts['curl'] = $counts['curl'] + 1
            [void]$out.Add(($l -replace '^curl\s+', 'call :stub_curl '))
        } elseif ($l -match '^\s*powershell\s.*Invoke-WebRequest') {
            $counts['psdl'] = $counts['psdl'] + 1
            [void]$out.Add('call :stub_ps_download')
        } else {
            [void]$out.Add($l)
        }
    }
    return [pscustomobject]@{ Lines = $out.ToArray(); Counts = $counts }
}

# The driver clears every variable the block reads, sets the scenario's two values (NEED_VISA and the registry mode), enters the
# block with goto as the main flow does, and ends at the block's own exit label, where it records what is left. The stubs write
# to the ledger; :log is the block's own logger reduced to one ledger line.
function New-PresentDriver {
    param([string]$Dir, $Scenario, [string[]]$Block)
    $lines = New-Object System.Collections.ArrayList
    foreach ($l in @(
        '@echo off', 'setlocal',
        ('set "LEDGER=' + (Join-Path $Dir '~driver_ledger.txt') + '"'),
        ('set "LOG=' + (Join-Path $Dir '~driver.log') + '"'),
        ('set "FLAG_REG=' + (Join-Path $Dir '~reg_seen.flag') + '"'),
        ('set "REG_MODE=' + $Scenario.RegMode + '"'),
        ('set "NEED_VISA=' + $Scenario.NeedVisa + '"'),
        'set "HP_SKIP_NIVISA="', 'set "HP_NIVISA_WAIT_SECS="', 'set "NIVISA_INSTALLER="', 'set "HP_VISA_DLVIA="', 'set "HP_VISA_DLSIZE="',
        'set "HP_VISA_PE="', 'set "HP_VISA_INSTALLER_RC="', 'set "HP_VISA_PINGN="', 'set "HP_VISA_MAXRETRY="', 'set "HP_VISA_RETRY="',
        '>"%LEDGER%" echo START',
        'goto :visa_wanted'
    )) { [void]$lines.Add($l) }
    foreach ($l in $Block) { [void]$lines.Add($l) }
    foreach ($l in @(
        ':visa_done',
        '>>"%LEDGER%" echo FINISHED NEED_VISA=%NEED_VISA%',
        'if exist "~ni-visa-runtime.exe" >>"%LEDGER%" echo INSTALLER_FILE=present',
        'if not exist "~ni-visa-runtime.exe" >>"%LEDGER%" echo INSTALLER_FILE=absent',
        '>>"%LEDGER%" echo END',
        'exit /b 0',
        ':log',
        'setlocal',
        'set "MSG=%~1"',
        '>>"%LEDGER%" echo LOG %MSG%',
        'endlocal',
        'exit /b 0',
        ':stub_reg_query',
        '>>"%LEDGER%" echo REG',
        'if "%REG_MODE%"=="present" exit /b 0',
        'if exist "%FLAG_REG%" exit /b 0',
        '>"%FLAG_REG%" echo seen',
        'exit /b 1',
        ':stub_curl',
        '>>"%LEDGER%" echo CURL %*',
        '>"%NIVISA_INSTALLER%" echo MZ',
        'exit /b 0',
        ':stub_ps_download',
        '>>"%LEDGER%" echo PSDL',
        'exit /b 1',
        ':run_installer_timeout',
        '>>"%LEDGER%" echo INSTALL %*',
        'exit /b 0',
        ':visa_subfolder_gate',
        '>>"%LEDGER%" echo GATE',
        'set "NEED_VISA=1"',
        'exit /b 0'
    )) { [void]$lines.Add($l) }
    return $lines.ToArray()
}

$work = Join-Path $here '~selftest_visapresent'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

# One scenario: one driver run. Returns the problems and the details of the scenario's row.
function Get-ScenarioResult {
    param($Scenario)
    $problems = New-Object System.Collections.ArrayList
    $details = [ordered]@{ scenario = $Scenario.Name }
    $block = Get-BatBlock -StartLabel ':visa_wanted' -EndLabel ':visa_done'
    if ($null -eq $block) {
        [void]$problems.Add('the label :visa_wanted (up to :visa_done) is not in run_setup.bat, so there is no block to test')
        $details['blockFound'] = $false
        return [pscustomobject]@{ Problems = @($problems); Details = $details }
    }
    $converted = Convert-VisaBlock -Block $block
    $details['replaced'] = [ordered]@{ regQuery = $converted.Counts['reg']; curl = $converted.Counts['curl']; powershellDownload = $converted.Counts['psdl'] }
    if (($converted.Counts['reg'] -ne 2) -or ($converted.Counts['curl'] -ne 1) -or ($converted.Counts['psdl'] -ne 1)) {
        [void]$problems.Add("the block no longer holds exactly 2 reg query lines, 1 curl line and 1 PowerShell download line (found $($converted.Counts['reg']), $($converted.Counts['curl']) and $($converted.Counts['psdl'])), so the driver was not run: it would reach the real registry or the network")
        return [pscustomobject]@{ Problems = @($problems); Details = $details }
    }
    $dir = Join-Path $work $Scenario.Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines (New-PresentDriver -Dir $dir -Scenario $Scenario -Block $converted.Lines)
    Write-CrLf -Path (Join-Path $dir '~driver_launch.cmd') -Lines @('@echo off', 'call ~driver.bat > ~driver_console.txt 2>&1 < nul', '>"~driver_exit.txt" echo %ERRORLEVEL%', 'exit /b 0')
    $launch = Invoke-Launch -Dir $dir -LaunchName '~driver_launch.cmd' -LimitMs 180000
    $ledger = Read-Text (Join-Path $dir '~driver_ledger.txt')
    $exitText = Read-Text (Join-Path $dir '~driver_exit.txt')
    $console = Read-Text (Join-Path $dir '~driver_console.txt')
    $found = @(Get-PresentProblems -Scenario $Scenario.Name -Kind $Scenario.Kind -Finished ([bool]$launch.Finished) -LedgerText $ledger -NeedVisa $Scenario.NeedVisa)
    Add-Evidence -Title ($Scenario.Name + ' (' + $launch.Seconds + ' s, launch exit ' + $launch.ExitCode + ', driver exit ' + $exitText.Trim() + ')') `
        -Text ("--- ledger`n" + $ledger + "`n--- console`n" + $console) -MaxLines 70
    foreach ($f in $found) { [void]$problems.Add($f) }
    $details['finished'] = [bool]$launch.Finished
    $details['seconds'] = $launch.Seconds
    $details['driverExit'] = $exitText.Trim()
    $details['stubCalls'] = (@(Get-StubCalls -LedgerText $ledger) -join ' ')
    if ($launch.Error) { $details['error'] = $launch.Error }
    if ($found.Count -gt 0) { $details['problems'] = @($found); $details['ledger'] = @(($ledger -split "`r?`n") | Where-Object { $_ }) }
    return [pscustomobject]@{ Problems = @($problems); Details = $details }
}

$allPass = $true

$noinstall = Get-ScenarioResult -Scenario $scenarios[0]
$subfolder = Get-ScenarioResult -Scenario $scenarios[1]
$control   = Get-ScenarioResult -Scenario $scenarios[2]

$pass = [bool](@($noinstall.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.present.noinstall'; req = 'REQ-008.2'; pass = $pass
    desc = 'An NI-VISA driver that is already installed is logged as present and is neither downloaded nor installed again'; details = $noinstall.Details })

$pass = [bool](@($subfolder.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.present.subfolder'; req = 'REQ-008.2'; pass = $pass
    desc = 'With the driver already installed and the import only in a subfolder nothing is downloaded or installed and the subfolder question is not asked'; details = $subfolder.Details })

$pass = [bool](@($control.Problems).Count -eq 0)
if (-not $pass) { $allPass = $false }
Write-NdjsonRow ([ordered]@{ id = 'self.nivisa.present.control'; req = 'REQ-008.2'; pass = $pass
    desc = 'Control: with the driver absent at the first look the same block downloads it once, starts the installer once and logs the success'; details = $control.Details })

if (-not $allPass) { exit 1 }
exit 0
