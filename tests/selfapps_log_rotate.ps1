# ASCII only
# selfapps_log_rotate.ps1 - the rolling setup log (docs/plan-test-suite-gaps.md gap T7, replaces the static row log.rotate).
#
# README "Maintenance, Logging": a single rolling log ~setup.log capped near 10 MB, trimmed at start. The old
# harness row `log.rotate` only looked for the text `Length -gt 10485760` anywhere in run_setup.bat, which stays
# green when the rotation is removed from the call path, moves the wrong file or is never called. This script
# seeds real logs of the two sizes and lets the real bootstrapper start.
#
# Scenario O  over the limit: ~setup.log holds more than 10 MB (and an older ~setup.prev.log exists)
#   - after the start the old log must be in ~setup.prev.log (it carries the seed marker, the older prev marker
#     is gone, replaced) and the new ~setup.log is small and does not carry the seed marker
# Scenario U  under the limit: ~setup.log holds 1 MB
#   - the log must be kept and appended to (the marker is still in ~setup.log, this run's lines follow it) and no
#     ~setup.prev.log may appear (a rotation on every start would throw the history away)
#
# The run is the short system-Python path (HP_CI_SKIP_ENV=1, same as selfapps_isolation.ps1): rotation happens
# before the environment is chosen, so a full provider run would only add minutes. The variable is set for the
# child only and restored afterwards.
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text,
# not PowerShell).
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately").
# Emits: self.log.rotate.over, self.log.rotate.under
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

$allIds = @('self.log.rotate.over', 'self.log.rotate.under')
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; pass = $true; desc = 'Log rotation (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; pass = $false; desc = 'Log rotation: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    exit 1
}

$limitBytes = 10485760
$overBytes = 11534336          # 11 MiB, comfortably over the limit
$underBytes = 1048576          # 1 MiB, comfortably under it
$newLogMaxBytes = 100          # the fresh log of one short run; planted too small on purpose in the red commit

function New-SeedLog {
    param([string]$Path, [string]$Marker, [long]$Bytes)
    # Marker first, then ASCII padding in 1 KiB lines up to the requested size.
    $line = ('x' * 1022) + "`r`n"
    $fs = [System.IO.File]::Create($Path)
    try {
        $head = [System.Text.Encoding]::ASCII.GetBytes($Marker + "`r`n")
        $fs.Write($head, 0, $head.Length)
        $body = [System.Text.Encoding]::ASCII.GetBytes($line)
        while ($fs.Length + $body.Length -le $Bytes) { $fs.Write($body, 0, $body.Length) }
        $pad = [System.Text.Encoding]::ASCII.GetBytes('y' * [int]($Bytes - $fs.Length))
        if ($pad.Length -gt 0) { $fs.Write($pad, 0, $pad.Length) }
    } finally { $fs.Dispose() }
}

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
}

function Invoke-LogBootstrap {
    param([string]$Dir)
    Copy-Item -LiteralPath $batchPath -Destination $Dir -Force
    Set-Content -LiteralPath (Join-Path $Dir 'rotate_app.py') -Value 'print("rotate-ok")' -Encoding ASCII
    $had = [Environment]::GetEnvironmentVariable('HP_CI_SKIP_ENV')
    [Environment]::SetEnvironmentVariable('HP_CI_SKIP_ENV', '1')
    Push-Location -LiteralPath $Dir
    try {
        & cmd.exe /c '.\run_setup.bat rotate_app.py > ~rotate_boot.log 2>&1 < nul'
        return $LASTEXITCODE
    } finally {
        Pop-Location
        [Environment]::SetEnvironmentVariable('HP_CI_SKIP_ENV', $had)
    }
}

