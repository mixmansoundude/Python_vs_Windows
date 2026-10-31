# ASCII only
# selfapps_conda_transient.ps1 - Item 93: a conda HTTP 5xx in the form conda prints when its sharded repodata
# download fails is retried once, like every other transient conda failure.
#
# Field evidence (run 41074512594): the first conda dry run exited 1 on
#   requests.exceptions.HTTPError: 502 Server Error: Bad Gateway for url: https://conda.anaconda.org/conda-forge/...msgpack.zst
# The text holds none of the four phrases run_setup.bat's REQ-022 detection searches for (CondaHTTPError, Failed to
# fetch, timed out, ConnectionError), so neither :try_conda_create (REQ-022.1) nor :conda_bulk_install (REQ-005.2)
# would wait and retry for a user who hits the same blip.
#
# No Miniconda and no network are involved. The two real code blocks are cut out of run_setup.bat (the bulk install
# subroutine, and the transient check of the create flow with the retry that follows it), wrapped in a tiny driver
# batch file and run by cmd.exe against a stub conda.bat that prints a chosen error text and counts its calls:
#   self.conda.retry5xx.control  - the CondaHTTPError wording is retried at both sites (proves the harness works)
#   self.conda.retry5xx.bulk     - a 502 at the bulk install: waits, runs conda a second time, succeeds
#   self.conda.retry5xx.create   - a 502 at the create check: waits, runs the same create again, succeeds
#   self.conda.retry5xx.bounded  - a 502 that stays: exactly two bulk calls, one create retry, then the failure stands
#   self.conda.retry5xx.nonretry - a solver answer and a 404 are never retried
#
# Lanes: real and justme-test (gating through the aggregate check). Nothing here depends on a provider.
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path -LiteralPath $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

