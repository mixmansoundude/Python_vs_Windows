# ASCII only
# selfapps_runtime_install.ps1 - CLAUDE.md Item 65 slice 2 (README REQ-018): the consented install
# of a package a program asked for at run time.
#
# Slice 1 only names the module. Slice 2 (decided 2026-10-09, option B) asks ONCE before any install,
# requirements edit or rebuild. A yes covers all of them plus one more run to check; a no changes
# nothing. The fixture is the one slice 1 uses: it catches the ImportError for xlsxwriter itself,
# prints the traceback to stderr and exits 0, with the module name built at run time so neither
# pipreqs nor PyInstaller sees the import. After a yes, the rebuilt EXE only finds the package
# because the rebuild passes --hidden-import, so the check run passing proves that flag was used.
#
# Rows: self.runtime.install.accept, self.runtime.install.decline and self.runtime.install.pyproject,
# one real bootstrap each. The third proves that when pyproject.toml is the dependency source a yes still
# installs and verifies, but leaves pyproject.toml alone and says so (pyproject dependencies are copied over
# requirements.txt on every run, so an appended line would be lost; CodeRabbit finding on PR #487).
# The answer comes from HP_TEST_RTM_ANSWER, the test override of the prompt. Each row first proves
# its precondition (the first run exited 0 and its stderr held the traceback), so a fixture that
# stops reproducing the symptom cannot make a row pass or fail vacuously. HP_NDJSON points at a
# private file per scenario so the bootstrapper's own rows do not land in the lane artifact.
#
# Lane: real only (uv provider; the install and the environment check use .uv_env).
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

# Non-Windows skip (parity with other selfapps tests).
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.install.accept'
        req     = 'REQ-018'
        pass    = $true
        desc    = 'a yes installs the package, rebuilds and verifies (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.install.decline'
        req     = 'REQ-018'
        pass    = $true
        desc    = 'a no changes nothing (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.install.accept'
        req     = 'REQ-018'
        pass    = $false
        desc    = 'runtime install: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

# The module name is joined at run time: a literal import_module("xlsxwriter") could be seen by a
# future static scan and installed up front, which would remove the failure this test needs.
$appCode = @'
import importlib
import traceback


def on_click():
    # Stand-in for a GUI callback: the exception is caught, its traceback goes to stderr, and the
    # program carries on and exits 0.
    name = "".join(("xlsx", "writer"))
    try:
        importlib.import_module(name)
    except ImportError:
        traceback.print_exc()


if __name__ == "__main__":
    on_click()
    print("runtime app ok")
'@

