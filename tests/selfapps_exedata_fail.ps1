# ASCII only
# selfapps_exedata_fail.ps1 - XFAIL test: EXE smokerun expected to fail when entry.py
# opens a data file not bundled by PyInstaller. Bootstrap completes (exitCode=0) but the
# built EXE exits non-zero at runtime. Test passes (xfail) when smokerun reports failure.
# Test fails (xpass) if smokerun unexpectedly reports exit 0.
#
# Two scenarios (EXEDATA_SCENARIO env var; unset defaults to 'plain'), both asserting
# :exe_smokerun_hints' CLAUDE.md Item 38 fix (honest advice for a CWD-relative missing
# file, real --add-data advice only for a genuine _MEIxxxxxx extraction path):
# - plain: entry.py opens "config.json" -- a bare CWD-relative path, no _MEI anywhere.
# - mei_substring (CodeRabbit review, PR #458): entry.py opens "config_MEI99.json" -- a
#   bare CWD-relative path whose NAME happens to contain "_MEI" followed by digits as a
#   coincidental substring, with no path separator on either side. Regression test for the
#   exact false-positive shape CodeRabbit's review flagged in the original plain findstr
#   substring match (fixed via a path-component-anchored regex instead) -- proves the fix
#   still gives the honest CWD-relative advice here, not the genuine-extraction-path one.
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
if (-not $scenario) { $scenario = 'plain' }

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    if ($scenario -eq 'mei_substring') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.smokerun.exedata.xfail'
            req     = 'REQ-003'
            pass    = $true
            desc    = 'EXE smokerun XFAIL: missing data file exits non-zero (skipped on non-Windows)'
            details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host'; scenario = $scenario }
        })
    } else {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.smokerun.exedata.xfail'
            req     = 'REQ-003'
            pass    = $true
            desc    = 'EXE smokerun XFAIL: missing data file exits non-zero (skipped on non-Windows)'
            details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host'; scenario = $scenario }
        })
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    if ($scenario -eq 'mei_substring') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.smokerun.exedata.xfail'
            req     = 'REQ-003'
            pass    = $false
            desc    = 'EXE smokerun XFAIL: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath; scenario = $scenario }
        })
    } else {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.exe.smokerun.exedata.xfail'
            req     = 'REQ-003'
            pass    = $false
            desc    = 'EXE smokerun XFAIL: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath; scenario = $scenario }
        })
    }
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

# derived requirement (CLAUDE.md Active Backlog Item 38): a bare, CWD-relative path -- no
# genuine _MEIxxxxxx marker, even if "mei_substring" coincidentally contains that text as a
# substring -- must get :exe_smokerun_hints' honest "place it next to the .exe" advice, not
# the misleading --add-data suggestion (which bundles into a temp extraction folder, never
# the working directory, so it would not actually fix this failure mode).
$honestHintFired = $combined -match [regex]::Escape('will not fix this')
if ($scenario -eq 'mei_substring') {
    $misleadingHintAbsent = -not ($combined -match [regex]::Escape('Consider adding: --add-data config_MEI99.json'))
} else {
    $misleadingHintAbsent = -not ($combined -match [regex]::Escape('Consider adding: --add-data config.json'))
}
$hintCorrect = $honestHintFired -and $misleadingHintAbsent

# xfailPass: smokerun fired AND did NOT report exit 0 AND the hint text is honest for this case
$xfailPass = $smokerunFired -and (-not $smokerunPassed) -and $hintCorrect

if ($scenario -eq 'mei_substring') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.smokerun.exedata.xfail'
        req     = 'REQ-003'
        pass    = $xfailPass
        desc    = 'EXE smokerun XFAIL: missing data file (name coincidentally contains _MEI+digits) causes non-zero exit (expected failure); hint text stays honest, not misled by the substring'
        details = [ordered]@{
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
    })
} else {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.smokerun.exedata.xfail'
        req     = 'REQ-003'
        pass    = $xfailPass
        desc    = 'EXE smokerun XFAIL: missing data file causes non-zero exit (expected failure); hint text is honest about --add-data not fixing a CWD-relative access'
        details = [ordered]@{
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
    })
}

if (-not $xfailPass) { exit 1 }
exit 0
