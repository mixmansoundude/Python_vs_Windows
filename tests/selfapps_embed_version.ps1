# ASCII only
# selfapps_embed_version.ps1 - REQ-009 Tier 5: the embedded-Python tier honors the Python version a program asks for.
#
# The embed tier always downloads the table's newest minor first. When runtime.txt (or pyproject.toml) asks for another
# minor, ~embed_pyver_check.py, running under that fresh interpreter, downloads the requested one into a sibling
# ~embed_python_swap folder and the batch then replaces ~embed_python with it (rd, then move, because a move onto an
# existing folder nests the source inside it). docs/agent-interconnect.md recorded that swap as "NOT CI-confirmed": the
# older embed rows never request a version, so none of it ever ran. A failed swap is also quiet by design (the helper
# exits 1, the batch keeps the interpreter it has and logs nothing about the request), so only the version the program
# really runs under can show that the swap worked.
#
# Four scenarios, each a real bootstrapper run (conda forced to fail, offline mode on, the embed download let through)
# of a one-line program that prints the Python version it runs under. The EXE the bootstrapper builds carries the
# interpreter it was built with, so the line the verification run captures in ~run.out.txt is the interpreter's own:
#   swap     runtime.txt asks for 3.12: the log says the swap happened and the program runs under 3.12; the interpreter
#            in ~embed_python is 3.12 (asked directly), its python312.dll is there, no ~embed_python_swap is left and
#            the swapped folder was not nested inside the old one.
#   floor    runtime.txt asks for 3.9, below the table's floor: the WARN says the request is not in the table and names
#            the floor, and the program runs under the floor minor.
#   ceiling  runtime.txt asks for 3.99, above the table's ceiling: the WARN names the newest minor, no swap download
#            happens, and the program runs under the newest minor.
#   range    pyproject.toml asks for requires-python ">=3.11,<3.13" and there is no runtime.txt: the newest minor the
#            range allows (3.12) is the one swapped in, not the range's lower bound.
#   isolated (Item 120) the same chain as a runner whose shared Public folder already holds a Miniconda: the inherited
#            PUBLIC points at a decoy Documents\Miniconda3 (a conda.bat that answers `python=3.12` to `conda run` and
#            records every call, a python.cmd), and runtime.txt asks for 3.99. The run must not see the decoy at all:
#            no decoy call, the embed tier does its own request detection (the log line), the WARN names the newest minor
#            and the program runs under it. A run that reached the decoy takes `python=3.12` from it, swaps to 3.12 and
#            logs no request line.
# All four first showed the same failure (run 40074772192, PR #507): the program ran under the newest minor with no WARN and
# no swap, because this chain (no uv, no Miniconda) reaches the embed tier before ~detect_python.py ever ran, so the
# tier saw no request at all. The tier now runs the helper under its own fresh interpreter and logs that it found a
# request (the log line every scenario here requires); the value itself is never logged.
# Expected minors come from tools/embed_pyver_check.py (LATEST_MINOR, FLOOR_MINOR, EMBED_PYTHON_TABLE), so a table
# refresh does not need a change here; the test fails if 3.12 ever leaves the table or becomes the newest or oldest
# minor, because the swap and range scenarios would then prove nothing.
# Item 120: every scenario runs with its own empty PUBLIC folder, never the runner's. Run 43608572893 (PR #531) had all four
# rows red although the product was right: an earlier step of the same job had really installed Miniconda into the
# runner's shared C:\Users\Public\Documents\Miniconda3 after a one-off uv download failure, so the main flow found conda.bat,
# computed PYSPEC itself and the embed tier never logged its own request line. The `isolated` row proves the isolation
# against a decoy, so the four rows cannot go quiet or red because of what a runner left behind.
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text,
# not PowerShell).
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"). Four full builds. Skipped under
# HP_FORCE_CONDA_ONLY=1 like the other embed rows (that mode forbids every non-conda provider).
# Emits: self.embed.version.swap, self.embed.version.floor, self.embed.version.ceiling, self.embed.version.range, self.embed.version.isolated
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

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.swap'; req = 'REQ-009'; pass = $true; desc = 'Embed version swap (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.floor'; req = 'REQ-009'; pass = $true; desc = 'Embed version floor (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.ceiling'; req = 'REQ-009'; pass = $true; desc = 'Embed version ceiling (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.range'; req = 'REQ-009'; pass = $true; desc = 'Embed version range (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.isolated'; req = 'REQ-009'; pass = $true; desc = 'Embed version isolated (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    exit 0
}
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    $skip = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-prohibits-non-conda-fallbacks' }
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.swap'; req = 'REQ-009'; pass = $true; desc = 'Embed version swap (skipped in conda-only mode)'; details = $skip })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.floor'; req = 'REQ-009'; pass = $true; desc = 'Embed version floor (skipped in conda-only mode)'; details = $skip })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.ceiling'; req = 'REQ-009'; pass = $true; desc = 'Embed version ceiling (skipped in conda-only mode)'; details = $skip })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.range'; req = 'REQ-009'; pass = $true; desc = 'Embed version range (skipped in conda-only mode)'; details = $skip })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.isolated'; req = 'REQ-009'; pass = $true; desc = 'Embed version isolated (skipped in conda-only mode)'; details = $skip })
    exit 0
}
$batchPath  = Join-Path $repo 'run_setup.bat'
$helperPath = Join-Path (Join-Path $repo 'tools') 'embed_pyver_check.py'
if (-not (Test-Path -LiteralPath $batchPath) -or -not (Test-Path -LiteralPath $helperPath)) {
    $why = [ordered]@{ error = 'run_setup.bat or tools/embed_pyver_check.py not found' }
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.swap'; req = 'REQ-009'; pass = $false; desc = 'Embed version swap: inputs missing'; details = $why })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.floor'; req = 'REQ-009'; pass = $false; desc = 'Embed version floor: inputs missing'; details = $why })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.ceiling'; req = 'REQ-009'; pass = $false; desc = 'Embed version ceiling: inputs missing'; details = $why })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.range'; req = 'REQ-009'; pass = $false; desc = 'Embed version range: inputs missing'; details = $why })
    Write-NdjsonRow ([ordered]@{ id = 'self.embed.version.isolated'; req = 'REQ-009'; pass = $false; desc = 'Embed version isolated: inputs missing'; details = $why })
    exit 1
}

