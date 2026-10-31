$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path -LiteralPath $nd)) { New-Item -ItemType File -Path $nd -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

$script:AnyRowFailed = $false
function Write-NdjsonRow {
    param([hashtable]$Row)

    if ($Row.ContainsKey('pass') -and -not $Row['pass']) { $script:AnyRowFailed = $true }
    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

function Write-ReqspecRows {
    param(
        [bool]$Pass,
        [hashtable]$TranslationChecks,
        [hashtable]$DryRunDetails,
        [hashtable]$InstallDetails,
        [hashtable]$FailcaseDetails,
        [hashtable]$ChannelPinDetails,
        [bool]$Skip = $false,
        [string]$Reason = ''
    )

    $rows = @(
        [ordered]@{ id = 'reqspec.translate.gte'; desc = 'six>=1.16 translates to conda >= syntax'; specifier = 'six>=1.16'; expected = 'six >=1.16' },
        [ordered]@{ id = 'reqspec.translate.eq'; desc = 'colorama==0.4.6 translates to conda == syntax'; specifier = 'colorama==0.4.6'; expected = 'colorama ==0.4.6' },
        [ordered]@{ id = 'reqspec.translate.compat'; desc = 'packaging~=24.0 translates to conda compatible range'; specifier = 'packaging~=24.0'; expected = 'packaging >=24.0,<25' },
        [ordered]@{ id = 'reqspec.translate.gt'; desc = 'attrs>22.0 translates to conda > syntax'; specifier = 'attrs>22.0'; expected = 'attrs >22.0' },
        [ordered]@{ id = 'reqspec.translate.neq'; desc = 'six!=1.15 translates to conda != syntax'; specifier = 'six!=1.15'; expected = 'six !=1.15' },
        [ordered]@{ id = 'reqspec.translate.lte'; desc = 'attrs<=23.0 translates to conda <= syntax'; specifier = 'attrs<=23.0'; expected = 'attrs <=23.0' }
    )

    foreach ($row in $rows) {
        $details = [ordered]@{
            specifier = $row.specifier
            expected = $row.expected
            found = $false
        }
        if ($TranslationChecks -and $TranslationChecks.ContainsKey($row.id)) {
            $details = $TranslationChecks[$row.id]
        }
        if ($Skip) {
            $details.skip = $true
            if ($Reason) { $details.reason = $Reason }
        }
        $rowPass = $true
        if (-not $Skip) {
            $rowPass = $Pass -and [bool]$details.found
        }
        Write-NdjsonRow ([ordered]@{
            id = $row.id
            req = 'REQ-005'
            pass = $rowPass
            desc = $row.desc
            details = $details
        })
    }

    $dry = if ($DryRunDetails) { $DryRunDetails } else { [ordered]@{ exitCode = -1; packages = @('six>=1.16', 'colorama==0.4.6', 'packaging~=24.0', 'attrs>22.0', 'six!=1.15', 'attrs<=23.0') } }
    if ($Skip) {
        $dry.skip = $true
        if ($Reason) { $dry.reason = $Reason }
    }
    $dryPass = $true
    if (-not $Skip) {
        $dryPass = ($dry.exitCode -eq 0)
    }
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.conda.dryrun'
        req = 'REQ-005'
        pass = $dryPass
        desc = 'conda dry-run accepts translated requirement specifiers'
        details = $dry
    })
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.conda.dryrun.req006'
        req = 'REQ-006'
        pass = $dryPass
        desc = 'conda dry-run uses --override-channels -c conda-forge'
        details = $dry
    })

    $channelPin = if ($ChannelPinDetails) { $ChannelPinDetails } else { [ordered]@{ channel = 'conda-forge'; exitCode = -1; defaultsFound = $false; pkgsMainFound = $false; outputMatched = $false; solverOutputSnippet = '' } }
    if ($Skip) {
        $channelPin.skip = $true
        if ($Reason) { $channelPin.reason = $Reason }
    }
    $channelPinPass = $true
    if (-not $Skip) {
        $channelPinPass = [bool]$channelPin.outputMatched
    }
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.conda.channelpin'
        req = 'REQ-005'
        pass = $channelPinPass
        desc = 'conda dry-run output includes conda-forge channel pin'
        details = $channelPin
    })
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.conda.channelpin.req006'
        req = 'REQ-006'
        pass = $channelPinPass
        desc = 'conda installs use conda-forge exclusively (no defaults channel)'
        details = $channelPin
    })

    $failcase = if ($FailcaseDetails) { $FailcaseDetails } else { [ordered]@{ exitCode = -1; expectedFailure = $true; constraint = 'six<1.0' } }
    if ($Skip) {
        $failcase.skip = $true
        if ($Reason) { $failcase.reason = $Reason }
    }
    $failcasePass = $true
    if (-not $Skip) {
        $failcasePass = Test-FailcaseRejected -Details $failcase
    }
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.conda.dryrun.failcase'
        req = 'REQ-005'
        pass = $failcasePass
        desc = 'conda dry-run rejects invalid requirement constraints'
        details = $failcase
    })

    $install = if ($InstallDetails) { $InstallDetails } else { [ordered]@{ package = 'six'; importable = $false } }
    if ($Skip) {
        $install.skip = $true
        if ($Reason) { $install.reason = $Reason }
    }
    $installPass = $true
    if (-not $Skip) {
        $installPass = $Pass -and [bool]$install.importable
    }
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.install.import'
        req = 'REQ-005'
        pass = $installPass
        desc = 'translated requirement installs into _envsmoke and imports successfully'
        details = $install
    })

    $gteDetails = [ordered]@{
        specifier = 'six>=1.16'
        expected = 'six >=1.16'
        preserved = $false
        installExitCode = if ($install.ContainsKey('installExitCode')) { $install.installExitCode } else { -1 }
        importExitCode = if ($install.ContainsKey('importExitCode')) { $install.importExitCode } else { -1 }
        importable = [bool]$install.importable
    }
    if ($TranslationChecks -and $TranslationChecks.ContainsKey('reqspec.translate.gte')) {
        $gteDetails.preserved = [bool]$TranslationChecks['reqspec.translate.gte'].found
    }
    if ($Skip) {
        $gteDetails.skip = $true
        if ($Reason) { $gteDetails.reason = $Reason }
    }
    $gtePass = $true
    if (-not $Skip) {
        $gtePass = [bool]$gteDetails.preserved -and [bool]$gteDetails.importable
    }
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.gte.explicit'
        req = 'REQ-005'
        pass = $gtePass
        desc = '>= specifier is preserved in translated conda requirements and remains installable/importable'
        details = $gteDetails
    })
}

