# ASCII only
# selfapps_lineending_check.ps1 - CLAUDE.md Active Backlog Item 44's own "Known gap": the
# line-ending self-check at the very top of run_setup.bat (before any goto/call in the file)
# had zero CI coverage of its own three failure branches. A normal actions/checkout always
# normalizes to CRLF per .gitattributes, so CI exercises the happy path on real cmd.exe every
# run but can never organically produce a broken copy to test the failure branches against --
# hence the three HP_TEST_FORCE_* hooks this file drives.
#
# Each scenario redirects the check at something OTHER than the file actually executing right
# now (a synthetic LF-only sentinel file, or a path that does not exist) rather than corrupting
# the running copy of run_setup.bat itself -- the running copy must stay healthy CRLF so it can
# reliably reach and execute the hook logic in the first place. The PS-check-fail scenario
# deliberately does not fake an exit code either: pointing at a nonexistent path makes the real,
# unmodified PowerShell command genuinely throw (FileNotFoundException) and hit its own
# catch{exit 2} branch, exercising the real failure path rather than a simulated one.
#
# Extended for CLAUDE.md Active Backlog Item 48: the writable-CWD preflight (right after
# these three checks, before :merge_git_config's own first write to the app folder) is the
# same class of "can this even run here at all" precondition, so its own regression coverage
# lives here too rather than in a new file -- same Test-PreflightScenario helper, same
# real/conda-full lanes, same status.json/exit-code assertion shape. Its own hook,
# HP_TEST_FORCE_CWD_NOT_WRITABLE, skips the real `type nul > ~wtest.tmp` write attempt
# entirely rather than revoking filesystem permissions on a shared CI runner.
#
# Lane: real and conda-full only (matches self.preflight.syntax's own precedent for a cheap,
# provider-agnostic, pure-batch preflight check -- no environment/dependency work is ever
# reached in any of these four scenarios, so there is no "could not verify locally" risk
# comparable to a real Nuitka/MSVC build; the command logic itself was verified directly
# against a real PowerShell 7 binary before this file was written).
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

$rowIds = @('self.preflight.no_powershell', 'self.preflight.ps_check_fail', 'self.preflight.lf_only', 'self.preflight.cwd_not_writable')

# Non-Windows skip
# derived requirement: $IsWindows is undefined (reads as $null, so "-not $IsWindows" is
# always true) under Windows PowerShell 5.1 -- it was only introduced in PowerShell 6+.
# [System.Environment]::OSVersion.Platform works identically on 5.1 and 7+.
$platform = [System.Environment]::OSVersion.Platform.ToString()
if ($platform -ne 'Win32NT') {
    foreach ($id in $rowIds) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'CLAUDE.md-Item-44'
            pass    = $true
            desc    = 'Line-ending self-check preflight branch (skipped on non-Windows)'
            details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
        })
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($id in $rowIds) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'CLAUDE.md-Item-44'
            pass    = $false
            desc    = 'Line-ending self-check preflight branch: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    }
    exit 1
}

