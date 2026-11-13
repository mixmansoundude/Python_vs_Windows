# ASCII only
# selfapps_conda_install_fail.ps1 - Item 46 Batch 6 (docs/plan-die-fatal-remediation.md): a failed Miniconda install must
# not end the run.
#
# :tci_both_failed (both Miniconda install types failed, or AllUsers was skipped and JustMe failed) ends in `call :die`.
# :die is the END of a run: it sets state=error, writes the status file, RELEASES THE LOCK, and waits for a key press
# (README REQ-016.8) unless the CI marker is set. But both callers go on: the main flow tries the next provider (embedded
# Python, venv, system) and the uv to conda cascade keeps the build it already has. So a real user saw "Press any key to
# continue" in the middle of a run that then went on, a second double click could start while the first was still working
# (the lock was gone), and a cascade that was only unavailable turned a good build into state=error.
#
# Two scenarios, one per caller (CONDA_INSTALL_FAIL_SCENARIO, default fallback):
#
# fallback (real lane): a default-order run with uv forced to fail and no network, where the Miniconda installer file
#   already exists (a stub; the JustMe step is forced to fail without starting it, the AllUsers step is skipped as
#   not elevated, so nothing is installed). The run reaches :tci_both_failed from the main flow, then the provider chain.
#   Two runs, each started with every HP_*, PVW_* and NOINPUT variable cleared (the CI marker included, because :die
#   pauses only without it) and standard input closed: a control run (no installer file, so :tci_both_failed is never
#   reached) and the failing run. While a run goes, the script polls ~setup.log; when the line "Attempting venv fallback"
#   appears (it is written AFTER anything :tci_both_failed did, and the venv step takes seconds) it looks at the lock
#   folder once and then stops the run, because nothing later matters.
#   self.conda.installfail.control  the control run: the same observation sees the lock folder in place and no key press
#                                   between the two log lines, so the observation can tell the difference
#   self.conda.installfail.lock     the failing run: the lock folder is still in place when the next provider starts
#   self.conda.installfail.nopause  the failing run: no "Press any key" between the failure message and the next provider
# cascade (contract-uv lane): a program that fails under uv, the last-chance offer answered C (try Miniconda), and the
#   Miniconda download pointed at a local stub (HP_MINICONDA_URL) whose JustMe install is forced to fail. The cascade
#   cannot get Miniconda and must keep the uv build (README REQ-009: a cascade that cannot run keeps the current build).
#   self.conda.installfail.cascade  the setup log says the cascade is unavailable and the build is kept, and the status
#                                   file still reads state ok (not error); the precondition (the failure message and the
#                                   cascade lines) is part of the verdict so a download that never happened cannot pass
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text).
# derived requirement: standard input is closed (< nul), so `pause` returns at once and prints its text, which is the
# evidence; a run that really waited would hit the time limit and be killed.
# Not tested here: the "both AllUsers and JustMe" wording (needs an elevated runner; the log line is the other branch of the
# same `if`), and what the final state is after the venv tier succeeds (the run is stopped before it gets there).
param()
$ErrorActionPreference = 'Continue'
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

$scenario = [Environment]::GetEnvironmentVariable('CONDA_INSTALL_FAIL_SCENARIO')
if (-not $scenario) { $scenario = 'fallback' }
if ($scenario -ne 'fallback' -and $scenario -ne 'cascade') {
    Write-Host ('CONDA_INSTALL_FAIL_SCENARIO must be fallback or cascade, got: ' + $scenario)
    exit 1
}
# Rows for a run that cannot start (not Windows, run_setup.bat missing). The ids stay literal here too, at the call site,
# because the registry scan reads the script text and a shared id variable would hide them.
function Write-PreflightRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    if ($scenario -eq 'cascade') {
        Write-NdjsonRow ([ordered]@{ id = 'self.conda.installfail.cascade'; req = 'REQ-009'; pass = $Pass; desc = $Desc; details = $Details })
        return
    }
    Write-NdjsonRow ([ordered]@{ id = 'self.conda.installfail.control'; req = 'REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.conda.installfail.lock'; req = 'REQ-024'; pass = $Pass; desc = $Desc; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.conda.installfail.nopause'; req = 'REQ-009'; pass = $Pass; desc = $Desc; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-PreflightRows -Pass $true -Desc 'Failed Miniconda install does not end the run (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path -LiteralPath $batchPath)) {
    Write-PreflightRows -Pass $false -Desc 'Failed Miniconda install does not end the run: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

$failMsg = 'Miniconda install failed (AllUsers skipped -- not elevated; JustMe also failed)'
$hookMsg = 'HP_TEST_FORCE_JUSTME_FAIL=1; simulating JustMe install failure'
$venvMsg = 'Attempting venv fallback'
$noCondaMsg = 'conda.bat not found after bootstrap'
$cascadeUnavailable = 'REQ-009: cascade to conda unavailable (Miniconda not installed); keeping current build.'
$timeLimitSec = 600

$evidence = Join-Path $here '~selftest_installfail_evidence'
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

# The text from the first $From up to the first $To after it, or $null when either marker is missing or they are out of
# order, so a log that lost a line cannot pass a "nothing in between" check.
function Get-Between {
    param([string]$Text, [string]$From, [string]$To)
    if (-not $Text) { return $null }
    $i = $Text.IndexOf($From, [System.StringComparison]::Ordinal)
    if ($i -lt 0) { return $null }
    $j = $Text.IndexOf($To, $i + $From.Length, [System.StringComparison]::Ordinal)
    if ($j -lt 0) { return $null }
    return $Text.Substring($i, $j - $i)
}

function ConvertTo-AsciiLine {
    param([string]$Text, [int]$Max = 400)
    if (-not $Text) { return '' }
    $flat = ($Text -replace '\s+', ' ').Trim()
    $flat = [regex]::Replace($flat, '[^\x20-\x7E]', '?')
    if ($flat.Length -gt $Max) { $flat = $flat.Substring(0, $Max) }
    return $flat
}

function Save-Evidence {
    param([string]$Dir, [string]$Prefix, [string[]]$Names)
    foreach ($f in $Names) {
        $src = Join-Path $Dir $f
        if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $evidence ($Prefix + '_' + ($f -replace '^~', ''))) -Force }
    }
}