function Write-ReqspecIngestRows {
    param(
        [hashtable]$TranslateDetails,
        [hashtable]$DryRunDetails,
        [hashtable]$ImportDetails,
        [bool]$Skip = $false,
        [string]$Reason = ''
    )

    $translate = if ($TranslateDetails) { $TranslateDetails } else { [ordered]@{ source = 'requirements.txt'; translated = $false } }
    if ($Skip) {
        $translate.skip = $true
        if ($Reason) { $translate.reason = $Reason }
    }
    $translatePass = if ($Skip) { $true } else { [bool]$translate.translated }
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.ingest.translate'
        req = 'REQ-005'
        pass = $translatePass
        desc = 'existing requirements.txt translates via prep_requirements.py'
        details = $translate
    })

    $dry = if ($DryRunDetails) { $DryRunDetails } else { [ordered]@{ exitCode = -1; source = 'requirements.txt' } }
    if ($Skip) {
        $dry.skip = $true
        if ($Reason) { $dry.reason = $Reason }
    }
    $dryPass = if ($Skip) { $true } else { ($dry.exitCode -eq 0) }
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.ingest.conda.dryrun'
        req = 'REQ-005'
        pass = $dryPass
        desc = 'conda dry-run accepts translated existing requirements.txt'
        details = $dry
    })

    $ingestImport = if ($ImportDetails) { $ImportDetails } else { [ordered]@{ package = 'six'; importable = $false; exitCode = -1 } }
    if ($Skip) {
        $ingestImport.skip = $true
        if ($Reason) { $ingestImport.reason = $Reason }
    }
    $importPass = if ($Skip) { $true } else { ($ingestImport.exitCode -eq 0) }
    Write-NdjsonRow ([ordered]@{
        id = 'reqspec.ingest.install.import'
        req = 'REQ-005'
        pass = $importPass
        desc = 'existing requirements path installs and imports in _envsmoke'
        details = $ingestImport
    })
}

# Item 92: conda-forge now and then answers one request with a 5xx (run 41074512594: a 502 on a repodata shard turned nine
# rows red on justme-test) or drops the connection. On the sharded repodata path conda then crashes with an unhandled
# requests.exceptions.HTTPError whose text holds none of the words run_setup.bat's own REQ-022 detection looks for. The network
# calls below go through Invoke-CondaCommand: one retry after a short wait, only when the output names a 5xx or a failed
# connection, never for a solver answer (PackagesNotFoundError, a 404), at most twice in total.
$script:CondaTransientPattern = '(?i)(\b5\d\d Server Error|HTTPError:\s*5\d\d|CondaHTTPError:\s*HTTP\s*(5\d\d|000)|CONNECTION FAILED|ConnectionError|Connection (reset|aborted|broken)|Read timed out|ReadTimeout|ConnectTimeout)'

function Invoke-CondaCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [Parameter(Mandatory = $true)][string]$Label,
        [string]$LogPath = '',
        [int]$WaitSeconds = 15
    )

    $maxAttempts = 2
    $attempts = 0
    $retried = $false
    $text = ''
    $code = -1
    while ($attempts -lt $maxAttempts) {
        $attempts++
        $raw = cmd /c $Command 2>&1
        $code = $LASTEXITCODE
        $text = $raw | Out-String
        if ($code -eq 0) { break }
        if ($attempts -ge $maxAttempts) { break }
        if ($text -notmatch $script:CondaTransientPattern) { break }
        $retried = $true
        if ($LogPath) {
            Add-Content -LiteralPath $LogPath -Value ('[INFO] {0}: transient conda-forge failure (exit {1}); retrying once after {2}s. First answer:' -f $Label, $code, $WaitSeconds) -Encoding Ascii
            Add-Content -LiteralPath $LogPath -Value $text -Encoding Ascii
        }
        Start-Sleep -Seconds $WaitSeconds
    }
    return [pscustomobject]@{ Output = $text; ExitCode = $code; Attempts = $attempts; Retried = $retried }
}