# What the shipped table says (the Python helper is the canonical source of the table).
$helperText = Get-Content -LiteralPath $helperPath -Raw -Encoding ASCII
$latestMinor = ''
$floorMinor  = ''
$mLatest = [regex]::Match($helperText, '(?m)^LATEST_MINOR\s*=\s*"(\d+\.\d+)"')
$mFloor  = [regex]::Match($helperText, '(?m)^FLOOR_MINOR\s*=\s*"(\d+\.\d+)"')
if ($mLatest.Success) { $latestMinor = $mLatest.Groups[1].Value }
if ($mFloor.Success)  { $floorMinor  = $mFloor.Groups[1].Value }
$tableMinors = @()
foreach ($m in [regex]::Matches($helperText, '(?m)^\s+"(\d+\.\d+)":\s*\("')) { $tableMinors += $m.Groups[1].Value }
$swapMinor = '3.12'
$tableOk = ($latestMinor.Length -gt 0) -and ($floorMinor.Length -gt 0) -and ($tableMinors -contains $swapMinor) -and ($swapMinor -ne $latestMinor) -and ($swapMinor -ne $floorMinor)

$clearVars = @(
    'HP_SKIP_ENTRY_SMOKE', 'HP_SKIP_EXE_SMOKERUN', 'HP_SKIP_PEP723_WRITEBACK', 'HP_SKIP_AUTOPEP_DISCOVERY',
    'HP_SKIP_PIPREQS', 'HP_FORCE_CONDA_ONLY', 'PVW_PROVIDER', 'PVW_TARGET_PY', 'HP_DISABLE_HEURISTICS', 'HP_CI_SKIP_ENV',
    'HP_NDJSON', 'HP_TEST_FORCE_CONDA_FAIL', 'HP_OFFLINE_MODE', 'HP_TEST_FORCE_EMBED_REAL', 'HP_TEST_FORCE_EMBED_FAIL',
    'HP_TEST_FORCE_EMBED_DL_FAIL_ONCE', 'HP_EMBED_LATEST_PATCH'
)
$runTimeoutMs = 30 * 60 * 1000

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
}

