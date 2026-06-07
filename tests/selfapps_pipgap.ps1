# REQ-005: pip gap-fill safety net -- a requirement that conda-forge cannot supply under the
# pipreqs-produced name (opencv-python, for `import cv2`) must be installed by the pip gap-fill
# step (`pip install -r requirements.txt`) that run_setup.bat runs after conda. This mirrors the
# documented cv2/opencv name-mismatch limitation: conda misses it, pip catches it.
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path -LiteralPath $nd)) { New-Item -ItemType File -Path $nd -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

function Write-NdjsonRow {
    param([hashtable]$Row)

    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

function Get-CondaBatPath {
    $publicRoot = [Environment]::GetEnvironmentVariable('PUBLIC')
    $publicRootClean = if ($publicRoot) { $publicRoot.Trim().Trim('"') } else { '' }
    $condaBatCandidates = @()
    if ($publicRootClean) {
        $condaBatCandidates += Join-Path $publicRootClean 'Documents\Miniconda3\condabin\conda.bat'
        $condaBatCandidates += Join-Path $publicRootClean 'Documents\Miniconda3\Scripts\conda.bat'
    }
    $condaBatCandidates += 'C:\Miniconda3\condabin\conda.bat'
    $condaBatCandidates += 'C:\Miniconda3\Scripts\conda.bat'
    $condaBatCandidates += 'C:\ProgramData\Miniconda3\condabin\conda.bat'
    $condaBatCandidates += 'C:\ProgramData\Miniconda3\Scripts\conda.bat'
    $condaBatCandidates += 'C:\Users\Public\Documents\Miniconda3\condabin\conda.bat'
    $condaBatCandidates += 'C:\Users\Public\Documents\Miniconda3\Scripts\conda.bat'

    $condaBat = $condaBatCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $condaBat) {
        $whereResult = where.exe conda 2>$null
        if ($whereResult) { $condaBat = ($whereResult -split "`r?`n")[0].Trim() }
    }

    return [ordered]@{
        path = $condaBat
        candidates = $condaBatCandidates
        publicRoot = if ($publicRoot) { $publicRoot } else { '(empty)' }
    }
}

if (-not $IsWindows) {
    $skipDetails = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    Write-NdjsonRow ([ordered]@{ id = 'pipgap.conda.miss'; req = 'REQ-005'; pass = $true; desc = 'conda-miss skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pipgap.pip.fill';   req = 'REQ-005'; pass = $true; desc = 'pip gap-fill skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pipgap.import';      req = 'REQ-005'; pass = $true; desc = 'import check skipped on non-Windows host'; details = $skipDetails })
    exit 0
}

$work = Join-Path $here '~pipgap'
$logPath = Join-Path $work '~pipgap.log'
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }

$appPath = Join-Path $work 'main.py'
$reqPath = Join-Path $work 'requirements.txt'
# ~reqs_conda.txt is what run_setup.bat feeds conda; opencv-python is not on conda-forge under this
# name (the cv2/opencv remap lives only in the warnfix path, tools/parse_warn.py), so conda must miss it.
$condaReqPath = Join-Path $work '~reqs_conda.txt'

Set-Content -LiteralPath $appPath -Encoding Ascii -Value @'
import cv2
print("PIPGAP_CV2_OK", cv2.__version__)
'@
Set-Content -LiteralPath $reqPath -Encoding Ascii -Value 'opencv-python'
Set-Content -LiteralPath $condaReqPath -Encoding Ascii -Value 'opencv-python'

$envName = '_pipgap'
$condaMissDetails = [ordered]@{ exitCode = -1; notFound = $false; env = $envName }
$pipFillDetails   = [ordered]@{ exitCode = -1; env = $envName }
$importDetails    = [ordered]@{ exitCode = -1; cv2Marker = $false; viaPypi = $false }

