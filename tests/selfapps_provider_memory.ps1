# ASCII only
# selfapps_provider_memory.ps1 - CLAUDE.md Item 66 (README REQ-009): the provider memory file and the PVW_PROVIDER switch.
#
# Item 66, decided 2026-10-17 (Q11, option A): after a run that only worked once the cascade reached conda, the
# bootstrapper writes ~provider.state.json, and the next run starts at conda instead of redoing all of uv's work.
# The file survives edits to the program's inputs; it is cleared only when Miniconda is gone or the user deletes it,
# and every run that uses it says so and how to reset it. PVW_PROVIDER=conda (super user) forces conda for one run
# and writes nothing. Each scenario is one real bootstrap of a standard-library fixture; the row asserts the
# reason it passes (log lines, files, status), not only the exit code.
#
# Group "real" (lane real, GATING, no download beyond what every uv bootstrap does):
#   self.provider.unset           no switch, no file: the normal uv run, nothing about memory in any output, and a
#                                 plain uv pass writes no memory file
#   self.provider.invalid         a PVW_PROVIDER value other than conda (wrong case, another name, a hostile string)
#                                 stops the run with one error, before any uv or conda work, and the value is never
#                                 echoed
#   self.provider.miniconda_gone  the file says conda but Miniconda is not installed: the file is cleared with a
#                                 visible line and the normal order runs
#   self.provider.unreadable      a file this bootstrapper cannot read is ignored with a warning, the normal order runs
#   self.provider.fastpath        a valid cached EXE is reused before provider selection, so PVW_PROVIDER=conda
#                                 changes nothing for that run
# Group "uv" (lane uv, non-gating: they download Miniconda and solve a conda environment, which can fail for
# transient network or provider reasons; flagged in the PR):
#   self.provider.forced          PVW_PROVIDER=conda with Miniconda not yet installed, an existing .uv_env and an
#                                 exact patch pin left in runtime.txt by the earlier uv run: conda is acquired and
#                                 used, the uv venv is not reused, the stale pin is ignored, nothing is written
#   self.provider.remember        run 1 reaches conda through the cascade and writes the file; run 2, after the
#                                 inputs were edited, starts at conda, says so, and skips uv
#   self.provider.forced_stop     PVW_PROVIDER=conda with a Python version conda cannot give: the run stops at
#                                 conda with a hint, no other provider is tried
#
# The group comes from PROVIDER_GROUP (real or uv); unset runs both. Windows only.
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

$group = [Environment]::GetEnvironmentVariable('PROVIDER_GROUP')
if (-not $group) { $group = 'all' }
$runReal = ($group -eq 'real') -or ($group -eq 'all')
$runUv   = ($group -eq 'uv')   -or ($group -eq 'all')

# Non-Windows skip (parity with other selfapps tests).
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.unset'
        req     = 'REQ-009'
        pass    = $true
        desc    = 'provider memory and PVW_PROVIDER (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.unset'
        req     = 'REQ-009'
        pass    = $false
        desc    = 'provider memory: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

# ---- fixtures: standard library only, so no dependency step can interfere ----
$appOk = @'
print("provider app ok")
'@

# Fails unless the provider is conda (the bootstrapper's HP_ENV_MODE is inherited by every run it starts).
$appCondaOnly = @'
import os
import sys

if os.environ.get("HP_ENV_MODE", "") == "conda":
    print("conda tier run")
    sys.exit(0)
print("Traceback (most recent call last):", file=sys.stderr)
print("RuntimeError: this provider cannot run the program", file=sys.stderr)
sys.exit(3)
'@

$stateConda = '{"version":1,"provider":"conda","passType":"exe_ok","cascadedFrom":"uv"}'

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::ASCII) }
    return ''
}

