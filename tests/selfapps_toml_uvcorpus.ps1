# ASCII only
# selfapps_toml_uvcorpus.ps1 - CLAUDE.md Item 79 slice 1: a canary for the layout `uv add --script` writes.
#
# The bootstrapper writes a PEP 723 header with uv (REQ-005.11) and reads it back on the next run with
# tools/pep723_extract.py (REQ-005.1), a hand-written TOML walker. selfapps_pep723_writeback.ps1 proves
# that round trip for one dependency. This test widens it to the shapes a header really holds, written
# by the REAL uv and not by hand: a lower-bound specifier, an extra with a compatible-release pin, and
# two environment markers. The extractor's list must equal what tomllib reads from the same block
# (tests/toml_oracle_check.py, which uses the regular expression the PEP publishes), so a uv release
# that changes its output layout turns this row red before a user meets it.
#
# Not a run_setup.bat test: it needs uv, a modern Python (for tomllib) and the network (uv resolves the
# packages to choose lower bounds), so like selfapps_pvw_quickstart.ps1 it installs uv the documented way.
# Lane: uv only, non-gating, because a PyPI or uv-download hiccup would fail it for no product reason.
# Emits: self.toml.uvcorpus
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
    Write-NdjsonRow ([ordered]@{ id = 'self.toml.uvcorpus'; req = 'REQ-005.1'; pass = $true; desc = 'uv-written PEP 723 header read back (skipped on non-Windows)'; details = ([ordered]@{ skip = $true; reason = 'non-windows-host' }) })
    exit 0
}

$workDir = Join-Path $here '~selftest_toml_uvcorpus'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
$details = [ordered]@{}
$pass = $false
Push-Location $workDir
try {
    # Same first line a user pastes from the README (selfapps_pvw_quickstart.ps1 does the same).
    irm https://astral.sh/uv/install.ps1 | iex
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    # tomllib needs Python 3.11+; only-managed gives a modern interpreter regardless of the runner image.
    $env:UV_PYTHON_PREFERENCE = 'only-managed'
    $details.uvVersion = ((uv --version) -join ' ')

    $script = Join-Path $workDir 'corpus.py'
    Set-Content -LiteralPath $script -Value "print('corpus')`n" -Encoding Ascii -NoNewline
    # Single quotes inside the markers, because PowerShell and Windows argument quoting disagree about
    # embedded double quotes; uv writes markers with single quotes anyway.
    $specs = @(
        'requests>=2.31',
        'rich[jupyter]~=13.0',
        "pywin32; sys_platform == 'win32'",
        "colorama; python_version < '3.10'"
    )
    $addOut = (uv add --script $script @specs 2>&1) -join "`n"
    $details.uvAddExit = $LASTEXITCODE
    $header = (Get-Content -LiteralPath $script -TotalCount 14) -join "`n"
    $details.header = $header

    $outFile = Join-Path $workDir 'extracted.txt'
    $extractOut = (uv run --no-project python (Join-Path $repo 'tools\pep723_extract.py') $script $outFile 2>&1) -join "`n"
    $details.extractExit = $LASTEXITCODE
    $details.extractOut = $extractOut

    $oracleJson = $null
    if (Test-Path -LiteralPath $outFile) {
        $oracleJson = (uv run --no-project python (Join-Path $here 'toml_oracle_check.py') $script $outFile 2>&1) -join "`n"
    }
    $details.oracleExit = $LASTEXITCODE
    $details.oracle = $oracleJson
    $oracle = $null
    try { $oracle = $oracleJson | ConvertFrom-Json } catch { $oracle = $null }
    $hasMarker = $false; $hasExtra = $false
    if ($oracle) {
        $hasMarker = [bool](@($oracle.reference) -match 'sys_platform')
        $hasExtra  = [bool](@($oracle.reference) -match '\[jupyter\]')
        $details.match = [bool]$oracle.match
        $details.referenceCount = $oracle.referenceCount
    }
    # The precondition is part of the verdict: a header that lost the marker or the extra would make a
    # matching empty-ish list look like success.
    $details.hasMarker = $hasMarker
    $details.hasExtra = $hasExtra
    $pass = ($details.uvAddExit -eq 0) -and ($details.extractExit -eq 0) -and ($details.oracleExit -eq 0) `
        -and ($oracle -ne $null) -and [bool]$oracle.match -and ($oracle.referenceCount -ge 4) -and $hasMarker -and $hasExtra
} catch {
    $details.error = $_.Exception.Message
} finally {
    Pop-Location
}
Write-NdjsonRow ([ordered]@{ id = 'self.toml.uvcorpus'; req = 'REQ-005.1'; pass = $pass; desc = 'The dependencies uv add --script writes are read back by the extractor exactly as tomllib reads them'; details = $details })
if (-not $pass) { exit 1 }
exit 0
