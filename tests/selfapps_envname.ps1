# ASCII only
# selfapps_envname.ps1 - REQ-004 env-name sanitization edge cases.
#
# Two scenarios (ENVNAME_SCENARIO env var; unset defaults to 'hyphen'):
#
# - 'hyphen' (default): a folder name starting with a hyphen must not flow through to
#   `conda create -n -foo`, where argparse would treat "-foo" as a command-line flag
#   (malformed). The sanitizer replaces a leading hyphen run with "_" (internal hyphens
#   like my-app are preserved).
# - 'ampersand' (CLAUDE.md Item 26): '&' is special-cased to the bare word 'and' BEFORE
#   the blanket [^A-Za-z0-9_-] -> '_' substitution runs, so a folder like "Sales & Marketing"
#   sanitizes to the more legible "Sales_and_Marketing" instead of "Sales___Marketing" --
#   readability only, not a safety fix (the blanket substitution alone already prevented the
#   real hazard: a raw '&' in the exported filename confusing URL query-string parsing or
#   rendering oddly in Outlook).
#
# Both scenarios run with HP_CI_SKIP_ENV=1 (no conda needed) and assert the derived env name
# logged by run_setup.bat matches expectations.
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

$scenario = if ($env:ENVNAME_SCENARIO) { $env:ENVNAME_SCENARIO } else { 'hyphen' }
# derived requirement: reject an unrecognized ENVNAME_SCENARIO explicitly instead of silently
# running the hyphen scenario via a catch-all default -- a typo'd CI env var should fail loudly,
# not quietly substitute a different test and still report pass.
if ($scenario -notin @('hyphen', 'ampersand')) {
    Write-Error "selfapps_envname.ps1: unknown ENVNAME_SCENARIO value '$scenario' (expected 'hyphen' or 'ampersand')."
    exit 1
}
switch ($scenario) {
    'ampersand' {
        $folderName   = 'Sales & Marketing'
        $expectedName = 'Sales_and_Marketing'
        $desc         = "'&' special-cased to 'and' before the blanket sanitizer runs (readability, CLAUDE.md Item 26)"
    }
    'hyphen' {
        $folderName   = '-hyphen-start'
        $expectedName = '_hyphen-start'
        $desc         = 'Leading-hyphen folder name sanitized to a conda-safe env name (no leading hyphen)'
    }
}

if (-not $IsWindows) {
    # derived requirement: tools/check_ndjson_registry.py's static scan matches a literal
    # id='...' hashtable-literal pattern (\bid\s*=\s*['"]...['"]), not a variable reference --
    # each scenario's id must appear as a literal string at its own Write-NdjsonRow call site,
    # not only assigned to $rowId above, or the row is (falsely) flagged as doc-only/unemitted.
    if ($scenario -eq 'ampersand') {
        Write-NdjsonRow ([ordered]@{
            id='self.envname.ampersand'; req='REQ-004'; pass=$true
            desc="$desc (skipped on non-Windows)"
            details=[ordered]@{ skip=$true; reason='non-windows-host' }
        })
    } else {
        Write-NdjsonRow ([ordered]@{
            id='self.envname.hyphen'; req='REQ-004'; pass=$true
            desc="$desc (skipped on non-Windows)"
            details=[ordered]@{ skip=$true; reason='non-windows-host' }
        })
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
$workDir = Join-Path $here $folderName
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

# derived requirement: case-sensitive, line-anchored match -- a loose case-insensitive substring
# search could false-positive on an incorrectly-cased value that happens to still contain the
# right characters.
$expectedPattern = "(?m)^[^\r\n]*Environment name:[ \t]+$([regex]::Escape($expectedName))[ \t]*(?:\r?$)"
$sawExpected = $combined -cmatch $expectedPattern
# Guard, scenario-specific: the hyphen case must never log a leading hyphen; the ampersand case
# must never log a raw, unsubstituted '&' anywhere on the "Environment name:" line (proves the
# special-case actually ran, not just that the blanket rule alone happened to produce a readable
# result by coincidence). Matches anywhere later on the line, not just immediately after the
# colon -- a raw, unsubstituted "Sales & Marketing" has a space (not a non-space run) before the
# '&', which an earlier \S*&-shaped guard would have missed entirely.
$sawBadPattern = switch ($scenario) {
    'ampersand' { $combined -match '(?m)^[^\r\n]*Environment name:[^\r\n]*&' }
    default     { $combined -match 'Environment name:\s+-' }
}

$pass = ($exit -eq 0) -and $sawExpected -and (-not $sawBadPattern)

# derived requirement: same literal-id-per-call-site reasoning as the non-Windows skip block above.
if ($scenario -eq 'ampersand') {
    Write-NdjsonRow ([ordered]@{
        id='self.envname.ampersand'
        req='REQ-004'
        pass=$pass
        desc=$desc
        details=[ordered]@{
            exitCode      = $exit
            expectedName  = $expectedName
            sawExpected   = $sawExpected
            sawBadPattern = $sawBadPattern
            log           = $bootstrapLog
        }
    })
} else {
    Write-NdjsonRow ([ordered]@{
        id='self.envname.hyphen'
        req='REQ-004'
        pass=$pass
        desc=$desc
        details=[ordered]@{
            exitCode      = $exit
            expectedName  = $expectedName
            sawExpected   = $sawExpected
            sawBadPattern = $sawBadPattern
            log           = $bootstrapLog
        }
    })
}

if (-not $pass) { exit 1 }
exit 0
