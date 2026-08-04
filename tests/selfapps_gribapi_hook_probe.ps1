# ASCII only
# selfapps_gribapi_hook_probe.ps1 - one-off empirical experiment for CLAUDE.md Active Backlog
# Item 24 / docs/prd-conda-native-dll-bundling.md's Requirement 1: does forcing
# --hidden-import=gribapi onto a pygrib PyInstaller build make pyinstaller-hooks-contrib's
# existing hook-gribapi.py bundle eccodes.dll for free, without any new bootstrapper mechanism?
#
# Background (see the PRD's Finding 1 for the full research trail): pygrib's own compiled
# extension links against eccodes.dll directly; PyInstaller never discovers/bundles it, so a
# frozen EXE importing pygrib fails at runtime with "ImportError: DLL load failed while
# importing _pygrib". pyinstaller-hooks-contrib ships hook-gribapi.py, which at build time
# queries gribapi.bindings.library_path to locate and bundle the eccodes shared library -- but
# pygrib and gribapi (the conda-forge package python-eccodes) are architecturally INDEPENDENT
# bindings to the same C library; pygrib never imports gribapi, so the hook has no reason to
# fire for a pygrib-only build. This test proves that empirically rather than relying on
# analysis alone, per explicit owner instruction to verify via real CI.
#
# Deliberately standalone -- does NOT invoke run_setup.bat or its REQ-009 provider cascade at
# all. The question here is narrow (does one PyInstaller flag change one DLL's bundling
# outcome), so a direct conda-env-plus-PyInstaller harness is more isolated and faster than
# reusing the full bootstrap+cascade machinery selfapps_layered_e2e.ps1 already proves works.
#
# Lane: conda-full only. Miniconda is always installed for real in that lane regardless of step
# ordering (CLAUDE.md's lane table), so this avoids the CI-ordering placement constraints other
# conda-dependent tests need (see selfapps_conda_bothfail.ps1's own placement note for contrast).
#
# derived requirement: this row is genuinely diagnostic/exploratory, not a correctness
# assertion about the bootstrapper -- it must NEVER emit pass=false. A CodeRabbit review on this
# PR's first commit correctly found that `continue-on-error: true` on the CI step does NOT make
# a row non-gating on its own: batch-check.yml's separate "Verdict from NDJSON" + "Enforce
# NDJSON failures for gated lanes" steps scan raw NDJSON pass values across ALL rows and fail
# the conda-full lane job outright on any pass=false, independent of which step emitted it.
# Every exit path below (including genuine infra failures such as a failed conda env create)
# therefore emits pass=true and exits 0 -- skip=true or details.conclusive=false carries the
# real outcome instead of a gating failure.
#
# Emits: self.gribapi_hook_probe.hidden_import
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path -LiteralPath $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

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
        id      = 'self.gribapi_hook_probe.hidden_import'
        req     = 'REQ-009'
        pass    = $true
        skip    = $true
        desc    = 'gribapi hook --hidden-import probe skipped on non-Windows'
        details = [ordered]@{ reason = 'non-windows-host' }
    })
    exit 0
}

function Get-CondaBatPath {
    $publicRoot = [Environment]::GetEnvironmentVariable('PUBLIC')
    $publicRootClean = if ($publicRoot) { $publicRoot.Trim().Trim('"') } else { '' }
    $candidates = @()
    if ($publicRootClean) {
        $candidates += Join-Path $publicRootClean 'Documents\Miniconda3\condabin\conda.bat'
    }
    $candidates += 'C:\Miniconda3\condabin\conda.bat'
    $candidates += 'C:\ProgramData\Miniconda3\condabin\conda.bat'
    $candidates += 'C:\Users\Public\Documents\Miniconda3\condabin\conda.bat'
    return ($candidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1)
}

