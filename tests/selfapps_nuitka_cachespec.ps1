# ASCII only
# selfapps_nuitka_cachespec.ps1 - Item 72 follow-up: the Nuitka builds keep their unpacked files in a per-app
# cache folder, and that is safe.
#
# Background: a Nuitka --onefile EXE unpacks into a fresh %TEMP%\onefile_* folder on EVERY launch. The Item 72
# experiment (selfapps_nuitka_launchcache.ps1, docs/plan-field-report-2026-10.md) showed that a static
# --onefile-tempdir-spec makes later launches about 3.7 times faster and that a same-spec rebuild runs the NEW
# code. run_setup.bat therefore passes --onefile-tempdir-spec={CACHE_DIR}/PVW/<env>-<token> on both Nuitka command
# lines (:try_nuitka_tier_a and :offer_optimized_build), where <token> is the first 12 hex characters of the
# SHA-256 of the lower-cased app folder path, so two apps never share a folder.
#
# This script emits two rows:
#   self.nuitka.cachespec   the bootstrapper's own Tier A build (PyInstaller failure forced, a real Nuitka build)
#                           created exactly the folder the rule names: %LOCALAPPDATA%\PVW\<env>-<token>, with
#                           files in it, and a second launch of dist\<env>.exe used that same folder.
#   self.nuitka.cachesafety what a static folder could break, measured on this runner with the same flag text:
#                           several copies of the program started at once (folder warm and folder cold), a
#                           second copy started while the first still runs, and a launch killed in the middle of
#                           unpacking followed by a normal launch. Every launch must exit 0 and print the
#                           payload's real SHA-256, or adopting the flag is unsafe.
# The safety row is independent of run_setup.bat's fix: it builds with the flag text itself.
#
# Non-gating (uv lane): two real Nuitka builds and a possible compiler download can fail from network or provider
# problems. A red safety row means the flag must not be adopted.
#
# Emits: self.nuitka.cachespec, self.nuitka.cachesafety
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

function Write-SpecRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.nuitka.cachespec'; req = 'REQ-AV'; pass = $Pass; desc = $Desc; details = $Details })
}

function Write-SafetyRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.nuitka.cachesafety'; req = 'REQ-AV'; pass = $Pass; desc = $Desc; details = $Details })
}

# A Nuitka onefile program reports its own folder in 8.3 form on a hosted runner (RUNNER~1), so any check by
# folder name needs the long form first (the launch-cache experiment read a false red for that reason).
function Get-LongPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if (-not ('PvwCsNative' -as [type])) {
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; using System.Text; public static class PvwCsNative { [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern int GetLongPathName(string path, StringBuilder buf, int len); }'
    }
    $sb = New-Object System.Text.StringBuilder 1024
    $n = [PvwCsNative]::GetLongPathName($Path, $sb, $sb.Capacity)
    if ($n -gt 0 -and $n -lt $sb.Capacity) { return $sb.ToString() }
    return $Path
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-SpecRow   -Pass $true -Desc 'Nuitka unpack cache folder (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' })
    Write-SafetyRow -Pass $true -Desc 'Nuitka unpack cache safety (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-SpecRow   -Pass $false -Desc 'Nuitka unpack cache folder: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    Write-SafetyRow -Pass $false -Desc 'Nuitka unpack cache safety: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# The flags run_setup.bat passes before the output name; the safety builds take theirs from this text so the
# build under test is the production one (only the output folder and the data file differ).
$prodFlags = '-m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist'

function Get-TokenCandidates {
    # The token is the SHA-256 of the lower-cased current directory the bootstrapper ran in. A runner can hand
    # out the path in its 8.3 or its long form, so accept either.
    param([string]$Path)
    $forms = @($Path, (Get-LongPath $Path)) | Select-Object -Unique
    $out = @()
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        foreach ($f in $forms) {
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($f.ToLowerInvariant())
            $hex = ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
            $out += $hex.Substring(0, 12)
        }
    } finally {
        $sha.Dispose()
    }
    return @($out | Select-Object -Unique)
}

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
    param($H)
    try { & taskkill /F /T /PID $H.Proc.Id 2>&1 | Out-Null } catch { }
    try { $H.Proc.WaitForExit(10000) | Out-Null } catch { }
}

$workDir = Join-Path $here '~selftest_nuitka_cachespec'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force
Set-Content -Path (Join-Path $workDir 'app.py') -Value 'print("nuitka-cachespec-ok")' -Encoding ASCII

$envName   = ((Split-Path $workDir -Leaf) -replace '[^A-Za-z0-9_-]', '_')
$cacheRoot = Join-Path $env:LOCALAPPDATA 'PVW'
$bootstrapLog = '~cachespec_bootstrap.log'

