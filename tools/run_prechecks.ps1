[CmdletBinding()]
param(
    [string]$ReportPath = "precheck_report.md",
    [string]$JsonPath = "precheck_results.json"
)

$ErrorActionPreference = 'Stop'

$results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Name,
        [string]$Status,
        [string]$Output
    )

    $results.Add([pscustomobject]@{
        Name   = $Name
        Status = $Status
        Output = $Output
    }) | Out-Null
}

function Run-Command {
    param(
        [string]$Name,
        [scriptblock]$Block,
        [switch]$TreatOutputAsWarning,
        [object[]]$Arguments = @()
    )

    $captured = $null
    $exitCode = 0

    try {
        $captured = & $Block @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $captured = @($_.Exception.Message)
        $exitCode = 1
    }

    if ($null -eq $captured) {
        $captured = @()
    }

    $text = ($captured | Out-String).Trim()

    $status = if ($exitCode -eq 0) { 'passed' } else { 'failed' }
    if ($status -eq 'passed' -and $TreatOutputAsWarning -and $text) {
        $status = 'warning'
    }

    Add-Result -Name $Name -Status $status -Output $text
}

function Get-TableRow {
    param(
        [string]$Status
    )

    switch ($Status) {
        'passed' { return '✅ Passed' }
        'failed' { return '❌ Failed' }
        'warning' { return '⚠️ Warning' }
        'skipped' { return '➖ Skipped' }
        default { return $Status }
    }
}

# Python compileall
Run-Command -Name 'Python compileall' -Block { python -m compileall -q . }

# Pyflakes
Run-Command -Name 'Pyflakes' -Block { python -m pyflakes . }

# YAML lint
$yamlFiles = @(Get-ChildItem -Path . -Recurse -File -Include *.yml, *.yaml | Where-Object { $_.FullName -notmatch '\\.git\\' })
if ($yamlFiles.Count -gt 0) {
    Run-Command -Name 'Yamllint' -Block {
        $paths = $yamlFiles | ForEach-Object { $_.FullName }
        python -m yamllint @paths
    }
} else {
    Add-Result -Name 'Yamllint' -Status 'skipped' -Output 'No YAML files found.'
}

# JSON lint
$jsonFiles = @(Get-ChildItem -Path . -Recurse -File -Include *.json | Where-Object { $_.FullName -notmatch '\\.git\\' })
if ($jsonFiles.Count -gt 0) {
    $jsonFailures = @()
    foreach ($jsonFile in $jsonFiles) {
        $message = & jq -e . -- "${jsonFile.FullName}" 2>&1
        if ($LASTEXITCODE -ne 0) {
            if ($message -is [System.Array]) {
                $message = ($message | Out-String).Trim()
            }
            $jsonFailures += "${jsonFile.FullName}: $message"
        }
    }
    if ($jsonFailures.Count -gt 0) {
        Add-Result -Name 'jq JSON lint' -Status 'failed' -Output (($jsonFailures -join [Environment]::NewLine).Trim())
    } else {
        Add-Result -Name 'jq JSON lint' -Status 'passed' -Output ''
    }
} else {
    Add-Result -Name 'jq JSON lint' -Status 'skipped' -Output 'No JSON files found.'
}

# PSScriptAnalyzer
Run-Command -Name 'PSScriptAnalyzer' -Block {
    Invoke-ScriptAnalyzer -Path . -Recurse -EnableExit | Out-String
}

# Delimiter checker
Run-Command -Name 'Delimiter check' -Block { python tools/check_delimiters.py }

$hasFailures = $false
$hasWarnings = $false
foreach ($result in $results) {
    if ($result.Status -eq 'failed') { $hasFailures = $true }
    if ($result.Status -eq 'warning') { $hasWarnings = $true }
}

$hasFindings = $hasFailures -or $hasWarnings

$builder = New-Object System.Text.StringBuilder
$null = $builder.AppendLine('### Precheck results')
$null = $builder.AppendLine()
$null = $builder.AppendLine('| Check | Status |')
$null = $builder.AppendLine('| --- | --- |')
foreach ($result in $results) {
    $statusText = Get-TableRow -Status $result.Status
    $null = $builder.AppendLine("| $($result.Name) | $statusText |")
}
$null = $builder.AppendLine()

foreach ($result in $results) {
    if (-not [string]::IsNullOrWhiteSpace($result.Output)) {
        $null = $builder.AppendLine("<details><summary>$($result.Name) output</summary>")
        $null = $builder.AppendLine()
        $null = $builder.AppendLine('```')
        $null = $builder.AppendLine($result.Output)
        $null = $builder.AppendLine('```')
        $null = $builder.AppendLine('</details>')
        $null = $builder.AppendLine()
    }
}

$reportContent = $builder.ToString().TrimEnd()
[System.IO.File]::WriteAllText($ReportPath, $reportContent, [System.Text.Encoding]::UTF8)

$summary = [pscustomobject]@{
    hasFailures = $hasFailures
    hasWarnings = $hasWarnings
    hasFindings = $hasFindings
    reportPath = [System.IO.Path]::GetFullPath($ReportPath)
}

$summary | ConvertTo-Json -Depth 4 | Set-Content -Path $JsonPath -Encoding UTF8

return 0