$condaBat = Get-CondaBatPath
if (-not $condaBat) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.gribapi_hook_probe.hidden_import'
        req     = 'REQ-009'
        pass    = $true
        skip    = $true
        desc    = 'gribapi hook --hidden-import probe skipped: conda not found'
        details = [ordered]@{ reason = 'conda-not-installed' }
    })
    exit 0
}

$workDir = Join-Path $here '~selftest_gribapi_probe'
try {
    if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop }
    New-Item -ItemType Directory -Force -Path $workDir -ErrorAction Stop | Out-Null
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.gribapi_hook_probe.hidden_import'
        req     = 'REQ-009'
        pass    = $true
        skip    = $true
        desc    = 'gribapi hook --hidden-import probe skipped: workspace preparation failed'
        details = [ordered]@{ reason = 'workspace-prep-failed'; error = $_.Exception.Message }
    })
    exit 0
}

$envName = 'gribapi_probe_env'
$envCreateLog = Join-Path $workDir '~env_create.log'
& cmd /c "call `"$condaBat`" env remove -y -n $envName >nul 2>&1"
& cmd /c "call `"$condaBat`" create -y -n $envName python pip pyinstaller pygrib eccodes python-eccodes --override-channels -c conda-forge > `"$envCreateLog`" 2>&1"
$envCreateExit = $LASTEXITCODE
$envCreateText = if (Test-Path -LiteralPath $envCreateLog) { Get-Content -LiteralPath $envCreateLog -Raw -Encoding ASCII } else { '' }

if ($envCreateExit -ne 0) {
    Write-Host "=== self.gribapi_hook_probe.hidden_import: conda env create failed ==="
    Write-Host $envCreateText
    Write-NdjsonRow ([ordered]@{
        id      = 'self.gribapi_hook_probe.hidden_import'
        req     = 'REQ-009'
        pass    = $true
        skip    = $true
        desc    = 'gribapi hook --hidden-import probe skipped: conda env create for pygrib+eccodes+python-eccodes+pyinstaller failed'
        details = [ordered]@{ reason = 'env-create-failed'; envCreateExit = $envCreateExit; envCreateTail = ($envCreateText -split "`n" | Select-Object -Last 40) -join "`n" }
    })
    exit 0
}

$condaRoot  = Split-Path -Path (Split-Path -Path $condaBat -Parent) -Parent
$envPython  = Join-Path $condaRoot "envs\$envName\python.exe"
if (-not (Test-Path -LiteralPath $envPython)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.gribapi_hook_probe.hidden_import'
        req     = 'REQ-009'
        pass    = $true
        skip    = $true
        desc    = 'gribapi hook --hidden-import probe skipped: conda env created but python.exe missing'
        details = [ordered]@{ reason = 'env-python-missing'; envPython = $envPython }
    })
    exit 0
}

$appCode = @'
import pygrib
print("pygrib-imported-ok")
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

