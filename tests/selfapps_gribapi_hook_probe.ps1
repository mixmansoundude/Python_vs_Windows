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
# Non-gating (continue-on-error at the step level) -- exploratory by nature, and the conda-forge
# solve for pygrib+eccodes+python-eccodes+pyinstaller together is untested and may need a real
# CI run to even confirm it resolves cleanly.
#
# This test is deliberately NOT tied to a specific pass/fail expectation on the hidden-import
# question itself -- "pass" means the experiment ran to completion and produced conclusive
# evidence for both the control and experiment builds; the actual finding (did the hidden-import
# help) is recorded in details.hiddenImportHelped for a human to read, matching the established
# "informational, pass=true records an observed fact" convention used elsewhere (e.g.
# diag.conda.available).
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
        pass    = $false
        desc    = 'probe workspace preparation failed'
        details = [ordered]@{ error = $_.Exception.Message }
    })
    exit 1
}

$envName = 'gribapi_probe_env'
$envCreateLog = Join-Path $workDir 'env_create.log'
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
        pass    = $false
        desc    = 'conda env create for pygrib+eccodes+python-eccodes+pyinstaller failed -- cannot run the probe'
        details = [ordered]@{ envCreateExit = $envCreateExit; envCreateTail = ($envCreateText -split "`n" | Select-Object -Last 40) -join "`n" }
    })
    exit 1
}

$condaRoot  = Split-Path -Path (Split-Path -Path $condaBat -Parent) -Parent
$envPython  = Join-Path $condaRoot "envs\$envName\python.exe"
if (-not (Test-Path -LiteralPath $envPython)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.gribapi_hook_probe.hidden_import'
        req     = 'REQ-009'
        pass    = $false
        desc    = 'conda env created but python.exe missing -- cannot run the probe'
        details = [ordered]@{ envPython = $envPython }
    })
    exit 1
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
    $buildLog = Join-Path $workDir "build_$Variant.log"
    $specName = "probe_$Variant"
    $pyiArgs = @('-m', 'PyInstaller', '-y', '--onefile', '--name', $specName,
                 '--distpath', $distDir, '--workpath', $buildDir,
                 '--specpath', $workDir) + $ExtraArgs + @((Join-Path $workDir 'app.py'))
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $envPython
    $psi.Arguments = ($pyiArgs | ForEach-Object { '"' + $_ + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.WorkingDirectory = $workDir
    $proc = [System.Diagnostics.Process]::Start($psi)
    $stdout = $proc.StandardOutput.ReadToEndAsync()
    $stderr = $proc.StandardError.ReadToEndAsync()
    $completed = $proc.WaitForExit(600000)
    $buildExit = if ($completed) { $proc.ExitCode } else { -1 }
    if (-not $completed) {
        try { & taskkill.exe /F /T /PID $proc.Id 2>$null 1>$null } catch {}
    }
    $stdoutText = ''
    $stderrText = ''
    if ($stdout.Wait(10000)) { try { $stdoutText = $stdout.Result } catch {} }
    if ($stderr.Wait(10000)) { try { $stderrText = $stderr.Result } catch {} }
    $combinedLog = $stdoutText + "`n" + $stderrText
    Set-Content -LiteralPath $buildLog -Value $combinedLog -Encoding Ascii

    $dllWarning = $combinedLog -match [regex]::Escape("could not resolve 'eccodes.dll'")
    $exePath = Join-Path $distDir "$specName.exe"
    $exeExists = Test-Path -LiteralPath $exePath
    # derived requirement: check for the DLL landing ANYWHERE under distDir, not just a flat
    # eccodes.dll -- hook-gribapi.py's own directory-preservation logic (Finding 1) nests it
    # under an "eccodes" subfolder on Windows, not the dist root.
    $bundledDll = @(Get-ChildItem -Path $distDir -Recurse -Filter 'eccodes*.dll' -ErrorAction SilentlyContinue).Count -gt 0

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
            $eOutTask = $eproc.StandardOutput.ReadToEndAsync()
            $eErrTask = $eproc.StandardError.ReadToEndAsync()
            if ($eproc.WaitForExit(30000)) {
                $exeExit = $eproc.ExitCode
            } else {
                try { & taskkill.exe /F /T /PID $eproc.Id 2>$null 1>$null } catch {}
                $exeExit = -1
            }
            $eOut = ''; $eErr = ''
            if ($eOutTask.Wait(5000)) { try { $eOut = $eOutTask.Result } catch {} }
            if ($eErrTask.Wait(5000)) { try { $eErr = $eErrTask.Result } catch {} }
            $exeOut = $eOut + $eErr
        } catch {
            $exeOut = $_.Exception.Message
        }
    }
    $dllLoadFailed = $exeOut -match 'DLL load failed'
    $ranClean = ($exeExit -eq 0) -and ($exeOut -match 'pygrib-imported-ok')

    return [ordered]@{
        variant        = $Variant
        buildExit      = $buildExit
        dllWarningSeen = [bool]$dllWarning
        exeExists      = [bool]$exeExists
        bundledDll     = [bool]$bundledDll
        exeExit        = $exeExit
        dllLoadFailed  = [bool]$dllLoadFailed
        ranClean       = [bool]$ranClean
    }
}

$control    = Invoke-ProbeBuild -Variant 'control' -ExtraArgs @()
$experiment = Invoke-ProbeBuild -Variant 'experiment' -ExtraArgs @('--hidden-import', 'gribapi')

& cmd /c "call `"$condaBat`" env remove -y -n $envName >nul 2>&1"

# derived requirement: "conclusive evidence" means both builds actually produced an EXE we could
# launch and observe -- if either build failed to even produce dist_*\probe_*.exe, the experiment
# itself is inconclusive (an infra/solve problem, not a finding about the hidden-import), so pass
# reflects "did this experiment run cleanly," not "did hidden-import fix the DLL."
$conclusive = $control.exeExists -and $experiment.exeExists
$hiddenImportHelped = $null
if ($conclusive) {
    $hiddenImportHelped = (-not $control.ranClean) -and $experiment.ranClean
}

Write-Host "=== self.gribapi_hook_probe.hidden_import evidence ==="
Write-Host ("control:    buildExit={0} exeExists={1} bundledDll={2} exeExit={3} dllLoadFailed={4} ranClean={5}" -f `
    $control.buildExit, $control.exeExists, $control.bundledDll, $control.exeExit, $control.dllLoadFailed, $control.ranClean)
Write-Host ("experiment: buildExit={0} exeExists={1} bundledDll={2} exeExit={3} dllLoadFailed={4} ranClean={5}" -f `
    $experiment.buildExit, $experiment.exeExists, $experiment.bundledDll, $experiment.exeExit, $experiment.dllLoadFailed, $experiment.ranClean)
Write-Host ("conclusive={0} hiddenImportHelped={1}" -f $conclusive, $hiddenImportHelped)
Write-Host "=== end self.gribapi_hook_probe.hidden_import evidence ==="

Write-NdjsonRow ([ordered]@{
    id      = 'self.gribapi_hook_probe.hidden_import'
    req     = 'REQ-009'
    pass    = [bool]$conclusive
    desc    = 'empirical probe: does --hidden-import=gribapi make hook-gribapi.py bundle eccodes.dll for a pygrib build (CLAUDE.md Active Backlog Item 24 / PRD Requirement 1)'
    details = [ordered]@{
        conclusive          = $conclusive
        hiddenImportHelped  = $hiddenImportHelped
        control             = $control
        experiment          = $experiment
    }
})

if (-not $conclusive) { exit 1 }
exit 0