function Test-PreflightScenario {
    param(
        [string]$Id,
        [string]$WorkDirName,
        [string]$EnvFlagName,
        [int]$ExpectedExit,
        [string[]]$ExpectedSubstrings,
        [switch]$WriteLfOnlySentinel,
        [string]$Req = 'CLAUDE.md-Item-44'
    )

    $workDir = Join-Path $here $WorkDirName
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Copy-Item -Path $batchPath -Destination $workDir -Force

    if ($WriteLfOnlySentinel) {
        # derived requirement: pure LF, no CR anywhere, no BOM -- WriteAllText with an
        # explicit no-BOM UTF8Encoding is used instead of Set-Content, since Set-Content's
        # array-join would use the OS newline convention (CRLF on Windows) and defeat the
        # whole point of this sentinel file.
        $sentinelPath = Join-Path $workDir '~test_lf_only.bat'
        $sentinelBody = "@echo off`n:: synthetic LF-only content for HP_TEST_FORCE_LF_ONLY`n:: no CRLF anywhere in this file`n"
        [System.IO.File]::WriteAllText($sentinelPath, $sentinelBody, (New-Object System.Text.UTF8Encoding($false)))
    }

    $bootstrapLog = '~lineending_bootstrap.log'
    $prev = if (Test-Path "Env:$EnvFlagName") { (Get-Item "Env:$EnvFlagName").Value } else { $null }
    Set-Item -Path "Env:$EnvFlagName" -Value '1'

    Push-Location $workDir
    try {
        # derived requirement: redirect stdin from nul -- all three scenarios reach a
        # preflight-failure branch that calls `pause` when HP_CI_LANE is not defined; in CI
        # that branch is always skipped (HP_CI_LANE is set at the job level), but a local run
        # of this script without it set would otherwise hang on a real keypress despite
        # stdout/stderr already being redirected.
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1 < nul"
        $runExit = $LASTEXITCODE
    } finally {
        if ($null -eq $prev) {
            Remove-Item -Path "Env:$EnvFlagName" -ErrorAction SilentlyContinue
        } else {
            Set-Item -Path "Env:$EnvFlagName" -Value $prev
        }
        Pop-Location
    }

    $logPath = Join-Path $workDir $bootstrapLog
    $statusF = Join-Path $workDir '~bootstrap.status.json'
    $logTxt  = if (Test-Path $logPath) { Get-Content -LiteralPath $logPath -Raw -Encoding ASCII } else { '' }

    # derived requirement: plain .Contains(), not -like -- these expected substrings contain
    # literal [ and ] (e.g. "[ERROR]"), which -like's wildcard syntax treats as a character
    # class rather than literal brackets, silently making a genuine match report as absent.
    $allSubstringsFound = $true
    foreach ($s in $ExpectedSubstrings) {
        if (-not $logTxt.Contains($s)) { $allSubstringsFound = $false }
    }

    $state = ''
    $exitCodeInStatus = -1
    if (Test-Path $statusF) {
        try {
            $parsed = Get-Content -LiteralPath $statusF -Raw -Encoding ASCII | ConvertFrom-Json
            $state = $parsed.state
            $exitCodeInStatus = $parsed.exitCode
        } catch { $state = 'unparseable' }
    }

    $exitMatches = ($runExit -eq $ExpectedExit)
    $statusMatches = ($state -eq 'error') -and ($exitCodeInStatus -eq $ExpectedExit)
    $pass = $exitMatches -and $statusMatches -and $allSubstringsFound

    Write-NdjsonRow ([ordered]@{
        id      = $Id
        req     = $Req
        pass    = $pass
        desc    = "Preflight self-check branch: $EnvFlagName"
        details = [ordered]@{
            bootstrapExit       = $runExit
            expectedExit        = $ExpectedExit
            exitMatches         = $exitMatches
            statusState         = $state
            statusExitCode      = $exitCodeInStatus
            statusMatches       = $statusMatches
            allSubstringsFound  = $allSubstringsFound
            log                 = $bootstrapLog
        }
    })

    return $pass
}

$results = @()

$results += Test-PreflightScenario -Id 'self.preflight.no_powershell' `
    -WorkDirName '~selftest_lineending_no_ps' `
    -EnvFlagName 'HP_TEST_FORCE_NO_POWERSHELL' `
    -ExpectedExit 1 `
    -ExpectedSubstrings @('[ERROR] PowerShell was not found on this machine.')

$results += Test-PreflightScenario -Id 'self.preflight.ps_check_fail' `
    -WorkDirName '~selftest_lineending_ps_fail' `
    -EnvFlagName 'HP_TEST_FORCE_PS_CHECK_FAIL' `
    -ExpectedExit 2 `
    -ExpectedSubstrings @('[ERROR] PowerShell could not check the line endings of this file.')

$results += Test-PreflightScenario -Id 'self.preflight.lf_only' `
    -WorkDirName '~selftest_lineending_lf_only' `
    -EnvFlagName 'HP_TEST_FORCE_LF_ONLY' `
    -ExpectedExit 1 `
    -ExpectedSubstrings @('[ERROR] This copy of run_setup.bat has invalid line endings.', 'Easiest fix: delete this copy and download run_setup.bat again') `
    -WriteLfOnlySentinel

$results += Test-PreflightScenario -Id 'self.preflight.cwd_not_writable' `
    -WorkDirName '~selftest_lineending_cwd_not_writable' `
    -EnvFlagName 'HP_TEST_FORCE_CWD_NOT_WRITABLE' `
    -ExpectedExit 1 `
    -ExpectedSubstrings @('[ERROR] This folder does not appear to be writable:', 'Move this script and your .py files to') `
    -Req 'CLAUDE.md-Item-48'

if ($results -contains $false) { exit 1 }
exit 0
