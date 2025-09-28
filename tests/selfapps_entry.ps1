$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$repoRoot = Split-Path -Path $here -Parent
$nd = Join-Path $here '~test-results.ndjson'
$sharedLog = Join-Path $here '~setup.log'

if (-not (Test-Path -LiteralPath $nd)) {
    New-Item -ItemType File -Path $nd -Force | Out-Null
}

New-Item -ItemType File -Path $sharedLog -Force | Out-Null

function Write-NdjsonRow {
    param([hashtable]$Record)
    try {
        $row = $Record | ConvertTo-Json -Compress
        Add-Content -LiteralPath $nd -Value $row -Encoding Ascii
    }
    catch {
        # Keep reporting best-effort; never block the job summary on conversion noise.
    }
}

function Get-ChosenLine {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    try {
        $lines = Get-Content -LiteralPath $Path -Encoding Ascii | Where-Object { $_ -like 'Chosen entry:*' }
        if ($lines.Count -gt 0) {
            return $lines[$lines.Count - 1]
        }
    }
    catch {
        return $null
    }
    return $null
}

function Append-SharedBreadcrumb {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return
    }
    try {
        Add-Content -LiteralPath $sharedLog -Value $Line -Encoding Ascii
    }
    catch {
        # Shared log replication is best-effort; keep going so the scenario result still records.
    }
}

function Parse-ChosenPath {
    param([string]$Line)
    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $null
    }
    $value = $Line -replace '^Chosen entry:\s*', ''
    return $value.Trim()
}

function Run-Bootstrap {
    param(
        [string]$Root,
        [string]$LogName
    )

    Push-Location -LiteralPath $Root
    try {
        cmd /c .\run_setup.bat *> $LogName
    }
    finally {
        Pop-Location
    }
}

# Scenario A: main.py should win over app.py when both present
$entryARoot = Join-Path $here '~entryA'
$entryALog = '~entryA_bootstrap.log'
$recordCommon = [ordered]@{
    id = 'entry.choose.commonname'
    pass = $false
    desc = 'main.py beats app.py'
    details = [ordered]@{}
}

try {
    if (Test-Path -LiteralPath $entryARoot) {
        Remove-Item -LiteralPath $entryARoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $entryARoot | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'run_setup.bat') -Destination $entryARoot -Force

    $mainPy = @'
if __name__ == "__main__":
    print("from-main")
'@
    $appPy = @'
if __name__ == "__main__":
    print("from-app")
'@
    Set-Content -LiteralPath (Join-Path $entryARoot 'main.py') -Value $mainPy -Encoding Ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $entryARoot 'app.py') -Value $appPy -Encoding Ascii -NoNewline

    $localLog = Join-Path $entryARoot '~setup.log'
    $bootstrapLogPath = Join-Path $entryARoot $entryALog
    if (Test-Path -LiteralPath $localLog) {
        Remove-Item -LiteralPath $localLog -Force
    }
    if (Test-Path -LiteralPath $bootstrapLogPath) {
        Remove-Item -LiteralPath $bootstrapLogPath -Force
    }

    Run-Bootstrap -Root $entryARoot -LogName $entryALog

    $localChosen = Get-ChosenLine -Path $localLog
    if ($localChosen) {
        Append-SharedBreadcrumb -Line $localChosen
    }

    $sharedChosen = Get-ChosenLine -Path $sharedLog
    $chosenPath = Parse-ChosenPath -Line $sharedChosen

    if ($chosenPath) {
        if ($chosenPath -like '*\main.py') {
            $recordCommon.pass = $true
        }
        else {
            $recordCommon.details.chosen = $chosenPath
        }
    }
    else {
        $recordCommon.details.noBreadcrumb = $true
    }
}
catch {
    $recordCommon.pass = $false
    $recordCommon.details.error = $_.Exception.Message
}
finally {
    Write-NdjsonRow -Record $recordCommon
}

# Scenario B: prefer common names or guarded modules when picking entries
$entryBRoot = Join-Path $here '~entryB'
$entryBLog = '~entryB_bootstrap.log'
$recordGuard = [ordered]@{
    id = 'entry.choose.guard_or_name'
    pass = $false
    desc = 'Common name or __main__ guard chosen'
    details = [ordered]@{}
}

try {
    if (Test-Path -LiteralPath $entryBRoot) {
        Remove-Item -LiteralPath $entryBRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $entryBRoot | Out-Null

    Copy-Item -LiteralPath (Join-Path $repoRoot 'run_setup.bat') -Destination $entryBRoot -Force

    $appB = @'
if __name__ == "__main__":
    print("from-app")
'@
    $fooB = @'
if __name__ == "__main__":
    print("from-guard")
'@
    Set-Content -LiteralPath (Join-Path $entryBRoot 'app.py') -Value $appB -Encoding Ascii -NoNewline
    Set-Content -LiteralPath (Join-Path $entryBRoot 'foo.py') -Value $fooB -Encoding Ascii -NoNewline

    $localLogB = Join-Path $entryBRoot '~setup.log'
    $bootstrapLogB = Join-Path $entryBRoot $entryBLog
    if (Test-Path -LiteralPath $localLogB) {
        Remove-Item -LiteralPath $localLogB -Force
    }
    if (Test-Path -LiteralPath $bootstrapLogB) {
        Remove-Item -LiteralPath $bootstrapLogB -Force
    }

    Run-Bootstrap -Root $entryBRoot -LogName $entryBLog

    $localChosenB = Get-ChosenLine -Path $localLogB
    if ($localChosenB) {
        Append-SharedBreadcrumb -Line $localChosenB
    }

    $sharedChosenB = Get-ChosenLine -Path $sharedLog
    $chosenPathB = Parse-ChosenPath -Line $sharedChosenB

    if ($chosenPathB) {
        $recordGuard.details.chosen = $chosenPathB
        if ($chosenPathB -like '*\app.py' -or $chosenPathB -like '*\foo.py') {
            $recordGuard.pass = $true
        }
    }
    else {
        $recordGuard.details.noBreadcrumb = $true
    }
}
catch {
    $recordGuard.pass = $false
    $recordGuard.details.error = $_.Exception.Message
}
finally {
    Write-NdjsonRow -Record $recordGuard
}