# The verdict of the dry run that is EXPECTED to fail. A non-zero exit alone is not a rejection of the constraint: a 5xx from
# conda-forge exits non-zero as well, and passing on it would prove nothing about the requirement (CodeRabbit, PR #515).
function Test-FailcaseRejected {
    param($Details)
    return (($Details.exitCode -ne 0) -and (-not $Details.transientAnswer))
}

function Get-CondaBatPath {
    $publicRoot = [Environment]::GetEnvironmentVariable('PUBLIC')
    $publicRootClean = if ($publicRoot) { $publicRoot.Trim().Trim('"') } else { '' }
    $condaBatCandidates = @()
    if ($publicRootClean) {
        $condaBatCandidates += Join-Path $publicRootClean 'Documents\Miniconda3\condabin\conda.bat'
        $condaBatCandidates += Join-Path $publicRootClean 'Documents\Miniconda3\Scripts\conda.bat'
    }
    $condaBatCandidates += 'C:\Miniconda3\condabin\conda.bat'
    $condaBatCandidates += 'C:\Miniconda3\Scripts\conda.bat'
    $condaBatCandidates += 'C:\ProgramData\Miniconda3\condabin\conda.bat'
    $condaBatCandidates += 'C:\ProgramData\Miniconda3\Scripts\conda.bat'
    $condaBatCandidates += 'C:\Users\Public\Documents\Miniconda3\condabin\conda.bat'
    $condaBatCandidates += 'C:\Users\Public\Documents\Miniconda3\Scripts\conda.bat'

    $condaBat = $condaBatCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $condaBat) {
        $whereResult = where.exe conda 2>$null
        if ($whereResult) { $condaBat = ($whereResult -split "`r?`n")[0].Trim() }
    }

    return [ordered]@{
        path = $condaBat
        candidates = $condaBatCandidates
        publicRoot = if ($publicRoot) { $publicRoot } else { '(empty)' }
    }
}

function Get-CondaPythonPath {
    param([string]$CondaBat)

    if (-not $CondaBat) { return '' }
    $scriptsDir = Split-Path -Path $CondaBat -Parent
    $leaf = Split-Path -Path $scriptsDir -Leaf
    if ($leaf -ieq 'condabin') {
        return Join-Path (Split-Path -Path $scriptsDir -Parent) 'python.exe'
    }
    if ($leaf -ieq 'Scripts') {
        return Join-Path (Split-Path -Path $scriptsDir -Parent) 'python.exe'
    }
    return ''
}

function Export-PrepRequirementsHelper {
    param(
        [string]$BatchPath,
        [string]$OutPath
    )

    if (-not (Test-Path -LiteralPath $BatchPath)) {
        throw "run_setup.bat not found: $BatchPath"
    }

    $payload = $null
    foreach ($line in Get-Content -LiteralPath $BatchPath -Encoding Ascii) {
        if ($line -match '^set "HP_PREP_REQUIREMENTS=([^\"]+)"$') {
            $payload = $Matches[1]
            break
        }
    }
    if (-not $payload) {
        throw 'HP_PREP_REQUIREMENTS payload not found in run_setup.bat'
    }

    $bytes = [Convert]::FromBase64String($payload)
    [IO.File]::WriteAllBytes($OutPath, $bytes)
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-ReqspecRows -Pass $true -TranslationChecks @{} -DryRunDetails @{} -InstallDetails @{} -FailcaseDetails @{} -ChannelPinDetails @{} -Skip $true -Reason 'non-windows-host'
    Write-ReqspecIngestRows -TranslateDetails @{} -DryRunDetails @{} -ImportDetails @{} -Skip $true -Reason 'non-windows-host'
    exit 0
}

$work = Join-Path $here '~reqspec'
$logPath = Join-Path $work '~reqspec_run.log'
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }

# Item 92: prove Invoke-CondaCommand's rules with a stub command, no conda and no network. The stub prints the last line of the
# real 502 crash (run 41074512594) or a real solver answer, so the pattern is checked against text conda wrote.
$retryStub = Join-Path $work '~retry_stub.cmd'
$retryMark = Join-Path $work '~retry_stub.mark'
Set-Content -LiteralPath $retryStub -Encoding Ascii -Value @(
    '@echo off',
    'if "%~2"=="ok" goto ok',
    'if "%~2"=="solver" goto solver',
    'if "%~2"=="always" goto transient',
    'if "%~2"=="once" if not exist "%~1" goto first',
    'goto ok',
    ':first',
    'echo first> "%~1"',
    ':transient',
    'echo requests.exceptions.HTTPError: 502 Server Error: Bad Gateway for url: https://conda.anaconda.org/conda-forge/win-64/ce81bff8e89d422c0e4ef1ac471cc77422695c84a7d589c446d1e1a1d5ad2b7b.msgpack.zst 1>&2',
    'exit /b 1',
    ':solver',
    'echo PackagesNotFoundError: The following packages are not available from current channels: 1>&2',
    'exit /b 1',
    ':ok',
    'echo ok',
    'exit /b 0'
)
function Invoke-RetryStub {
    param([string]$Mode)
    if (Test-Path -LiteralPath $retryMark) { Remove-Item -LiteralPath $retryMark -Force -ErrorAction SilentlyContinue }
    return Invoke-CondaCommand -Command ('"{0}" "{1}" {2}' -f $retryStub, $retryMark, $Mode) -Label ('stub ' + $Mode) -LogPath $logPath -WaitSeconds 1
}
function Get-RetryDetails {
    param($Run)
    return [ordered]@{
        exitCode = $Run.ExitCode
        attempts = $Run.Attempts
        retried = $Run.Retried
        outputSnippet = ($Run.Output.Trim() -replace '[^\x20-\x7e]', '?').Substring(0, [Math]::Min(120, $Run.Output.Trim().Length))
    }
}

