$ErrorActionPreference = 'Stop'

$resultsPath = Join-Path $PSScriptRoot '~test-results.ndjson'
$repoRoot = Split-Path -Parent $PSScriptRoot
$record = [ordered]@{
    id = 'self.empty_repo.msg'
    pass = $false
    desc = "Empty repo emits 'No Python files detected'"
    details = [ordered]@{}
}

try {
    $selfTestDir = Join-Path $PSScriptRoot '~selftest_empty'
    if (-not (Test-Path $selfTestDir)) {
        New-Item -ItemType Directory -Force -Path $selfTestDir | Out-Null
    }

    Copy-Item -Path (Join-Path $repoRoot 'run_setup.bat') -Destination $selfTestDir -Force

    Push-Location $selfTestDir
    try {
        $logPath = Join-Path $selfTestDir '~empty_bootstrap.log'
        if (Test-Path $logPath) {
            Remove-Item -Path $logPath -Force
        }

        & cmd.exe /d /c run_setup.bat 2>&1 | Tee-Object -FilePath $logPath -Encoding Ascii | Out-Null

        $record.details.exitCode = $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) {
            Write-Host "run_setup.bat exited with code $LASTEXITCODE"
        }

        if (-not (Test-Path $logPath)) {
            New-Item -ItemType File -Path $logPath -Force | Out-Null
        }

        $logContent = Get-Content -Path $logPath -Raw -Encoding Ascii
        $record.details.logTail = ($logContent -split "`r?`n") | Select-Object -Last 20 -join "`n"

        if ($logContent -match 'Python file count: 0' -or $logContent -match 'No Python files detected; skipping environment bootstrap.') {
            $record.pass = $true
        } else {
            throw "Expected bootstrap message was not found in log."
        }
    }
    finally {
        Pop-Location
    }
}
catch {
    $record.details.error = $_.Exception.Message
    $record.pass = $false
}
finally {
    $json = $record | ConvertTo-Json -Compress
    Add-Content -Path $resultsPath -Value $json -Encoding Ascii
}

if (-not $record.pass) {
    $message = if ($record.details.Contains('error')) { $record.details.error } else { 'Expected bootstrap message missing.' }
    Write-Error "Empty repo self-test failed: $message"
    exit 1
}
