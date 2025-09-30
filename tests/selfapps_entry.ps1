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

function Invoke-EntryScenario {
    param(
        [string]$Root,
        [string]$LogName,
        [hashtable]$Files
    )

    $result = [ordered]@{
        exitCode = $null
        log = ''
        crumb = ''
        error = $null
    }

    try {
        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $Root | Out-Null

        Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $Root -Force

        foreach ($name in $Files.Keys) {
            $content = $Files[$name]
            Set-Content -LiteralPath (Join-Path -Path $Root -ChildPath $name) -Value $content -Encoding Ascii -NoNewline
        }

        $setupLog = Join-Path -Path $Root -ChildPath '~setup.log'
        if (Test-Path -LiteralPath $setupLog) {
            Remove-Item -LiteralPath $setupLog -Force
        }

        $bootstrapLog = Join-Path -Path $Root -ChildPath $LogName
        if (Test-Path -LiteralPath $bootstrapLog) {
            Remove-Item -LiteralPath $bootstrapLog -Force
        }

        Push-Location -LiteralPath $Root
        try {
            cmd /c .\run_setup.bat *> $LogName
            $result.exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        if (Test-Path -LiteralPath $setupLog) {
            $result.log = Get-Content -LiteralPath $setupLog -Raw -Encoding Ascii
            $match = [regex]::Match($result.log, '^Chosen entry: (.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if ($match.Success) {
                $result.crumb = $match.Groups[1].Value
            }
        }
    }
    catch {
        $result.error = $_.Exception.Message
    }

    return $result
}

# Scenario A: main.py should win over app.py when both present
$scenarioA = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entryA') -LogName '~entryA_bootstrap.log' -Files ([ordered]@{
    'main.py' = @'
if __name__ == "__main__":
    print("from-main")
'@
    'app.py' = @'
if __name__ == "__main__":
    print("from-app")
'@
})

$detailsA = [ordered]@{
    exitCode = $scenarioA.exitCode
}
if ($scenarioA.crumb) { $detailsA.breadcrumb = $scenarioA.crumb }
if (-not $scenarioA.log) { $detailsA.logMissing = $true }
if ($scenarioA.log -and -not $scenarioA.crumb) { $detailsA.breadcrumbMissing = $true }
if ($scenarioA.error) { $detailsA.error = $scenarioA.error }

$passA = ([string]::IsNullOrEmpty($scenarioA.error)) -and ($scenarioA.exitCode -eq 0) -and ($scenarioA.log -match 'Chosen entry: .*\\main\.py')

Add-Content -LiteralPath $nd -Value (@{
    id='entry.choose.commonname'
    pass=$passA
    desc='main.py beats app.py'
    details=$detailsA
} | ConvertTo-Json -Compress) -Encoding Ascii

# Scenario B: prefer common names or guarded modules when picking entries
$scenarioB = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entryB') -LogName '~entryB_bootstrap.log' -Files ([ordered]@{
    'app.py' = @'
if __name__ == "__main__":
    print("from-app")
'@
    'foo.py' = @'
if __name__ == "__main__":
    print("from-guard")
'@
})

$detailsB = [ordered]@{
    exitCode = $scenarioB.exitCode
}
if ($scenarioB.crumb) { $detailsB.breadcrumb = $scenarioB.crumb }
if (-not $scenarioB.log) { $detailsB.logMissing = $true }
if ($scenarioB.log -and -not $scenarioB.crumb) { $detailsB.breadcrumbMissing = $true }
if ($scenarioB.error) { $detailsB.error = $scenarioB.error }

$hasApp = $scenarioB.log -match 'Chosen entry: .*\\app\.py'
$hasFoo = $scenarioB.log -match 'Chosen entry: .*\\foo\.py'
$passB = ([string]::IsNullOrEmpty($scenarioB.error)) -and ($scenarioB.exitCode -eq 0) -and ($hasApp -or $hasFoo)

Add-Content -LiteralPath $nd -Value (@{
    id='entry.choose.guard_or_name'
    pass=$passB
    desc='Choose __main__ guard or common name'
    details=$detailsB
} | ConvertTo-Json -Compress) -Encoding Ascii
