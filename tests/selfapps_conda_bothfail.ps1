# ASCII only
# selfapps_conda_bothfail.ps1 - Regression coverage for CLAUDE.md Active Backlog item 10:
# :tci_both_failed (both AllUsers and JustMe Miniconda installs fail) previously had zero CI
# coverage. This is a real, reachable production branch (a machine where both install types
# genuinely fail -- corrupted installer, unusual ACLs) with no deterministic HP_TEST_* hook to
# force it -- tests/selfapps_justme.ps1's HP_TEST_NOT_ELEVATED=1 only proves the JustMe install
# SUCCEEDS.
#
# New hook: HP_TEST_FORCE_JUSTME_FAIL=1 (run_setup.bat, :tci_justme) skips the real JustMe
# `start "" /wait` call and forces a nonzero result deterministically. Combined with
# HP_TEST_NOT_ELEVATED=1 (already reaches :tci_justme by skipping straight past the AllUsers
# attempt), this reaches :tci_both_failed -> :die "[ERROR] Miniconda install failed (AllUsers
# skipped -- not elevated; JustMe also failed)." without depending on a genuinely broken
# installer/ACL environment. (Message wording updated for Active Backlog item 16, renumbered
# from 11 -- see docs/agent-closed-backlog.md -- to stop implying AllUsers was genuinely
# attempted-then-failed when this scenario always skips it.)
#
# derived requirement: Miniconda installs to the SHARED, machine-wide %PUBLIC%\Documents\
# Miniconda3 path, not a per-test-directory location -- if an EARLIER step in the same CI job
# (the main "Bootstrap environment" step, or an earlier selfapps script) already installed
# Miniconda there, :try_conda_install's own top-level gate (`if not defined CONDA_BAT (...)`,
# run_setup.bat ~line 655) would find conda.bat already present and skip the install block
# entirely -- this test's hooks would never fire. This is WHY this test is wired into the `uv`
# lane specifically, placed BEFORE any earlier selfapps step that forces conda (e.g. the
# provider-cascade-exec step, which cascades uv -> conda and would install Miniconda first if it
# ran earlier) -- see docs/agent-ndjson.md for the exact placement constraint. The `uv` lane's own
# main bootstrap step normally succeeds via uv alone (no Miniconda installed), so by the time this
# step runs, conda.bat genuinely does not exist yet on the runner.
#
# Runs a FRESH, isolated sub-bootstrap (own temp dir) with HP_FORCE_CONDA_ONLY=1 (self-contained
# override per docs/agent-interconnect.md's "HP_FORCE_CONDA_ONLY as a test-override pattern" --
# this test genuinely needs conda's own install path exercised, not uv's).
#
# Asserts: the HP_TEST_FORCE_JUSTME_FAIL hook fired, the exact :tci_both_failed [ERROR] message
# appears, and ~bootstrap.status.json reads state=error (not silently overwritten back to ok --
# the same class of bug CLAUDE.md's ":die" entry in docs/agent-lessons-learned.md documents).
# Does NOT assert process exit code -- :success's own `exit /b 0` runs unconditionally regardless
# of HP_BOOTSTRAP_STATE (this repo's established "graceful stop" contract for this failure class;
# see selfapps_pyinstaller_fail.ps1's sibling reasoning).
#
# Also regression-tests CLAUDE.md Active Backlog Item 46 Bucket A Batch 1
# (docs/plan-die-fatal-remediation.md's "Batch Roadmap"): a genuine Miniconda-install failure via
# :tci_both_failed's own fall-through (its `call :die` returns via `goto :eof` to :try_conda_
# install's caller, which then finds no conda.bat and falls into the conda-acquisition-probe chain)
# used to be able to stack up to 4-5 redundant [ERROR]/pause pairs (conda.bat not found -> 'conda'
# not found on PATH -> 'python' not found on PATH -> 'python -V' failed -> Conda not found at:)
# before finally reaching the real "Active Python interpreter not resolved" sink. Each of those 5
# sites now `goto :after_env_mode_selection` right after its own `call :die`, so this exact scenario
# should show the conda.bat-not-found message (the first site in the chain, always reached since
# CONDA_BAT genuinely never gets set here) and the eventual sink message, but NONE of the other 4
# chain messages -- this test already drives the real fall-through path, so no new test hook is
# needed, only new assertions.
#
# Lane: uv only, non-gating (real Miniconda download+install-attempt cost; unproven CI-ordering
# assumption above needs to soak before considering gating-lane promotion).
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
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.conda.bothfail'
        req     = 'REQ-003'
        pass    = $true
        desc    = 'Miniconda both-install-types-fail path (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.conda.bothfail'
        req     = 'REQ-003'
        pass    = $false
        desc    = 'Miniconda both-install-types-fail: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_conda_bothfail'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force
Set-Content -Path (Join-Path $workDir 'app.py') -Value 'print("should-not-matter")' -Encoding ASCII

$bootstrapLog = '~conda_bothfail_bootstrap.log'

