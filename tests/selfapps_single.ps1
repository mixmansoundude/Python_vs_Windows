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

$exitCode = $null
$log = ''
$crumb = ''
$errorMessage = $null

try {
    if (Test-Path -LiteralPath $app) {
        Remove-Item -LiteralPath $app -Recurse -Force
    }
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
        cmd /c .\run_setup.bat *> $logName
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if (Test-Path -LiteralPath $logPath) {
        $log = Get-Content -LiteralPath $logPath -Raw -Encoding Ascii
        $match = [regex]::Match($log, '^Chosen entry: (.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
        if ($match.Success) {
            $crumb = $match.Groups[1].Value
        }
    }
}
catch {
    $errorMessage = $_.Exception.Message
}
finally {
    $details = [ordered]@{
        exitCode = $exitCode
    }
    if ($crumb) { $details.breadcrumb = $crumb }
    if (-not $log) { $details.logMissing = $true }
    if ($log -and -not $crumb) { $details.breadcrumbMissing = $true }
    if ($errorMessage) { $details.error = $errorMessage }

    $pass = ([string]::IsNullOrEmpty($errorMessage)) -and ($exitCode -eq 0) -and ($log -match 'Chosen entry: .*\\solo\.py')

    Add-Content -LiteralPath $nd -Value (@{
        id='entry.single.direct'
        pass=$pass
        desc='Exactly one .py chosen and run'
        details=$details
    } | ConvertTo-Json -Compress) -Encoding Ascii
}
