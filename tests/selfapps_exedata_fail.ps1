# ASCII only
# selfapps_exedata_fail.ps1 - XFAIL test: EXE smokerun expected to fail when entry.py
# opens a data file not bundled by PyInstaller. Bootstrap completes (exitCode=0) but the
# built EXE exits non-zero at runtime. Test passes (xfail) when smokerun reports failure.
# Test fails (xpass) if smokerun unexpectedly reports exit 0.
#
# Three scenarios (EXEDATA_SCENARIO env var; unset defaults to 'plain'), covering both
# branches of :exe_smokerun_hints' CLAUDE.md Item 38 fix (honest advice for a CWD-relative
# missing file, real --add-data advice only for a genuine _MEIxxxxxx extraction path):
# - plain: entry.py opens "config.json" -- a bare CWD-relative path, no _MEI anywhere.
#   Expects the honest CWD-relative advice.
# - mei_substring (CodeRabbit review, PR #458): entry.py opens "config_MEI99.json" -- a
#   bare CWD-relative path whose NAME happens to contain "_MEI" followed by digits as a
#   coincidental substring, with no path separator on either side. Regression test for the
#   exact false-positive shape CodeRabbit's review flagged in the original plain findstr
#   substring match (fixed via a path-component-anchored regex instead). Expects the honest
#   CWD-relative advice, NOT the misleading --add-data one.
# - mei_genuine (CodeRabbit review, PR #458): entry.py reads a file via a path joined from
#   sys._MEIPASS -- PyInstaller's own real, randomly-named onefile extraction directory at
#   runtime -- never bundled via --add-data, so the open() genuinely fails with a path
#   rooted under a real _MEIxxxxxx folder. The only scenario that exercises the OTHER branch
#   of the fix: --add-data remains the correct, unchanged advice here. Closes the coverage
#   gap CodeRabbit's review flagged (both new scenarios above only ever exercise the
#   CWD-relative branch; nothing previously exercised the genuine-extraction-path branch at
#   all).
#
# Lane: real and conda-full only.
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

$scenario = $env:EXEDATA_SCENARIO
if ($scenario -notin @('mei_substring', 'mei_genuine')) { $scenario = 'plain' }

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.smokerun.exedata.xfail'
        req     = 'REQ-003'
        pass    = $true
        desc    = 'EXE smokerun XFAIL: missing data file exits non-zero (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host'; scenario = $scenario }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.smokerun.exedata.xfail'
        req     = 'REQ-003'
        pass    = $false
        desc    = 'EXE smokerun XFAIL: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath; scenario = $scenario }
    })
    exit 1
}

$workDir = Join-Path $here "~selftest_exedata_fail_$scenario"
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

if ($scenario -eq 'mei_substring') {
    # derived requirement: entry.py opens config_MEI99.json -- a bare, CWD-relative path whose
    # name coincidentally contains "_MEI" followed by digits, with no path separator on either
    # side (matching CodeRabbit's own "config_MEI.json" example shape). Must NOT be misread as
    # a genuine PyInstaller _MEIxxxxxx extraction-directory path.
    Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
with open("config_MEI99.json", "r") as f:
    print(f.read())
'@ -Encoding ASCII
    Set-Content -Path (Join-Path $workDir 'config_MEI99.json') -Value '{"msg": "hello-data"}' -Encoding ASCII
} elseif ($scenario -eq 'mei_genuine') {
    # derived requirement: entry.py reads a file joined from sys._MEIPASS, PyInstaller's own
    # real onefile extraction directory (a genuine, randomly-named _MEIxxxxxx folder at
    # runtime) -- never bundled via --add-data, so this always fails with a path genuinely
    # rooted under _MEIxxxxxx. Exercises the branch where --add-data remains correct advice.
    Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
import sys, os
p = os.path.join(sys._MEIPASS, "bundled_data.json")
with open(p, "r") as f:
    print(f.read())
'@ -Encoding ASCII
} else {
    # derived requirement: entry.py opens config.json via a relative path. PyInstaller does
    # not bundle arbitrary data files unless explicitly spec'd, so the EXE exits non-zero
    # when config.json is absent from the dist\ directory at runtime.
    Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
with open("config.json", "r") as f:
    print(f.read())
'@ -Encoding ASCII
    Set-Content -Path (Join-Path $workDir 'config.json') -Value '{"msg": "hello-data"}' -Encoding ASCII
}

$bootstrapLog = "~exedata_bootstrap_$scenario.log"

$prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'

Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    if ($null -eq $prev) {
        Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PIPREQS = $prev
    }
    Pop-Location
}

