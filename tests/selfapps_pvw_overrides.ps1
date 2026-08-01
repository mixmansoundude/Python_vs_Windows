# ASCII only
# selfapps_pvw_overrides.ps1 - CLAUDE.md former Active Backlog item 10: PVW_PYTHON_EXE and
# PVW_WORKSPACE had ZERO test coverage of any kind (unlike PVW_UV_EXE and PVW_TARGET_PY, which
# each have real, valid-value end-to-end CI coverage incidental to another test's own purpose,
# and PVW_CONDA_EXE, which has dedicated coverage). Scoped to the cheapest, highest-value gap
# per the backlog item's own suggested shape: valid-value paths for these two variables only,
# not the full 5x2 valid/invalid combinatorial matrix -- see CLAUDE.md's own backlog history
# for why that full matrix was deliberately deferred.
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

# Same save/set/restore helper as selfapps_ux_hardening.ps1 -- see that file's own comment for
# why a hashtable-based helper (not a fixed var list) and why restoring via
# [Environment]::SetEnvironmentVariable($name, $null) needs no separate "was it null" branch.
function Invoke-WithEnvOverrides {
    param(
        [Parameter(Mandatory)][hashtable]$Overrides,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    $saved = @{}
    foreach ($name in $Overrides.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, [string]$Overrides[$name])
    }
    try {
        & $Body
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
}

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    $skipDetails = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    foreach ($id in @('self.pvw.python_exe.valid', 'self.pvw.workspace.valid', 'self.pvw.python_exe.invalid', 'self.pvw.workspace.invalid')) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            pass    = $true
            desc    = 'PVW override test (skipped on non-Windows host)'
            details = $skipDetails
        })
    }
    return
}