$prevSkipPipreqs   = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevForceExecfail = if (Test-Path Env:HP_TEST_FORCE_PYINSTALLER_FAIL) { $env:HP_TEST_FORCE_PYINSTALLER_FAIL } else { $null }
$env:HP_SKIP_PIPREQS = '1'
$env:HP_TEST_FORCE_PYINSTALLER_FAIL = '1'

$dSpec = [ordered]@{}
$dSafe = [ordered]@{}
$specPass = $false
$safePass = $false
$specFolder = $null
$safeToken = 'pvwsafe' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
$safeFolder = Join-Path $cacheRoot ('safety-' + $safeToken)
try {
    # ---- Part 1: the bootstrapper's own Tier A build -------------------------------------------------------
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $dSpec.bootstrapExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $logPath = Join-Path $workDir $bootstrapLog
    $combined = if (Test-Path -LiteralPath $logPath) { (Get-Content -LiteralPath $logPath -Encoding ASCII) -join "`n" } else { '' }
    $dSpec.fallbackSucceeded = [bool]($combined -match [regex]::Escape('Fallback build succeeded'))
    $dSpec.cacheLineLogged = [bool]($combined -match [regex]::Escape('Unpack cache: the program keeps its unpacked files in the PVW folder'))

    $exePath = Join-Path $workDir "dist\$envName.exe"
    $dSpec.exeExists = [bool](Test-Path -LiteralPath $exePath)
    $runOutPath = Join-Path $workDir '~run.out.txt'
    $runOut = if (Test-Path -LiteralPath $runOutPath) { Get-Content -LiteralPath $runOutPath -Raw -Encoding ASCII } else { '' }
    $dSpec.smokeStdoutFound = [bool]($runOut -match [regex]::Escape('nuitka-cachespec-ok'))
    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusState = $null
    if (Test-Path -LiteralPath $statusPath) {
        try { $statusState = (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).state } catch { $statusState = $null }
    }
    $dSpec.statusState = $statusState

    $tokens = Get-TokenCandidates $workDir
    $dSpec.tokenCandidates = $tokens
    $dSpec.envName = $envName
    $existing = @()
    if (Test-Path -LiteralPath $cacheRoot) { $existing = @(Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
    $dSpec.pvwFolders = $existing
    foreach ($t in $tokens) {
        $candidate = Join-Path $cacheRoot ($envName + '-' + $t)
        if (Test-Path -LiteralPath $candidate) { $specFolder = $candidate; break }
    }
    $dSpec.cacheFolderExists = [bool]$specFolder
    $dSpec.cacheFolder = $specFolder
    $dSpec.cacheHasFiles = $false
    if ($specFolder) { $dSpec.cacheHasFiles = ((Get-FolderBytes $specFolder) -gt 0) }

    # A second launch of the built EXE must unpack into the very same folder (and run).
    $dSpec.relaunchOk = $false
    $dSpec.relaunchNoNewFolder = $false
    if ($dSpec.exeExists) {
        $h = Start-App -Exe $exePath
        $r = Wait-App -H $h -TimeoutMs 120000
        $dSpec.relaunchMs = $r.ms
        $dSpec.relaunchExit = $r.exit
        $dSpec.relaunchOk = [bool]($r.exit -eq 0 -and $r.out.Contains('nuitka-cachespec-ok'))
        $after = @()
        if (Test-Path -LiteralPath $cacheRoot) { $after = @(Get-ChildItem -LiteralPath $cacheRoot -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
        $dSpec.pvwFoldersAfterRelaunch = $after
        $dSpec.relaunchNoNewFolder = [bool]((($existing | Sort-Object) -join '|') -eq (($after | Sort-Object) -join '|'))
    }

    $specPass = $dSpec.fallbackSucceeded -and $dSpec.cacheLineLogged -and $dSpec.exeExists -and $dSpec.smokeStdoutFound -and
                ($statusState -eq 'ok') -and $dSpec.cacheFolderExists -and $dSpec.cacheHasFiles -and $dSpec.relaunchOk -and $dSpec.relaunchNoNewFolder
    $specPass = [bool]$specPass
    Write-SpecRow -Pass $specPass -Desc 'Item 72: the Tier A Nuitka build keeps its unpacked files in %LOCALAPPDATA%\PVW\<env>-<token> (token from the app folder path)' -Details $dSpec

    # ---- Part 2: what a static folder could break ----------------------------------------------------------
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

    @'
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
'@ | Set-Content -LiteralPath (Join-Path $workDir 'safetyapp.py') -Encoding ASCII

    function Test-Output {
        param($R)
        return [bool]($R.exit -eq 0 -and -not $R.timedOut -and $R.out.Contains("sha=$expectedSha ") -and $R.out.Contains("size=$($dSafe.payloadBytes)"))
    }

    $built = $false
    if ($dSafe.nuitkaUsable) {
        $flagArgs = @($prodFlags -split ' ' | Where-Object { $_ -notlike '--output-dir=*' })
        $spec = "--onefile-tempdir-spec={CACHE_DIR}/PVW/safety-$safeToken"
        $nArgs = $flagArgs + @('--output-dir=exp', '--include-data-files=payload.bin=payload.bin', $spec, '-o', 'safety.exe', 'safetyapp.py')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Push-Location $workDir
        try {
            $buildLog = Join-Path $workDir '~build_safety.log'
            & $py @nArgs > $buildLog 2>&1
            $dSafe.buildRc = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $sw.Stop()
        $dSafe.buildSeconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $exe = Join-Path $expDir 'safety.exe'
        $built = [bool]((Test-Path -LiteralPath $exe) -and $dSafe.buildRc -eq 0)
    }
    $dSafe.built = $built

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
        if (-not $dSafe.warmConcurrentOk) { $dSafe.warmConcurrentSample = ($rs | Where-Object { -not (Test-Output $_) } | Select-Object -First 1 | ForEach-Object { ("exit={0} out={1} err={2}" -f $_.exit, $_.out, $_.err) }) }

        # several copies at once, folder cold (they race to unpack)
        $dSafe.coldRemoved = Remove-Folder $safeFolder
        $hs = @(); foreach ($i in 1..3) { $hs += ,(Start-App -Exe $exe -ArgText '3') }
        $rs = @($hs | ForEach-Object { Wait-App -H $_ })
        $dSafe.coldConcurrentOk = (@($rs | Where-Object { Test-Output $_ }).Count -eq 3)
        $dSafe.coldConcurrentExits = @($rs | ForEach-Object { $_.exit })
        if (-not $dSafe.coldConcurrentOk) { $dSafe.coldConcurrentSample = ($rs | Where-Object { -not (Test-Output $_) } | Select-Object -First 1 | ForEach-Object { ("exit={0} out={1} err={2}" -f $_.exit, $_.out, $_.err) }) }
        $r = Wait-App -H (Start-App -Exe $exe)
        $dSafe.afterColdOk = Test-Output $r

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
                Stop-AppTree $h
                $partialKills++
            } else {
                Wait-App -H $h | Out-Null
            }
            $entry.partial = $partial
            $r = Wait-App -H (Start-App -Exe $exe)
            $entry.relaunchOk = Test-Output $r
            if (-not $entry.relaunchOk) { $recoveryOk = $false; $entry.sample = ("exit={0} out={1} err={2}" -f $r.exit, $r.out, $r.err) }
            $attempts += ,$entry
        }
        $dSafe.killAttempts = $attempts
        $dSafe.partialKills = $partialKills
        $dSafe.killRecoveryOk = $recoveryOk
    }

    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $dSafe.realtimeMonitoringDisabled = [bool]$mp.DisableRealtimeMonitoring
    } catch {
        $dSafe.realtimeMonitoringDisabled = $null
    }

    $safePass = [bool]($dSafe.nuitkaUsable -and $built -and $dSafe.baselineOk -and $dSafe.folderKept -and
                       $dSafe.warmConcurrentOk -and $dSafe.coldRemoved -and $dSafe.coldConcurrentOk -and $dSafe.afterColdOk -and
                       $dSafe.overlapOk -and $dSafe.killRecoveryOk -and ($dSafe.partialKills -ge 1))
    $dSafe.finding = "baseline=$($dSafe.baselineOk) warm=$($dSafe.warmConcurrentOk) cold=$($dSafe.coldConcurrentOk) overlap=$($dSafe.overlapOk) killRecovery=$($dSafe.killRecoveryOk) partialKills=$($dSafe.partialKills)"
    Write-SafetyRow -Pass $safePass -Desc 'Item 72: a static Nuitka unpack folder survives concurrent launches, an overlapping launch and a launch killed mid-unpack' -Details $dSafe
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevForceExecfail) { Remove-Item Env:HP_TEST_FORCE_PYINSTALLER_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PYINSTALLER_FAIL = $prevForceExecfail }
    # Drop the large leftovers (data file, EXEs, venv) but keep the ~*.log files: the diagnostics snapshot copies
    # tests/ recursively, and a venv's license .txt files would ride along.
    foreach ($big in @('payload.bin', 'exp', '.uv_env', 'dist', 'build')) {
        $bigPath = Join-Path $workDir $big
        if (Test-Path -LiteralPath $bigPath) { Remove-Item -LiteralPath $bigPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # The cache folders live outside the workspace; remove exactly the two this run created.
    if ($safeFolder) { [void](Remove-Folder $safeFolder) }
    if ($specFolder) { [void](Remove-Folder $specFolder) }
    if ((Test-Path -LiteralPath $cacheRoot) -and -not (Get-ChildItem -LiteralPath $cacheRoot -Force -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $cacheRoot -Force -ErrorAction SilentlyContinue
    }
}

if (-not ($specPass -and $safePass)) { exit 1 }
exit 0