# Runs one bootstrap of the fixture with the given answer and returns everything the rows need.
function Invoke-InstallScenario {
    param([string]$Name, [string]$Answer, [switch]$Pyproject)
    $workDir = Join-Path $here ('~selftest_runtime_install_' + $Name)
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Copy-Item -Path $batchPath -Destination $workDir -Force
    Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII
    $pyprojText = ''
    if ($Pyproject) {
        $pyprojText = "[project]`r`nname = `"runtimeapp`"`r`nversion = `"0.1.0`"`r`ndependencies = [`"six`"]`r`n"
        [System.IO.File]::WriteAllText((Join-Path $workDir 'pyproject.toml'), $pyprojText, (New-Object System.Text.ASCIIEncoding))
    }

    $bootstrapLog = '~install_' + $Name + '_bootstrap.log'
    $subNdjson    = Join-Path $workDir '~sub.ndjson'
    $savedNdjson  = [Environment]::GetEnvironmentVariable('HP_NDJSON')
    $savedAnswer  = [Environment]::GetEnvironmentVariable('HP_TEST_RTM_ANSWER')
    Push-Location $workDir
    try {
        [Environment]::SetEnvironmentVariable('HP_NDJSON', $subNdjson)
        [Environment]::SetEnvironmentVariable('HP_TEST_RTM_ANSWER', $Answer)
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('HP_NDJSON', $savedNdjson)
        [Environment]::SetEnvironmentVariable('HP_TEST_RTM_ANSWER', $savedAnswer)
        Pop-Location
    }

    $logPath   = Join-Path $workDir $bootstrapLog
    $setupLog  = Join-Path $workDir '~setup.log'
    $errPath   = Join-Path $workDir '~run.err.txt'
    $outPath   = Join-Path $workDir '~run.out.txt'
    $reqPath   = Join-Path $workDir 'requirements.txt'
    $pyPath    = Join-Path $workDir '.uv_env\Scripts\python.exe'
    $console   = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Raw -Encoding ASCII } else { '' }
    $setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
    $errText   = if (Test-Path $errPath)  { Get-Content -LiteralPath $errPath  -Raw -Encoding ASCII } else { '' }
    $outText   = if (Test-Path $outPath)  { Get-Content -LiteralPath $outPath  -Raw -Encoding ASCII } else { '' }
    $reqText   = if (Test-Path $reqPath)  { Get-Content -LiteralPath $reqPath  -Raw -Encoding ASCII } else { '' }

    $envHasModule = $false
    if (Test-Path $pyPath) {
        & $pyPath -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('xlsxwriter') else 1)" 2>$null
        $envHasModule = ($LASTEXITCODE -eq 0)
    }

    $rows = @()
    if (Test-Path -LiteralPath $subNdjson) {
        foreach ($line in (Get-Content -LiteralPath $subNdjson -Encoding ASCII)) {
            if (-not $line.Trim()) { continue }
            try { $rows += ($line | ConvertFrom-Json) } catch { continue }
        }
    }
    $pyprojAfter = ''
    $pyprojPath = Join-Path $workDir 'pyproject.toml'
    if (Test-Path -LiteralPath $pyprojPath) { $pyprojAfter = [System.IO.File]::ReadAllText($pyprojPath) }
    $installRow = $rows | Where-Object { $_.id -eq 'self.runtime.install' } | Select-Object -First 1
    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    $statusState = $null
    if (Test-Path -LiteralPath $statusPath) {
        try { $statusState = (Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { $statusState = $null }
    }

    [pscustomobject]@{
        RunExit        = $runExit
        Console        = $console
        SetupText      = $setupText
        ErrText        = $errText
        OutText        = $outText
        ReqText        = $reqText
        EnvHasModule   = $envHasModule
        ExeExists      = (Test-Path (Join-Path $workDir 'dist'))
        InstallState   = if ($installRow) { [string]$installRow.details.state } else { $null }
        InstallSite    = if ($installRow) { [string]$installRow.details.site } else { $null }
        InstallPkgs    = if ($installRow) { [string]$installRow.details.packages } else { $null }
        StatusState    = $statusState
        PyprojectBefore = $pyprojText
        PyprojectAfter  = $pyprojAfter
        InstallDepSource = if ($installRow) { [string]$installRow.details.depSource } else { $null }
        SmokeRuns      = ([regex]::Matches($setupText, 'Entry smoke exit=')).Count
    }
}

# ---- accept: a yes installs, adds to requirements.txt, rebuilds with --hidden-import, checks ----
$a = Invoke-InstallScenario -Name 'accept' -Answer 'Y'
$aFirstRunTrace = $a.SetupText -match 'Your program needed the module xlsxwriter'
$aPrompted      = $a.Console -match 'asked for packages that are not installed'
$aInstalled     = $a.SetupText -match 'Runtime install: installed xlsxwriter'
$aReqLine       = $a.ReqText -match '(?m)^\s*xlsxwriter\s*$'
$aRebuilt       = $a.SetupText -match '\[REPAIR\] rebuild complete after runtime install'
$aVerified      = $a.SetupText -match 'Runtime install: verified'
$aCheckClean    = ($a.ErrText -notmatch 'No module named') -and ($a.OutText -match 'runtime app ok')
$aRan2          = $a.SmokeRuns -ge 2
$aPass = ($a.RunExit -eq 0) -and $aFirstRunTrace -and $aPrompted -and $aInstalled -and $a.EnvHasModule -and
         $aReqLine -and $aRebuilt -and $aVerified -and $aCheckClean -and $aRan2 -and
         ($a.InstallState -eq 'verified') -and ($a.InstallSite -eq 'exe') -and ($a.InstallPkgs -eq 'xlsxwriter') -and
         ($a.StatusState -eq 'ok')
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.install.accept'
    req     = 'REQ-018'
    pass    = $aPass
    desc    = 'a yes installs the missing package, adds it to requirements.txt, rebuilds the EXE with it and the check run is clean'
    details = [ordered]@{
        exitCode        = $a.RunExit
        firstRunTrace   = $aFirstRunTrace
        prompted        = $aPrompted
        installed       = $aInstalled
        envHasModule    = $a.EnvHasModule
        requirementsLine = $aReqLine
        rebuilt         = $aRebuilt
        verified        = $aVerified
        checkRunClean   = $aCheckClean
        smokeRuns       = $a.SmokeRuns
        rowState        = $a.InstallState
        rowSite         = $a.InstallSite
        rowPackages     = $a.InstallPkgs
        statusState     = $a.StatusState
    }
})

