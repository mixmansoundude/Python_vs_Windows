# ASCII only
# selfapps_unicode_path.ps1 - non-ASCII folder names (docs/plan-test-suite-gaps.md gap T8, REQ-001).
#
# Real machines have accented user profile and project folders (C:\Users\Jose with an accent\Downloads\...).
# The batch, PowerShell, Python, PyInstaller and pip all see that path, and every existing path test
# (self.prime.spaced-path, self.envname.*) uses ASCII only. This script bootstraps a stub program from
#   <tests>\~selftest_unicode_path\Cafe-with-accent Test\Jose-with-accent
# (an accented e in two components, one with a space) and checks, from the program's own record, that it ran
# in exactly that folder. Repo files stay ASCII, so the accent is built at run time with [char]0x00E9.
#
# What a pass asserts (each part can fail on its own, all are listed in the row details):
#   - the bootstrap exits 0 and ~bootstrap.status.json says state ok
#   - the EXE exists under dist and the EXE smoke run finished with exit 0 (no path error in the log)
#   - the program (frozen, started by the bootstrapper) wrote ~unicode_token.json whose cwd names both
#     non-ASCII components unchanged (a lossy conversion to '?' would not compare equal) and whose token matches
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py
# scans text, not PowerShell). The skip row below is its own call site with a literal id.
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"). One bootstrap.
# Emits: self.prime.unicode-path
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
    Write-NdjsonRow ([ordered]@{
        id = 'self.prime.unicode-path'; req = 'REQ-001.2'; pass = $true
        desc = 'Non-ASCII folder bootstrap (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id = 'self.prime.unicode-path'; req = 'REQ-001.2'; pass = $false
        desc = 'Non-ASCII folder bootstrap: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

# --- build the non-ASCII path at run time (U+00E9 is in both Windows-1252 and the common OEM code pages) ---
$eAcute     = [string][char]0x00E9
$parentName = 'Caf' + $eAcute + ' Test'
$leafName   = 'Jos' + $eAcute
$rootDir    = Join-Path $here '~selftest_unicode_path'
$evidence   = Join-Path $here '~selftest_unicode_path_evidence'
foreach ($p in @($rootDir, $evidence)) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Recurse -Force } }
$dir = Join-Path (Join-Path $rootDir $parentName) $leafName
New-Item -ItemType Directory -Force -Path $dir | Out-Null
New-Item -ItemType Directory -Force -Path $evidence | Out-Null
Copy-Item -LiteralPath $batchPath -Destination $dir -Force

$stub = @'
import json
import os
import sys

rec = {
    "token": "unicode-path-ok",
    "cwd": os.getcwd(),
    "frozen": bool(getattr(sys, "frozen", False)),
}
with open("~unicode_token.json", "w") as f:
    f.write(json.dumps(rec) + "\n")
print("unicode-path-ok")
'@
Set-Content -LiteralPath (Join-Path $dir 'unicode_app.py') -Value $stub -Encoding ASCII

$expectedToken = 'unicode-path-ok'

# Never prompt, skip the dependency scan (stdlib-only stub). The batch is started from a generated .cmd so
# that nothing non-ASCII is ever typed into a command line by this script.
$envSet = [ordered]@{ HP_SKIP_PIPREQS = '1' }
if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $envSet['HP_CI_LANE'] = 'test' }
$saved = @{}
foreach ($k in @($envSet.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $envSet[$k]) }
$wrapper = Join-Path $dir '~unicode_launch.cmd'
Set-Content -LiteralPath $wrapper -Value @('@echo off', 'call run_setup.bat unicode_app.py > ~unicode_bootstrap.log 2>&1', 'exit /b %ERRORLEVEL%') -Encoding ASCII
$exitCode = -1
Push-Location -LiteralPath $dir
try {
    cmd /c "call ~unicode_launch.cmd" | Out-Null
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
    foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
}

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
}
$bootText = Read-Text (Join-Path $dir '~unicode_bootstrap.log')
$setupText = Read-Text (Join-Path $dir '~setup.log')
$combined = $bootText + "`n" + $setupText

