# ASCII only
# selfapps_layered_e2e.ps1 - CLAUDE.md Active Backlog item 22: a real, non-simulated
# end-to-end test proving THREE distinct REQ-009/REQ-007/REQ-016 mechanisms all fire for
# real in ONE run, replacing Part VII Scenario 33's [Extrapolated Branch] splice with
# genuine evidence:
#
#   1. uv-fails-to-conda provider cascade (REQ-009/REQ-005.10 slice 3): pygrib ships zero
#      Windows wheels on PyPI (confirmed via a direct PyPI JSON API query -- macOS/Linux
#      wheels exist for every recent CPython, Windows was deliberately excluded, and the
#      sdist needs the ecCodes/GRIB-API C library that a bare CI runner does not have), so
#      `uv pip install -r requirements.txt` genuinely fails to build it. conda-forge ships
#      real win-64 pygrib builds (verified via the anaconda.org API), so cascading to conda
#      genuinely resolves it.
#   2. warnfix repair (REQ-007), BOTH outcomes in the same round: pygrib and xlrd are both
#      genuinely absent after the failed bulk install (both statically imported, so both
#      land in PyInstaller's own warn file). warnfix's per-module loop tries each
#      separately -- xlrd has a real PyPI wheel and installs cleanly (genuine REPAIR
#      SUCCESS); pygrib genuinely fails again (genuine REPAIR FAILURE, the same real
#      cause as the bulk failure -- not a decoy). This is what drives the REQ-009 cascade
#      candidate detection: still-unresolved (pygrib) AND a real recorded install failure.
#   3. --hidden-import auto-recovery (REQ-016 Slice 2): colorama is imported only via
#      importlib.import_module('colorama'), invisible to PyInstaller's static analysis, so
#      it is never touched by warnfix. Once cascaded to conda, colorama installs
#      successfully as part of the ordinary bulk install (declared in requirements.txt),
#      but the frozen EXE still fails at runtime with ModuleNotFoundError (never bundled).
#      Because colorama IS installed in the (now conda) build interpreter, the strict
#      double-gate fires and a --hidden-import=colorama rebuild fixes it for real.
#
# GDAL/osgeo was the original candidate researched for mechanism 1, but was rejected after
# deeper research: GDAL's Python bindings live under the `osgeo` namespace
# (`from osgeo import gdal`), and PyInstaller's warn file always records the top-level
# import name ("osgeo"), not the actual PyPI distribution name ("gdal"/"GDAL"). PyPI hosts
# a real, always-succeeding dummy package literally named "osgeo" (a deliberate
# typosquat-protection placeholder for people who mistakenly `pip install osgeo`), so
# warnfix's own per-module repair attempt for GDAL would install that harmless dummy
# instead of failing -- silently defeating the REQ-009 cascade-candidate detection's
# Signal B (a REAL recorded install failure), which specifically checks
# ~warnfix_repair_failed.flag, set only by a genuine per-module install failure. pygrib's
# top-level import name IS its own correct PyPI/conda-forge package name (no namespace
# indirection, no decoy), so this same trap cannot occur.
#
# Needed test-only flag: HP_TEST_CASCADE_ANSWER=Y to accept the REQ-009 cascade consent
# prompt deterministically in CI (no way around an interactive prompt otherwise). No other
# HP_SKIP_*/HP_TEST_FORCE_*/HP_DISABLE_* flags are used -- pipreqs, the REQ-005.12
# autopep723 Tier 1 merge, and the REQ-005 heuristics all run normally; every failure and
# repair in this test is a genuine, unflagged consequence of the three packages' own real
# availability on PyPI vs. conda-forge.
#
# Lane: cache only (uv-first, and the only lane that already caches Miniconda across runs
# to amortize the one-time download this test's own cascade triggers). Non-gating for its
# first landing (the `cache` job is continue-on-error at the job level in batch-check.yml)
# -- promote once proven stable across several real runs, matching this repo's established
# graduation pattern (see CLAUDE.md's "CI lane gating maturity" periodic check).
#
# Emits: self.layered_e2e.chain
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

if (-not $IsWindows) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.layered_e2e.chain'
        req     = 'REQ-009'
        pass    = $true
        skip    = $true
        desc    = 'real layered dependency chain (cascade + warnfix + hidden-import) skipped on non-Windows'
        details = [ordered]@{ reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.layered_e2e.chain'
        req     = 'REQ-009'
        pass    = $false
        desc    = 'run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_layered_e2e'
# derived requirement: fail closed on stale-workspace cleanup -- $ErrorActionPreference is
# 'Continue' for the rest of this script (so later steps still write an NDJSON row/exit code
# on failure), which would otherwise let a failed Remove-Item (e.g. a locked dist\<env>.exe
# left over from a prior interrupted run) silently pass through, letting this run reuse stale
# dist/status/token/log files and pass for the wrong reason instead of exercising a genuinely
# fresh bootstrap. -ErrorAction Stop + an explicit existence re-check makes that failure loud.
# Wrapped in try/catch (rather than just letting the throw propagate) so a workspace-prep
# failure still emits the self.layered_e2e.chain NDJSON row -- a raw terminating error here
# would otherwise leave CI with no record of this test at all instead of an explicit failure.
try {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $workDir) {
            throw "selfapps_layered_e2e.ps1: failed to remove stale workspace: $workDir"
        }
    }
    New-Item -ItemType Directory -Force -Path $workDir -ErrorAction Stop | Out-Null
    Copy-Item -Path $batchPath -Destination $workDir -Force -ErrorAction Stop
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.layered_e2e.chain'
        req     = 'REQ-009'
        pass    = $false
        desc    = 'layered test workspace preparation failed'
        details = [ordered]@{ error = $_.Exception.Message }
    })
    exit 1
}