$logPath  = Join-Path $workDir $bootstrapLog
$setupLog = Join-Path $workDir '~setup.log'
$logLines = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupTxt = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined = ($logLines -join "`n") + "`n" + $setupTxt

# derived requirement: exact log phrases from :run_exe_smokerun in run_setup.bat.
# XFAIL: smokerun fires and reports a non-zero exit (expected failure) -> pass.
# XPASS: smokerun fires and reports exit 0 (unexpected success) -> fail.
$smokerunFiredPhrase = 'EXE smokerun: exited'
$smokerunPassPhrase  = 'EXE smokerun: exited 0 (ok)'

$smokerunFired  = $combined -match [regex]::Escape($smokerunFiredPhrase)
$smokerunPassed = $combined -match [regex]::Escape($smokerunPassPhrase)

# derived requirement (CLAUDE.md Active Backlog Item 38): honest CWD-relative advice for
# 'plain'/'mei_substring' (neither has a genuine _MEIxxxxxx path component); the original,
# unchanged --add-data advice for 'mei_genuine' (a real _MEIxxxxxx-rooted path).
$honestHintFired = $combined -match [regex]::Escape('will not fix this')
if ($scenario -eq 'mei_genuine') {
    # A random runtime-generated _MEIxxxxxx name means the exact --add-data line can't be
    # matched verbatim -- assert the stable parts instead: the advice text, the filename it
    # names, and a genuine _MEI<digits> path segment actually present in the captured log.
    $addDataHintFired = ($combined -match [regex]::Escape('Consider adding: --add-data')) -and
                         ($combined -match [regex]::Escape('bundled_data.json'))
    $genuineMeiPathSeen = $combined -match '_MEI\d+'
    $hintCorrect = $addDataHintFired -and $genuineMeiPathSeen -and (-not $honestHintFired)
} elseif ($scenario -eq 'mei_substring') {
    $misleadingHintAbsent = -not ($combined -match [regex]::Escape('Consider adding: --add-data config_MEI99.json'))
    $hintCorrect = $honestHintFired -and $misleadingHintAbsent
} else {
    $misleadingHintAbsent = -not ($combined -match [regex]::Escape('Consider adding: --add-data config.json'))
    $hintCorrect = $honestHintFired -and $misleadingHintAbsent
}

# xfailPass: smokerun fired AND did NOT report exit 0 AND the hint text is correct for this case
$xfailPass = $smokerunFired -and (-not $smokerunPassed) -and $hintCorrect

if ($scenario -eq 'mei_genuine') {
    $desc = 'EXE smokerun XFAIL: missing data file under a genuine _MEIxxxxxx extraction path causes non-zero exit (expected failure); --add-data advice correctly still fires for this case'
    $details = [ordered]@{
        scenario            = $scenario
        bootstrapExit       = $runExit
        smokerunFired       = $smokerunFired
        smokerunPassed      = $smokerunPassed
        addDataHintFired    = $addDataHintFired
        genuineMeiPathSeen  = $genuineMeiPathSeen
        honestHintAbsent    = (-not $honestHintFired)
        hintCorrect         = $hintCorrect
        xfailPass           = $xfailPass
        log                 = $bootstrapLog
    }
} elseif ($scenario -eq 'mei_substring') {
    $desc = 'EXE smokerun XFAIL: missing data file (name coincidentally contains _MEI+digits) causes non-zero exit (expected failure); hint text stays honest, not misled by the substring'
    $details = [ordered]@{
        scenario              = $scenario
        bootstrapExit         = $runExit
        smokerunFired         = $smokerunFired
        smokerunPassed        = $smokerunPassed
        honestHintFired       = $honestHintFired
        misleadingHintAbsent  = $misleadingHintAbsent
        hintCorrect           = $hintCorrect
        xfailPass             = $xfailPass
        log                   = $bootstrapLog
    }
} else {
    $desc = 'EXE smokerun XFAIL: missing data file causes non-zero exit (expected failure); hint text is honest about --add-data not fixing a CWD-relative access'
    $details = [ordered]@{
        scenario              = $scenario
        bootstrapExit         = $runExit
        smokerunFired         = $smokerunFired
        smokerunPassed        = $smokerunPassed
        honestHintFired       = $honestHintFired
        misleadingHintAbsent  = $misleadingHintAbsent
        hintCorrect           = $hintCorrect
        xfailPass             = $xfailPass
        log                   = $bootstrapLog
    }
}

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.smokerun.exedata.xfail'
    req     = 'REQ-003'
    pass    = $xfailPass
    desc    = $desc
    details = $details
})

if (-not $xfailPass) { exit 1 }
exit 0