# Runs one bootstrap in <tests>\~selftest_provider_<Name>. A new folder gets a copy of run_setup.bat and app.py;
# -Reuse runs again in the folder left by the previous call. $Files maps a relative name to the text written
# before the run. Console and setup-log text are THIS run's only (the setup log is appended across runs).
function Invoke-Provider {
    param([string]$Name, [string]$AppCode = $null, [hashtable]$EnvVars = @{}, [hashtable]$Files = @{},
          [switch]$Reuse, [string]$Tag = 'run')
    $workDir = Join-Path $here ('~selftest_provider_' + $Name)
    if (-not $Reuse) {
        if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
        New-Item -ItemType Directory -Force -Path $workDir | Out-Null
        Copy-Item -Path $batchPath -Destination $workDir -Force
    }
    if ($AppCode) { Set-Content -Path (Join-Path $workDir 'app.py') -Value $AppCode -Encoding ASCII }
    foreach ($f in $Files.Keys) {
        [System.IO.File]::WriteAllText((Join-Path $workDir $f), [string]$Files[$f], (New-Object System.Text.ASCIIEncoding))
    }
    $setupPath = Join-Path $workDir '~setup.log'
    $before = (Read-Text $setupPath).Length
    $bootstrapLog = '~pv_' + $Tag + '_bootstrap.log'
    $names = @($EnvVars.Keys)
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    Push-Location $workDir
    try {
        foreach ($k in $EnvVars.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$EnvVars[$k]) }
        cmd /c "call run_setup.bat < nul > $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        Pop-Location
    }
    $setupAll = Read-Text $setupPath
    $setupRun = if ($setupAll.Length -ge $before) { $setupAll.Substring($before) } else { $setupAll }
    $console  = Read-Text (Join-Path $workDir $bootstrapLog)
    $statusText = Read-Text (Join-Path $workDir '~bootstrap.status.json')
    $statePath = Join-Path $workDir '~provider.state.json'
    $exeFiles = @()
    $distDir = Join-Path $workDir 'dist'
    if (Test-Path -LiteralPath $distDir) { $exeFiles = @(Get-ChildItem -LiteralPath $distDir -Filter '*.exe' -ErrorAction SilentlyContinue) }
    [pscustomobject]@{
        WorkDir    = $workDir
        RunExit    = $runExit
        Console    = $console
        SetupText  = $setupRun
        Status     = $(if ($statusText -match '"state":"([a-z_]+)"') { $Matches[1] } else { '' })
        StateFile  = $(if (Test-Path -LiteralPath $statePath) { (Read-Text $statePath).Trim() } else { $null })
        RuntimeTxt = $(if (Test-Path -LiteralPath (Join-Path $workDir 'runtime.txt')) { (Read-Text (Join-Path $workDir 'runtime.txt')).Trim() } else { $null })
        Sidecar    = $(if (Test-Path -LiteralPath (Join-Path $workDir '~runtime_writeback.txt')) { (Read-Text (Join-Path $workDir '~runtime_writeback.txt')).Trim() } else { $null })
        UvEnv      = (Test-Path -LiteralPath (Join-Path $workDir '.uv_env'))
        UvBin      = (Test-Path -LiteralPath (Join-Path $workDir '~uv_bin'))
        ExeBuilt   = ($exeFiles.Count -gt 0)
        TopNames   = @(Get-ChildItem -LiteralPath $workDir -Force | Where-Object { $_.Name -notlike '~*' } | ForEach-Object { $_.Name } | Sort-Object)
    }
}

# A Windows path that cannot hold a Miniconda: used as PUBLIC, which the bootstrapper turns into
# %PUBLIC%\Documents\Miniconda3. Nothing is installed there unless the run installs it.
function New-PublicDir {
    param([string]$Label)
    $p = Join-Path ([System.IO.Path]::GetTempPath()) ('pvw_public_' + $Label + '_' + ([guid]::NewGuid().ToString('N').Substring(0, 8)))
    return $p
}

$memoryOrSwitchText = 'Provider memory|PVW_PROVIDER'
$allPass = $true

