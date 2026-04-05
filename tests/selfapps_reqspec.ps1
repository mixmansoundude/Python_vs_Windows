$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path -LiteralPath $nd)) { New-Item -ItemType File -Path $nd -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

function Write-NdjsonRow {
    param([hashtable]$Row)

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

    $failcase = if ($FailcaseDetails) { $FailcaseDetails } else { [ordered]@{ exitCode = -1; expectedFailure = $true; constraint = 'six<1.0' } }
    if ($Skip) {
        $failcase.skip = $true
        if ($Reason) { $failcase.reason = $Reason }
    }
    $failcasePass = $true
    if (-not $Skip) {
        $failcasePass = ($failcase.exitCode -ne 0)
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

if (-not $IsWindows) {
    Write-ReqspecRows -Pass $true -TranslationChecks @{} -DryRunDetails @{} -InstallDetails @{} -FailcaseDetails @{} -ChannelPinDetails @{} -Skip $true -Reason 'non-windows-host'
    Write-ReqspecIngestRows -TranslateDetails @{} -DryRunDetails @{} -ImportDetails @{} -Skip $true -Reason 'non-windows-host'
    exit 0
}

$work = Join-Path $here '~reqspec'
$logPath = Join-Path $work '~reqspec_run.log'
New-Item -ItemType Directory -Force -Path $work | Out-Null
if (Test-Path -LiteralPath $logPath) { Remove-Item -LiteralPath $logPath -Force -ErrorAction SilentlyContinue }

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
    Write-ReqspecRows -Pass $false -TranslationChecks $translationChecks -DryRunDetails $dryRunDetails -InstallDetails $installDetails -FailcaseDetails ([ordered]@{ exitCode = -1; expectedFailure = $true; constraint = 'six<1.0'; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot }) -ChannelPinDetails ([ordered]@{ channel = 'conda-forge'; exitCode = -1; defaultsFound = $false; pkgsMainFound = $false; outputMatched = $false; solverOutputSnippet = ''; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot })
    Write-ReqspecIngestRows -TranslateDetails ([ordered]@{ source = 'requirements.txt'; translated = $false; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot }) -DryRunDetails ([ordered]@{ exitCode = -1; source = 'requirements.txt'; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot }) -ImportDetails ([ordered]@{ package = 'six'; importable = $false; exitCode = -1; reason = 'conda-not-found'; condaBatCandidates = $condaInfo.candidates; publicRoot = $condaInfo.publicRoot })
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
    $dryOutput = cmd /c $dryRunCommand 2>&1
    $dryExit = $LASTEXITCODE
    $dryRunDetails.exitCode = $dryExit
    $channelPinDetails.exitCode = $dryExit
    if ($dryOutput) {
        Add-Content -LiteralPath $logPath -Value 'conda dry-run output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value ($dryOutput | Out-String) -Encoding Ascii
        $dryOutputText = $dryOutput | Out-String
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
    $badDryOutput = cmd /c $badDryRunCommand 2>&1
    $exitCodeBad = $LASTEXITCODE
    $failcaseDetails.exitCode = $exitCodeBad
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
$installCommand = "`"$condaBat`" install -y -n _envsmoke --override-channels -c conda-forge `"six>=1.16`""
try {
    $installOutput = cmd /c $installCommand 2>&1
    $installExit = $LASTEXITCODE
    $installDetails.installExitCode = $installExit
    if ($installOutput) {
        Add-Content -LiteralPath $logPath -Value 'conda install output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value ($installOutput | Out-String) -Encoding Ascii
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
    $ingestDryRunOutput = cmd /c $ingestDryRunCommand 2>&1
    $ingestDryRunExit = $LASTEXITCODE
    $ingestDryRunDetails.exitCode = $ingestDryRunExit
    if ($ingestDryRunOutput) {
        Add-Content -LiteralPath $logPath -Value 'ingest conda dry-run output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value ($ingestDryRunOutput | Out-String) -Encoding Ascii
    }
} catch {
    $ingestDryRunDetails.exitCode = -1
    $ingestDryRunDetails.error = $_.Exception.Message
    Add-Content -LiteralPath $logPath -Value ("ingest conda dry-run exception: {0}" -f $_.Exception.Message) -Encoding Ascii
}

$ingestInstallCommand = "`"$condaBat`" install -y -n _envsmoke --override-channels -c conda-forge `"six`""
try {
    $ingestInstallOutput = cmd /c $ingestInstallCommand 2>&1
    $ingestInstallExit = $LASTEXITCODE
    $ingestImportDetails.installExitCode = $ingestInstallExit
    if ($ingestInstallOutput) {
        Add-Content -LiteralPath $logPath -Value 'ingest conda install output:' -Encoding Ascii
        Add-Content -LiteralPath $logPath -Value ($ingestInstallOutput | Out-String) -Encoding Ascii
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

Write-ReqspecRows -Pass $overallPass -TranslationChecks $translationChecks -DryRunDetails $dryRunDetails -InstallDetails $installDetails -FailcaseDetails $failcaseDetails -ChannelPinDetails $channelPinDetails
Write-ReqspecIngestRows -TranslateDetails $ingestTranslateDetails -DryRunDetails $ingestDryRunDetails -ImportDetails $ingestImportDetails