Set-Content -Path (Join-Path $workDir 'requirements.txt') -Value "pygrib`ncolorama`nxlrd" -Encoding ASCII

$appCode = @'
import pygrib
import xlrd
import importlib
import os as _os
import sys as _sys

_pygrib_ok = bool(pygrib)
_xlrd_ver = xlrd.__version__
_colorama_mod = importlib.import_module('colorama')

_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~layered_e2e_token.txt'), 'w') as _f:
    _f.write('pygrib=%s xlrd=%s colorama=%s\n' % (_pygrib_ok, _xlrd_ver, _colorama_mod.__name__))
print('pygrib/xlrd/colorama layered e2e ok')
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

# HP_TEST_CASCADE_ANSWER=Y: grant cascade consent deterministically (no prompt, no CI auto-decline).
# No other override -- pipreqs, Tier 1 autopep723 merge, and REQ-005 heuristics all run normally.
$prevCascade = if (Test-Path Env:HP_TEST_CASCADE_ANSWER) { $env:HP_TEST_CASCADE_ANSWER } else { $null }
$env:HP_TEST_CASCADE_ANSWER = 'Y'

$bootstrapLog = '~layered_e2e_bootstrap.log'
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    if ($null -eq $prevCascade) { Remove-Item Env:HP_TEST_CASCADE_ANSWER -ErrorAction SilentlyContinue } else { $env:HP_TEST_CASCADE_ANSWER = $prevCascade }
    Pop-Location
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# Mechanism 1: uv-fails-to-conda cascade.
$uvInstallFailed = $combined -match [regex]::Escape('[WARN] uv pip install -r requirements.txt failed; some packages may be missing.')
$cascadeDetected = $combined -match [regex]::Escape('[INFO] REQ-009: cascade candidate detected')
$cascadeApproved = $combined -match [regex]::Escape('[INFO] REQ-009: cascade approved; will re-attempt under the next provider tier.')
$uvToConda       = ([regex]::Matches($setupText, [regex]::Escape('REQ-009: cascading provider uv to conda'))).Count
$condaSelected   = $combined -match [regex]::Escape('REQ-009: Selected Python provider: Conda')

# Mechanism 2: warnfix repair, both outcomes in the SAME round -- derived requirement: a plain
# "does this string appear anywhere in the combined log" check (the original approach) cannot
# distinguish "both happened in one round" from "each happened in a different round," so it
# would not actually catch a future regression that split them across rounds. Scope the pygrib/
# xlrd checks to the single warnfix round's own text slice instead: from the round's start
# marker to the next "rebuild complete" marker (or end of log if the round never completed).
# $warnfixRoundCount -eq 1 additionally proves there was exactly one such round in this run, so
# the slice below cannot itself be straddling two rounds.
# derived requirement: match against $setupText ALONE, not $combined -- every :log-emitted line
# (including both markers below) is written to BOTH stdout (captured into $logLines) AND
# ~setup.log (%LOG%, see run_setup.bat's :log subroutine), so counting matches in $combined
# double-counts every occurrence. $uvToConda above already established this same
# single-source-for-counts convention; this reuses it rather than inventing a second one.
$warnInstallFired    = $setupText -match [regex]::Escape('[REPAIR] missing modules detected; installing and rebuilding.')
$warnfixRoundMatches = [regex]::Matches($setupText, [regex]::Escape('[REPAIR] missing modules detected; installing and rebuilding.'))
$warnfixRoundCount   = $warnfixRoundMatches.Count
$warnfixRoundText     = ''
$warnfixRoundComplete = $false
if ($warnfixRoundCount -ge 1) {
    $roundStart = $warnfixRoundMatches[0].Index
    $tail = $setupText.Substring($roundStart)
    $endMarker = [regex]::Match($tail, [regex]::Escape('[REPAIR] rebuild complete after warnfix.'))
    # derived requirement: an incomplete round (no completion marker -- e.g. the rebuild itself
    # errored, or the log was truncated) must NOT count as same-round evidence just because the
    # rest of the log happens to still contain both substrings; require the marker explicitly
    # rather than falling back to "everything to EOF."
    if ($endMarker.Success) {
        $warnfixRoundText = $tail.Substring(0, $endMarker.Index + $endMarker.Length)
        $warnfixRoundComplete = $true
    }
}
$pygribAttempted  = $warnfixRoundText -match [regex]::Escape('[INFO] Attempting to install: pygrib')
$pygribFailed     = $warnfixRoundText -match [regex]::Escape('[WARN] Repair failed: pygrib')
$xlrdAttempted    = $warnfixRoundText -match [regex]::Escape('[INFO] Attempting to install: xlrd')
$xlrdInstalled    = $warnfixRoundText -match [regex]::Escape('[INFO] Installed: xlrd')

