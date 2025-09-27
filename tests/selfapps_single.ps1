$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$resultsPath = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$entryRoot = Join-Path -Path $here -ChildPath '~entry1'
$logName = '~entry1_bootstrap.log'
$token = 'from-single'
$repoRoot = Split-Path -Parent $here
$bootstrapperName = 'run_setup.bat'
$bootstrapperSrc = Join-Path -Path $repoRoot -ChildPath $bootstrapperName
$bootstrapperDest = Join-Path -Path $entryRoot -ChildPath $bootstrapperName

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
        'def main():'
        "    print('$token')"
        ''
        "if __name__ == '__main__':"
        '    main()'
    ) -join "`n"
    Set-Content -LiteralPath $pyPath -Value $pySource -Encoding Ascii

    if (Test-Path -LiteralPath $bootstrapperDest) {
        Remove-Item -LiteralPath $bootstrapperDest -Force
    }
    if (Test-Path -LiteralPath $bootstrapperSrc) {
        Copy-Item -LiteralPath $bootstrapperSrc -Destination $bootstrapperDest -Force
    }

    $logPath = Join-Path -Path $entryRoot -ChildPath $logName
    if (Test-Path -LiteralPath $logPath) {
        Remove-Item -LiteralPath $logPath -Force
    }

    Push-Location -Path $entryRoot
    try {
        cmd.exe /d /c "run_setup.bat *> $logName" | Out-Null
    }
    finally {
        Pop-Location
    }

    if (Test-Path -LiteralPath $logPath) {
        $logContent = Get-Content -LiteralPath $logPath -Raw -Encoding Ascii
        if ($null -ne $logContent -and $logContent.Contains($token)) {
            $record.pass = $true
        }
    }
}
catch {
    $record.pass = $false
}
finally {
    $json = $record | ConvertTo-Json -Compress
    Add-Content -LiteralPath $resultsPath -Value $json -Encoding Ascii
}
