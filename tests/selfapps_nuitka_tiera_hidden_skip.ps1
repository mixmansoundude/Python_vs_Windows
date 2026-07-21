# ASCII only
# selfapps_nuitka_tiera_hidden_skip.ps1 - regression test for a real bug found via a refinement
# pass on the already-shipped AV-Safe Build Path Tier A code: :hidden_import_recover (the
# --hidden-import auto-recovery loop, REQ-016 Slice 2) unconditionally rebuilds via PyInstaller
# on a recoverable missing-import failure, with NO check for whether the current dist\<env>.exe
# was actually built by Nuitka (Tier A, HP_NUITKA_FALLBACK_USED=1) rather than PyInstaller.
# PyInstaller's --hidden-import flag is a PyInstaller-specific repair mechanism that does not
# apply to a Nuitka-produced EXE; silently rebuilding via PyInstaller there risks reproducing the
# very failure Tier A exists to route around, or clobbering a working Nuitka build with a broken
# PyInstaller one. Fixed with an early-skip guard at the top of :hidden_import_recover.
#
# HP_TEST_FORCE_PYINSTALLER_FAIL=1 forces Tier A to trigger (same technique as
# selfapps_nuitka_tiera.ps1); HP_TEST_FORCE_NUITKA_FAIL is deliberately NOT set, so this is a real
# Nuitka build. The stub app deliberately prints a fabricated, exact-format
# "ModuleNotFoundError: No module named 'nuitka'" to stderr and exits 1 -- nuitka itself is
# guaranteed to be pip-installed into the SAME build interpreter that Tier A just used (Tier A
# installs it right before building), so ~hidden_import_scan.py's find_spec gate would treat this
# as a genuinely fixable target if the recovery loop were mistakenly attempted. The scanner is a
# pure text-based regex match against captured process output (see tools/hidden_import_scan.py's
# _PATTERN), not real Python introspection, so this fabricated signal is indistinguishable from a
# real one to the scanner -- letting this test deterministically construct the exact trigger
# condition the skip guard must catch, without depending on genuine Nuitka missing-import
# behavior (which would be fragile and non-deterministic to rely on).
#
# Deliberately non-gating (uv lane only), matching selfapps_nuitka_tiera.ps1's own graduation
# reasoning: this depends on a real Nuitka build succeeding, which could not be verified locally.
#
# Asserts: Tier A succeeds (same fallback-attempt/succeeded checks as selfapps_nuitka_tiera.ps1),
# the EXE genuinely runs and exits non-zero, the new skip log line fires, the OLD
# [REPAIR][HIDDEN_IMPORT] PyInstaller-rebuild log line does NOT fire (proves no rebuild was
# attempted), and ~bootstrap.status.json still reads state=ok (the user program's own non-zero
# exit is not a bootstrapper failure -- matches this repo's established "User-code exit-code
# semantics are already correctly isolated from bootstrapper status" precedent, CLAUDE.md Known
# Findings).
#
# Emits: self.exe.tiera.hidden_skip
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

function Write-HiddenSkipRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = 'self.exe.tiera.hidden_skip'; req = 'REQ-AV'; pass = $Pass; desc = $Desc; details = $Details })
}

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-HiddenSkipRow -Pass $true -Desc 'Tier A / hidden-import-recovery skip guard (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-HiddenSkipRow -Pass $false -Desc 'Tier A / hidden-import-recovery skip guard: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

$workDir = Join-Path $here '~selftest_nuitka_tiera_hidden_skip'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

Set-Content -Path (Join-Path $workDir 'app.py') -Value @'
import sys
print("nuitka-hidden-skip-ok")
sys.stderr.write("Traceback (most recent call last):\n")
sys.stderr.write("ModuleNotFoundError: No module named 'nuitka'\n")
sys.exit(1)
'@ -Encoding ASCII

$bootstrapLog = '~nuitka_tiera_hidden_skip_bootstrap.log'

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

    $envLeaf  = Split-Path $workDir -Leaf
    $envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
    if (-not $envName) { $envName = '_env' }
    $exePath   = Join-Path $workDir "dist\$envName.exe"
    $exeExists = Test-Path -LiteralPath $exePath

    $runOutPath = Join-Path $workDir '~run.out.txt'
    $runOutText = if (Test-Path -LiteralPath $runOutPath) { Get-Content -LiteralPath $runOutPath -Raw -Encoding ASCII } else { '' }
    $appStdoutFound = $runOutText -match [regex]::Escape('nuitka-hidden-skip-ok')

    $smokerunNonzeroLogged = $combined -match [regex]::Escape('EXE smokerun: exited')
    $skipGuardLogged       = $combined -match [regex]::Escape('Skipping --hidden-import auto-recovery')
    $noRepairRebuild       = -not ($combined -match [regex]::Escape('[REPAIR][HIDDEN_IMPORT] Adding --hidden-import='))

    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusText = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw } else { $null }
    $statusState = $null
    if ($statusText) {
        try { $statusState = ($statusText | ConvertFrom-Json).state } catch { $statusState = $null }
    }

    $pass = $attemptLogged -and $successLogged -and $exeExists -and $appStdoutFound -and
            $smokerunNonzeroLogged -and $skipGuardLogged -and $noRepairRebuild -and ($statusState -eq 'ok')

    Write-HiddenSkipRow -Pass $pass -Desc 'AV-Safe Build Path Tier A: hidden-import auto-recovery correctly skips (never rebuilds via PyInstaller) against a Nuitka-built EXE' -Details ([ordered]@{
        bootstrapExit          = $runExit
        attemptLogged          = [bool]$attemptLogged
        successLogged          = [bool]$successLogged
        exeExists               = [bool]$exeExists
        appStdoutFound          = [bool]$appStdoutFound
        smokerunNonzeroLogged   = [bool]$smokerunNonzeroLogged
        skipGuardLogged         = [bool]$skipGuardLogged
        noRepairRebuild         = [bool]$noRepairRebuild
        statusState             = $statusState
        log                     = $bootstrapLog
    })
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevForceExecfail) { Remove-Item Env:HP_TEST_FORCE_PYINSTALLER_FAIL -ErrorAction SilentlyContinue } else { $env:HP_TEST_FORCE_PYINSTALLER_FAIL = $prevForceExecfail }
}

if (-not $pass) { exit 1 }
exit 0
