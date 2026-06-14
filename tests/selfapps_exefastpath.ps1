# ASCII only
# selfapps_exefastpath.ps1 - regression guard for graceful fast-path EXE failure.
#
# Background: run_setup.bat has an EXE "fast path" that reuses an existing dist\*.exe
# when sources are unchanged. Previously, if that reused EXE exited non-zero the
# bootstrapper called :die and aborted -- a hard EXE failure took out the whole
# bootstrapper instead of falling back. This test reproduces that path and asserts
# the new graceful behavior: the cached EXE is discarded, a full rebuild runs, and
# the bootstrap finishes with exitCode 0 (never the old hard-exit).
#
# Failure mechanism is CWD-independent (unlike selfapps_exedata_fail.ps1's relative
# open()): entry.py reads a package data file via importlib.resources. The file
# exists on disk (so "python entry.py" succeeds), but PyInstaller does not bundle
# arbitrary package data, so the frozen EXE raises FileNotFoundError no matter which
# directory it runs from -- exactly the class with zero warnfile footprint.
#
# Lane: real and conda-full only.
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

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.fastpath.graceful'
        req     = 'REQ-007'
        pass    = $true
        desc    = 'Fast-path broken-EXE reuse handled gracefully (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.exe.fastpath.graceful'
        req     = 'REQ-007'
        pass    = $false
        desc    = 'Fast-path broken-EXE reuse: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_exefastpath'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# A package whose data file is visible on disk but never bundled by PyInstaller.
New-Item -ItemType Directory -Force -Path (Join-Path $workDir 'mypkg') | Out-Null
New-Item -ItemType Directory -Force -Path (Join-Path $workDir 'mypkg\data') | Out-Null
Set-Content -Path (Join-Path $workDir 'mypkg\__init__.py') -Value '' -Encoding ASCII
Set-Content -Path (Join-Path $workDir 'mypkg\data\info.txt') -Value 'hello-bundled-data' -Encoding ASCII

# entry.py succeeds under the interpreter (file on disk) but the frozen EXE cannot
# find mypkg/data/info.txt inside its bundle -> non-zero exit regardless of CWD.
Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
import mypkg  # ensure PyInstaller traces and bundles the package itself
import importlib.resources as ir
print((ir.files("mypkg") / "data" / "info.txt").read_text())
'@ -Encoding ASCII

$prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'

# Defensive: ensure the bootstrap's EXE smokerun does not emit a self.exe.smokerun
# pass=false row into the gated NDJSON (the broken EXE is expected to fail here).
# run_setup.bat only emits that row when HP_NDJSON is defined.
$prevNd = if (Test-Path Env:HP_NDJSON) { $env:HP_NDJSON } else { $null }
Remove-Item Env:HP_NDJSON -ErrorAction SilentlyContinue

function Invoke-Bootstrap {
    param([string]$LogName)
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $LogName 2>&1"
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

try {
    # Run 1: builds the EXE (first-build smokerun fails gracefully, exitCode 0).
    $run1Exit = Invoke-Bootstrap '~exefastpath_run1.log'
    # Run 2: sources unchanged -> EXE fast path reuses the broken EXE, which fails.
    $run2Exit = Invoke-Bootstrap '~exefastpath_run2.log'
} finally {
    if ($null -eq $prev) {
        Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PIPREQS = $prev
    }
    if ($null -ne $prevNd) { $env:HP_NDJSON = $prevNd }
}

$run2LogPath = Join-Path $workDir '~exefastpath_run2.log'
$run2SetupLog = Join-Path $workDir '~setup.log'
$run2Lines = if (Test-Path $run2LogPath)  { Get-Content -LiteralPath $run2LogPath  -Encoding ASCII } else { @() }
$run2Setup = if (Test-Path $run2SetupLog) { Get-Content -LiteralPath $run2SetupLog -Raw -Encoding ASCII } else { '' }
$run2Combined = ($run2Lines -join "`n") + "`n" + $run2Setup

# derived requirement: exact phrases from :try_fast_exe (graceful fallback) and the
# old hard-exit message that must NOT appear.
$gracefulPhrase = 'discarding cached EXE and rebuilding'
$hardExitPhrase = 'Fast path EXE execution failed'

$fastPathFellBack = $run2Combined -match [regex]::Escape($gracefulPhrase)
$hardExited       = $run2Combined -match [regex]::Escape($hardExitPhrase)

# Graceful means: run 2 fast path detected the broken EXE, fell back instead of dying,
# and the bootstrap completed with exitCode 0 (not the old non-zero :die).
$pass = ($run1Exit -eq 0) -and ($run2Exit -eq 0) -and $fastPathFellBack -and (-not $hardExited)

Write-NdjsonRow ([ordered]@{
    id      = 'self.exe.fastpath.graceful'
    req     = 'REQ-007'
    pass    = $pass
    desc    = 'Reused fast-path EXE that fails is discarded and rebuilt; bootstrap stays graceful'
    details = [ordered]@{
        run1Exit         = $run1Exit
        run2Exit         = $run2Exit
        fastPathFellBack = $fastPathFellBack
        hardExited       = $hardExited
        run2Log          = '~exefastpath_run2.log'
    }
})

if (-not $pass) { exit 1 }
exit 0
