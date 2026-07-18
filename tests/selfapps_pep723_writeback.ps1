# ASCII only
# selfapps_pep723_writeback.ps1 - Test REQ-005.11 PEP 723 header write-back (uv add --script).
#
# Scenarios (controlled by PEP723_SCENARIO env var; default: fresh):
#
#   fresh      - No existing header; stub imports requests (pipreqs/heuristic resolves
#                requests+certifi); no requirements.txt/pyproject.toml pre-seeded.
#                Emits: self.pep723.writeback.fresh
#
#   idempotent - Runs the bootstrapper twice in the same scratch dir without deleting or
#                modifying the entry file. dist\<env>.exe is removed between runs so the
#                EXE fast path cannot short-circuit run 2 before it reaches :lock_done --
#                this forces a genuine second uv add --script invocation, not just a
#                trivially-unchanged file from an early exit.
#                Emits: self.pep723.writeback.idempotent
#
#   skipflag   - HP_SKIP_PEP723_WRITEBACK=1; no pre-existing header.
#                Emits: self.pep723.writeback.skipflag
#
# v1 scope gate: the feature only runs under HP_ENV_MODE=uv (docs/plan-pep723-writeback.md
# Part 2.2). Any lane/run that resolves to a non-uv provider (e.g. conda-full, where
# HP_FORCE_CONDA_ONLY=1 blocks uv entirely) emits skip=true reason=provider_not_uv, mirroring
# the established Get-CondaBatPath skip-pattern used elsewhere in this suite (see
# docs/agent-interconnect.md "Skip pattern template").
#
# Lane: real/cache/uv/contract-uv (any uv-first lane). Not wired into CI yet (Loop 1 of a
# two-loop split; see CLAUDE.md plan-pep723-writeback.md Part 4) -- run manually for now.
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

$scenario = if ($env:PEP723_SCENARIO) { $env:PEP723_SCENARIO.ToLower() } else { 'fresh' }

# derived requirement: id assignments below are literal strings per branch, not a shared
# $rowId variable, so tools/check_ndjson_registry.py's regex-based PowerShell scanner
# (CODE_HASHTABLE_ID_RE, which only matches `id = '<literal>'`) can find every row id --
# mirrors the established literal-per-branch convention already used in selfapps_warnfix.ps1.
$workDirName = switch ($scenario) {
    'idempotent' { '~selftest_pep723_idempotent' }
    'skipflag'   { '~selftest_pep723_skipflag' }
    default      { '~selftest_pep723_fresh' }
}
$bootstrapLog = "~pep723_$($scenario)_bootstrap.log"

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    if ($scenario -eq 'idempotent') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pep723.writeback.idempotent'
            req     = 'REQ-005.11'
            pass    = $true
            desc    = "PEP 723 write-back $scenario (skipped on non-Windows)"
            details = [ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' }
        })
    } elseif ($scenario -eq 'skipflag') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pep723.writeback.skipflag'
            req     = 'REQ-005.11'
            pass    = $true
            desc    = "PEP 723 write-back $scenario (skipped on non-Windows)"
            details = [ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' }
        })
    } else {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pep723.writeback.fresh'
            req     = 'REQ-005.11'
            pass    = $true
            desc    = "PEP 723 write-back $scenario (skipped on non-Windows)"
            details = [ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' }
        })
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    if ($scenario -eq 'idempotent') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pep723.writeback.idempotent'
            req     = 'REQ-005.11'
            pass    = $false
            desc    = "PEP 723 write-back $scenario`: run_setup.bat not found"
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    } elseif ($scenario -eq 'skipflag') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pep723.writeback.skipflag'
            req     = 'REQ-005.11'
            pass    = $false
            desc    = "PEP 723 write-back $scenario`: run_setup.bat not found"
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    } else {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pep723.writeback.fresh'
            req     = 'REQ-005.11'
            pass    = $false
            desc    = "PEP 723 write-back $scenario`: run_setup.bat not found"
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    }
    exit 1
}

