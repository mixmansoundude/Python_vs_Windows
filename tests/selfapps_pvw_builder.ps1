# ASCII only
# selfapps_pvw_builder.ps1 - CLAUDE.md Item 71: the PVW_BUILDER super-user override
# (auto|pyinstaller|nuitka|both). Absence of the variable means today's behavior (README REQ-019:
# a flag may add a super-user override, never gate a Prime Directive outcome), so every scenario
# below sets it explicitly and asserts a build-tool decision the default run would not make.
#
# Scenarios (PVW_BUILDER_SCENARIO env var):
#   invalid              - PVW_BUILDER=zz9&echo_pwn|v%PATH%^w (not a choice, and full of cmd syntax). The run must
#                          say so once, must not echo the value or act on any part of it, and must behave as
#                          auto: the fallback build is still attempted after the forced PyInstaller failure.
#                          Both build tools are forced to fail, so no real build.
#   pyinstaller_nofallback - PVW_BUILDER=PyInstaller (mixed case, proves case-insensitive) with the PyInstaller
#                          build forced to fail: the Nuitka fallback is switched off, so it is never attempted
#                          (the forced-Nuitka-failure hook is never reached) and the failure is reported. A dist\<env>.exe
#                          from an earlier run is seeded here too (see nuitka_stale) and must be gone afterwards.
#   pyinstaller          - PVW_BUILDER=pyinstaller, a real PyInstaller build succeeds: the optimized-build
#                          offer is not shown at all (the user asked for PyInstaller only).
#   nuitka_forcefail     - PVW_BUILDER=nuitka with the Nuitka build forced to fail: PyInstaller is neither
#                          installed nor run (no EXE, no "PyInstaller produced" line, the "not installed for
#                          this run" line is logged) and the failure is reported with reason=builder_nuitka.
#   nuitka_stale         - PVW_BUILDER=nuitka with the Nuitka build forced to fail while a dist\<env>.exe from an
#                          earlier run is lying there (seeded as a copy of hostname.exe: a real, harmless program that
#                          exits 0, so a run that verifies it looks like a passing build, which is the false green this
#                          guards against). The failed fallback must not leave that old EXE to be verified in place of
#                          the current sources: the file is removed and the verification run goes through the
#                          interpreter, as the log says.
#   nuitka_warnfile      - PVW_BUILDER=nuitka with the Nuitka build forced to fail while build\<env>\warn-<env>.txt from an
#                          earlier PyInstaller run is held open by another program (FileShare.Read: it can be read, not
#                          deleted), so the bootstrapper's own delete of it fails. The file names a module (xlrd) that
#                          the warnfix repair would install and then rebuild for with PyInstaller, which the user asked
#                          not to run: no repair starts, nothing is installed, no PyInstaller rebuild. The log line that says
#                          the repair was skipped is required too, because it is only written when the surviving file was read
#                          and named a module, so a run where the file was simply deleted cannot pass.
#   both_forcefail       - PVW_BUILDER=both with the optimized build forced to fail: the standard build is
#                          verified first, the optimized build starts without a prompt, and its failure leaves
#                          the verified EXE untouched.
#   nuitka               - PVW_BUILDER=nuitka, a REAL Nuitka build (uv lane, non-gating: needs a compiler
#                          download that can fail for network reasons, like selfapps_nuitka_tiera.ps1).
#   both                 - PVW_BUILDER=both, REAL PyInstaller build then a REAL Nuitka build swapped in
#                          after verification (uv lane, non-gating, same reason).
#   nuitka_unsupported   - CLAUDE.md Item 80: PVW_BUILDER=nuitka where Nuitka answers that it does not support this Python
#                          (uv's newest CPython outran Nuitka 4.2.2 for a day in October 2026). A stub nuitka.py in the app
#                          folder stands in for the real package, because `python -m nuitka` finds the current folder first, and
#                          prints that line the way Nuitka does. The real package is still installed first, so the step before the
#                          build is the real one; nothing is compiled. The run must say, in its own words, that the fallback build
#                          system does not support this Python yet, and must NOT send the user off to install Visual Studio.
#   nuitka_failother     - the same stub failing for any other reason, with an "is not supported by Nuitka" line left in ~setup.log by an
#                          EARLIER run: the Visual Studio hint still shows and the new sentence does not (the log persists across runs,
#                          so only this run's lines may count; this row is the negative control for the one above).
#   both_unsupported     - PVW_BUILDER=both with a real PyInstaller build, then the same stub for the optimized build: the optimized
#                          build's failure says the same thing, the verified EXE stays untouched.
#                          (Item 80's three scenarios are deterministic, so they gate on real and conda-full from the first run.)
#
# Emits: self.builder.override
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