$onceRun = Invoke-RetryStub -Mode 'once'
$onceDetails = Get-RetryDetails -Run $onceRun
Write-NdjsonRow ([ordered]@{
    id = 'reqspec.retry.once'
    req = 'N/A'
    pass = (($onceRun.ExitCode -eq 0) -and ($onceRun.Attempts -eq 2) -and $onceRun.Retried)
    desc = 'a conda command that fails once with a 502 is run a second time and the second answer counts'
    details = $onceDetails
})

$alwaysRun = Invoke-RetryStub -Mode 'always'
$alwaysDetails = Get-RetryDetails -Run $alwaysRun
Write-NdjsonRow ([ordered]@{
    id = 'reqspec.retry.bounded'
    req = 'N/A'
    pass = (($alwaysRun.ExitCode -eq 1) -and ($alwaysRun.Attempts -eq 2) -and $alwaysRun.Retried)
    desc = 'a conda command that keeps failing with a 502 is run exactly twice and the failure is reported'
    details = $alwaysDetails
})

$solverRun = Invoke-RetryStub -Mode 'solver'
$okRun = Invoke-RetryStub -Mode 'ok'
$solverDetails = Get-RetryDetails -Run $solverRun
$solverDetails.okAttempts = $okRun.Attempts
$solverDetails.okExitCode = $okRun.ExitCode
Write-NdjsonRow ([ordered]@{
    id = 'reqspec.retry.nontransient'
    req = 'N/A'
    pass = (($solverRun.ExitCode -eq 1) -and ($solverRun.Attempts -eq 1) -and (-not $solverRun.Retried) -and ($okRun.ExitCode -eq 0) -and ($okRun.Attempts -eq 1))
    desc = 'a solver answer is never run twice, and a command that succeeds is run once'
    details = $solverDetails
})

$classifyCases = @(
    @{ transient = $true;  text = 'requests.exceptions.HTTPError: 502 Server Error: Bad Gateway for url: https://conda.anaconda.org/conda-forge/win-64/ce81bff8e89d422c0e4ef1ac471cc77422695c84a7d589c446d1e1a1d5ad2b7b.msgpack.zst' },
    @{ transient = $true;  text = 'CondaHTTPError: HTTP 503 SERVICE UNAVAILABLE for url <https://conda.anaconda.org/conda-forge/noarch/repodata.json>' },
    @{ transient = $true;  text = 'CondaHTTPError: HTTP 000 CONNECTION FAILED for url <https://conda.anaconda.org/conda-forge/win-64/current_repodata.json>' },
    @{ transient = $true;  text = "requests.exceptions.ConnectionError: HTTPSConnectionPool(host='conda.anaconda.org', port=443): Max retries exceeded" },
    @{ transient = $true;  text = "requests.exceptions.ReadTimeout: HTTPSConnectionPool(host='conda.anaconda.org', port=443): Read timed out. (read timeout=9.15)" },
    @{ transient = $false; text = 'PackagesNotFoundError: The following packages are not available from current channels:' },
    @{ transient = $false; text = 'UnsatisfiableError: The following specifications were found to be incompatible with each other:' },
    @{ transient = $false; text = 'CondaHTTPError: HTTP 404 NOT FOUND for url <https://conda.anaconda.org/conda-forge/win-64/nosuchpackage>' },
    @{ transient = $false; text = 'requests.exceptions.HTTPError: 404 Client Error: Not Found for url: https://conda.anaconda.org/conda-forge/win-64/x.msgpack.zst' }
)
$classifyWrong = @()
foreach ($case in $classifyCases) {
    if (([bool]($case.text -match $script:CondaTransientPattern)) -ne $case.transient) { $classifyWrong += $case.text.Substring(0, [Math]::Min(60, $case.text.Length)) }
}
Write-NdjsonRow ([ordered]@{
    id = 'reqspec.retry.classify'
    req = 'N/A'
    pass = ($classifyWrong.Count -eq 0)
    desc = 'the transient pattern matches conda 5xx and connection failures and not solver answers or a 404'
    details = [ordered]@{ cases = $classifyCases.Count; wrong = $classifyWrong }
})