# ---------------------------------------------------------------------------------------------------- fallback scenario
if ($scenario -eq 'fallback') {
    $flagNames = @()
    foreach ($item in @(Get-ChildItem Env:)) {
        if (($item.Name -match '^(HP_|PVW_)' -or $item.Name -ieq 'NOINPUT') -and $item.Name -match '^[A-Za-z0-9_]+$') { $flagNames += $item.Name }
    }
    $flagNames = @($flagNames | Sort-Object)

    # One run. $FailInstall puts a stub installer file where the bootstrapper looks for the downloaded one and forces the
    # not-elevated and JustMe-fails hooks; without it the run goes down the same chain through "conda.bat not found".
    function Invoke-FallbackRun {
        param([string]$Name, [bool]$FailInstall)
        $dir = Join-Path $here ('~selftest_installfail_' + $Name)
        $scratch = Join-Path $here ('~selftest_installfail_' + $Name + '_scratch')
        foreach ($p in @($dir, $scratch)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $scratch 'tmp') | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $scratch 'public') | Out-Null
        Copy-Item -LiteralPath $batchPath -Destination $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value 'print("installfail app")' -Encoding ASCII
        if ($FailInstall) {
            # Never started: the AllUsers step is skipped (not elevated) and the JustMe step is forced to fail first.
            Set-Content -LiteralPath (Join-Path $scratch 'tmp\miniconda.exe') -Value 'not an installer' -Encoding ASCII
        }
        # TEMP and PUBLIC are private to the run: the installer file is looked for in %TEMP% and Miniconda in
        # %PUBLIC%\Documents, both machine-wide places an earlier step of the job may have used.
        $lines = @('@echo off')
        foreach ($n in $flagNames) { $lines += ('set "' + $n + '="') }
        $lines += ('set "TEMP=' + (Join-Path $scratch 'tmp') + '"')
        $lines += ('set "TMP=' + (Join-Path $scratch 'tmp') + '"')
        $lines += ('set "PUBLIC=' + (Join-Path $scratch 'public') + '"')
        $lines += 'set "HP_OFFLINE_MODE=1"'
        $lines += 'set "HP_TEST_FORCE_UV_FAIL=1"'
        if ($FailInstall) {
            $lines += 'set "HP_TEST_NOT_ELEVATED=1"'
            $lines += 'set "HP_TEST_FORCE_JUSTME_FAIL=1"'
        }
        $lines += 'call run_setup.bat app.py > ~console.log 2>&1 < nul'
        $lines += 'exit /b %ERRORLEVEL%'
        Set-Content -LiteralPath (Join-Path $dir '~installfail_launch.cmd') -Value $lines -Encoding ASCII

        $setupPath = Join-Path $dir '~setup.log'
        $lockDir = Join-Path $dir '~bootstrap.lock'
        $started = Get-Date
        $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', 'call ~installfail_launch.cmd') -WorkingDirectory $dir -NoNewWindow -PassThru
        $sampled = $false
        $lockAtVenv = $null
        $deadline = $started.AddSeconds($timeLimitSec)
        while ((Get-Date) -lt $deadline) {
            $t = Read-Shared $setupPath
            if ($t -and $t.Contains($venvMsg)) {
                # The line is written after everything :tci_both_failed and :die did, and the venv step that follows takes
                # seconds, so this one look is of the state the next provider runs in.
                $lockAtVenv = [bool](Test-Path -LiteralPath $lockDir)
                $sampled = $true
                break
            }
            if ($proc.HasExited) { break }
            Start-Sleep -Milliseconds 100
        }
        $timedOut = (-not $sampled) -and (-not $proc.HasExited)
        if (-not $proc.HasExited) {
            & taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null
            $null = $proc.WaitForExit(30000)
        }
        Start-Sleep -Milliseconds 500
        Save-Evidence -Dir $dir -Prefix $Name -Names @('~console.log', '~setup.log', '~bootstrap.status.json')
        return [pscustomobject]@{
            Console    = (Read-Shared (Join-Path $dir '~console.log'))
            Setup      = (Read-Shared $setupPath)
            Sampled    = $sampled
            LockAtVenv = $lockAtVenv
            TimedOut   = $timedOut
            Seconds    = [int]((Get-Date) - $started).TotalSeconds
        }
    }

    $ctl = Invoke-FallbackRun -Name 'control' -FailInstall $false
    $ctlWindow = Get-Between $ctl.Console $noCondaMsg $venvMsg
    $ctlPass = [bool]($ctl.Sampled -and ($ctl.LockAtVenv -eq $true) -and ($null -ne $ctlWindow) -and ($ctlWindow -notmatch 'Press any key') -and
        ($ctl.Console -notmatch [regex]::Escape($failMsg)))
    Write-NdjsonRow ([ordered]@{
        id = 'self.conda.installfail.control'; req = 'REQ-024'; pass = $ctlPass
        desc = 'control for the failed-install rows: with no installer file the same chain reaches the next provider with the lock folder in place and no key press'
        details = [ordered]@{
            sampled = $ctl.Sampled; lockAtVenv = $ctl.LockAtVenv; timedOut = $ctl.TimedOut; seconds = $ctl.Seconds
            windowFound = [bool]($null -ne $ctlWindow); pauseInWindow = [bool]($ctlWindow -and ($ctlWindow -match 'Press any key'))
            failMessageSeen = [bool]($ctl.Console -and $ctl.Console.Contains($failMsg))
            window = (ConvertTo-AsciiLine $ctlWindow)
        }
    })

    $fl = Invoke-FallbackRun -Name 'fail' -FailInstall $true
    $flWindow = Get-Between $fl.Console $failMsg $venvMsg
    $hookSeen = [bool]($fl.Setup -and $fl.Setup.Contains($hookMsg))
    $failSeen = [bool]($fl.Console -and $fl.Console.Contains($failMsg))
    # The precondition: the run really went through :tci_both_failed and on to the next provider. Without it a run that
    # never reached the failure (an installer file the batch did not find) would pass the two checks below.
    $flPre = $hookSeen -and $failSeen -and $fl.Sampled -and ($null -ne $flWindow)
    $lockPass = [bool]($flPre -and ($fl.LockAtVenv -eq $true))
    Write-NdjsonRow ([ordered]@{
        id = 'self.conda.installfail.lock'; req = 'REQ-024'; pass = $lockPass
        desc = 'a failed Miniconda install does not release the lock: the run goes on with the next provider, so the lock folder is still in place there'
        details = [ordered]@{
            precondition = [bool]$flPre; hookSeen = $hookSeen; failMessageSeen = $failSeen; sampled = $fl.Sampled
            lockAtVenv = $fl.LockAtVenv; controlLockAtVenv = $ctl.LockAtVenv; timedOut = $fl.TimedOut; seconds = $fl.Seconds
        }
    })
    $pausePass = [bool]($flPre -and ($flWindow -notmatch 'Press any key'))
    Write-NdjsonRow ([ordered]@{
        id = 'self.conda.installfail.nopause'; req = 'REQ-009'; pass = $pausePass
        desc = 'a failed Miniconda install does not wait for a key press before the next provider: the key press belongs to the end of the run'
        details = [ordered]@{
            precondition = [bool]$flPre; hookSeen = $hookSeen; failMessageSeen = $failSeen; sampled = $fl.Sampled
            pauseInWindow = [bool]($flWindow -and ($flWindow -match 'Press any key'))
            noCondaMessageSeen = [bool]($fl.Console -and $fl.Console.Contains($noCondaMsg))
            window = (ConvertTo-AsciiLine $flWindow)
        }
    })
    Write-Host '=== installfail evidence: failing run, text from the failure message to the next provider ==='
    Write-Host (ConvertTo-AsciiLine $flWindow 1200)
    if (-not ($ctlPass -and $lockPass -and $pausePass)) { exit 1 }
    exit 0
}

