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
# Rows: self.runtime.install.accept, self.runtime.install.decline, self.runtime.install.pyproject and
# self.runtime.install.pep723, one real bootstrap each (the last two add a second bootstrap of the same folder).
# self.runtime.install.wording and self.runtime.install.risk are verdicts over the console text of those runs: the
# second (the risk half of README REQ-018.2, which stays untraced) needs the prompt to say that running the program twice could cause harm, because a yes also
# starts the program once more to check.
# Item 91 (README REQ-018.18): a yes adds the package to requirements.txt whatever the dependency source is.
# Before Item 89 a pyproject.toml or PEP 723 list was copied over requirements.txt on every run, so an appended
# line was lost and the offer left every file alone; since Item 89 the merge keeps a list's change, so the rows
# require the line in requirements.txt, pyproject.toml untouched (a header stays a header), and the line still there after a
# second run of the same folder (dist deleted so the dependency lists are read again; answer N, the rebuilt
# EXE misses the dynamically imported module again, which is the known limit of a computed import). The second run
# must not ask again either: the package is part of the environment now, so the runtime scan has nothing to report.
# Whether the header receives the package on that run is recorded (secondHeaderHasPackage), not asserted.
# The answer comes from HP_TEST_RTM_ANSWER, the test override of the prompt. Each row first proves
# its precondition (the first run exited 0 and its stderr held the traceback), so a fixture that
# stops reproducing the symptom cannot make a row pass or fail vacuously. HP_NDJSON points at a
# private file per scenario so the bootstrapper's own rows do not land in the lane artifact.
#
# Item 99 (README REQ-018.20): the accept row also carries that tag. The check run after a yes is the one the yes
# covers, and the log says "verified" when its output no longer names the module; the other half of the shall (the log
# says the module is still named) is the row self.runtime.install.stillmissing in selfapps_runtime_install_edges.ps1.
#
#
# Item 124 (README REQ-018.19): self.runtime.install.submodules is a fifth bootstrap, of a program that loads pytz and
# pytz.reference by names built at run time. pytz never imports pytz.reference, so PyInstaller brings that module into an
# EXE only when the rebuild passes --collect-submodules=pytz; --hidden-import=pytz alone leaves it out (PyInstaller 6.22.3
# with pyinstaller-hooks-contrib 2026.10: the second import fails with No module named 'pytz.reference'). The runtime scan
# cannot see that failure: it reports top-level names that are not installed and pytz is installed by then, so the install
# row says verified either way. The row therefore reads the check run's own output, and a control build of the same program
# with only --hidden-import=pytz, made with the environment the bootstrapper built, must lack the second line: without the
# control, a hook or a PyInstaller release that collected pytz.reference by itself would let the row pass for a rebuild
# that had dropped the flag.
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

