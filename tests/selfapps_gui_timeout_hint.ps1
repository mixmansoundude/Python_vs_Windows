# ASCII only
# selfapps_gui_timeout_hint.ps1 - CLAUDE.md Active Backlog Item 41: a working GUI app is
# force-killed at the ~30s build-verification deadline (:run_exe_smokerun's activity-aware kill,
# ~exe_smokerun.ps1's own $sawOutput gate -- see docs/agent-interconnect.md "Activity-aware
# EXE-smoke kill") because it produces zero console output, exactly the same silence a genuinely
# hung program produces. HP_EXE_EXIT=="-1" (TIMED OUT) at that point in run_setup.bat already
# implies $sawOutput was false when the kill fired (the kill is gated on it), so no new runtime
# signal was needed -- run_setup.bat now records HP_EXE_TIMEDOUT_SILENT at that exact point and
# the post-flight caveat panel (:pfb_caveat) prints a GUI-app-aware note distinguishing this case
# from a genuine crash/hang, instead of leaving a beginner to read the generic caveat as evidence
# something is broken.
#
# This test does not launch a real GUI (no display/Xvfb available on a headless Windows CI
# runner, and building one would be its own, much larger and more fragile undertaking) -- it
# reproduces the exact SIGNAL the mechanism reacts to instead: a frozen EXE that produces zero
# stdout/stderr and blocks past the kill deadline. That is sufficient, since :pfb_caveat's new
# branch only ever inspects HP_EXE_TIMEDOUT_SILENT, never anything GUI-specific itself.
#
# HP_SMOKERUN_KILL_MS is a pre-existing test-only override (~exe_smokerun.ps1 reads
# $env:HP_SMOKERUN_KILL_MS directly; production run_setup.bat never sets it, so this is inherited
# from this test's own process environment with no run_setup.bat code change needed -- see
# tests/test_exe_smokerun.py for the identical override technique used at the Python-unit-test
# level). Set well above typical PyInstaller onefile cold-start extraction time (documented as
# commonly 1-3+ seconds even on an idle machine, see docs/agent-lessons-learned.md's "widened to
# 10000ms" entry for the sibling fail-fast-probe window) so a slow-but-genuinely-silent extraction
# cannot be misclassified, while staying far below the real 30000ms production default to keep
# this test fast.
#
# Lane: uv only, non-gating for its first landing -- this exercises HP_SMOKERUN_KILL_MS from a
# full-bootstrap selfapps test for the first time (previously only exercised at the Python-unit
# level against a plain pwsh-launched script, not a real PyInstaller-frozen EXE's own cold-start
# behavior), so it could not be verified against a real Windows PyInstaller build locally --
# matches this repo's established graduation pattern (see CLAUDE.md's "CI lane gating maturity"
# periodic check) for a new mechanism not yet proven stable across several real runs.
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

function Write-Row {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.exe.timeout_gui_hint'; req = 'CLAUDE.md-Item-41'; pass = $Pass; desc = $Desc; details = $Details })
}

# Non-Windows skip
$platform = [System.Environment]::OSVersion.Platform.ToString()
if ($platform -ne 'Win32NT') {
    Write-Row -Pass $true -Desc 'GUI-timeout caveat hint (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-Row -Pass $false -Desc 'GUI-timeout caveat hint: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

$workDir = Join-Path $here '~selftest_gui_timeout_hint'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# derived requirement: zero print()/output of any kind, then block well past the shortened kill
# window -- reproduces the exact "silent + force-stopped" shape a correctly-behaving GUI
# mainloop() produces, without needing a real display.
Set-Content -Path (Join-Path $workDir 'app.py') -Value @'
import time
time.sleep(600)
'@ -Encoding ASCII

$bootstrapLog = '~gui_timeout_hint_bootstrap.log'

$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevKillMs = if (Test-Path Env:HP_SMOKERUN_KILL_MS) { $env:HP_SMOKERUN_KILL_MS } else { $null }
$env:HP_SKIP_PIPREQS = '1'
$env:HP_SMOKERUN_KILL_MS = '12000'

try {
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1 < nul"
        $runExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $logPath  = Join-Path $workDir $bootstrapLog
    $logLines = if (Test-Path $logPath) { Get-Content -LiteralPath $logPath -Encoding ASCII } else { @() }
    $combined = $logLines -join "`n"

    $timedOutFound  = $combined -match [regex]::Escape('Run Status: TIMED OUT')
    $caveatFound    = $combined -match [regex]::Escape('SETUP COMPLETE -- WITH A CAVEAT')
    $guiHintFound   = $combined -match [regex]::Escape('this can happen for a GUI app, e.g. tkinter or PyQt')
    $exeExists      = Test-Path (Join-Path $workDir 'dist')

    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusText = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw } else { $null }
    $statusState = $null
    if ($statusText) {
        try { $statusState = ($statusText | ConvertFrom-Json).state } catch { $statusState = $null }
    }

    # derived requirement: the EXE must have genuinely been BUILT (a real PyInstaller success) --
    # otherwise this would be exercising :print_no_exe_briefing's own, unrelated caveat path
    # instead of :print_postflight_briefing's :pfb_gui_hint branch this test targets.
    $pass = $timedOutFound -and $caveatFound -and $guiHintFound -and $exeExists

    Write-Row -Pass $pass -Desc 'GUI-timeout caveat hint: a silent, force-killed EXE gets the GUI-aware caveat note' -Details ([ordered]@{
        bootstrapExit  = $runExit
        timedOutFound  = [bool]$timedOutFound
        caveatFound    = [bool]$caveatFound
        guiHintFound   = [bool]$guiHintFound
        exeExists      = [bool]$exeExists
        statusState    = $statusState
        log            = $bootstrapLog
    })
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevKillMs) { Remove-Item Env:HP_SMOKERUN_KILL_MS -ErrorAction SilentlyContinue } else { $env:HP_SMOKERUN_KILL_MS = $prevKillMs }
}

if (-not $pass) { exit 1 }
exit 0
