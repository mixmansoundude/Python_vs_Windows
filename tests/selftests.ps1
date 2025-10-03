$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
$resultsPath = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$summaryPath = Join-Path -Path $here -ChildPath '~selftests-summary.txt'
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('=== Console Self-test ===')
if (Test-Path -LiteralPath $summaryPath) {
    Remove-Item -LiteralPath $summaryPath -Force
}
$repoRoot = Split-Path -Parent $here

if (-not (Test-Path -LiteralPath $resultsPath)) {
    New-Item -ItemType File -Force -Path $resultsPath | Out-Null
}
Add-Content -LiteralPath $resultsPath -Value '{"id":"self.harness.started","pass":true,"desc":"harness init"}' -Encoding Ascii

$record = [ordered]@{
    id = 'self.empty_repo.msg'
    pass = $false
    desc = "Empty repo emits the no-python console lines"
    details = [ordered]@{
        logExists = $false
        missing = @()
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

        $statusPath = Join-Path -Path $selfTestDir -ChildPath '~bootstrap.status.json'
        $stateRow = [ordered]@{
            id = 'self.bootstrap.state'
            pass = $false
            desc = 'status json missing'
            details = [ordered]@{ path = $statusPath }
        }
        if (Test-Path -LiteralPath $statusPath) {
            try {
                $status = Get-Content -LiteralPath $statusPath -Raw -Encoding Ascii | ConvertFrom-Json
                $stateRow.desc = "state=$($status.state)"
                $stateRow.details.state = $status.state
                $stateRow.details.exitCode = $status.exitCode
                $stateRow.details.pyFiles = $status.pyFiles
                if ($status.state -eq 'no_python_files') {
                    $stateRow.pass = $true
                } else {
                    $stateRow.pass = $false
                }
            } catch {
                $stateRow.desc = 'invalid bootstrap status json'
                $stateRow.details.error = $_.Exception.Message
            }
        }
        $stateJson = $stateRow | ConvertTo-Json -Compress
        Add-Content -LiteralPath $resultsPath -Value $stateJson -Encoding Ascii

        $record.details.logExists = Test-Path -LiteralPath $logPath
        if ($record.details.logExists) {
            $logContent = Get-Content -LiteralPath $logPath -Raw -Encoding Ascii
            $lines = $logContent -split "`r?`n"
            $messages = @{ count = $false; skip = $false }
            foreach ($line in $lines) {
                if (-not $messages.count -and $line -match 'Python file count: 0') {
                    $messages.count = $true
                }
                if (-not $messages.skip -and $line -match 'No Python files detected; skipping environment bootstrap\.') {
                    $messages.skip = $true
                }
                if ($messages.count -and $messages.skip) {
                    break
                }
            }
            $missing = @()
            if (-not $messages.count) { $missing += 'Python file count: 0' }
            if (-not $messages.skip) { $missing += 'No Python files detected; skipping environment bootstrap.' }
            $record.details.missing = $missing
            if ($missing.Count -eq 0) {
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
if ($record.pass) {
    $summary.Add('Empty repo bootstrap message: PASS')
} else {
    $summary.Add('Empty repo bootstrap message: FAIL')
    $hasErrorProp = ($record.PSObject.Properties.Match('error').Count -gt 0)
    if ($hasErrorProp -and $record.error) {
        $summary.Add('Error: ' + $record.error)
    } elseif (-not $record.details.logExists) {
        $summary.Add('Error: ~empty_bootstrap.log was not produced')
    } elseif ($record.details.missing.Count -gt 0) {
        $summary.Add('Missing lines: ' + ($record.details.missing -join '; '))
    } else {
        $summary.Add("Error: Expected console lines weren't found")
    }
}
$summary | Set-Content -LiteralPath $summaryPath -Encoding Ascii
if ($record.pass) {
    exit 0
} else {
    exit 1
}