# The prompt text between its heading and the first line that records the decision, whitespace flattened to single
# spaces. Empty when either marker is missing, so a prompt that moved or changed its heading cannot pass.
function Get-PromptBlock {
    param([string]$Text, [string]$Heading, [string]$Decision)
    if (-not $Text) { return '' }
    $from = $Text.IndexOf($Heading, [System.StringComparison]::Ordinal)
    if ($from -lt 0) { return '' }
    $rest = $Text.Substring($from)
    $m = [regex]::Match($rest, $Decision)
    if (-not $m.Success) { return '' }
    return ($rest.Substring(0, $m.Index) -replace '\s+', ' ').Trim()
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
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.install.pyproject'
        req     = 'REQ-018.18'
        pass    = $true
        desc    = 'a pyproject.toml dependency source gets the package in requirements.txt (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.install.pep723'
        req     = 'REQ-018.18'
        pass    = $true
        desc    = 'a PEP 723 header dependency source gets the package in requirements.txt (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.install.wording'
        req     = 'REQ-018.37'
        pass    = $true
        desc    = 'the prompt and the log say requirements.txt receives the package (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.install.risk'
        req     = 'REQ-018'
        pass    = $true
        desc    = 'the prompt tells the user that running the program twice could cause harm (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.runtime.install.submodules'
        req     = 'REQ-018.19'
        pass    = $true
        desc    = 'after a yes the rebuilt EXE holds the installed package and a submodule that only --collect-submodules brings (skipped on non-Windows)'
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

# The program of the submodule row (README REQ-018.19). Both names are built at run time, so neither pipreqs nor PyInstaller sees an
# import and the program needs the consented install and the rebuild's flags. pytz never imports pytz.reference, which is what makes
# the second flag visible. A failed import goes to stderr and the program carries on and exits 0, like the program above.
$submoduleAppCode = @'
import importlib
import traceback


def load(name):
    try:
        importlib.import_module(name)
        print("loaded " + name)
    except ImportError:
        traceback.print_exc()


if __name__ == "__main__":
    package = "".join(("pyt", "z"))
    load(package)
    load(package + "." + "".join(("refer", "ence")))
    print("submodule app done")
'@

# The header the PEP 723 scenario starts with: the dependency source is the header alone (one package, six).
$pep723Header = "# /// script`n# dependencies = [`n#     `"six`",`n# ]`n# ///`n"

# Runs one bootstrap of the fixture with the given answer and returns everything the rows need.
function Invoke-InstallScenario {
    param([string]$Name, [string]$Answer, [switch]$Pyproject, [switch]$Pep723, [string]$AppSource = '', [string]$Module = 'xlsxwriter')
    $workDir = Join-Path $here ('~selftest_runtime_install_' + $Name)
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Copy-Item -Path $batchPath -Destination $workDir -Force
    $appText = $appCode
    if ($AppSource) { $appText = $AppSource }
    if ($Pep723) { $appText = $pep723Header + $appText }
    Set-Content -Path (Join-Path $workDir 'app.py') -Value $appText -Encoding ASCII
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
        & $pyPath -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('$Module') else 1)" 2>$null
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
        WorkDir        = $workDir
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

# Runs the SAME folder once more (Item 91): the EXE folder is deleted so the cached-EXE fast path cannot skip the
# dependency lists, and the answer is N so nothing is installed on the way. It returns only what this run wrote to
# ~setup.log (the log is not rotated per run) plus the files the rows judge.
function Invoke-SecondRun {
    param([string]$Name, [string]$WorkDir)
    $setupLog = Join-Path $WorkDir '~setup.log'
    $before = 0
    if (Test-Path -LiteralPath $setupLog) { $before = (Get-Item -LiteralPath $setupLog).Length }
    $distDir = Join-Path $WorkDir 'dist'
    if (Test-Path -LiteralPath $distDir) { Remove-Item -Recurse -Force -LiteralPath $distDir }

    # derived requirement: the second run appends to the console log and the NDJSON file of the first run, because
    # those are the names the test-logs upload of batch-check.yml already lists; a new name would not be uploaded.
    $bootstrapLog = '~install_' + $Name + '_bootstrap.log'
    $subNdjson    = Join-Path $WorkDir '~sub.ndjson'
    $consoleBefore = 0
    if (Test-Path -LiteralPath (Join-Path $WorkDir $bootstrapLog)) { $consoleBefore = (Get-Item -LiteralPath (Join-Path $WorkDir $bootstrapLog)).Length }
    $savedNdjson  = [Environment]::GetEnvironmentVariable('HP_NDJSON')
    $savedAnswer  = [Environment]::GetEnvironmentVariable('HP_TEST_RTM_ANSWER')
    Push-Location $WorkDir
    try {
        [Environment]::SetEnvironmentVariable('HP_NDJSON', $subNdjson)
        [Environment]::SetEnvironmentVariable('HP_TEST_RTM_ANSWER', 'N')
        cmd /c "call run_setup.bat >> $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        [Environment]::SetEnvironmentVariable('HP_NDJSON', $savedNdjson)
        [Environment]::SetEnvironmentVariable('HP_TEST_RTM_ANSWER', $savedAnswer)
        Pop-Location
    }

    $console = ''
    $consolePath = Join-Path $WorkDir $bootstrapLog
    if (Test-Path -LiteralPath $consolePath) {
        $consoleBytes = [System.IO.File]::ReadAllBytes($consolePath)
        if ($consoleBytes.Length -gt $consoleBefore) { $console = [System.Text.Encoding]::ASCII.GetString($consoleBytes, $consoleBefore, $consoleBytes.Length - $consoleBefore) }
    }
    $newLog = ''
    if (Test-Path -LiteralPath $setupLog) {
        $bytes = [System.IO.File]::ReadAllBytes($setupLog)
        if ($bytes.Length -gt $before) { $newLog = [System.Text.Encoding]::ASCII.GetString($bytes, $before, $bytes.Length - $before) }
    }
    $reqPath = Join-Path $WorkDir 'requirements.txt'
    $reqText = ''
    if (Test-Path -LiteralPath $reqPath) { $reqText = Get-Content -LiteralPath $reqPath -Raw -Encoding ASCII }
    $pyprojPath = Join-Path $WorkDir 'pyproject.toml'
    $pyprojText = ''
    if (Test-Path -LiteralPath $pyprojPath) { $pyprojText = [System.IO.File]::ReadAllText($pyprojPath) }
    $appText = Get-Content -LiteralPath (Join-Path $WorkDir 'app.py') -Raw -Encoding ASCII
    $statusState = $null
    $statusPath = Join-Path $WorkDir '~bootstrap.status.json'
    if (Test-Path -LiteralPath $statusPath) {
        try { $statusState = (Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { $statusState = $null }
    }
    [pscustomobject]@{
        RunExit     = $runExit
        Console     = $console
        NewLog      = $newLog
        ReqText     = $reqText
        Pyproject   = $pyprojText
        AppText     = $appText
        StatusState = $statusState
    }
}

# The few log lines that explain a red row, printable ASCII only and cut short, so the row says WHY without the log files.
function Get-LogExcerpt {
    param([string]$Text, [int]$Max = 14)
    $keep = @()
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match 'DEP_SOURCE=|Dependency lists|Removed |still lists it|Runtime install|\[ERROR\]|\[WARN\]') {
            $clean = ($l -replace '[^\x20-\x7E]', '?')
            if ($clean.Length -gt 160) { $clean = $clean.Substring(0, 160) }
            $keep += $clean
            if ($keep.Count -ge $Max) { break }
        }
    }
    return ,$keep
}

# A program's output for a red row: printable ASCII only, line ends shown as " | ", cut short.
function Get-OutputExcerpt {
    param([string]$Text, [int]$Max = 300)
    if (-not $Text) { return '' }
    $kept = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) { if ($l.Trim()) { [void]$kept.Add($l.Trim()) } }
    $flat = ($kept.ToArray() -join ' | ') -replace '[^\x20-\x7E]', '?'
    if ($flat.Length -gt $Max) { $flat = $flat.Substring(0, $Max) }
    return $flat
}

