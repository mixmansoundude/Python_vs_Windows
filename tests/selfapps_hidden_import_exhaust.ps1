# ASCII only
# selfapps_hidden_import_exhaust.ps1 - REQ-016 Slice 2: strict --hidden-import auto-recovery
# EXHAUSTION path. CLAUDE.md Active Backlog item 11.
#
# selfapps_hidden_import.ps1 (its sibling) only exercises the one-shot-recoverable SUCCESS path
# (a single dynamically-imported, installed-but-uncollected module, fixed by exactly one
# --hidden-import rebuild). No existing test drives HP_HIDDEN_ITER to its 3-attempt cap without
# ever exiting 0 -- this is that test.
#
# The stub app rotates through THREE distinct, always-installed (via requirements.txt) modules
# on successive launches, using a small state file (~hidden_exhaust_state.txt, next to the EXE,
# surviving across the recovery loop's own rebuilds) to pick a different fabricated
# "ModuleNotFoundError: No module named 'X'" each time -- deliberately NOT a real failed import,
# just text printed to stderr, so the failure signature is exact and deterministic regardless of
# whether the named module actually ends up bundled.
#
# Why 3 DISTINCT modules, not one repeated: ~hidden_import_scan.py's own tried-list exclusion
# means a REPEATED module name is treated as already-fixed and returns nothing, which would stop
# the loop via the "no next hidden import found" exit (run_setup.bat's own
# "if not defined HP_NEXT_HIDDEN goto :hidden_import_recover_done" check) well before the
# 3-iteration cap -- exactly the gap this test closes.
#
# Traced launch sequence (state index 0 = the very first EXE smoke run in :run_exe_smokerun,
# BEFORE :hidden_import_recover is ever entered -- its stderr is never scanned, so its module
# choice is irrelevant): loop launch 1 (idx 1 -> modules[1%3]) is discovered and fixed
# (ITER=1), loop launch 2 (idx 2 -> modules[2%3]) is discovered and fixed (ITER=2), loop launch 3
# (idx 3 -> modules[0], same as idx 0 but NOT yet in the tried set since idx 0's output was
# never scanned) is discovered and fixed (ITER=3), loop launch 4 (idx 4 -> modules[1%3], same
# module already fixed at ITER=1) hits the "if %HP_HIDDEN_ITER% GEQ 3" cap check BEFORE the scan
# even runs -- exhaustion, HP_EXE_EXIT stays nonzero, and the WARN line under test fires.
#
# Asserts: exactly 3 "[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=" lines (proves the loop
# stopped at the ITERATION cap, not an early "nothing left to try" exit), the exhaustion WARN
# line, the app never actually verifies (no "EXE verified after hidden-import recovery" line),
# and ~bootstrap.status.json still reads state=ok (the user program's own perpetual failure is
# not a bootstrapper failure -- see CLAUDE.md's "User-code exit-code semantics" Known Finding,
# and this test's sibling self.exe.hidden_import for the same non-assertion-of-exit-code
# convention this repo already uses for user-code-outcome tests).
#
# Emits: self.exe.hidden_import.exhaust
# Lane: real and conda-full (matches selfapps_hidden_import.ps1).
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
        id      = 'self.exe.hidden_import.exhaust'
        req     = 'REQ-016'
        pass    = $true
        desc    = 'Strict --hidden-import auto-recovery exhaustion (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.hidden_import.exhaust'
        req     = 'REQ-016'
        pass    = $false
        desc    = 'Hidden-import recovery exhaustion: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_hidden_import_exhaust'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# All three rotated modules are genuinely installed (requirements.txt) so ~hidden_import_scan.py's
# find_spec "installed" gate always passes for each -- none are ever a typo/not-installed no-op.
Set-Content -Path (Join-Path $workDir 'requirements.txt') -Value "colorama`nsix`ncertifi" -Encoding ASCII
$appCode = @'
import os
import sys

_here = os.path.dirname(os.path.abspath(sys.argv[0]))
_state_path = os.path.join(_here, '~hidden_exhaust_state.txt')
try:
    with open(_state_path, 'r') as f:
        _idx = int(f.read().strip())
except (OSError, ValueError):
    _idx = 0
with open(_state_path, 'w') as f:
    f.write(str(_idx + 1))

_modules = ['colorama', 'six', 'certifi']
_mod = _modules[_idx % len(_modules)]
sys.stderr.write("Traceback (most recent call last):\n")
sys.stderr.write("  File \"app.py\", line 1, in <module>\n")
sys.stderr.write("ModuleNotFoundError: No module named '%s'\n" % _mod)
sys.exit(1)
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$bootstrapLog = '~hidden_exhaust_bootstrap.log'
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    Pop-Location
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

$addingCount    = ([regex]::Matches($combined, [regex]::Escape('[REPAIR][HIDDEN_IMPORT] Adding --hidden-import='))).Count
$exhaustedFired = $combined -match [regex]::Escape('[WARN][HIDDEN_IMPORT] Auto-recovery exhausted after 3 attempts; module(s) still missing.')
$recoveredFired = $combined -match [regex]::Escape('[REPAIR][HIDDEN_IMPORT] EXE verified after hidden-import recovery')
$infraError     = $combined -match 'Failed to parse|uv error|pip error'

$statusPath = Join-Path $workDir '~bootstrap.status.json'
$statusText = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw } else { $null }
$statusState = $null
if ($statusText) {
    try { $statusState = ($statusText | ConvertFrom-Json).state } catch { $statusState = $null }
}

$exhaustPass = ($addingCount -eq 3) -and $exhaustedFired -and (-not $recoveredFired) -and (-not $infraError) -and ($statusState -eq 'ok')
Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.hidden_import.exhaust'
    req     = 'REQ-016'
    pass    = $exhaustPass
    desc    = 'Strict --hidden-import recovery exhausts after 3 attempts when the app never actually succeeds'
    details = [ordered]@{
        bootstrapExit   = $runExit
        addingCount     = $addingCount
        exhaustedFired  = $exhaustedFired
        recoveredFired  = $recoveredFired
        infraError      = $infraError
        statusState     = $statusState
        log             = $bootstrapLog
    }
})

if (-not $exhaustPass) { exit 1 }
exit 0
