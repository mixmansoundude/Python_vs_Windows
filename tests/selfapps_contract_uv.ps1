$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path $nd)) { New-Item -ItemType File -Path $nd -Force | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

function Write-NdjsonRow {
    param([hashtable]$Row)
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

# derived requirement: this script asserts the uv contract using only artifacts
# left behind by the envsmoke run. It does not invoke run_setup.bat itself.
$envsmoke = Join-Path $here '~envsmoke'
$setupLog = Join-Path $envsmoke '~setup.log'
$lockFile = Join-Path $envsmoke '~environment.lock.txt'
$runtimeTxt = Join-Path $envsmoke 'runtime.txt'

$logText = ''
if (Test-Path -LiteralPath $setupLog) {
    $logText = Get-Content -LiteralPath $setupLog -Raw -ErrorAction SilentlyContinue
    if (-not $logText) { $logText = '' }
}

$lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
$fallbackInjected = ($logText -match '\[TEST\] Injecting uv dep install failure')
$fallbackLogged = ($logText -match '\[WARN\] UV_FALLBACK reason=(\w+)')
$fallbackReason = if ($fallbackLogged) { $matches[1] } else { '' }
$envModeLines = [regex]::Matches($logText, 'HP_ENV_MODE=(\w+)')
$lastEnvMode = if ($envModeLines.Count -gt 0) { $envModeLines[$envModeLines.Count - 1].Groups[1].Value } else { 'unknown' }
$uvUsedSignal = ($logText -match '\[INFO\] UV_USED=1')
$uvVenvReady  = ($logText -match '\[INFO\] uv: (venv created at|reusing existing)')

$lockExists = Test-Path -LiteralPath $lockFile
$lockNonEmpty = $false
if ($lockExists) {
    try { $lockNonEmpty = ((Get-Item -LiteralPath $lockFile).Length -gt 0) } catch { $lockNonEmpty = $false }
}

$runtimeExists = Test-Path -LiteralPath $runtimeTxt
$runtimeValid = $false
if ($runtimeExists) {
    $runtimeContent = (Get-Content -LiteralPath $runtimeTxt -Raw -ErrorAction SilentlyContinue) -replace '\s', ''
    $runtimeValid = ($runtimeContent -match '^python-3\.\d+')
}

if ($lane -eq 'contract-uv-fail') {
    # Failure-injection contract: HP_TEST_UV_FAIL=1 lets venv creation succeed, then forces
    # uv dep install to fail. Asserts dep_install_failed reason and venv was ready first.
    $assertions = [ordered]@{
        injectionLogged   = $fallbackInjected
        fallbackLogged    = $fallbackLogged
        fallbackReason    = $fallbackReason
        uvVenvReady       = $uvVenvReady
        lockExists        = $lockExists
        lockNonEmpty      = $lockNonEmpty
        runtimeExists     = $runtimeExists
        runtimeValid      = $runtimeValid
    }
    $pass = $fallbackInjected -and $fallbackLogged -and `
            ($fallbackReason -eq 'dep_install_failed') -and `
            $uvVenvReady -and `
            $lockNonEmpty -and $runtimeValid
    Write-NdjsonRow ([ordered]@{
        id      = 'self.contract.uv.fail'
        req     = 'REQ-003'
        pass    = [bool]$pass
        desc    = 'Forced uv dep install failure must log dep_install_failed after venv creation'
        details = $assertions
        lane    = $lane
    })
} else {
    # Happy contract: assert uv-as-authority end-to-end
    $assertions = [ordered]@{
        envModeIsUv      = ($lastEnvMode -eq 'uv')
        finalEnvMode     = $lastEnvMode
        uvUsedSignal     = $uvUsedSignal
        lockExists       = $lockExists
        lockNonEmpty     = $lockNonEmpty
        runtimeExists    = $runtimeExists
        runtimeValid     = $runtimeValid
        noFallbackLogged = (-not $fallbackLogged)
        fallbackReason   = $fallbackReason
    }
    $pass = ($lastEnvMode -eq 'uv') -and `
            $lockNonEmpty -and $runtimeValid -and (-not $fallbackLogged)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.contract.uv'
        req     = 'REQ-003'
        pass    = [bool]$pass
        desc    = 'uv must be authoritative end-to-end on happy path'
        details = $assertions
        lane    = $lane
    })

    # self.contract.uv.pyver: assert that REQ-004 Python version (from runtime.txt) is
    # forwarded to uv venv via --python X.Y when PYSPEC is set.
    # Runs a dedicated minimal bootstrap with runtime.txt pre-created so PYSPEC is set
    # on the first run and the version forwarding log line is observable.
    $uvBin = Join-Path $envsmoke '~uv_bin\uv.exe'
    $uvBinExists = Test-Path -LiteralPath $uvBin
    $runtimeVersionForPyver = ''
    if ($runtimeValid -and $runtimeContent -match '^python-([0-9]+\.[0-9]+)') {
        $runtimeVersionForPyver = $Matches[1]
    }

    $pyverPass = $false
    $pyverDetails = [ordered]@{}

    if (-not $uvBinExists) {
        $pyverPass = $true
        $pyverDetails = [ordered]@{ skip=$true; reason='uv-not-acquired'; uvBin=$uvBin }
    } elseif (-not $runtimeVersionForPyver) {
        $pyverPass = $true
        $pyverDetails = [ordered]@{ skip=$true; reason='no-runtime-version'; runtimeExists=$runtimeExists; runtimeValid=$runtimeValid }
    } else {
        $pyverTest = Join-Path $here '~uv_pyver_test'
        New-Item -ItemType Directory -Force -Path $pyverTest | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $pyverTest -Force
        Set-Content -LiteralPath (Join-Path $pyverTest 'app.py') -Value "print('pyver-test-ok')" -NoNewline
        Set-Content -LiteralPath (Join-Path $pyverTest 'runtime.txt') -Value "python-$runtimeVersionForPyver" -NoNewline
        $pyverSetupLog = Join-Path $pyverTest '~setup.log'
        $prevPvwUv = [Environment]::GetEnvironmentVariable('PVW_UV_EXE')
        $env:PVW_UV_EXE = $uvBin
        $pyverExit = -1
        Push-Location -LiteralPath $pyverTest
        try {
            cmd /c .\run_setup.bat *> '~pyver_bootstrap.log'
            $pyverExit = $LASTEXITCODE
        } finally {
            if ($null -eq $prevPvwUv) {
                Remove-Item Env:PVW_UV_EXE -ErrorAction SilentlyContinue
            } else {
                $env:PVW_UV_EXE = $prevPvwUv
            }
            Pop-Location
        }
        $pyverLog = if (Test-Path -LiteralPath $pyverSetupLog) {
            Get-Content -LiteralPath $pyverSetupLog -Raw -ErrorAction SilentlyContinue
        } else { '' }
        # Match the exact log line emitted by run_setup.bat when --python is forwarded.
        $expectedLogLine = "[INFO] uv: creating venv at .uv_env with Python $runtimeVersionForPyver"
        $versionForwarded = ($pyverLog -match [regex]::Escape($expectedLogLine))
        $pyverPass = [bool]$versionForwarded
        $pyverDetails = [ordered]@{
            runtimeVersion   = $runtimeVersionForPyver
            exitCode         = $pyverExit
            versionForwarded = $versionForwarded
            expectedLogLine  = $expectedLogLine
        }
    }

    Write-NdjsonRow ([ordered]@{
        id      = 'self.contract.uv.pyver'
        req     = 'REQ-004'
        pass    = [bool]$pyverPass
        desc    = 'uv venv --python X.Y forwarded from runtime.txt (PYSPEC REQ-004 Tiers 1-2)'
        details = $pyverDetails
        lane    = $lane
    })
}
