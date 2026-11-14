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
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform
    Write-NdjsonRow ([ordered]@{
        id      = 'self.depcheck.channels'
        req     = 'REQ-006.1'
        pass    = $true
        desc    = 'Every package of the conda environment the bootstrapper made came from conda-forge (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = [string][System.Environment]::OSVersion.Platform; reason = 'non-windows-host' }
    })
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

# --- REQ-006.1: every package the bootstrapper put into the conda environment came from conda-forge ---
# Only the conda provider has channels (the real lane runs uv, which has none), so the row is a skip
# unless this lane forces conda. `conda list --json` names the channel of every installed package;
# pip-installed packages say pypi. A package from the Anaconda defaults channels (channel defaults,
# a pkgs/ channel, a repo.anaconda.com base url) fails the row. Other channel names are not failures
# here but are listed in the details, and the row needs at least one conda-forge package (python
# itself), so an empty or unreadable list can never pass.
$chanPass = $true
if ($env:HP_FORCE_CONDA_ONLY -ne '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.depcheck.channels'
        req     = 'REQ-006.1'
        pass    = $true
        desc    = 'Every package of the conda environment the bootstrapper made came from conda-forge (skipped: conda is not the provider in this lane)'
        details = [ordered]@{ skip = $true; reason = 'conda-not-the-provider' }
    })
} else {
    $condaBat = Join-Path $env:PUBLIC 'Documents\Miniconda3\condabin\conda.bat'
    $envName = ''
    foreach ($ln in $run1Lines) { if ($ln -match 'Environment name:\s+(\S+)') { $envName = $Matches[1]; break } }
    $listExit = -1
    $parseError = ''
    $pkgCount = 0
    $forgeCount = 0
    $offenders = @()
    $otherChannels = @()
    if ((Test-Path -LiteralPath $condaBat) -and $envName) {
        $listText = (cmd /c "`"$condaBat`" list -n $envName --json 2>nul" | Out-String)
        $listExit = $LASTEXITCODE
        $jsonStart = $listText.IndexOf('[')
        $jsonEnd = $listText.LastIndexOf(']')
        $pkgs = @()
        if ($jsonStart -ge 0 -and $jsonEnd -gt $jsonStart) {
            try { $pkgs = @($listText.Substring($jsonStart, $jsonEnd - $jsonStart + 1) | ConvertFrom-Json) } catch { $parseError = $_.Exception.Message }
        } else {
            $parseError = 'no json array in the output of conda list'
        }
        foreach ($p in $pkgs) {
            $pkgCount++
            $ch = [string]$p.channel
            $bu = [string]$p.base_url
            if ($ch -eq 'conda-forge') { $forgeCount++ }
            elseif ($ch -ne 'pypi') { $otherChannels += ('{0}={1}' -f $p.name, $ch) }
            if (($ch -match '^(defaults|pkgs/)') -or ($bu -match 'repo\.anaconda\.com|/pkgs/(main|r|msys2)')) { $offenders += ('{0}={1}' -f $p.name, $ch) }
        }
    }
    $chanPass = ($listExit -eq 0) -and (-not $parseError) -and ($forgeCount -gt 0) -and ($offenders.Count -eq 0)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.depcheck.channels'
        req     = 'REQ-006.1'
        pass    = $chanPass
        desc    = 'Every package of the conda environment the bootstrapper made came from conda-forge'
        details = [ordered]@{
            envName = $envName; condaFound = (Test-Path -LiteralPath $condaBat); listExit = $listExit; parseError = $parseError
            packages = $pkgCount; condaForge = $forgeCount
            offenders = @($offenders | Select-Object -First 10); otherChannels = @($otherChannels | Select-Object -First 10)
        }
    })
}

if (-not $installPass -or -not $depSkipPass -or -not $chanPass) { exit 1 }
exit 0