$statusState = ''
$statusPath = Join-Path $dir '~bootstrap.status.json'
if (Test-Path -LiteralPath $statusPath) {
    try { $statusState = [string]((Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { $statusState = 'unparseable' }
}
$exeFiles = @()
$distDir = Join-Path $dir 'dist'
if (Test-Path -LiteralPath $distDir) { $exeFiles = @(Get-ChildItem -LiteralPath $distDir -Filter '*.exe' -File | ForEach-Object { $_.Name }) }

$token = $null
$tokenPath = Join-Path $dir '~unicode_token.json'
if (Test-Path -LiteralPath $tokenPath) {
    try { $token = (Get-Content -LiteralPath $tokenPath -Raw -Encoding ASCII | ConvertFrom-Json) } catch { $token = $null }
}
$cwd = if ($token) { [string]$token.cwd } else { '' }
$cwdLeaf = if ($cwd) { Split-Path -Path $cwd -Leaf } else { '' }
$cwdParentLeaf = if ($cwd) { Split-Path -Path (Split-Path -Path $cwd -Parent) -Leaf } else { '' }
$cwdOk = ($cwdLeaf -ceq $leafName) -and ($cwdParentLeaf -ceq $parentName)
$tokenOk = ($null -ne $token) -and ([string]$token.token -ceq $expectedToken)
$frozenOk = ($null -ne $token) -and ($token.frozen -eq $true)

$pathErrorPattern = 'The system cannot find the path specified|is not recognized as an internal or external command'
$noPathErrors = -not ($combined -match $pathErrorPattern)
$smokeOk = $combined -match 'Entry smoke exit=0'
$envLine = ([regex]::Match($setupText, '(?m)^.*\[INFO\] Environment name:.*$')).Value.Trim()
$pathLines = @(($combined -split "`r?`n") | Where-Object { $_ -match 'The system cannot find|is not recognized|\[ERROR\]|\[WARN\].*(path|Path)' } | Select-Object -First 12)

foreach ($f in @('~unicode_bootstrap.log', '~setup.log', '~unicode_token.json', '~bootstrap.status.json')) {
    $src = Join-Path $dir $f
    if (Test-Path -LiteralPath $src) { Copy-Item -LiteralPath $src -Destination (Join-Path $evidence $f) -Force }
}

# The non-ASCII folder is removed once its evidence is copied (the ASCII evidence folder keeps what a reader needs),
# so no later step in the job has to walk a non-ASCII path.
$cleanedUp = $false
try { Remove-Item -LiteralPath $rootDir -Recurse -Force -ErrorAction Stop; $cleanedUp = $true } catch { $cleanedUp = $false }

$pass = ($exitCode -eq 0) -and ($statusState -eq 'ok') -and ($exeFiles.Count -ge 1) -and $smokeOk -and $noPathErrors -and $frozenOk -and $cwdOk -and $tokenOk
Write-NdjsonRow ([ordered]@{
    id = 'self.prime.unicode-path'; req = 'REQ-001.2'; pass = [bool]$pass
    desc = 'REQ-001: the bootstrap succeeds from a folder path with a non-ASCII character in two components'
    details = [ordered]@{
        exitCode = $exitCode
        statusState = $statusState
        exeFiles = @($exeFiles)
        entrySmokeExit0 = [bool]$smokeOk
        noPathErrors = [bool]$noPathErrors
        frozen = [bool]$frozenOk
        cwdLeafMatches = [bool]($cwdLeaf -ceq $leafName)
        cwdParentMatches = [bool]($cwdParentLeaf -ceq $parentName)
        cwdLeafCodePoints = @($cwdLeaf.ToCharArray() | ForEach-Object { [int]$_ })
        expectedLeafCodePoints = @($leafName.ToCharArray() | ForEach-Object { [int]$_ })
        tokenSeen = if ($token) { [string]$token.token } else { $null }
        expectedToken = $expectedToken
        environmentLine = $envLine
        cleanedUp = [bool]$cleanedUp
        suspectLines = @($pathLines)
    }
})
if (-not $pass) { exit 1 }
exit 0
