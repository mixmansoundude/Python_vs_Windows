# ASCII only
# selfapps_dep_source_matrix.ps1 - REQ-005.1 dependency source resolution, one bootstrap per cell
# (docs/plan-test-suite-gaps.md gap T2).
#
# README "Source Resolution (authoritative order)": PEP 723 inline metadata, then pyproject.toml
# [project].dependencies, then requirements.txt, then the pipreqs scan, then nothing. Existing rows prove two
# pairs of that order; no row asserted which source a run really used together with what it really installed.
# Each cell is a fresh folder holding a stdlib-only stub (so a scan cannot add anything, except in the two pipreqs
# cells) plus one distinct tiny pure-Python package per source:
#
#     requirements.txt -> termcolor     pyproject.toml -> iniconfig     PEP 723 header -> toolz
#     the pipreqs cells import six (found by the scan, declared nowhere)
#
# A cell passes only if the recorded dependency source (the one-line file the bootstrapper writes) names the
# expected source, the winning package is in ~dependency_installed.txt (pip freeze of the environment), and every
# package a LOSING source declared is absent. Both skip hooks are set, so no user code runs (the build still does);
# the PEP 723 write-back and the autopep723 merge are off so the entry file and the declared lists stay as written.
#
#   1 pep723_only            PEP 723 header only                                      -> pep723, toolz
#   2 requirements_only      requirements.txt only                                    -> requirements.txt, termcolor
#   3 all_three              PEP 723 + pyproject + requirements.txt                   -> pep723, toolz only
#   4 pep723_malformed       unclosed PEP 723 array + requirements.txt                -> requirements.txt, termcolor,
#                                                                                       the documented WARN
#   5 pyproject_nodeps       pyproject with no dependencies + requirements.txt        -> requirements.txt, termcolor
#   6 requirements_empty     empty requirements.txt + a program importing six         -> pipreqs, six
#   7 nothing_declared       nothing declared + a program importing six               -> pipreqs, six
#
# derived requirement: ids stay literal at each Write-DepRow call site (tools/check_ndjson_registry.py scans text,
# and matches a literal -Id argument the same way as an id = '...' key).
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"). Seven bootstraps; every package
# comes from PyPI, which the lane already depends on for pipreqs and PyInstaller.
# Emits: self.depsource.pep723_only, .requirements_only, .all_three, .pep723_malformed, .pyproject_nodeps,
#        .requirements_empty, .nothing_declared
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

function Write-DepRow {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = $Id; req = 'REQ-005.1'; pass = $Pass; desc = $Desc; details = $Details })
}

$allIds = @(
    'self.depsource.pep723_only', 'self.depsource.requirements_only', 'self.depsource.all_three',
    'self.depsource.pep723_malformed', 'self.depsource.pyproject_nodeps', 'self.depsource.requirements_empty',
    'self.depsource.nothing_declared'
)
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-005.1'; pass = $true; desc = 'Dependency source matrix (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-005.1'; pass = $false; desc = 'Dependency source matrix: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    exit 1
}

# The recorded-source file is read through this one list so a rename of the file touches one line (the bootstrapper
# writes ~dependency_source.txt since Item 76; an older copy was named dependency_source.txt).
$sourceFileNames = @('~dependency_source.txt', 'dependency_source.txt')

# The five distinct package names the cells look for.
$watched = @('termcolor', 'iniconfig', 'toolz', 'six')

$stubPlain = "import sys`nprint('dep-source-cell-ok')`n"
$stubSix = "import six`nprint('dep-source-cell-ok', six.__version__)`n"
$pep723Good = "# /// script`n# dependencies = [`n#     `"toolz`",`n# ]`n# ///`n"
$pep723Open = "# /// script`n# dependencies = [`n#     `"toolz`",`n# ///`n"
$pyprojectDeps = "[project]`nname = `"depsrccell`"`nversion = `"0.1.0`"`ndependencies = [`"iniconfig`"]`n"
$pyprojectNoDeps = "[project]`nname = `"depsrccell`"`nversion = `"0.1.0`"`n"

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
}