function Invoke-ProbeBuild {
    param(
        [string]$Variant,
        [string[]]$ExtraArgs
    )
    $distDir  = Join-Path $workDir "dist_$Variant"
    $buildDir = Join-Path $workDir "build_$Variant"
    $buildLog = Join-Path $workDir "~build_$Variant.log"
    $specName = "probe_$Variant"
    $pyiArgs = @('-m', 'PyInstaller', '-y', '--onefile', '--name', $specName,
                 '--distpath', $distDir, '--workpath', $buildDir,
                 '--specpath', $workDir) + $ExtraArgs + @((Join-Path $workDir 'app.py'))

    # derived requirement (CodeRabbit review finding): a launch exception, a timeout, or a
    # failed output read must each be tracked explicitly and distinctly from a genuine build/run
    # result -- collapsing them all into the same -1/empty-string defaults let an incomplete
    # observation masquerade as a real (negative) finding. buildLaunched/buildCompleted/
    # buildOutputCaptured (and the EXE-side equivalents below) make "did we actually observe
    # this variant's real behavior" a first-class, checkable fact instead of an implicit
    # assumption baked into $conclusive.
    $buildLaunched  = $false
    $buildCompleted = $false
    $buildOutputCaptured = $false
    $buildExit = -1
    $stdoutText = ''
    $stderrText = ''
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $envPython
        $psi.Arguments = ($pyiArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.WorkingDirectory = $workDir
        $proc = [System.Diagnostics.Process]::Start($psi)
        $buildLaunched = $true
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
        $buildCompleted = $proc.WaitForExit(600000)
        if ($buildCompleted) {
            $buildExit = $proc.ExitCode
        } else {
            try {
                & taskkill.exe /F /T /PID $proc.Id 2>$null 1>$null
            } catch {
                Write-Warning "taskkill failed for build PID $($proc.Id): $($_.Exception.Message)"
            }
        }
        $stdoutOk = $stdoutTask.Wait(10000)
        $stderrOk = $stderrTask.Wait(10000)
        if ($stdoutOk) { try { $stdoutText = $stdoutTask.Result } catch {} }
        if ($stderrOk) { try { $stderrText = $stderrTask.Result } catch {} }
        $buildOutputCaptured = $stdoutOk -and $stderrOk
    } catch {
        Write-Warning "PyInstaller launch failed for variant '$Variant': $($_.Exception.Message)"
    }
    $combinedLog = $stdoutText + "`n" + $stderrText
    Set-Content -LiteralPath $buildLog -Value $combinedLog -Encoding Ascii

    $dllWarning = $combinedLog -match [regex]::Escape("could not resolve 'eccodes.dll'")
    $exePath = Join-Path $distDir "$specName.exe"
    $exeExists = Test-Path -LiteralPath $exePath
    # derived requirement: check for the DLL landing ANYWHERE under distDir, not just a flat
    # eccodes.dll -- hook-gribapi.py's own directory-preservation logic (Finding 1) nests it
    # under an "eccodes" subfolder on Windows, not the dist root.
    $bundledDll = @(Get-ChildItem -Path $distDir -Recurse -Filter 'eccodes*.dll' -ErrorAction SilentlyContinue).Count -gt 0

    $exeLaunched = $false
    $exeCompleted = $false
    $exeOutputCaptured = $false
    $exeExit = -1
    $exeOut = ''
    if ($exeExists) {
        try {
            $epsi = New-Object System.Diagnostics.ProcessStartInfo
            $epsi.FileName = $exePath
            $epsi.UseShellExecute = $false
            $epsi.RedirectStandardOutput = $true
            $epsi.RedirectStandardError = $true
            $eproc = [System.Diagnostics.Process]::Start($epsi)
            $exeLaunched = $true
            $eOutTask = $eproc.StandardOutput.ReadToEndAsync()
            $eErrTask = $eproc.StandardError.ReadToEndAsync()
            $exeCompleted = $eproc.WaitForExit(30000)
            if ($exeCompleted) {
                $exeExit = $eproc.ExitCode
            } else {
                try {
                    & taskkill.exe /F /T /PID $eproc.Id 2>$null 1>$null
                } catch {
                    Write-Warning "taskkill failed for EXE PID $($eproc.Id): $($_.Exception.Message)"
                }
            }
            $eOut = ''; $eErr = ''
            $eOutOk = $eOutTask.Wait(5000)
            $eErrOk = $eErrTask.Wait(5000)
            if ($eOutOk) { try { $eOut = $eOutTask.Result } catch {} }
            if ($eErrOk) { try { $eErr = $eErrTask.Result } catch {} }
            $exeOutputCaptured = $eOutOk -and $eErrOk
            $exeOut = $eOut + $eErr
        } catch {
            Write-Warning "EXE launch failed for variant '$Variant': $($_.Exception.Message)"
        }
    }
    $dllLoadFailed = $exeOut -match 'DLL load failed'

    # derived requirement: an "observation" only counts as complete when the EXE genuinely
    # launched, ran to completion within the timeout (not killed), and both output streams were
    # fully captured -- only then can ranClean's absence be trusted as a real negative result
    # rather than an artifact of a hung process or a truncated read.
    $observationComplete = $exeExists -and $exeLaunched -and $exeCompleted -and $exeOutputCaptured
    $ranClean = $observationComplete -and ($exeExit -eq 0) -and ($exeOut -match 'pygrib-imported-ok')

    return [ordered]@{
        variant              = $Variant
        buildLaunched        = [bool]$buildLaunched
        buildCompleted       = [bool]$buildCompleted
        buildOutputCaptured  = [bool]$buildOutputCaptured
        buildExit            = $buildExit
        dllWarningSeen       = [bool]$dllWarning
        exeExists            = [bool]$exeExists
        bundledDll           = [bool]$bundledDll
        exeLaunched          = [bool]$exeLaunched
        exeCompleted         = [bool]$exeCompleted
        exeOutputCaptured    = [bool]$exeOutputCaptured
        observationComplete  = [bool]$observationComplete
        exeExit              = $exeExit
        dllLoadFailed        = [bool]$dllLoadFailed
        ranClean             = [bool]$ranClean
    }
}

