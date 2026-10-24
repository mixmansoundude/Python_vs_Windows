# ASCII only
# selfapps_nuitka_cachesafety.ps1 - Item 72 follow-up: what a static Nuitka unpack folder would break.
#
# Background: a Nuitka --onefile EXE unpacks into a fresh %TEMP%\onefile_* folder on EVERY launch. The Item 72
# experiment (selfapps_nuitka_launchcache.ps1, docs/plan-field-report-2026-10.md) showed that a static
# --onefile-tempdir-spec makes later launches about 3.7 times faster and that a same-spec rebuild runs the NEW
# code. This script measures what that static folder costs, with the production flag text plus
# --onefile-tempdir-spec={CACHE_DIR}/PVW/safety-<token> (the build is independent of run_setup.bat's command
# lines, which carry no such flag):
#   warm concurrent   three copies started at once with the folder already unpacked
#   cold concurrent   three copies started at once with no folder, three rounds
#   overlap           a second and third copy started while the first still runs
#   kill recovery     a launch killed in the middle of unpacking, then a normal launch, five times
#   update            a NEW build of the same spec started while the OLD build is still running
#
# FINDING (run 40043297712, Nuitka 4.3.1, 2026-10-24): warm concurrent, overlap and kill recovery are fine, but with
# the folder cold one of three simultaneous launches exits 2 with "failed to open '<folder>\vcruntime140_1.dll' for
# writing" (the launch that arrives second tries to write a file the first one has already loaded). The flag
# was therefore NOT adopted. Revisit it only when this row says adoptable is true; see docs/agent-cold-storage.md.
#
# The row passes when the experiment ran and every check the finding relies on held (build, baseline, warm
# concurrent, overlap, kill recovery, and a normal launch after every cold round). The cold concurrent rounds
# and the update scenario are RECORDED, not asserted: coldConcurrentOk / updateWhileRunningOk / adoptable say
# what this runner saw, and a red cold round is the known finding, not a failure of the test.
#
# Non-gating (uv lane): two real Nuitka builds and a possible compiler download can fail from network or provider
# problems.
#
# Emits: self.nuitka.cachesafety
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

function Write-SafetyRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.nuitka.cachesafety'; req = 'REQ-AV'; pass = $Pass; desc = $Desc; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-SafetyRow -Pass $true -Desc 'Nuitka unpack cache safety (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-SafetyRow -Pass $false -Desc 'Nuitka unpack cache safety: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# The flags run_setup.bat passes before the output name; the safety builds take theirs from this text so the
# build under test is the production one (only the output folder, the data file and the spec differ).
$prodFlags = '-m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist'

function Remove-Folder {
    # A folder can be held briefly by a process that is still exiting; retry before giving up.
    param([string]$Path)
    for ($i = 0; $i -lt 15; $i++) {
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $Path)) { return $true }
        Start-Sleep -Milliseconds 300
    }
    return (-not (Test-Path -LiteralPath $Path))
}

function Get-FolderBytes {
    param([string]$Path)
    $sum = [int64]0
    try {
        foreach ($f in [System.IO.Directory]::EnumerateFiles($Path, '*', [System.IO.SearchOption]::AllDirectories)) {
            try { $sum += (New-Object System.IO.FileInfo $f).Length } catch { }
        }
    } catch { }
    return $sum
}

function Start-App {
    param([string]$Exe, [string]$ArgText = '')
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $ArgText
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = [System.Diagnostics.Process]::Start($psi)
    return [pscustomobject]@{ Proc = $p; Out = $p.StandardOutput.ReadToEndAsync(); Err = $p.StandardError.ReadToEndAsync(); Watch = $sw }
}

function Wait-App {
    param($H, [int]$TimeoutMs = 180000)
    $timedOut = $false
    if (-not $H.Proc.WaitForExit($TimeoutMs)) {
        $timedOut = $true
        & taskkill /F /T /PID $H.Proc.Id 2>&1 | Out-Null
        $H.Proc.WaitForExit(10000) | Out-Null
    } else {
        $H.Proc.WaitForExit()
    }
    $H.Watch.Stop()
    $out = ''; $err = ''
    if (-not $timedOut) { $out = "$($H.Out.Result)".Trim(); $err = "$($H.Err.Result)".Trim() }
    return [ordered]@{ exit = $(if ($timedOut) { -1 } else { $H.Proc.ExitCode }); timedOut = $timedOut; out = $out; err = $err; ms = [int]$H.Watch.ElapsedMilliseconds }
}

