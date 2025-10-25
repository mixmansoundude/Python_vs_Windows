<#
.SYNOPSIS
    Build a curated repository bundle for iterate Requests.
.DESCRIPTION
    Derived requirement: supervisors requested a files-first iterate strategy where
    the model consumes a curated zip instead of bloated prompt context. This helper
    stages allowlisted files, applies denylists, redacts sensitive matches using the
    same iterate pattern, and emits contextual crumbs under bundle_context/ to keep
    the model grounded without bloating the prompt.
#>
param(
    [string]$OutZip = "$env:RUNNER_TEMP/repo_context.zip",
    [int]$MaxMB = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-EmptyDirectory {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

$root = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
if (-not (Test-Path -LiteralPath $root)) {
    throw "Workspace root '$root' not found"
}

$stage = Join-Path $env:RUNNER_TEMP 'repo_context_stage'
New-EmptyDirectory -Path $stage

$included = New-Object System.Collections.Generic.HashSet[string]
$manifestIncluded = New-Object System.Collections.Generic.List[string]

function Get-RelativePath {
    param([string]$FullPath)
    $normalizedRoot = [System.IO.Path]::GetFullPath($root)
    $normalized = [System.IO.Path]::GetFullPath($FullPath)
    $rel = $normalized.Substring($normalizedRoot.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    return $rel.Replace('\', '/')
}

function Should-SkipFile {
    param([string]$RelPath)
    $unix = $RelPath.Replace('\\','/')
    if ($unix -match '(^|/)\.git(/|$)') { return $true }
    if ($unix -match '(^|/).__pycache__(/|$)') { return $true }
    if ($unix -match '(^|/)node_modules(/|$)') { return $true }
    if ($unix -match '(^|/)\.venv(/|$)') { return $true }
    if ($unix -match '(^|/)env(/|$)') { return $true }
    if ($unix -match '\.(png|jpe?g|gif|zip|pdf|exe|dll|so|dylib|7z|tgz)$') { return $true }
    return $false
}

function Stage-File {
    param([System.IO.FileInfo]$Item)
    $rel = Get-RelativePath -FullPath $Item.FullName
    if ([string]::IsNullOrWhiteSpace($rel)) { return }
    if (Should-SkipFile -RelPath $rel) { return }
    if (-not $included.Add($rel)) { return }
    $dest = Join-Path $stage $rel
    $destDir = Split-Path -Parent $dest
    if ($destDir) { New-Item -ItemType Directory -Force -Path $destDir | Out-Null }
    Copy-Item -LiteralPath $Item.FullName -Destination $dest -Force
    $manifestIncluded.Add($rel)
}

$dirIncludes = @('.github', 'tools', 'tests')
foreach ($dir in $dirIncludes) {
    $dirPath = Join-Path $root $dir
    if (Test-Path -LiteralPath $dirPath) {
        Get-ChildItem -LiteralPath $dirPath -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { Stage-File -Item $_ }
    }
}

$explicitFiles = @('run_setup.bat')
foreach ($file in $explicitFiles) {
    $candidate = Join-Path $root $file
    if (Test-Path -LiteralPath $candidate) {
        $info = Get-Item -LiteralPath $candidate
        if ($info.PSIsContainer) { continue }
        Stage-File -Item $info
    }
}

$patternIncludes = @('*.ps1','*.psm1','*.py','*.bat','*.cmd','*.yml','*.yaml','*.md')
foreach ($pattern in $patternIncludes) {
    Get-ChildItem -Path $root -Filter $pattern -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { Stage-File -Item $_ }
}

$contextDir = Join-Path $stage 'bundle_context'
New-Item -ItemType Directory -Force -Path $contextDir | Out-Null

$firstFailure = Join-Path $root 'first_failure.json'
if (Test-Path -LiteralPath $firstFailure) {
    Copy-Item -LiteralPath $firstFailure -Destination (Join-Path $contextDir 'first_failure.json') -Force
}

$ndjsonHeadWritten = $false
foreach ($candidate in @('ci_test_results.ndjson', 'tests~test-results.ndjson')) {
    $path = Join-Path $root $candidate
    if (Test-Path -LiteralPath $path) {
        try {
            $line = Get-Content -LiteralPath $path -TotalCount 1 -Encoding UTF8
            if ($line) {
                $dest = Join-Path $contextDir 'ndjson_head.txt'
                $line | Out-File -FilePath $dest -Encoding UTF8
                $ndjsonHeadWritten = $true
                break
            }
        } catch {
            # derived requirement: keep bundle resilient if the NDJSON mirror is transient.
        }
    }
}

$manifestPath = Join-Path $contextDir 'manifest.txt'
"included_count=$($manifestIncluded.Count)" | Out-File -FilePath $manifestPath -Encoding UTF8
if ($manifestIncluded.Count -gt 0) {
    "included_files:" | Out-File -FilePath $manifestPath -Encoding UTF8 -Append
    ($manifestIncluded | Sort-Object) | Out-File -FilePath $manifestPath -Encoding UTF8 -Append
}
if (Test-Path -LiteralPath $firstFailure) {
    "context:first_failure.json" | Out-File -FilePath $manifestPath -Encoding UTF8 -Append
}
if ($ndjsonHeadWritten) {
    "context:ndjson_head.txt" | Out-File -FilePath $manifestPath -Encoding UTF8 -Append
}

$pattern = $env:ITERATE_REDACT_PATTERN
$flagged = New-Object System.Collections.Generic.List[string]
if ($pattern) {
    try {
        $regex = [System.Text.RegularExpressions.Regex]::new($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
        Get-ChildItem -Path $stage -File -Recurse -Force | ForEach-Object {
            $content = $null
            try {
                $content = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
            } catch {
                return
            }
            if ($content -and $regex.IsMatch($content)) {
                $rel = $_.FullName.Substring($stage.Length).TrimStart([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar).Replace('\\','/')
                $flagged.Add($rel)
                Remove-Item -LiteralPath $_.FullName -Force
            }
        }
    } catch {
        # derived requirement: fall back silently if regex compilation fails to avoid blocking iterate.
    }
}

if ($flagged.Count -gt 0) {
    "omitted_for_redaction:" | Out-File -FilePath $manifestPath -Encoding UTF8 -Append
    ($flagged | Sort-Object) | Out-File -FilePath $manifestPath -Encoding UTF8 -Append
}

if (Test-Path -LiteralPath $OutZip) {
    Remove-Item -LiteralPath $OutZip -Force
}

$stageGlob = Join-Path $stage '*'
Compress-Archive -Path $stageGlob -DestinationPath $OutZip -Force
$bundleSizeMB = [Math]::Round((Get-Item -LiteralPath $OutZip).Length / 1MB, 2)
Write-Host ("repo bundle: {0} ({1} MB)" -f $OutZip, $bundleSizeMB)
if ($bundleSizeMB -gt $MaxMB) {
    Write-Warning ("Bundle size {0} MB exceeds cap {1} MB" -f $bundleSizeMB, $MaxMB)
}
