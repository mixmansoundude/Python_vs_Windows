# ASCII only
# selfapps_size.ps1 - REQ-017 bootstrapper size tripwire.
#
# run_setup.bat is fully self-contained (all helper payloads are base64-embedded),
# so the single file IS the entire deliverable. It must stay under 20 MB so it can
# be distributed by email. This is a cheap future tripwire (current size is a tiny
# fraction of the limit); it exists to catch unbounded growth, not to flag today.
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

$limitBytes = 20 * 1024 * 1024
$batch = Join-Path $repo 'run_setup.bat'
$sizeBytes = if (Test-Path -LiteralPath $batch) { (Get-Item -LiteralPath $batch).Length } else { -1 }
$pass = ($sizeBytes -ge 0) -and ($sizeBytes -lt $limitBytes)

Write-NdjsonRow ([ordered]@{
    id='self.size.tripwire'
    req='REQ-017'
    pass=$pass
    desc='run_setup.bat (self-contained deliverable) stays under the 20 MB email-distribution limit'
    details=[ordered]@{
        sizeBytes  = $sizeBytes
        limitBytes = $limitBytes
        sizeKiB    = [math]::Round($sizeBytes / 1024, 1)
    }
})

if (-not $pass) { exit 1 }
exit 0
