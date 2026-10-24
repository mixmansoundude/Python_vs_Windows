# ASCII only
# selfapps_unlaunchable_exe.ps1 - CLAUDE.md Item 87: a dist\<env>.exe that Windows cannot start must end the check.
#
# The three bounded-launch helpers (~exe_smokerun.ps1, ~failfast_probe.ps1, ~exe_hint_rerun.ps1) used to call
# Process.Start() without handling a failure. A text file, a zero-byte file or a truncated copy of a program named
# dist\<env>.exe (an interrupted build, an antivirus stub) made Start() throw, and the read loop that follows then
# waited for a process that never ran, forever. The first red-test commit of PR #499 saw it: a text file seeded as the
# EXE kept the step running for over ten minutes until the next push cancelled the run.
#
# Two scenarios, each a real bootstrapper run of the stdlib_single fixture (tests/fixtures/examples), each under a
# 15-minute watchdog so a hang is a red row (timedOut) and not a held job:
#   smoke_stub     HP_TEST_CORRUPT_BUILT_EXE=1 replaces the EXE with a text file right before the verification run of a
#                  fresh build. The check must end, say the program could not be started and why, remove the stub and
#                  check the program through Python instead (README REQ-018.5).
#   fastpath_stub  run 1 builds normally; the EXE is then replaced with a text file (the source hash still says it is
#                  fresh) and run 2 forces the interactive fail-fast probe. The probe must end, the stub must be
#                  discarded and the program rebuilt (README REQ-018.3).
# The third helper (~exe_hint_rerun.ps1) is covered by tests/test_unlaunchable_exe.py; the batch only reaches it for an
# EXE that already ran, so no bootstrapper scenario can start it with a stub.
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text,
# not PowerShell).
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"). Two full builds.
# Emits: self.unlaunchable.smoke_stub, self.unlaunchable.fastpath_stub
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
    Write-NdjsonRow ([ordered]@{ id = 'self.unlaunchable.smoke_stub'; pass = $true; desc = 'Unlaunchable EXE (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.unlaunchable.fastpath_stub'; pass = $true; desc = 'Unlaunchable EXE (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.unlaunchable.smoke_stub'; pass = $false; desc = 'Unlaunchable EXE: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.unlaunchable.fastpath_stub'; pass = $false; desc = 'Unlaunchable EXE: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

$fixture = Join-Path (Join-Path (Join-Path $here 'fixtures') 'examples') 'stdlib_single'
# Cleared in this process and again in the launched shell (SetEnvironmentVariable(name, $null) alone is not trusted,
# see docs/agent-lessons-learned.md). HP_CI_LANE stays: it resolves the optional prompts without a keyboard.
$clearVars = @(
    'HP_SKIP_ENTRY_SMOKE', 'HP_SKIP_EXE_SMOKERUN', 'HP_SKIP_PEP723_WRITEBACK', 'HP_SKIP_AUTOPEP_DISCOVERY',
    'HP_SKIP_PIPREQS', 'HP_FORCE_CONDA_ONLY', 'PVW_PROVIDER', 'HP_DISABLE_HEURISTICS', 'HP_CI_SKIP_ENV',
    'HP_NDJSON', 'HP_TEST_CORRUPT_BUILT_EXE', 'HP_TEST_FORCE_INTERACTIVE_PROBE'
)
$runTimeoutMs = 15 * 60 * 1000

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
}

function Get-ExeFiles {
    param([string]$Work)
    $distDir = Join-Path $Work 'dist'
    if (Test-Path -LiteralPath $distDir) { return @(Get-ChildItem -LiteralPath $distDir -Filter '*.exe' -File) }
    return @()
}

# One bootstrapper run in $Work with no argument. $SetVars are set for this run only; every other name in $clearVars is
# cleared. Returns @{ timedOut; exitCode; boot; setup }; never throws.
function Invoke-Bootstrap {
    param([string]$Work, [string]$LogName, [hashtable]$SetVars)
    $res = @{ timedOut = $false; exitCode = -1; boot = ''; setup = '' }
    try {
        $lines = @('@echo off')
        foreach ($k in $clearVars) { if (-not $SetVars.ContainsKey($k)) { $lines += ('set "' + $k + '="') } }
        $lines += ('call run_setup.bat > ' + $LogName + ' 2>&1 < nul')
        $lines += 'exit /b %ERRORLEVEL%'
        Set-Content -LiteralPath (Join-Path $Work '~unlaunch_launch.cmd') -Value $lines -Encoding ASCII
        $saved = @{}
        foreach ($k in $clearVars) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            if (Test-Path -LiteralPath ('Env:' + $k)) { Remove-Item -LiteralPath ('Env:' + $k) }
        }
        foreach ($k in $SetVars.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$SetVars[$k]) }
        $hadLane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
        if (-not $hadLane) { [Environment]::SetEnvironmentVariable('HP_CI_LANE', 'test') }
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'call ~unlaunch_launch.cmd') -WorkingDirectory $Work -NoNewWindow -PassThru
            $null = $p.Handle   # keeps ExitCode readable after WaitForExit(ms)
            if (-not $p.WaitForExit($runTimeoutMs)) {
                $res.timedOut = $true
                & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
                $null = $p.WaitForExit(30000)
            } else {
                $res.exitCode = $p.ExitCode
            }
        } finally {
            foreach ($k in $SetVars.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
            foreach ($k in $clearVars) {
                if ($null -ne $saved[$k]) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            }
            if (-not $hadLane) { [Environment]::SetEnvironmentVariable('HP_CI_LANE', $null) }
        }
        $res.boot = Read-Text (Join-Path $Work $LogName)
        $res.setup = Read-Text (Join-Path $Work '~setup.log')
    } catch {
        $res.error = $_.Exception.Message
    }
    return $res
}

