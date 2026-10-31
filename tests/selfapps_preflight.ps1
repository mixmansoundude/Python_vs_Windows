# ASCII only
# selfapps_preflight.ps1 - REQ-021: static syntax pre-flight.
# A user entry with a SyntaxError must be reported clearly and EARLY (attributed to the
# user's code) and stop the run gracefully BEFORE the doomed PyInstaller build -- not surface
# later as a confusing "[ERROR] PyInstaller execution failed". The check compiles the entry in memory
# with the interpreter's own parser, so it has zero false positives for the entry file.
#
# self.preflight.syntax      the report is shown, the run stops gracefully, the doomed build is never reached
# self.preflight.attribution README REQ-021.3: the report itself says the mistake is in the user's own program and
#                            not in installing dependencies or building the EXE (read from the same run's console)
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
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.syntax'
        req     = 'REQ-021.2'
        pass    = $true
        desc    = 'REQ-021 pre-flight: syntax error reported + graceful stop (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.attribution'
        req     = 'REQ-021.3'
        pass    = $true
        desc    = 'REQ-021 pre-flight: the report says the mistake is in the own program (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.syntax'
        req     = 'REQ-021.2'
        pass    = $false
        desc    = 'REQ-021 pre-flight: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.attribution'
        req     = 'REQ-021.3'
        pass    = $false
        desc    = 'REQ-021 pre-flight: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_preflight'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# derived requirement: entry.py has an unambiguous SyntaxError (unclosed paren). The check
# exits 1 with a SyntaxError on stderr; the pre-flight surfaces it and stops the run.
# HP_SKIP_PIPREQS=1 keeps pipreqs from any network lookup.
Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
print("this program has a syntax error"
x = 1
'@ -Encoding ASCII

$bootstrapLog = '~preflight_bootstrap.log'

$prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'

Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    if ($null -eq $prev) {
        Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PIPREQS = $prev
    }
    Pop-Location
}

$logPath  = Join-Path $workDir $bootstrapLog
$setupLog = Join-Path $workDir '~setup.log'
$statusF  = Join-Path $workDir '~bootstrap.status.json'
$logLines = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupTxt = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined = ($logLines -join "`n") + "`n" + $setupTxt

# Assertions:
#  - REQ-021 error message present and mentions a syntax error
#  - the SyntaxError detail (the check's stderr) made it through
#  - bootstrap status state == error (graceful stop, not a crash)
#  - the run did NOT reach the doomed PyInstaller build (no "PyInstaller execution failed")
#  - no EXE was produced
$req021Fired   = $combined -match [regex]::Escape('REQ-021') -and ($combined -match 'syntax error')
$syntaxDetail  = $combined -match 'SyntaxError'
$state = ''
if (Test-Path $statusF) {
    try { $state = (Get-Content -LiteralPath $statusF -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { $state = 'unparseable' }
}
$stateError    = ($state -eq 'error')
$noPyiCrash    = -not ($combined -match [regex]::Escape('PyInstaller execution failed'))
$noExe         = -not (Test-Path (Join-Path $workDir 'dist\~selftest_preflight.exe')) -and
                 -not (Test-Path (Join-Path $workDir 'dist'))

$pass = $req021Fired -and $syntaxDetail -and $stateError -and $noPyiCrash

Write-NdjsonRow ([ordered]@{
    id      = 'self.preflight.syntax'
    req     = 'REQ-021.1, REQ-021.2'
    pass    = $pass
    desc    = 'REQ-021 pre-flight: SyntaxError reported clearly and run stops gracefully before the build'
    details = [ordered]@{
        bootstrapExit = $runExit
        req021Fired   = $req021Fired
        syntaxDetail  = $syntaxDetail
        statusState   = $state
        noPyiCrash    = $noPyiCrash
        noExe         = $noExe
        log           = $bootstrapLog
    }
})

# REQ-021.3: between the report's heading and its closing line (the SyntaxError text from the check sits in between) the
# report says whose mistake it is. The block is taken from the console text the user sees; an empty block (heading or
# closing line missing) fails the row.
$attrBlock = ''
$attrFrom = $combined.IndexOf('Your Python program has a syntax error and cannot run.', [System.StringComparison]::Ordinal)
if ($attrFrom -ge 0) {
    $attrRest = $combined.Substring($attrFrom)
    $attrTo = $attrRest.IndexOf('Fix the syntax error shown above', [System.StringComparison]::Ordinal)
    if ($attrTo -ge 0) { $attrBlock = ($attrRest.Substring(0, $attrTo) -replace '\s+', ' ').Trim() }
}
$attrOwn  = $attrBlock -match '(?i)own program'
$attrDeps = $attrBlock -match '(?i)\bnot\b.{0,80}dependenc'
$attrExe  = $attrBlock -match '(?i)dependenc.{0,80}\bEXE\b'
$attrPass = ($attrBlock.Length -gt 0) -and $attrOwn -and $attrDeps -and $attrExe
$attrShown = $attrBlock
if ($attrShown.Length -gt 500) { $attrShown = $attrShown.Substring(0, 500) }
Write-NdjsonRow ([ordered]@{
    id      = 'self.preflight.attribution'
    req     = 'REQ-021.3'
    pass    = $attrPass
    desc    = 'REQ-021 pre-flight: the report says the mistake is in the own program and not in installing dependencies or building the EXE'
    details = [ordered]@{
        blockFound   = ($attrBlock.Length -gt 0)
        namesOwnProgram = $attrOwn
        ruleOutDependencies = $attrDeps
        ruleOutExe   = $attrExe
        reportText   = $attrShown
    }
})

if (-not ($pass -and $attrPass)) { exit 1 }
exit 0
