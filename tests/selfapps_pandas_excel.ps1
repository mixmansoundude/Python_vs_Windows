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

function Get-CondaPythonPath {
    param([string]$CondaBat)

    if (-not $CondaBat) { return '' }
    $scriptsDir = Split-Path -Path $CondaBat -Parent
    $leaf = Split-Path -Path $scriptsDir -Leaf
    if ($leaf -ieq 'condabin') {
        return Join-Path (Split-Path -Path $scriptsDir -Parent) 'python.exe'
    }
    if ($leaf -ieq 'Scripts') {
        return Join-Path (Split-Path -Path $scriptsDir -Parent) 'python.exe'
    }
    return ''
}

function Export-PrepRequirementsHelper {
    param(
        [string]$BatchPath,
        [string]$OutPath
    )

    if (-not (Test-Path -LiteralPath $BatchPath)) {
        throw "run_setup.bat not found: $BatchPath"
    }

    $payload = $null
    foreach ($line in Get-Content -LiteralPath $BatchPath -Encoding Ascii) {
        if ($line -match '^set "HP_PREP_REQUIREMENTS=([^\"]+)"$') {
            $payload = $Matches[1]
            break
        }
    }
    if (-not $payload) {
        throw 'HP_PREP_REQUIREMENTS payload not found in run_setup.bat'
    }

    $bytes = [Convert]::FromBase64String($payload)
    [IO.File]::WriteAllBytes($OutPath, $bytes)
}

if (-not $IsWindows) {
    $skipDetails = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    Write-NdjsonRow ([ordered]@{ id = 'pandas_excel.translate';      req = 'REQ-005'; pass = $true; desc = 'translation skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pandas_excel.conda.install';  req = 'REQ-005'; pass = $true; desc = 'conda install skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pandas_excel.runtime';        req = 'REQ-005'; pass = $true; desc = 'runtime execution skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.pandas.openpyxl.install'; req = 'REQ-005'; pass = $true; desc = 'env list check skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.pandas.openpyxl.import';  req = 'REQ-005'; pass = $true; desc = 'import check skipped on non-Windows host'; details = $skipDetails })
    exit 0
}

$work = Join-Path $here '~pandas_excel'
$logPath = Join-Path $work '~pandas_excel.log'
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }

$appPath = Join-Path $work 'app.py'
$reqPath = Join-Path $work 'requirements.txt'
$prepPath = Join-Path $work '~prep_requirements.py'
$condaReqPath = Join-Path $work '~reqs_conda.txt'
$outPath = Join-Path $work 'out.xlsx'

Set-Content -LiteralPath $appPath -Encoding Ascii -Value @'
import pandas as pd

df = pd.DataFrame({"a": [1, 2]})
df.to_excel("out.xlsx")
'@

Set-Content -LiteralPath $reqPath -Encoding Ascii -Value @(
    'pandas',
    'openpyxl'
)

$translationDetails = [ordered]@{ pandasFound = $false; openpyxlFound = $false; file = $condaReqPath }
$installDetails = [ordered]@{ exitCode = -1; environment = '_envsmoke'; file = $condaReqPath }
$runtimeDetails = [ordered]@{ exitCode = -1; outExists = $false; outPath = $outPath }

$condaInfo = Get-CondaBatPath
$condaBat = $condaInfo.path
$condaPython = Get-CondaPythonPath -CondaBat $condaBat
if (-not $condaBat) {
    $translationDetails.reason = 'conda-not-found'
    $translationDetails.condaBatCandidates = $condaInfo.candidates
    $translationDetails.publicRoot = $condaInfo.publicRoot
    $installDetails.reason = 'conda-not-found'
    $installDetails.condaBatCandidates = $condaInfo.candidates
    $installDetails.publicRoot = $condaInfo.publicRoot
    $runtimeDetails.reason = 'conda-not-found'
    $runtimeDetails.condaBatCandidates = $condaInfo.candidates
    $runtimeDetails.publicRoot = $condaInfo.publicRoot
    Write-NdjsonRow ([ordered]@{ id = 'pandas_excel.translate';     req = 'REQ-005'; pass = $false; desc = 'prep_requirements translates pandas and openpyxl'; details = $translationDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pandas_excel.conda.install'; req = 'REQ-005'; pass = $false; desc = 'conda installs translated pandas/openpyxl requirements'; details = $installDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pandas_excel.runtime';       req = 'REQ-005'; pass = $false; desc = 'runtime writes out.xlsx using pandas+openpyxl'; details = $runtimeDetails })
    exit 0
}