function New-Scratch {
    param([string]$Name)
    $work = Join-Path $here ('~selftest_unlaunch_' + $Name)
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Copy-Item -Path (Join-Path $fixture '*') -Destination $work -Recurse -Force
    Copy-Item -LiteralPath $batchPath -Destination $work -Force
    return $work
}

function Get-StatusState {
    param([string]$Work)
    $statusPath = Join-Path $Work '~bootstrap.status.json'
    if (Test-Path -LiteralPath $statusPath) {
        try { return [string]((Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { return 'unparseable' }
    }
    return ''
}

function Get-ReasonLine {
    param([string]$Boot)
    $m = [regex]::Match($Boot, '(?m)The reason Windows gave is:\s*\r?\n\s*(.+?)\s*$')
    if ($m.Success) { return (($m.Groups[1].Value) -replace '[^\x20-\x7E]', '?') }
    return ''
}

# ---------------------------------------------------------------- smoke_stub: the verification run of a fresh build
$d = [ordered]@{
    fixtureFound = $false; timedOut = $false; exitCode = -1; statusState = ''; hookFired = $false; launchWarned = $false
    reasonLine = ''; exeFiles = @(); stubRemoved = $false; markerGone = $false; interpreterRan = $false
    entrySmokeExit0 = $false; noTimedOutClaim = $false; runOutOk = $false; error = $null
}
$passSmoke = $false
try {
    $d.fixtureFound = (Test-Path -LiteralPath (Join-Path $fixture 'solo.py'))
    if (-not $d.fixtureFound) { throw 'fixture folder missing: tests/fixtures/examples/stdlib_single' }
    $work = New-Scratch 'smoke'
    $r = Invoke-Bootstrap -Work $work -LogName '~unlaunch_boot.log' -SetVars @{ HP_TEST_CORRUPT_BUILT_EXE = '1'; HP_SKIP_PIPREQS = '1' }
    $d.timedOut = $r.timedOut
    $d.exitCode = $r.exitCode
    $d.statusState = Get-StatusState $work
    $combined = $r.boot + "`n" + $r.setup
    $d.hookFired = [bool]($r.setup -match 'HP_TEST_CORRUPT_BUILT_EXE')
    $d.launchWarned = [bool]($r.boot -match 'could not be started')
    $d.reasonLine = Get-ReasonLine $r.boot
    $d.exeFiles = @(Get-ExeFiles $work | ForEach-Object { $_.Name })
    $d.stubRemoved = ($d.exeFiles.Count -eq 0)
    $d.markerGone = -not (Test-Path -LiteralPath (Join-Path $work '~launch_failed.txt'))
    $d.interpreterRan = [bool]($combined -match 'Running entry script smoke test via \w+ interpreter')
    $d.entrySmokeExit0 = [bool]($combined -match 'Entry smoke exit=0')
    $d.noTimedOutClaim = -not ($r.boot -match 'Run Status: TIMED OUT')
    $d.runOutOk = [bool]((Read-Text (Join-Path $work '~run.out.txt')).Contains('from-single'))
    $passSmoke = (-not $d.timedOut) -and ($d.exitCode -eq 0) -and ($d.statusState -eq 'ok') -and $d.hookFired -and $d.launchWarned -and ($d.reasonLine.Length -gt 0) -and $d.stubRemoved -and $d.markerGone -and $d.interpreterRan -and $d.entrySmokeExit0 -and $d.noTimedOutClaim -and $d.runOutOk
} catch {
    $d.error = $_.Exception.Message
}
Write-NdjsonRow ([ordered]@{
    id = 'self.unlaunchable.smoke_stub'; req = 'REQ-018.5'; pass = [bool]$passSmoke
    desc = 'README REQ-018.5: a freshly built EXE that cannot be started ends the verification run at once, says why, is removed and the program is checked through Python'
    details = $d
})

# ---------------------------------------------------------------- fastpath_stub: the cached EXE under the fail-fast probe
$d = [ordered]@{
    fixtureFound = $false; run1TimedOut = $false; run1Exit = -1; run1ExeBytes = 0; hashFileBefore = $false
    stubSeeded = $false; timedOut = $false; exitCode = -1; statusState = ''; probeLaunched = $false; launchWarned = $false
    reasonLine = ''; discarded = $false; noAliveMsg = $false; rebuiltExeBytes = 0; rebuiltIsReal = $false
    entrySmokeExit0 = $false; error = $null
}
$passFast = $false
try {
    $d.fixtureFound = (Test-Path -LiteralPath (Join-Path $fixture 'solo.py'))
    if (-not $d.fixtureFound) { throw 'fixture folder missing: tests/fixtures/examples/stdlib_single' }
    $work = New-Scratch 'fast'
    $r1 = Invoke-Bootstrap -Work $work -LogName '~unlaunch_run1.log' -SetVars @{ HP_SKIP_PIPREQS = '1' }
    $d.run1TimedOut = $r1.timedOut
    $d.run1Exit = $r1.exitCode
    $exes = @(Get-ExeFiles $work)
    if ($exes.Count -ge 1) { $d.run1ExeBytes = [int64]$exes[0].Length }
    $d.hashFileBefore = (Test-Path -LiteralPath (Join-Path $work '~fast_check.hash.txt'))
    if (($exes.Count -ge 1) -and (-not $r1.timedOut)) {
        # a text file under the EXE's own name; the source hash file is untouched, so run 2 takes the cached-EXE path
        Set-Content -LiteralPath $exes[0].FullName -Value 'this is not a program' -Encoding ASCII
        $d.stubSeeded = ((Get-Item -LiteralPath $exes[0].FullName).Length -lt 100)
        $r2 = Invoke-Bootstrap -Work $work -LogName '~unlaunch_run2.log' -SetVars @{ HP_SKIP_PIPREQS = '1'; HP_TEST_FORCE_INTERACTIVE_PROBE = '1' }
        $d.timedOut = $r2.timedOut
        $d.exitCode = $r2.exitCode
        $d.statusState = Get-StatusState $work
        $combined2 = $r2.boot + "`n" + $r2.setup
        $d.probeLaunched = [bool]($r2.boot -match [regex]::Escape('Launching your program now via the cached standalone EXE'))
        $d.launchWarned = [bool]($r2.boot -match 'could not be started')
        $d.reasonLine = Get-ReasonLine $r2.boot
        $d.discarded = [bool]($r2.boot -match [regex]::Escape('discarding cached EXE and rebuilding'))
        $d.noAliveMsg = -not ($r2.boot -match [regex]::Escape('Fail-fast probe: still running after'))
        $after = @(Get-ExeFiles $work)
        if ($after.Count -ge 1) { $d.rebuiltExeBytes = [int64]$after[0].Length }
        $d.rebuiltIsReal = ($d.rebuiltExeBytes -gt 1000000)
        $d.entrySmokeExit0 = [bool]($combined2 -match 'Entry smoke exit=0')
    }
    $passFast = (-not $d.run1TimedOut) -and ($d.run1Exit -eq 0) -and ($d.run1ExeBytes -gt 1000000) -and $d.hashFileBefore -and $d.stubSeeded -and (-not $d.timedOut) -and ($d.exitCode -eq 0) -and ($d.statusState -eq 'ok') -and $d.probeLaunched -and $d.launchWarned -and ($d.reasonLine.Length -gt 0) -and $d.discarded -and $d.noAliveMsg -and $d.rebuiltIsReal -and $d.entrySmokeExit0
} catch {
    $d.error = $_.Exception.Message
}
Write-NdjsonRow ([ordered]@{
    id = 'self.unlaunchable.fastpath_stub'; req = 'REQ-018.3'; pass = [bool]$passFast
    desc = 'README REQ-018.3: a cached EXE that cannot be started ends the fail-fast probe at once, says why, is discarded and the program is rebuilt'
    details = $d
})

if (-not ($passSmoke -and $passFast)) { exit 1 }
exit 0
