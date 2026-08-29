# ASCII only
# selfapps_envname.ps1 - REQ-004 env-name sanitization edge cases.
#
# Three scenarios (ENVNAME_SCENARIO env var; unset defaults to 'hyphen'):
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
# - 'longname' (CodeRabbit finding on PR #417, follow-up to Item 26): '&'->'and' is a 1-to-3
#   char expansion, unlike every other substitution in this sanitizer (all 1-to-1) -- an
#   ampersand-heavy folder name can make the sanitized result LONGER than the original, so the
#   sanitizer truncates to 64 chars post-substitution. This scenario is the only one that
#   actually exercises that truncation branch.
#
# All three scenarios run with HP_CI_SKIP_ENV=1 (no conda needed) and assert the derived env
# name logged by run_setup.bat matches expectations.
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
# not quietly substitute a different test and still report pass. Still emit a (failed) NDJSON
# row first -- a bare Write-Error/exit with no row at all is invisible to the NDJSON-based
# verdict/registry checks, which would then have no record of why this scenario never ran.
if ($scenario -notin @('hyphen', 'ampersand', 'longname')) {
    Write-Error "selfapps_envname.ps1: unknown ENVNAME_SCENARIO value '$scenario' (expected 'hyphen', 'ampersand', or 'longname')."
    Write-NdjsonRow ([ordered]@{
        id='self.envname.hyphen'; req='REQ-004'; pass=$false
        desc="unknown ENVNAME_SCENARIO value '$scenario'"
        details=[ordered]@{ error='unrecognized-scenario'; scenario=$scenario }
    })
    exit 1
}
switch ($scenario) {
    'ampersand' {
        $folderName   = 'Sales & Marketing'
        $expectedName = 'Sales_and_Marketing'
        $desc         = "'&' special-cased to 'and' before the blanket sanitizer runs (readability, CLAUDE.md Item 26)"
    }
    'longname' {
        # derived requirement (CodeRabbit finding on PR #417): the '&'->'and' substitution is the
        # first 1-to-3-char expansion in this sanitizer (every other substitution is 1-to-1), so a
        # folder name unusually heavy in '&' could make the sanitized name LONGER than the
        # original -- this scenario is the only one that actually exercises the resulting 64-char
        # truncation bound (`run_setup.bat`'s ENVNAME_SANITIZED computation, CLAUDE.md Item 26).
        # 15 repeats of "A & " (4 chars each) = 59 raw chars (short enough to stay well clear of
        # Windows MAX_PATH once nested under tests\), expanding to "A and " (6 chars each) = 89
        # sanitized chars pre-truncation -- comfortably over the 64-char cap.
        $folderName   = ('A & ' * 15).TrimEnd()
        $expectedName = ('A_and_' * 11).Substring(0, 64).TrimEnd('_', '-')
        $desc         = 'Over-64-char, ampersand-heavy folder name exercises the post-substitution truncation bound (CLAUDE.md Item 26)'
    }
    'hyphen' {
        $folderName   = '-hyphen-start'
        $expectedName = '_hyphen-start'
        $desc         = 'Leading-hyphen folder name sanitized to a conda-safe env name (no leading hyphen)'
    }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
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
    } elseif ($scenario -eq 'longname') {
        Write-NdjsonRow ([ordered]@{
            id='self.envname.longname'; req='REQ-004'; pass=$true
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
    'longname'  { $combined -match '(?m)^[^\r\n]*Environment name:[^\r\n]*&' }
    default     { $combined -match 'Environment name:\s+-' }
}

# derived requirement (CodeRabbit finding on PR #417): the 'longname' scenario's whole point is
# proving the 64-char truncation branch actually ran, not just that SOME value was logged --
# extract the logged name via a capture group and assert its length explicitly, decoupled from
# the exact-string match above (which would also pass, coincidentally, if truncation were broken
# in a way that still produced a 64-char string equal to $expectedName by chance).
$loggedNameLen = $null
$sawTruncationBound = $true
if ($scenario -eq 'longname') {
    $captureMatch = [regex]::Match($combined, '(?m)^[^\r\n]*Environment name:[ \t]+([^\r\n \t]+)[ \t]*(?:\r?$)')
    if ($captureMatch.Success) { $loggedNameLen = $captureMatch.Groups[1].Value.Length }
    $sawTruncationBound = ($null -ne $loggedNameLen) -and ($loggedNameLen -le 64)
}

# derived requirement: this scenario deliberately does NOT attempt to prove the truncated name
# flows into a real conda ENV_PATH / `conda create -n <name>` -- like its 'hyphen'/'ampersand'
# siblings, it runs with HP_CI_SKIP_ENV=1 (system Python, no conda) specifically to stay cheap and
# lane-agnostic; ENV_PATH is only ever assigned on the real conda/uv/venv code paths this harness
# intentionally bypasses. What IS proven here: ENVNAME_SANITIZED is computed once, near the very
# top of run_setup.bat, and unconditionally becomes ENVNAME (`set "ENVNAME=%ENVNAME_SANITIZED%"`)
# before ANY provider-specific branch -- so a value confirmed correct here is, by construction,
# the same value every later `%ENVNAME%` substitution (including `ENV_PATH=...\envs\%ENVNAME%`
# and `dist\%ENVNAME%.exe`) will use. Proving the truncated value with a real conda env create is
# already covered by every other test in this file/suite that exercises a full provider build.

$pass = ($exit -eq 0) -and $sawExpected -and (-not $sawBadPattern) -and $sawTruncationBound

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
} elseif ($scenario -eq 'longname') {
    Write-NdjsonRow ([ordered]@{
        id='self.envname.longname'
        req='REQ-004'
        pass=$pass
        desc=$desc
        details=[ordered]@{
            exitCode           = $exit
            expectedName       = $expectedName
            sawExpected        = $sawExpected
            sawBadPattern       = $sawBadPattern
            loggedNameLen       = $loggedNameLen
            sawTruncationBound  = $sawTruncationBound
            log                 = $bootstrapLog
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