$condaInfo = Get-CondaBatPath
$condaBat = $condaInfo.path
if (-not $condaBat) {
    $translationChecks = @{}
    foreach ($pair in @(
        @{ id = 'reqspec.translate.gte'; specifier = 'six>=1.16'; expected = 'six >=1.16' },
        @{ id = 'reqspec.translate.eq'; specifier = 'colorama==0.4.6'; expected = 'colorama ==0.4.6' },
        @{ id = 'reqspec.translate.compat'; specifier = 'packaging~=24.0'; expected = 'packaging >=24.0,<25' },
        @{ id = 'reqspec.translate.gt'; specifier = 'attrs>22.0'; expected = 'attrs >22.0' },
        @{ id = 'reqspec.translate.neq'; specifier = 'six!=1.15'; expected = 'six !=1.15' },
        @{ id = 'reqspec.translate.lte'; specifier = 'attrs<=23.0'; expected = 'attrs <=23.0' }
    )) {
        $translationChecks[$pair.id] = [ordered]@{
            specifier = $pair.specifier
            expected = $pair.expected
            found = $false
            reason = 'conda-not-found'
            condaBatCandidates = $condaInfo.candidates
            publicRoot = $condaInfo.publicRoot
        }
    }
    $dryRunDetails = [ordered]@{
        exitCode = -1
        packages = @('six>=1.16', 'colorama==0.4.6', 'packaging~=24.0', 'attrs>22.0', 'six!=1.15', 'attrs<=23.0')
        reason = 'conda-not-found'
        condaBatCandidates = $condaInfo.candidates
        publicRoot = $condaInfo.publicRoot
    }
    $installDetails = [ordered]@{
        package = 'six'
        importable = $false
        reason = 'conda-not-found'
        condaBatCandidates = $condaInfo.candidates
        publicRoot = $condaInfo.publicRoot
    }
    # derived requirement: in uv-first lanes (HP_FORCE_CONDA_ONLY not set), Miniconda is
    # never installed so these conda-specific tests are not applicable -- emit skip=true.
    # In conda-only lanes (HP_FORCE_CONDA_ONLY=1), conda MUST be present; emit failures.
    if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
        Write-ReqspecRows -Pass $false -TranslationChecks $translationChecks -DryRunDetails $dryRunDetails -InstallDetails $installDetails -FailcaseDetails ([ordered]@{ exitCode = -1; expectedFailure = $true; constraint = 'six<1.0'; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot }) -ChannelPinDetails ([ordered]@{ channel = 'conda-forge'; exitCode = -1; defaultsFound = $false; pkgsMainFound = $false; outputMatched = $false; solverOutputSnippet = ''; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot })
        Write-ReqspecIngestRows -TranslateDetails ([ordered]@{ source = 'requirements.txt'; translated = $false; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot }) -DryRunDetails ([ordered]@{ exitCode = -1; source = 'requirements.txt'; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot }) -ImportDetails ([ordered]@{ package = 'six'; importable = $false; exitCode = -1; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot })
    } else {
        Write-ReqspecRows -Pass $true -Skip $true -Reason 'conda-not-installed-uv-first' -TranslationChecks $translationChecks -DryRunDetails $dryRunDetails -InstallDetails $installDetails -FailcaseDetails ([ordered]@{ exitCode = -1; expectedFailure = $true; constraint = 'six<1.0'; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot }) -ChannelPinDetails ([ordered]@{ channel = 'conda-forge'; exitCode = -1; defaultsFound = $false; pkgsMainFound = $false; outputMatched = $false; solverOutputSnippet = ''; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot })
        Write-ReqspecIngestRows -Skip $true -Reason 'conda-not-installed-uv-first' -TranslateDetails ([ordered]@{ source = 'requirements.txt'; translated = $false; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot }) -DryRunDetails ([ordered]@{ exitCode = -1; source = 'requirements.txt'; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot }) -ImportDetails ([ordered]@{ package = 'six'; importable = $false; exitCode = -1; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot })
    }
    if ($script:AnyRowFailed) { exit 1 }
    exit 0
}

$condaPython = Get-CondaPythonPath -CondaBat $condaBat
$prepPath = Join-Path $work '~prep_requirements.py'
$reqPath = Join-Path $work 'requirements.txt'
$badReqPath = Join-Path $work 'requirements.bad.txt'
$condaReqPath = Join-Path $work '~reqs_conda.txt'
$translationChecks = @{}
$dryRunDetails = [ordered]@{ exitCode = -1; packages = @('six>=1.16', 'colorama==0.4.6', 'packaging~=24.0', 'attrs>22.0', 'six!=1.15', 'attrs<=23.0'); solverOutputSnippet = ''; condaBat = $condaBat }
$installDetails = [ordered]@{ package = 'six'; importable = $false; condaBat = $condaBat; environment = '_envsmoke' }
$failcaseDetails = [ordered]@{ exitCode = -1; expectedFailure = $true; constraint = 'six<1.0'; condaBat = $condaBat }
$channelPinDetails = [ordered]@{ channel = 'conda-forge'; exitCode = -1; defaultsFound = $false; pkgsMainFound = $false; outputMatched = $false; solverOutputSnippet = ''; condaBat = $condaBat }
$reqIngestDir = Join-Path $PSScriptRoot '~req_ingest'
$reqFile = Join-Path $reqIngestDir 'requirements.txt'
$ingestCondaReqPath = Join-Path $reqIngestDir '~reqs_conda.txt'
$ingestTranslateDetails = [ordered]@{ source = 'requirements.txt'; translated = $false }
$ingestDryRunDetails = [ordered]@{ exitCode = -1; source = 'requirements.txt' }
$ingestImportDetails = [ordered]@{ package = 'six'; importable = $false; exitCode = -1 }

