# ASCII only
# selfapps_example_apps.ps1 - CLAUDE.md Item 74: the curated example apps in tests/fixtures/examples, run the way a
# beginner runs them.
#
# Four small programs sit in tests/fixtures/examples so that a person (or a later scenario) can drop one next to
# run_setup.bat without running the whole suite. This script takes three of them, copies the folder's files into a
# scratch folder with a copy of the bootstrapper, and starts the bootstrapper with no argument and no skip hook, so the
# whole default path runs: entry selection, dependency discovery, the uv install, the PyInstaller build and the
# verification run of the EXE. The fourth app (pandas_excel) is read by selfapps_pandas_excel.ps1 (conda-full lane) and
# is too heavy for a third run here.
#
#   stdlib_single      solo.py only; the simplest program, nothing to install
#   multifile_sibling  main.py imports helper.py from the same folder; entry selection must pick main.py and the
#                      sibling must not be mistaken for something to install (CLAUDE.md Item 88)
#   gui_exits          a real tkinter window that closes itself after half a second; the build must bundle tkinter
#                      and the window must open and close on the runner's desktop
#
# What a pass asserts for each app (every sub-check is a named detail; the reason it passes, not only the exit code):
#   fixtureFound  the folder exists under tests/fixtures/examples and holds the expected number of .py files
#   exit 0        the bootstrapper exited 0 and ~bootstrap.status.json says state ok
#   exe built     dist\<env>.exe exists and the log says "Entry smoke exit=0" (the EXE's own verification run)
#   entry         the log chose the expected file ("Chosen entry: ...\<file>") and counted the expected .py files
#   output        the program's own line is in ~run.out.txt, which holds the stdout of that verification run
# A run that does not finish inside 25 minutes is stopped and reported (timedOut) instead of holding the job.
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text,
# not PowerShell).
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"). It needs PyPI and the uv download
# like every other real-lane scenario; three full builds.
# Emits: self.examples.stdlib_single, self.examples.multifile_sibling, self.examples.gui_exits
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
    Write-NdjsonRow ([ordered]@{ id = 'self.examples.stdlib_single'; req = 'REQ-001.1'; pass = $true; desc = 'Example app run (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.examples.multifile_sibling'; req = 'REQ-001.1'; pass = $true; desc = 'Example app run (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.examples.gui_exits'; req = 'REQ-001.1'; pass = $true; desc = 'Example app run (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.examples.stdlib_single'; req = 'REQ-001.1'; pass = $false; desc = 'Example app run: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.examples.multifile_sibling'; req = 'REQ-001.1'; pass = $false; desc = 'Example app run: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.examples.gui_exits'; req = 'REQ-001.1'; pass = $false; desc = 'Example app run: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

$fixtureRoot = Join-Path (Join-Path $here 'fixtures') 'examples'

# Every skip hook and test override a leaked environment could carry is cleared, in this process and again in the
# launched shell (clearing through SetEnvironmentVariable(name, $null) alone is not trusted, see
# docs/agent-lessons-learned.md). HP_CI_LANE stays: it is what makes the optional prompts resolve without a keyboard.
$clearVars = @(
    'HP_SKIP_ENTRY_SMOKE', 'HP_SKIP_EXE_SMOKERUN', 'HP_SKIP_PEP723_WRITEBACK', 'HP_SKIP_AUTOPEP_DISCOVERY',
    'HP_SKIP_PIPREQS', 'HP_FORCE_CONDA_ONLY', 'PVW_PROVIDER', 'HP_DISABLE_HEURISTICS', 'HP_CI_SKIP_ENV'
)
$runTimeoutMs = 25 * 60 * 1000

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
}

# Runs one example folder through the bootstrapper. Returns @{ pass; details }; never throws.
function Invoke-ExampleRun {
    param([string]$Name, [string]$Entry, [string]$Expect, [int]$PyFiles)
    $d = [ordered]@{
        fixtureFound = $false; pyFilesInFixture = -1; timedOut = $false; exitCode = -1; statusState = ''
        exeFiles = @(); entrySmokeExit0 = $false; entryOk = $false; chosenEntry = ''; fileCountOk = $false
        pythonFileCountLine = ''; outputOk = $false; runOutExists = $false; runOutTail = ''; uvUsed = $false
        errorLines = @(); error = $null
    }
    $src = Join-Path $fixtureRoot $Name
    $work = Join-Path $here ('~selftest_example_' + $Name)
    try {
        if (-not (Test-Path -LiteralPath $src -PathType Container)) {
            $d.error = 'fixture folder missing: tests/fixtures/examples/' + $Name
            return @{ pass = $false; details = $d }
        }
        $pyCount = @(Get-ChildItem -LiteralPath $src -Filter '*.py' -File).Count
        $d.pyFilesInFixture = $pyCount
        $d.fixtureFound = ($pyCount -eq $PyFiles)
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $work | Out-Null
        Copy-Item -Path (Join-Path $src '*') -Destination $work -Recurse -Force
        Copy-Item -LiteralPath $batchPath -Destination $work -Force

        $lines = @('@echo off')
        foreach ($k in $clearVars) { $lines += ('set "' + $k + '="') }
        $lines += 'call run_setup.bat > ~example_boot.log 2>&1 < nul'
        $lines += 'exit /b %ERRORLEVEL%'
        Set-Content -LiteralPath (Join-Path $work '~example_launch.cmd') -Value $lines -Encoding ASCII

        $saved = @{}
        foreach ($k in $clearVars) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            if (Test-Path -LiteralPath ('Env:' + $k)) { Remove-Item -LiteralPath ('Env:' + $k) }
        }
        $hadLane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
        if (-not $hadLane) { [Environment]::SetEnvironmentVariable('HP_CI_LANE', 'test') }
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'call ~example_launch.cmd') -WorkingDirectory $work -NoNewWindow -PassThru
            $null = $p.Handle   # keeps ExitCode readable after WaitForExit(ms)
            if (-not $p.WaitForExit($runTimeoutMs)) {
                $d.timedOut = $true
                & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
                $null = $p.WaitForExit(30000)
            } else {
                $d.exitCode = $p.ExitCode
            }
        } finally {
            foreach ($k in $clearVars) {
                if ($null -ne $saved[$k]) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            }
            if (-not $hadLane) { [Environment]::SetEnvironmentVariable('HP_CI_LANE', $null) }
        }

        $boot = Read-Text (Join-Path $work '~example_boot.log')
        $setup = Read-Text (Join-Path $work '~setup.log')
        $combined = $boot + "`n" + $setup
        $statusPath = Join-Path $work '~bootstrap.status.json'
        if (Test-Path -LiteralPath $statusPath) {
            try { $d.statusState = [string]((Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { $d.statusState = 'unparseable' }
        }
        $distDir = Join-Path $work 'dist'
        if (Test-Path -LiteralPath $distDir) { $d.exeFiles = @(Get-ChildItem -LiteralPath $distDir -Filter '*.exe' -File | ForEach-Object { $_.Name }) }
        $d.entrySmokeExit0 = [bool]($combined -match 'Entry smoke exit=0')
        $m = [regex]::Match($boot, '(?m)^Chosen entry: (.+?)\s*$')
        if ($m.Success) { $d.chosenEntry = $m.Groups[1].Value }
        $d.entryOk = [bool]($d.chosenEntry -match ('(?i)\\' + [regex]::Escape($Entry) + '$'))
        $mc = [regex]::Match($setup, '(?m)\[INFO\] (Python file count: \d+)')
        if ($mc.Success) { $d.pythonFileCountLine = $mc.Groups[1].Value }
        $d.fileCountOk = ($d.pythonFileCountLine -eq ('Python file count: ' + $PyFiles))
        $runOutPath = Join-Path $work '~run.out.txt'
        $d.runOutExists = Test-Path -LiteralPath $runOutPath
        $runOut = Read-Text $runOutPath
        $d.outputOk = [bool]($runOut.Contains($Expect))
        $tail = ($runOut.Trim() -split "`r?`n" | Select-Object -Last 3) -join ' | '
        if ($tail.Length -gt 200) { $tail = $tail.Substring(0, 200) }
        $d.runOutTail = ($tail -replace '[^\x20-\x7E]', '?')
        $d.uvUsed = [bool]($setup -match '\[INFO\] uv: (acquired at|cached binary found)')
        $d.errorLines = @(($combined -split "`r?`n") | Where-Object { $_ -match '\[ERROR\]' } | Select-Object -First 6 | ForEach-Object { ($_ -replace '[^\x20-\x7E]', '?') })
    } catch {
        $d.error = $_.Exception.Message
    }
    $pass = $d.fixtureFound -and (-not $d.timedOut) -and ($d.exitCode -eq 0) -and ($d.statusState -eq 'ok') -and ($d.exeFiles.Count -ge 1) -and $d.entrySmokeExit0 -and $d.entryOk -and $d.fileCountOk -and $d.outputOk -and (-not $d.error)
    return @{ pass = [bool]$pass; details = $d }
}

# ---------------------------------------------------------------- stdlib only, one file
$r = Invoke-ExampleRun -Name 'stdlib_single' -Entry 'solo.py' -Expect 'from-single' -PyFiles 1
$passStdlib = $r.pass
Write-NdjsonRow ([ordered]@{
    id = 'self.examples.stdlib_single'; req = 'REQ-001.1'; pass = [bool]$r.pass
    desc = 'README REQ-001.1: the stdlib-only example (one file) is chosen as the entry, built into an EXE and its verification run prints its line'
    details = $r.details
})

# ---------------------------------------------------------------- two files, the entry imports its sibling
$r = Invoke-ExampleRun -Name 'multifile_sibling' -Entry 'main.py' -Expect 'hello from helper: multi-file example' -PyFiles 2
$passMulti = $r.pass
Write-NdjsonRow ([ordered]@{
    id = 'self.examples.multifile_sibling'; req = 'REQ-001.1'; pass = [bool]$r.pass
    desc = 'README REQ-001.1: the two-file example chooses main.py as the entry and its verification run prints the sibling module line'
    details = $r.details
})

# ---------------------------------------------------------------- a tkinter window that closes itself
$r = Invoke-ExampleRun -Name 'gui_exits' -Entry 'app.py' -Expect 'window closed' -PyFiles 1
$passGui = $r.pass
Write-NdjsonRow ([ordered]@{
    id = 'self.examples.gui_exits'; req = 'REQ-001.1'; pass = [bool]$r.pass
    desc = 'README REQ-001.1: the tkinter example is built into an EXE, its window opens and closes by itself and the run exits 0'
    details = $r.details
})

if (-not ($passStdlib -and $passMulti -and $passGui)) { exit 1 }
exit 0