# The control of the submodule row (README REQ-018.19): the same program built with the command line of :rti_rebuild minus
# --collect-submodules, by the PyInstaller of the environment the bootstrapper just built, and started once. Its output says
# whether --hidden-import alone brings the submodule; the row means something only while it does not.
function Invoke-ControlBuild {
    param([string]$WorkDir, [string]$Module)
    $py       = Join-Path $WorkDir '.uv_env\Scripts\python.exe'
    $root     = Join-Path $WorkDir '~control'
    $buildLog = Join-Path $WorkDir '~control_build.log'
    $outPath  = Join-Path $WorkDir '~control_out.txt'
    $errPath  = Join-Path $WorkDir '~control_err.txt'
    foreach ($old in @($root, $buildLog, $outPath, $errPath)) {
        if (Test-Path -LiteralPath $old) { Remove-Item -Recurse -Force -LiteralPath $old }
    }
    New-Item -ItemType Directory -Force -Path $root | Out-Null
    $exe = Join-Path $root 'dist\control.exe'
    $buildExit = -1
    if (Test-Path -LiteralPath $py) {
        & $py -m PyInstaller -y --onefile --clean --log-level WARN "--hidden-import=$Module" --distpath (Join-Path $root 'dist') --workpath (Join-Path $root 'work') --specpath $root --name control (Join-Path $WorkDir 'app.py') > $buildLog 2>&1
        $buildExit = $LASTEXITCODE
    }
    $built = ($buildExit -eq 0) -and (Test-Path -LiteralPath $exe)
    $runExit = -1
    if ($built) {
        & $exe > $outPath 2> $errPath
        $runExit = $LASTEXITCODE
    }
    $out = ''
    $err = ''
    if (Test-Path -LiteralPath $outPath) { $out = [System.IO.File]::ReadAllText($outPath) }
    if (Test-Path -LiteralPath $errPath) { $err = [System.IO.File]::ReadAllText($errPath) }
    [pscustomobject]@{ Built = $built; BuildExit = $buildExit; RunExit = $runExit; Out = $out; Err = $err }
}