# One bootstrapper run in $Work under a watchdog; the embed tier is reached by failing conda, with the embed download let
# through offline mode (the same overrides as self.embed.fallback.real). Never throws.
function Invoke-Bootstrap {
    param([string]$Work, [string]$LogName)
    $res = @{ timedOut = $false; exitCode = -1; boot = ''; setup = ''; error = $null }
    $setVars = @{
        HP_TEST_FORCE_CONDA_FAIL = '1'
        HP_OFFLINE_MODE          = '1'
        HP_SKIP_PIPREQS          = '1'
        HP_TEST_FORCE_EMBED_REAL = '1'
    }
    try {
        $lines = @('@echo off')
        foreach ($k in $clearVars) { if (-not $setVars.ContainsKey($k)) { $lines += ('set "' + $k + '="') } }
        $lines += '>~embver_public.txt echo PUBLIC=%PUBLIC%'
        $lines += ('call run_setup.bat > ' + $LogName + ' 2>&1 < nul')
        $lines += 'exit /b %ERRORLEVEL%'
        Set-Content -LiteralPath (Join-Path $Work '~embver_launch.cmd') -Value $lines -Encoding ASCII
        $saved = @{}
        foreach ($k in $clearVars) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            if (Test-Path -LiteralPath ('Env:' + $k)) { Remove-Item -LiteralPath ('Env:' + $k) }
        }
        foreach ($k in $setVars.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$setVars[$k]) }
        $hadLane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
        if (-not $hadLane) { [Environment]::SetEnvironmentVariable('HP_CI_LANE', 'test') }
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'call ~embver_launch.cmd') -WorkingDirectory $Work -NoNewWindow -PassThru
            $null = $p.Handle   # keeps ExitCode readable after WaitForExit(ms)
            if (-not $p.WaitForExit($runTimeoutMs)) {
                $res.timedOut = $true
                & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
                $null = $p.WaitForExit(30000)
            } else {
                $res.exitCode = $p.ExitCode
            }
        } finally {
            foreach ($k in $setVars.Keys) { [Environment]::SetEnvironmentVariable($k, $null) }
            foreach ($k in $clearVars) {
                if ($null -ne $saved[$k]) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            }
            if (-not $hadLane) { [Environment]::SetEnvironmentVariable('HP_CI_LANE', $null) }
        }
        $res.boot = Read-Text (Join-Path $Work $LogName)
        $res.setup = Read-Text (Join-Path $Work '~setup.log')
    } catch {
        $res.error = $_.Exception.Message
    }
    return $res
}

function New-Scratch {
    param([string]$Name, [string]$RuntimeTxt, [string]$Pyproject = '')
    $work = Join-Path $here ('~selftest_embed_ver_' + $Name)
    foreach ($stale in @($work, ($work + '_decoy'))) {
        if (Test-Path -LiteralPath $stale) { Remove-Item -LiteralPath $stale -Recurse -Force }
    }
    New-Item -ItemType Directory -Force -Path $work | Out-Null
    Copy-Item -LiteralPath $batchPath -Destination $work -Force
    Set-Content -LiteralPath (Join-Path $work 'app.py') -Value 'import sys; print("embed-version-ok %d.%d" % sys.version_info[:2])' -Encoding Ascii
    if ($RuntimeTxt.Length -gt 0) { Set-Content -LiteralPath (Join-Path $work 'runtime.txt') -Value $RuntimeTxt -Encoding Ascii }
    if ($Pyproject.Length -gt 0) { Set-Content -LiteralPath (Join-Path $work 'pyproject.toml') -Value $Pyproject -Encoding Ascii }
    return $work
}

# A Public folder that already holds a Miniconda, the way the shared runner folder can after an earlier step of the job fell back
# to conda. Its conda.bat records every call in $Marker, exits 0 and answers `conda run ...` with `python=3.12` (what
# ~detect_python.py would print for a 3.12 request); its python.cmd stands in for the python the PATH probes look for. A
# bootstrap that reaches either one leaves a line in the marker, which is how the row knows the decoy was seen.
function New-DecoyPublic {
    param([string]$Work, [string]$Marker)
    $pub = $Work + '_decoy'
    $mc = Join-Path (Join-Path $pub 'Documents') 'Miniconda3'
    $cb = Join-Path $mc 'condabin'
    New-Item -ItemType Directory -Force -Path $cb | Out-Null
    $conda = @('@echo off', ('>> "' + $Marker + '" echo conda %*'), 'if /i "%~1"=="run" echo python=3.12', 'exit /b 0')
    Set-Content -LiteralPath (Join-Path $cb 'conda.bat') -Value $conda -Encoding ASCII
    $py = @('@echo off', ('>> "' + $Marker + '" echo python %*'), 'echo Python 3.12.0', 'exit /b 0')
    Set-Content -LiteralPath (Join-Path $mc 'python.cmd') -Value $py -Encoding ASCII
    return $pub
}