$script:AnyRowFailed = $false
function Write-NdjsonRow {
    param([hashtable]$Row)
    if ($Row.ContainsKey('pass') -and -not $Row['pass']) { $script:AnyRowFailed = $true }
    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

# derived requirement: tools/check_ndjson_registry.py finds a row id only as a quoted string right after the id key,
# and tests/test_req_trace.py reads the req tag the same way, so each call below spells both out in quotes.
function Write-AllRows {
    param([bool]$Pass, $Details)
    Write-NdjsonRow ([ordered]@{ id = 'self.conda.retry5xx.control'; req = 'REQ-022.1'; pass = $Pass; desc = 'the CondaHTTPError wording is retried at the bulk install and the create check, which shows the harness works'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.conda.retry5xx.bulk'; req = 'REQ-005.2'; pass = $Pass; desc = 'a 502 Server Error at the conda bulk install is retried once and the second answer counts'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.conda.retry5xx.create'; req = 'REQ-022.1'; pass = $Pass; desc = 'a 502 Server Error at the conda create check is retried once with the same create command'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.conda.retry5xx.bounded'; req = 'REQ-022.2'; pass = $Pass; desc = 'a 502 that stays is retried exactly once and the failure then stands'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.conda.retry5xx.nonretry'; req = 'REQ-022.3'; pass = $Pass; desc = 'a solver answer and a 404 are not retried'; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path -LiteralPath $batchPath)) {
    Write-AllRows -Pass $false -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# The text conda printed in run 41074512594 (last line of the crash), the old wording the detection already knows, a
# solver answer, and the client-error form of an HTTP failure (a 404 says "Client Error", never "Server Error").
$text502 = 'requests.exceptions.HTTPError: 502 Server Error: Bad Gateway for url: https://conda.anaconda.org/conda-forge/win-64/ce81bff8e89d422c0e4ef1ac471cc77422695c84a7d589c446d1e1a1d5ad2b7b.msgpack.zst'
$textOld = 'CondaHTTPError: HTTP 000 CONNECTION FAILED for url <https://conda.anaconda.org/conda-forge/win-64/current_repodata.json>'
$textSolver = 'PackagesNotFoundError: The following packages are not available from current channels:'
$text404 = 'requests.exceptions.HTTPError: 404 Client Error: Not Found for url: https://conda.anaconda.org/conda-forge/win-64/nosuchfile.msgpack.zst'

$work = Join-Path $here '~selftest_conda5xx'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

$batLines = [System.IO.File]::ReadAllLines($batchPath)

# Lines from the line that is exactly StartLabel up to, not including, the line that is exactly EndLabel.
function Get-BatBlock {
    param([string]$StartLabel, [string]$EndLabel)
    $start = -1
    for ($i = 0; $i -lt $batLines.Length; $i++) {
        if ($batLines[$i].Trim() -eq $StartLabel) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = -1
    for ($j = $start + 1; $j -lt $batLines.Length; $j++) {
        if ($batLines[$j].Trim() -eq $EndLabel) { $end = $j; break }
    }
    if ($end -lt 0) { return $null }
    return $batLines[$start..($end - 1)]
}

$bulkBlock = Get-BatBlock -StartLabel ':conda_bulk_install' -EndLabel ':try_nuitka_tier_a'
$createBlock = Get-BatBlock -StartLabel ':conda_create_check_transient' -EndLabel ':conda_create_failed'
if (-not $bulkBlock -or -not $createBlock) {
    Write-AllRows -Pass $false -Details ([ordered]@{
        error = 'could not cut the code blocks out of run_setup.bat; the labels the harness needs moved'
        bulkFound = [bool]$bulkBlock
        createFound = [bool]$createBlock
    })
    exit 1
}

function Write-CrLf {
    param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
}

# The stub counts its calls in ~stub_calls.txt (one line per call, the first argument) and answers by CONDA_STUB_MODE:
# ok, solver, client404, once502 (502 on the first call, success after), once_old (CondaHTTPError on the first call),
# always502 (502 on every call).
$stubLines = @(
    '@echo off',
    'set "CALLS=%~dp0~stub_calls.txt"',
    'set "FIRST=1"',
    'if exist "%CALLS%" set "FIRST="',
    'echo %1>>"%CALLS%"',
    'if "%CONDA_STUB_MODE%"=="solver" goto :solver',
    'if "%CONDA_STUB_MODE%"=="client404" goto :client404',
    'if "%CONDA_STUB_MODE%"=="always502" goto :t502',
    'if "%CONDA_STUB_MODE%"=="once502" if defined FIRST goto :t502',
    'if "%CONDA_STUB_MODE%"=="once_old" if defined FIRST goto :told',
    'exit /b 0',
    ':t502',
    ('echo ' + $text502 + ' 1>&2'),
    'exit /b 1',
    ':told',
    ('echo ' + $textOld.Replace('<', '^<').Replace('>', '^>') + ' 1>&2'),
    'exit /b 1',
    ':solver',
    ('echo ' + $textSolver + ' 1>&2'),
    'exit /b 1',
    ':client404',
    ('echo ' + $text404 + ' 1>&2'),
    'exit /b 1'
)

# The driver defines the few names the cut-out code expects (LOG, CONDA_BAT, ENVNAME and a :log that only appends to the
# log), calls the code, and writes where it ended up. The real :log also prints a time stamp; the test only needs the text.
function New-Driver {
    param([string]$Site, [string]$Dir, [string]$ResultPath)
    $logLines = @(
        ':log',
        'setlocal',
        'set "MSG=%~1"',
        '>>"%LOG%" echo %MSG%',
        'endlocal',
        'exit /b 0'
    )
    $head = @(
        '@echo off',
        'setlocal',
        ('set "LOG=' + (Join-Path $Dir '~driver.log') + '"'),
        ('set "CONDA_BAT=' + (Join-Path $Dir '~conda_stub.bat') + '"'),
        'set "ENVNAME=stubenv"'
    )
    if ($Site -eq 'bulk') {
        $body = @(
            'call :conda_bulk_install',
            'set "DRV_RC=%ERRORLEVEL%"',
            ('echo RC=%DRV_RC% > "' + $ResultPath + '"'),
            'exit /b 0'
        ) + $bulkBlock + $logLines
        return $head + $body
    }
    $body = @(
        'set "HP_CCREATE_RC=1"',
        'set "HP_CONDA_PYSPEC_SKIP=1"',
        'goto :conda_create_check_transient'
    ) + $createBlock + @(
        ':conda_create_failed',
        ('echo RESULT=failed > "' + $ResultPath + '"'),
        'exit /b 1',
        ':conda_create_done',
        ('echo RESULT=done > "' + $ResultPath + '"'),
        'exit /b 0'
    ) + $logLines
    return $head + $body
}

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}

# One scenario: Site is bulk or create, StubMode picks the stub's answer, FirstText is the output of the failed first
# create attempt (the create flow writes it to ~conda_create.tmp before the cut-out block starts).
function Invoke-Scenario {
    param([string]$Site, [string]$Name, [string]$StubMode, [string]$FirstText = '')
    $dir = Join-Path $work ($Site + '_' + $Name)
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $resultPath = Join-Path $dir '~driver_result.txt'
    Write-CrLf -Path (Join-Path $dir '~conda_stub.bat') -Lines $stubLines
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines (New-Driver -Site $Site -Dir $dir -ResultPath $resultPath)
    if ($Site -eq 'create') {
        Write-CrLf -Path (Join-Path $dir '~conda_create.tmp') -Lines @($FirstText)
    }
    $env:CONDA_STUB_MODE = $StubMode
    $driverExit = $null
    Push-Location -LiteralPath $dir
    try {
        $null = & cmd /c ('"{0}"' -f (Join-Path $dir '~driver.bat')) 2>&1
        $driverExit = $LASTEXITCODE
    } catch {
        $driverExit = -1
    } finally {
        Pop-Location
        Remove-Item Env:CONDA_STUB_MODE -ErrorAction SilentlyContinue
    }
    $calls = 0
    $callsText = Read-Text -Path (Join-Path $dir '~stub_calls.txt')
    if ($callsText) { $calls = @($callsText -split "`r?`n" | Where-Object { $_ -ne '' }).Count }
    $result = (Read-Text -Path $resultPath).Trim()
    $log = Read-Text -Path (Join-Path $dir '~driver.log')
    return [ordered]@{
        site = $Site
        scenario = $Name
        driverExit = $driverExit
        calls = $calls
        result = $result
        retryLine = ($log -match 'transient failure detected; retrying after 15s')
        alsoFailedLine = ($log -match 'retry after transient failure also failed')
    }
}

$retryOk = {
    param($r, [int]$wantCalls, [string]$wantResult)
    return (($r.calls -eq $wantCalls) -and ($r.result -eq $wantResult) -and $r.retryLine)
}

# bulk: the cut-out subroutine makes the first attempt itself, so a retried 502 is two stub calls. create: the first
# attempt is the text file written above, so a retry is one stub call and none means "treated as failed at once".
$bulkOld = Invoke-Scenario -Site 'bulk' -Name 'once_old' -StubMode 'once_old'
$createOld = Invoke-Scenario -Site 'create' -Name 'old' -StubMode 'ok' -FirstText $textOld
$bulk502 = Invoke-Scenario -Site 'bulk' -Name 'once502' -StubMode 'once502'
$create502 = Invoke-Scenario -Site 'create' -Name 'once502' -StubMode 'ok' -FirstText $text502
$bulkAlways = Invoke-Scenario -Site 'bulk' -Name 'always502' -StubMode 'always502'
$createAlways = Invoke-Scenario -Site 'create' -Name 'always502' -StubMode 'always502' -FirstText $text502
$bulkSolver = Invoke-Scenario -Site 'bulk' -Name 'solver' -StubMode 'solver'
$bulk404 = Invoke-Scenario -Site 'bulk' -Name 'client404' -StubMode 'client404'
$createSolver = Invoke-Scenario -Site 'create' -Name 'solver' -StubMode 'ok' -FirstText $textSolver
$create404 = Invoke-Scenario -Site 'create' -Name 'client404' -StubMode 'ok' -FirstText $text404

$controlPass = (& $retryOk $bulkOld 2 'RC=0') -and (& $retryOk $createOld 1 'RESULT=done')
Write-NdjsonRow ([ordered]@{
    id = 'self.conda.retry5xx.control'
    req = 'REQ-022.1'
    pass = [bool]$controlPass
    desc = 'the CondaHTTPError wording is retried at the bulk install and the create check, which shows the harness works'
    details = [ordered]@{ bulk = $bulkOld; create = $createOld }
})

Write-NdjsonRow ([ordered]@{
    id = 'self.conda.retry5xx.bulk'
    req = 'REQ-005.2'
    pass = [bool](& $retryOk $bulk502 2 'RC=0')
    desc = 'a 502 Server Error at the conda bulk install is retried once and the second answer counts'
    details = [ordered]@{ bulk = $bulk502 }
})

Write-NdjsonRow ([ordered]@{
    id = 'self.conda.retry5xx.create'
    req = 'REQ-022.1'
    pass = [bool](& $retryOk $create502 1 'RESULT=done')
    desc = 'a 502 Server Error at the conda create check is retried once with the same create command'
    details = [ordered]@{ create = $create502 }
})

$boundedBulk = ($bulkAlways.calls -eq 2) -and ($bulkAlways.result -eq 'RC=1') -and $bulkAlways.retryLine -and $bulkAlways.alsoFailedLine
$boundedCreate = ($createAlways.calls -eq 1) -and ($createAlways.result -eq 'RESULT=failed') -and $createAlways.retryLine -and $createAlways.alsoFailedLine
Write-NdjsonRow ([ordered]@{
    id = 'self.conda.retry5xx.bounded'
    req = 'REQ-022.2'
    pass = [bool]($boundedBulk -and $boundedCreate)
    desc = 'a 502 that stays is retried exactly once and the failure then stands'
    details = [ordered]@{ bulk = $bulkAlways; create = $createAlways }
})

$nonBulk = ($bulkSolver.calls -eq 1) -and ($bulkSolver.result -eq 'RC=1') -and (-not $bulkSolver.retryLine) -and ($bulk404.calls -eq 1) -and ($bulk404.result -eq 'RC=1') -and (-not $bulk404.retryLine)
$nonCreate = ($createSolver.calls -eq 0) -and ($createSolver.result -eq 'RESULT=failed') -and (-not $createSolver.retryLine) -and ($create404.calls -eq 0) -and ($create404.result -eq 'RESULT=failed') -and (-not $create404.retryLine)
Write-NdjsonRow ([ordered]@{
    id = 'self.conda.retry5xx.nonretry'
    req = 'REQ-022.3'
    pass = [bool]($nonBulk -and $nonCreate)
    desc = 'a solver answer and a 404 are not retried'
    details = [ordered]@{ bulkSolver = $bulkSolver; bulk404 = $bulk404; createSolver = $createSolver; create404 = $create404 }
})

if ($script:AnyRowFailed) { exit 1 }
exit 0