# What is wrong with the submodule scenario; nothing when the program was reported missing, installed, rebuilt and verified, the check
# run loaded the package AND the submodule nothing imports, and the control EXE (built with --hidden-import alone) loaded the package
# and reported the submodule as missing. It reads plain values only, so a unit test can run it on synthetic runs; each comparison is
# its own if, so every wrong run is named by its own words.
function Get-SubmoduleProblems {
    param([int]$BootstrapExit, [bool]$FirstRunNamedModule, [bool]$Installed, [bool]$EnvHasModule, [bool]$Rebuilt,
          [string]$RowState, [string]$StatusState, [string]$CheckOut, [string]$CheckErr,
          [bool]$ControlBuilt, [string]$ControlOut, [string]$ControlErr)
    $out = New-Object System.Collections.ArrayList
    if ($BootstrapExit -ne 0) { [void]$out.Add("the bootstrap ended with exit code $BootstrapExit, expected 0") }
    if (-not $FirstRunNamedModule) { [void]$out.Add('the first run never reported pytz as missing, so the scenario did not start from the symptom') }
    if (-not $Installed) { [void]$out.Add('the log does not say that pytz was installed after the yes') }
    if (-not $EnvHasModule) { [void]$out.Add("pytz is not in the program's own environment after the yes") }
    if (-not $Rebuilt) { [void]$out.Add('the log does not say that the EXE was rebuilt after the install') }
    if ($RowState -ne 'verified') { [void]$out.Add("the install row says state $RowState, expected verified") }
    if ($StatusState -ne 'ok') { [void]$out.Add("the bootstrap status says state $StatusState, expected ok") }
    if ($CheckOut -notmatch '(?m)^loaded pytz\s*$') { [void]$out.Add('the check run did not load pytz, so the rebuilt EXE does not hold the package') }
    if ($CheckOut -notmatch '(?m)^loaded pytz\.reference\s*$') { [void]$out.Add('the check run did not load pytz.reference, so the rebuilt EXE lacks a submodule nothing imports and the rebuild did not pass --collect-submodules') }
    if ($CheckErr -match 'No module named') { [void]$out.Add('the check run printed No module named on its error output') }
    if ($CheckOut -notmatch '(?m)^submodule app done\s*$') { [void]$out.Add('the check run never printed its last line, so the program did not run to its end') }
    if (-not $ControlBuilt) {
        [void]$out.Add('the control build with --hidden-import alone did not produce an EXE')
    } else {
        if ($ControlOut -notmatch '(?m)^loaded pytz\s*$') { [void]$out.Add('the control EXE did not load pytz, so --hidden-import alone did not bring the package and the control proves nothing') }
        if ($ControlOut -match '(?m)^loaded pytz\.reference\s*$') { [void]$out.Add('the control EXE, built with --hidden-import alone, already holds pytz.reference, so this program no longer shows what --collect-submodules adds') }
        if ($ControlErr -notmatch "No module named 'pytz\.reference'") { [void]$out.Add('the control EXE did not report pytz.reference as missing') }
    }
    return $out.ToArray()
}

# ---- accept: a yes installs, adds to requirements.txt, rebuilds with --hidden-import, checks ----
$a = Invoke-InstallScenario -Name 'accept' -Answer 'Y'
$aFirstRunTrace = $a.SetupText -match 'Your program needed the module xlsxwriter'
$aPrompted      = $a.Console -match 'asked for packages that are not installed'
$aPromptNamesReq = $a.Console -match 'adds them to this program.s own environment and to requirements\.txt'
$aPromptNoSkip  = $a.Console -notmatch 'but does not edit'
$aInstalled     = $a.SetupText -match 'Runtime install: installed xlsxwriter'
$aSaidAdded     = $a.SetupText -match 'Runtime install: added xlsxwriter to requirements\.txt\.'
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
    req     = 'REQ-018.17, REQ-018.20'
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
    req     = 'REQ-018.12, REQ-018.15'
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

