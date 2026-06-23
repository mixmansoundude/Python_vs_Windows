# ASCII only
# selfapps_cascade.ps1 - REQ-009/REQ-005.10 slice 3: provider-cascade EXECUTION test.
#
# Validates that when warnfix leaves a dependency unresolved under the current provider AND
# the user approves (HP_TEST_CASCADE_ANSWER=Y), run_setup.bat re-attempts the dependency
# phase under the NEXT REQ-009 provider tier -- and that the per-tier HP_CASCADE_TRIED_*
# guards make the cascade exhaust the tiers and STOP (no tier is retried, no infinite loop).
#
# The app imports a nonexistent module (fake_pkg_cascade_xyz). PyInstaller's static analysis
# writes it to the warn file, so warnfix fires under every tier and genuinely fails to install
# it, marking a cascade candidate each time. With consent granted the run walks the priority
# path uv -> conda (the main gain: conda is the strongest solver) and then conda -> venv, then
# stops at venv -> system because system fallback is not enabled. The final build is kept.
#
# This lane is NON-GATING (continue-on-error) and deliberately heavy: the uv -> conda step
# downloads Miniconda mid-run. It must run uv-first (do NOT set HP_FORCE_CONDA_ONLY).
#
# Emits: self.cascade.exec
#
# Lane: cascade-exec (non-gating). Windows only.
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

# Non-Windows skip (batch bootstrapper only runs on Windows).
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.cascade.exec'
        req     = 'REQ-009'
        pass    = $true
        skip    = $true
        desc    = 'provider cascade execution (uv -> conda -> ...) skipped on non-Windows'
        details = [ordered]@{ platform = $platform }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.cascade.exec'
        req     = 'REQ-009'
        pass    = $false
        desc    = 'run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_cascade_exec'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# derived requirement: a static "import fake_pkg_cascade_xyz" makes PyInstaller's static
# analysis flag the module in warn-<envname>.txt. It does not exist on any index, so warnfix
# fails to install it under uv, conda, and venv alike -- a cascade candidate fires at each tier.
$appCode = @'
import fake_pkg_cascade_xyz
import os as _os
import sys as _sys
_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~cascade_token.txt'), 'w') as _f:
    _f.write('cascade-exec-ok\n')
print('wrote token')
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

# HP_SKIP_PIPREQS=1: keep the fake module out of pipreqs/conda install so warnfix is the path.
# HP_DISABLE_HEURISTICS=1: no heuristic can touch the fake module; warnfix is the only repair.
# HP_TEST_CASCADE_ANSWER=Y: grant cascade consent deterministically (no prompt, no CI auto-decline).
$prevSkip     = if (Test-Path Env:HP_SKIP_PIPREQS)       { $env:HP_SKIP_PIPREQS }       else { $null }
$prevDisableH = if (Test-Path Env:HP_DISABLE_HEURISTICS) { $env:HP_DISABLE_HEURISTICS } else { $null }
$prevCascade  = if (Test-Path Env:HP_TEST_CASCADE_ANSWER){ $env:HP_TEST_CASCADE_ANSWER }else { $null }
$env:HP_SKIP_PIPREQS       = '1'
$env:HP_DISABLE_HEURISTICS = '1'
$env:HP_TEST_CASCADE_ANSWER = 'Y'

$bootstrapLog = '~cascade_exec_bootstrap.log'
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    if ($null -eq $prevSkip)     { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue }       else { $env:HP_SKIP_PIPREQS = $prevSkip }
    if ($null -eq $prevDisableH) { Remove-Item Env:HP_DISABLE_HEURISTICS -ErrorAction SilentlyContinue } else { $env:HP_DISABLE_HEURISTICS = $prevDisableH }
    if ($null -eq $prevCascade)  { Remove-Item Env:HP_TEST_CASCADE_ANSWER -ErrorAction SilentlyContinue }else { $env:HP_TEST_CASCADE_ANSWER = $prevCascade }
    Pop-Location
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# Cascade execution evidence (exact phrases from run_setup.bat :provider_cascade).
# IMPORTANT: count against a SINGLE log source ($setupText = ~setup.log). :log writes every
# line to BOTH stdout (captured in $logLines) AND ~setup.log, so counting against $combined
# would double every occurrence and break the "-eq 1" / no-loop checks.
$uvToConda    = ([regex]::Matches($setupText, [regex]::Escape('REQ-009: cascading provider uv -> conda'))).Count
$condaToVenv  = ([regex]::Matches($setupText, [regex]::Escape('REQ-009: cascading provider conda -> venv'))).Count
$venvToSystem = ([regex]::Matches($setupText, [regex]::Escape('REQ-009: cascading provider venv -> system'))).Count
# Conda was actually selected after the uv -> conda cascade.
$condaSelected = $combined -match [regex]::Escape('REQ-009: Selected Python provider: Conda')
# Terminal state: a "keeping current build" line means the cascade stopped (did not loop).
$terminated = $combined -match [regex]::Escape('keeping current build')
# No tier was used as a cascade source more than once (per-tier guard works -> no loop).
$noLoop = ($uvToConda -le 1) -and ($condaToVenv -le 1) -and ($venvToSystem -le 1)

# Bootstrap status: the run must end gracefully (exitCode 0) despite the unresolvable dep.
$statusPath = Join-Path $workDir '~bootstrap.status.json'
$statusExit = $null
$statusState = $null
if (Test-Path $statusPath) {
    try {
        $status = Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json
        $statusExit = $status.exitCode
        $statusState = $status.state
    } catch { }
}

# Primary criteria: the priority uv -> conda cascade executed and selected conda, the run
# terminated (did not loop), no tier was retried, and the bootstrap ended gracefully (exit 0).
$execPass = ($uvToConda -eq 1) -and $condaSelected -and $terminated -and $noLoop -and ($statusExit -eq 0)

Write-NdjsonRow ([ordered]@{
    id      = 'self.cascade.exec'
    req     = 'REQ-009'
    pass    = [bool]$execPass
    desc    = 'cascade executes uv -> conda on consent, re-attempts deps, never retries a tier, ends gracefully'
    details = [ordered]@{
        uvToConda     = $uvToConda
        condaToVenv   = $condaToVenv
        venvToSystem  = $venvToSystem
        condaSelected = $condaSelected
        terminated    = $terminated
        noLoop        = $noLoop
        statusExit    = $statusExit
        statusState   = $statusState
        runExit       = $runExit
    }
})

if (-not $execPass) { exit 1 }
exit 0
