# REQ-004: Python version precedence -- runtime.txt -> pyproject.toml -> fallback
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
    Write-NdjsonRow ([ordered]@{ id = 'pyproject.precedence.detect';    req = 'REQ-004'; pass = $true; desc = 'pyproject precedence detect skipped on non-Windows host';   details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pyproject.precedence.writeback'; req = 'REQ-004'; pass = $true; desc = 'pyproject precedence writeback skipped on non-Windows host'; details = $skipDetails })
    exit 0
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
    $condaBatCandidates += 'C:\Users\Public\Documents\Miniconda3\condabin\conda.bat'
    $condaBat = $condaBatCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $condaBat) {
        $whereResult = where.exe conda 2>$null
        if ($whereResult) { $condaBat = ($whereResult -split "`r?`n")[0].Trim() }
    }
    return [ordered]@{ path = $condaBat; candidates = $condaBatCandidates }
}

function Get-CondaBasePython {
    param([string]$CondaBat)
    if (-not $CondaBat) { return '' }
    $scriptsDir = Split-Path -Path $CondaBat -Parent
    $leaf = Split-Path -Path $scriptsDir -Leaf
    if ($leaf -ieq 'condabin') { return Join-Path (Split-Path -Path $scriptsDir -Parent) 'python.exe' }
    if ($leaf -ieq 'Scripts')  { return Join-Path (Split-Path -Path $scriptsDir -Parent) 'python.exe' }
    return ''
}

function Export-DetectPythonHelper {
    param([string]$BatchPath, [string]$OutPath)
    if (-not (Test-Path -LiteralPath $BatchPath)) { throw "run_setup.bat not found: $BatchPath" }
    $payload = $null
    foreach ($line in Get-Content -LiteralPath $BatchPath -Encoding Ascii) {
        if ($line -match '^set "HP_DETECT_PY=([^\"]+)"$') {
            $payload = $Matches[1]
            break
        }
    }
    if (-not $payload) { throw 'HP_DETECT_PY payload not found in run_setup.bat' }
    $bytes = [Convert]::FromBase64String($payload)
    [IO.File]::WriteAllBytes($OutPath, $bytes)
}

$condaInfo   = Get-CondaBatPath
$condaBat    = $condaInfo.path
$condaPython = Get-CondaBasePython -CondaBat $condaBat

# --- Test 1: pyproject.precedence.detect ---
# derived requirement: validate HP_DETECT_PY reads pyproject.toml when runtime.txt
# is absent, without running the full bootstrapper (which would create a conda env).
$detectDir  = Join-Path $here '~pyproject_detect'
$detectPy   = Join-Path $detectDir '~detect_python.py'
$detectPass = $false
$detectDetails = [ordered]@{}