# ---- pyproject: a yes adds the package to requirements.txt too (Item 91), pyproject.toml stays untouched ----
$p = Invoke-InstallScenario -Name 'pyproject' -Answer 'Y' -Pyproject
$pSource        = $p.SetupText -match 'DEP_SOURCE=pyproject'
$pFirstRunTrace = $p.SetupText -match 'Your program needed the module xlsxwriter'
$pPromptNamesReq = $p.Console -match 'adds them to this program.s own environment and to requirements\.txt'
$pPromptNoSkip  = $p.Console -notmatch 'but does not edit'
$pInstalled     = $p.SetupText -match 'Runtime install: installed xlsxwriter'
$pSaidAdded     = $p.SetupText -match 'Runtime install: added xlsxwriter to requirements\.txt\.'
$pReqGotIt      = ($p.ReqText -match '(?m)^\s*xlsxwriter\s*$') -and ($p.ReqText -match '(?m)^\s*six\b')
$pUntouched     = ($p.PyprojectAfter -ceq $p.PyprojectBefore) -and ($p.PyprojectAfter -notmatch 'xlsxwriter')
$pVerified      = $p.SetupText -match 'Runtime install: verified'
$pCheckClean    = ($p.ErrText -notmatch 'No module named') -and ($p.OutText -match 'runtime app ok')
$p2 = Invoke-SecondRun -Name 'pyproject' -WorkDir $p.WorkDir
$p2Read         = $p2.NewLog -match 'DEP_SOURCE='
$p2Kept         = ($p2.ReqText -match '(?m)^\s*xlsxwriter\s*$') -and ($p2.ReqText -match '(?m)^\s*six\b')
$p2NotRemoved   = $p2.NewLog -notmatch 'Removed xlsxwriter'
$p2NoPrompt     = $p2.Console -notmatch 'asked for packages that are not installed'
$p2Untouched    = ($p2.Pyproject -ceq $p.PyprojectBefore)
$pPass = ($p.RunExit -eq 0) -and $pSource -and $pFirstRunTrace -and
         $pInstalled -and $p.EnvHasModule -and $pReqGotIt -and $pUntouched -and
         $pVerified -and $pCheckClean -and
         ($p.InstallState -eq 'verified') -and ($p.InstallDepSource -eq 'pyproject') -and ($p.StatusState -eq 'ok') -and
         ($p2.RunExit -eq 0) -and ($p2.StatusState -eq 'ok') -and $p2Read -and $p2Kept -and $p2NotRemoved -and $p2NoPrompt -and $p2Untouched
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.install.pyproject'
    req     = 'REQ-018.18'
    pass    = $pPass
    desc    = 'with pyproject.toml as the dependency source a yes adds the package to requirements.txt, leaves pyproject.toml untouched, and a second run keeps the line'
    details = [ordered]@{
        exitCode         = $p.RunExit
        sourceIsPyproject = $pSource
        firstRunTrace    = $pFirstRunTrace
        installed        = $pInstalled
        envHasModule     = $p.EnvHasModule
        requirementsGotIt = $pReqGotIt
        pyprojectUntouched = $pUntouched
        verified         = $pVerified
        checkRunClean    = $pCheckClean
        rowState         = $p.InstallState
        rowDepSource     = $p.InstallDepSource
        statusState      = $p.StatusState
        secondExit       = $p2.RunExit
        secondStatus     = $p2.StatusState
        secondReadLists  = $p2Read
        secondKeptLine   = $p2Kept
        secondNoRemoved  = $p2NotRemoved
        secondNoPrompt   = $p2NoPrompt
        secondHeaderHasPackage = ($p2.AppText -match 'xlsxwriter')
        secondPyprojectUntouched = $p2Untouched
        firstLog         = (Get-LogExcerpt $p.SetupText)
        secondLog        = (Get-LogExcerpt $p2.NewLog)
    }
})

