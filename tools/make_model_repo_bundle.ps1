# derived requirement: iterate prompt must stay lean while giving Codex full repo
# context. Build a curated bundle so Responses can mount files via
# code_interpreter without inflating the prompt itself.
param(
    [string]$OutZip = "$env:RUNNER_TEMP/repo_context.zip",
    [int]$MaxMB = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-DirectoryIfMissing {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

$root = $env:GITHUB_WORKSPACE
if (-not $root) {
    $root = (Get-Location).Path
}

$tempRoot = $env:RUNNER_TEMP
if (-not $tempRoot) {
    throw "RUNNER_TEMP not defined; required for staging repo bundle."
}

$stage = Join-Path $tempRoot 'repo_context_stage'
if (Test-Path -LiteralPath $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
New-DirectoryIfMissing -Path $stage

$allowlist = @(
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

$denyRegexes = @(
    '(^|[\\/])\.git([\\/]|$)',
    '(^|[\\/])__pycache__([\\/]|$)',
    '(^|[\\/])node_modules([\\/]|$)',
    '(^|[\\/])\.venv([\\/]|$)',
    '(^|[\\/])env([\\/]|$)',
    '\.(png|jpe?g|gif|zip|pdf|exe|dll|so|dylib|7z|tgz)$'
)

$copied = New-Object System.Collections.Generic.List[string]

foreach ($inc in $allowlist) {
    $fullPath = Join-Path $root $inc
    try {
        $items = Get-ChildItem -Path $fullPath -Recurse -Force -ErrorAction SilentlyContinue
    } catch {
        $items = @()
    }
    foreach ($item in $items) {
        if ($item.PSIsContainer) { continue }
        $resolved = try {
            (Resolve-Path -LiteralPath $item.FullName).ProviderPath
        } catch {
            $null
        }
        if (-not $resolved) { continue }
        $rel = $resolved.Substring($root.Length).TrimStart('\','/')
        $denyHit = $false
        foreach ($pattern in $denyRegexes) {
            if ($rel -match $pattern) {
                $denyHit = $true
                break
            }
        }
        if ($denyHit) { continue }
        $dest = Join-Path $stage $rel
        if (Test-Path -LiteralPath $dest) {
            continue
        }
        New-DirectoryIfMissing -Path (Split-Path -Parent $dest)
        Copy-Item -LiteralPath $resolved -Destination $dest -Force
        [void]$copied.Add($rel)
    }
}

$contextDir = Join-Path $stage 'bundle_context'
New-DirectoryIfMissing -Path $contextDir

function Copy-IfPresent {
    param(
        [string]$Source,
        [string]$Destination,
        [switch]$HeadOnly
    )
    if (-not (Test-Path -LiteralPath $Source)) { return }
    if ($HeadOnly) {
        $head = Get-Content -LiteralPath $Source -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($null -ne $head) {
            $head | Set-Content -LiteralPath $Destination -Encoding UTF8
        }
    } else {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

Copy-IfPresent -Source (Join-Path $root 'first_failure.json') -Destination (Join-Path $contextDir 'first_failure.json')
Copy-IfPresent -Source (Join-Path $root 'ci_test_results.ndjson') -Destination (Join-Path $contextDir 'ndjson_head.txt') -HeadOnly
if (-not (Test-Path -LiteralPath (Join-Path $contextDir 'ndjson_head.txt'))) {
    Copy-IfPresent -Source (Join-Path $root 'tests~test-results.ndjson') -Destination (Join-Path $contextDir 'ndjson_head.txt') -HeadOnly
}

$manifestPath = Join-Path $contextDir 'manifest.txt'
"files_copied_count=$($copied.Count)" | Set-Content -LiteralPath $manifestPath -Encoding UTF8
if ($copied.Count -gt 0) {
    "files_copied_list:" | Add-Content -LiteralPath $manifestPath -Encoding UTF8
    $copied | Sort-Object | ForEach-Object { $_ } | Add-Content -LiteralPath $manifestPath -Encoding UTF8
}

$redactPattern = $env:ITERATE_REDACT_PATTERN
$redacted = New-Object System.Collections.Generic.List[string]
if ($redactPattern) {
    $regex = New-Object System.Text.RegularExpressions.Regex($redactPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    Get-ChildItem -LiteralPath $stage -File -Recurse | ForEach-Object {
        try {
            $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
        } catch {
            return
        }
        if ($regex.IsMatch($text)) {
            $rel = $_.FullName.Substring($stage.Length).TrimStart('\','/')
            [void]$redacted.Add($rel)
            Remove-Item -LiteralPath $_.FullName -Force
        }
    }
    if ($redacted.Count -gt 0) {
        "" | Add-Content -LiteralPath $manifestPath -Encoding UTF8
        "omitted_for_redaction:" | Add-Content -LiteralPath $manifestPath -Encoding UTF8
        $redacted | Sort-Object | ForEach-Object { $_ } | Add-Content -LiteralPath $manifestPath -Encoding UTF8
    }
}

if (Test-Path -LiteralPath $OutZip) {
    Remove-Item -LiteralPath $OutZip -Force
}

Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutZip -Force
$bundleSizeBytes = (Get-Item -LiteralPath $OutZip).Length
$bundleMB = [Math]::Round($bundleSizeBytes / 1MB, 2)
Write-Host "repo bundle: $OutZip (${bundleMB} MB)"

if ($bundleMB -gt $MaxMB) {
    Write-Warning "Bundle size ${bundleMB}MB exceeds cap ${MaxMB}MB; consider trimming includes."
}

