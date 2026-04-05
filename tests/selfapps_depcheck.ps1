# ASCII only
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

# Non-Windows skip: emit pass=true with skip flag and exit 0
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform
    foreach ($id in @('self.depcheck.install','self.depcheck.skip')) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-005'
            pass    = $true
            desc    = if ($id -eq 'self.depcheck.install') {
                          'Dep check: first run installs colorama into depcheck env'
                      } else {
                          'Dep check: second run skips conda install (deps unchanged)'
                      }
            details = [ordered]@{ skip = $true; platform = [string]$platform; reason = 'non-windows-host' }
        })
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($id in @('self.depcheck.install','self.depcheck.skip')) {
        Write-NdjsonRow ([ordered]@{
            id = $id; req = 'REQ-005'; pass = $false
            desc = 'Dep check: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    }
    exit 1
}

$workDir = Join-Path $here '~selftest_depcheck'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

$appPath = Join-Path $workDir 'depcheck_app.py'
# derived requirement: colorama is a lightweight conda-forge package with no system deps,
# safe to install in CI; import ensures pipreqs detects it and adds to requirements.auto.txt.
Set-Content -Path $appPath -Value "import colorama`nprint('depcheck-ok')" -Encoding ASCII

$bootstrapLog = '~depcheck_bootstrap.log'
$rebuildLog   = '~depcheck_rebuild.log'
# derived requirement: exact phrase from HP_DEP_CHECK log in run_setup.bat line:
#   if defined HP_DEP_SKIP call :log "[INFO] Dep-check: all pipreqs packages satisfied in lock; skipping conda install."
$depSkipPhrase = 'Dep-check: all pipreqs packages satisfied in lock; skipping conda install.'

# --- Run 1: fresh bootstrap; conda install must run ---
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $run1Exit = $LASTEXITCODE
} finally {
    Pop-Location
}

$run1LogPath  = Join-Path $workDir $bootstrapLog
$run1Lines    = if (Test-Path $run1LogPath) {
                    Get-Content -LiteralPath $run1LogPath -Encoding ASCII
                } else { @() }
$lockPath     = Join-Path $workDir '~environment.lock.txt'
$lockWritten  = Test-Path $lockPath
# Pass when: exit 0, lock file written (conda install ran), and dep-skip did NOT fire on run 1
$run1DepSkip  = ($run1Lines | Where-Object { $_ -like "*$depSkipPhrase*" }).Count -gt 0
$installPass  = ($run1Exit -eq 0) -and $lockWritten -and (-not $run1DepSkip)

Write-NdjsonRow ([ordered]@{
    id      = 'self.depcheck.install'
    req     = 'REQ-005'
    pass    = $installPass
    desc    = 'Dep check: first run installs colorama into depcheck env'
    details = [ordered]@{
        condaInstalled = $installPass
        exitCode       = $run1Exit
        lockWritten    = $lockWritten
        depSkipOnRun1  = $run1DepSkip
        log            = $bootstrapLog
    }
})

# --- Modify app: keep colorama import, add comment to change source mtime ---
Add-Content -Path $appPath -Value '# touched to trigger rebuild; colorama import unchanged' -Encoding ASCII
[System.IO.File]::SetLastWriteTimeUtc($appPath, [DateTime]::UtcNow)

# --- Run 2: dep-check should skip conda install since colorama is in lock ---
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $rebuildLog 2>&1"
    $run2Exit = $LASTEXITCODE
} finally {
    Pop-Location
}

$run2LogPath  = Join-Path $workDir $rebuildLog
$run2Lines    = if (Test-Path $run2LogPath) {
                    Get-Content -LiteralPath $run2LogPath -Encoding ASCII
                } else { @() }
$depSkipFound = ($run2Lines | Where-Object { $_ -like "*$depSkipPhrase*" }).Count -gt 0
$depSkipPass  = ($run2Exit -eq 0) -and $depSkipFound

Write-NdjsonRow ([ordered]@{
    id      = 'self.depcheck.skip'
    req     = 'REQ-005'
    pass    = $depSkipPass
    desc    = 'Dep check: second run skips conda install (deps unchanged)'
    details = [ordered]@{
        depSkipDetected = $depSkipFound
        phrase          = $depSkipPhrase
        exitCode        = $run2Exit
        log             = $rebuildLog
    }
})

if (-not $installPass -or -not $depSkipPass) { exit 1 }
exit 0
