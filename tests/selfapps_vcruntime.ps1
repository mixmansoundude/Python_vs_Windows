# ASCII only
# selfapps_vcruntime.ps1 - CLAUDE.md Active Backlog Item 77: a "DLL load failed" run on a machine without
# Microsoft's Visual C++ runtime must say what the runtime is and where to get it.
#
# Field symptom (2026-10-09, a clean Windows image): "ImportError: DLL load failed while importing _extra:
# The specified module could not be found." for pymupdf. Windows never names the missing DLL; the wheel's
# mupdfcpp64.dll needs msvcp140.dll and vcruntime140_1.dll, which a clean Windows install does not have.
# The bootstrapper said nothing about it. It now prints a [WARN] when BOTH hold: the run printed
# "DLL load failed", and System32 lacks msvcp140.dll or vcruntime140_1.dll. It never installs the runtime.
#
# CI runners have the runtime, so the missing-runtime half is simulated with HP_TEST_VCRT_MISSING=1 (absent
# means the real System32 check, README REQ-019). Everything else is real: the fixture raises the exact
# message the field run printed, the bootstrapper runs it, the batch scans the captured output.
#
#   self.vcruntime.warn.interp         - no-EXE path, legacy (non-interactive) verification run
#   self.vcruntime.warn.interp_probe   - no-EXE path, the fail-fast probe a double-click user gets
#   self.vcruntime.warn.exe            - a real PyInstaller EXE fails with the DLL text
#   self.vcruntime.warn.runtime_present - no simulation: the warning appears only if this runner really
#                                         lacks the runtime (it does not), so the expected outcome is
#                                         derived from the files, not assumed
#   self.vcruntime.warn.unrelated_error - simulation on, but the failure is not a DLL error: no warning
#
# Lane: real only (gating). The first two rows and the last two force the PyInstaller build to fail so
# the interpreter runs the program; only "exe" pays for a real EXE build.
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
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{ id = 'self.vcruntime.warn.interp'; req = 'REQ-018.32'; pass = $true; desc = 'VC++ runtime warning (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.vcruntime.warn.interp_probe'; req = 'REQ-018.32'; pass = $true; desc = 'VC++ runtime warning (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.vcruntime.warn.exe'; req = 'REQ-018.32'; pass = $true; desc = 'VC++ runtime warning (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.vcruntime.warn.runtime_present'; req = 'REQ-018.32'; pass = $true; desc = 'VC++ runtime warning (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.vcruntime.warn.unrelated_error'; req = 'REQ-018.32'; pass = $true; desc = 'VC++ runtime warning (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id = 'self.vcruntime.warn.interp'; req = 'REQ-018.32'; pass = $false
        desc = 'VC++ runtime warning: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$sys32 = Join-Path $env:SystemRoot 'System32'
$runnerMissing = @('msvcp140.dll', 'vcruntime140_1.dll' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $sys32 $_)) })

# The exact text the field run printed, as a real Python traceback.
$dllFixture = @'
raise ImportError("DLL load failed while importing _extra: The specified module could not be found.")
'@
$plainFixture = @'
import sys
print("plain-failure")
sys.exit(3)
'@

# Run one scenario in its own scratch folder. $envMap is name -> value; every name is restored afterwards.
function Invoke-Scenario {
    param([string]$Name, [string]$AppText, [hashtable]$EnvMap)
    $workDir = Join-Path $here "~selftest_vcruntime_$Name"
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Copy-Item -Path $batchPath -Destination $workDir -Force
    Set-Content -Path (Join-Path $workDir 'app.py') -Value $AppText -Encoding ASCII
    $logName = "~vcruntime_${Name}_bootstrap.log"
    $saved = @{}
    foreach ($k in $EnvMap.Keys) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $EnvMap[$k])
    }
    $exit = $null
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $logName 2>&1"
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($k in $EnvMap.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $logPath = Join-Path $workDir $logName
    $text = if (Test-Path $logPath) { Get-Content -LiteralPath $logPath -Raw -Encoding ASCII } else { '' }
    # The program's own stderr, as the bootstrapper captured it (the legacy branch keeps it off the console).
    $errPath = Join-Path $workDir '~run.err.txt'
    $runErr = if (Test-Path $errPath) { Get-Content -LiteralPath $errPath -Raw -Encoding ASCII } else { '' }
    return [pscustomobject]@{ Text = $text; RunErr = $runErr; Exit = $exit; Log = $logName }
}

# Facts about one console log: how many VC++ warnings, and whether the warning is complete.
$warnPattern = '\[WARN\][^\r\n]*Visual C\+\+ runtime'
function Get-WarnFacts {
    param([string]$Text, [string[]]$ExpectedFiles)
    $count = ([regex]::Matches($Text, $warnPattern)).Count
    $line = ([regex]::Match($Text, '\[WARN\][^\r\n]*Visual C\+\+ runtime[^\r\n]*')).Value
    return [ordered]@{
        count       = $count
        link        = ($line -match [regex]::Escape('https://aka.ms/vc14/vc_redist.x64.exe'))
        names       = (@($ExpectedFiles | Where-Object { $line -notmatch [regex]::Escape($_) }).Count -eq 0)
        notInstalled = ($line -match 'not install')
    }
}

$forceFail = @{ HP_SKIP_PIPREQS = '1'; HP_TEST_FORCE_PYINSTALLER_FAIL = '1'; HP_TEST_FORCE_NUITKA_FAIL = '1' }
$simBoth = @('msvcp140.dll', 'vcruntime140_1.dll')

