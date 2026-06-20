# ASCII only
# selfapps_dl_fallback.ps1 - Verify Miniconda and uv fallback download URLs were tried.
# Lane: justme-test only (HP_TEST_CONDA_DL_FALLBACK=1, HP_TEST_UV_DL_FALLBACK=1).
# Reads ~setup.log and asserts fallback log messages are present.
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
    foreach ($id in @('self.dl.conda.fallback', 'self.dl.uv.fallback')) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-003'
            pass    = $true
            desc    = 'Download fallback URL test (skipped on non-Windows)'
            details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
        })
    }
    exit 0
}

# Read envsmoke ~setup.log: the main bootstrap finds no .py files at repo root
# and exits early; the actual Miniconda/uv download happens inside the envsmoke
# sub-bootstrap which runs from tests/~envsmoke/ (same pattern as selfapps_justme.ps1).
$setupLogPath = Join-Path $here '~envsmoke\~setup.log'
$logText = ''
if (Test-Path -LiteralPath $setupLogPath) {
    $logText = Get-Content -LiteralPath $setupLogPath -Raw -Encoding Ascii -ErrorAction SilentlyContinue
}
if (-not $logText) { $logText = '' }

# Check Miniconda fallback
$condaFallbackTried     = $logText -match 'Trying fallback Miniconda URL:'
$condaFallbackSucceeded = $logText -match 'Miniconda download succeeded from fallback URL\.'
$condaPass = $condaFallbackTried -and $condaFallbackSucceeded

Write-NdjsonRow ([ordered]@{
    id      = 'self.dl.conda.fallback'
    req     = 'REQ-003'
    pass    = $condaPass
    desc    = 'Miniconda fallback URL tried and succeeded when primary fails'
    details = [ordered]@{
        fallbackTried     = $condaFallbackTried
        fallbackSucceeded = $condaFallbackSucceeded
        setupLog          = $setupLogPath
    }
})

# Check uv fallback: verify fallback was attempted AND uv binary was ultimately acquired.
# derived requirement: when HP_TEST_FORCE_UV_FAIL=1, uv acquisition is bypassed before any
# download attempt so the DL fallback path is never reached. Skip with explicit reason.
# The uv DL fallback path needs a dedicated lane to be fully exercised (see Active Backlog).
$uvForcedFail    = $logText -match 'HP_TEST_FORCE_UV_FAIL: simulating uv acquisition failure'
$uvFallbackTried = $logText -match 'Trying fallback uv URL:'
$uvAcquired      = $logText -match 'uv: acquired at ~uv_bin\\uv\.exe'
if ($uvForcedFail) {
    $uvPass = $true
    Write-NdjsonRow ([ordered]@{
        id      = 'self.dl.uv.fallback'
        req     = 'REQ-003'
        pass    = $true
        desc    = 'uv fallback URL tried and uv binary acquired after fallback'
        details = [ordered]@{ skip = $true; reason = 'HP_TEST_FORCE_UV_FAIL'; uvForcedFail = $true }
    })
} else {
    $uvPass = $uvFallbackTried -and $uvAcquired
    Write-NdjsonRow ([ordered]@{
        id      = 'self.dl.uv.fallback'
        req     = 'REQ-003'
        pass    = $uvPass
        desc    = 'uv fallback URL tried and uv binary acquired after fallback'
        details = [ordered]@{
            fallbackTried = $uvFallbackTried
            uvAcquired    = $uvAcquired
            setupLog      = $setupLogPath
        }
    })
}

if (-not $condaPass -or -not $uvPass) { exit 1 }
exit 0
