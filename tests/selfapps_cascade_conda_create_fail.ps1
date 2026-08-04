# ASCII only
# selfapps_cascade_conda_create_fail.ps1 - Regression coverage for CLAUDE.md Active Backlog
# Item 23: a genuine (non-test-bypassed) conda-create failure reached during a REQ-009 cascade
# re-entry previously fell through :die into :conda_create_done's own success path instead of
# routing through :after_cascade_decision like every other cascade-target failure, so the
# bootstrap could not gracefully keep the previous working uv build. Fixed by adding
# "if defined HP_CASCADE_SAVED_PY goto :cascade_conda_create_failed" at both :conda_create_failed
# fall-through sites, plus a new :cascade_conda_create_failed label mirroring the existing
# :cascade_conda_unavailable / :cascade_embed_unavailable / :cascade_venv_unavailable /
# :cascade_system_unavailable template.
#
# Two scenarios (CASCADE_CCF_SCENARIO env var; unset/anything-but-missing_python defaults to
# create_fails, the original scenario, for CI-wiring back-compat):
#
# create_fails (default): forces a GENUINE failure through the real conda-create/retry code path
# (not the :hp_test_conda_fail bypass HP_TEST_FORCE_CONDA_FAIL uses, which CLAUDE.md's Item 23
# entry explicitly says is NOT sufficient evidence of this gap being covered) via
# HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL=1 (run_setup.bat, :try_conda_create) -- unlike the
# existing HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL (first attempt only, then clears itself so
# the retry can genuinely succeed), this flag persists through the retry too, so both the
# initial attempt and the retry fail deterministically without depending on real network
# conditions. Exercises :conda_create_failed's own call site of the fix.
#
# missing_python: a CodeRabbit review finding on this PR (see PR #413) noted the ORIGINAL
# scenario never exercises the fix's OTHER call site -- inside :conda_create_done's own
# "if not exist %HP_PY%" block, reached when conda create itself genuinely SUCCEEDS but the
# resulting environment is somehow missing python.exe. Forces this via
# HP_TEST_FORCE_CONDA_MISSING_PYTHON=1 (run_setup.bat, :conda_create_done), which lets the real
# conda create command run and succeed for real, then deletes the python.exe it just produced --
# a genuine successful create followed by a genuinely missing interpreter, not a simulated create
# failure. HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL is deliberately NOT set in this scenario (the
# create must succeed for real to reach :conda_create_done at all).
#
# Both scenarios: the app imports a nonexistent module (fake_pkg_cascade_xyz, same trick as
# selfapps_cascade.ps1) so warnfix genuinely fails to resolve it under uv, marking a cascade
# candidate. With HP_TEST_CASCADE_ANSWER=Y the run cascades uv -> conda, reaching
# :try_conda_create as a :cascade_from_uv re-entry (HP_CASCADE_SAVED_PY is set at this point,
# holding the working uv interpreter path). HP_TEST_FORCE_EMBED_FAIL=1, HP_TEST_FORCE_VENV_FAIL=1,
# and HP_TEST_SYSCON_ANSWER=N exhaust :handle_conda_failure's own embed/venv/system fallback chain
# deterministically in both scenarios, so HP_ENV_READY never gets set and the fix's own check is
# actually reached (not short-circuited by an unrelated fallback succeeding).
#
# Asserts (both scenarios): the cascade fired to conda exactly once, the new "cascade target
# conda create failed; keeping current build" WARN line fired, the old hard-failure
# "[ERROR] conda env create failed."/"[ERROR] python.exe missing from conda environment." lines
# never reached :die's own log output, and -- the key behavioral difference the fix makes --
# ~bootstrap.status.json reads state=ok (not error), since HP_BOOTSTRAP_STATE is still its
# default "ok" at this point in the run and :after_cascade_decision preserves it, matching every
# other "keeping current build" cascade-decline exit. Before the fix this would have fallen
# through :die (which stamps state=error) and continued executing with a broken HP_PY instead.
# create_fails additionally asserts both the simulated initial-attempt and retry-attempt failures
# engaged; missing_python additionally asserts the real create succeeded and the missing-python.exe
# WARN specifically fired (distinguishing it from the create-itself-failed path).
#
# Placement: must run AFTER selfapps_cascade.ps1 in the same uv-lane job -- that step already
# downloads and installs Miniconda for real, so by the time this step runs CONDA_BAT is already
# cached and :cascade_acquire_conda's own real-install branch is skipped (mirrors
# selfapps_conda_bothfail.ps1's own documented CI-ordering constraint, just the opposite
# direction: that test needs Miniconda NOT yet installed, this one wants it already installed).
# missing_python additionally needs a real (not simulated-failure) conda create to complete, which
# is slower than create_fails's immediate simulated failure -- both scenarios still rely on the
# same already-cached Miniconda binary, just with a genuinely longer create step in this one.
#
# Emits: self.cascade.conda_create_fail
#
# Lane: uv only, non-gating (depends on selfapps_cascade.ps1 having already run in the same job).
param()
$ErrorActionPreference = 'Continue'
$scenario = $env:CASCADE_CCF_SCENARIO
if ($scenario -ne 'missing_python') { $scenario = 'create_fails' }
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
        id      = 'self.cascade.conda_create_fail'
        req     = 'REQ-009'
        pass    = $true
        skip    = $true
        desc    = 'cascade-reentry conda-create failure gracefully keeps previous build (skipped on non-Windows)'
        details = [ordered]@{ platform = $platform }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.cascade.conda_create_fail'
        req     = 'REQ-009'
        pass    = $false
        desc    = 'run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_cascade_conda_create_fail'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# derived requirement: a static "import fake_pkg_cascade_xyz" makes PyInstaller's static
