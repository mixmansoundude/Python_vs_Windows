# ASCII only
# selfapps_pep723_uverr.ps1 - CLAUDE.md Active Backlog Item 73: when the PEP 723 header write-back
# fails, the setup log must say why.
#
# Field symptom: "[WARN] REQ-005.11: PEP 723 header write-back failed (ERROR:uv_rc_1)" with no reason.
# tools/pep723_writeback.py captured uv's stderr and threw it away, so the user (and the next agent
# reading the log) could not tell a resolution failure from a network error.
#
# Real uv cannot be made to fail here after a successful install without also breaking the install,
# and no public package installs but cannot be added to a script header. So the helper has one
# test hook, HP_TEST_PEP723_UV_ERR: when set, the helper skips uv and behaves as if uv had exited 1
# with that text on stderr. Absent, nothing changes (README REQ-019). Everything else is real: a
# real bootstrap, a real install, the emitted helper, the batch wiring that appends the helper's
# stderr to ~setup.log.
#
#   self.pep723.writeback.uverr - the injected two-line reason appears in ~setup.log, the WARN line
#                                 still names ERROR:uv_rc_1, the entry file is byte-identical, and
#                                 the bootstrap itself still ends in state ok (a failed write-back
#                                 never fails the run)
#
# Lane: real only (gating). The real lane is uv-first, which the write-back requires; if it ever
# is not (no .uv_env python), the row FAILS with reason=provider_not_uv, because a run that never
# reached the write-back proved nothing. Off the real lane (a local run) it records skip=true instead.
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

# Non-Windows skip (OSVersion.Platform works under pwsh and Windows PowerShell 5.1; $IsWindows does not).
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{
        id = 'self.pep723.writeback.uverr'; req = 'REQ-005.11'; pass = $true
        desc = 'Write-back failure reason is logged (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = [System.Environment]::OSVersion.Platform.ToString(); reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id = 'self.pep723.writeback.uverr'; req = 'REQ-005.11'; pass = $false
        desc = 'Write-back failure reason is logged: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_pep723_uverr'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# six is small, pure Python, and found by pipreqs, so the install succeeds and the write-back runs.
$appPath = Join-Path $workDir 'app.py'
Set-Content -Path $appPath -Value @'
import six
print("uverr-app", six.__version__)
'@ -Encoding ASCII
$appBefore = [System.IO.File]::ReadAllBytes($appPath)

$hookText = "pvw-injected-uv-reason-line-one`npvw-injected-uv-reason-line-two"
$prevHook = [Environment]::GetEnvironmentVariable('HP_TEST_PEP723_UV_ERR')
$env:HP_TEST_PEP723_UV_ERR = $hookText
$bootstrapLog = '~uverr_bootstrap.log'
$runExit = $null
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prevHook) { Remove-Item Env:HP_TEST_PEP723_UV_ERR -ErrorAction SilentlyContinue } else { $env:HP_TEST_PEP723_UV_ERR = $prevHook }
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupPath = Join-Path $workDir '~setup.log'
$console   = if (Test-Path $logPath)   { Get-Content -LiteralPath $logPath   -Raw -Encoding ASCII } else { '' }
$setupText = if (Test-Path $setupPath) { Get-Content -LiteralPath $setupPath -Raw -Encoding ASCII } else { '' }
$statusPath = Join-Path $workDir '~bootstrap.status.json'
$state = $null
if (Test-Path $statusPath) {
    try { $state = (Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { $state = 'unreadable' }
}

$uvEnvPy  = Join-Path $workDir '.uv_env\Scripts\python.exe'
$isUvMode = Test-Path -LiteralPath $uvEnvPy

$appAfter = [System.IO.File]::ReadAllBytes($appPath)
$appUnchanged = ($appBefore.Length -eq $appAfter.Length) -and (@(Compare-Object $appBefore $appAfter -SyncWindow 0).Count -eq 0)
$warnShown  = $setupText -match [regex]::Escape('[WARN] REQ-005.11: PEP 723 header write-back failed (ERROR:uv_rc_1)')
$reasonOne  = $setupText -match 'pvw-injected-uv-reason-line-one'
$reasonTwo  = $setupText -match 'pvw-injected-uv-reason-line-two'
$stateOk    = ($state -eq 'ok')

$details = [ordered]@{
    uvMode       = $isUvMode
    exit         = $runExit
    state        = $state
    warnShown    = $warnShown
    reasonOne    = $reasonOne
    reasonTwo    = $reasonTwo
    appUnchanged = $appUnchanged
    log          = $bootstrapLog
}
if (-not $isUvMode) {
    $details.reason = 'provider_not_uv'
    if ($env:HP_CI_LANE -eq 'real') {
        # The real lane is uv-first, so a run that is not in uv mode proved nothing: fail, never skip.
        Write-NdjsonRow ([ordered]@{ id = 'self.pep723.writeback.uverr'; req = 'REQ-005.11'; pass = $false; desc = 'Write-back failure reason is logged: the real lane did not resolve to uv, so the write-back never ran'; details = $details })
        exit 0
    }
    $details.skip = $true
    Write-NdjsonRow ([ordered]@{ id = 'self.pep723.writeback.uverr'; req = 'REQ-005.11'; pass = $true; desc = 'Write-back failure reason is logged (v1 scope gate: HP_ENV_MODE did not resolve to uv)'; details = $details })
    exit 0
}
$pass = $warnShown -and $reasonOne -and $reasonTwo -and $appUnchanged -and $stateOk
Write-NdjsonRow ([ordered]@{
    id      = 'self.pep723.writeback.uverr'
    req     = 'REQ-005.11'
    pass    = [bool]$pass
    desc    = 'A failed PEP 723 write-back logs the reason uv gave'
    details = $details
})
exit 0
