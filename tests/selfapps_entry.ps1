$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$repoRoot = Split-Path -Path $here -Parent
$nd = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$ciNd = Join-Path -Path $repoRoot -ChildPath 'ci_test_results.ndjson'

if (-not (Test-Path -LiteralPath $nd)) {
    New-Item -ItemType File -Path $nd -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $ciNd)) {
    New-Item -ItemType File -Path $ciNd -Force | Out-Null
}

function Write-NdjsonRow {
    param([hashtable]$Row)

    $json = $Row | ConvertTo-Json -Compress
    Add-Content -LiteralPath $nd -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

function Get-LineSnippet {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if (-not $Text) { return '' }
    foreach ($line in $Text -split "`r?`n") {
        if ($line -match $Pattern) {
            $trimmed = $line.Trim()
            if ($trimmed.Length -gt 160) { return $trimmed.Substring(0,160) }
            return $trimmed
        }
    }
    return ''
}

function Emit-FailureRow {
    param(
        [string]$Id,
        [string]$Description,
        [string]$FilePath,
        [string]$Pattern,
        [string]$LogText
    )

    if (-not $LogText) {
        $LogText = Get-Content -LiteralPath $FilePath -Raw -Encoding Ascii
    }
    $snippet = Get-LineSnippet -Text $LogText -Pattern $Pattern
    $details = [ordered]@{ file = $FilePath }
    if ($snippet) { $details.snippet = $snippet }

    Write-NdjsonRow ([ordered]@{
        id      = $Id
        pass    = $false
        desc    = $Description
        details = $details
    })
}

$script:RecordedPipreqs = $false
$script:RecordedHelperInvoke = $false

function Check-PipreqsFailure {
    param(
        [string]$LogPath,
        [string]$LogText
    )

    if ($script:RecordedPipreqs -or -not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return }
    if (-not $LogText) { $LogText = Get-Content -LiteralPath $LogPath -Raw -Encoding Ascii }

    $patterns = @(
        'No module named pipreqs\.__main__',
        'ERROR\s+conda\.cli\.main_run:execute\(127\):'
    )

    foreach ($pattern in $patterns) {
        if ($LogText -match $pattern) {
            Emit-FailureRow -Id 'pipreqs.run' -Description 'pipreqs invocation failed during bootstrap' -FilePath $LogPath -Pattern $pattern -LogText $LogText
            $script:RecordedPipreqs = $true
            break
        }
    }
}

function Check-HelperInvokeFailure {
    param(
        [string]$LogPath,
        [string]$LogText
    )

    if ($script:RecordedHelperInvoke -or -not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return }
    if (-not $LogText) { $LogText = Get-Content -LiteralPath $LogPath -Raw -Encoding Ascii }

    $patterns = @(
        @{ Pattern = '''python" "~find_entry\.py'' is not recognized as an internal or external command'; RequireFindEntry = $false },
        @{ Pattern = 'SyntaxError:'; RequireFindEntry = $true }
    )

    foreach ($item in $patterns) {
        $pattern = $item.Pattern
        if ($LogText -match $pattern) {
            if ($item.RequireFindEntry -and ($LogText -notmatch '~find_entry\.py')) { continue }
            Emit-FailureRow -Id 'helper.invoke' -Description 'Entry helper failed to execute under Python' -FilePath $LogPath -Pattern $pattern -LogText $LogText
            $script:RecordedHelperInvoke = $true
            break
        }
    }
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
        setupPath = $null
        setupLog = ''
        bootstrapPath = $null
        bootstrapLog = ''
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

        $result.setupPath = $setupLog
        if (Test-Path -LiteralPath $setupLog) {
            $result.log = Get-Content -LiteralPath $setupLog -Raw -Encoding Ascii
            $result.setupLog = $result.log
            $match = [regex]::Match($result.log, '^Chosen entry: (.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if ($match.Success) {
                $result.crumb = $match.Groups[1].Value
            }
        }

        $result.bootstrapPath = $bootstrapLog
        if (Test-Path -LiteralPath $bootstrapLog) {
            $result.bootstrapLog = Get-Content -LiteralPath $bootstrapLog -Raw -Encoding Ascii
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

    Write-NdjsonRow ([ordered]@{
        id      = $Id
        pass    = $pass
        desc    = $Description
        details = $details
    })
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
Check-PipreqsFailure -LogPath $scenario1.setupPath -LogText $scenario1.setupLog
Check-HelperInvokeFailure -LogPath $scenario1.bootstrapPath -LogText $scenario1.bootstrapLog

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
Check-PipreqsFailure -LogPath $scenarioA.setupPath -LogText $scenarioA.setupLog
Check-HelperInvokeFailure -LogPath $scenarioA.bootstrapPath -LogText $scenarioA.bootstrapLog

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
Check-PipreqsFailure -LogPath $scenarioB.setupPath -LogText $scenarioB.setupLog
Check-HelperInvokeFailure -LogPath $scenarioB.bootstrapPath -LogText $scenarioB.bootstrapLog

$parsedRows = @()
if (Test-Path -LiteralPath $ciNd) {
    foreach ($line in Get-Content -LiteralPath $ciNd -Encoding Ascii) {
        $trim = $line.Trim()
        if (-not $trim) { continue }
        try {
            $parsedRows += ($trim | ConvertFrom-Json)
        } catch {
            # derived requirement: keep parsing resilient so diagnostics survive malformed
            # lines without crashing the self-test loop.
        }
    }
}

$helperRows = @($parsedRows | Where-Object { $_.id -eq 'helper.invoke' })
Write-NdjsonRow ([ordered]@{
    id      = 'self.entry.helper.invoke.absent'
    pass    = ($helperRows.Count -eq 0)
    desc    = 'Helper invocation rows are absent in NDJSON output'
    details = @{ count = $helperRows.Count }
})

$expectedMap = @(
    @{ Id = 'self.entry.entry1'; Expected = $expected1 },
    @{ Id = 'self.entry.entryA'; Expected = $expectedA },
    @{ Id = 'self.entry.entryB'; Expected = $expectedB }
)
$issues = @()
foreach ($item in $expectedMap) {
    $row = $parsedRows | Where-Object { $_.id -eq $item.Id } | Select-Object -First 1
    if (-not $row) {
        $issues += [ordered]@{ id = $item.Id; reason = 'missing-row' }
        continue
    }
    if (-not $row.pass) {
        $issues += [ordered]@{ id = $item.Id; reason = 'row-failed'; exitCode = $row.details.exitCode; chosen = $row.details.chosen }
        continue
    }
    if (-not $row.details -or -not $row.details.chosen) {
        $issues += [ordered]@{ id = $item.Id; reason = 'missing-chosen' }
    }
}

Write-NdjsonRow ([ordered]@{
    id      = 'self.entry.results'
    pass    = ($issues.Count -eq 0)
    desc    = 'Entry scenarios emitted breadcrumbs and passed'
    details = @{ issues = $issues }
})