# analysis flag the module in warn-<envname>.txt. It does not exist on any index, so warnfix
# genuinely fails to install it under uv, marking a cascade candidate (same trick as
# selfapps_cascade.ps1).
$appCode = @'
import fake_pkg_cascade_xyz
print("should-not-run")
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$prevSkip        = if (Test-Path Env:HP_SKIP_PIPREQS)                     { $env:HP_SKIP_PIPREQS }                     else { $null }
$prevDisableH    = if (Test-Path Env:HP_DISABLE_HEURISTICS)               { $env:HP_DISABLE_HEURISTICS }               else { $null }
$prevCascade     = if (Test-Path Env:HP_TEST_CASCADE_ANSWER)              { $env:HP_TEST_CASCADE_ANSWER }              else { $null }
$prevCcBothFail  = if (Test-Path Env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL){ $env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL }else { $null }
$prevCcMissPy    = if (Test-Path Env:HP_TEST_FORCE_CONDA_MISSING_PYTHON)  { $env:HP_TEST_FORCE_CONDA_MISSING_PYTHON }  else { $null }
$prevEmbedFail   = if (Test-Path Env:HP_TEST_FORCE_EMBED_FAIL)            { $env:HP_TEST_FORCE_EMBED_FAIL }            else { $null }
$prevVenvFail    = if (Test-Path Env:HP_TEST_FORCE_VENV_FAIL)             { $env:HP_TEST_FORCE_VENV_FAIL }             else { $null }
$prevSyscon      = if (Test-Path Env:HP_TEST_SYSCON_ANSWER)               { $env:HP_TEST_SYSCON_ANSWER }               else { $null }
$env:HP_SKIP_PIPREQS        = '1'
$env:HP_DISABLE_HEURISTICS  = '1'
$env:HP_TEST_CASCADE_ANSWER = 'Y'
if ($scenario -eq 'missing_python') {
    $env:HP_TEST_FORCE_CONDA_MISSING_PYTHON = '1'
} else {
    $env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL = '1'
}
$env:HP_TEST_FORCE_EMBED_FAIL = '1'
$env:HP_TEST_FORCE_VENV_FAIL  = '1'
$env:HP_TEST_SYSCON_ANSWER    = 'N'

$bootstrapLog = '~cascade_conda_create_fail_bootstrap.log'
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    if ($null -eq $prevSkip)       { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue }                     else { $env:HP_SKIP_PIPREQS = $prevSkip }
    if ($null -eq $prevDisableH)   { Remove-Item Env:HP_DISABLE_HEURISTICS -ErrorAction SilentlyContinue }               else { $env:HP_DISABLE_HEURISTICS = $prevDisableH }
    if ($null -eq $prevCascade)    { Remove-Item Env:HP_TEST_CASCADE_ANSWER -ErrorAction SilentlyContinue }              else { $env:HP_TEST_CASCADE_ANSWER = $prevCascade }
    if ($null -eq $prevCcBothFail) { Remove-Item Env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL -ErrorAction SilentlyContinue }else { $env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL = $prevCcBothFail }
    if ($null -eq $prevCcMissPy)   { Remove-Item Env:HP_TEST_FORCE_CONDA_MISSING_PYTHON -ErrorAction SilentlyContinue }  else { $env:HP_TEST_FORCE_CONDA_MISSING_PYTHON = $prevCcMissPy }
    if ($null -eq $prevEmbedFail)  { Remove-Item Env:HP_TEST_FORCE_EMBED_FAIL -ErrorAction SilentlyContinue }            else { $env:HP_TEST_FORCE_EMBED_FAIL = $prevEmbedFail }
    if ($null -eq $prevVenvFail)   { Remove-Item Env:HP_TEST_FORCE_VENV_FAIL -ErrorAction SilentlyContinue }             else { $env:HP_TEST_FORCE_VENV_FAIL = $prevVenvFail }
    if ($null -eq $prevSyscon)     { Remove-Item Env:HP_TEST_SYSCON_ANSWER -ErrorAction SilentlyContinue }               else { $env:HP_TEST_SYSCON_ANSWER = $prevSyscon }
    Pop-Location
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# derived requirement: count against a SINGLE log source ($setupText), matching
# selfapps_cascade.ps1's own established convention -- :log writes every line to BOTH stdout
# (captured in $logLines) AND ~setup.log, so counting against $combined would double every
# occurrence.
$uvToConda = ([regex]::Matches($setupText, [regex]::Escape('REQ-009: cascading provider uv to conda'))).Count