New-Item -ItemType Directory -Force -Path $reqIngestDir | Out-Null
Set-Content -LiteralPath $reqFile -Encoding Ascii -Value @(
    'six>=1.16',
    'colorama==0.4.6',
    'packaging~=24.0'
)

Set-Content -LiteralPath $reqPath -Encoding Ascii -Value @(
    'six>=1.16',
    'colorama==0.4.6',
    'packaging~=24.0',
    'attrs>22.0',
    'six!=1.15',
    'attrs<=23.0'
)
Set-Content -LiteralPath $badReqPath -Encoding Ascii -Value @(
    'six<1.0'
)

$overallPass = $true
try {
    Export-PrepRequirementsHelper -BatchPath (Join-Path $repo 'run_setup.bat') -OutPath $prepPath
} catch {
    $overallPass = $false
    Add-Content -LiteralPath $logPath -Value ("helper export failed: {0}" -f $_.Exception.Message) -Encoding Ascii
}

if (-not (Test-Path -LiteralPath $condaPython)) {
    $overallPass = $false
    Add-Content -LiteralPath $logPath -Value ("conda python missing: {0}" -f $condaPython) -Encoding Ascii
}

$condaText = ''
if ($overallPass) {
    Push-Location -LiteralPath $work
    try {
        $prepOutput = & $condaPython $prepPath $reqPath 2>&1
        $prepExit = $LASTEXITCODE
        if ($prepOutput) { Add-Content -LiteralPath $logPath -Value ($prepOutput | Out-String) -Encoding Ascii }
        Add-Content -LiteralPath $logPath -Value ("prep exit code: {0}" -f $prepExit) -Encoding Ascii
        if ($prepExit -ne 0) {
            $overallPass = $false
        }
    } catch {
        $overallPass = $false
        Add-Content -LiteralPath $logPath -Value ("prep exception: {0}" -f $_.Exception.Message) -Encoding Ascii
    } finally {
        Pop-Location
    }
}

if (Test-Path -LiteralPath $condaReqPath) {
    $condaText = Get-Content -LiteralPath $condaReqPath -Raw -Encoding Ascii
    Add-Content -LiteralPath $logPath -Value "translated requirements:" -Encoding Ascii
    Add-Content -LiteralPath $logPath -Value $condaText -Encoding Ascii
} else {
    $overallPass = $false
    Add-Content -LiteralPath $logPath -Value ("missing translated requirements file: {0}" -f $condaReqPath) -Encoding Ascii
}

foreach ($pair in @(
    @{ id = 'reqspec.translate.gte'; specifier = 'six>=1.16'; expected = 'six >=1.16' },
    @{ id = 'reqspec.translate.eq'; specifier = 'colorama==0.4.6'; expected = 'colorama ==0.4.6' },
    @{ id = 'reqspec.translate.compat'; specifier = 'packaging~=24.0'; expected = 'packaging >=24.0,<25' },
    @{ id = 'reqspec.translate.gt'; specifier = 'attrs>22.0'; expected = 'attrs >22.0' },
    @{ id = 'reqspec.translate.neq'; specifier = 'six!=1.15'; expected = 'six !=1.15' },
    @{ id = 'reqspec.translate.lte'; specifier = 'attrs<=23.0'; expected = 'attrs <=23.0' }
)) {
    $found = $false
    if ($condaText) { $found = $condaText.Contains($pair.expected) }
    $translationChecks[$pair.id] = [ordered]@{
        specifier = $pair.specifier
        expected = $pair.expected
        found = $found
    }
}

$dryRunCommand = "`"$condaBat`" install --dry-run -n base --override-channels -c conda-forge --file `"$condaReqPath`""
$badDryRunCommand = "`"$condaBat`" install --dry-run -n base --override-channels -c conda-forge --file `"$badReqPath`""

