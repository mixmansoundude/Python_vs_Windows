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

function Write-EntryRow {
    param(
        [string]$Id,
        [string]$Expected,
        [hashtable]$Scenario,
        [string]$Description
    )

    $chosen = $Scenario.crumb
    if ($null -eq $chosen) { $chosen = '' }

    $details = [ordered]@{
        exitCode = $Scenario.exitCode
        expected = $Expected
        chosen   = $chosen
    }

    if ($Scenario.error) {
        $details.error = $Scenario.error
    }

    $pass = ($Scenario.exitCode -eq 0) -and ($chosen -eq $Expected)

    Add-Content -LiteralPath $nd -Value (@{
        id      = $Id
        pass    = $pass
        desc    = $Description
        details = $details
    } | ConvertTo-Json -Compress) -Encoding Ascii
}

# Scenario 1: single entry file should breadcrumb correctly
$scenario1 = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry1') -LogName '~entry1_bootstrap.log' -Files ([ordered]@{
    'entry1.py' = @'
if __name__ == "__main__":
    print("from-entry1")
'@
})
$expected1 = Join-Path '.' 'entry1.py'
Write-EntryRow -Id 'self.entry.entry1' -Expected $expected1 -Scenario $scenario1 -Description 'Single entry file detected'

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
$expectedA = Join-Path '.' 'main.py'
Write-EntryRow -Id 'self.entry.entryA' -Expected $expectedA -Scenario $scenarioA -Description 'main.py beats app.py'

# Scenario B: prefer common names over generic modules when picking entries
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
$expectedB = Join-Path '.' 'app.py'
Write-EntryRow -Id 'self.entry.entryB' -Expected $expectedB -Scenario $scenarioB -Description 'app.py preferred over generic modules'
