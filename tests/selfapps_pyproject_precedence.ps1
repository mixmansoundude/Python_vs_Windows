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
    Write-NdjsonRow ([ordered]@{ id = 'pyproject.precedence.detect';    pass = $true; desc = 'pyproject precedence detect skipped on non-Windows host';   details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pyproject.precedence.writeback'; pass = $true; desc = 'pyproject precedence writeback skipped on non-Windows host'; details = $skipDetails })
    exit 0
}

$work          = Join-Path -Path $here -ChildPath '~pyproject_prec'
$logName       = '~pyproject_prec_bootstrap.log'
$logPath       = Join-Path -Path $work -ChildPath $logName
$runtimeTxt    = Join-Path -Path $work -ChildPath 'runtime.txt'
$pyprojectToml = Join-Path -Path $work -ChildPath 'pyproject.toml'

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $work -Force

# pyproject.toml constrains Python to 3.10.x; runtime.txt must be absent so the
# precedence falls through to pyproject.toml (Tier 2).
Set-Content -LiteralPath $pyprojectToml -Encoding Ascii -Value @'
[project]
requires-python = ">=3.10,<3.11"
'@

Set-Content -LiteralPath (Join-Path -Path $work -ChildPath 'main.py') -Value 'print("hello")' -Encoding Ascii -NoNewline

# derived requirement: runtime.txt must not exist before the run so Tier 1 is
# bypassed and the bootstrapper reads pyproject.toml instead.
if (Test-Path -LiteralPath $runtimeTxt) { Remove-Item -LiteralPath $runtimeTxt -Force }

$exitCode     = $null
$log          = ''
$errorMessage = $null

try {
    if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force }
    Push-Location -LiteralPath $work
    try {
        cmd /c .\run_setup.bat *> $logName
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if (Test-Path -LiteralPath $logPath) {
        $log = Get-Content -LiteralPath $logPath -Raw -Encoding Ascii
    }
} catch {
    $errorMessage = $_.Exception.Message
}

# Detect: bootstrapper should have selected Python 3.10.x (matching the constraint).
# The log line "[INFO] runtime.txt written: python-3.10.x" is the signal.
$detectPass  = ($log -match 'runtime\.txt written:.*3\.10\.')
$runtimeExists = (Test-Path -LiteralPath $runtimeTxt)
$writebackPass = $runtimeExists

$detectDetails = [ordered]@{ exitCode = $exitCode; detectFound = $detectPass }
if (-not $log)     { $detectDetails.logMissing = $true }
if ($errorMessage) { $detectDetails.error = $errorMessage }

$writebackDetails = [ordered]@{ exitCode = $exitCode; runtimeTxtExists = $runtimeExists }
if (-not $log)     { $writebackDetails.logMissing = $true }
if ($errorMessage) { $writebackDetails.error = $errorMessage }
if ($runtimeExists) {
    $rtContent = Get-Content -LiteralPath $runtimeTxt -Raw -Encoding Ascii
    $writebackDetails.runtimeTxtContent = $rtContent.Trim()
}

Write-NdjsonRow ([ordered]@{
    id      = 'pyproject.precedence.detect'
    pass    = $detectPass
    desc    = 'pyproject.toml requires-python used when runtime.txt absent'
    details = $detectDetails
})

Write-NdjsonRow ([ordered]@{
    id      = 'pyproject.precedence.writeback'
    pass    = $writebackPass
    desc    = 'runtime.txt written after bootstrap with pyproject.toml constraint'
    details = $writebackDetails
})

exit 0