# ===== PVW_PYTHON_EXE: valid-value override actually wins over provider-selected interpreter =====
# PVW_PYTHON_EXE's documented purpose (run_setup.bat's own top-of-file RECOVERY comment): when
# auto-detection breaks on a future Python version, a user installs a known-good interpreter and
# points the bootstrapper at it directly, bypassing provider acquisition/selection entirely for
# HP_PY specifically. run_setup.bat overrides HP_PY with it at :after_env_mode_selection --
# AFTER normal provider selection (uv/conda/etc.) has already run and set its own HP_PY -- so the
# only way to prove this override genuinely takes effect is to point it at a DIFFERENT, already-
# working interpreter than whatever this run's own provider selection would have chosen, and
# confirm the pipeline (dependency install, entry smoke) succeeds using THAT borrowed interpreter.
#
# Two-stage design: stage 1 does an ordinary uv bootstrap of a throwaway stub app purely to
# materialize a real, working python.exe on disk (with pip already usable in it). Stage 2 is a
# GENUINELY FRESH scratch directory (never bootstrapped before, so :try_fast_exe's EXE-cache
# fast path -- which runs before :after_env_mode_selection is ever reached -- cannot short-circuit
# past the override) running a DIFFERENT stub app, with PVW_PYTHON_EXE pointed at stage 1's
# interpreter. Skipped in conda-full lane: PVW_PYTHON_EXE overrides HP_PY regardless of provider,
# but stage 1 needs a fast, low-cost way to materialize a real interpreter, and conda-full forces
# every stage through the (slow) real Miniconda path -- not worth the extra CI minutes for a
# scenario this test can already prove cleanly via uv.
$pyExePass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pvw.python_exe.valid'
        pass    = $true
        desc    = 'PVW_PYTHON_EXE super-user override: a valid interpreter path wins over provider selection'
        details = [ordered]@{ skip = $true; reason = 'conda-full-lane-not-worth-the-extra-minutes' }
    })
} else {
    $stage1Dir = Join-Path $here '~selftest_pvw_pyexe_stage1'
    if (Test-Path $stage1Dir) { Remove-Item -Recurse -Force $stage1Dir }
    New-Item -ItemType Directory -Force -Path $stage1Dir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $stage1Dir -Force
    Set-Content -LiteralPath (Join-Path $stage1Dir 'stage1_app.py') -Value 'print("stage1-materialize-ok")' -Encoding Ascii

    $stage1Exit = Invoke-WithEnvOverrides -Overrides @{ HP_CI_LANE = 'test'; HP_SKIP_PIPREQS = '1' } -Body {
        Push-Location -LiteralPath $stage1Dir
        try {
            cmd /c "run_setup.bat > ~stage1_bootstrap.log 2>&1"
            $LASTEXITCODE
        } finally {
            Pop-Location
        }
    }
    $stage1Py = Join-Path $stage1Dir '.uv_env\Scripts\python.exe'

    if ($stage1Exit -ne 0 -or -not (Test-Path -LiteralPath $stage1Py)) {
        # Stage 1 itself failed to produce a real interpreter -- cannot proceed to stage 2's
        # actual assertion. Report as a genuine failure (not a skip): this is test-infra
        # breakage, not a runner limitation like self.warn.longpath's own skip case.
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pvw.python_exe.valid'
            pass    = $false
            desc    = 'PVW_PYTHON_EXE super-user override: a valid interpreter path wins over provider selection'
            details = [ordered]@{ stage1Exit = $stage1Exit; stage1PyExists = (Test-Path -LiteralPath $stage1Py) }
        })
    } else {
        $stage2Dir = Join-Path $here '~selftest_pvw_pyexe_stage2'
        if (Test-Path $stage2Dir) { Remove-Item -Recurse -Force $stage2Dir }
        New-Item -ItemType Directory -Force -Path $stage2Dir | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $stage2Dir -Force
        Set-Content -LiteralPath (Join-Path $stage2Dir 'stage2_app.py') -Value 'print("stage2-override-ok")' -Encoding Ascii

        $stage2Exit = Invoke-WithEnvOverrides -Overrides @{
            HP_CI_LANE      = 'test'
            HP_SKIP_PIPREQS = '1'
            PVW_PYTHON_EXE  = $stage1Py
        } -Body {
            Push-Location -LiteralPath $stage2Dir
            try {
                cmd /c "run_setup.bat > ~stage2_bootstrap.log 2>&1"
                $LASTEXITCODE
            } finally {
                Pop-Location
            }
        }

        $stage2LogPath = Join-Path $stage2Dir '~stage2_bootstrap.log'
        $stage2LogText = ''
        if (Test-Path -LiteralPath $stage2LogPath) {
            $stage2LogText = Get-Content -LiteralPath $stage2LogPath -Raw -Encoding Ascii
        }
        $stage2RunOut = Join-Path $stage2Dir '~run.out.txt'
        $stage2RunText = ''
        if (Test-Path -LiteralPath $stage2RunOut) {
            $stage2RunText = Get-Content -LiteralPath $stage2RunOut -Raw -Encoding Ascii
        }
        $overrideLogFound = ($stage2LogText -match [regex]::Escape('[INFO] Python host: using super-user override PVW_PYTHON_EXE.'))
        $appRan = ($stage2RunText -match [regex]::Escape('stage2-override-ok'))
        # Stage 2's OWN .uv_env must never have been created -- the override applies before uv's
        # own venv would otherwise be relevant to HP_PY, but if this env exists it does not by
        # itself disprove the override (uv still creates it as a side effect of normal
        # acquisition); the decisive signal is the log line + the app actually running via the
        # borrowed interpreter, both already asserted above.
        $pyExePass = ($stage2Exit -eq 0) -and $overrideLogFound -and $appRan
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pvw.python_exe.valid'
            pass    = $pyExePass
            desc    = 'PVW_PYTHON_EXE super-user override: a valid interpreter path wins over provider selection'
            details = [ordered]@{
                stage1Py         = $stage1Py
                stage2Exit       = $stage2Exit
                overrideLogFound = $overrideLogFound
                appRan           = $appRan
            }
        })
    }
}

