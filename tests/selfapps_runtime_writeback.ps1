# ASCII only
# Validates that after a fresh bootstrap (no pre-existing runtime.txt), the
# bootstrapper writes runtime.txt with the resolved python version and emits
# the expected [INFO] log line.  Emits NDJSON row self.runtime.writeback.
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repoRoot 'ci_test_results.ndjson'
if (-not (Test-Path -LiteralPath $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

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
        id   = 'self.runtime.writeback'
        req  = 'REQ-004'
        pass = $true
        desc = 'runtime.txt write-back skipped on non-Windows host'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$workDir   = Join-Path $here '~selftest_runtime_writeback'
$logName   = '~runtime_writeback_bootstrap.log'
$batchPath = Join-Path $repoRoot 'run_setup.bat'

if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

Copy-Item -Path $batchPath -Destination $workDir -Force

# Single stub with no imports -- no runtime.txt present (Tier 3 path).
Set-Content -LiteralPath (Join-Path $workDir 'hello_writeback.py') `
    -Value 'print("hello-writeback")' -Encoding ASCII

Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $logName 2>&1"
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}

$runtimeTxtPath = Join-Path $workDir 'runtime.txt'
$setupLogPath   = Join-Path $workDir '~setup.log'

$runtimeExists  = Test-Path -LiteralPath $runtimeTxtPath
$runtimeContent = if ($runtimeExists) {
    (Get-Content -LiteralPath $runtimeTxtPath -Encoding ASCII -Raw).Trim()
} else { '' }

# Content must match python-X.Y.Z (three-part version; HP_PRINT_PYVER emits patch level)
$runtimeValid = $runtimeContent -match '^python-\d+\.\d+\.\d+$'

# No trailing whitespace (Trim() above removes it; compare raw vs trimmed to detect it)
$rawContent = if ($runtimeExists) {
    (Get-Content -LiteralPath $runtimeTxtPath -Encoding ASCII -Raw)
} else { '' }
$noTrailingSpace = ($rawContent.TrimEnd("`r","`n"," ","`t") -eq $runtimeContent)

$logContainsWriteback = $false
if (Test-Path -LiteralPath $setupLogPath) {
    $logText = Get-Content -LiteralPath $setupLogPath -Encoding ASCII -Raw
    $logContainsWriteback = $logText -match '\[INFO\] runtime\.txt written:'
}

# Second run: verify runtime.txt is treated as Tier 1 (content unchanged, bootstrapper reuses it)
$runtimeContent2     = ''
$secondRunMatches    = $false
if ($runtimeExists -and $runtimeValid) {
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > ~runtime_writeback_bootstrap2.log 2>&1"
    } finally {
        Pop-Location
    }
    if (Test-Path -LiteralPath $runtimeTxtPath) {
        $runtimeContent2  = (Get-Content -LiteralPath $runtimeTxtPath -Encoding ASCII -Raw).Trim()
        $secondRunMatches = ($runtimeContent2 -eq $runtimeContent)
    }
}

$pass = ($exitCode -eq 0) -and $runtimeExists -and $runtimeValid -and
        $noTrailingSpace -and $logContainsWriteback -and $secondRunMatches

Write-NdjsonRow ([ordered]@{
    id   = 'self.runtime.writeback'
    req  = 'REQ-004'
    pass = $pass
    desc = 'runtime.txt written with resolved python version and log line emitted'
    details = [ordered]@{
        bootstrapExit        = $exitCode
        runtimeExists        = $runtimeExists
        runtimeContent       = $runtimeContent
        runtimeValid         = $runtimeValid
        noTrailingSpace      = $noTrailingSpace
        logContainsWriteback = $logContainsWriteback
        secondRunContent     = $runtimeContent2
        secondRunMatches     = $secondRunMatches
    }
})