# ----------------------------------------------------------------------------------------------------- cascade scenario
$dir = Join-Path $here '~selftest_installfail_cascade'
$scratch = Join-Path $here '~selftest_installfail_cascade_scratch'
foreach ($p in @($dir, $scratch)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
foreach ($sub in @('tmp', 'public', 'stub')) { New-Item -ItemType Directory -Force -Path (Join-Path $scratch $sub) | Out-Null }
Copy-Item -LiteralPath $batchPath -Destination $dir -Force
# Fails on every run, so the last-chance offer is raised after the uv build; standard library only.
$appFail = @'
import sys

print("installfail cascade app starting")
print("Traceback (most recent call last):", file=sys.stderr)
print("RuntimeError: simulated environment problem", file=sys.stderr)
sys.exit(3)
'@
Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value $appFail -Encoding ASCII
# The "download" is a copy of a local file (never started: the JustMe step is forced to fail before it would be).
$stub = Join-Path $scratch 'stub\Miniconda3-stub.exe'
Set-Content -LiteralPath $stub -Value 'not an installer' -Encoding ASCII
$stubUrl = 'file:///' + ($stub -replace '\\', '/')

$envSet = [ordered]@{
    HP_TEST_LASTCHANCE_ANSWER  = 'C'
    HP_TEST_NOT_ELEVATED       = '1'
    HP_TEST_FORCE_JUSTME_FAIL  = '1'
    HP_MINICONDA_URL           = $stubUrl
    PUBLIC                     = (Join-Path $scratch 'public')
    TEMP                       = (Join-Path $scratch 'tmp')
    TMP                        = (Join-Path $scratch 'tmp')
}
$saved = @{}
foreach ($k in $envSet.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k) }
$runExit = $null
$timedOut = $false
try {
    foreach ($k in $envSet.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$envSet[$k]) }
    $started = Get-Date
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', 'call run_setup.bat app.py > ~console.log 2>&1 < nul') -WorkingDirectory $dir -NoNewWindow -PassThru
    if ($proc.WaitForExit($timeLimitSec * 3 * 1000)) {
        $proc.WaitForExit()
        $runExit = $proc.ExitCode
    } else {
        $timedOut = $true
        & taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null
        $null = $proc.WaitForExit(30000)
    }
} finally {
    foreach ($k in $envSet.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
}
Save-Evidence -Dir $dir -Prefix 'cascade' -Names @('~console.log', '~setup.log', '~bootstrap.status.json')
$console = Read-Shared (Join-Path $dir '~console.log')
$setup = Read-Shared (Join-Path $dir '~setup.log')
$state = $null
$statusPath = Join-Path $dir '~bootstrap.status.json'
if (Test-Path -LiteralPath $statusPath) {
    try { $state = [string]((Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { $state = 'unparseable' }
}
$entryFailed = [bool]($setup -and ($setup -match 'Entry smoke exit=3'))
$approved = [bool]($setup -and $setup.Contains('Last chance: cascade approved') -and $setup.Contains('cascading provider uv to conda'))
$hookSeen = [bool]($setup -and $setup.Contains($hookMsg))
$failSeen = [bool]($setup -and $setup.Contains($failMsg))
$unavailable = [bool]($setup -and $setup.Contains($cascadeUnavailable))
# The precondition: the cascade was approved, asked for Miniconda and met the failed install. Without it a download that
# never happened (no installer file, so :tci_both_failed was never reached) would read as a cascade that kept the build.
$pre = $entryFailed -and $approved -and $hookSeen -and $failSeen
$pass = [bool]($pre -and $unavailable -and ($state -eq 'ok') -and (-not $timedOut))
Write-NdjsonRow ([ordered]@{
    id = 'self.conda.installfail.cascade'; req = 'REQ-009'; pass = $pass
    desc = 'a provider cascade that cannot install Miniconda keeps the uv build and its state ok'
    details = [ordered]@{
        precondition = [bool]$pre; entryFailed = $entryFailed; cascadeApproved = $approved; hookSeen = $hookSeen; failMessageSeen = $failSeen
        cascadeUnavailableLine = $unavailable; statusState = $state; exitCode = $runExit; timedOut = $timedOut
        seconds = [int]((Get-Date) - $started).TotalSeconds; stubUrl = (ConvertTo-AsciiLine $stubUrl 200)
    }
})
Write-Host '=== installfail evidence: cascade run ==='
foreach ($l in (($setup -split "`r?`n") | Where-Object { $_ -match 'Entry smoke|Last chance|cascad|Miniconda|\[ERROR\]|Press any key' } | Select-Object -First 30)) { Write-Host (ConvertTo-AsciiLine $l 300) }
if (-not $pass) { exit 1 }
exit 0