# ===== PVW_WORKSPACE: valid-value override relocates the uv venv =====
# PVW_WORKSPACE only takes effect inside the uv venv-creation block (run_setup.bat,
# `if defined PVW_WORKSPACE set "HP_UV_ENV_PATH=%PVW_WORKSPACE%"`, gated behind
# `if not defined HP_UV_EXE goto :try_conda_create` above it) -- so this scenario forces uv mode
# implicitly by running in a fresh directory with no HP_TEST_FORCE_UV_FAIL. Confirms the venv is
# actually created at the CUSTOM path (not the default `.uv_env`) and the app still
# builds/installs/runs successfully from there. Skipped in conda-full lane (uv is never the
# provider there, so PVW_WORKSPACE's own effect is unreachable -- same reasoning this repo
# already uses for the other uv-only PVW/embed scenarios in selfapps_ux_hardening.ps1).
$workspacePass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pvw.workspace.valid'
        pass    = $true
        desc    = 'PVW_WORKSPACE super-user override: relocates the uv venv to a custom path'
        details = [ordered]@{ skip = $true; reason = 'uv-not-the-provider-in-conda-full' }
    })
} else {
    $wsAppDir = Join-Path $here '~selftest_pvw_workspace'
    if (Test-Path $wsAppDir) { Remove-Item -Recurse -Force $wsAppDir }
    New-Item -ItemType Directory -Force -Path $wsAppDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $wsAppDir -Force
    Set-Content -LiteralPath (Join-Path $wsAppDir 'ws_app.py') -Value 'print("workspace-relocate-ok")' -Encoding Ascii

    $customWorkspace = Join-Path $here '~selftest_pvw_workspace_env'
    if (Test-Path $customWorkspace) { Remove-Item -Recurse -Force $customWorkspace }

    $wsExit = Invoke-WithEnvOverrides -Overrides @{
        HP_CI_LANE      = 'test'
        HP_SKIP_PIPREQS = '1'
        PVW_WORKSPACE   = $customWorkspace
    } -Body {
        Push-Location -LiteralPath $wsAppDir
        try {
            cmd /c "run_setup.bat > ~ws_bootstrap.log 2>&1"
            $LASTEXITCODE
        } finally {
            Pop-Location
        }
    }

    $wsLogPath = Join-Path $wsAppDir '~ws_bootstrap.log'
    $wsLogText = ''
    if (Test-Path -LiteralPath $wsLogPath) {
        $wsLogText = Get-Content -LiteralPath $wsLogPath -Raw -Encoding Ascii
    }
    $wsRunOut = Join-Path $wsAppDir '~run.out.txt'
    $wsRunText = ''
    if (Test-Path -LiteralPath $wsRunOut) {
        $wsRunText = Get-Content -LiteralPath $wsRunOut -Raw -Encoding Ascii
    }
    $wsDebugLogFound = ($wsLogText -match [regex]::Escape('[DEBUG] Using super-user override for PVW_WORKSPACE:'))
    $customPyExists = Test-Path -LiteralPath (Join-Path $customWorkspace 'Scripts\python.exe')
    $defaultEnvAbsent = -not (Test-Path -LiteralPath (Join-Path $wsAppDir '.uv_env\Scripts\python.exe'))
    $wsAppRan = ($wsRunText -match [regex]::Escape('workspace-relocate-ok'))
    $workspacePass = ($wsExit -eq 0) -and $wsDebugLogFound -and $customPyExists -and $defaultEnvAbsent -and $wsAppRan
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pvw.workspace.valid'
        pass    = $workspacePass
        desc    = 'PVW_WORKSPACE super-user override: relocates the uv venv to a custom path'
        details = [ordered]@{
            customWorkspace   = $customWorkspace
            wsExit            = $wsExit
            debugLogFound     = $wsDebugLogFound
            customPyExists    = $customPyExists
            defaultEnvAbsent  = $defaultEnvAbsent
            appRan            = $wsAppRan
        }
    })
}

