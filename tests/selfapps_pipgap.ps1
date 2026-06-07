# REQ-005: pip gap-fill safety net -- EXERCISED THROUGH THE REAL BOOTSTRAP.
#
# This test runs run_setup.bat (the product code) end-to-end on an app whose only requirement
# is opencv-python -- a package pipreqs emits for `import cv2` but which conda-forge cannot supply
# under that name (the cv2/opencv remap lives only in the warnfix path, tools/parse_warn.py). So
# the bootstrapper must: attempt the conda bulk install, fail, fall through to the per-package
# install, fail again, then have the pip gap-fill (`pip install -r requirements.txt`) install it
# from PyPI -- after which `import cv2` works. If anyone removes/reorders/guards-out the gap-fill
# in run_setup.bat, pipgap.pip.fill and pipgap.import go red. That is the regression signal.
#
# Python is pinned to 3.12 via the PVW_TARGET_PY super-user override so an opencv-python wheel
# always exists on PyPI (avoids bleeding-edge-Python no-wheel noise that would mask the signal).
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Path $here -Parent
$nd   = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$ciNd = Join-Path -Path $repoRoot -ChildPath 'ci_test_results.ndjson'
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
    $skipDetails = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    Write-NdjsonRow ([ordered]@{ id = 'pipgap.conda.miss'; req = 'REQ-005'; pass = $true; desc = 'conda-miss skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pipgap.pip.fill';   req = 'REQ-005'; pass = $true; desc = 'pip gap-fill skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pipgap.import';      req = 'REQ-005'; pass = $true; desc = 'import check skipped on non-Windows host'; details = $skipDetails })
    exit 0
}

$work    = Join-Path -Path $here -ChildPath '~pipgap'
$logName = '~pipgap_bootstrap.log'
$logPath = Join-Path -Path $work -ChildPath $logName
$setupLogPath = Join-Path -Path $work -ChildPath '~setup.log'
$runOutPath   = Join-Path -Path $work -ChildPath '~run.out.txt'
$installedPath = Join-Path -Path $work -ChildPath '~dependency_installed.txt'

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $work -Force

# main.py prints a sentinel only reachable if `import cv2` succeeds; run_setup.bat runs the entry
# as a smoke test and captures stdout to ~run.out.txt, giving an end-to-end import proof.
Set-Content -LiteralPath (Join-Path -Path $work -ChildPath 'main.py') -Encoding Ascii -Value @'
import cv2
print("PIPGAP_CV2_OK", cv2.__version__)
'@
Set-Content -LiteralPath (Join-Path -Path $work -ChildPath 'requirements.txt') -Value 'opencv-python' -Encoding Ascii -NoNewline

$exitCode = $null
$errorMessage = $null
# Force the conda env path and pin Python to 3.12 (PyPI opencv wheel guaranteed). conda-full
# already sets HP_FORCE_CONDA_ONLY; set it explicitly so the test is lane-robust.
$savedTargetPy = $env:PVW_TARGET_PY
$savedForceConda = $env:HP_FORCE_CONDA_ONLY
$env:PVW_TARGET_PY = 'python=3.12'
$env:HP_FORCE_CONDA_ONLY = '1'
try {
    Push-Location -LiteralPath $work
    try {
        cmd /c .\run_setup.bat *> $logName
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} catch {
    $errorMessage = $_.Exception.Message
} finally {
    $env:PVW_TARGET_PY = $savedTargetPy
    $env:HP_FORCE_CONDA_ONLY = $savedForceConda
}

# Combine the bootstrapper's internal log (~setup.log: [INSTALL] lines + conda stderr) with the
# captured console stream so assertions see both the call :log echoes and conda's own output.
$setupLog = if (Test-Path -LiteralPath $setupLogPath) { Get-Content -LiteralPath $setupLogPath -Raw -Encoding Ascii } else { '' }
$consoleLog = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw -Encoding Ascii } else { '' }
$log = $setupLog + "`n" + $consoleLog
$runOut = if (Test-Path -LiteralPath $runOutPath) { Get-Content -LiteralPath $runOutPath -Raw -Encoding Ascii } else { '' }
$installed = if (Test-Path -LiteralPath $installedPath) { Get-Content -LiteralPath $installedPath -Raw -Encoding Ascii } else { '' }

# 1) conda product path genuinely misses opencv-python: bulk attempted -> per-pkg fallback fired
#    -> conda reports it is not available from conda-forge.
$bulkAttempted   = ($log -match [regex]::Escape('[INSTALL] conda bulk from ~reqs_conda.txt'))
$perpkgFallback  = ($log -match [regex]::Escape('[INSTALL] conda per-pkg fallback'))
$condaNotFound   = ($log -match 'PackagesNotFoundError') -or ($log -match 'not available from current channels') -or ($log -match 'Nothing provides')
$condaMissPass   = $bulkAttempted -and $perpkgFallback -and $condaNotFound
Write-NdjsonRow ([ordered]@{
    id = 'pipgap.conda.miss'; req = 'REQ-005'; pass = $condaMissPass
    desc = 'run_setup.bat conda bulk+per-pkg both miss opencv-python (PackagesNotFoundError)'
    details = [ordered]@{ exitCode = $exitCode; bulkAttempted = $bulkAttempted; perpkgFallback = $perpkgFallback; condaNotFound = $condaNotFound; error = $errorMessage }
})

# 2) pip gap-fill in run_setup.bat ran and succeeded -> opencv-python landed in the env (pip freeze).
$gapFillRan    = ($log -match [regex]::Escape('[INSTALL] pip gap fill from requirements.txt'))
$gapFillFailed = ($log -match [regex]::Escape('pip install -r requirements.txt failed'))
$installedOpencv = ($installed -match '(?im)^opencv-python\b')
$pipFillPass   = $gapFillRan -and (-not $gapFillFailed) -and $installedOpencv
Write-NdjsonRow ([ordered]@{
    id = 'pipgap.pip.fill'; req = 'REQ-005'; pass = $pipFillPass
    desc = 'run_setup.bat pip gap-fill installs opencv-python from PyPI after conda misses it'
    details = [ordered]@{ exitCode = $exitCode; gapFillRan = $gapFillRan; gapFillFailed = $gapFillFailed; installedOpencv = [bool]$installedOpencv }
})

# 3) End-to-end: the bootstrapped env can `import cv2` (entry smoke stdout carries the sentinel).
$importPass = ($runOut -match 'PIPGAP_CV2_OK')
Write-NdjsonRow ([ordered]@{
    id = 'pipgap.import'; req = 'REQ-005'; pass = $importPass
    desc = 'import cv2 succeeds in the bootstrapped env (entry smoke prints sentinel)'
    details = [ordered]@{ exitCode = $exitCode; sentinelFound = $importPass; runOutLen = $runOut.Length }
})

if (-not $condaMissPass) { Write-Host '[pipgap] conda did not miss opencv-python as expected' }
if (-not $pipFillPass)   { Write-Host '[pipgap] pip gap-fill did not install opencv-python' }
if (-not $importPass)    { Write-Host '[pipgap] import cv2 sentinel not found in entry smoke output' }
