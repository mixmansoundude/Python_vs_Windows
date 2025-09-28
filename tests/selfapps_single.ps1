$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$repoRoot = Split-Path -Path $here -Parent
$nd = Join-Path $here '~test-results.ndjson'

if (-not (Test-Path -LiteralPath $nd)) {
    New-Item -ItemType File -Path $nd -Force | Out-Null
}

$app = Join-Path $here '~entry1'
$logName = '~entry1_bootstrap.log'
$logPath = Join-Path $app $logName

$record = [ordered]@{
    id = 'entry.single.direct'
    pass = $false
    desc = 'Exactly one .py is executed directly'
    details = [ordered]@{}
}

try {
    New-Item -ItemType Directory -Force -Path $app | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'run_setup.bat') -Destination $app -Force

    $solo = Join-Path $app 'solo.py'
    $source = @'
if __name__ == "__main__":
    print("from-single")
'@
    Set-Content -LiteralPath $solo -Value $source -Encoding Ascii -NoNewline

    if (Test-Path -LiteralPath $logPath) {
        Remove-Item -LiteralPath $logPath -Force
    }

    Push-Location -LiteralPath $app
    try {
        cmd /c .\run_setup.bat *> '~entry1_bootstrap.log'
    }
    finally {
        Pop-Location
    }

    $ok = $false
    if (Test-Path -LiteralPath $logPath) {
        $content = Get-Content -LiteralPath $logPath -Raw -Encoding Ascii
        if ($content -match 'from-single') {
            $ok = $true
        }
        else {
            $record.details.missingToken = $true
        }
    }
    else {
        $record.details.logMissing = $true
    }

    $record.pass = $ok
}
catch {
    $record.pass = $false
    $record.details.error = $_.Exception.Message
}
finally {
    try {
        $row = $record | ConvertTo-Json -Compress
        Add-Content -LiteralPath $nd -Value $row -Encoding Ascii
    }
    catch {
        # Swallow serialization issues; logging best-effort only.
    }
}