if ($runReal) {
    # ---- unset: nothing changes ----
    $u = Invoke-Provider -Name 'unset' -AppCode $appOk -Tag 'unset'
    $uPrecond = ($u.SetupText -match 'Entry smoke exit=0') -and $u.ExeBuilt
    $uUv      = $u.SetupText -match 'uv-first: Miniconda download skipped'
    $uSilent  = ($u.SetupText -notmatch $memoryOrSwitchText) -and ($u.Console -notmatch $memoryOrSwitchText)
    $uNoFile  = ($null -eq $u.StateFile)
    $uPass = $uPrecond -and $uUv -and $uSilent -and $uNoFile -and ($u.Status -eq 'ok')
    if (-not $uPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.unset'
        req     = 'REQ-009'
        pass    = $uPass
        desc    = 'with no switch and no memory file the normal uv run happens, nothing mentions memory or the switch, and a plain uv pass writes no file'
        details = [ordered]@{
            exitCode = $u.RunExit; precondition = $uPrecond; usedUv = $uUv; silent = $uSilent; noStateFile = $uNoFile; status = $u.Status
        }
    })

    # ---- invalid: wrong case, another name, a hostile string ----
    $badValues = @('Conda', 'miniconda', 'zz9&echo_pwn|v%PATH%^w')
    $badDetails = [ordered]@{}
    $iPass = $true
    $idx = 0
    foreach ($bad in $badValues) {
        $idx++
        $b = Invoke-Provider -Name ('invalid' + $idx) -AppCode $appOk -EnvVars @{ PVW_PROVIDER = $bad } -Tag 'invalid'
        $bText = $b.Console + "`n" + $b.SetupText
        $bStopped = ($bText -match 'PVW_PROVIDER has a value this bootstrapper does not accept') -and ($b.Status -eq 'error')
        $bSaysAccepted = $bText -match 'only accepted value is conda'
        $bEarly = (-not $b.UvBin) -and (-not $b.UvEnv) -and ($bText -notmatch '\buv: ')
        $bNoEcho = $true
        if ($bad -like 'zz9*') { $bNoEcho = ($bText -notmatch 'zz9') -and ($bText -notmatch 'echo_pwn') }
        elseif ($bad -ceq 'Conda') { $bNoEcho = ($bText -cnotmatch '\bConda\b') }
        else { $bNoEcho = ($bText -cnotmatch 'miniconda') }
        $bNoStray = @($b.TopNames | Where-Object { $_ -match 'echo_pwn|^w$|^v$|PATH' }).Count -eq 0
        $one = $bStopped -and $bSaysAccepted -and $bEarly -and $bNoEcho -and $bNoStray
        if (-not $one) { $iPass = $false }
        $badDetails['value' + $idx] = [ordered]@{ stopped = $bStopped; saysAccepted = $bSaysAccepted; beforeUvWork = $bEarly; valueNotEchoed = $bNoEcho; noStrayFile = $bNoStray; exitCode = $b.RunExit }
    }
    if (-not $iPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.invalid'
        req     = 'REQ-009'
        pass    = $iPass
        desc    = 'a PVW_PROVIDER value other than conda stops the run with one error before any uv or conda work, and the value is never echoed'
        details = $badDetails
    })

    # ---- miniconda_gone: the file says conda, Miniconda is not there ----
    $noPublic = New-PublicDir 'gone'
    $g = Invoke-Provider -Name 'gone' -AppCode $appOk -EnvVars @{ PUBLIC = $noPublic } -Files @{ '~provider.state.json' = $stateConda } -Tag 'gone'
    $gPrecond = (-not (Test-Path -LiteralPath (Join-Path $noPublic 'Documents\Miniconda3'))) -and ($g.SetupText -match 'Entry smoke exit=0')
    $gCleared = ($g.SetupText -match 'Provider memory: conda was remembered, but Miniconda is no longer installed') -and ($null -eq $g.StateFile)
    $gVisible = $g.Console -match 'Provider memory: conda was remembered, but Miniconda is no longer installed'
    $gNormal  = ($g.SetupText -match 'uv-first: Miniconda download skipped') -and ($g.SetupText -notmatch 'uv: skipped \(provider memory')
    $gPass = $gPrecond -and $gCleared -and $gVisible -and $gNormal -and ($g.Status -eq 'ok')
    if (-not $gPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.miniconda_gone'
        req     = 'REQ-009'
        pass    = $gPass
        desc    = 'a memory file that names conda is cleared, with a visible line, when Miniconda is not installed, and the normal order runs'
        details = [ordered]@{ exitCode = $g.RunExit; precondition = $gPrecond; cleared = $gCleared; visibleOnConsole = $gVisible; normalOrder = $gNormal; status = $g.Status }
    })
    if (Test-Path $noPublic) { Remove-Item -Recurse -Force $noPublic -ErrorAction SilentlyContinue }

    # ---- unreadable: a file this bootstrapper cannot read ----
    $r = Invoke-Provider -Name 'unreadable' -AppCode $appOk -Files @{ '~provider.state.json' = 'this is not the memory file' } -Tag 'unreadable'
    $rPrecond = $r.SetupText -match 'Entry smoke exit=0'
    $rWarned = ($r.SetupText -match 'Provider memory: ~provider.state.json is not in a form this bootstrapper reads') -and ($r.Console -match 'Provider memory: ~provider.state.json is not in a form')
    $rNormal = ($r.SetupText -match 'uv-first: Miniconda download skipped') -and ($r.SetupText -notmatch 'uv: skipped \(provider memory')
    $rKept = ($r.StateFile -eq 'this is not the memory file')
    $rPass = $rPrecond -and $rWarned -and $rNormal -and $rKept -and ($r.Status -eq 'ok')
    if (-not $rPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.unreadable'
        req     = 'REQ-009'
        pass    = $rPass
        desc    = 'a memory file the bootstrapper cannot read is ignored with a visible warning, left in place, and the normal order runs'
        details = [ordered]@{ exitCode = $r.RunExit; precondition = $rPrecond; warned = $rWarned; normalOrder = $rNormal; fileKept = $rKept; status = $r.Status }
    })

    # ---- fastpath: a valid cached EXE runs before provider selection ----
    $f1 = Invoke-Provider -Name 'fastpath' -AppCode $appOk -Tag 'fast1'
    $f2 = Invoke-Provider -Name 'fastpath' -Reuse -EnvVars @{ PVW_PROVIDER = 'conda' } -Tag 'fast2'
    $fPrecond = ($f1.SetupText -match 'Entry smoke exit=0') -and $f1.ExeBuilt
    $fOverride = $f2.SetupText -match 'Using super-user override for PVW_PROVIDER: conda'
    $fFast = ($f2.SetupText -match 'Fast path: skipping PyInstaller rebuild') -and ($f2.SetupText -notmatch 'Selected Python provider') -and ($f2.SetupText -notmatch '\buv: ')
    $fPass = $fPrecond -and $fOverride -and $fFast -and ($f2.Status -eq 'ok') -and ($null -eq $f2.StateFile)
    if (-not $fPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.fastpath'
        req     = 'REQ-009'
        pass    = $fPass
        desc    = 'a valid cached EXE is reused before provider selection, so PVW_PROVIDER=conda changes nothing for that run'
        details = [ordered]@{ exitCode = $f2.RunExit; precondition = $fPrecond; overrideLogged = $fOverride; fastPathOnly = $fFast; status = $f2.Status }
    })
}