function Stop-AppTree {
    # True only when the process is confirmed gone: a kill that did not take must not count as a kill that was tested.
    param($H)
    try { & taskkill /F /T /PID $H.Proc.Id 2>&1 | Out-Null } catch { }
    $gone = $false
    try { $gone = [bool]$H.Proc.WaitForExit(10000) } catch { }
    return $gone
}

$workDir = Join-Path $here '~selftest_nuitka_cachesafety'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force
Set-Content -Path (Join-Path $workDir 'app.py') -Value 'print("nuitka-cachesafety-ok")' -Encoding ASCII

$cacheRoot = Join-Path $env:LOCALAPPDATA 'PVW'
$bootstrapLog = '~cachesafety_bootstrap.log'

$prevSkipPipreqs   = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevForceExecfail = if (Test-Path Env:HP_TEST_FORCE_PYINSTALLER_FAIL) { $env:HP_TEST_FORCE_PYINSTALLER_FAIL } else { $null }
$env:HP_SKIP_PIPREQS = '1'
$env:HP_TEST_FORCE_PYINSTALLER_FAIL = '1'

$dSafe = [ordered]@{}
$safePass = $false
$rowPass = $false
$safeToken = 'pvwsafe' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
$safeFolder = Join-Path $cacheRoot ('safety-' + $safeToken)
try {
    # ---- Setup: the bootstrapper's own Tier A build leaves a venv with Nuitka in it ------------------------------
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $dSafe.setupExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $logPath = Join-Path $workDir $bootstrapLog
    $combined = if (Test-Path -LiteralPath $logPath) { (Get-Content -LiteralPath $logPath -Encoding ASCII) -join "`n" } else { '' }
    $dSafe.setupFallbackSucceeded = [bool]($combined -match [regex]::Escape('Fallback build succeeded'))
    # The production Nuitka lines carry no static unpack folder, so the bootstrapper's own build leaves nothing here.
    $dSafe.pvwFoldersAfterSetup = @()
    if (Test-Path -LiteralPath $cacheRoot) { $dSafe.pvwFoldersAfterSetup = @(Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }

    $py = Join-Path $workDir '.uv_env\Scripts\python.exe'
    $dSafe.envPython = [bool](Test-Path -LiteralPath $py)
    $verRc = -1
    $nuitkaVer = ''
    if ($dSafe.envPython) {
        $verOut = & $py -m nuitka --version 2>&1
        $verRc = $LASTEXITCODE
        $nuitkaVer = @($verOut)[0]
    }
    $dSafe.nuitkaVersion = "$nuitkaVer"
    $dSafe.nuitkaUsable = ($dSafe.envPython -and ($verRc -eq 0))

    $expDir = Join-Path $workDir 'exp'
    $expDir2 = Join-Path $workDir 'exp2'
    New-Item -ItemType Directory -Force -Path $expDir | Out-Null
    $payload = Join-Path $workDir 'payload.bin'
    $buf = New-Object byte[] (100MB)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buf) } finally { $rng.Dispose() }
    [System.IO.File]::WriteAllBytes($payload, $buf)
    $buf = $null
    $dSafe.payloadBytes = (Get-Item -LiteralPath $payload).Length
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $fs = [System.IO.File]::OpenRead($payload)
    try { $expectedSha = ([System.BitConverter]::ToString($sha.ComputeHash($fs))).Replace('-', '').ToLowerInvariant() } finally { $fs.Dispose(); $sha.Dispose() }
    $dSafe.payloadSha = $expectedSha

    $appSource = @'
import hashlib
import os
import sys
import time
here = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(here, "payload.bin")
h = hashlib.sha256()
with open(path, "rb") as f:
    for chunk in iter(lambda: f.read(1 << 20), b""):
        h.update(chunk)
print("safety sha=%s size=%d" % (h.hexdigest(), os.path.getsize(path)), flush=True)
hold = float(sys.argv[1]) if len(sys.argv) > 1 else 0.0
if hold > 0:
    time.sleep(hold)
