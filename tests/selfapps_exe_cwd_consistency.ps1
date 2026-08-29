# ASCII only
# selfapps_exe_cwd_consistency.ps1 - CLAUDE.md Active Backlog Item 38 (resolved): proves the fix
# for the EXE-verification current working directory (CWD) mismatch. Before this fix,
# :run_exe_smokerun (the fresh-build verification, run 1) ran from dist\, while :try_fast_exe
# (every later, cached-EXE run) ran from the app root -- a CWD-relative-path app (e.g.
# open("config.json"), with config.json sitting next to the .py source at the app root, the way
# a beginner naturally organizes adjacent data files) could pass on one of those two verification
# points and fail on the other with zero code change in between. Both verification points now
# share the same CWD (the app root, matching the interpreter's own CWD too) -- this test proves
# run 1 (a fresh build via :run_exe_smokerun) and run 2 (the cached-EXE fast path via
# :try_fast_exe) agree on the SAME CWD-relative app: both must find config.json and both must
# succeed.
#
# Split out of selfapps_exedata_fail.ps1's former "plain" scenario, which used to assert the
# OPPOSITE (an expected, xfail failure) before this fix. That file's own remaining scenarios
# (mei_substring, mei_genuine) stay genuinely XFAIL -- their files are made truly absent (or, for
# mei_genuine, live under a randomly-named PyInstaller extraction directory independent of launch
# CWD), so they are unaffected by which CWD :run_exe_smokerun uses.
#
# Lane: real and conda-full only, mirroring selfapps_exedata_fail.ps1's own lane placement.
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

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.smokerun.cwd_consistency'
        req     = 'REQ-018'
        pass    = $true
        desc    = 'EXE CWD consistency: fresh build and fast-path reuse agree on the app-root CWD (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.smokerun.cwd_consistency'
        req     = 'REQ-018'
        pass    = $false
        desc    = 'EXE CWD consistency: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_exe_cwd_consistency'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# derived requirement: entry.py opens config.json via a bare, CWD-relative path -- config.json
# sits next to entry.py at the app root, the way a beginner naturally organizes adjacent data
# files. PyInstaller does not bundle it; only the CWD the EXE launches from decides whether the
# open() call finds it.
Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
with open("config.json", "r") as f:
    print(f.read())
'@ -Encoding ASCII
Set-Content -Path (Join-Path $workDir 'config.json') -Value '{"msg": "hello-data"}' -Encoding ASCII

$prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'

function Invoke-Bootstrap {
    param([string]$LogName)
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $LogName 2>&1"
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

$run1Log = '~exe_cwd_consistency_run1.log'
$run2Log = '~exe_cwd_consistency_run2.log'

try {
    $run1Exit = Invoke-Bootstrap -LogName $run1Log
    $run2Exit = Invoke-Bootstrap -LogName $run2Log
} finally {
    if ($null -eq $prev) {
        Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PIPREQS = $prev
    }
}

$run1LogPath = Join-Path $workDir $run1Log
$run2LogPath = Join-Path $workDir $run2Log
$run1Text = if (Test-Path $run1LogPath) { Get-Content -LiteralPath $run1LogPath -Raw -Encoding ASCII } else { '' }
$run2Text = if (Test-Path $run2LogPath) { Get-Content -LiteralPath $run2LogPath -Raw -Encoding ASCII } else { '' }
$runOutPath = Join-Path $workDir '~run.out.txt'

# Run 1: a fresh build via :run_exe_smokerun. Must succeed -- config.json sits at the app root,
# and :run_exe_smokerun now verifies from the app root too (CLAUDE.md Item 38).
$run1SmokerunFired  = $run1Text -match [regex]::Escape('EXE smokerun: exited')
$run1SmokerunPassed = $run1Text -match [regex]::Escape('EXE smokerun: exited 0 (ok)')
$run1OutText  = if (Test-Path $runOutPath) { Get-Content -LiteralPath $runOutPath -Raw -Encoding ASCII } else { '' }
$run1DataSeen = $run1OutText -match 'hello-data'
$run1Pass = $run1SmokerunFired -and $run1SmokerunPassed -and $run1DataSeen

# Run 2: the cached-EXE fast path via :try_fast_exe, same directory, no source changes. Must
# ALSO succeed, from the SAME CWD as run 1 -- this is the actual consistency being proven: no
# behavior flip between "just built" and "every run after."
$run2FastpathFired = $run2Text -match [regex]::Escape('Fast path: reusing')
$run2StatusSuccess = $run2Text -match [regex]::Escape('[STATUS] Run Status: SUCCESS')
$run2OutText  = if (Test-Path $runOutPath) { Get-Content -LiteralPath $runOutPath -Raw -Encoding ASCII } else { '' }
$run2DataSeen = $run2OutText -match 'hello-data'
$run2Pass = $run2FastpathFired -and $run2StatusSuccess -and $run2DataSeen

$consistencyPass = $run1Pass -and $run2Pass

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.smokerun.cwd_consistency'
    req     = 'REQ-018'
    pass    = $consistencyPass
    desc    = 'EXE CWD consistency: a CWD-relative-path app succeeds identically on a fresh build (:run_exe_smokerun) and on the cached-EXE fast path (:try_fast_exe)'
    details = [ordered]@{
        run1Exit           = $run1Exit
        run1SmokerunFired  = $run1SmokerunFired
        run1SmokerunPassed = $run1SmokerunPassed
        run1DataSeen       = $run1DataSeen
        run2Exit           = $run2Exit
        run2FastpathFired  = $run2FastpathFired
        run2StatusSuccess  = $run2StatusSuccess
        run2DataSeen       = $run2DataSeen
        consistencyPass    = $consistencyPass
        run1Log            = $run1Log
        run2Log            = $run2Log
    }
})

if (-not $consistencyPass) { exit 1 }
exit 0
