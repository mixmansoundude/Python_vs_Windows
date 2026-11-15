# ASCII only
# selfapps_venv_probe.ps1 - Item 113: README REQ-023 (venv fallback canary probe) shown with the real probe command.
#
# What was missing (docs/plan-test-suite-gaps.md, REQ-023.1): the only row about the probe (self.venv.canary_fail in
# selfapps_ux_hardening.ps1) forces its failure with a hook that jumps past the probe command, so no row ever ran the
# real `"%HP_PY%" -c "import sys"` line, and no row ever gave it a result other than success. The README says the venv
# is selected only when that command exits with code 0 (REQ-023.2), and a venv that cannot run because a DLL is missing
# makes the interpreter exit with a NEGATIVE code (0xC0000135 reads as -1073741515 to cmd.exe), which `if errorlevel 1`
# does not see: it is true only for a code of 1 or more.
#
# How: the REAL block `:try_venv_fallback` is cut out of run_setup.bat (the technique of selfapps_net_resilience.ps1),
# wrapped in a tiny driver batch file and run by cmd.exe. The "system Python" it creates the venv with is a small
# compiled stub (csc) copied as python.exe into the scenario folder. When it is called as `-m venv .\.venv` it builds
# .venv\Scripts\python.exe as a copy of itself; every call, by whichever copy, is written to one ledger with the full path
# of the program that ran, and a call such as `-c "import sys"` exits with the code the scenario chose. The driver's :log
# writes into the same ledger, so the order of the probe and of the lines that select the venv is read from one file.
# No network, no Python and no provider are involved.
#
# Rows (all real lane, gating through the aggregate check):
#   self.venvprobe.command   REQ-023.1   a healthy venv: created, then probed once with `-c import sys`, then selected
#   self.venvprobe.nofile    REQ-023.1   the creation leaves no interpreter file: no probe, no selection
#   self.venvprobe.declines  REQ-023.2, .3   a probe that exits 1, 2 or 255: warning, not selected, tier fails
#   self.venvprobe.crash     REQ-023.2, .3   a probe that exits -1, -1073741515 or -1073741819: the same
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path -LiteralPath $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