# ---- decline: a no changes nothing and runs nothing again ----
$d = Invoke-InstallScenario -Name 'decline' -Answer 'N'
$dFirstRunTrace = $d.SetupText -match 'Your program needed the module xlsxwriter'
$dPrompted      = $d.Console -match 'asked for packages that are not installed'
$dDeclined      = $d.SetupText -match 'Runtime install: declined'
$dNothingAdded  = ($d.ReqText -notmatch 'xlsxwriter') -and (-not $d.EnvHasModule)
$dOneRun        = $d.SmokeRuns -eq 1
$dStillWarned   = $d.Console -match 'asked for modules that are not installed'
$dPass = ($d.RunExit -eq 0) -and $dFirstRunTrace -and $dPrompted -and $dDeclined -and $dNothingAdded -and
         $dOneRun -and $dStillWarned -and ($d.InstallState -eq 'declined') -and ($d.StatusState -eq 'ok')
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.install.decline'
    req     = 'REQ-018'
    pass    = $dPass
    desc    = 'a no installs nothing, edits no requirements file, does not run the program again and still reports the module'
    details = [ordered]@{
        exitCode      = $d.RunExit
        firstRunTrace = $dFirstRunTrace
        prompted      = $dPrompted
        declined      = $dDeclined
        nothingAdded  = $dNothingAdded
        envHasModule  = $d.EnvHasModule
        smokeRuns     = $d.SmokeRuns
        stillWarned   = $dStillWarned
        rowState      = $d.InstallState
        statusState   = $d.StatusState
    }
})

# ---- pyproject: a yes installs and verifies, but pyproject.toml is not edited and the user is told ----
$p = Invoke-InstallScenario -Name 'pyproject' -Answer 'Y' -Pyproject
$pSource        = $p.SetupText -match 'DEP_SOURCE=pyproject'
$pFirstRunTrace = $p.SetupText -match 'Your program needed the module xlsxwriter'
$pPromptNamesIt = $p.Console -match 'does not edit \*+\s+\*+ the dependencies in pyproject\.toml'
$pPromptNoReq   = $p.Console -notmatch 'adds them to this program.s own environment and to requirements\.txt'
$pInstalled     = $p.SetupText -match 'Runtime install: installed xlsxwriter'
$pNotEdited     = $p.SetupText -match 'Runtime install: did not edit the dependencies in pyproject\.toml'
$pUntouched     = ($p.PyprojectAfter -ceq $p.PyprojectBefore) -and ($p.PyprojectAfter -notmatch 'xlsxwriter')
$pReqNotAdded   = $p.ReqText -notmatch 'xlsxwriter'
$pVerified      = $p.SetupText -match 'Runtime install: verified'
$pCheckClean    = ($p.ErrText -notmatch 'No module named') -and ($p.OutText -match 'runtime app ok')
$pPass = ($p.RunExit -eq 0) -and $pSource -and $pFirstRunTrace -and $pPromptNamesIt -and $pPromptNoReq -and
         $pInstalled -and $p.EnvHasModule -and $pNotEdited -and $pUntouched -and $pReqNotAdded -and
         $pVerified -and $pCheckClean -and
         ($p.InstallState -eq 'verified') -and ($p.InstallDepSource -eq 'pyproject') -and ($p.StatusState -eq 'ok')
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.install.pyproject'
    req     = 'REQ-018'
    pass    = $pPass
    desc    = 'with pyproject.toml as the dependency source a yes installs and verifies, leaves pyproject.toml untouched and says so'
    details = [ordered]@{
        exitCode         = $p.RunExit
        sourceIsPyproject = $pSource
        firstRunTrace    = $pFirstRunTrace
        promptNamesPyproject = $pPromptNamesIt
        promptDoesNotPromiseRequirements = $pPromptNoReq
        installed        = $pInstalled
        envHasModule     = $p.EnvHasModule
        saidNotEdited    = $pNotEdited
        pyprojectUntouched = $pUntouched
        requirementsGotIt = (-not $pReqNotAdded)
        verified         = $pVerified
        checkRunClean    = $pCheckClean
        rowState         = $p.InstallState
        rowDepSource     = $p.InstallDepSource
        statusState      = $p.StatusState
    }
})

if (-not ($aPass -and $dPass -and $pPass)) { exit 1 }
exit 0