# ---- pep723: the same for a PEP 723 header as the dependency source; the header stays a header ----
$e = Invoke-InstallScenario -Name 'pep723' -Answer 'Y' -Pep723
$eSource        = $e.SetupText -match 'DEP_SOURCE=pep723'
$eFirstRunTrace = $e.SetupText -match 'Your program needed the module xlsxwriter'
$ePromptNamesReq = $e.Console -match 'adds them to this program.s own environment and to requirements\.txt'
$ePromptNoSkip  = $e.Console -notmatch 'but does not edit'
$eInstalled     = $e.SetupText -match 'Runtime install: installed xlsxwriter'
$eSaidAdded     = $e.SetupText -match 'Runtime install: added xlsxwriter to requirements\.txt\.'
$eReqGotIt      = ($e.ReqText -match '(?m)^\s*xlsxwriter\s*$') -and ($e.ReqText -match '(?m)^\s*six\b')
$eAppText       = Get-Content -LiteralPath (Join-Path $e.WorkDir 'app.py') -Raw -Encoding ASCII
$eHeaderKept    = ($eAppText -match '(?m)^# /// script\s*$') -and ($eAppText -match '(?m)^# ///\s*$') -and ($eAppText -match '(?m)^#\s+"six')
$eVerified      = $e.SetupText -match 'Runtime install: verified'
$eCheckClean    = ($e.ErrText -notmatch 'No module named') -and ($e.OutText -match 'runtime app ok')
$e2 = Invoke-SecondRun -Name 'pep723' -WorkDir $e.WorkDir
$e2Read         = $e2.NewLog -match 'DEP_SOURCE='
$e2Kept         = ($e2.ReqText -match '(?m)^\s*xlsxwriter\s*$') -and ($e2.ReqText -match '(?m)^\s*six\b')
$e2NotRemoved   = $e2.NewLog -notmatch 'Removed xlsxwriter'
$e2NoPrompt     = $e2.Console -notmatch 'asked for packages that are not installed'
$e2HeaderKept   = ($e2.AppText -match '(?m)^# /// script\s*$') -and ($e2.AppText -match '(?m)^#\s+"six')
$ePass = ($e.RunExit -eq 0) -and $eSource -and $eFirstRunTrace -and
         $eInstalled -and $e.EnvHasModule -and $eReqGotIt -and $eHeaderKept -and
         $eVerified -and $eCheckClean -and
         ($e.InstallState -eq 'verified') -and ($e.InstallDepSource -eq 'pep723') -and ($e.StatusState -eq 'ok') -and
         ($e2.RunExit -eq 0) -and ($e2.StatusState -eq 'ok') -and $e2Read -and $e2Kept -and $e2NotRemoved -and $e2NoPrompt -and $e2HeaderKept
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.install.pep723'
    req     = 'REQ-018.18'
    pass    = $ePass
    desc    = 'with a PEP 723 header as the dependency source a yes adds the package to requirements.txt, keeps the header, and a second run keeps the line'
    details = [ordered]@{
        exitCode         = $e.RunExit
        sourceIsPep723   = $eSource
        firstRunTrace    = $eFirstRunTrace
        installed        = $eInstalled
        envHasModule     = $e.EnvHasModule
        requirementsGotIt = $eReqGotIt
        headerKept       = $eHeaderKept
        verified         = $eVerified
        checkRunClean    = $eCheckClean
        rowState         = $e.InstallState
        rowDepSource     = $e.InstallDepSource
        statusState      = $e.StatusState
        secondExit       = $e2.RunExit
        secondStatus     = $e2.StatusState
        secondReadLists  = $e2Read
        secondKeptLine   = $e2Kept
        secondNoRemoved  = $e2NotRemoved
        secondNoPrompt   = $e2NoPrompt
        secondHeaderHasPackage = ($e2.AppText -match 'xlsxwriter')
        secondHeaderKept = $e2HeaderKept
        firstLog         = (Get-LogExcerpt $e.SetupText)
        secondLog        = (Get-LogExcerpt $e2.NewLog)
    }
})

# ---- wording (REQ-018.37): prompt and log say that requirements.txt receives the package, for every dependency source ----
# One verdict over the three yes runs (requirements.txt, pyproject.toml and PEP 723 header as the source), taken from the
# console text the user saw and the setup log, so a source that quietly skips the sentence turns this row red.
$wPass = $aPromptNamesReq -and $aPromptNoSkip -and $aSaidAdded -and
         $pPromptNamesReq -and $pPromptNoSkip -and $pSaidAdded -and
         $ePromptNamesReq -and $ePromptNoSkip -and $eSaidAdded
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.install.wording'
    req     = 'REQ-018.37'
    pass    = $wPass
    desc    = 'on a yes the prompt says requirements.txt receives the package and the log says it was added, for each dependency source'
    details = [ordered]@{
        acceptPromptNamesRequirements    = $aPromptNamesReq
        acceptPromptDoesNotSkipEdit      = $aPromptNoSkip
        acceptSaidAdded                  = $aSaidAdded
        pyprojectPromptNamesRequirements = $pPromptNamesReq
        pyprojectPromptDoesNotSkipEdit   = $pPromptNoSkip
        pyprojectSaidAdded               = $pSaidAdded
        pep723PromptNamesRequirements    = $ePromptNamesReq
        pep723PromptDoesNotSkipEdit      = $ePromptNoSkip
        pep723SaidAdded                  = $eSaidAdded
    }
})

