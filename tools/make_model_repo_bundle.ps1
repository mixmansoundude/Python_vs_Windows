param(
    [string]$OutZip = "${env:RUNNER_TEMP}/repo_context.zip",
    [int]$MaxMB = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = $env:GITHUB_WORKSPACE
if (-not $root -or -not (Test-Path -LiteralPath $root)) {
    $root = (Get-Location).Path
}

$runnerTemp = $env:RUNNER_TEMP
if (-not $runnerTemp) {
    throw "RUNNER_TEMP is not defined"
}

$stage = Join-Path $runnerTemp 'repo_context_stage'
if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$includes = @(
    '.github',
    'tools',
    'tests',
    'run_setup.bat',
    '*.ps1',
    '*.psm1',
    '*.py',
    '*.bat',
    '*.cmd',
    '*.yml',
    '*.yaml',
    '*.md'
)

$denyPatterns = @(
    '(?i)(^|/|\\)\.git(/|\\)',
    '(?i)(^|/|\\)__pycache__(/|\\)',
    '(?i)(^|/|\\)node_modules(/|\\)',
    '(?i)(^|/|\\)\.venv(/|\\)',
    '(?i)(^|/|\\)env(/|\\)',
    '(?i)\.(png|jpe?g|gif|zip|pdf|exe|dll|so|dylib|7z|tgz)$'
)

$included = New-Object System.Collections.Generic.HashSet[string]
$copied = New-Object System.Collections.Generic.List[string]
$skippedMissing = New-Object System.Collections.Generic.List[string]

function Test-Denylist {
    param([string]$Relative)
    foreach ($pattern in $denyPatterns) {
        if ($Relative -match $pattern) {
            return $true
        }
    }
    return $false
}

foreach ($include in $includes) {
    $candidate = Join-Path $root $include
    if (-not (Test-Path $candidate)) {
        $skippedMissing.Add($include) | Out-Null
        continue
    }

    $items = Get-ChildItem -Path $candidate -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($item in $items) {
        if ($item.PSIsContainer) {
            continue
        }
        $relative = [System.IO.Path]::GetRelativePath($root, $item.FullName)
        $relative = $relative -replace '\\', '/'
        if ($included.Contains($relative)) {
            continue
        }
        if (Test-Denylist -Relative $relative) {
            continue
        }
        $destination = Join-Path $stage $relative
        $destinationDir = Split-Path -Parent $destination
        if (-not (Test-Path $destinationDir)) {
            New-Item -ItemType Directory -Force -Path $destinationDir | Out-Null
        }
        Copy-Item -LiteralPath $item.FullName -Destination $destination -Force
        $included.Add($relative) | Out-Null
        $copied.Add($relative) | Out-Null
    }
}

$ctx = Join-Path $stage 'bundle_context'
New-Item -ItemType Directory -Force -Path $ctx | Out-Null

$firstFailure = Join-Path $root 'first_failure.json'
if (Test-Path $firstFailure) {
    Copy-Item -LiteralPath $firstFailure -Destination (Join-Path $ctx 'first_failure.json') -Force
}

$ndjsonTargets = @(
    'ci_test_results.ndjson',
    'tests~test-results.ndjson'
)
foreach ($nd in $ndjsonTargets) {
    $candidate = Join-Path $root $nd
    if (Test-Path $candidate) {
        $dest = Join-Path $ctx 'ndjson_head.txt'
        Get-Content -LiteralPath $candidate -Encoding UTF8 -TotalCount 1 | Set-Content -LiteralPath $dest -Encoding UTF8
        break
    }
}

$manifestPath = Join-Path $ctx 'manifest.txt'
$manifest = New-Object System.Collections.Generic.List[string]
$manifest.Add('repo bundle manifest') | Out-Null
$manifest.Add("root=$root") | Out-Null
$manifest.Add(('copied_files={0}' -f $copied.Count)) | Out-Null

if ($skippedMissing.Count -gt 0) {
    $manifest.Add('missing_includes:') | Out-Null
    foreach ($miss in $skippedMissing) {
        $manifest.Add("  - $miss") | Out-Null
    }
}

$patternEnv = $env:ITERATE_REDACT_PATTERN
$omitted = New-Object System.Collections.Generic.List[string]
if ($patternEnv) {
    try {
        $regex = [System.Text.RegularExpressions.Regex]::new($patternEnv, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    } catch {
        Write-Warning "Invalid ITERATE_REDACT_PATTERN; skipping secret scan."
        $regex = $null
    }
    if ($regex) {
        Get-ChildItem -Path $stage -Recurse -File | ForEach-Object {
            $file = $_
            $relative = [System.IO.Path]::GetRelativePath($stage, $file.FullName) -replace '\\','/'
            try {
                $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8
            } catch {
                return
            }
            if ($regex.IsMatch($text)) {
                # derived requirement: reviewers requested redaction parity between prompt payload and rationale.
                # Drop flagged files from the bundle so the Files upload never carries secrets.
                Remove-Item -LiteralPath $file.FullName -Force
                $omitted.Add($relative) | Out-Null
            }
        }
    }
}

if ($omitted.Count -gt 0) {
    $manifest.Add('omitted_for_redaction:') | Out-Null
    foreach ($entry in $omitted) {
        $manifest.Add("  - $entry") | Out-Null
    }
}

$manifest | Set-Content -LiteralPath $manifestPath -Encoding UTF8

if (Test-Path $OutZip) {
    Remove-Item -LiteralPath $OutZip -Force
}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutZip -Force

$zipInfo = Get-Item -LiteralPath $OutZip
$sizeMB = [Math]::Round($zipInfo.Length / 1MB, 2)
Write-Host ("repo bundle: {0} ({1} MB)" -f $OutZip, $sizeMB)
if ($sizeMB -gt $MaxMB) {
    Write-Warning ("Bundle size {0} MB exceeds cap {1} MB" -f $sizeMB, $MaxMB)
}
