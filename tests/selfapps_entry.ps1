$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$repoRoot = Split-Path -Path $here -Parent
$nd = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$sharedLog = Join-Path -Path $here -ChildPath '~setup.log'

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

function Get-LastChosenValue {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return ''
    }
    try {
        $match = Select-String -LiteralPath $Path -Pattern '^Chosen entry: (.+)$' -ErrorAction SilentlyContinue
        if ($match) {
            $last = $match | Select-Object -Last 1
            if ($last -and $last.Matches.Count -gt 0) {
                return $last.Matches[0].Groups[1].Value
            }
        }
    }
    catch {
        return ''
    }
    return ''
}

function Invoke-Bootstrap {
    param(
        [string]$Root,
        [string]$LogName
    )

    Push-Location -LiteralPath $Root
    try {
        cmd /c .\run_setup.bat *> $LogName
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    return $exitCode
}

# Scenario A: main.py should win over app.py when both present
$entryARoot = Join-Path -Path $here -ChildPath '~entryA'
$entryALog = '~entryA_bootstrap.log'
$recordCommon = [ordered]@{
    id = 'entry.choose.commonname'
    pass = $false
    desc = 'main.py beats app.py'
    details = [ordered]@{}
}

$exitCodeA = $null

try {
    if (Test-Path -LiteralPath $entryARoot) {
        Remove-Item -LiteralPath $entryARoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $entryARoot | Out-Null

    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $entryARoot -Force

    $mainPy = @'
if __name__ == "__main__":
    print("from-main")
'@
    $appPy = @'
if __name__ == "__main__":
    print("from-app")
'@
    Set-Content -LiteralPath (Join-Path -Path $entryARoot -ChildPath 'main.py') -Value $mainPy -Encoding Ascii -NoNewline
    Set-Content -LiteralPath (Join-Path -Path $entryARoot -ChildPath 'app.py') -Value $appPy -Encoding Ascii -NoNewline

    $localLog = Join-Path -Path $entryARoot -ChildPath '~setup.log'
    $bootstrapLogPath = Join-Path -Path $entryARoot -ChildPath $entryALog

    if (Test-Path -LiteralPath $localLog) {
        Remove-Item -LiteralPath $localLog -Force
    }
    if (Test-Path -LiteralPath $bootstrapLogPath) {
        Remove-Item -LiteralPath $bootstrapLogPath -Force
    }

    $exitCodeA = Invoke-Bootstrap -Root $entryARoot -LogName $entryALog

    $localChosen = Get-LastChosenValue -Path $localLog
    if ($localChosen) {
        Append-SharedBreadcrumb -Line "Chosen entry: $localChosen"
    }

    $hasMain = [bool](Select-String -LiteralPath $sharedLog -Pattern 'Chosen entry: .*\\main\.py' -SimpleMatch -ErrorAction SilentlyContinue)
    $chosenPath = Get-LastChosenValue -Path $sharedLog

    $recordCommon.details.exitCode = $exitCodeA
    if ($chosenPath) {
        $recordCommon.details.chosen = $chosenPath
    }

    $recordCommon.pass = (($exitCodeA -eq 0) -and $hasMain)
    if (-not $recordCommon.pass -and -not $chosenPath) {
        $recordCommon.details.noBreadcrumb = $true
    }
}
catch {
    $recordCommon.pass = $false
    $recordCommon.details.exitCode = $exitCodeA
    $recordCommon.details.error = $_.Exception.Message
}
finally {
    Write-NdjsonRow -Record $recordCommon
}

# Scenario B: prefer common names or guarded modules when picking entries
$entryBRoot = Join-Path -Path $here -ChildPath '~entryB'
$entryBLog = '~entryB_bootstrap.log'
$recordGuard = [ordered]@{
    id = 'entry.choose.guard_or_name'
    pass = $false
    desc = 'Common name or __main__ guard chosen'
    details = [ordered]@{}
}

$exitCodeB = $null

try {
    if (Test-Path -LiteralPath $entryBRoot) {
        Remove-Item -LiteralPath $entryBRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $entryBRoot | Out-Null

    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $entryBRoot -Force

    $appB = @'
if __name__ == "__main__":
    print("from-app")
'@
    $fooB = @'
if __name__ == "__main__":
    print("from-guard")
'@
    Set-Content -LiteralPath (Join-Path -Path $entryBRoot -ChildPath 'app.py') -Value $appB -Encoding Ascii -NoNewline
    Set-Content -LiteralPath (Join-Path -Path $entryBRoot -ChildPath 'foo.py') -Value $fooB -Encoding Ascii -NoNewline

    $localLogB = Join-Path -Path $entryBRoot -ChildPath '~setup.log'
    $bootstrapLogB = Join-Path -Path $entryBRoot -ChildPath $entryBLog

    if (Test-Path -LiteralPath $localLogB) {
        Remove-Item -LiteralPath $localLogB -Force
    }
    if (Test-Path -LiteralPath $bootstrapLogB) {
        Remove-Item -LiteralPath $bootstrapLogB -Force
    }

    $exitCodeB = Invoke-Bootstrap -Root $entryBRoot -LogName $entryBLog

    $localChosenB = Get-LastChosenValue -Path $localLogB
    if ($localChosenB) {
        Append-SharedBreadcrumb -Line "Chosen entry: $localChosenB"
    }

    $chosenLine = Select-String -LiteralPath $sharedLog -Pattern '^Chosen entry: (.+)$' -ErrorAction SilentlyContinue | Select-Object -Last 1
    $chosenRel = ''
    if ($chosenLine -and $chosenLine.Matches.Count -gt 0) {
        $chosenRel = $chosenLine.Matches[0].Groups[1].Value
    }

    $okNameOrGuard = ($chosenRel -match '\\app\.py$') -or ($chosenRel -match '\\foo\.py$')

    $recordGuard.details.exitCode = $exitCodeB
    if ($chosenRel) {
        $recordGuard.details.chosen = $chosenRel
    }

    $recordGuard.pass = (($exitCodeB -eq 0) -and $okNameOrGuard)
    if (-not $recordGuard.pass -and -not $chosenRel) {
        $recordGuard.details.noBreadcrumb = $true
    }
}
catch {
    $recordGuard.pass = $false
    $recordGuard.details.exitCode = $exitCodeB
    $recordGuard.details.error = $_.Exception.Message
}
finally {
    Write-NdjsonRow -Record $recordGuard
}
