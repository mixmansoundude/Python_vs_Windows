# ASCII only
# selfapps_nuitka_launchcache.ps1 - Item 72 (b) experiment: does Nuitka's --onefile-tempdir-spec
# (a static cache folder) change what the second launch of a --onefile EXE costs, and is it safe
# for a bootstrapper that rebuilds whenever the source changes?
#
# Field note (Sep 2026): a Nuitka --onefile EXE took about 60 s to show output on a test machine
# while Defender sat at 100% CPU, against 5 s for the PyInstaller EXE. Nuitka --onefile unpacks
# its payload into a fresh %TEMP%\onefile_* folder on EVERY launch and deletes it on exit, so a
# large app is extracted (and scanned) each time. A static spec keeps the unpacked folder, so
# only the first launch should pay. This script measures that and, more important, checks the
# two things that would make adopting it unsafe here: (1) a rebuild with the SAME spec must run
# the NEW code, never a stale unpacked copy; (2) the default build must still clean up after
# itself, so the comparison is real.
#
# It does NOT edit run_setup.bat and decides nothing. The row records numbers and mechanism
# facts; whether to add the flag to :try_nuitka_tier_a / :offer_optimized_build is decided from
# a run's rows (see docs/plan-field-report-2026-10.md, Item 72).
#
# Environment: a forced-PyInstaller-failure bootstrap of a trivial app (the same recipe as
# selfapps_nuitka_tiera.ps1) leaves a uv venv with Nuitka installed; every build below uses that
# venv's own python and the bootstrapper's own Nuitka flags (checked against run_setup.bat so
# they cannot drift apart). The app carries a 40 MB random data file so extraction is not free.
#
# Non-gating (uv lane): it needs a real Nuitka build, three times, and may download a compiler.
# The row passes on the MECHANISM checks only (builds ran, every launch printed the expected
# marker and payload size, default extraction folders were removed, the cache folder stayed);
# the speed numbers and the rebuild-freshness answer are findings in the details.
#
# Emits: self.nuitka.launchcache
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

function Write-CacheRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.nuitka.launchcache'; req = 'REQ-AV'; pass = $Pass; desc = $Desc; details = $Details })
}