# ---- risk (half of README REQ-018.2, tagged with the goal only): a yes also starts the program once more, so the prompt says running it twice could cause harm ----
# One verdict over the accept and the decline runs: the prompt block (from its heading to the line that records the
# decision) must exist in both consoles and say it in both. The text is the same in all four runs; two are enough.
$riskMarker   = 'running it twice could cause harm'
$riskHeading  = 'Your program asked for packages that are not installed:'
$riskDecision = 'Runtime install: (accepted|declined)'
$aBlock = Get-PromptBlock -Text $a.Console -Heading $riskHeading -Decision $riskDecision
$dBlock = Get-PromptBlock -Text $d.Console -Heading $riskHeading -Decision $riskDecision
$aNamesRisk = $aBlock.Contains($riskMarker)
$dNamesRisk = $dBlock.Contains($riskMarker)
$rPass = ($aBlock.Length -gt 0) -and ($dBlock.Length -gt 0) -and $aNamesRisk -and $dNamesRisk
$rShown = $aBlock
if ($rShown.Length -gt 500) { $rShown = $rShown.Substring(0, 500) }
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.install.risk'
    req     = 'REQ-018'
    pass    = $rPass
    desc    = 'the install prompt tells the user that running the program twice could cause harm, because a yes also starts the program once more to check'
    details = [ordered]@{
        acceptBlockFound  = ($aBlock.Length -gt 0)
        declineBlockFound = ($dBlock.Length -gt 0)
        acceptNamesRisk   = $aNamesRisk
        declineNamesRisk  = $dNamesRisk
        promptText        = $rShown
    }
})

# ---- submodules (README REQ-018.19): the rebuild after a yes also passes --collect-submodules ----
# After a yes the rebuilt EXE must hold the package AND pytz.reference, which nothing imports. The scan cannot tell (pytz is installed by
# then, so the state is verified either way), so the row reads the check run's own output. The control, built from the same environment
# with --hidden-import alone, must lack the submodule: otherwise the row would pass without the second flag.
$s = Invoke-InstallScenario -Name 'submodules' -Answer 'Y' -AppSource $submoduleAppCode -Module 'pytz'
$ctl = Invoke-ControlBuild -WorkDir $s.WorkDir -Module 'pytz'
$sFirstRun  = $s.SetupText -match 'Your program needed the module pytz'
$sInstalled = $s.SetupText -match 'Runtime install: installed pytz'
$sRebuilt   = $s.SetupText -match '\[REPAIR\] rebuild complete after runtime install'
$sArgs = @{
    BootstrapExit = [int]$s.RunExit; FirstRunNamedModule = [bool]$sFirstRun; Installed = [bool]$sInstalled
    EnvHasModule = [bool]$s.EnvHasModule; Rebuilt = [bool]$sRebuilt; RowState = [string]$s.InstallState; StatusState = [string]$s.StatusState
    CheckOut = [string]$s.OutText; CheckErr = [string]$s.ErrText
    ControlBuilt = [bool]$ctl.Built; ControlOut = [string]$ctl.Out; ControlErr = [string]$ctl.Err
}
$sProblems = @(Get-SubmoduleProblems @sArgs)
$sPass = ($sProblems.Count -eq 0)
$sDetails = [ordered]@{
    exitCode = $s.RunExit; firstRunNamedModule = $sFirstRun; installed = $sInstalled; envHasModule = $s.EnvHasModule
    rebuilt = $sRebuilt; rowState = $s.InstallState; statusState = $s.StatusState
    checkOut = (Get-OutputExcerpt $s.OutText); checkErr = (Get-OutputExcerpt $s.ErrText)
    controlBuilt = $ctl.Built; controlBuildExit = $ctl.BuildExit; controlRunExit = $ctl.RunExit
    controlOut = (Get-OutputExcerpt $ctl.Out); controlErr = (Get-OutputExcerpt $ctl.Err)
}
if (-not $sPass) { $sDetails['problems'] = @($sProblems); $sDetails['log'] = (Get-LogExcerpt $s.SetupText) }
Write-NdjsonRow ([ordered]@{
    id      = 'self.runtime.install.submodules'
    req     = 'REQ-018.19'
    pass    = $sPass
    desc    = 'after a yes the rebuilt EXE holds the installed package and a submodule that only --collect-submodules brings, and a build with --hidden-import alone does not'
    details = $sDetails
})

if (-not ($aPass -and $dPass -and $pPass -and $ePass -and $wPass -and $rPass -and $sPass)) { exit 1 }
exit 0