$condaInfo = Get-CondaBatPath
$condaBat = $condaInfo.path
if (-not $condaBat) {
    $condaMissDetails.reason = 'conda-not-found'
    $condaMissDetails.condaBatCandidates = $condaInfo.candidates
    Write-NdjsonRow ([ordered]@{ id = 'pipgap.conda.miss'; req = 'REQ-005'; pass = $false; desc = 'conda cannot supply opencv-python (PackagesNotFoundError)'; details = $condaMissDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pipgap.pip.fill';   req = 'REQ-005'; pass = $false; desc = 'pip gap-fill installs opencv-python from PyPI'; details = $pipFillDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pipgap.import';      req = 'REQ-005'; pass = $false; desc = 'import cv2 succeeds after pip gap-fill'; details = $importDetails })
    exit 0
}

# Isolated env with a pinned, wheel-supported Python so opencv-python always has a PyPI wheel
# (avoids bleeding-edge-Python no-wheel flakiness that would muddy the gap-fill signal).
$createOut = cmd /c "`"$condaBat`" create -y -n $envName --override-channels -c conda-forge python=3.12 pip" 2>&1
Add-Content -LiteralPath $logPath -Value 'conda create output:' -Encoding Ascii
Add-Content -LiteralPath $logPath -Value ($createOut | Out-String) -Encoding Ascii

# 1) conda install from conda-forge -- expected to FAIL: opencv-python is not a conda-forge package name
$installOut = cmd /c "`"$condaBat`" install -y -n $envName --override-channels -c conda-forge --file `"$condaReqPath`"" 2>&1
$condaMissDetails.exitCode = $LASTEXITCODE
$installStr = ($installOut | Out-String)
Add-Content -LiteralPath $logPath -Value 'conda install output (expected miss):' -Encoding Ascii
Add-Content -LiteralPath $logPath -Value $installStr -Encoding Ascii
$condaMissDetails.notFound = ($installStr -match 'PackagesNotFoundError') -or ($installStr -match 'Nothing provides') -or ($installStr -match 'not available from')
$condaMissPass = ($condaMissDetails.exitCode -ne 0) -and [bool]$condaMissDetails.notFound

# 2) pip gap-fill -- mirrors run_setup.bat's `python -m pip install -r requirements.txt`; should SUCCEED via PyPI
$pipOut = cmd /c "`"$condaBat`" run -n $envName python -m pip install -r `"$reqPath`"" 2>&1
$pipFillDetails.exitCode = $LASTEXITCODE
Add-Content -LiteralPath $logPath -Value 'pip gap-fill output:' -Encoding Ascii
Add-Content -LiteralPath $logPath -Value ($pipOut | Out-String) -Encoding Ascii
$pipFillPass = ($pipFillDetails.exitCode -eq 0)

# 3) import cv2 now works -- pip supplied what conda could not
$importOut = cmd /c "`"$condaBat`" run -n $envName python `"$appPath`"" 2>&1
$importDetails.exitCode = $LASTEXITCODE
$importStr = ($importOut | Out-String)
Add-Content -LiteralPath $logPath -Value 'runtime output:' -Encoding Ascii
Add-Content -LiteralPath $logPath -Value $importStr -Encoding Ascii
$importDetails.cv2Marker = ($importStr -match 'PIPGAP_CV2_OK')
$listOut = cmd /c "`"$condaBat`" list -n $envName" 2>&1
$importDetails.viaPypi = (($listOut | Out-String) -match '(?m)^opencv-python\s.*pypi')
$importPass = ($importDetails.exitCode -eq 0) -and [bool]$importDetails.cv2Marker

Write-NdjsonRow ([ordered]@{ id = 'pipgap.conda.miss'; req = 'REQ-005'; pass = $condaMissPass; desc = 'conda cannot supply opencv-python (PackagesNotFoundError)'; details = $condaMissDetails })
Write-NdjsonRow ([ordered]@{ id = 'pipgap.pip.fill';   req = 'REQ-005'; pass = $pipFillPass;   desc = 'pip gap-fill installs opencv-python from PyPI'; details = $pipFillDetails })
Write-NdjsonRow ([ordered]@{ id = 'pipgap.import';      req = 'REQ-005'; pass = $importPass;    desc = 'import cv2 succeeds after pip gap-fill'; details = $importDetails })