if ($runUv) {
    # ---- forced: PVW_PROVIDER=conda, Miniconda not yet installed, .uv_env and a stale exact pin present ----
    $pubForced = New-PublicDir 'forced'
    $uvRun = Invoke-Provider -Name 'forced' -AppCode $appOk -EnvVars @{ PUBLIC = $pubForced } -Tag 'forced1'
    $pinText = 'python-3.99.9'
    $c1Precond = ($uvRun.SetupText -match 'Entry smoke exit=0') -and $uvRun.UvEnv -and ($null -ne $uvRun.RuntimeTxt) -and
                 ($uvRun.RuntimeTxt -match '^python-\d+\.\d+\.\d+$') -and ($uvRun.Sidecar -eq $uvRun.RuntimeTxt)
    $cf = Invoke-Provider -Name 'forced' -Reuse -EnvVars @{ PUBLIC = $pubForced; PVW_PROVIDER = 'conda'; HP_TEST_SYSCON_ANSWER = 'N' } `
          -Files @{ 'runtime.txt' = $pinText + "`r`n"; '~runtime_writeback.txt' = $pinText + "`r`n" } -Tag 'forced2'
    $cfOverride = $cf.SetupText -match 'Using super-user override for PVW_PROVIDER: conda'
    $cfNoUv = ($cf.SetupText -match 'uv: skipped \(PVW_PROVIDER=conda\)') -and ($cf.SetupText -notmatch 'uv: reusing existing \.uv_env') -and ($cf.SetupText -notmatch 'uv-first')
    $cfAcquired = ($cf.Console -match 'Installing Miniconda into') -and $cf.Console.Contains($pubForced)
    $cfConda = $cf.SetupText -match 'Selected Python provider: Conda \(Portable\)'
    $cfPinDropped = ($cf.SetupText -match 'runtime.txt holds the exact Python version an earlier run of this bootstrapper wrote') -and ($cf.SetupText -notmatch 'conda env create failed')
    $cfPassed = ($cf.SetupText -match 'Entry smoke exit=0') -and ($cf.Status -eq 'ok')
    $cfNoWrite = ($null -eq $cf.StateFile)
    $cfPass = $c1Precond -and $cfOverride -and $cfNoUv -and $cfAcquired -and $cfConda -and $cfPinDropped -and $cfPassed -and $cfNoWrite
    if (-not $cfPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.forced'
        req     = 'REQ-009'
        pass    = $cfPass
        desc    = 'PVW_PROVIDER=conda acquires Miniconda, never reuses the uv venv, ignores an exact pin the bootstrapper itself wrote earlier, and writes no memory file'
        details = [ordered]@{
            exitCode = $cf.RunExit; precondition = $c1Precond; overrideLogged = $cfOverride; uvSkipped = $cfNoUv; minicondaAcquired = $cfAcquired
            condaSelected = $cfConda; stalePinDropped = $cfPinDropped; passedOnConda = $cfPassed; noMemoryWritten = $cfNoWrite
            firstRunPin = $uvRun.RuntimeTxt; firstRunSidecar = $uvRun.Sidecar; status = $cf.Status
        }
    })
    if (Test-Path $pubForced) { Remove-Item -Recurse -Force $pubForced -ErrorAction SilentlyContinue }

    # ---- remember: run 1 reaches conda through the cascade and writes the file; run 2 starts at conda ----
    $m1 = Invoke-Provider -Name 'remember' -AppCode $appCondaOnly -EnvVars @{ HP_TEST_LASTCHANCE_ANSWER = 'C'; HP_TEST_SYSCON_ANSWER = 'N' } -Tag 'rem1'
    $m1Precond = ($m1.SetupText -match 'Entry smoke exit=3') -and ($m1.SetupText -match 'cascading provider uv to conda') -and ($m1.SetupText -match 'Entry smoke exit=0')
    $m1Wrote = ($m1.StateFile -match '"provider":"conda"') -and ($m1.StateFile -match '"passType":"exe_ok"')
    $m1Said = ($m1.Console -match 'Provider memory: conda worked for this program after uv did not') -and ($m1.Console -match 'delete ~provider.state.json')
    # The field-note case: the user edits the inputs and runs again.
    $m2 = Invoke-Provider -Name 'remember' -Reuse -AppCode ($appCondaOnly + "`r`n# edited`r`n") -EnvVars @{ HP_TEST_LASTCHANCE_ANSWER = 'C'; HP_TEST_SYSCON_ANSWER = 'N' } `
          -Files @{ 'requirements.txt' = "# edited by the test`r`n" } -Tag 'rem2'
    $m2Start = ($m2.Console -match 'Provider memory: starting with conda') -and ($m2.Console -match 'delete ~provider.state.json')
    $m2NoUv = ($m2.SetupText -match 'uv: skipped \(provider memory: conda\)') -and ($m2.SetupText -notmatch 'uv-first') -and ($m2.SetupText -notmatch 'uv: creating venv') -and ($m2.SetupText -notmatch 'uv: reusing')
    $m2Conda = ($m2.SetupText -match 'Selected Python provider: Conda') -and ($m2.SetupText -notmatch 'cascading provider')
    $m2Passed = ($m2.SetupText -match 'Entry smoke exit=0') -and ($m2.Status -eq 'ok') -and ($m2.SetupText -notmatch 'Entry smoke exit=3')
    $m2Kept = ($m2.StateFile -eq $m1.StateFile)
    $mPass = $m1Precond -and $m1Wrote -and $m1Said -and $m2Start -and $m2NoUv -and $m2Conda -and $m2Passed -and $m2Kept
    if (-not $mPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.remember'
        req     = 'REQ-009'
        pass    = $mPass
        desc    = 'after a run that only worked on conda the next run, after the inputs were edited, starts at conda, says so and how to reset, and skips uv'
        details = [ordered]@{
            exitCode = $m2.RunExit; firstRunPrecondition = $m1Precond; fileWritten = $m1Wrote; firstRunSaidSo = $m1Said
            secondRunSaidSo = $m2Start; uvSkipped = $m2NoUv; condaFirst = $m2Conda; passedOnConda = $m2Passed; fileKept = $m2Kept
            stateFile = $m1.StateFile
        }
    })

    # ---- forced_stop: a Python version conda cannot give, written by the user ----
    $s = Invoke-Provider -Name 'forcedstop' -AppCode $appOk -EnvVars @{ PVW_PROVIDER = 'conda'; HP_TEST_SYSCON_ANSWER = 'N' } -Files @{ 'runtime.txt' = "python-3.99.9`r`n" } -Tag 'stop'
    $sReachedConda = ($s.SetupText -match 'Using super-user override for PVW_PROVIDER: conda') -and ($s.SetupText -match 'conda env create failed')
    $sHint = ($s.SetupText -match 'PVW_PROVIDER=conda is set, so no other provider was tried') -and ($s.Console -match 'Run again without PVW_PROVIDER')
    $sNoCascade = ($s.SetupText -notmatch 'Attempting embedded Python') -and ($s.SetupText -notmatch 'cascading provider') -and ($s.SetupText -notmatch 'Attempting venv fallback') -and (-not $s.UvEnv)
    $sNoFile = ($null -eq $s.StateFile)
    $sPass = $sReachedConda -and $sHint -and $sNoCascade -and $sNoFile -and ($s.Status -eq 'error')
    if (-not $sPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.provider.forced_stop'
        req     = 'REQ-009'
        pass    = $sPass
        desc    = 'when conda cannot solve under PVW_PROVIDER=conda the run stops there with a hint and no other provider is tried'
        details = [ordered]@{ exitCode = $s.RunExit; reachedConda = $sReachedConda; hintShown = $sHint; noOtherProvider = $sNoCascade; noMemoryWritten = $sNoFile; status = $s.Status }
    })
}

if (-not $allPass) { exit 1 }
exit 0