$passO = $false
$passU = $false
try {
    # ------------------------------------------------------------ Scenario O: over the limit
    $dirO = Join-Path $here '~selftest_logrotate_over'
    if (Test-Path -LiteralPath $dirO) { Remove-Item -LiteralPath $dirO -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dirO | Out-Null
    New-SeedLog -Path (Join-Path $dirO '~setup.log') -Marker 'SEED-LOG-OVER-LIMIT' -Bytes $overBytes
    Set-Content -LiteralPath (Join-Path $dirO '~setup.prev.log') -Value 'OLD-PREV-MARKER' -Encoding ASCII
    $seedSize = (Get-Item -LiteralPath (Join-Path $dirO '~setup.log')).Length
    $exitO = Invoke-LogBootstrap -Dir $dirO
    $logO = Join-Path $dirO '~setup.log'
    $prevO = Join-Path $dirO '~setup.prev.log'
    $newSizeO = if (Test-Path -LiteralPath $logO) { (Get-Item -LiteralPath $logO).Length } else { -1 }
    $prevSizeO = if (Test-Path -LiteralPath $prevO) { (Get-Item -LiteralPath $prevO).Length } else { -1 }
    $prevHead = if ($prevSizeO -gt 0) { (Get-Content -LiteralPath $prevO -TotalCount 1 -Encoding ASCII) } else { '' }
    $newHasSeed = (Read-Text $logO) -match 'SEED-LOG-OVER-LIMIT'
    $prevHasOld = ($prevSizeO -gt 0 -and $prevSizeO -lt 4096) -and ((Read-Text $prevO) -match 'OLD-PREV-MARKER')
    $passO = ($seedSize -gt $limitBytes) -and ($prevSizeO -ge $seedSize) -and ($prevHead -eq 'SEED-LOG-OVER-LIMIT') -and (-not $prevHasOld) -and ($newSizeO -gt 0) -and ($newSizeO -lt $newLogMaxBytes) -and (-not $newHasSeed)
    Write-NdjsonRow ([ordered]@{
        id = 'self.log.rotate.over'; req = 'REQ-028.1'; pass = [bool]$passO
        desc = 'README logging: a ~setup.log over 10 MB at start is moved to ~setup.prev.log (replacing an older one) and a small fresh ~setup.log starts'
        details = [ordered]@{
            seedBytes = $seedSize; limitBytes = $limitBytes; exitCode = $exitO
            prevBytes = $prevSizeO; prevFirstLine = $prevHead; olderPrevReplaced = [bool](-not $prevHasOld)
            newLogBytes = $newSizeO; newLogMaxBytes = $newLogMaxBytes; newLogHasSeedMarker = [bool]$newHasSeed
        }
    })
} catch {
    Write-NdjsonRow ([ordered]@{ id = 'self.log.rotate.over'; pass = $false; desc = 'Log rotation (over limit) threw an exception'; details = [ordered]@{ error = $_.Exception.Message } })
}

try {
    # ------------------------------------------------------------ Scenario U: under the limit
    $dirU = Join-Path $here '~selftest_logrotate_under'
    if (Test-Path -LiteralPath $dirU) { Remove-Item -LiteralPath $dirU -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dirU | Out-Null
    New-SeedLog -Path (Join-Path $dirU '~setup.log') -Marker 'SEED-LOG-UNDER-LIMIT' -Bytes $underBytes
    $seedSizeU = (Get-Item -LiteralPath (Join-Path $dirU '~setup.log')).Length
    $exitU = Invoke-LogBootstrap -Dir $dirU
    $logU = Join-Path $dirU '~setup.log'
    $prevU = Join-Path $dirU '~setup.prev.log'
    $sizeU = if (Test-Path -LiteralPath $logU) { (Get-Item -LiteralPath $logU).Length } else { -1 }
    $firstU = if ($sizeU -gt 0) { (Get-Content -LiteralPath $logU -TotalCount 1 -Encoding ASCII) } else { '' }
    $prevExistsU = Test-Path -LiteralPath $prevU
    $passU = ($seedSizeU -lt $limitBytes) -and ($firstU -eq 'SEED-LOG-UNDER-LIMIT') -and ($sizeU -gt $seedSizeU) -and (-not $prevExistsU)
    Write-NdjsonRow ([ordered]@{
        id = 'self.log.rotate.under'; req = 'REQ-028.2'; pass = [bool]$passU
        desc = 'README logging: a ~setup.log under 10 MB is kept and appended to, and no ~setup.prev.log is created'
        details = [ordered]@{
            seedBytes = $seedSizeU; limitBytes = $limitBytes; exitCode = $exitU
            logBytes = $sizeU; firstLine = $firstU; prevCreated = [bool]$prevExistsU
        }
    })
} catch {
    Write-NdjsonRow ([ordered]@{ id = 'self.log.rotate.under'; pass = $false; desc = 'Log rotation (under limit) threw an exception'; details = [ordered]@{ error = $_.Exception.Message } })
}

# The seeded logs are 11 MB and 1 MB; neither is evidence a reader needs (the row holds the sizes and first lines),
# so remove them rather than leave them for the job's later steps to walk.
foreach ($big in @((Join-Path $here '~selftest_logrotate_over\~setup.prev.log'), (Join-Path $here '~selftest_logrotate_under\~setup.log'))) {
    if (Test-Path -LiteralPath $big) { Remove-Item -LiteralPath $big -Force -ErrorAction SilentlyContinue }
}

if (-not ($passO -and $passU)) { exit 1 }
exit 0
