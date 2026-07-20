# ASCII only
# selfapps_nuitka_tiera.ps1 - proves AV-Safe Build Path requirements 2-4 (Tier A) actually
# work end to end: when PyInstaller's build fails, :try_nuitka_tier_a is attempted in the SAME
# environment (no reprovisioning), a real Nuitka build runs, and -- on success -- the rest of
# the pipeline treats the Nuitka-produced dist\<env>.exe exactly like a PyInstaller one (same
# smoke-test path, same postflight briefing, no special-casing needed downstream).
#
# HP_TEST_FORCE_PYINSTALLER_FAIL=1 forces the PRIMARY build to "fail" (deterministic, does not
# depend on real AV/environment conditions); HP_TEST_FORCE_NUITKA_FAIL is deliberately NOT set,
# so the fallback attempt is a genuine Nuitka build against a trivial stub app.
#
# Deliberately non-gating (uv lane only) for its first landing: unlike
# self.exe.build.xfail (requirement 1, real/conda-full, gating -- that test forces the fallback
# to fail too, so it never depends on a real Nuitka/compiler outcome), this test's whole point is
# exercising a REAL Nuitka build, whose CLI flags and MSVC/compiler availability could not be
# verified locally (no Windows machine in this sandbox). Promote to a gating lane once proven
# stable across several real runs, matching this repo's established graduation pattern for new
# lanes (see CLAUDE.md's "CI lane gating maturity" periodic check).
#
# Asserts: the fallback-attempt and fallback-succeeded log lines appear, dist\<env>.exe exists,
# the app's own stdout made it through the existing (unmodified) EXE smoke-test path, and the
# final ~bootstrap.status.json reads state=ok (a successful fallback is bootstrap SUCCESS, not
# an error -- distinct from self.exe.build.xfail, where every tier failing is the error case).
#
# Emits: self.exe.build.tiera
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

function Write-TierARow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.exe.build.tiera'; req = 'REQ-AV'; pass = $Pass; desc = $Desc; details = $Details })
}

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-TierARow -Pass $true -Desc 'AV-Safe Build Path Tier A (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-TierARow -Pass $false -Desc 'AV-Safe Build Path Tier A: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

$workDir = Join-Path $here '~selftest_nuitka_tiera'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

Set-Content -Path (Join-Path $workDir 'app.py') -Value @'
print("nuitka-fallback-ok")
'@ -Encoding ASCII

$bootstrapLog = '~nuitka_tiera_bootstrap.log'

$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevForceExecfail = if (Test-Path Env:HP_TEST_FORCE_PYINSTALLER_FAIL) { $env:HP_TEST_FORCE_PYINSTALLER_FAIL } else { $null }
$env:HP_SKIP_PIPREQS = '1'
$env:HP_TEST_FORCE_PYINSTALLER_FAIL = '1'

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

    $attemptLogged  = $combined -match [regex]::Escape('attempting a fallback build')
    $successLogged  = $combined -match [regex]::Escape('Fallback build succeeded')

    # ENVNAME is derived from the workDir leaf name with every non-alnum/underscore/hyphen
    # character (including the leading '~') sanitized to '_' (run_setup.bat lines ~350-356) --
    # mirrors the established pattern in selfapps_collect.ps1/selfapps_envsmoke.ps1/etc. rather
    # than hardcoding the literal tilde-prefixed folder name.
    $envLeaf  = Split-Path $workDir -Leaf
    $envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
    if (-not $envName) { $envName = '_env' }
    $exePath        = Join-Path $workDir "dist\$envName.exe"
    $exeExists      = Test-Path -LiteralPath $exePath

    # The EXE's own stdout is captured to ~run.out.txt in the app root (not echoed into the
    # console-redirected bootstrap log) -- see :run_exe_smokerun's PowerShell capture. Read it
    # directly rather than searching $combined, matching selfapps_envsmoke.ps1's own pattern.
    $runOutPath     = Join-Path $workDir '~run.out.txt'
    $runOutText     = if (Test-Path -LiteralPath $runOutPath) { Get-Content -LiteralPath $runOutPath -Raw -Encoding ASCII } else { '' }
    $appStdoutFound = $runOutText -match [regex]::Escape('nuitka-fallback-ok')

    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusText = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw } else { $null }
    $statusState = $null
    if ($statusText) {
        try { $statusState = ($statusText | ConvertFrom-Json).state } catch { $statusState = $null }
    }

    $pass = $attemptLogged -and $successLogged -and $exeExists -and $appStdoutFound -and ($statusState -eq 'ok')

    Write-TierARow -Pass $pass -Desc 'AV-Safe Build Path Tier A: real Nuitka fallback build succeeds and is used as the standalone EXE' -Details ([ordered]@{
        bootstrapExit  = $runExit
        attemptLogged  = [bool]$attemptLogged
        successLogged  = [bool]$successLogged
        exeExists      = [bool]$exeExists
        appStdoutFound = [bool]$appStdoutFound
        statusState    = $statusState
        log            = $bootstrapLog
    })
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevForceExecfail) { Remove-Item Env:HP_TEST_FORCE_PYINSTALLER_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PYINSTALLER_FAIL = $prevForceExecfail }
}

if (-not $pass) { exit 1 }
exit 0
