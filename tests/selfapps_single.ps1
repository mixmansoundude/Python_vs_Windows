$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$repoRoot = Split-Path -Path $here -Parent
$nd = Join-Path -Path $here -ChildPath '~test-results.ndjson'

if (-not (Test-Path -LiteralPath $nd)) {
    New-Item -ItemType File -Path $nd -Force | Out-Null
}

$app = Join-Path -Path $here -ChildPath '~entry1'
$logName = '~entry1_bootstrap.log'
$logPath = Join-Path -Path $app -ChildPath $logName

$record = [ordered]@{
    id = 'entry.single.direct'
    pass = $false
    desc = 'Exactly one .py is executed directly'
    details = [ordered]@{}
}

$exitCode = $null

try {
    New-Item -ItemType Directory -Force -Path $app | Out-Null

    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $app -Force

    $solo = Join-Path -Path $app -ChildPath 'solo.py'
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
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $log = $null
    if (Test-Path -LiteralPath $logPath) {
        $log = Get-Content -LiteralPath $logPath -Raw -Encoding Ascii
    }

    $hasToken = $false
    $hasCrumb = $false
    if ($log) {
        $hasToken = ($log -match 'from-single')
        $hasCrumb = ($log -match 'Chosen entry: .*\\solo\.py')
        if (-not $hasToken) {
            $record.details.missingToken = $true
        }
        if (-not $hasCrumb) {
            $record.details.missingBreadcrumb = $true
        }
    } else {
        $record.details.logMissing = $true
    }

    $mode = if ($hasToken) { 'token' } else { 'breadcrumb' }
    $pass = (($exitCode -eq 0) -and ($hasToken -or $hasCrumb))
    $record.pass = $pass
    $record.details.exitCode = $exitCode
    $record.details.mode = $mode
}
catch {
    $record.pass = $false
    $record.details.exitCode = $exitCode
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