$prevForceCondaOnly = if (Test-Path Env:HP_FORCE_CONDA_ONLY) { $env:HP_FORCE_CONDA_ONLY } else { $null }
$prevNotElevated = if (Test-Path Env:HP_TEST_NOT_ELEVATED) { $env:HP_TEST_NOT_ELEVATED } else { $null }
$prevForceJustmeFail = if (Test-Path Env:HP_TEST_FORCE_JUSTME_FAIL) { $env:HP_TEST_FORCE_JUSTME_FAIL } else { $null }
$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_FORCE_CONDA_ONLY = '1'
$env:HP_TEST_NOT_ELEVATED = '1'
$env:HP_TEST_FORCE_JUSTME_FAIL = '1'
$env:HP_SKIP_PIPREQS = '1'

try {
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $logPath  = Join-Path $workDir $bootstrapLog
    $logLines = if (Test-Path $logPath) { Get-Content -LiteralPath $logPath -Encoding ASCII } else { @() }
    $combined = $logLines -join "`n"

    $notElevatedSkip = $combined -match [regex]::Escape('Not elevated; skipping AllUsers Miniconda install.')
    $justmeFailHookFired = $combined -match [regex]::Escape('HP_TEST_FORCE_JUSTME_FAIL=1; simulating JustMe install failure')
    # derived requirement: [Active Backlog item 16, renumbered from 11 -- see docs/agent-closed-
    # backlog.md] :tci_both_failed's terminal message is now skip-aware -- this scenario always
    # sets HP_TEST_NOT_ELEVATED=1, so AllUsers was skipped, never attempted, and the correct
    # terminal wording says so instead of implying a genuine AllUsers install failure.
    $bothFailedMsgFound = $combined -match [regex]::Escape('Miniconda install failed (AllUsers skipped -- not elevated; JustMe also failed)')

    # Item 46 Bucket A Batch 1: conda.bat-not-found is the first (and, post-fix, only) site in the
    # conda-acquisition-probe chain this fall-through path reaches -- CONDA_BAT genuinely never
    # gets set in this scenario, so this message MUST still appear.
    $condaBatNotFoundMsgFound = $combined -match [regex]::Escape("conda.bat not found after bootstrap")
    # The 4 sibling chain sites must NOT fire anymore -- their own `goto :after_env_mode_selection`
    # (added right after conda.bat-not-found's own) must short-circuit past all of them.
    $condaPathMsgFound   = $combined -match [regex]::Escape("'conda' not found on PATH after bootstrap")
    $pythonPathMsgFound  = $combined -match [regex]::Escape("'python' not found on PATH after bootstrap")
    $pythonVMsgFound     = $combined -match [regex]::Escape("'python -V' failed after bootstrap")
    $condaNotFoundAtFound = $combined -match [regex]::Escape('Conda not found at:')
    $chainCollapsed = -not ($condaPathMsgFound -or $pythonPathMsgFound -or $pythonVMsgFound -or $condaNotFoundAtFound)
    # Execution should still reach the real sink (Active Python interpreter not resolved) rather
    # than hanging or erroring out somewhere unexpected -- proves the goto landed at a working
    # convergence point, not just that the intermediate messages went silent.
    $reachedSink = $combined -match [regex]::Escape('Active Python interpreter not resolved')

    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusText = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw } else { $null }
    $statusState = $null
    if ($statusText) {
        try { $statusState = ($statusText | ConvertFrom-Json).state } catch { $statusState = $null }
    }

    $pass = $notElevatedSkip -and $justmeFailHookFired -and $bothFailedMsgFound -and ($statusState -eq 'error') `
        -and $condaBatNotFoundMsgFound -and $chainCollapsed -and $reachedSink

    Write-NdjsonRow ([ordered]@{
        id      = 'self.conda.bothfail'
        req     = 'REQ-003'
        pass    = $pass
        desc    = 'Miniconda both-install-types-fail (:tci_both_failed) correctly reported, state=error, Item 46 Batch 1 chain collapsed'
        details = [ordered]@{
            notElevatedSkip           = [bool]$notElevatedSkip
            justmeFailHookFired       = [bool]$justmeFailHookFired
            bothFailedMsgFound        = [bool]$bothFailedMsgFound
            condaBatNotFoundMsgFound  = [bool]$condaBatNotFoundMsgFound
            condaPathMsgFound         = [bool]$condaPathMsgFound
            pythonPathMsgFound        = [bool]$pythonPathMsgFound
            pythonVMsgFound           = [bool]$pythonVMsgFound
            condaNotFoundAtFound      = [bool]$condaNotFoundAtFound
            chainCollapsed            = [bool]$chainCollapsed
            reachedSink               = [bool]$reachedSink
            statusState               = $statusState
            bootstrapExit             = $runExit
            log                       = $bootstrapLog
        }
    })
} finally {
    if ($null -eq $prevForceCondaOnly) { Remove-Item Env:HP_FORCE_CONDA_ONLY -ErrorAction SilentlyContinue } else { $env:HP_FORCE_CONDA_ONLY = $prevForceCondaOnly }
    if ($null -eq $prevNotElevated) { Remove-Item Env:HP_TEST_NOT_ELEVATED -ErrorAction SilentlyContinue } else { $env:HP_TEST_NOT_ELEVATED = $prevNotElevated }
    if ($null -eq $prevForceJustmeFail) { Remove-Item Env:HP_TEST_FORCE_JUSTME_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_JUSTME_FAIL = $prevForceJustmeFail }
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
}

if (-not $pass) { exit 1 }
exit 0