function Get-StatusState {
    param([string]$Work)
    $statusPath = Join-Path $Work '~bootstrap.status.json'
    if (Test-Path -LiteralPath $statusPath) {
        try { return [string]((Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { return 'unparseable' }
    }
    return ''
}

# The minor the interpreter in ~embed_python reports when asked directly ('' if it cannot be started).
function Get-EmbedInterpreterMinor {
    param([string]$Work)
    $py = Join-Path (Join-Path $Work '~embed_python') 'python.exe'
    if (-not (Test-Path -LiteralPath $py)) { return '' }
    try {
        $out = & $py -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>$null
        return ([string]($out | Select-Object -First 1)).Trim()
    } catch { return '' }
}

# What every scenario shares: one bootstrap, then the facts about the folder and the program's own version line.
function Get-EmbedFacts {
    param([string]$Name, [string]$RuntimeTxt, [string]$Pyproject = '', [switch]$Polluted)
    $f = [ordered]@{
        timedOut = $false; exitCode = -1; statusState = ''; providerLine = $false; appLine = ''; interpreterMinor = ''
        embedDirExists = $false; swapDirLeft = $false; nested = $false; dlls = @(); swappedLog = $false; warnLine = ''
        swapFailedLog = $false; requestLog = $false; error = $null; work = ''
        publicSeen = ''; publicIsolated = $false; polluted = [bool]$Polluted; decoyPublic = ''; decoyCalls = 0; decoyFirstCall = ''
    }
    $pollutedSet = $false
    $savedPublic = $null
    try {
        $work = New-Scratch $Name $RuntimeTxt $Pyproject
        $f.work = $work
        if ($Polluted) {
            # the runner's own environment, as a step before this one left it: PUBLIC names a folder with a Miniconda in it
            $f.decoyPublic = New-DecoyPublic -Work $work -Marker (Join-Path $work '~embver_decoy_calls.txt')
            $savedPublic = [Environment]::GetEnvironmentVariable('PUBLIC')
            [Environment]::SetEnvironmentVariable('PUBLIC', $f.decoyPublic)
            $pollutedSet = $true
        }
        $r = Invoke-Bootstrap -Work $work -LogName '~embver_boot.log'
        $f.timedOut = $r.timedOut
        $f.exitCode = $r.exitCode
        $f.error = $r.error
        $f.statusState = Get-StatusState $work
        $combined = $r.boot + "`n" + $r.setup
        $f.providerLine = [bool]($combined -match [regex]::Escape('Selected Python provider: Embedded Python (python.org).'))
        $f.swappedLog = [bool]($combined -match 'embed fallback: swapped to requested Python')
        $f.swapFailedLog = [bool]($combined -match 'embed version swap failed')
        $f.requestLog = [bool]($combined -match [regex]::Escape('[INFO] embed fallback: a Python version request was found in this folder.'))
        $mWarn = [regex]::Match($combined, '(?m)\[WARN\] REQ-009: requested Python not in embed table; using (\d+\.\d+) instead\.')
        if ($mWarn.Success) { $f.warnLine = $mWarn.Groups[1].Value }
        $mApp = [regex]::Match((Read-Text (Join-Path $work '~run.out.txt')), 'embed-version-ok (\d+\.\d+)')
        if ($mApp.Success) { $f.appLine = $mApp.Groups[1].Value }
        $embedDir = Join-Path $work '~embed_python'
        $f.embedDirExists = (Test-Path -LiteralPath (Join-Path $embedDir 'python.exe'))
        $f.swapDirLeft = (Test-Path -LiteralPath (Join-Path $work '~embed_python_swap'))
        $f.nested = (Test-Path -LiteralPath (Join-Path $embedDir '~embed_python_swap'))
        # python3.dll (the stable-ABI forwarder) is always there; python3NN.dll is the one that names the version.
        if (Test-Path -LiteralPath $embedDir) { $f.dlls = @(Get-ChildItem -LiteralPath $embedDir -Filter 'python3*.dll' -File | Where-Object { $_.Name -match '^python3\d+\.dll$' } | ForEach-Object { $_.Name }) }
        $f.interpreterMinor = Get-EmbedInterpreterMinor $work
        # what the bootstrapper's own cmd.exe had as PUBLIC, and whether it saw the decoy (every decoy call leaves a line)
        $mPub = [regex]::Match((Read-Text (Join-Path $work '~embver_public.txt')), '(?m)^PUBLIC=(.*?)\s*$')
        if ($mPub.Success) { $f.publicSeen = $mPub.Groups[1].Value }
        $f.publicIsolated = ($f.publicSeen.Length -gt 0) -and ($f.publicSeen -ieq ($work + '_public'))
        $calls = @((Read-Text (Join-Path $work '~embver_decoy_calls.txt')) -split "`r?`n" | Where-Object { $_.Trim().Length -gt 0 })
        $f.decoyCalls = $calls.Count
        if ($calls.Count -gt 0) { $f.decoyFirstCall = ([string]$calls[0]).Trim() }
    } catch {
        $f.error = $_.Exception.Message
    } finally {
        if ($pollutedSet) { [Environment]::SetEnvironmentVariable('PUBLIC', $savedPublic) }
    }
    return $f
}

function Get-DllName {
    param([string]$Minor)
    return ('python3' + $Minor.Split('.')[1] + '.dll')
}

# ---------------------------------------------------------------- swap: a minor that is not the newest
$d = Get-EmbedFacts 'swap' ('python-' + $swapMinor)
$wantDll = Get-DllName $swapMinor
$d['tableOk'] = $tableOk
$d['latestMinor'] = $latestMinor
$d['floorMinor'] = $floorMinor
$d['swapMinor'] = $swapMinor
$d['dllExpected'] = $wantDll
$passSwap = $tableOk -and (-not $d.timedOut) -and ($d.exitCode -eq 0) -and ($d.statusState -eq 'embed_env' -or $d.statusState -eq 'ok') -and $d.providerLine -and $d.requestLog -and $d.swappedLog -and (-not $d.swapFailedLog) -and
    ($d.warnLine -eq '') -and ($d.appLine -eq $swapMinor) -and ($d.interpreterMinor -eq $swapMinor) -and $d.embedDirExists -and (-not $d.swapDirLeft) -and (-not $d.nested) -and
    ($d.dlls -contains $wantDll) -and ($d.dlls.Count -eq 1)
Write-NdjsonRow ([ordered]@{
    id = 'self.embed.version.swap'; req = 'REQ-009, REQ-004.1'; pass = [bool]$passSwap
    desc = 'README REQ-009 Tier 5: a requested minor other than the newest is downloaded, swapped into ~embed_python (not nested) and is the interpreter the program runs under'
    details = $d
})

# ---------------------------------------------------------------- floor: a request below the table
$d = Get-EmbedFacts 'floor' 'python-3.9'
$wantDll = ''
if ($floorMinor.Length -gt 0) { $wantDll = Get-DllName $floorMinor }
$d['tableOk'] = $tableOk
$d['latestMinor'] = $latestMinor
$d['floorMinor'] = $floorMinor
$d['dllExpected'] = $wantDll
$passFloor = $tableOk -and (-not $d.timedOut) -and ($d.exitCode -eq 0) -and ($d.statusState -eq 'embed_env' -or $d.statusState -eq 'ok') -and $d.providerLine -and $d.requestLog -and (-not $d.swapFailedLog) -and
    ($d.warnLine -eq $floorMinor) -and ($d.appLine -eq $floorMinor) -and ($d.interpreterMinor -eq $floorMinor) -and $d.embedDirExists -and (-not $d.swapDirLeft) -and (-not $d.nested) -and
    ($d.dlls -contains $wantDll) -and ($d.dlls.Count -eq 1)
Write-NdjsonRow ([ordered]@{
    id = 'self.embed.version.floor'; req = 'REQ-009'; pass = [bool]$passFloor
    desc = 'README REQ-009 Tier 5: a request below the oldest minor the embed table holds warns that it is not in the table and runs under the floor minor'
    details = $d
})

# ---------------------------------------------------------------- ceiling: a request above the table
$d = Get-EmbedFacts 'ceiling' 'python-3.99'
$wantDll = ''
if ($latestMinor.Length -gt 0) { $wantDll = Get-DllName $latestMinor }
$d['tableOk'] = $tableOk
$d['latestMinor'] = $latestMinor
$d['floorMinor'] = $floorMinor
$d['dllExpected'] = $wantDll
$passCeiling = $tableOk -and (-not $d.timedOut) -and ($d.exitCode -eq 0) -and ($d.statusState -eq 'embed_env' -or $d.statusState -eq 'ok') -and $d.providerLine -and $d.requestLog -and (-not $d.swappedLog) -and (-not $d.swapFailedLog) -and
    ($d.warnLine -eq $latestMinor) -and ($d.appLine -eq $latestMinor) -and ($d.interpreterMinor -eq $latestMinor) -and $d.embedDirExists -and (-not $d.swapDirLeft) -and (-not $d.nested) -and
    ($d.dlls -contains $wantDll) -and ($d.dlls.Count -eq 1)
Write-NdjsonRow ([ordered]@{
    id = 'self.embed.version.ceiling'; req = 'REQ-009'; pass = [bool]$passCeiling
    desc = 'README REQ-009 Tier 5: a request above the newest minor the embed table holds warns that it is not in the table, downloads nothing more and runs under the newest minor'
    details = $d
})

# ---------------------------------------------------------------- range: pyproject.toml, newest minor the range allows
$rangeToml = "[project]`r`nname = `"embver`"`r`nversion = `"0.0.1`"`r`nrequires-python = `">=3.11,<3.13`"`r`ndependencies = []`r`n"
$d = Get-EmbedFacts 'range' '' $rangeToml
$wantDll = Get-DllName $swapMinor
$d['tableOk'] = $tableOk
$d['latestMinor'] = $latestMinor
$d['floorMinor'] = $floorMinor
$d['swapMinor'] = $swapMinor
$d['dllExpected'] = $wantDll
$passRange = $tableOk -and (-not $d.timedOut) -and ($d.exitCode -eq 0) -and ($d.statusState -eq 'embed_env' -or $d.statusState -eq 'ok') -and $d.providerLine -and $d.requestLog -and $d.swappedLog -and (-not $d.swapFailedLog) -and
    ($d.warnLine -eq '') -and ($d.appLine -eq $swapMinor) -and ($d.interpreterMinor -eq $swapMinor) -and $d.embedDirExists -and (-not $d.swapDirLeft) -and (-not $d.nested) -and
    ($d.dlls -contains $wantDll) -and ($d.dlls.Count -eq 1)
Write-NdjsonRow ([ordered]@{
    id = 'self.embed.version.range'; req = 'REQ-009, REQ-004.2'; pass = [bool]$passRange
    desc = 'README REQ-009 Tier 5: a requires-python range in pyproject.toml gets the newest minor the range allows from the embed table, not the range lower bound'
    details = $d
})

# ---------------------------------------------------------------- isolated: a runner whose Public folder already holds a Miniconda
# runtime.txt asks for 3.99 (above the table). A run that reached the decoy gets `python=3.12` from its conda.bat, so it would
# swap to 3.12, log no request line and print no WARN; an isolated run does the ceiling scenario's own work.
$d = Get-EmbedFacts 'isolated' 'python-3.99' -Polluted
$wantDll = ''
if ($latestMinor.Length -gt 0) { $wantDll = Get-DllName $latestMinor }
$d['tableOk'] = $tableOk
$d['latestMinor'] = $latestMinor
$d['floorMinor'] = $floorMinor
$d['dllExpected'] = $wantDll
$passIsolated = $tableOk -and (-not $d.timedOut) -and ($d.exitCode -eq 0) -and ($d.statusState -eq 'embed_env' -or $d.statusState -eq 'ok') -and $d.providerLine -and $d.requestLog -and (-not $d.swappedLog) -and (-not $d.swapFailedLog) -and
    ($d.warnLine -eq $latestMinor) -and ($d.appLine -eq $latestMinor) -and ($d.interpreterMinor -eq $latestMinor) -and $d.embedDirExists -and (-not $d.swapDirLeft) -and (-not $d.nested) -and
    ($d.dlls -contains $wantDll) -and ($d.dlls.Count -eq 1) -and $d.publicIsolated -and ($d.decoyCalls -eq 0)
Write-NdjsonRow ([ordered]@{
    id = 'self.embed.version.isolated'; req = 'REQ-009'; pass = [bool]$passIsolated
    desc = 'README REQ-009 Tier 5: a Miniconda already present in the shared Public folder of the runner is not seen by the scenario (own PUBLIC), so the embed tier detects the requested Python itself'
    details = $d
})

if (-not ($passSwap -and $passFloor -and $passCeiling -and $passRange -and $passIsolated)) { exit 1 }
exit 0