# Mechanism 3: hidden-import auto-recovery for colorama, after the cascade.
$hiddenAdding     = $combined -match [regex]::Escape('[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama')
$hiddenRecovered  = $combined -match [regex]::Escape('[REPAIR][HIDDEN_IMPORT] EXE verified after hidden-import recovery')

$infraError = $combined -match 'Failed to parse|uv error|pip error'

# Final EXE: built under conda (the tier the cascade lands on), run for real.
$envLeaf  = Split-Path $workDir -Leaf
$envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_layered_e2e' }
$distDir  = Join-Path $workDir 'dist'
$exePath  = Join-Path $distDir "$envName.exe"
$exeExists = Test-Path -LiteralPath $exePath
$exeExit   = -1
$tokenPath = Join-Path $distDir '~layered_e2e_token.txt'
$tokenFound = $false

if ($exeExists) {
    try {
        Push-Location -LiteralPath $distDir
        try {
            cmd /c "`"$exePath`"" *> '~layered_e2e_exe.log'
            $exeExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $tokenFound = Test-Path -LiteralPath $tokenPath
    } catch {
        $exeExit = -1
    }
}

$statusPath = Join-Path $workDir '~bootstrap.status.json'
$statusExit = $null
$statusState = $null
if (Test-Path $statusPath) {
    try {
        $status = Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json
        $statusExit = $status.exitCode
        $statusState = $status.state
    } catch {
        Write-Warning "Failed to parse ${statusPath}: $($_.Exception.Message)"
    }
}

$mech1Pass = $uvInstallFailed -and $cascadeDetected -and $cascadeApproved -and ($uvToConda -eq 1) -and $condaSelected
$mech2Pass = $warnInstallFired -and ($warnfixRoundCount -eq 1) -and $warnfixRoundComplete -and $pygribAttempted -and $pygribFailed -and $xlrdAttempted -and $xlrdInstalled
$mech3Pass = $hiddenAdding -and $hiddenRecovered
$exePass   = $exeExists -and ($exeExit -eq 0) -and $tokenFound -and (-not $infraError)
$chainPass = $mech1Pass -and $mech2Pass -and $mech3Pass -and $exePass -and ($statusExit -eq 0) -and ($statusState -eq 'ok')

# Self-diagnosis: run_setup.bat output is redirected to the bootstrap log file, so without
# this the CI job log shows nothing about what the chain actually did.
Write-Host "=== self.layered_e2e.chain evidence ==="
Write-Host ("mech1Pass={0} mech2Pass={1} mech3Pass={2} exePass={3} statusExit={4} statusState={5} runExit={6} chainPass={7}" -f `
    $mech1Pass, $mech2Pass, $mech3Pass, $exePass, $statusExit, $statusState, $runExit, $chainPass)
Write-Host "=== REQ-009 / warnfix / hidden-import lines (setup log) ==="
($setupText -split "`n") | Where-Object { $_ -match 'REQ-009|REPAIR|HIDDEN_IMPORT|Selected Python provider|Attempting to install|Installed:|Repair failed' } | Select-Object -First 100 | ForEach-Object { Write-Host $_ }
Write-Host "=== bootstrap stdout log tail (50) ==="
$logLines | Select-Object -Last 50 | ForEach-Object { Write-Host $_ }
Write-Host "=== end self.layered_e2e.chain evidence ==="

Write-NdjsonRow ([ordered]@{
    id      = 'self.layered_e2e.chain'
    req     = 'REQ-009'
    pass    = [bool]$chainPass
    desc    = 'real, unflagged chain: uv fails on pygrib -> cascades to conda; warnfix fixes xlrd but genuinely fails on pygrib (driving the cascade); hidden-import-recovery fixes colorama after the cascade'
    details = [ordered]@{
        mech1Pass        = $mech1Pass
        uvInstallFailed  = $uvInstallFailed
        cascadeDetected  = $cascadeDetected
        cascadeApproved  = $cascadeApproved
        uvToConda        = $uvToConda
        condaSelected    = $condaSelected
        mech2Pass        = $mech2Pass
        warnInstallFired = $warnInstallFired
        warnfixRoundCount    = $warnfixRoundCount
        warnfixRoundComplete = $warnfixRoundComplete
        pygribAttempted  = $pygribAttempted
        pygribFailed     = $pygribFailed
        xlrdAttempted    = $xlrdAttempted
        xlrdInstalled    = $xlrdInstalled
        mech3Pass        = $mech3Pass
        hiddenAdding     = $hiddenAdding
        hiddenRecovered  = $hiddenRecovered
        exePass          = $exePass
        exeExists        = $exeExists
        exeExit          = $exeExit
        tokenFound       = $tokenFound
        infraError       = $infraError
        statusExit       = $statusExit
        statusState      = $statusState
        runExit          = $runExit
        exePath          = $exePath
    }
})

if (-not $chainPass) { exit 1 }
exit 0