if (-not $condaPython -or -not (Test-Path -LiteralPath $condaPython)) {
    $detectDetails.reason = "conda python missing: $condaPython"
    $detectDetails.condaBatCandidates = $condaInfo.candidates
} else {
    if (Test-Path -LiteralPath $detectDir) { Remove-Item -LiteralPath $detectDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $detectDir | Out-Null
    # pyproject.toml with requires-python constraint; no runtime.txt present
    Set-Content -LiteralPath (Join-Path $detectDir 'pyproject.toml') -Encoding Ascii -Value '[project]
requires-python = ">=3.10,<3.11"
'
    try {
        Export-DetectPythonHelper -BatchPath (Join-Path $repoRoot 'run_setup.bat') -OutPath $detectPy
        Push-Location -LiteralPath $detectDir
        try {
            $detectOut  = & $condaPython $detectPy 2>&1
            $detectExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $detectOutStr = ($detectOut | Out-String).Trim()
        $detectDetails.output   = $detectOutStr
        $detectDetails.exitCode = $detectExit
        # Assert exact conda spec and successful exit to guard REQ-004 parse precision
        $detectPass = ($detectExit -eq 0) -and ($detectOutStr -eq 'python>=3.10,<3.11')
    } catch {
        $detectDetails.error = $_.Exception.Message
    }
}

Write-NdjsonRow ([ordered]@{
    id      = 'pyproject.precedence.detect'
    req     = 'REQ-004'
    pass    = $detectPass
    desc    = 'HP_DETECT_PY reads pyproject.toml requires-python when runtime.txt absent'
    details = $detectDetails
})

# --- Test 2: pyproject.precedence.writeback ---
# derived requirement: follow selfapps_runtime_writeback pattern -- read ~setup.log
# (not captured stdout) and verify runtime.txt was created by the bootstrapper.
$work       = Join-Path $here '~pyproject_prec'
$logName    = '~pyproject_prec_bootstrap.log'
$logPath    = Join-Path $work -ChildPath $logName
$runtimeTxt = Join-Path $work -ChildPath 'runtime.txt'
$setupLog   = Join-Path $work -ChildPath '~setup.log'

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null
Copy-Item -LiteralPath (Join-Path $repoRoot 'run_setup.bat') -Destination $work -Force

Set-Content -LiteralPath (Join-Path $work 'main.py') -Value 'print("hello")' -Encoding Ascii -NoNewline

# derived requirement: use a loose constraint so conda picks a cached Python
# version and avoids a slow resolver round-trip for Python 3.10 packages.
# The detect test (Test 1) above validates the actual constraint-parse path in
# isolation; this test validates the end-to-end bootstrap path (Tier 2/3 fires,
# runtime.txt is written, and the resolved version satisfies the constraint).
# Known limitation: run_setup.bat does not emit the PYSPEC value to ~setup.log
# so we cannot grep for ">=3.9" in the log; instead we assert the resolved
# version in runtime.txt satisfies the constraint (major.minor >= 3.9).
Set-Content -LiteralPath (Join-Path $work 'pyproject.toml') -Encoding Ascii -Value '[project]
requires-python = ">=3.9"
'
# derived requirement: runtime.txt must not pre-exist so Tier 1 is bypassed.
if (Test-Path -LiteralPath $runtimeTxt) { Remove-Item -LiteralPath $runtimeTxt -Force }

$exitCode         = $null
$runtimeExists    = $false
$logContains      = $false
$versionSatisfied = $false
$runtimeVersion   = ''
$errorMessage     = $null

try {
    Push-Location -LiteralPath $work
    try {
        cmd /c "call run_setup.bat > $logName 2>&1"
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $runtimeExists = Test-Path -LiteralPath $runtimeTxt
    if (Test-Path -LiteralPath $setupLog) {
        $setupLogText = Get-Content -LiteralPath $setupLog -Encoding Ascii -Raw
        $logContains  = $setupLogText -match '\[INFO\] runtime\.txt written:'
    }
    # Assert the resolved version in runtime.txt satisfies requires-python = ">=3.9"
    if ($runtimeExists) {
        $rtText = (Get-Content -LiteralPath $runtimeTxt -Encoding Ascii -Raw).Trim()
        $runtimeVersion = $rtText
        if ($rtText -match '(\d+)\.(\d+)') {
            $major = [int]$Matches[1]; $minor = [int]$Matches[2]
            $versionSatisfied = ($major -gt 3) -or ($major -eq 3 -and $minor -ge 9)
        }
    }
} catch {
    $errorMessage = $_.Exception.Message
}

$writebackPass = ($exitCode -eq 0) -and $runtimeExists -and $logContains -and $versionSatisfied
$writebackDetails = [ordered]@{
    exitCode         = $exitCode
    runtimeExists    = $runtimeExists
    logContains      = $logContains
    versionSatisfied = $versionSatisfied
    runtimeVersion   = $runtimeVersion
}
if ($errorMessage) { $writebackDetails.error = $errorMessage }

Write-NdjsonRow ([ordered]@{
    id      = 'pyproject.precedence.writeback'
    req     = 'REQ-004'
    pass    = $writebackPass
    desc    = 'runtime.txt written after bootstrap when pyproject.toml present and runtime.txt absent'
    details = $writebackDetails
})

exit 0
