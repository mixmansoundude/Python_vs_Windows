# ASCII only
# selfapps_justme.ps1 - Verify that the JustMe Miniconda install path executed.
# Lane: justme-test only. Asserts that ~setup.log contains the JustMe install message.
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

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'conda.install.justme'
        req     = 'REQ-003'
        pass    = $true
        desc    = 'Miniconda JustMe install path executed successfully'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

# Read the envsmoke ~setup.log which is written by the bootstrap that ran with HP_TEST_JUSTME_FALLBACK=1.
# The justme-test lane runs selfapps_envsmoke.ps1 first (which executes run_setup.bat),
# so the setup log is at tests/~envsmoke/~setup.log.
$setupLogPath = Join-Path $here '~envsmoke\~setup.log'
$setupText = ''
if (Test-Path -LiteralPath $setupLogPath) {
    $setupText = Get-Content -LiteralPath $setupLogPath -Raw -Encoding Ascii
}

# Also check the main bootstrap log written at repo root
$mainSetupPath = Join-Path $repo '~setup.log'
$mainSetupText = ''
if (Test-Path -LiteralPath $mainSetupPath) {
    $mainSetupText = Get-Content -LiteralPath $mainSetupPath -Raw -Encoding Ascii
}

$combinedText = $setupText + $mainSetupText

# derived requirement: the JustMe path log line must appear to confirm the fallback ran.
# HP_TEST_JUSTME_FALLBACK=1 causes run_setup.bat to goto :tci_justme,
# which logs "[INFO] Miniconda installed (JustMe fallback)."
# The force-bypass log is "[INFO] HP_TEST_JUSTME_FALLBACK: skipping AllUsers, forcing JustMe path."
$justmeInstalled = $combinedText -match 'Miniconda installed \(JustMe fallback\)'
$justmeForced    = $combinedText -match 'HP_TEST_JUSTME_FALLBACK'

$pass = $justmeInstalled -and $justmeForced

Write-NdjsonRow ([ordered]@{
    id      = 'conda.install.justme'
    req     = 'REQ-003'
    pass    = $pass
    desc    = 'Miniconda JustMe install path executed successfully'
    details = [ordered]@{
        justmeInstalled = $justmeInstalled
        justmeForced    = $justmeForced
        setupLog        = $setupLogPath
    }
})

if (-not $pass) { exit 1 }
exit 0