$scenario = $env:PVW_BUILDER_SCENARIO
if (-not $scenario) { $scenario = 'invalid' }

function Write-BuilderRow {
    param(
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    # README REQ-009.17 to REQ-009.21: each scenario proves one shall of the PVW_BUILDER group. The tag has to stay
    # a literal for tests/test_req_trace.py (it scans the text), so the lookup is a switch of literal hashtables.
    $tag = switch ($scenario) {
        'invalid'                { @{ req = 'REQ-009.21' } }
        'pyinstaller'            { @{ req = 'REQ-009.17' } }
        'pyinstaller_nofallback' { @{ req = 'REQ-009.17' } }
        'nuitka'                 { @{ req = 'REQ-009.18' } }
        'nuitka_forcefail'       { @{ req = 'REQ-009.18' } }
        'nuitka_warnfile'        { @{ req = 'REQ-009.18' } }
        'nuitka_unsupported'     { @{ req = 'REQ-009.18' } }
        'nuitka_failother'       { @{ req = 'REQ-009.18' } }
        'both_unsupported'       { @{ req = 'REQ-009.20' } }
        'nuitka_stale'           { @{ req = 'REQ-009.19' } }
        'both'                   { @{ req = 'REQ-009.20' } }
        'both_forcefail'         { @{ req = 'REQ-009.20' } }
        default                  { @{ req = 'REQ-009' } }
    }
    Write-NdjsonRow ([ordered]@{ id = 'self.builder.override'; req = $tag.req; pass = $Pass; desc = $Desc; details = $Details })
}

# Non-Windows skip
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-BuilderRow -Pass $true -Desc "PVW_BUILDER override ($scenario, skipped on non-Windows)" -Details ([ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host'; scenario = $scenario })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-BuilderRow -Pass $false -Desc 'PVW_BUILDER override: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath; scenario = $scenario })
    exit 1
}

$workDir = Join-Path $here "~selftest_pvw_builder_$scenario"
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force
Set-Content -Path (Join-Path $workDir 'app.py') -Value @'
print("builder-app-ok")
'@ -Encoding ASCII

$bootstrapLog = "~pvw_builder_${scenario}_bootstrap.log"

$names = @('PVW_BUILDER', 'HP_SKIP_PIPREQS', 'HP_TEST_FORCE_PYINSTALLER_FAIL', 'HP_TEST_FORCE_NUITKA_FAIL', 'HP_TEST_FORCE_OPTBUILD_FAIL')
$prev = @{}
foreach ($n in $names) { $prev[$n] = if (Test-Path "Env:$n") { (Get-Item "Env:$n").Value } else { $null } }
foreach ($n in $names) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue }
$env:HP_SKIP_PIPREQS = '1'
switch ($scenario) {
    'invalid'                { $env:PVW_BUILDER = 'zz9&echo_pwn|v%PATH%^w'; $env:HP_TEST_FORCE_PYINSTALLER_FAIL = '1'; $env:HP_TEST_FORCE_NUITKA_FAIL = '1' }
    'pyinstaller_nofallback' { $env:PVW_BUILDER = 'PyInstaller'; $env:HP_TEST_FORCE_PYINSTALLER_FAIL = '1'; $env:HP_TEST_FORCE_NUITKA_FAIL = '1' }
    'pyinstaller'            { $env:PVW_BUILDER = 'pyinstaller' }
    'nuitka_forcefail'       { $env:PVW_BUILDER = 'nuitka'; $env:HP_TEST_FORCE_NUITKA_FAIL = '1' }
    'nuitka_stale'           { $env:PVW_BUILDER = 'nuitka'; $env:HP_TEST_FORCE_NUITKA_FAIL = '1' }
    'nuitka_warnfile'        { $env:PVW_BUILDER = 'nuitka'; $env:HP_TEST_FORCE_NUITKA_FAIL = '1' }
    'nuitka_unsupported'     { $env:PVW_BUILDER = 'nuitka' }
    'nuitka_failother'       { $env:PVW_BUILDER = 'nuitka' }
    'both_unsupported'       { $env:PVW_BUILDER = 'both' }
    'both_forcefail'         { $env:PVW_BUILDER = 'both'; $env:HP_TEST_FORCE_OPTBUILD_FAIL = '1' }
    'nuitka'                 { $env:PVW_BUILDER = 'nuitka' }
    'both'                   { $env:PVW_BUILDER = 'both' }
}

