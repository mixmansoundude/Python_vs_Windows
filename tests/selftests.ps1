$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$resultsPath = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$repoRoot = Split-Path -Parent $here

$record = [ordered]@{
    id = 'self.empty_repo.msg'
    pass = $false
    desc = "Empty repo emits 'No Python files detected'"
    details = [ordered]@{
        logExists = $false
    }
}

try {
    $selfTestDir = Join-Path -Path $here -ChildPath '~selftest_empty'
    if (-not (Test-Path -LiteralPath $selfTestDir)) {
        New-Item -ItemType Directory -Force -Path $selfTestDir | Out-Null
    }

    $bootstrapperPath = Join-Path -Path $repoRoot -ChildPath 'run_setup.bat'
    Copy-Item -LiteralPath $bootstrapperPath -Destination $selfTestDir -Force

    Push-Location -Path $selfTestDir
    try {
        $logPath = Join-Path -Path $selfTestDir -ChildPath '~empty_bootstrap.log'
        if (Test-Path -LiteralPath $logPath) {
            Remove-Item -LiteralPath $logPath -Force
        }

        cmd.exe /d /c "run_setup.bat *> ~empty_bootstrap.log" | Out-Null

        $record.details.logExists = Test-Path -LiteralPath $logPath
        if ($record.details.logExists) {
            $logContent = Get-Content -LiteralPath $logPath -Raw -Encoding Ascii
            $lines = $logContent -split "`r?`n"
            $found = $false
            foreach ($line in $lines) {
                if ($line -match 'Python file count: 0' -or $line -match 'No Python files detected; skipping environment bootstrap\.') {
                    $found = $true
                    break
                }
            }
            if ($found) {
                $record.pass = $true
            }
        }
    }
    finally {
        Pop-Location
    }
}
catch {
    $record.pass = $false
    $record.error = $_.Exception.Message
}
finally {
    $json = $record | ConvertTo-Json -Compress
    Add-Content -LiteralPath $resultsPath -Value $json -Encoding Ascii
}
