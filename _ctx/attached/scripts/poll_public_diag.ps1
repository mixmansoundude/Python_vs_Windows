[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Never put a colon right after a PowerShell variable in double-quoted strings;
# prefer -f or $($var)—and don’t mismatch placeholder counts. CI caught parser
# errors in this script before, so keep this guard comment close to the helpers.

function Format-Safe {
    param(
        [Parameter(Mandatory=$true)][string]$Template,
        [Parameter(ValueFromRemainingArguments=$true)][object[]]$Args
    )

    try {
        return [string]::Format($Template, $Args)
    } catch {
        $joined = if ($Args -and $Args.Count -gt 0) { [string]::Join(' | ', $Args) } else { '<no-args>' }
        Write-Warn ("Format fallback engaged for template {0}" -f $Template)
        return "$Template :: $joined"
    }
}

function Write-Info {
    param([string]$Message)
    Write-Host "INFO  diag-poller: $Message"
}

function Write-Warn {
    param([string]$Message)
    Write-Host "WARN  diag-poller: $Message"
}

function Resolve-HttpUri {
    param(
        [Parameter(Mandatory=$true)][string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw 'CI_DIAG_URL must be provided.'
    }

    try {
        $uri = [System.Uri]::new($Value)
    } catch {
        throw "CI_DIAG_URL is not a valid URI: $Value"
    }

    if (-not $uri.IsAbsoluteUri) {
        throw "CI_DIAG_URL must be absolute: $Value"
    }

    if ($uri.Scheme -ne 'http' -and $uri.Scheme -ne 'https') {
        throw "CI_DIAG_URL must use http or https: $Value"
    }

    return $uri
}

$diagUri = $null
try {
    $diagUri = Resolve-HttpUri -Value $env:CI_DIAG_URL
} catch {
    Write-Error $_.Exception.Message
    exit 1
}

$workspaceRoot = Convert-Path '.'

$outDir = $env:OUT_DIR
if ([string]::IsNullOrWhiteSpace($outDir)) {
    $outDir = '_artifacts/iterate/inputs'
}

try {
    $outDir = (Resolve-Path -LiteralPath $outDir -ErrorAction Stop).Path
} catch {
    $outDir = Join-Path -Path $workspaceRoot -ChildPath $outDir
    if (-not (Test-Path -LiteralPath $outDir)) {
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    $outDir = (Resolve-Path -LiteralPath $outDir).Path
}

$artifactsIterate = Join-Path -Path $workspaceRoot -ChildPath '_artifacts/iterate'
if (-not (Test-Path -LiteralPath $artifactsIterate)) {
    New-Item -ItemType Directory -Path $artifactsIterate -Force | Out-Null
}

$gatePath = Join-Path -Path $artifactsIterate -ChildPath 'iterate_gate.json'
$checkedPatterns = [System.Collections.Generic.List[string]]::new()
$checkedPatterns.Add('public-diag-html:real-ndjson-links') | Out-Null
$checkedPatterns.Add("CI_DIAG_URL:$($diagUri.AbsoluteUri)") | Out-Null

[int]$maxAttempts = 14
$parsedInt = 0
if ([int]::TryParse($env:MAX_ATTEMPTS, [ref]$parsedInt)) {
    $maxAttempts = $parsedInt
}
if ($maxAttempts -lt 1) { $maxAttempts = 1 }

[double]$baseDelay = 0.6
$parsedDouble = 0.0
if ([double]::TryParse($env:BASE_DELAY_SEC, [ref]$parsedDouble)) {
    $baseDelay = $parsedDouble
}
if ($baseDelay -lt 0.1) { $baseDelay = 0.1 }

$targets = @{
    ci  = @{ name = 'ci_test_results.ndjson'; matches = @() }
    tests = @{ name = 'tests~test-results.ndjson'; matches = @() }
}

function Capture-Link {
    param(
        [string]$Href
    )

    if ([string]::IsNullOrWhiteSpace($Href)) { return }
    $raw = $Href.Trim()

    $isTxt = $false
    if ($raw.EndsWith('.ndjson.txt')) {
        $isTxt = $true
    } elseif (-not $raw.EndsWith('.ndjson')) {
        return
    }

    $label = $null
    if ($raw -match 'ci_test_results') {
        $label = 'ci'
    } elseif ($raw -match '~test-results') {
        $label = 'tests'
    } else {
        return
    }

    try {
        $resolved = if ([System.Uri]::IsWellFormedUriString($raw, [System.UriKind]::Absolute)) {
            [System.Uri]::new($raw)
        } else {
            [System.Uri]::new($diagUri, $raw)
        }
    } catch {
        Write-Warn "Invalid href ignored: $raw"
        return
    }

    $entry = [pscustomobject]@{
        Uri = $resolved
        IsTxt = $isTxt
        Raw = $raw
    }

    $targets[$label].matches += $entry
}

$matched = $false
for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
    try {
        $response = Invoke-WebRequest -Uri $diagUri -UseBasicParsing -ErrorAction Stop
        $html = $response.Content
    } catch {
        # derived requirement: always format the attempt index so the colon that follows it never
        # reforms the "$attempt:" parser error called out in CI (PowerShell treats that as a scoped
        # variable lookup and aborts the poller).
        Write-Warn ("Attempt {0}: failed to fetch diagnostics page ({1})." -f $attempt, $_.Exception.Message)
        $html = $null
    }

    if ($html) {
        $targets.Keys | ForEach-Object { $targets[$_].matches = @() }
        $regex = [regex]'href\s*=\s*"(?<url>[^"#?]+(?:\?[^"#]*)?)"'
        $matches = $regex.Matches($html)
        foreach ($match in $matches) {
            Capture-Link -Href $match.Groups['url'].Value
        }
        $haveCi = $targets['ci'].matches | Where-Object { $_ }
        $haveTests = $targets['tests'].matches | Where-Object { $_ }
        if ($haveCi -and $haveTests) {
            $matched = $true
            break
        }
    }

    if ($attempt -ge $maxAttempts) { break }
    $delay = [Math]::Min($baseDelay * [Math]::Pow(1.6, $attempt - 1), 6.0)
    Start-Sleep -Seconds $delay
}

$foundInputs = @{}
$missing = New-Object System.Collections.Generic.List[string]
$sources = New-Object System.Collections.Generic.List[string]

function Select-BestMatch {
    param([object[]]$Entries)
    if (-not $Entries) { return $null }
    $exact = $Entries | Where-Object { -not $_.IsTxt }
    if ($exact) { return ($exact | Select-Object -First 1) }
    return ($Entries | Select-Object -First 1)
}

foreach ($key in $targets.Keys) {
    $data = $targets[$key]
    $best = Select-BestMatch -Entries $data.matches
    if (-not $best) {
        $missing.Add($data.name) | Out-Null
        continue
    }

    $dest = Join-Path -Path $outDir -ChildPath $data.name
    try {
        $content = Invoke-WebRequest -Uri $best.Uri -UseBasicParsing -ErrorAction Stop
    } catch {
        Write-Warn "Download failed for $($best.Uri.AbsoluteUri): $($_.Exception.Message)"
        $missing.Add($data.name) | Out-Null
        continue
    }

    $text = $content.Content
    if ($null -eq $text) { $text = '' }
    if ($best.IsTxt) {
        $text = [regex]::Replace($text, '}(\s*\r?\n?\s*){', "}`n{")
        if (-not $text.EndsWith("`n")) { $text += "`n" }
    }

    try {
        $dir = Split-Path -Path $dest -Parent
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Set-Content -LiteralPath $dest -Value $text -Encoding UTF8
        $foundInputs[$key] = (Resolve-Path -LiteralPath $dest).Path
        $sources.Add("$($data.name):$($best.Uri.AbsoluteUri)") | Out-Null
        Write-Info "Downloaded $($data.name) from $($best.Uri.AbsoluteUri)"
    } catch {
        # derived requirement: format the warning so the colon after $dest never
        # triggers PowerShell's scoped-variable parser again.
        Write-Warn (Format-Safe "Failed to write {0}: {1}" $dest $_.Exception.Message)
        $missing.Add($data.name) | Out-Null
    }
}

if ($missing.Count -gt 0) {
    $unique = $missing | Sort-Object -Unique
    $missing.Clear()
    foreach ($m in $unique) { $missing.Add($m) | Out-Null }
    Write-Warn (Format-Safe "Missing inputs: {0}" ([string]::Join(', ', $missing)))
}

$gate = [ordered]@{
    stage = 'iterate-gate'
    proceed = $true
    found_inputs = [ordered]@{
        ci = $foundInputs['ci']
        tests = $foundInputs['tests']
    }
    missing_inputs = @($missing)
    checked_patterns = @($checkedPatterns)
    note = 'fail-open via public diagnostics poller'
}
$gate | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $gatePath -Encoding UTF8
Write-Info "iterate_gate.json written to $gatePath"

$envPath = $env:GITHUB_ENV
if ($envPath) {
    $foundValue = if ($foundInputs.Count -gt 0) { 'true' } else { 'false' }
    Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_FOUND=$foundValue"
    if ($sources.Count -gt 0) {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_SOURCE=$([string]::Join(';', $sources))"
    } else {
        Add-Content -LiteralPath $envPath -Value 'GATE_NDJSON_SOURCE='
    }
    if ($missing.Count -gt 0) {
        Add-Content -LiteralPath $envPath -Value "GATE_NDJSON_MISSING=$([string]::Join(';', $missing))"
    } else {
        Add-Content -LiteralPath $envPath -Value 'GATE_NDJSON_MISSING='
    }
}

Write-Info (
    "summary: matched={0} downloaded={1} missing={2}" -f `
    ($matched -as [string]), $foundInputs.Count, $missing.Count)