$translatePass = $false
if (-not $condaPython -or -not (Test-Path -LiteralPath $condaPython)) {
    $translationDetails.error = "conda python missing: $condaPython"
    Add-Content -LiteralPath $logPath -Value ("conda python missing: {0}" -f $condaPython) -Encoding Ascii
} else {
try {
    Export-PrepRequirementsHelper -BatchPath (Join-Path $repo 'run_setup.bat') -OutPath $prepPath
    Push-Location -LiteralPath $work
    try {
        $prepOutput = & $condaPython $prepPath $reqPath 2>&1
        $prepExit = $LASTEXITCODE
        if ($prepOutput) { Add-Content -LiteralPath $logPath -Value ($prepOutput | Out-String) -Encoding Ascii }
        Add-Content -LiteralPath $logPath -Value ("prep exit code: {0}" -f $prepExit) -Encoding Ascii
    } finally {
        Pop-Location
    }

    if (Test-Path -LiteralPath $condaReqPath) {
        $condaText = Get-Content -LiteralPath $condaReqPath -Raw -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value 'translated requirements:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value $condaText -Encoding Ascii
        $translationDetails.pandasFound = $condaText.Contains('pandas')
        $translationDetails.openpyxlFound = $condaText.Contains('openpyxl')
        $translatePass = [bool]$translationDetails.pandasFound -and [bool]$translationDetails.openpyxlFound
    } else {
        Add-Content -LiteralPath $logPath -Value ("missing translated requirements file: {0}" -f $condaReqPath) -Encoding Ascii
    }
} catch {
    $translationDetails.error = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("translation exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}
}

$condaConfigCommands = @(
    "`"$condaBat`" config --env --add channels conda-forge",
    "`"$condaBat`" config --env --remove channels defaults"
)
foreach ($configCommand in $condaConfigCommands) {
    try {
        $configOutput = cmd /c $configCommand 2>&1
        $configExit = $LASTEXITCODE
        Add-Content -LiteralPath $logPath -Value ("conda config command: {0}" -f $configCommand) -Encoding Ascii
        if ($configOutput) {
            Add-Content -LiteralPath $logPath -Value ($configOutput | Out-String) -Encoding Ascii
        }
        if (($configCommand -match 'remove channels defaults') -and ($configExit -ne 0)) {
            Add-Content -LiteralPath $logPath -Value 'conda defaults channel was already absent' -Encoding Ascii
        }
    } catch {
        Add-Content -LiteralPath $logPath -Value ("conda config exception: {0}" -f $_.Exception.Message) -Encoding Ascii
    }
}

$installCommand = "`"$condaBat`" install -y -n _envsmoke --override-channels -c conda-forge --file `"$condaReqPath`""
try {
    $installOutput = cmd /c $installCommand 2>&1
    $installExit = $LASTEXITCODE
    $installDetails.exitCode = $installExit
    if ($installOutput) {
        Add-Content -LiteralPath $logPath -Value 'conda install output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value ($installOutput | Out-String) -Encoding Ascii
    }
} catch {
    $installDetails.exitCode = -1
    $installDetails.error = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("conda install exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}
$installPass = ($installDetails.exitCode -eq 0)

if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath -Force -ErrorAction SilentlyContinue }
$runtimeCommand = "`"$condaBat`" run -n _envsmoke --cwd `"$work`" python `"$appPath`""
try {
    $runtimeOutput = cmd /c $runtimeCommand 2>&1
    $runtimeExit = $LASTEXITCODE
    $runtimeDetails.exitCode = $runtimeExit
    if ($runtimeOutput) {
        Add-Content -LiteralPath $logPath -Value 'runtime output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value ($runtimeOutput | Out-String) -Encoding Ascii
    }
} catch {
    $runtimeDetails.exitCode = -1
    $runtimeDetails.error = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("runtime exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}
$runtimeDetails.outExists = (Test-Path -LiteralPath $outPath)
$runtimePass = ($runtimeDetails.exitCode -eq 0) -and [bool]$runtimeDetails.outExists

Write-NdjsonRow ([ordered]@{ id = 'pandas_excel.translate';     req = 'REQ-005'; pass = $translatePass; desc = 'prep_requirements translates pandas and openpyxl'; details = $translationDetails })
Write-NdjsonRow ([ordered]@{ id = 'pandas_excel.conda.install'; req = 'REQ-005'; pass = $installPass;   desc = 'conda installs translated pandas/openpyxl requirements'; details = $installDetails })
Write-NdjsonRow ([ordered]@{ id = 'pandas_excel.runtime';       req = 'REQ-005'; pass = $runtimePass;   desc = 'runtime writes out.xlsx using pandas+openpyxl'; details = $runtimeDetails })

# Verify both packages are present in the conda env after install
$envListDetails = [ordered]@{ pandasPresent = $false; openpyxlPresent = $false }
$importDetails  = [ordered]@{ exitCode = -1 }
if ($installPass -and $condaBat) {
    $listOut = cmd /c "`"$condaBat`" list -n _envsmoke 2>&1"
    $listStr = ($listOut | Out-String)
    $envListDetails.pandasPresent  = ($listStr -match '(?m)^pandas\b')
    $envListDetails.openpyxlPresent = ($listStr -match '(?m)^openpyxl\b')

    $importOut = cmd /c "`"$condaBat`" run -n _envsmoke python -c `"import pandas; import openpyxl`" 2>&1"
    $importDetails.exitCode = $LASTEXITCODE
}
$envListPass  = [bool]$envListDetails.pandasPresent -and [bool]$envListDetails.openpyxlPresent
$importPass   = ($importDetails.exitCode -eq 0)

Write-NdjsonRow ([ordered]@{ id = 'self.pandas.openpyxl.install'; req = 'REQ-005'; pass = $envListPass; desc = 'pandas and openpyxl both present in conda env after install'; details = $envListDetails })
Write-NdjsonRow ([ordered]@{ id = 'self.pandas.openpyxl.import';  req = 'REQ-005'; pass = $importPass;  desc = 'import pandas; import openpyxl succeeds in conda env'; details = $importDetails })