$script:LaneTag = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
$script:AnyRowFailed = $false
function Write-NdjsonRow {
    param([hashtable]$Row)
    if ($Row.ContainsKey('pass') -and -not $Row['pass']) { $script:AnyRowFailed = $true }
    if ($script:LaneTag -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $script:LaneTag }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

# derived requirement: tools/check_ndjson_registry.py finds a row id only as a quoted string right after the id key, and
# tests/test_req_trace.py reads the req tag the same way, so each call below spells both out in quotes.
function Write-AllRows {
    param([bool]$Pass, $Details)
    Write-NdjsonRow ([ordered]@{ id = 'self.venvprobe.command'; req = 'REQ-023.1'; pass = $Pass; desc = 'venv fallback: after the venv is created, the interpreter in it is run once with a command that imports sys, before the venv is selected'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.venvprobe.nofile'; req = 'REQ-023.1'; pass = $Pass; desc = 'venv fallback: when the creation leaves no interpreter file the probe is not run and the venv is not selected'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.venvprobe.declines'; req = 'REQ-023.2, REQ-023.3'; pass = $Pass; desc = 'venv fallback: a probe that exits 1, 2 or 255 is logged as a warning, the venv is not selected and the tier fails'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.venvprobe.crash'; req = 'REQ-023.2, REQ-023.3'; pass = $Pass; desc = 'venv fallback: a probe that crashes with a negative exit code (missing DLL, access violation) is logged as a warning, the venv is not selected and the tier fails'; details = $Details })
}

# --- the judging functions: plain values in, a list of problems out (tests/test_venv_probe.py runs them in a real pwsh on
# --- synthetic ledgers, so a reworded line or a wrong comparison cannot hide behind scenarios that happen to pass) ---------
# The ledger (one line per event, in the order they happened):
#   CALL|<full path of the program that ran>|<its arguments joined with |>     written by the stub
#   LOG: <text>                                                                written by the driver's :log
#   RC=<errorlevel> / HPPY=<value> / HPENV=<value>                             written by the driver after the block returned
function Get-ProbeFacts {
    param([string[]]$Lines)
    $suffix = '\.venv\Scripts\python.exe'
    $creates = 0
    $createAt = -1
    $venvCalls = 0
    $probeAt = New-Object System.Collections.Generic.List[int]
    $readyAt = -1
    $selectedAt = -1
    $warnAt = -1
    $missingAt = -1
    $getpipAt = -1
    $rcValue = ''
    $hpPyValue = ''
    $hpEnvValue = ''
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        $line = $Lines[$i]
        if ($line.StartsWith('CALL|')) {
            $rest = $line.Substring(5)
            $sep = $rest.IndexOf('|')
            if ($sep -lt 0) { continue }
            $exeValue = $rest.Substring(0, $sep)
            $callArgs = $rest.Substring($sep + 1)
            if ($callArgs -ceq '-m|venv|.\.venv') {
                $creates = $creates + 1
                if ($createAt -lt 0) { $createAt = $i }
            }
            if ($exeValue.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $venvCalls = $venvCalls + 1
                if ($callArgs -ceq '-c|import sys') { $probeAt.Add($i) }
            }
        } elseif ($line.StartsWith('LOG: [INFO] venv fallback ready:')) {
            if ($readyAt -lt 0) { $readyAt = $i }
        } elseif ($line -ceq 'LOG: [BOOT] REQ-009: Selected Python provider: Local venv (fallback).') {
            if ($selectedAt -lt 0) { $selectedAt = $i }
        } elseif ($line -ceq 'LOG: [WARN] venv fallback: interpreter created but failed canary probe (import sys).') {
            if ($warnAt -lt 0) { $warnAt = $i }
        } elseif ($line -ceq 'LOG: [WARN] venv fallback: interpreter missing after creation.') {
            if ($missingAt -lt 0) { $missingAt = $i }
        } elseif ($line -ceq 'LOG: download_get_pip was reached') {
            if ($getpipAt -lt 0) { $getpipAt = $i }
        } elseif ($line.StartsWith('RC=')) {
            $rcValue = $line.Substring(3).Trim()
        } elseif ($line.StartsWith('HPPY=')) {
            $hpPyValue = $line.Substring(5).Trim()
        } elseif ($line.StartsWith('HPENV=')) {
            $hpEnvValue = $line.Substring(6).Trim()
        }
    }
    return [pscustomobject][ordered]@{
        creates = $creates
        createAt = $createAt
        venvCalls = $venvCalls
        probeCalls = $probeAt.Count
        probeAt = $(if ($probeAt.Count -gt 0) { $probeAt[0] } else { -1 })
        readyAt = $readyAt
        selectedAt = $selectedAt
        warnAt = $warnAt
        missingAt = $missingAt
        getpipAt = $getpipAt
        rc = $rcValue
        hpPyEndsInVenv = $hpPyValue.EndsWith($suffix, [System.StringComparison]::OrdinalIgnoreCase)
        hpPyEmpty = ($hpPyValue -eq '')
        hpEnvMode = $hpEnvValue
    }
}

function Get-ProbeProblems {
    param([string]$Kind, $Facts)
    $problems = New-Object System.Collections.Generic.List[string]
    if ($Facts.creates -ne 1) { $problems.Add('the venv was created ' + $Facts.creates + ' times, expected exactly once') }
    if ($Facts.getpipAt -ge 0) { $problems.Add('the get-pip.py retry path was reached, so the creation did not go as the scenario planned') }
    if ($Kind -eq 'healthy') {
        if ($Facts.probeCalls -ne 1) { $problems.Add('the interpreter in the venv was probed with -c "import sys" ' + $Facts.probeCalls + ' times, expected exactly once') }
        if ($Facts.venvCalls -ne 1) { $problems.Add('the interpreter in the venv was started ' + $Facts.venvCalls + ' times in all, expected only the probe') }
        if (($Facts.probeCalls -ge 1) -and ($Facts.createAt -ge $Facts.probeAt)) { $problems.Add('the probe came before the creation of the venv') }
        if ($Facts.readyAt -lt 0) { $problems.Add('no "venv fallback ready" line was logged') }
        if ($Facts.selectedAt -lt 0) { $problems.Add('the venv was not reported as the selected provider') }
        if (($Facts.probeCalls -ge 1) -and ($Facts.readyAt -ge 0) -and ($Facts.readyAt -lt $Facts.probeAt)) { $problems.Add('the venv was reported ready before the probe ran') }
        if (($Facts.probeCalls -ge 1) -and ($Facts.selectedAt -ge 0) -and ($Facts.selectedAt -lt $Facts.probeAt)) { $problems.Add('the venv was reported selected before the probe ran') }
        if ($Facts.warnAt -ge 0) { $problems.Add('a healthy venv was reported as having failed the probe') }
        if ($Facts.rc -ne '0') { $problems.Add('the tier returned ' + $Facts.rc + ', expected 0') }
        if (-not $Facts.hpPyEndsInVenv) { $problems.Add('HP_PY does not name the interpreter inside .venv after a healthy probe') }
        if ($Facts.hpEnvMode -ne 'venv') { $problems.Add('HP_ENV_MODE is "' + $Facts.hpEnvMode + '", expected venv') }
    } elseif ($Kind -eq 'declined') {
        if ($Facts.probeCalls -ne 1) { $problems.Add('the interpreter in the venv was probed with -c "import sys" ' + $Facts.probeCalls + ' times, expected exactly once') }
        if (($Facts.probeCalls -ge 1) -and ($Facts.createAt -ge $Facts.probeAt)) { $problems.Add('the probe came before the creation of the venv') }
        if ($Facts.warnAt -lt 0) { $problems.Add('no warning said the interpreter was created but failed the probe') }
        if (($Facts.probeCalls -ge 1) -and ($Facts.warnAt -ge 0) -and ($Facts.warnAt -lt $Facts.probeAt)) { $problems.Add('the warning was written before the probe ran') }
        if ($Facts.readyAt -ge 0) { $problems.Add('a "venv fallback ready" line was logged for a venv whose probe did not exit 0') }
        if ($Facts.selectedAt -ge 0) { $problems.Add('the venv was reported as the selected provider although its probe did not exit 0') }
        if ($Facts.rc -ne '1') { $problems.Add('the tier returned ' + $Facts.rc + ', expected 1 so that the next provider is tried') }
        if (-not $Facts.hpPyEmpty) { $problems.Add('HP_PY still names the failed venv, so a later check would take it for a selected provider') }
        if ($Facts.hpEnvMode -ne '') { $problems.Add('HP_ENV_MODE is "' + $Facts.hpEnvMode + '", expected it to stay unset') }
    } elseif ($Kind -eq 'nofile') {
        if ($Facts.probeCalls -ne 0) { $problems.Add('the interpreter was probed ' + $Facts.probeCalls + ' times although the creation left no interpreter file') }
        if ($Facts.venvCalls -ne 0) { $problems.Add('something ran inside .venv although the creation left no interpreter file') }
        if ($Facts.missingAt -lt 0) { $problems.Add('no warning said the interpreter was missing after creation') }
        if ($Facts.readyAt -ge 0) { $problems.Add('a "venv fallback ready" line was logged for a venv without an interpreter') }
        if ($Facts.selectedAt -ge 0) { $problems.Add('the venv was reported as the selected provider without an interpreter') }
        if ($Facts.rc -ne '1') { $problems.Add('the tier returned ' + $Facts.rc + ', expected 1 so that the next provider is tried') }
        if ($Facts.hpEnvMode -ne '') { $problems.Add('HP_ENV_MODE is "' + $Facts.hpEnvMode + '", expected it to stay unset') }
    } else {
        $problems.Add('unknown scenario kind ' + $Kind)
    }
    return @($problems.ToArray())
}

function Get-ProbeVerdict {
    param([string]$Kind, [string[]]$Lines)
    $facts = Get-ProbeFacts -Lines $Lines
    $problems = @(Get-ProbeProblems -Kind $Kind -Facts $facts)
    return [pscustomobject][ordered]@{ facts = $facts; problems = $problems }
}

function Test-ScenarioOk {
    param($Scenario)
    if ($Scenario.timedOut) { return $false }
    if ($Scenario.driverExit -ne 0) { return $false }
    if (@($Scenario.problems).Count -gt 0) { return $false }
    return $true
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path -LiteralPath $batchPath)) {
    Write-AllRows -Pass $false -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# A variable the product reads must not come from the job: the scenarios start cmd.exe children that inherit this process.
$scrubPattern = '^(HP_|PVW_|VP_|NOINPUT$|NoDefaultCurrentDirectoryInExePath$)'
foreach ($v in @(Get-ChildItem Env: | Where-Object { $_.Name -match $scrubPattern })) {
    Remove-Item -LiteralPath ('Env:' + $v.Name) -ErrorAction SilentlyContinue
}

$work = Join-Path $here '~selftest_venvprobe'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

$batLines = [System.IO.File]::ReadAllLines($batchPath)

# Lines from the line that is exactly StartLine up to, not including, the line that is exactly EndLine.
function Get-BatBlock {
    param([string]$StartLine, [string]$EndLine)
    $start = -1
    for ($i = 0; $i -lt $batLines.Length; $i++) {
        if ($batLines[$i].Trim() -eq $StartLine) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = -1
    for ($j = $start + 1; $j -lt $batLines.Length; $j++) {
        if ($batLines[$j].Trim() -eq $EndLine) { $end = $j; break }
    }
    if ($end -lt 0) { return $null }
    return $batLines[$start..($end - 1)]
}

$venvBlock = Get-BatBlock -StartLine ':try_venv_fallback' -EndLine ':try_system_fallback'
if (-not $venvBlock) {
    Write-AllRows -Pass $false -Details ([ordered]@{ error = 'could not cut :try_venv_fallback out of run_setup.bat; the lines the harness needs moved' })
    exit 1
}

function Write-CrLf {
    param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
}

# --- the stub program: the "system Python" the venv is made with, and later the interpreter inside the venv ---------------
# Every call is written to the ledger first. `-m venv ...` builds .venv\Scripts\python.exe as a copy of this program
# (VP_VENV_MODE=nofile builds the folder and no file). Any other call exits with VP_PROBE_EXIT, which may be negative.
$stubSource = @'
using System;
using System.IO;
public static class Stub
{
    public static int Main(string[] args)
    {
        string exe = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string ledger = Environment.GetEnvironmentVariable("VP_LEDGER");
        if (!string.IsNullOrEmpty(ledger))
        {
            File.AppendAllText(ledger, "CALL|" + exe + "|" + string.Join("|", args) + "\r\n");
        }
        if (args.Length >= 2 && args[0] == "-m" && args[1] == "venv")
        {
            string scripts = Path.Combine(Directory.GetCurrentDirectory(), ".venv", "Scripts");
            Directory.CreateDirectory(scripts);
            if (Environment.GetEnvironmentVariable("VP_VENV_MODE") != "nofile")
            {
                File.Copy(exe, Path.Combine(scripts, "python.exe"), true);
            }
            return 0;
        }
        string code = Environment.GetEnvironmentVariable("VP_PROBE_EXIT");
        if (string.IsNullOrEmpty(code)) { return 0; }
        return int.Parse(code);
    }
}
'@

$stubDir = Join-Path $work '~stubbuild'
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
$stubExe = Join-Path $stubDir 'stub.exe'
$stubBuild = [ordered]@{ ok = $false; reason = 'not-built' }
$csc = $null
foreach ($candidate in @((Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'), (Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))) {
    if ((-not $csc) -and (Test-Path -LiteralPath $candidate)) { $csc = $candidate }
}
if ($csc) {
    $srcPath = Join-Path $stubDir 'stub.cs'
    [System.IO.File]::WriteAllText($srcPath, $stubSource, [System.Text.Encoding]::ASCII)
    $cscOut = & $csc /nologo /target:exe ('/out:' + $stubExe) $srcPath 2>&1
    $stubBuild = [ordered]@{ ok = (Test-Path -LiteralPath $stubExe); reason = 'csc'; cscOutput = (($cscOut | Out-String).Trim()) }
} else {
    $stubBuild = [ordered]@{ ok = $false; reason = 'csc-not-found' }
}
if (-not $stubBuild.ok) {
    Write-AllRows -Pass $false -Details ([ordered]@{ error = 'the stub program could not be built'; stub = $stubBuild })
    exit 1
}

# Starts the driver, waits for it (a hang is killed with its children and reported), and returns how it ended.
function Invoke-Driver {
    param([string]$Dir, [int]$TimeoutSec = 120)
    $driver = Join-Path $Dir '~driver.bat'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c "' + $driver + '"') -WorkingDirectory $Dir -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $Dir '~driver_console.txt') -RedirectStandardError (Join-Path $Dir '~driver_console_err.txt')
    $null = $p.Handle
    $timedOut = $false
    while (-not $p.HasExited) {
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            $timedOut = $true
            & taskkill /F /T /PID $p.Id 2>&1 | Out-Null
            break
        }
        Start-Sleep -Milliseconds 50
    }
    $null = $p.WaitForExit(15000)
    return [ordered]@{
        exitCode = $(if ($p.HasExited) { $p.ExitCode } else { -1 })
        timedOut = $timedOut
        seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

# One scenario: a fresh folder with the stub as python.exe, the driver around the cut-out block, the ledger read back.
function Invoke-VenvScenario {
    param([string]$Name, [string]$Kind, [string]$ProbeExit, [string]$VenvMode)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $python = Join-Path $dir 'python.exe'
    Copy-Item -LiteralPath $stubExe -Destination $python -Force
    $ledger = Join-Path $dir '~ledger.txt'
    $head = @(
        '@echo off',
        'setlocal',
        ('set "LOG=' + (Join-Path $dir '~driver.log') + '"'),
        ('set "VP_LEDGER=' + $ledger + '"'),
        ('set "VP_PROBE_EXIT=' + $ProbeExit + '"'),
        ('set "VP_VENV_MODE=' + $VenvMode + '"'),
        'call :try_venv_fallback',
        '>> "%VP_LEDGER%" echo RC=%ERRORLEVEL%',
        '>> "%VP_LEDGER%" echo HPPY=%HP_PY%',
        '>> "%VP_LEDGER%" echo HPENV=%HP_ENV_MODE%',
        'exit /b 0',
        ':log',
        '>> "%VP_LEDGER%" echo LOG: %~1',
        'exit /b 0',
        ':resolve_system_python',
        ('set "HP_SYS_CMD=' + $python + '"'),
        'set "HP_SYS_ARGS="',
        ('set "HP_SYS_EXE=' + $python + '"'),
        'exit /b 0',
        ':download_get_pip',
        '>> "%VP_LEDGER%" echo LOG: download_get_pip was reached',
        'exit /b 0'
    )
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines ($head + $venvBlock)
    $run = Invoke-Driver -Dir $dir
    $lines = @()
    if (Test-Path -LiteralPath $ledger) { $lines = @(Get-Content -LiteralPath $ledger) }
    $verdict = Get-ProbeVerdict -Kind $Kind -Lines $lines
    return [ordered]@{
        name = $Name
        kind = $Kind
        probeExit = $ProbeExit
        driverExit = $run.exitCode
        timedOut = $run.timedOut
        seconds = $run.seconds
        facts = $verdict.facts
        problems = @($verdict.problems)
        ledger = @($lines)
    }
}

function Test-AllOk {
    param($Scenarios)
    foreach ($s in @($Scenarios)) {
        if (-not (Test-ScenarioOk -Scenario $s)) { return $false }
    }
    return $true
}

$healthy = Invoke-VenvScenario -Name 'healthy' -Kind 'healthy' -ProbeExit '0' -VenvMode 'ok'
$nofile  = Invoke-VenvScenario -Name 'nofile' -Kind 'nofile' -ProbeExit '0' -VenvMode 'nofile'
$declined = @()
foreach ($code in @('1', '2', '255')) {
    $declined += , (Invoke-VenvScenario -Name ('declined_' + $code) -Kind 'declined' -ProbeExit $code -VenvMode 'ok')
}
# 0xFFFFFFFF, 0xC0000135 (STATUS_DLL_NOT_FOUND, a venv python.exe that cannot load its runtime) and 0xC0000005 (access violation),
# as cmd.exe reports them: negative, which `if errorlevel 1` does not catch.
$crashed = @()
foreach ($code in @('-1', '-1073741515', '-1073741819')) {
    $crashed += , (Invoke-VenvScenario -Name ('crash_' + ($code -replace '^-', 'm')) -Kind 'declined' -ProbeExit $code -VenvMode 'ok')
}

Write-NdjsonRow ([ordered]@{ id = 'self.venvprobe.command'; req = 'REQ-023.1'; pass = (Test-AllOk -Scenarios @($healthy)); desc = 'venv fallback: after the venv is created, the interpreter in it is run once with a command that imports sys, before the venv is selected'; details = $healthy })
Write-NdjsonRow ([ordered]@{ id = 'self.venvprobe.nofile'; req = 'REQ-023.1'; pass = (Test-AllOk -Scenarios @($nofile)); desc = 'venv fallback: when the creation leaves no interpreter file the probe is not run and the venv is not selected'; details = $nofile })
Write-NdjsonRow ([ordered]@{ id = 'self.venvprobe.declines'; req = 'REQ-023.2, REQ-023.3'; pass = (Test-AllOk -Scenarios $declined); desc = 'venv fallback: a probe that exits 1, 2 or 255 is logged as a warning, the venv is not selected and the tier fails'; details = [ordered]@{ scenarios = $declined } })
Write-NdjsonRow ([ordered]@{ id = 'self.venvprobe.crash'; req = 'REQ-023.2, REQ-023.3'; pass = (Test-AllOk -Scenarios $crashed); desc = 'venv fallback: a probe that crashes with a negative exit code (missing DLL, access violation) is logged as a warning, the venv is not selected and the tier fails'; details = [ordered]@{ scenarios = $crashed } })

if ($script:AnyRowFailed) { exit 1 }
exit 0