function Get-InstalledNames {
    param([string]$Dir)
    $names = New-Object System.Collections.ArrayList
    $path = Join-Path $Dir '~dependency_installed.txt'
    if (-not (Test-Path -LiteralPath $path)) { return ,@() }
    foreach ($line in (Get-Content -LiteralPath $path -Encoding ASCII)) {
        $m = [regex]::Match($line.Trim(), '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(==|@|\s|$)')
        if ($m.Success) { [void]$names.Add((($m.Groups[1].Value.ToLowerInvariant()) -replace '[-_.]+', '-')) }
    }
    return ,$names.ToArray()
}

function Get-RecordedSource {
    param([string]$Dir)
    foreach ($n in $sourceFileNames) {
        $p = Join-Path $Dir $n
        if (Test-Path -LiteralPath $p) {
            $m = [regex]::Match((Get-Content -LiteralPath $p -Raw -Encoding ASCII), 'dependency_source=([A-Za-z0-9._-]+)')
            return [pscustomobject]@{ File = $n; Value = $(if ($m.Success) { $m.Groups[1].Value } else { '' }) }
        }
    }
    return [pscustomobject]@{ File = ''; Value = '' }
}

# One cell: build the folder from the given file map, bootstrap it once, and report what happened.
function Invoke-Cell {
    param([string]$Name, [hashtable]$Files, [string]$Entry = 'cell_app.py')
    $dir = Join-Path $here ("~selftest_depsrc_" + $Name)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $batchPath -Destination $dir -Force
    foreach ($f in @($Files.Keys)) {
        [System.IO.File]::WriteAllText((Join-Path $dir $f), [string]$Files[$f], (New-Object System.Text.UTF8Encoding($false)))
    }
    $logName = "~depsrc_$Name.log"
    $wrapper = Join-Path $dir '~depsrc_launch.cmd'
    Set-Content -LiteralPath $wrapper -Value @('@echo off', "call run_setup.bat $Entry > $logName 2>&1", 'exit /b %ERRORLEVEL%') -Encoding ASCII
    $vars = [ordered]@{
        HP_SKIP_ENTRY_SMOKE = '1'; HP_SKIP_EXE_SMOKERUN = '1'; HP_SKIP_PEP723_WRITEBACK = '1'; HP_SKIP_AUTOPEP_DISCOVERY = '1'
        HP_SKIP_PIPREQS = $null; HP_SKIP_NIVISA = '1'
    }
    if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
    $saved = @{}
    foreach ($k in @($vars.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    $exitCode = -1
    Push-Location -LiteralPath $dir
    try {
        cmd /c "call ~depsrc_launch.cmd" | Out-Null
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $log = Read-Text (Join-Path $dir $logName)
    $setup = Read-Text (Join-Path $dir '~setup.log')
    $installed = @(Get-InstalledNames -Dir $dir)
    $recorded = Get-RecordedSource -Dir $dir
    Write-Host ("=== dependency source cell: {0} ===" -f $Name)
    Write-Host ("recorded source: file='{0}' value='{1}'" -f $recorded.File, $recorded.Value)
    Write-Host ("watched packages installed: " + ((@($watched | Where-Object { $installed -contains $_ })) -join ', '))
    foreach ($l in (($log -split "`r?`n") | Where-Object { $_ -match 'DEP_SOURCE|dep source selected|PEP 723|pyproject|requirements\.txt|auto-detected via pipreqs|\[ERROR\]' } | Select-Object -First 16)) { Write-Host $l }
    return [pscustomobject]@{
        Name = $Name; Dir = $dir; Exit = $exitCode; Log = $log; Setup = $setup
        Installed = $installed; SourceFile = $recorded.File; Source = $recorded.Value
        Watched = @($watched | Where-Object { $installed -contains $_ })
    }
}

# Shared verdict: expected source, exactly the expected watched packages installed (so every losing source's package
# is absent), and the bootstrap itself ran to the end.
function Get-CellVerdict {
    param($Cell, [string]$ExpectedSource, [string[]]$ExpectedWatched)
    $watchedOk = (@($Cell.Watched | Sort-Object) -join ',') -eq (@($ExpectedWatched | Sort-Object) -join ',')
    return [pscustomobject]@{
        SourceOk = ($Cell.Source -ceq $ExpectedSource)
        WatchedOk = [bool]$watchedOk
        Ran = ($Cell.Exit -eq 0) -and ($Cell.Installed.Count -gt 0)
    }
}

function Get-CellDetails {
    param($Cell, $Verdict, [string]$ExpectedSource, [string[]]$ExpectedWatched)
    return [ordered]@{
        exitCode = $Cell.Exit; recordedSource = $Cell.Source; expectedSource = $ExpectedSource; sourceFile = $Cell.SourceFile
        watchedInstalled = @($Cell.Watched); expectedWatched = @($ExpectedWatched)
        installedCount = $Cell.Installed.Count
        sourceOk = $Verdict.SourceOk; watchedOk = $Verdict.WatchedOk; ran = $Verdict.Ran
    }
}

$anyRed = $false

# ---- 1: PEP 723 only
$c = Invoke-Cell -Name 'pep723_only' -Files @{ 'cell_app.py' = ($pep723Good + $stubPlain) }
$v = Get-CellVerdict -Cell $c -ExpectedSource 'pep723' -ExpectedWatched @('toolz')
$d = Get-CellDetails -Cell $c -Verdict $v -ExpectedSource 'pep723' -ExpectedWatched @('toolz')
$pass = $v.SourceOk -and $v.WatchedOk -and $v.Ran
if (-not $pass) { $anyRed = $true }
Write-DepRow -Id 'self.depsource.pep723_only' -Pass ([bool]$pass) -Desc 'REQ-005.1: a PEP 723 header alone is the dependency source and its package is installed' -Details $d

# ---- 2: requirements.txt only
$c = Invoke-Cell -Name 'requirements_only' -Files @{ 'cell_app.py' = $stubPlain; 'requirements.txt' = "termcolor`n" }
$v = Get-CellVerdict -Cell $c -ExpectedSource 'requirements.txt' -ExpectedWatched @('termcolor')
$d = Get-CellDetails -Cell $c -Verdict $v -ExpectedSource 'requirements.txt' -ExpectedWatched @('termcolor')
$pass = $v.SourceOk -and $v.WatchedOk -and $v.Ran
if (-not $pass) { $anyRed = $true }
Write-DepRow -Id 'self.depsource.requirements_only' -Pass ([bool]$pass) -Desc 'REQ-005.1: requirements.txt alone is the dependency source and its package is installed' -Details $d

# ---- 3: all three present; PEP 723 wins
# FIRST COMMIT ONLY: the expected winner below is deliberately wrong (the documented order makes PEP 723 win). It
# proves the row fails on real data; the details show the source the run really recorded. The next commit restores
# 'pep723' and 'toolz'.
$expectedSource3 = 'pyproject'
$expectedWatched3 = @('iniconfig')
$c = Invoke-Cell -Name 'all_three' -Files @{ 'cell_app.py' = ($pep723Good + $stubPlain); 'pyproject.toml' = $pyprojectDeps; 'requirements.txt' = "termcolor`n" }
$v = Get-CellVerdict -Cell $c -ExpectedSource $expectedSource3 -ExpectedWatched $expectedWatched3
$d = Get-CellDetails -Cell $c -Verdict $v -ExpectedSource $expectedSource3 -ExpectedWatched $expectedWatched3
$pass = $v.SourceOk -and $v.WatchedOk -and $v.Ran
if (-not $pass) { $anyRed = $true }
Write-DepRow -Id 'self.depsource.all_three' -Pass ([bool]$pass) -Desc 'REQ-005.1: with PEP 723, pyproject.toml and requirements.txt all present the PEP 723 header wins and the other two lists are not installed' -Details $d

# ---- 4: malformed PEP 723 header falls through to requirements.txt, with the documented WARN
$c = Invoke-Cell -Name 'pep723_malformed' -Files @{ 'cell_app.py' = ($pep723Open + $stubPlain); 'requirements.txt' = "termcolor`n" }
$v = Get-CellVerdict -Cell $c -ExpectedSource 'requirements.txt' -ExpectedWatched @('termcolor')
$warnShown = $c.Log -match [regex]::Escape('PEP 723 block found but dependency list is empty or malformed')
$d = Get-CellDetails -Cell $c -Verdict $v -ExpectedSource 'requirements.txt' -ExpectedWatched @('termcolor')
$d['warnShown'] = [bool]$warnShown
$pass = $v.SourceOk -and $v.WatchedOk -and $v.Ran -and $warnShown
if (-not $pass) { $anyRed = $true }
Write-DepRow -Id 'self.depsource.pep723_malformed' -Pass ([bool]$pass) -Desc 'REQ-005.1: a malformed PEP 723 header prints the documented WARN and the run falls through to requirements.txt' -Details $d

# ---- 5: pyproject without [project].dependencies falls through to requirements.txt
$c = Invoke-Cell -Name 'pyproject_nodeps' -Files @{ 'cell_app.py' = $stubPlain; 'pyproject.toml' = $pyprojectNoDeps; 'requirements.txt' = "termcolor`n" }
$v = Get-CellVerdict -Cell $c -ExpectedSource 'requirements.txt' -ExpectedWatched @('termcolor')
$d = Get-CellDetails -Cell $c -Verdict $v -ExpectedSource 'requirements.txt' -ExpectedWatched @('termcolor')
$pass = $v.SourceOk -and $v.WatchedOk -and $v.Ran
if (-not $pass) { $anyRed = $true }
Write-DepRow -Id 'self.depsource.pyproject_nodeps' -Pass ([bool]$pass) -Desc 'REQ-005.1: a pyproject.toml with no [project].dependencies falls through to requirements.txt' -Details $d

# ---- 6: an empty requirements.txt is not a source; the scan of the program decides
$c = Invoke-Cell -Name 'requirements_empty' -Files @{ 'cell_app.py' = $stubSix; 'requirements.txt' = '' }
$v = Get-CellVerdict -Cell $c -ExpectedSource 'pipreqs' -ExpectedWatched @('six')
$d = Get-CellDetails -Cell $c -Verdict $v -ExpectedSource 'pipreqs' -ExpectedWatched @('six')
$pass = $v.SourceOk -and $v.WatchedOk -and $v.Ran
if (-not $pass) { $anyRed = $true }
Write-DepRow -Id 'self.depsource.requirements_empty' -Pass ([bool]$pass) -Desc 'REQ-005.1: an empty requirements.txt is not a source; the pipreqs scan of the program supplies the dependency' -Details $d

# ---- 7: nothing declared; the scan of the program decides
$c = Invoke-Cell -Name 'nothing_declared' -Files @{ 'cell_app.py' = $stubSix }
$v = Get-CellVerdict -Cell $c -ExpectedSource 'pipreqs' -ExpectedWatched @('six')
$d = Get-CellDetails -Cell $c -Verdict $v -ExpectedSource 'pipreqs' -ExpectedWatched @('six')
$pass = $v.SourceOk -and $v.WatchedOk -and $v.Ran
if (-not $pass) { $anyRed = $true }
Write-DepRow -Id 'self.depsource.nothing_declared' -Pass ([bool]$pass) -Desc 'REQ-005.1: with nothing declared the pipreqs scan is the dependency source' -Details $d

if ($anyRed) { exit 1 }
exit 0