# ===== PVW_PYTHON_EXE: invalid-value path is absorbed gracefully, not an uncontrolled crash =====
# A nonexistent PVW_PYTHON_EXE path is never validated before HP_PY is overridden with it
# (`:after_env_mode_selection`) -- the very next real use is the pre-existing interpreter smoke
# test a few lines later (`"%HP_PY%" -c "print('py_ok')" ... || (call :log "[WARN] Interpreter
# smoke test failed (continuing)." & set "HP_NO_INTERPRETER=1")`), which already exists
# specifically to absorb exactly this class of broken-HP_PY failure gracefully (cmd.exe's own
# "is not recognized" error on a nonexistent .exe trips the `||` fallback). This asserts that
# absorption actually happens for the PVW_PYTHON_EXE case specifically -- confirms the WARN
# fires and the bootstrap completes (bounded, not hung), rather than a raw, unhandled batch error.
$pyExeInvalidPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pvw.python_exe.invalid'
        pass    = $true
        desc    = 'PVW_PYTHON_EXE super-user override: an invalid interpreter path is absorbed gracefully, not an uncontrolled crash'
        details = [ordered]@{ skip = $true; reason = 'conda-full-lane-not-worth-the-extra-minutes' }
    })
} else {
    $pyInvalidDir = Join-Path $here '~selftest_pvw_pyexe_invalid'
    if (Test-Path $pyInvalidDir) { Remove-Item -Recurse -Force $pyInvalidDir }
    New-Item -ItemType Directory -Force -Path $pyInvalidDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $pyInvalidDir -Force
    Set-Content -LiteralPath (Join-Path $pyInvalidDir 'pyinvalid_app.py') -Value 'print("pyinvalid-app-ok")' -Encoding Ascii
    $bogusPy = Join-Path $pyInvalidDir 'this_python_exe_does_not_exist.exe'

    $pyInvalidExit = Invoke-WithEnvOverrides -Overrides @{
        HP_CI_LANE      = 'test'
        HP_SKIP_PIPREQS = '1'
        PVW_PYTHON_EXE  = $bogusPy
    } -Body {
        Push-Location -LiteralPath $pyInvalidDir
        try {
            cmd /c "run_setup.bat > ~pyinvalid_bootstrap.log 2>&1"
            $LASTEXITCODE
        } finally {
            Pop-Location
        }
    }

    $pyInvalidLogPath = Join-Path $pyInvalidDir '~pyinvalid_bootstrap.log'
    $pyInvalidLogText = ''
    if (Test-Path -LiteralPath $pyInvalidLogPath) {
        $pyInvalidLogText = Get-Content -LiteralPath $pyInvalidLogPath -Raw -Encoding Ascii
    }
    $overrideLogFound = ($pyInvalidLogText -match [regex]::Escape('[INFO] Python host: using super-user override PVW_PYTHON_EXE.'))
    $smokeWarnFound = ($pyInvalidLogText -match [regex]::Escape('[WARN] Interpreter smoke test failed (continuing).'))
    # derived requirement: the whole point is "no uncontrolled crash" -- the bootstrap must have
    # produced SOME real exit code (the test's own cmd /c call always returns one; there is no
    # separate "did it hang" signal here since PowerShell's own subprocess call is itself
    # unbounded, but a real, non-null exit code combined with the log file actually being written
    # is the available proof this run completed rather than the parent job's own outer CI timeout
    # being what stopped it).
    $completedGracefully = ($null -ne $pyInvalidExit) -and (Test-Path -LiteralPath $pyInvalidLogPath)
    $pyExeInvalidPass = $overrideLogFound -and $smokeWarnFound -and $completedGracefully
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pvw.python_exe.invalid'
        pass    = $pyExeInvalidPass
        desc    = 'PVW_PYTHON_EXE super-user override: an invalid interpreter path is absorbed gracefully, not an uncontrolled crash'
        details = [ordered]@{
            bogusPy              = $bogusPy
            pyInvalidExit        = $pyInvalidExit
            overrideLogFound     = $overrideLogFound
            smokeWarnFound       = $smokeWarnFound
            completedGracefully  = $completedGracefully
        }
    })
}

