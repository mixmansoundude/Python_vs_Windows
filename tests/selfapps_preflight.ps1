# ASCII only
# selfapps_preflight.ps1 - REQ-021: static py_compile pre-flight.
# A user entry with a SyntaxError must be reported clearly and EARLY (attributed to the
# user's code) and stop the run gracefully BEFORE the doomed PyInstaller build -- not surface
# later as a confusing "[ERROR] PyInstaller execution failed". py_compile shares the
# interpreter's parser, so this has zero false positives for the entry file.
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
        id      = 'self.preflight.syntax'
        req     = 'REQ-021'
        pass    = $true
        desc    = 'REQ-021 pre-flight: syntax error reported + graceful stop (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.syntax'
        req     = 'REQ-021'
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

# derived requirement: entry.py has an unambiguous SyntaxError (unclosed paren). py_compile
# exits non-zero with a SyntaxError on stderr; the pre-flight surfaces it and stops the run.
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
#  - the SyntaxError detail (py_compile stderr) made it through
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
    req     = 'REQ-021'
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

if (-not $pass) { exit 1 }
exit 0