# A Nuitka onefile program reports its own folder in 8.3 form on a hosted runner (RUNNER~1, PVWEXP~1), so any
# check by folder name needs the long form first (the first run read cachedFolderInSpec false for that reason).
function Get-LongPath {
    param([string]$Path)
    if (-not $Path) { return $Path }
    if (-not ('PvwLaNative' -as [type])) {
        Add-Type -TypeDefinition 'using System.Runtime.InteropServices; using System.Text; public static class PvwLaNative { [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] public static extern int GetLongPathName(string path, StringBuilder buf, int len); }'
    }
    $sb = New-Object System.Text.StringBuilder 1024
    $n = [PvwLaNative]::GetLongPathName($Path, $sb, $sb.Capacity)
    if ($n -gt 0 -and $n -lt $sb.Capacity) { return $sb.ToString() }
    return $Path
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-CacheRow -Pass $true -Desc 'Nuitka onefile launch cache experiment (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-CacheRow -Pass $false -Desc 'Nuitka onefile launch cache experiment: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# The flags the bootstrapper passes before the entry file. Both Nuitka command lines
# (:try_nuitka_tier_a and :offer_optimized_build) must carry exactly this text, or the numbers
# below describe a different build than the user gets.
$prodFlags = '-m nuitka --onefile --assume-yes-for-downloads --remove-output --output-dir=dist'
$batchText = [System.IO.File]::ReadAllText($batchPath)
$flagLines = ([regex]::Matches($batchText, [regex]::Escape($prodFlags))).Count

$workDir = Join-Path $here '~selftest_nuitka_launchcache'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force
Set-Content -Path (Join-Path $workDir 'app.py') -Value 'print("launchcache-env-ready")' -Encoding ASCII

$token   = 'pvwexp' + ([guid]::NewGuid().ToString('N').Substring(0, 12))
$spec    = '{CACHE_DIR}/pvw_launchcache_exp/' + $token
$expDir  = Join-Path $workDir 'exp'
New-Item -ItemType Directory -Force -Path $expDir | Out-Null

$prevSkipPipreqs   = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevForceExecfail = if (Test-Path Env:HP_TEST_FORCE_PYINSTALLER_FAIL) { $env:HP_TEST_FORCE_PYINSTALLER_FAIL } else { $null }
$env:HP_SKIP_PIPREQS = '1'
$env:HP_TEST_FORCE_PYINSTALLER_FAIL = '1'

$d = [ordered]@{}
$pass = $false
$cacheDirSeen = $null
try {
    # Step 1: the bootstrapper leaves a venv with Nuitka installed.
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > ~bootstrap.log 2>&1"
        $d.bootstrapExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $py = Join-Path $workDir '.uv_env\Scripts\python.exe'
    $d.envPython = [bool](Test-Path -LiteralPath $py)
    $nuitkaVer = ''
    $verRc = -1
    if ($d.envPython) {
        $verOut = & $py -m nuitka --version 2>&1
        $verRc = $LASTEXITCODE
        $nuitkaVer = @($verOut)[0]
    }
    $d.nuitkaVersion = "$nuitkaVer"
    $d.nuitkaUsable = ($d.envPython -and ($verRc -eq 0))

    # Step 2: the app, with a payload big enough that unpacking it costs something.
    $payload = Join-Path $workDir 'payload.bin'
    $buf = New-Object byte[] (40MB)
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($buf) } finally { $rng.Dispose() }
    [System.IO.File]::WriteAllBytes($payload, $buf)
    $buf = $null
    $d.payloadBytes = (Get-Item -LiteralPath $payload).Length

    $appTemplate = @'
import os
MARK = "__MARK__"
here = os.path.dirname(os.path.abspath(__file__))
size = os.path.getsize(os.path.join(here, "payload.bin"))
print("launchcache marker=%s payload=%d dir=%s" % (MARK, size, here))
'@
    $appPath = Join-Path $workDir 'cacheapp.py'

    function Build-App {
        param([string]$Mark, [string]$OutName, [string[]]$Extra)
        [System.IO.File]::WriteAllText($appPath, $appTemplate.Replace('__MARK__', $Mark))
        $log = Join-Path $workDir ("~build_" + $OutName + '.log')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        Push-Location $workDir
        try {
            # The flags come from $prodFlags (the text checked against run_setup.bat above); only the output folder differs.
            $flagArgs = @($prodFlags -split ' ' | Where-Object { $_ -notlike '--output-dir=*' })
            $nArgs = $flagArgs + @('--output-dir=exp', '--include-data-files=payload.bin=payload.bin') + $Extra + @('-o', $OutName, 'cacheapp.py')
            & $py @nArgs > $log 2>&1
            $rc = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $sw.Stop()
        return [ordered]@{ rc = $rc; seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); exe = (Join-Path $expDir $OutName); built = [bool](Test-Path -LiteralPath (Join-Path $expDir $OutName)) }
    }

    function Measure-Launch {
        param([string]$Exe)
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $Exe
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $p = [System.Diagnostics.Process]::Start($psi)
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $timedOut = $false
        if (-not $p.WaitForExit(240000)) {
            $timedOut = $true
            try { $p.Kill() } catch { }
        } else {
            $p.WaitForExit()
        }
        $sw.Stop()
        $out = ''
        if (-not $timedOut) { $out = $outTask.Result.Trim() }
        $dir = $null
        $m = [regex]::Match($out, 'dir=(.+)$')
        if ($m.Success) { $dir = $m.Groups[1].Value.Trim() }
        return [ordered]@{
            ms       = [int]$sw.ElapsedMilliseconds
            exit     = $(if ($timedOut) { -1 } else { $p.ExitCode })
            timedOut = $timedOut
            out      = $out
            dir      = $dir
            dirKept  = $(if ($dir) { [bool](Test-Path -LiteralPath $dir) } else { $null })
        }
    }

    function Test-Launch {
        param($L, [string]$Mark)
        return ($L.exit -eq 0 -and -not $L.timedOut -and $L.out.Contains("marker=$Mark ") -and $L.out.Contains("payload=$($d.payloadBytes) "))
    }

    if ($d.nuitkaUsable) {
        # Step 3: two builds of the same source, differing only in the tempdir spec.
        $bDefault = Build-App -Mark 'v1' -OutName 'default.exe' -Extra @()
        $bCached  = Build-App -Mark 'v1' -OutName 'cached.exe'  -Extra @("--onefile-tempdir-spec=$spec")
        $d.buildDefaultSeconds = $bDefault.seconds
        $d.buildCachedSeconds  = $bCached.seconds
        $d.buildDefaultOk = ($bDefault.rc -eq 0 -and $bDefault.built)
        $d.buildCachedOk  = ($bCached.rc -eq 0 -and $bCached.built)

        if ($d.buildDefaultOk -and $d.buildCachedOk) {
            # Step 4: three launches each. The first cached launch pays the extraction.
            $defaultRuns = @(); $cachedRuns = @()
            foreach ($i in 1..3) { $defaultRuns += ,(Measure-Launch -Exe $bDefault.exe) }
            foreach ($i in 1..3) { $cachedRuns  += ,(Measure-Launch -Exe $bCached.exe) }
            $d.defaultLaunchMs = @($defaultRuns | ForEach-Object { $_.ms })
            $d.cachedLaunchMs  = @($cachedRuns  | ForEach-Object { $_.ms })
            $d.defaultLaunchesOk = (@($defaultRuns | Where-Object { Test-Launch $_ 'v1' }).Count -eq 3)
            $d.cachedLaunchesOk  = (@($cachedRuns  | Where-Object { Test-Launch $_ 'v1' }).Count -eq 3)
            $d.defaultFoldersRemoved = (@($defaultRuns | Where-Object { $_.dir -and -not $_.dirKept }).Count -eq 3)
            $cachedDirs = @($cachedRuns | ForEach-Object { $_.dir } | Select-Object -Unique)
            $d.cachedSameFolder = ($cachedDirs.Count -eq 1 -and [bool]$cachedDirs[0])
            $d.cachedFolderKept = (@($cachedRuns | Where-Object { $_.dirKept }).Count -eq 3)
            $cachedLong = $null
            if ($cachedDirs.Count -ge 1 -and $cachedDirs[0]) { $cachedLong = Get-LongPath $cachedDirs[0] }
            $d.cachedFolderInSpec = ($d.cachedSameFolder -and $cachedLong.Contains($token) -and $cachedLong.Contains('pvw_launchcache_exp'))
            $cacheDirSeen = $cachedLong
            $d.defaultExampleDir = $defaultRuns[0].dir
            $d.cachedFolderAsReported = $cachedDirs[0]
            $d.cachedFolder = $cacheDirSeen

            # Step 5: the safety question. Same spec, changed source, rebuilt EXE.
            $bRebuild = Build-App -Mark 'v2' -OutName 'cached.exe' -Extra @("--onefile-tempdir-spec=$spec")
            $d.buildRebuildOk = ($bRebuild.rc -eq 0 -and $bRebuild.built)
            if ($d.buildRebuildOk) {
                $reRun = Measure-Launch -Exe $bRebuild.exe
                $d.rebuildLaunchMs = $reRun.ms
                $d.rebuildRanNewCode = [bool]($reRun.exit -eq 0 -and $reRun.out.Contains('marker=v2 '))
                $d.rebuildRanStaleCode = [bool]($reRun.exit -eq 0 -and $reRun.out.Contains('marker=v1 '))
                $d.rebuildOutput = $reRun.out
                $reRun2 = Measure-Launch -Exe $bRebuild.exe
                $d.rebuildSecondLaunchMs = $reRun2.ms
            }
        }
    }

    # Defender state, so a reader can tell whether the timings can show anything at all.
    try {
        $mp = Get-MpPreference -ErrorAction Stop
        $d.realtimeMonitoringDisabled = [bool]$mp.DisableRealtimeMonitoring
    } catch {
        $d.realtimeMonitoringDisabled = $null
    }
    $d.prodFlagLines = $flagLines
    $d.spec = $spec

    $mechanism = ($flagLines -ge 2) -and $d.nuitkaUsable -and $d.buildDefaultOk -and $d.buildCachedOk -and
                 $d.defaultLaunchesOk -and $d.cachedLaunchesOk -and $d.defaultFoldersRemoved -and
                 $d.cachedSameFolder -and $d.cachedFolderKept -and $d.cachedFolderInSpec -and
                 $d.buildRebuildOk -and ($d.rebuildRanNewCode -or $d.rebuildRanStaleCode)
    $pass = [bool]$mechanism

    $first = $null; $later = $null; $defMedian = $null
    if ($d.cachedLaunchMs) { $first = $d.cachedLaunchMs[0]; $later = [int](($d.cachedLaunchMs[1..2] | Measure-Object -Average).Average) }
    if ($d.defaultLaunchMs) { $defMedian = [int](($d.defaultLaunchMs | Sort-Object)[1]) }
    $d.finding = "default launches median ${defMedian} ms; cached first ${first} ms, later ${later} ms; rebuild with the same spec ran newCode=$($d.rebuildRanNewCode) staleCode=$($d.rebuildRanStaleCode)"

    Write-CacheRow -Pass $pass -Desc 'Item 72: Nuitka onefile launch with a static --onefile-tempdir-spec (mechanism checks; timings and rebuild freshness are findings)' -Details $d
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevForceExecfail) { Remove-Item Env:HP_TEST_FORCE_PYINSTALLER_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PYINSTALLER_FAIL = $prevForceExecfail }
    # Drop the large build leftovers (the data file, both EXEs, the venv) but keep the ~build_*.log files: the
    # diagnostics snapshot copies tests/ recursively, and a venv's license .txt files would ride along.
    foreach ($big in @('payload.bin', 'exp', '.uv_env')) {
        $bigPath = Join-Path $workDir $big
        if (Test-Path -LiteralPath $bigPath) { Remove-Item -LiteralPath $bigPath -Recurse -Force -ErrorAction SilentlyContinue }
    }
    # The cache folder lives outside the workspace; remove exactly the folder named by this run's token.
    if ($cacheDirSeen -and $cacheDirSeen.Contains($token) -and (Test-Path -LiteralPath $cacheDirSeen)) {
        Remove-Item -LiteralPath $cacheDirSeen -Recurse -Force -ErrorAction SilentlyContinue
        $cacheParent = Split-Path -Path $cacheDirSeen -Parent
        if ((Split-Path -Path $cacheParent -Leaf) -eq 'pvw_launchcache_exp' -and -not (Get-ChildItem -LiteralPath $cacheParent -Force -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $cacheParent -Force -ErrorAction SilentlyContinue
        }
    }
}

if (-not $pass) { exit 1 }
exit 0