# ===== PVW_WORKSPACE: invalid-value path (occupied by a file) cascades to conda, not a crash =====
# A PVW_WORKSPACE path that already exists as a FILE (not a directory) makes `uv venv --seed ...
# <path>` fail outright -- `if errorlevel 1 goto :uv_venv_fail` / `if not exist
# "%HP_UV_ENV_PATH%\Scripts\python.exe" goto :uv_venv_fail` (run_setup.bat) both cascade cleanly
# to the SAME already-established, already-tested `:uv_venv_fail` -> `:try_conda_create` fallback
# every other uv-venv-creation failure in this file already goes through -- confirms this
# specific trigger (an occupied PVW_WORKSPACE path) reaches that same fallback rather than a raw,
# unhandled failure. Deliberately does NOT require conda create to actually SUCCEED (a real
# Miniconda download in this lane is a real, accepted cost already established by this repo's own
# self.conda.bothfail scenario) -- only that the cascade is reached and the bootstrap terminates
# with a real signal either way, not hung or silently swallowed.
$workspaceInvalidPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pvw.workspace.invalid'
        pass    = $true
        desc    = 'PVW_WORKSPACE super-user override: a path occupied by a file cascades to the conda fallback, not a crash'
        details = [ordered]@{ skip = $true; reason = 'uv-not-the-provider-in-conda-full' }
    })
} else {
    $wsInvalidAppDir = Join-Path $here '~selftest_pvw_workspace_invalid'
    if (Test-Path $wsInvalidAppDir) { Remove-Item -Recurse -Force $wsInvalidAppDir }
    New-Item -ItemType Directory -Force -Path $wsInvalidAppDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $wsInvalidAppDir -Force
    Set-Content -LiteralPath (Join-Path $wsInvalidAppDir 'wsinvalid_app.py') -Value 'print("wsinvalid-app-ok")' -Encoding Ascii

    $occupiedWorkspace = Join-Path $here '~selftest_pvw_workspace_occupied'
    if (Test-Path $occupiedWorkspace) { Remove-Item -Recurse -Force $occupiedWorkspace }
    # A plain file, not a directory -- uv cannot create a venv "inside" a file.
    Set-Content -LiteralPath $occupiedWorkspace -Value 'this is a file, not a directory' -Encoding Ascii

    $wsInvalidExit = Invoke-WithEnvOverrides -Overrides @{
        HP_CI_LANE      = 'test'
        HP_SKIP_PIPREQS = '1'
        PVW_WORKSPACE   = $occupiedWorkspace
    } -Body {
        Push-Location -LiteralPath $wsInvalidAppDir
        try {
            cmd /c "run_setup.bat > ~wsinvalid_bootstrap.log 2>&1"
            $LASTEXITCODE
        } finally {
            Pop-Location
        }
    }

    $wsInvalidLogPath = Join-Path $wsInvalidAppDir '~wsinvalid_bootstrap.log'
    $wsInvalidLogText = ''
    if (Test-Path -LiteralPath $wsInvalidLogPath) {
        $wsInvalidLogText = Get-Content -LiteralPath $wsInvalidLogPath -Raw -Encoding Ascii
    }
    $wsInvalidDebugLogFound = ($wsInvalidLogText -match [regex]::Escape('[DEBUG] Using super-user override for PVW_WORKSPACE:'))
    $cascadeReached = ($wsInvalidLogText -match [regex]::Escape('falling back to conda create'))
    $wsInvalidCompletedGracefully = ($null -ne $wsInvalidExit) -and (Test-Path -LiteralPath $wsInvalidLogPath)
    $workspaceInvalidPass = $wsInvalidDebugLogFound -and $cascadeReached -and $wsInvalidCompletedGracefully
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pvw.workspace.invalid'
        pass    = $workspaceInvalidPass
        desc    = 'PVW_WORKSPACE super-user override: a path occupied by a file cascades to the conda fallback, not a crash'
        details = [ordered]@{
            occupiedWorkspace     = $occupiedWorkspace
            wsInvalidExit         = $wsInvalidExit
            debugLogFound         = $wsInvalidDebugLogFound
            cascadeReached        = $cascadeReached
            completedGracefully   = $wsInvalidCompletedGracefully
        }
    })
}
