# REQ-008: Optional pyvisa dependency triggers NI-VISA runtime handling
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
    Write-NdjsonRow ([ordered]@{ id = 'pyvisa.detect';         req = 'REQ-008'; pass = $true; desc = 'pyvisa detection skipped on non-Windows host';  details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pyvisa.nivisa.branch';  req = 'REQ-008'; pass = $true; desc = 'NI-VISA branch skipped on non-Windows host';    details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pyvisa.nivisa.outcome'; req = 'REQ-008'; pass = $true; desc = 'NI-VISA outcome skipped on non-Windows host';   details = $skipDetails })
    exit 0
}

$work    = Join-Path -Path $here -ChildPath '~pyvisa'
$logName = '~pyvisa_bootstrap.log'
$logPath = Join-Path -Path $work -ChildPath $logName

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $work -Force

# derived requirement: VISA detection scans .py files; requirements.txt alone is not enough.
Set-Content -LiteralPath (Join-Path -Path $work -ChildPath 'main.py')        -Value 'import pyvisa' -Encoding Ascii -NoNewline
Set-Content -LiteralPath (Join-Path -Path $work -ChildPath 'requirements.txt') -Value 'pyvisa'      -Encoding Ascii -NoNewline

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

$detectPass      = ($log -match 'Detected pyvisa')
$nisaPass        = ($log -match 'NI-VISA')
$nisaOutcomePass = ($log -match 'NI-VISA install may be required') -or ($log -match 'NI-VISA already installed') -or ($log -match 'Installing NI-VISA') -or ($log -match 'Skipping NI-VISA')

$detectDetails = [ordered]@{ exitCode = $exitCode; detectFound = $detectPass }
if (-not $log)      { $detectDetails.logMissing = $true }
if ($errorMessage)  { $detectDetails.error = $errorMessage }

$nisaDetails = [ordered]@{ exitCode = $exitCode; nisaFound = $nisaPass }
if (-not $log)      { $nisaDetails.logMissing = $true }
if ($errorMessage)  { $nisaDetails.error = $errorMessage }

Write-NdjsonRow ([ordered]@{
    id      = 'pyvisa.detect'
    req     = 'REQ-008'
    pass    = $detectPass
    desc    = 'pyvisa import detected and logged by bootstrapper'
    details = $detectDetails
})

Write-NdjsonRow ([ordered]@{
    id      = 'pyvisa.nivisa.branch'
    req     = 'REQ-008'
    pass    = $nisaPass
    desc    = 'NI-VISA branch taken when pyvisa import detected'
    details = $nisaDetails
})

Write-NdjsonRow ([ordered]@{
    id      = 'pyvisa.nivisa.outcome'
    req     = 'REQ-008'
    pass    = $nisaOutcomePass
    desc    = 'NI-VISA branch outcome logged (install required / already installed / installing / skipping)'
    details = [ordered]@{ exitCode = $exitCode; outcomeFound = $nisaOutcomePass }
})

exit 0