# --- interp: no-EXE path, legacy verification run -------------------------------------------------
$envA = @{} + $forceFail; $envA['HP_TEST_VCRT_MISSING'] = '1'
$a = Invoke-Scenario -Name 'interp' -AppText $dllFixture -EnvMap $envA
$aFacts = Get-WarnFacts -Text $a.Text -ExpectedFiles $simBoth
$aRan = ($a.RunErr -match 'DLL load failed while importing _extra') -and ($a.Text -match 'Entry smoke exit=')
$aPass = [bool]($aRan -and $aFacts.count -eq 1 -and $aFacts.link -and $aFacts.names -and $aFacts.notInstalled)
Write-NdjsonRow ([ordered]@{
    id = 'self.vcruntime.warn.interp'; req = 'REQ-018.32'
    pass = $aPass
    desc = 'A DLL load failure in the interpreter run prints the Visual C++ runtime warning once, with the link'
    details = [ordered]@{ programRan = $aRan; warn = $aFacts; exit = $a.Exit; log = $a.Log }
})

# --- interp_probe: no-EXE path, the fail-fast probe a double-click user gets ----------------------
$envB = @{} + $forceFail; $envB['HP_TEST_VCRT_MISSING'] = '1'; $envB['HP_TEST_FORCE_INTERACTIVE_PROBE'] = '1'
$b = Invoke-Scenario -Name 'interp_probe' -AppText $dllFixture -EnvMap $envB
$bFacts = Get-WarnFacts -Text $b.Text -ExpectedFiles $simBoth
$bRan = ($b.RunErr -match 'DLL load failed while importing _extra') -and ($b.Text -match 'Launching your program now')
$bPass = [bool]($bRan -and $bFacts.count -eq 1 -and $bFacts.link -and $bFacts.names -and $bFacts.notInstalled)
Write-NdjsonRow ([ordered]@{
    id = 'self.vcruntime.warn.interp_probe'; req = 'REQ-018.32'
    pass = $bPass
    desc = 'A DLL load failure under the fail-fast probe prints the Visual C++ runtime warning once, with the link'
    details = [ordered]@{ programRan = $bRan; warn = $bFacts; exit = $b.Exit; log = $b.Log }
})

# --- exe: a real PyInstaller EXE fails with the DLL text ------------------------------------------
$envC = @{ HP_SKIP_PIPREQS = '1'; HP_TEST_VCRT_MISSING = '1' }
$c = Invoke-Scenario -Name 'exe' -AppText $dllFixture -EnvMap $envC
$cFacts = Get-WarnFacts -Text $c.Text -ExpectedFiles $simBoth
$cRan = ($c.RunErr -match 'DLL load failed while importing _extra') -and ($c.Text -match 'Run Status: FAILED')
$cBuilt = ($c.Text -match 'Running entry script smoke test via packaged EXE') -and (-not ($c.Text -match 'PyInstaller execution failed'))
$cPass = [bool]($cRan -and $cBuilt -and $cFacts.count -eq 1 -and $cFacts.link -and $cFacts.names -and $cFacts.notInstalled)
Write-NdjsonRow ([ordered]@{
    id = 'self.vcruntime.warn.exe'; req = 'REQ-018.32'
    pass = $cPass
    desc = 'A DLL load failure in the built EXE prints the Visual C++ runtime warning once, with the link'
    details = [ordered]@{ programRan = $cRan; exeBuilt = $cBuilt; warn = $cFacts; exit = $c.Exit; log = $c.Log }
})

# --- runtime_present: no simulation; expected outcome derived from the runner's own System32 ------
$d = Invoke-Scenario -Name 'present' -AppText $dllFixture -EnvMap $forceFail
$dFacts = Get-WarnFacts -Text $d.Text -ExpectedFiles $runnerMissing
$dRan = ($d.RunErr -match 'DLL load failed while importing _extra') -and ($d.Text -match 'Entry smoke exit=')
$dExpectWarn = ($runnerMissing.Count -gt 0)
$dPass = $dRan -and (($dExpectWarn -and $dFacts.count -eq 1 -and $dFacts.link) -or ((-not $dExpectWarn) -and $dFacts.count -eq 0))
Write-NdjsonRow ([ordered]@{
    id = 'self.vcruntime.warn.runtime_present'; req = 'REQ-018.32'
    pass = [bool]$dPass
    desc = 'Without the simulation, the warning appears exactly when System32 really lacks the runtime'
    details = [ordered]@{ programRan = $dRan; runnerMissing = @($runnerMissing); expectWarn = $dExpectWarn; warn = $dFacts; exit = $d.Exit; log = $d.Log }
})

# --- unrelated_error: simulation on, failure is not a DLL error -----------------------------------
$envE = @{} + $forceFail; $envE['HP_TEST_VCRT_MISSING'] = '1'
$e = Invoke-Scenario -Name 'unrelated' -AppText $plainFixture -EnvMap $envE
$eFacts = Get-WarnFacts -Text $e.Text -ExpectedFiles $simBoth
$eRan = ($e.Text -match 'Entry smoke exit=3')
$ePass = [bool]($eRan -and $eFacts.count -eq 0)
Write-NdjsonRow ([ordered]@{
    id = 'self.vcruntime.warn.unrelated_error'; req = 'REQ-018.32'
    pass = $ePass
    desc = 'A failure that is not a DLL load error does not print the Visual C++ runtime warning'
    details = [ordered]@{ programRan = $eRan; warn = $eFacts; exit = $e.Exit; log = $e.Log }
})

# Item 84: a script run by a CI step ends with its own exit code, or the last native command's code leaks into the job.
if (-not ($aPass -and $bPass -and $cPass -and $dPass -and $ePass)) { exit 1 }
exit 0
