$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$resultsPath = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$entryRoot = Join-Path -Path $here -ChildPath '~entry1'
$logName = '~entry1_bootstrap.log'
$logPath = Join-Path -Path $entryRoot -ChildPath $logName
$token = 'from-single'

$record = [ordered]@{
    id = 'entry.single.direct'
    pass = $false
    desc = 'Exactly one .py is executed directly'
    details = [ordered]@{}
}

try {
    if (-not (Test-Path -LiteralPath $entryRoot)) {
        New-Item -ItemType Directory -Force -Path $entryRoot | Out-Null
    }

    $pyPath = Join-Path -Path $entryRoot -ChildPath 'solo.py'
    $pySource = @(
        'if __name__ == "__main__":'
        '    print("from-single")'
    ) -join "`n"
    Set-Content -LiteralPath $pyPath -Value $pySource -Encoding Ascii

    if (Test-Path -LiteralPath $logPath) {
        Remove-Item -LiteralPath $logPath -Force
    }

    $hasToken = $false

    Push-Location -LiteralPath $entryRoot
    try {
        cmd.exe /d /c '..\..\run_setup.bat *> "~entry1_bootstrap.log"' | Out-Null
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if (Test-Path -LiteralPath $logPath) {
        $logContent = Get-Content -LiteralPath $logPath -Raw -Encoding Ascii
        if ($null -ne $logContent -and $logContent.Contains($token)) {
            $hasToken = $true
        }
        else {
            $record.details.missingToken = $true
        }
    }
    else {
        $record.details.logMissing = $true
    }

    if ($null -ne $exitCode -and $exitCode -ne 0) {
        $record.details.exitCode = $exitCode
    }

    if ($hasToken -and -not $record.details.Contains('exitCode')) {
        $record.pass = $true
    }
}
catch {
    $record.pass = $false
    $record.details.error = ($_ | Out-String).Trim()
}
finally {
    $json = $record | ConvertTo-Json -Compress
    Add-Content -LiteralPath $resultsPath -Value $json -Encoding Ascii
}
