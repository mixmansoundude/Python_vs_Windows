$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$resultsPath = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$sharedLogPath = Join-Path -Path $here -ChildPath '~setup.log'

$repoRoot = Split-Path -Path $here -Parent

function Write-NdjsonRecord {
    param([hashtable]$Record)
    try {
        $json = $Record | ConvertTo-Json -Compress
        Add-Content -LiteralPath $resultsPath -Value $json -Encoding Ascii
    }
    catch {
        # Swallow serialization errors; do not throw
    }
}

function Get-BreadcrumbLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }
    try {
        return Get-Content -LiteralPath $Path -Encoding Ascii | Where-Object { $_ -like 'Chosen entry:*' }
    }
    catch {
        return @()
    }
}

function Invoke-RunSetup {
    param(
        [string]$WorkingRoot,
        [string]$BootstrapLog
    )

    Push-Location -LiteralPath $WorkingRoot
    try {
        cmd.exe /c ('.\run_setup.bat *> "' + $BootstrapLog + '"') | Out-Null
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

# Scenario A: main.py should win over app.py when both present
$entryARoot = Join-Path -Path $here -ChildPath '~entryA'
$entryALogName = '~entryA_bootstrap.log'
$entryALogPath = Join-Path -Path $entryARoot -ChildPath $entryALogName

$recordA = [ordered]@{
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

    $mainPy = @(
        'if __name__ == "__main__":'
        '    print("from-main")'
    ) -join "`n"
    $appPy = @(
        'if __name__ == "__main__":'
        '    print("from-app")'
    ) -join "`n"

    Set-Content -LiteralPath (Join-Path -Path $entryARoot -ChildPath 'main.py') -Value $mainPy -Encoding Ascii
    Set-Content -LiteralPath (Join-Path -Path $entryARoot -ChildPath 'app.py') -Value $appPy -Encoding Ascii

    if (Test-Path -LiteralPath $entryALogPath) {
        Remove-Item -LiteralPath $entryALogPath -Force
    }

    $before = Get-BreadcrumbLines -Path $sharedLogPath
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $entryARoot -Force
    $exitCode = Invoke-RunSetup -WorkingRoot $entryARoot -BootstrapLog $entryALogName

    $after = Get-BreadcrumbLines -Path $sharedLogPath
    $newLines = $after.Count - $before.Count

    if ($exitCode -ne $null -and $exitCode -ne 0) {
        $recordA.details.exitCode = $exitCode
    }

    if ($newLines -ne 1) {
        $recordA.details.breadcrumbCount = [ordered]@{ before = $before.Count; after = $after.Count }
    }

    if ($after.Count -gt 0) {
        $lastLine = $after[$after.Count - 1]
        if ($lastLine -like '*\main.py') {
            if ($newLines -eq 1 -and -not $recordA.details.Contains('exitCode')) {
                $recordA.pass = $true
            }
        }
        else {
            $recordA.details.lastLine = $lastLine
        }
    }
    else {
        $recordA.details.noBreadcrumbs = $true
    }
}
catch {
    $recordA.pass = $false
    $recordA.details.error = ($_ | Out-String).Trim()
}
finally {
    Write-NdjsonRecord -Record $recordA
}

# Scenario B: choose app.py (common name) or foo.py (has __main__ guard)
$entryBRoot = Join-Path -Path $here -ChildPath '~entryB'
$entryBLogName = '~entryB_bootstrap.log'
$entryBLogPath = Join-Path -Path $entryBRoot -ChildPath $entryBLogName

$recordB = [ordered]@{
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

    $appB = @(
        'if __name__ == "__main__":'
        '    print("from-app")'
    ) -join "`n"
    $fooB = @(
        'if __name__ == "__main__":'
        '    print("from-guard")'
    ) -join "`n"

    Set-Content -LiteralPath (Join-Path -Path $entryBRoot -ChildPath 'app.py') -Value $appB -Encoding Ascii
    Set-Content -LiteralPath (Join-Path -Path $entryBRoot -ChildPath 'foo.py') -Value $fooB -Encoding Ascii

    if (Test-Path -LiteralPath $entryBLogPath) {
        Remove-Item -LiteralPath $entryBLogPath -Force
    }

    $beforeB = Get-BreadcrumbLines -Path $sharedLogPath
    Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $entryBRoot -Force
    $exitCodeB = Invoke-RunSetup -WorkingRoot $entryBRoot -BootstrapLog $entryBLogName

    $afterB = Get-BreadcrumbLines -Path $sharedLogPath
    $newLinesB = $afterB.Count - $beforeB.Count

    if ($exitCodeB -ne $null -and $exitCodeB -ne 0) {
        $recordB.details.exitCode = $exitCodeB
    }

    if ($newLinesB -ne 1) {
        $recordB.details.breadcrumbCount = [ordered]@{ before = $beforeB.Count; after = $afterB.Count }
    }

    if ($afterB.Count -gt 0) {
        $lastLineB = $afterB[$afterB.Count - 1]
        if ($lastLineB -like '*\app.py' -or $lastLineB -like '*\foo.py') {
            $recordB.details.chosen = $lastLineB
            if ($newLinesB -eq 1 -and -not $recordB.details.Contains('exitCode')) {
                $recordB.pass = $true
            }
        }
        else {
            $recordB.details.chosen = $lastLineB
        }
    }
    else {
        $recordB.details.noBreadcrumbs = $true
    }
}
catch {
    $recordB.pass = $false
    $recordB.details.error = ($_ | Out-String).Trim()
}
finally {
    Write-NdjsonRecord -Record $recordB
}