$workDir = Join-Path $here $workDirName
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# derived requirement: a single "import requests" entry lets both pipreqs and the REQ-005.8
# requests->certifi heuristic resolve a two-package dependency set, giving the write-back
# helper something non-trivial to persist. Written BOM-free UTF-8 via .NET API, not a bare
# PowerShell cmdlet default (docs/plan-pep723-writeback.md Part 2.3's explicit encoding
# warning: Set-Content/Out-File can default to UTF-16LE-with-BOM or an unwanted BOM).
$appCode = @'
import requests
print('hi')
'@
$appPath = Join-Path $workDir 'app.py'
[System.IO.File]::WriteAllText($appPath, $appCode, (New-Object System.Text.UTF8Encoding($false)))
$entryBytesPreRun = [System.IO.File]::ReadAllBytes($appPath)

$envLeaf = Split-Path $workDir -Leaf
$envName = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_pep723' }
$distDir = Join-Path $workDir 'dist'
$exePath = Join-Path $distDir "$envName.exe"

$prevSkipFlag = if (Test-Path Env:HP_SKIP_PEP723_WRITEBACK) { $env:HP_SKIP_PEP723_WRITEBACK } else { $null }
if ($scenario -eq 'skipflag') {
    $env:HP_SKIP_PEP723_WRITEBACK = '1'
} else {
    Remove-Item Env:HP_SKIP_PEP723_WRITEBACK -ErrorAction SilentlyContinue
}

function Invoke-Bootstrap {
    param([string]$LogName)
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $LogName 2>&1"
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

try {
    $run1Exit = Invoke-Bootstrap -LogName $bootstrapLog
    $run2Exit = $null
    $entryBytesAfterRun1 = if (Test-Path -LiteralPath $appPath) { [System.IO.File]::ReadAllBytes($appPath) } else { $null }
    if ($scenario -eq 'idempotent') {
        # Force a real second write-back invocation: remove the cached EXE so the top-of-file
        # EXE fast path (which would otherwise short-circuit straight to :success on an
        # unchanged source hash, per docs/agent-interconnect.md "EXE fast path vs env-state
        # fast path") cannot fire, and :lock_done -> :pep723_writeback runs again for real.
        if (Test-Path -LiteralPath $exePath) { Remove-Item -Force -LiteralPath $exePath }
        $bootstrapLog2 = '~pep723_idempotent_bootstrap_run2.log'
        $run2Exit = Invoke-Bootstrap -LogName $bootstrapLog2
    }
} finally {
    if ($null -eq $prevSkipFlag) {
        Remove-Item Env:HP_SKIP_PEP723_WRITEBACK -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PEP723_WRITEBACK = $prevSkipFlag
    }
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText
if ($scenario -eq 'idempotent') {
    $logPath2  = Join-Path $workDir '~pep723_idempotent_bootstrap_run2.log'
    $logLines2 = if (Test-Path $logPath2) { Get-Content -LiteralPath $logPath2 -Encoding ASCII } else { @() }
    $setupText2 = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
    $combined2 = ($logLines2 -join "`n") + "`n" + $setupText2
}

$uvEnvPy  = Join-Path $workDir '.uv_env\Scripts\python.exe'
$isUvMode = Test-Path -LiteralPath $uvEnvPy

$successPhrase  = '[INFO] REQ-005.11: PEP 723 header write-back succeeded via uv add --script.'
$skipflagPhrase = '[INFO] REQ-005.11: PEP 723 write-back skipped (HP_SKIP_PEP723_WRITEBACK set).'
$successFired1  = $combined -match [regex]::Escape($successPhrase)
$skipflagFired1 = $combined -match [regex]::Escape($skipflagPhrase)

if (-not $isUvMode) {
    if ($scenario -eq 'idempotent') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pep723.writeback.idempotent'
            req     = 'REQ-005.11'
            pass    = $true
            desc    = "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)"
            details = [ordered]@{ skip = $true; scenario = $scenario; reason = 'provider_not_uv' }
        })
    } elseif ($scenario -eq 'skipflag') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pep723.writeback.skipflag'
            req     = 'REQ-005.11'
            pass    = $true
            desc    = "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)"
            details = [ordered]@{ skip = $true; scenario = $scenario; reason = 'provider_not_uv' }
        })
    } else {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.pep723.writeback.fresh'
            req     = 'REQ-005.11'
            pass    = $true
            desc    = "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)"
            details = [ordered]@{ skip = $true; scenario = $scenario; reason = 'provider_not_uv' }
        })
    }
    exit 0
}