$control    = Invoke-ProbeBuild -Variant 'control' -ExtraArgs @()
$experiment = Invoke-ProbeBuild -Variant 'experiment' -ExtraArgs @('--hidden-import', 'gribapi')

& cmd /c "call `"$condaBat`" env remove -y -n $envName >nul 2>&1"

# derived requirement (CodeRabbit review finding): "conclusive evidence" must require a
# COMPLETE runtime observation for both variants, not merely that a dist\*.exe file exists on
# disk -- a build that produced an EXE which then hung or whose output read timed out is NOT
# evidence about whether the hidden-import helped, and must not be treated as if it were.
$conclusive = $control.observationComplete -and $experiment.observationComplete
$hiddenImportHelped = $null
if ($conclusive) {
    $hiddenImportHelped = (-not $control.ranClean) -and $experiment.ranClean
}

Write-Host "=== self.gribapi_hook_probe.hidden_import evidence ==="
Write-Host ("control:    buildExit={0} exeExists={1} bundledDll={2} observationComplete={3} exeExit={4} dllLoadFailed={5} ranClean={6}" -f `
    $control.buildExit, $control.exeExists, $control.bundledDll, $control.observationComplete, $control.exeExit, $control.dllLoadFailed, $control.ranClean)
Write-Host ("experiment: buildExit={0} exeExists={1} bundledDll={2} observationComplete={3} exeExit={4} dllLoadFailed={5} ranClean={6}" -f `
    $experiment.buildExit, $experiment.exeExists, $experiment.bundledDll, $experiment.observationComplete, $experiment.exeExit, $experiment.dllLoadFailed, $experiment.ranClean)
Write-Host ("conclusive={0} hiddenImportHelped={1}" -f $conclusive, $hiddenImportHelped)
Write-Host "=== end self.gribapi_hook_probe.hidden_import evidence ==="

# derived requirement: pass is ALWAYS true -- this row is diagnostic/exploratory (see the file
# header comment), never a bootstrapper-correctness assertion, so it must never fail the
# conda-full lane's gated NDJSON verdict regardless of what this probe observed.
Write-NdjsonRow ([ordered]@{
    id      = 'self.gribapi_hook_probe.hidden_import'
    req     = 'REQ-009'
    pass    = $true
    desc    = 'empirical probe: does --hidden-import=gribapi make hook-gribapi.py bundle eccodes.dll for a pygrib build (CLAUDE.md Active Backlog Item 24 / PRD Requirement 1)'
    details = [ordered]@{
        conclusive          = $conclusive
        hiddenImportHelped  = $hiddenImportHelped
        control             = $control
        experiment          = $experiment
    }
})

exit 0
