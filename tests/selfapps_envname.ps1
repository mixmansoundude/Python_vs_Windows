# ASCII only
# selfapps_envname.ps1 - REQ-004 env-name sanitization edge case.
#
# A folder name starting with a hyphen must not flow through to `conda create -n -foo`,
# where argparse would treat "-foo" as a command-line flag (malformed). The sanitizer
# replaces a leading hyphen run with "_" (internal hyphens like my-app are preserved).
# Runs with HP_CI_SKIP_ENV=1 (no conda needed) and asserts the derived env name logged
# by run_setup.bat is conda-safe.
#
# Lane: any (cheap, skip-env).
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

if (-not $IsWindows) {
    Write-NdjsonRow ([ordered]@{
        id='self.envname.hyphen'; req='REQ-004'; pass=$true
        desc='Leading-hyphen folder name sanitized to a conda-safe env name (skipped on non-Windows)'
        details=[ordered]@{ skip=$true; reason='non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
# Leaf folder name deliberately starts with a hyphen.
$workDir = Join-Path $here '-hyphen-start'
if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -LiteralPath $batchPath -Destination $workDir -Force
Set-Content -LiteralPath (Join-Path $workDir 'entry.py') -Value "print('hi')`n" -Encoding ASCII

$prevSkip = if (Test-Path Env:HP_CI_SKIP_ENV) { $env:HP_CI_SKIP_ENV } else { $null }
$prevPip  = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_CI_SKIP_ENV = '1'
$env:HP_SKIP_PIPREQS = '1'
$bootstrapLog = '~envname_bootstrap.log'
$exit = -1
Push-Location -LiteralPath $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $exit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prevSkip) { Remove-Item Env:HP_CI_SKIP_ENV -ErrorAction SilentlyContinue } else { $env:HP_CI_SKIP_ENV = $prevSkip }
    if ($null -eq $prevPip)  { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevPip }
}

$logPath  = Join-Path $workDir $bootstrapLog
$setupLog = Join-Path $workDir '~setup.log'
$logText  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Raw -Encoding ASCII } else { '' }
$setupTxt = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined = $logText + "`n" + $setupTxt

# Expected sanitized name: leading "-" -> "_", internal hyphens preserved.
$expectedName  = '_hyphen-start'
$sawExpected   = $combined -match [regex]::Escape("Environment name: $expectedName")
# Guard: the env name must never be logged with a leading hyphen.
$sawBadLeading = $combined -match 'Environment name:\s+-'

$pass = ($exit -eq 0) -and $sawExpected -and (-not $sawBadLeading)

Write-NdjsonRow ([ordered]@{
    id='self.envname.hyphen'
    req='REQ-004'
    pass=$pass
    desc='Leading-hyphen folder name sanitized to a conda-safe env name (no leading hyphen)'
    details=[ordered]@{
        exitCode      = $exit
        expectedName  = $expectedName
        sawExpected   = $sawExpected
        sawBadLeading = $sawBadLeading
        log           = $bootstrapLog
    }
})

if (-not $pass) { exit 1 }
exit 0
