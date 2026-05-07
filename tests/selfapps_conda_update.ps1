# ASCII only
# selfapps_conda_update.ps1 - Verify conda base periodic update ran and succeeded.
# Lane: conda-full only (HP_TEST_CONDA_UPDATE=1).
# Reads ~setup.log and checks ~conda.lastupdate file is written.
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
        id      = 'self.conda.base.update'
        req     = 'REQ-003'
        pass    = $true
        desc    = 'Conda base periodic update (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$setupLogPath = Join-Path $repo '~setup.log'
$logText = ''
if (Test-Path -LiteralPath $setupLogPath) {
    $logText = Get-Content -LiteralPath $setupLogPath -Raw -Encoding Ascii -ErrorAction SilentlyContinue
}
if (-not $logText) { $logText = '' }

$updateRan        = $logText -match 'Conda base update: running'
$updateComplete   = $logText -match 'Conda base update complete\.'
$minicondaRoot    = if ($env:PUBLIC) { Join-Path $env:PUBLIC 'Documents\Miniconda3' } else { '' }
$lastupdatePath   = if ($minicondaRoot) { Join-Path $minicondaRoot '~conda.lastupdate' } else { Join-Path $repo '~conda.lastupdate' }
$lastupdateWritten = Test-Path -LiteralPath $lastupdatePath

$pass = $updateRan -and $updateComplete -and $lastupdateWritten

Write-NdjsonRow ([ordered]@{
    id      = 'self.conda.base.update'
    req     = 'REQ-003'
    pass    = $pass
    desc    = 'Conda base periodic update ran and completed successfully'
    details = [ordered]@{
        updateRan         = $updateRan
        updateComplete    = $updateComplete
        lastupdateWritten = $lastupdateWritten
        setupLog          = $setupLogPath
    }
})

if (-not $pass) { exit 1 }
exit 0
