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

# Runs a dedicated minimal bootstrap in a fresh temp dir whose pyproject.toml carries the
# given requires-python, using the already-acquired uv binary (PVW_UV_EXE). Returns the
# bootstrap exit code, the ~setup.log text, and the interpreter version that actually
# landed in .uv_env (read from pyvenv.cfg -- the anatomical truth -- with a python.exe
# --version fallback). Used by the REQ-004 floor-vs-pin contract rows below.
function Invoke-UvPyverScenario {
    param(
        [string]$Name,
        [string]$RequiresPython = '',
        [string]$RuntimePython = '',
        [string]$UvBin,
        [string]$Repo,
        [string]$Here
    )
    $dir = Join-Path $Here $Name
    if (Test-Path -LiteralPath $dir) {
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath (Join-Path $Repo 'run_setup.bat') -Destination $dir -Force
    Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value "print('pyver-test-ok')" -NoNewline
    # runtime.txt (Tier 1) is preferred for exact pins: uv does not read a project
    # requires-python from it, so the chosen interpreter is never re-validated against an
    # exact `==X.Y` constraint (which PEP 440 would not match against X.Y.patch). pyproject
    # (Tier 2) is used for loose ranges, which uv satisfies with the latest version.
    if ($RuntimePython) {
        Set-Content -LiteralPath (Join-Path $dir 'runtime.txt') -Value "python-$RuntimePython" -NoNewline
    } else {
        $pyproj = "[project]`r`nname = `"pyvertest`"`r`nversion = `"0.0.0`"`r`nrequires-python = `"$RequiresPython`"`r`n"
        Set-Content -LiteralPath (Join-Path $dir 'pyproject.toml') -Value $pyproj -Encoding Ascii
    }
    $scenarioLog = Join-Path $dir '~setup.log'
    $prev = [Environment]::GetEnvironmentVariable('PVW_UV_EXE')
    $env:PVW_UV_EXE = $UvBin
    $exit = -1
    Push-Location -LiteralPath $dir
    try {
        cmd /c .\run_setup.bat *> '~scenario_bootstrap.log'
        $exit = $LASTEXITCODE
    } finally {
        if ($null -eq $prev) {
            Remove-Item Env:PVW_UV_EXE -ErrorAction SilentlyContinue
        } else {
            $env:PVW_UV_EXE = $prev
        }
        Pop-Location
    }
    $log = if (Test-Path -LiteralPath $scenarioLog) {
        Get-Content -LiteralPath $scenarioLog -Raw -ErrorAction SilentlyContinue
    } else { '' }
    if (-not $log) { $log = '' }
    # version_info in pyvenv.cfg is the interpreter uv actually provisioned for .uv_env.
    $ver = ''
    $cfg = Join-Path $dir '.uv_env\pyvenv.cfg'
    if (Test-Path -LiteralPath $cfg) {
        $cfgText = Get-Content -LiteralPath $cfg -Raw -ErrorAction SilentlyContinue
        if ($cfgText -match 'version_info\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)') { $ver = $Matches[1] }
        elseif ($cfgText -match 'version\s*=\s*([0-9]+\.[0-9]+\.[0-9]+)') { $ver = $Matches[1] }
    }
    if (-not $ver) {
        $py = Join-Path $dir '.uv_env\Scripts\python.exe'
        if (Test-Path -LiteralPath $py) {
            try {
                $out = & $py --version 2>&1
                if ("$out" -match '([0-9]+\.[0-9]+\.[0-9]+)') { $ver = $Matches[1] }
            } catch { $ver = '' }
        }
    }
    return [ordered]@{ exit = $exit; log = $log; version = $ver }
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

    # self.uv.first.miniconda.skip: assert that Miniconda download was skipped when uv
    # was available (uv-first feature). Expects the skip log line and no install attempt.
    $uvFirstSkipped = ($logText -match '\[INFO\] uv-first: Miniconda download skipped\.')
    $minicondaInstalled = ($logText -match '\[INFO\] Installing Miniconda')
    Write-NdjsonRow ([ordered]@{
        id      = 'self.uv.first.miniconda.skip'
        req     = 'REQ-009'
        pass    = [bool]($uvFirstSkipped -and -not $minicondaInstalled)
        desc    = 'Miniconda download must be skipped when uv is available (uv-first)'
        details = [ordered]@{
            uvFirstSkipped      = $uvFirstSkipped
            minicondaInstalled  = $minicondaInstalled
        }
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

    # self.contract.uv.pyver.range: REQ-004 floor-vs-pin. A loose pyproject requires-python
    # (>=X.Y) must forward the RANGE to uv venv --python so uv resolves the latest satisfying
    # Python, not the floor. Asserts the "or newer" log phrasing AND that the provisioned
    # interpreter minor is greater than the floor minor. (RED against floor-pinning code.)
    $rangePass = $false
    $rangeDetails = [ordered]@{}
    if (-not $uvBinExists) {
        $rangePass = $true
        $rangeDetails = [ordered]@{ skip=$true; reason='uv-not-acquired'; uvBin=$uvBin }
    } else {
        $r = Invoke-UvPyverScenario -Name '~uv_pyver_range' -RequiresPython '>=3.9' -UvBin $uvBin -Repo $repo -Here $here
        $looseMsg = ($r.log -match [regex]::Escape('[INFO] uv: creating venv at .uv_env with Python 3.9 or newer'))
        $minor = -1
        if ($r.version -match '^[0-9]+\.([0-9]+)') { $minor = [int]$Matches[1] }
        $newerThanFloor = ($minor -gt 9)
        $rangePass = [bool]($looseMsg -and $newerThanFloor)
        $rangeDetails = [ordered]@{
            floor           = '3.9'
            resolvedVersion = $r.version
            resolvedMinor   = $minor
            looseMsgLogged  = $looseMsg
            newerThanFloor  = $newerThanFloor
            exitCode        = $r.exit
        }
    }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.contract.uv.pyver.range'
        req     = 'REQ-004'
        pass    = [bool]$rangePass
        desc    = 'Loose requires-python (>=X.Y) forwards range to uv; resolves latest-satisfying, not floor-pin'
        details = $rangeDetails
        lane    = $lane
    })

    # self.contract.uv.pyver.exactpin: REQ-004 floor-vs-pin guard for the OTHER half. An exact
    # pin (runtime.txt python-X.Y -> PYSPEC python=X.Y) must stay pinned to X.Y and must NOT
    # drift to latest after the range change. Uses a non-latest version (3.12) and asserts the
    # exact log phrasing (no "or newer") AND that the provisioned interpreter is exactly 3.12.x.
    # runtime.txt (not pyproject ==3.12) avoids uv re-validating the 3.12.x interpreter against
    # an exact ==3.12 constraint that PEP 440 would not match.
    $exactPass = $false
    $exactDetails = [ordered]@{}
    if (-not $uvBinExists) {
        $exactPass = $true
        $exactDetails = [ordered]@{ skip=$true; reason='uv-not-acquired'; uvBin=$uvBin }
    } else {
        $r = Invoke-UvPyverScenario -Name '~uv_pyver_exact' -RuntimePython '3.12' -UvBin $uvBin -Repo $repo -Here $here
        $exactMsg  = ($r.log -match [regex]::Escape('[INFO] uv: creating venv at .uv_env with Python 3.12'))
        $notNewer  = (-not ($r.log -match 'with Python 3\.12 or newer'))
        $isExactPin = ($r.version -match '^3\.12\.')
        $exactPass = [bool]($exactMsg -and $notNewer -and $isExactPin)
        $exactDetails = [ordered]@{
            requested       = 'runtime.txt python-3.12'
            resolvedVersion = $r.version
            exactMsgLogged  = $exactMsg
            notLabeledNewer = $notNewer
            isExactPin      = $isExactPin
            exitCode        = $r.exit
        }
    }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.contract.uv.pyver.exactpin'
        req     = 'REQ-004'
        pass    = [bool]$exactPass
        desc    = 'Exact pin (runtime.txt python-X.Y) pins uv venv --python to X.Y (does not drift to latest)'
        details = $exactDetails
        lane    = $lane
    })
}