print("safety done", flush=True)
'@
    $appSource | Set-Content -LiteralPath (Join-Path $workDir 'safetyapp.py') -Encoding ASCII
    # The second build differs from the first in its code, which is what a user's edit looks like.
    ($appSource + "`nprint(`"safety version=2`", flush=True)`n") | Set-Content -LiteralPath (Join-Path $workDir 'safetyapp2.py') -Encoding ASCII

    function Test-Output {
        param($R)
        return [bool]($R.exit -eq 0 -and -not $R.timedOut -and $R.out.Contains("sha=$expectedSha ") -and $R.out.Contains("size=$($dSafe.payloadBytes)"))
    }
    function Get-Sample {
        param($R)
        return ("exit={0} out={1} err={2}" -f $R.exit, $R.out, $R.err)
    }

    function Build-Safety {
        # Same flags as the production lines plus the static spec; returns $true when the EXE exists.
        param([string]$Source, [string]$OutDirName, [string]$LogName)
        $flagArgs = @($prodFlags -split ' ' | Where-Object { $_ -notlike '--output-dir=*' })
        $spec = "--onefile-tempdir-spec={CACHE_DIR}/PVW/safety-$safeToken"
        $nArgs = $flagArgs + @("--output-dir=$OutDirName", '--include-data-files=payload.bin=payload.bin', $spec, '-o', 'safety.exe', $Source)
        $logFull = Join-Path $workDir $LogName
        Push-Location $workDir
        try {
            & $py @nArgs > $logFull 2>&1
            $rc = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        return [pscustomobject]@{ Rc = $rc; Built = [bool]((Test-Path -LiteralPath (Join-Path $workDir "$OutDirName\safety.exe")) -and $rc -eq 0) }
    }

    $built = $false
    if ($dSafe.nuitkaUsable) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $b = Build-Safety -Source 'safetyapp.py' -OutDirName 'exp' -LogName '~build_safety.log'
        $sw.Stop()
        $dSafe.buildRc = $b.Rc
        $dSafe.buildSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $built = $b.Built
    }
    $dSafe.built = $built
    $exe = Join-Path $expDir 'safety.exe'

    if ($built) {
        # baseline: the first launch unpacks, the folder stays
        [void](Remove-Folder $safeFolder)
        $r = Wait-App -H (Start-App -Exe $exe)
        $dSafe.baselineOk = Test-Output $r
        $dSafe.baselineMs = $r.ms
        $dSafe.folderKept = [bool](Test-Path -LiteralPath $safeFolder)
        $fullBytes = Get-FolderBytes $safeFolder
        $dSafe.folderBytes = $fullBytes

        # several copies at once, folder warm
        $hs = @(); foreach ($i in 1..3) { $hs += ,(Start-App -Exe $exe -ArgText '4') }
        $rs = @($hs | ForEach-Object { Wait-App -H $_ })
        $dSafe.warmConcurrentOk = (@($rs | Where-Object { Test-Output $_ }).Count -eq 3)
        $dSafe.warmConcurrentExits = @($rs | ForEach-Object { $_.exit })
        if (-not $dSafe.warmConcurrentOk) { $dSafe.warmConcurrentSample = ($rs | Where-Object { -not (Test-Output $_) } | Select-Object -First 1 | ForEach-Object { Get-Sample $_ }) }

        # several copies at once, folder cold (they race to unpack): three rounds, a normal launch after each
        $coldRounds = @()
        $coldRemovedAll = $true
        $coldRecoveryOk = $true
        $coldFailedLaunches = 0
        $coldUnexpectedFailures = 0
        # The known finding: a launch that cannot rewrite a file another launch has loaded exits non-zero and says so.
        # Any other failed cold launch (a timeout, exit 0 with wrong output, another error) is not that finding.
        $coldKnownReason = 'failed to open .* for writing'
        foreach ($round in 1..3) {
            $entry = [ordered]@{ round = $round }
            $entry.removed = Remove-Folder $safeFolder
            if (-not $entry.removed) { $coldRemovedAll = $false }
            $hs = @(); foreach ($i in 1..3) { $hs += ,(Start-App -Exe $exe -ArgText '3') }
            $rs = @($hs | ForEach-Object { Wait-App -H $_ })
            $bad = @($rs | Where-Object { -not (Test-Output $_) })
            $entry.exits = @($rs | ForEach-Object { $_.exit })
            $entry.ok = ($bad.Count -eq 0)
            $coldFailedLaunches += $bad.Count
            foreach ($badRun in $bad) {
                if ($badRun.timedOut -or $badRun.exit -eq 0 -or -not (("$($badRun.out) $($badRun.err)") -match $coldKnownReason)) {
                    $coldUnexpectedFailures++
                    if (-not $dSafe.Contains('coldUnexpectedSample')) { $dSafe.coldUnexpectedSample = (Get-Sample $badRun) }
                }
            }
            if ($bad.Count -gt 0 -and -not $dSafe.Contains('coldConcurrentSample')) { $dSafe.coldConcurrentSample = (Get-Sample $bad[0]) }
            $r = Wait-App -H (Start-App -Exe $exe)
            $entry.afterOk = Test-Output $r
            if (-not $entry.afterOk) { $coldRecoveryOk = $false; $entry.afterSample = (Get-Sample $r) }
            $coldRounds += ,$entry
        }
        $dSafe.coldRounds = $coldRounds
        $dSafe.coldRemoved = $coldRemovedAll
        $dSafe.coldFailedLaunches = $coldFailedLaunches
        $dSafe.coldUnexpectedFailures = $coldUnexpectedFailures
        $dSafe.coldConcurrentOk = (@($coldRounds | Where-Object { -not $_.ok }).Count -eq 0)
        $dSafe.afterColdOk = $coldRecoveryOk

        # a second copy started while the first still runs (it holds files in the folder open)
        $a = Start-App -Exe $exe -ArgText '20'
        Start-Sleep -Milliseconds 2500
        $dSafe.firstStillRunning = (-not $a.Proc.HasExited)
        $rb = Wait-App -H (Start-App -Exe $exe)
        $rc = Wait-App -H (Start-App -Exe $exe)
        $dSafe.firstStillRunningAfter = (-not $a.Proc.HasExited)
        $ra = Wait-App -H $a
        # Both checks are needed: the first copy must still be running when the second and third have finished, or
        # nothing overlapped.
        $dSafe.overlapOk = ((Test-Output $ra) -and (Test-Output $rb) -and (Test-Output $rc) -and $dSafe.firstStillRunning -and $dSafe.firstStillRunningAfter)

        # a launch killed in the middle of unpacking, then a normal launch
        $attempts = @()
        $partialKills = 0
        $recoveryOk = $true
        foreach ($i in 1..5) {
            $entry = [ordered]@{ attempt = $i }
            $entry.removed = Remove-Folder $safeFolder
            # A folder that could not be removed means this launch would not unpack, so the attempt proves nothing.
            if (-not $entry.removed) { $recoveryOk = $false }
            $h = Start-App -Exe $exe
            $partial = $false
            $watch = [System.Diagnostics.Stopwatch]::StartNew()
            while ($watch.ElapsedMilliseconds -lt 15000 -and -not $h.Proc.HasExited) {
                if (Test-Path -LiteralPath $safeFolder) {
                    $bytes = Get-FolderBytes $safeFolder
                    # Some data written (so the unpack is under way) but not all of it (so it is not finished).
                    if ($bytes -gt 1MB -and $bytes -lt ($fullBytes - 1MB)) { $partial = $true; $entry.bytesAtKill = $bytes; break }
                }
            }
            if ($partial) {
                if (Stop-AppTree $h) {
                    $partialKills++
                } else {
                    # The launch could not be stopped, so no mid-unpack kill was tested in this attempt.
                    $partial = $false
                    $entry.stopFailed = $true
                    $recoveryOk = $false
                }
            } else {
                Wait-App -H $h | Out-Null
            }
            $entry.partial = $partial
            $r = Wait-App -H (Start-App -Exe $exe)
            $entry.relaunchOk = Test-Output $r
            if (-not $entry.relaunchOk) { $recoveryOk = $false; $entry.sample = (Get-Sample $r) }
            $attempts += ,$entry
        }
        $dSafe.killAttempts = $attempts
        $dSafe.partialKills = $partialKills
        $dSafe.killRecoveryOk = $recoveryOk

        # a NEW build of the same spec started while the OLD build still runs (the user edits the program and runs
        # the bootstrapper again with the window still open); recorded, not asserted
        $dSafe.updateWhileRunningTested = $false
        $dSafe.updateWhileRunningOk = $false
        $b2 = Build-Safety -Source 'safetyapp2.py' -OutDirName 'exp2' -LogName '~build_safety2.log'
        $dSafe.build2Rc = $b2.Rc
        if ($b2.Built) {
            $exe2 = Join-Path $expDir2 'safety.exe'
            [void](Remove-Folder $safeFolder)
            $old = Start-App -Exe $exe -ArgText '25'
            $waited = [System.Diagnostics.Stopwatch]::StartNew()
            while ($waited.ElapsedMilliseconds -lt 20000 -and -not $old.Proc.HasExited -and (Get-FolderBytes $safeFolder) -lt ($fullBytes - 1MB)) { Start-Sleep -Milliseconds 200 }
            $dSafe.updateOldStillRunning = (-not $old.Proc.HasExited)
            if ($dSafe.updateOldStillRunning) {
                $r2 = Wait-App -H (Start-App -Exe $exe2)
                # The old build must still be running after the new one has finished, or the two never overlapped.
                $dSafe.updateOldStillRunningAfter = (-not $old.Proc.HasExited)
                $dSafe.updateWhileRunningTested = [bool]$dSafe.updateOldStillRunningAfter
                $dSafe.updateWhileRunningOk = [bool]((Test-Output $r2) -and $r2.out.Contains('safety version=2'))
                $dSafe.updateWhileRunningExit = $r2.exit
                if (-not $dSafe.updateWhileRunningOk) { $dSafe.updateWhileRunningSample = (Get-Sample $r2) }
            }
            [void](Stop-AppTree $old)
            $r3 = Wait-App -H (Start-App -Exe $exe2)
            $dSafe.updateAfterOldGoneOk = [bool]((Test-Output $r3) -and $r3.out.Contains('safety version=2'))
            if (-not $dSafe.updateAfterOldGoneOk) { $dSafe.updateAfterOldGoneSample = (Get-Sample $r3) }
        }
    }

    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $dSafe.realtimeMonitoringDisabled = [bool]$mp.DisableRealtimeMonitoring
    } catch {
        $dSafe.realtimeMonitoringDisabled = $null
    }

    # What the finding relies on. Cold concurrent rounds and the update scenario are recorded below, not asserted,
    # except that a cold launch failing for any reason other than the known one is unexpected and fails the row.
    $safePass = [bool]($dSafe.nuitkaUsable -and $built -and $dSafe.baselineOk -and $dSafe.folderKept -and
                       $dSafe.warmConcurrentOk -and $dSafe.coldRemoved -and $dSafe.afterColdOk -and
                       $dSafe.overlapOk -and $dSafe.killRecoveryOk -and ($dSafe.partialKills -ge 1) -and
                       ($dSafe.coldUnexpectedFailures -eq 0))
    # derived requirement: Nuitka missing from the venv or its build failing (a compiler download, the network) is a
    # provider problem, not a result. The row then says inconclusive with pass true, because the aggregate self-test
    # gate (CLAUDE.md Item 35) turns every pass:false row in any lane into a red check.
    $measured = [bool]($dSafe.nuitkaUsable -and $built)
    $dSafe.inconclusive = (-not $measured)
    $rowPass = [bool]((-not $measured) -or $safePass)
    $dSafe.adoptable = [bool]($safePass -and $dSafe.coldConcurrentOk -and $dSafe.updateWhileRunningTested -and $dSafe.updateWhileRunningOk)
    $dSafe.finding = "baseline=$($dSafe.baselineOk) warm=$($dSafe.warmConcurrentOk) coldOk=$($dSafe.coldConcurrentOk) coldFailedLaunches=$($dSafe.coldFailedLaunches) overlap=$($dSafe.overlapOk) killRecovery=$($dSafe.killRecoveryOk) partialKills=$($dSafe.partialKills) updateTested=$($dSafe.updateWhileRunningTested) updateOk=$($dSafe.updateWhileRunningOk) adoptable=$($dSafe.adoptable)"
    Write-SafetyRow -Pass $rowPass -Desc 'Item 72 finding (flag not adopted): a static Nuitka unpack folder measured for warm and cold concurrent launches, an overlapping launch, a launch killed mid-unpack and an update while the old build runs' -Details $dSafe
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevForceExecfail) { Remove-Item Env:HP_TEST_FORCE_PYINSTALLER_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PYINSTALLER_FAIL = $prevForceExecfail }
    # Drop the large leftovers (data file, EXEs, venv) but keep the ~*.log files: the diagnostics snapshot copies
    # tests/ recursively, and a venv's license .txt files would ride along.
    foreach ($big in @('payload.bin', 'exp', 'exp2', '.uv_env', 'dist', 'build')) {
        $bigPath = Join-Path $workDir $big
        if (Test-Path -LiteralPath $bigPath) { Remove-Item -LiteralPath $bigPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # The cache folder lives outside the workspace; remove exactly the one this run created.
    if ($safeFolder) { [void](Remove-Folder $safeFolder) }
    if ((Test-Path -LiteralPath $cacheRoot) -and -not (Get-ChildItem -LiteralPath $cacheRoot -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $cacheRoot -Force -ErrorAction SilentlyContinue
    }
}

if (-not $rowPass) { exit 1 }
exit 0