$entryText = if (Test-Path -LiteralPath $appPath) { [System.IO.File]::ReadAllText($appPath) } else { '' }

if ($scenario -eq 'fresh') {
    $hasBlockStart = $entryText -match [regex]::Escape('# /// script')
    $hasBlockEnd   = $entryText -match [regex]::Escape('# ///')
    $hasRequiresPy = $entryText -match 'requires-python'
    $hasRequests   = $entryText -match 'requests'
    $hasCertifi    = $entryText -match 'certifi'
    $freshPass = $successFired1 -and $hasBlockStart -and $hasBlockEnd -and $hasRequiresPy -and $hasRequests -and $hasCertifi
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pep723.writeback.fresh'
        req     = 'REQ-005.11'
        pass    = $freshPass
        desc    = 'Fresh dependency install wrote a PEP 723 header via uv add --script'
        details = [ordered]@{
            scenario       = $scenario
            exitCode       = $run1Exit
            successFired   = $successFired1
            hasBlockStart  = $hasBlockStart
            hasBlockEnd    = $hasBlockEnd
            hasRequiresPy  = $hasRequiresPy
            hasRequests    = $hasRequests
            hasCertifi     = $hasCertifi
        }
    })
    if (-not $freshPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'skipflag') {
    # Byte-identical check against the pre-run snapshot captured right after the stub was
    # written, BEFORE run_setup.bat ever touched it.
    $bytesEqual = ($null -ne $entryBytesPreRun) -and ($null -ne $entryBytesAfterRun1) -and
                  ($entryBytesPreRun.Length -eq $entryBytesAfterRun1.Length) -and
                  (Compare-Object $entryBytesPreRun $entryBytesAfterRun1 -SyncWindow 0 | Measure-Object).Count -eq 0
    $skipPass = $skipflagFired1 -and $bytesEqual -and (-not $successFired1)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pep723.writeback.skipflag'
        req     = 'REQ-005.11'
        pass    = $skipPass
        desc    = 'HP_SKIP_PEP723_WRITEBACK=1 suppresses write-back; entry file untouched'
        details = [ordered]@{
            scenario        = $scenario
            exitCode        = $run1Exit
            skipflagFired   = $skipflagFired1
            successFired    = $successFired1
            bytesEqual      = $bytesEqual
        }
    })
    if (-not $skipPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'idempotent') {
    $successFired2 = $combined2 -match [regex]::Escape($successPhrase)
    $entryBytesAfterRun2 = if (Test-Path -LiteralPath $appPath) { [System.IO.File]::ReadAllBytes($appPath) } else { $null }
    $bytesEqual = ($null -ne $entryBytesAfterRun1) -and ($null -ne $entryBytesAfterRun2) -and
                  ($entryBytesAfterRun1.Length -eq $entryBytesAfterRun2.Length) -and
                  (Compare-Object $entryBytesAfterRun1 $entryBytesAfterRun2 -SyncWindow 0 | Measure-Object).Count -eq 0
    $idempotentPass = $successFired1 -and $successFired2 -and $bytesEqual
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pep723.writeback.idempotent'
        req     = 'REQ-005.11'
        pass    = $idempotentPass
        desc    = 'Two full bootstrap runs produce a byte-identical PEP 723 header (uv add --script idempotency)'
        details = [ordered]@{
            scenario       = $scenario
            run1Exit       = $run1Exit
            run2Exit       = $run2Exit
            successFired1  = $successFired1
            successFired2  = $successFired2
            bytesEqual     = $bytesEqual
        }
    })
    if (-not $idempotentPass) { exit 1 }
    exit 0
}

Write-NdjsonRow ([ordered]@{
    id      = 'self.pep723.writeback.fresh'
    req     = 'REQ-005.11'
    pass    = $false
    desc    = "Unknown PEP723_SCENARIO value: $scenario"
    details = [ordered]@{ scenario = $scenario }
})
exit 1
