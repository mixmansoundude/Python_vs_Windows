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
    Write-NdjsonRow ([ordered]@{ id = 'pyvisa.nivisa.reason';  req = 'REQ-008'; pass = $true; desc = 'NI-VISA diagnostic reason skipped on non-Windows host'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'pyvisa.nivisa.disabled'; req = 'REQ-008'; pass = $true; desc = 'NI-VISA opt-out skipped on non-Windows host';   details = $skipDetails })
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
# derived requirement: branch and outcome require explicit [VISA] terminal signals, not indirect log substrings.
# Old fuzzy matches ('NI-VISA', 'NI-VISA install may be required', etc.) allowed false-green when no action was taken.
$nisaPass        = ($log -match '\[VISA\]')
$nisaOutcomePass = ($log -match '\[VISA\] present') -or ($log -match '\[VISA\] install_success') -or ($log -match '\[VISA\] skipped') -or ($log -match '\[VISA\] install_failed')

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
    desc    = 'NI-VISA branch taken when pyvisa import detected (requires [VISA] terminal signal)'
    details = $nisaDetails
})

Write-NdjsonRow ([ordered]@{
    id      = 'pyvisa.nivisa.outcome'
    req     = 'REQ-008'
    pass    = $nisaOutcomePass
    desc    = 'NI-VISA terminal signal present ([VISA] present / install_success / skipped / install_failed)'
    details = [ordered]@{ exitCode = $exitCode; outcomeFound = $nisaOutcomePass }
})

# REQ-008 diagnostic: the install path must emit a classifiable reason so external (network/installer)
# failures are distinguishable from a regression. When the install is attempted, the installer exit code
# is logged; if the download is blocked, that is logged instead. Either is a legible diagnostic outcome.
$installerRcMatch = [regex]::Match($log, '\[VISA\] installer exit code:\s*(-?\d+)')
$nisaReasonPass = ($installerRcMatch.Success) `
    -or ($log -match [regex]::Escape('[VISA] install_failed (download)')) `
    -or ($log -match [regex]::Escape('[VISA] present')) `
    -or ($log -match '\[VISA\] skipped')
$nisaReasonDetails = [ordered]@{ exitCode = $exitCode; reasonFound = $nisaReasonPass }
if ($installerRcMatch.Success) { $nisaReasonDetails.installerRc = $installerRcMatch.Groups[1].Value }
Write-NdjsonRow ([ordered]@{
    id      = 'pyvisa.nivisa.reason'
    req     = 'REQ-008'
    pass    = $nisaReasonPass
    desc    = 'NI-VISA install path emits a classifiable diagnostic (installer exit code or download/skip reason)'
    details = $nisaReasonDetails
})

# ===== REQ-008 opt-out: HP_SKIP_NIVISA=1 skips NI-VISA install even when pyvisa is detected =====
$disWork    = Join-Path -Path $here -ChildPath '~pyvisa_disabled'
$disLogName = '~pyvisa_disabled_bootstrap.log'
$disLogPath = Join-Path -Path $disWork -ChildPath $disLogName
if (Test-Path -LiteralPath $disWork) { Remove-Item -LiteralPath $disWork -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $disWork | Out-Null
Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $disWork -Force
Set-Content -LiteralPath (Join-Path -Path $disWork -ChildPath 'main.py')         -Value 'import pyvisa' -Encoding Ascii -NoNewline
Set-Content -LiteralPath (Join-Path -Path $disWork -ChildPath 'requirements.txt') -Value 'pyvisa'      -Encoding Ascii -NoNewline

$disExit = $null
$disLog  = ''
$savedSkipNivisa = $env:HP_SKIP_NIVISA
$env:HP_SKIP_NIVISA = '1'
try {
    if (Test-Path -LiteralPath $disLogPath) { Remove-Item -LiteralPath $disLogPath -Force }
    Push-Location -LiteralPath $disWork
    try {
        cmd /c .\run_setup.bat *> $disLogName
        $disExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    if (Test-Path -LiteralPath $disLogPath) { $disLog = Get-Content -LiteralPath $disLogPath -Raw -Encoding Ascii }
} finally {
    $env:HP_SKIP_NIVISA = $savedSkipNivisa
}

# pyvisa must still be detected (so the skip is meaningful), the opt-out skip must fire, and
# no install terminal signal (present/install_success/install_failed) may appear -- the gate
# returns before the registry probe and download.
$disDetected  = ($disLog -match 'Detected pyvisa')
$disSkipped   = ($disLog -match [regex]::Escape('[VISA] skipped (disabled)'))
$disNoInstall = -not (($disLog -match [regex]::Escape('[VISA] present')) -or ($disLog -match [regex]::Escape('[VISA] install_success')) -or ($disLog -match [regex]::Escape('[VISA] install_failed')))
$disabledPass = ($disDetected -and $disSkipped -and $disNoInstall)
Write-NdjsonRow ([ordered]@{
    id      = 'pyvisa.nivisa.disabled'
    req     = 'REQ-008'
    pass    = $disabledPass
    desc    = 'HP_SKIP_NIVISA=1 skips NI-VISA install even when pyvisa import detected'
    details = [ordered]@{ exitCode = $disExit; detected = $disDetected; skippedDisabled = $disSkipped; noInstallAttempt = $disNoInstall }
})

if (-not $nisaPass) {
    Write-Host "[VISA] terminal signal not present in log"
    exit 1
}
if (-not $nisaOutcomePass) {
    Write-Host "NI-VISA branch outcome not detected"
    exit 1
}
if (-not $disabledPass) {
    Write-Host "HP_SKIP_NIVISA opt-out did not skip the NI-VISA install"
    exit 1
}
exit 0