# Both the simulated initial attempt (the fake CondaHTTPError text written to ~conda_create.tmp,
# then typed into %LOG%) and the simulated retry failure (the existing REQ-022 retry-exhausted
# message, now reached via the forced-fail goto instead of a genuine failed real retry) must
# both appear in create_fails -- proving HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL engaged at both
# call sites, not just the first. In missing_python these must be ABSENT -- proving the real
# create genuinely succeeded rather than taking the simulated-failure path.
$initialAttemptFailed = $combined -match [regex]::Escape('CondaHTTPError: HTTP 000 CONNECTION FAILED (simulated)')
$retryAlsoFailed      = $combined -match [regex]::Escape('conda create: retry after transient failure also failed')

# The fix itself: the new cascade-target-failure label fired instead of falling through :die.
$cascadeRestoreFired = $combined -match [regex]::Escape('REQ-009: cascade target conda create failed; keeping current build')

# derived requirement: :handle_conda_failure always logs its message argument once via :log
# BEFORE attempting any fallback (run_setup.bat, :handle_conda_failure's own first line), so
# "[ERROR] ... failed." legitimately appears once in EITHER scenario even on the graceful-restore
# path -- a single occurrence is expected, not a sign the old bug is back. :die (if it fires)
# echoes the SAME message text a second time (its own echo, not via :log) -- so a genuine
# fall-through-to-:die regression shows up as a SECOND occurrence of the scenario's own message,
# not merely a first one. Count, don't just match, for exactly this reason.
if ($scenario -eq 'missing_python') {
    $scenarioMsg = '[ERROR] python.exe missing from conda environment.'
} else {
    $scenarioMsg = '[ERROR] conda env create failed.'
}
$scenarioMsgCount = ([regex]::Matches($setupText, [regex]::Escape($scenarioMsg))).Count
$dieMessageFired  = $scenarioMsgCount -gt 1

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

# Primary criteria, common to both scenarios: the cascade reached conda exactly once, the new
# graceful-restore label fired, the scenario's own failure message reached the log exactly once
# (not the double occurrence a :die fall-through regression would produce), the bootstrap ended
# gracefully (exit 0), and -- the key behavioral proof of the fix -- ~bootstrap.status.json reads
# state=ok (HP_BOOTSTRAP_STATE's own default, preserved by :after_cascade_decision) rather than
# state=error.
$commonPass = ($uvToConda -eq 1) -and $cascadeRestoreFired -and (-not $dieMessageFired) -and ($runExit -eq 0) -and ($statusState -eq 'ok') -and ($statusExit -eq 0)
if ($scenario -eq 'missing_python') {
    # The real create must have succeeded (neither simulated-failure signature present) --
    # otherwise this scenario would be indistinguishable from create_fails and prove nothing new.
    $pass = $commonPass -and (-not $initialAttemptFailed) -and (-not $retryAlsoFailed)
} else {
    $pass = $commonPass -and $initialAttemptFailed -and $retryAlsoFailed
}

Write-Host "=== self.cascade.conda_create_fail evidence (scenario=$scenario) ==="
Write-Host ("uvToConda={0} initialAttemptFailed={1} retryAlsoFailed={2} cascadeRestoreFired={3} scenarioMsgCount={4} dieMessageFired={5} runExit={6} statusExit={7} statusState={8} pass={9}" -f `
    $uvToConda, $initialAttemptFailed, $retryAlsoFailed, $cascadeRestoreFired, $scenarioMsgCount, $dieMessageFired, $runExit, $statusExit, $statusState, $pass)
Write-Host "=== REQ-009 / conda create / cascade lines (setup log) ==="
($setupText -split "`n") | Where-Object { $_ -match 'REQ-009|conda create|conda env create|cascade|Creating Python environment|CondaHTTPError|python.exe missing' } | Select-Object -First 80 | ForEach-Object { Write-Host $_ }
Write-Host "=== bootstrap stdout log tail (50) ==="
$logLines | Select-Object -Last 50 | ForEach-Object { Write-Host $_ }
Write-Host "=== end self.cascade.conda_create_fail evidence ==="

Write-NdjsonRow ([ordered]@{
    id      = 'self.cascade.conda_create_fail'
    req     = 'REQ-009'
    pass    = [bool]$pass
    desc    = "a genuine conda-create failure (scenario=$scenario) during a uv-to-conda cascade re-entry gracefully keeps the previous uv build (CLAUDE.md Active Backlog Item 23)"
    details = [ordered]@{
        scenario             = $scenario
        uvToConda            = $uvToConda
        initialAttemptFailed = [bool]$initialAttemptFailed
        retryAlsoFailed      = [bool]$retryAlsoFailed
        scenarioMsgCount     = $scenarioMsgCount
        cascadeRestoreFired  = [bool]$cascadeRestoreFired
        dieMessageFired      = [bool]$dieMessageFired
        runExit              = $runExit
        statusExit           = $statusExit
        statusState          = $statusState
    }
})

if (-not $pass) { exit 1 }
exit 0