$envLeaf  = Split-Path $workDir -Leaf
$envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_env' }

# nuitka_stale and pyinstaller_nofallback: an EXE from an earlier run, in the place the bootstrapper builds into. A copy
# of hostname.exe: it is a real program that exits 0, so if the run ever starts it, the verification looks like a pass,
# which is the false green being guarded against. (A text file named .exe was the first version; it made the first red
# run sit on the smoke-runner step for over ten minutes, which proves nothing about this bug.)
$staleSeedPath = Join-Path $workDir "dist\$envName.exe"
$staleSeeded   = $false
if ($scenario -eq 'nuitka_stale' -or $scenario -eq 'pyinstaller_nofallback') {
    New-Item -ItemType Directory -Force -Path (Join-Path $workDir 'dist') | Out-Null
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\hostname.exe') -Destination $staleSeedPath -Force
    $staleSeeded = (Test-Path -LiteralPath $staleSeedPath) -and ((Get-Item -LiteralPath $staleSeedPath).Length -gt 0)
}

# nuitka_warnfile: a PyInstaller warn file from an earlier run, held open with FileShare.Read for the whole bootstrap so the
# bootstrapper can read it but its own delete fails (the same lock as selfapps_pipreqs_output.ps1). It names xlrd, a real
# package, so a repair that wrongly starts installs something harmless and visible in the log.
$warnPath   = Join-Path $workDir "build\$envName\warn-$envName.txt"
$warnSeeded = $false
$lockHeld   = $false
$warnLock   = $null
if ($scenario -eq 'nuitka_warnfile') {
    New-Item -ItemType Directory -Force -Path (Join-Path $workDir "build\$envName") | Out-Null
    Set-Content -LiteralPath $warnPath -Value 'missing module named xlrd - imported by app (top-level)' -Encoding ASCII
    $warnSeeded = Test-Path -LiteralPath $warnPath
    if ($warnSeeded) {
        $warnLock = [System.IO.File]::Open($warnPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        # Prove the lock works here: a delete must fail and leave the file.
        try { [System.IO.File]::Delete($warnPath) } catch { }
        $lockHeld = Test-Path -LiteralPath $warnPath
    }
}

# Item 80 scenarios: a stub nuitka.py next to app.py stands in for the package (cwd is first on sys.path for -m), and
# prints what the real Nuitka prints for an unsupported Python, or a different failure for the negative control. app.py is
# preferred by the entry selection (REQ-002), so the stub is never run as the program. nuitka_failother also leaves an
# "is not supported by Nuitka" line from an earlier run in ~setup.log, which the bootstrapper appends to.
$stubLine = $null
$stubPath = Join-Path $workDir 'nuitka.py'
$setupLogPath = Join-Path $workDir '~setup.log'
$staleLine = "Nuitka:FATAL: The Python version '3.15' is not supported by Nuitka '4.2.2'."
$staleSeededInLog = $false
if ($scenario -eq 'nuitka_unsupported' -or $scenario -eq 'both_unsupported') {
    $stubLine = "Nuitka:FATAL: The Python version '9.99' is not supported by Nuitka '0.0.0'."
} elseif ($scenario -eq 'nuitka_failother') {
    $stubLine = 'Nuitka:FATAL: no C compiler was found (test stub, any other reason).'
    Set-Content -LiteralPath $setupLogPath -Value $staleLine -Encoding ASCII
    $staleSeededInLog = [bool](Select-String -LiteralPath $setupLogPath -SimpleMatch 'is not supported by Nuitka' -Quiet)
}
if ($stubLine) {
    Set-Content -LiteralPath $stubPath -Value @('import sys', ('print("' + $stubLine + '")'), 'sys.exit(1)') -Encoding ASCII
}

$pass = $false
try {
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        Pop-Location
        if ($warnLock) { $warnLock.Dispose() }
    }

    $logPath  = Join-Path $workDir $bootstrapLog
    $logLines = if (Test-Path $logPath) { Get-Content -LiteralPath $logPath -Encoding ASCII } else { @() }
    $combined = $logLines -join "`n"
    function Has([string]$text) { return [bool]($combined -match [regex]::Escape($text)) }

    $exePath    = Join-Path $workDir "dist\$envName.exe"
    $tmpExePath = Join-Path $workDir "dist\$envName.optimized_build.exe"
    $exeExists  = Test-Path -LiteralPath $exePath
    $tmpExeGone = -not (Test-Path -LiteralPath $tmpExePath)

    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusText = if (Test-Path -LiteralPath $statusPath) { Get-Content -LiteralPath $statusPath -Raw } else { $null }
    $statusState = $null
    if ($statusText) {
        try { $statusState = ($statusText | ConvertFrom-Json).state } catch { $statusState = $null }
    }

    # The EXE in dist\ runs and prints the fixture's token (cmd /c with the full name: PowerShell's & does not
    # search the current directory, see selfapps_optimized_build.ps1).
    $exeRuns = $false
    if ($exeExists) {
        try {
            Push-Location (Join-Path $workDir 'dist')
            try {
                $out = cmd /c "`"$envName.exe`"" 2>&1
                $exeRuns = ($LASTEXITCODE -eq 0) -and ($out -join "`n") -match [regex]::Escape('builder-app-ok')
            } finally { Pop-Location }
        } catch { $exeRuns = $false }
    }

    $setupLogText = if (Test-Path -LiteralPath $setupLogPath) { [System.IO.File]::ReadAllText($setupLogPath) } else { '' }
    $stubRan = [bool]($stubLine -and $setupLogText.Contains($stubLine))
    $installFailed = (Has 'could not install the fallback build tool') -or (Has 'could not install the build tool')
    $honestLine = Has 'does not support this Python version yet'
    $vsHint = Has 'Desktop development with C++'

    $overrideLogged   = Has 'Using super-user override for PVW_BUILDER:'
    $promptShown      = Has 'Want to build an optimized version too?'
    $pyiProduced      = Has 'PyInstaller produced dist'
    $fallbackTried    = Has 'attempting a fallback build'
    $nuitkaHookFired  = Has '[TEST] HP_TEST_FORCE_NUITKA_FAIL'
    $pyiInstallSkipped = Has 'PVW_BUILDER=nuitka: PyInstaller is not installed for this run.'
    $optHookFired     = Has '[TEST] HP_TEST_FORCE_OPTBUILD_FAIL'
    $optSucceeded     = Has 'Optimized build succeeded and verified'

    $details = [ordered]@{
        scenario       = $scenario
        bootstrapExit  = $runExit
        statusState    = $statusState
        overrideLogged = $overrideLogged
        promptShown    = $promptShown
        pyiProduced    = $pyiProduced
        fallbackTried  = $fallbackTried
        exeExists      = [bool]$exeExists
        log            = $bootstrapLog
    }

    switch ($scenario) {
        'invalid' {
            $warnLogged   = Has 'PVW_BUILDER is not one of auto, pyinstaller, nuitka or both; using auto.'
            $valueEchoed  = (Has 'zz9') -or (Has 'echo_pwn')
            $reasonOk     = Has 'reason=test_forced_fail'
            $pass = $warnLogged -and (-not $overrideLogged) -and (-not $valueEchoed) -and $fallbackTried -and $nuitkaHookFired -and $reasonOk -and ($statusState -eq 'error')
            $details.warnLogged = $warnLogged; $details.valueEchoed = $valueEchoed; $details.nuitkaHookFired = $nuitkaHookFired; $details.reasonOk = $reasonOk
            $desc = 'PVW_BUILDER (invalid value full of cmd syntax): warned once, value not echoed or acted on, behaves as auto (the fallback build is still attempted)'
        }
        'pyinstaller_nofallback' {
            $switchedOff = Has 'PVW_BUILDER=pyinstaller: the fallback build system is switched off'
            $reasonOk    = Has 'reason=test_forced_fail'
            $ranViaExe   = Has 'smoke test via packaged EXE'
            $pass = $staleSeeded -and $overrideLogged -and $switchedOff -and (-not $fallbackTried) -and (-not $nuitkaHookFired) -and $reasonOk -and (-not $exeExists) -and (-not $ranViaExe) -and ($statusState -eq 'error')
            $details.staleSeeded = [bool]$staleSeeded; $details.switchedOff = $switchedOff; $details.nuitkaHookFired = $nuitkaHookFired; $details.reasonOk = $reasonOk; $details.ranViaExe = $ranViaExe
            $desc = 'PVW_BUILDER=pyinstaller: a PyInstaller failure is reported, the Nuitka fallback is never attempted, and an EXE left by an earlier run is not verified in its place'
        }
        'pyinstaller' {
            $optOffer = Has 'Optimized build:'
            $pass = $overrideLogged -and $pyiProduced -and $exeExists -and $exeRuns -and (-not $promptShown) -and (-not $optOffer) -and ($statusState -eq 'ok')
            $details.exeRuns = [bool]$exeRuns; $details.optOffer = $optOffer
            $desc = 'PVW_BUILDER=pyinstaller: a real PyInstaller build is kept and the optimized-build offer is never shown'
        }
        'nuitka_forcefail' {
            $skipLogged = Has 'PVW_BUILDER=nuitka: skipping the standard PyInstaller build'
            $reasonOk   = Has 'reason=builder_nuitka'
            $pass = $overrideLogged -and $skipLogged -and $pyiInstallSkipped -and $nuitkaHookFired -and (-not $pyiProduced) -and (-not $exeExists) -and $reasonOk -and ($statusState -eq 'error')
            $details.skipLogged = $skipLogged; $details.pyiInstallSkipped = $pyiInstallSkipped; $details.nuitkaHookFired = $nuitkaHookFired; $details.reasonOk = $reasonOk
            $desc = 'PVW_BUILDER=nuitka: PyInstaller is neither installed nor run and a failed Nuitka build is reported with reason=builder_nuitka'
        }
        'nuitka_stale' {
            $skipLogged   = Has 'PVW_BUILDER=nuitka: skipping the standard PyInstaller build'
            $reasonOk     = Has 'reason=builder_nuitka'
            $ranViaExe    = Has 'smoke test via packaged EXE'
            $ranViaInterp = [bool]($combined -match 'Running entry script smoke test via \w+ interpreter')
            $pass = $staleSeeded -and $overrideLogged -and $skipLogged -and $nuitkaHookFired -and $reasonOk -and (-not $exeExists) -and (-not $ranViaExe) -and $ranViaInterp -and ($statusState -eq 'error')
            $details.staleSeeded = [bool]$staleSeeded; $details.skipLogged = $skipLogged; $details.nuitkaHookFired = $nuitkaHookFired; $details.reasonOk = $reasonOk; $details.ranViaExe = $ranViaExe; $details.ranViaInterp = $ranViaInterp
            $desc = 'PVW_BUILDER=nuitka: a failed Nuitka build removes the EXE left by an earlier run, so the verification run goes through the interpreter as logged'
        }
        'nuitka_warnfile' {
            $skipLogged   = Has 'PVW_BUILDER=nuitka: skipping the standard PyInstaller build'
            $skipNoted    = Has 'PVW_BUILDER=nuitka: the warnfix repair is skipped'
            $repairStarted = Has '[REPAIR] missing modules detected'
            $installTried = Has 'Attempting to install'
            $pyiRebuild   = Has 'Rebuilding standalone executable after warnfix'
            $pass = $warnSeeded -and $lockHeld -and $overrideLogged -and $skipLogged -and $nuitkaHookFired -and $skipNoted -and (-not $repairStarted) -and (-not $installTried) -and (-not $pyiRebuild) -and (-not $pyiProduced) -and (-not $exeExists) -and ($statusState -eq 'error')
            $details.warnSeeded = [bool]$warnSeeded; $details.lockHeld = [bool]$lockHeld; $details.skipLogged = $skipLogged; $details.nuitkaHookFired = $nuitkaHookFired
            $details.skipNoted = $skipNoted; $details.repairStarted = $repairStarted; $details.installTried = $installTried; $details.pyiRebuild = $pyiRebuild
            $desc = 'PVW_BUILDER=nuitka: a PyInstaller warn file that survives the delete never starts the warnfix repair or a PyInstaller rebuild'
        }
        'nuitka_unsupported' {
            $skipLogged = Has 'PVW_BUILDER=nuitka: skipping the standard PyInstaller build'
            $reasonOk   = Has 'reason=builder_nuitka'
            $failLogged = Has 'Fallback build did not complete successfully.'
            $pass = $overrideLogged -and $skipLogged -and $stubRan -and (-not $installFailed) -and $failLogged -and $honestLine -and (-not $vsHint) -and (-not $exeExists) -and $reasonOk -and ($statusState -eq 'error')
            $details.skipLogged = $skipLogged; $details.stubRan = $stubRan; $details.installFailed = $installFailed; $details.failLogged = $failLogged
            $details.honestLine = $honestLine; $details.vsHint = $vsHint; $details.reasonOk = $reasonOk
            $desc = 'PVW_BUILDER=nuitka: when Nuitka says it does not support this Python, the run says so in plain words and does not send the user to install Visual Studio'
        }
        'nuitka_failother' {
            $skipLogged = Has 'PVW_BUILDER=nuitka: skipping the standard PyInstaller build'
            $failLogged = Has 'Fallback build did not complete successfully.'
            $pass = $staleSeededInLog -and $overrideLogged -and $skipLogged -and $stubRan -and (-not $installFailed) -and $failLogged -and $vsHint -and (-not $honestLine) -and (-not $exeExists) -and ($statusState -eq 'error')
            $details.staleSeededInLog = $staleSeededInLog; $details.skipLogged = $skipLogged; $details.stubRan = $stubRan; $details.installFailed = $installFailed
            $details.failLogged = $failLogged; $details.honestLine = $honestLine; $details.vsHint = $vsHint
            $desc = 'PVW_BUILDER=nuitka: any other Nuitka failure still shows the Visual Studio hint, and an unsupported-Python line left by an earlier run is not counted'
        }
        'both_unsupported' {
            $bothLogged = Has 'PVW_BUILDER=both: building the optimized version now without asking.'
            $optFailed  = Has 'Optimized build did not complete; your app is still ready to use as-is.'
            $pass = $overrideLogged -and $pyiProduced -and $bothLogged -and $stubRan -and (-not $installFailed) -and $optFailed -and $honestLine -and (-not $vsHint) -and (-not $optSucceeded) -and $exeExists -and $tmpExeGone -and $exeRuns -and ($statusState -eq 'ok')
            $details.bothLogged = $bothLogged; $details.stubRan = $stubRan; $details.installFailed = $installFailed; $details.optFailed = $optFailed
            $details.honestLine = $honestLine; $details.vsHint = $vsHint; $details.tmpExeGone = [bool]$tmpExeGone; $details.exeRuns = [bool]$exeRuns
            $desc = 'PVW_BUILDER=both: when Nuitka says it does not support this Python, the optimized build says so plainly and the verified EXE is left untouched'
        }
        'both_forcefail' {
            $bothLogged = Has 'PVW_BUILDER=both: building the optimized version now without asking.'
            $warnsRerun = Has 'starts your program once more for up to 30 seconds'
            $pass = $overrideLogged -and $pyiProduced -and $bothLogged -and $warnsRerun -and (-not $promptShown) -and $optHookFired -and (-not $optSucceeded) -and $exeExists -and $tmpExeGone -and $exeRuns -and ($statusState -eq 'ok')
            $details.bothLogged = $bothLogged; $details.warnsRerun = $warnsRerun; $details.optHookFired = $optHookFired; $details.tmpExeGone = [bool]$tmpExeGone; $details.exeRuns = [bool]$exeRuns
            $desc = 'PVW_BUILDER=both: the optimized build starts without a prompt after the standard build verifies, and a failure leaves the verified EXE untouched'
        }
        'nuitka' {
            $fallbackOk = Has 'Fallback build succeeded'
            $pass = $overrideLogged -and $pyiInstallSkipped -and (-not $pyiProduced) -and $fallbackOk -and $exeExists -and $exeRuns -and ($statusState -eq 'ok')
            $details.fallbackOk = $fallbackOk; $details.pyiInstallSkipped = $pyiInstallSkipped; $details.exeRuns = [bool]$exeRuns
            $desc = 'PVW_BUILDER=nuitka: a real Nuitka build is produced without running PyInstaller'
        }
        'both' {
            $pass = $overrideLogged -and $pyiProduced -and (-not $promptShown) -and $optSucceeded -and $exeExists -and $tmpExeGone -and $exeRuns -and ($statusState -eq 'ok')
            $details.optSucceeded = $optSucceeded; $details.tmpExeGone = [bool]$tmpExeGone; $details.exeRuns = [bool]$exeRuns
            $desc = 'PVW_BUILDER=both: a real PyInstaller build is verified, then a real Nuitka build is swapped in without a prompt'
        }
        default {
            $pass = $false
            $desc = "PVW_BUILDER override: unknown scenario $scenario"
        }
    }
    Write-BuilderRow -Pass $pass -Desc $desc -Details $details
} finally {
    foreach ($n in $names) {
        if ($null -eq $prev[$n]) { Remove-Item "Env:$n" -ErrorAction SilentlyContinue } else { Set-Item "Env:$n" -Value $prev[$n] }
    }
}

if (-not $pass) { exit 1 }
exit 0