$condaConfigCommands = @(
    "`"$condaBat`" config --env --add channels conda-forge",
    "`"$condaBat`" config --env --remove channels defaults"
)
foreach ($configCommand in $condaConfigCommands) {
    try {
        $configOutput = cmd /c $configCommand 2>&1
        $configExit = $LASTEXITCODE
        Add-Content -LiteralPath $logPath -Value ("conda config command: {0}" -f $configCommand) -Encoding Ascii
        if ($configOutput) {
            Add-Content -LiteralPath $logPath -Value ($configOutput | Out-String) -Encoding Ascii
        }
        if (($configCommand -match 'remove channels defaults') -and ($configExit -ne 0)) {
            Add-Content -LiteralPath $logPath -Value 'conda defaults channel was already absent' -Encoding Ascii
        } elseif ($configExit -ne 0) {
            Add-Content -LiteralPath $logPath -Value ("conda config warning exit code: {0}" -f $configExit) -Encoding Ascii
        }
    } catch {
        if ($configCommand -match 'remove channels defaults') {
            Add-Content -LiteralPath $logPath -Value ("conda defaults removal warning: {0}" -f $_.Exception.Message) -Encoding Ascii
        } else {
            Add-Content -LiteralPath $logPath -Value ("conda config exception: {0}" -f $_.Exception.Message) -Encoding Ascii
        }
    }
}
try {
    $dryRun = Invoke-CondaCommand -Command $dryRunCommand -Label 'conda dry-run' -LogPath $logPath
    $dryOutput = $dryRun.Output
    $dryExit = $dryRun.ExitCode
    $dryRunDetails.exitCode = $dryExit
    $dryRunDetails.attempts = $dryRun.Attempts
    $channelPinDetails.exitCode = $dryExit
    if ($dryOutput) {
        Add-Content -LiteralPath $logPath -Value 'conda dry-run output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value $dryOutput -Encoding Ascii
        $dryOutputText = $dryOutput
        $drySnippet = $dryOutputText.Substring(0, [Math]::Min(200, $dryOutputText.Length))
        $dryRunDetails.solverOutputSnippet = $drySnippet
        $channelPinDetails.outputMatched = $dryOutputText.Contains('conda-forge')
        $channelPinDetails.defaultsFound = $dryOutputText.Contains('defaults')
        $channelPinDetails.pkgsMainFound = $dryOutputText.Contains('pkgs/main')
        $channelPinDetails.solverOutputSnippet = $drySnippet
    }
    if ($dryExit -ne 0) { $overallPass = $false }
} catch {
    $overallPass = $false
    $dryRunDetails.exitCode = -1
    $dryRunDetails.error = $_.Exception.Message
    $channelPinDetails.exitCode = -1
    Add-Content -LiteralPath $logPath -Value ("conda dry-run exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}

try {
    $badDryRun = Invoke-CondaCommand -Command $badDryRunCommand -Label 'conda failure-case dry-run' -LogPath $logPath
    $badDryOutput = $badDryRun.Output
    $exitCodeBad = $badDryRun.ExitCode
    $failcaseDetails.exitCode = $exitCodeBad
    $failcaseDetails.attempts = $badDryRun.Attempts
    $failcaseDetails.transientAnswer = [bool]($badDryOutput -match $script:CondaTransientPattern)
    if ($badDryOutput) {
        Add-Content -LiteralPath $logPath -Value 'conda failure-case dry-run output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value ($badDryOutput | Out-String) -Encoding Ascii
    }
    Add-Content -LiteralPath $logPath -Value ("[INFO] failure-case dry-run exitCode={0} (expected non-zero)" -f $exitCodeBad) -Encoding Ascii
} catch {
    $failcaseDetails.exitCode = -1
    $failcaseDetails.error = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("failure-case dry-run exception: {0}" -f $_.Exception.Message) -Encoding Ascii
    Add-Content -LiteralPath $logPath -Value '[INFO] failure-case dry-run exitCode=-1 (expected non-zero)' -Encoding Ascii
}

# derived requirement: reuse the _envsmoke environment that the earlier self-test
# already created so this probe proves translated specifiers install end-to-end in
# the same real bootstrap environment instead of a synthetic throwaway env.
# When uv mode was used, no conda env was created; skip install/import without
# failing $overallPass so translation rows still pass on uv lanes.
$condaEnvsRoot = Split-Path (Split-Path $condaBat -Parent) -Parent
$smokeEnvPy = Join-Path $condaEnvsRoot "envs\_envsmoke\python.exe"
# derived requirement: only skip when uv was actually used for the bootstrap;
# if conda was used and _envsmoke is missing that is a real failure, not a graceful skip.
$uvEnvPath = Join-Path $here '~envsmoke' '.uv_env'
$uvWasUsed = Test-Path -LiteralPath $uvEnvPath
if (-not (Test-Path -LiteralPath $smokeEnvPy)) {
    if ($uvWasUsed) {
        $installDetails.installExitCode = 0
        $installDetails.importExitCode = 0
        $installDetails.importable = $true
        $installDetails.skip = $true
        $installDetails.reason = 'env-not-found (uv-mode)'
    } else {
        $overallPass = $false
        $installDetails.installExitCode = -1
        $installDetails.importExitCode = -1
        $installDetails.importable = $false
        $installDetails.reason = 'env-not-found (unexpected)'
    }
} else {
$installCommand = "`"$condaBat`" install -y -n _envsmoke --override-channels -c conda-forge `"six>=1.16`""
try {
    $installRun = Invoke-CondaCommand -Command $installCommand -Label 'conda install' -LogPath $logPath
    $installOutput = $installRun.Output
    $installExit = $installRun.ExitCode
    $installDetails.installExitCode = $installExit
    $installDetails.installAttempts = $installRun.Attempts
    if ($installOutput) {
        Add-Content -LiteralPath $logPath -Value 'conda install output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value $installOutput -Encoding Ascii
    }
    if ($installExit -ne 0) { $overallPass = $false }
} catch {
    $overallPass = $false
    $installDetails.installExitCode = -1
    $installDetails.installError = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("conda install exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}

$importCommand = "`"$condaBat`" run -n _envsmoke python -c `"import six`""
try {
    $importOutput = cmd /c $importCommand 2>&1
    $importExit = $LASTEXITCODE
    $installDetails.importExitCode = $importExit
    $installDetails.importable = ($importExit -eq 0)
    if ($importOutput) {
        Add-Content -LiteralPath $logPath -Value 'conda import output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value ($importOutput | Out-String) -Encoding Ascii
    }
    if ($importExit -ne 0) { $overallPass = $false }
} catch {
    $overallPass = $false
    $installDetails.importExitCode = -1
    $installDetails.importable = $false
    $installDetails.importError = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("conda import exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}
}

try {
    Push-Location -LiteralPath $reqIngestDir
    try {
        $ingestPrepOutput = & $condaPython $prepPath $reqFile 2>&1
        $ingestPrepExit = $LASTEXITCODE
        if ($ingestPrepOutput) { Add-Content -LiteralPath $logPath -Value ($ingestPrepOutput | Out-String) -Encoding Ascii }
        Add-Content -LiteralPath $logPath -Value ("ingest prep exit code: {0}" -f $ingestPrepExit) -Encoding Ascii
    } finally {
        Pop-Location
    }
} catch {
    $ingestTranslateDetails.error = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("ingest prep exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}

if (Test-Path -LiteralPath $ingestCondaReqPath) {
    $ingestText = Get-Content -LiteralPath $ingestCondaReqPath -Raw -Encoding Ascii
    $ingestTranslated = $ingestText.Contains('six >=1.16') -and $ingestText.Contains('colorama ==0.4.6') -and $ingestText.Contains('packaging >=24.0,<25')
    $ingestTranslateDetails.translated = $ingestTranslated
    Add-Content -LiteralPath $logPath -Value 'ingest translated requirements:' -Encoding Ascii
    Add-Content -LiteralPath $logPath -Value $ingestText -Encoding Ascii
} else {
    Add-Content -LiteralPath $logPath -Value ("missing ingest translated requirements file: {0}" -f $ingestCondaReqPath) -Encoding Ascii
}

$ingestDryRunCommand = "`"$condaBat`" install --dry-run -n base --override-channels -c conda-forge --file `"$ingestCondaReqPath`""
try {
    $ingestDryRun = Invoke-CondaCommand -Command $ingestDryRunCommand -Label 'ingest conda dry-run' -LogPath $logPath
    $ingestDryRunOutput = $ingestDryRun.Output
    $ingestDryRunExit = $ingestDryRun.ExitCode
    $ingestDryRunDetails.exitCode = $ingestDryRunExit
    $ingestDryRunDetails.attempts = $ingestDryRun.Attempts
    if ($ingestDryRunOutput) {
        Add-Content -LiteralPath $logPath -Value 'ingest conda dry-run output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value $ingestDryRunOutput -Encoding Ascii
    }
} catch {
    $ingestDryRunDetails.exitCode = -1
    $ingestDryRunDetails.error = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("ingest conda dry-run exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}

if (-not (Test-Path -LiteralPath $smokeEnvPy)) {
    if ($uvWasUsed) {
        $ingestImportDetails.exitCode = 0
        $ingestImportDetails.installExitCode = 0
        $ingestImportDetails.importable = $true
        $ingestImportDetails.skip = $true
        $ingestImportDetails.reason = 'env-not-found (uv-mode)'
    } else {
        $overallPass = $false
        $ingestImportDetails.exitCode = -1
        $ingestImportDetails.installExitCode = -1
        $ingestImportDetails.importable = $false
        $ingestImportDetails.reason = 'env-not-found (unexpected)'
    }
} else {
$ingestInstallCommand = "`"$condaBat`" install -y -n _envsmoke --override-channels -c conda-forge `"six`""
try {
    $ingestInstallRun = Invoke-CondaCommand -Command $ingestInstallCommand -Label 'ingest conda install' -LogPath $logPath
    $ingestInstallOutput = $ingestInstallRun.Output
    $ingestInstallExit = $ingestInstallRun.ExitCode
    $ingestImportDetails.installExitCode = $ingestInstallExit
    $ingestImportDetails.installAttempts = $ingestInstallRun.Attempts
    if ($ingestInstallOutput) {
        Add-Content -LiteralPath $logPath -Value 'ingest conda install output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value $ingestInstallOutput -Encoding Ascii
    }
} catch {
    $ingestImportDetails.installExitCode = -1
    $ingestImportDetails.installError = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("ingest conda install exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}

$ingestImportCommand = "`"$condaBat`" run -n _envsmoke python -c `"import six`""
try {
    $ingestImportOutput = cmd /c $ingestImportCommand 2>&1
    $ingestImportExit = $LASTEXITCODE
    $ingestImportDetails.exitCode = $ingestImportExit
    $ingestImportDetails.importable = ($ingestImportExit -eq 0)
    if ($ingestImportOutput) {
        Add-Content -LiteralPath $logPath -Value 'ingest conda import output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value ($ingestImportOutput | Out-String) -Encoding Ascii
    }
} catch {
    $ingestImportDetails.exitCode = -1
    $ingestImportDetails.importable = $false
    $ingestImportDetails.importError = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("ingest conda import exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}
}

Write-ReqspecRows -Pass $overallPass -TranslationChecks $translationChecks -DryRunDetails $dryRunDetails -InstallDetails $installDetails -FailcaseDetails $failcaseDetails -ChannelPinDetails $channelPinDetails
Write-ReqspecIngestRows -TranslateDetails $ingestTranslateDetails -DryRunDetails $ingestDryRunDetails -ImportDetails $ingestImportDetails

if ($script:AnyRowFailed) { exit 1 }
exit 0
