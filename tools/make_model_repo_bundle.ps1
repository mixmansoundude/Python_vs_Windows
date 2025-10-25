[CmdletBinding()]
param(
    [string]$OutZip,
    [int]$MaxMB = 25
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# derived requirement: supervisor requested a files-first iterate strategy that hands the
# Responses API a curated repo bundle. Build the archive deterministically so the model
# can inspect sources via code_interpreter without inflating the prompt payload.

$root = $env:GITHUB_WORKSPACE
if (-not $root) {
    $root = (Get-Location).Path
}
$root = Convert-Path $root

$runnerTemp = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
if (-not $OutZip) {
    $OutZip = Join-Path $runnerTemp 'repo_context.zip'
}

$stage = Join-Path $runnerTemp 'repo_context_stage'
if (Test-Path $stage) {
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
}
New-Item -ItemType Directory -Force -Path $stage | Out-Null

$allowedPrefixes = @('.github/', 'tools/', 'tests/')
$allowedExtensions = @('.ps1', '.psm1', '.py', '.bat', '.cmd', '.yml', '.yaml', '.md')
$allowedNames = @('run_setup.bat')
$denyPatternDirectories = '(^|[\\/])((\.git)|(__pycache__)|(node_modules)|(\.venv)|(env))(?:[\\/]|$)'
$denyPatternExtensions = '\.(png|jpe?g|gif|zip|pdf|exe|dll|so|dylib|7z|tgz)$'

function Convert-ToPosix([string]$Path) {
    return $Path -replace '\\', '/'
}

function Should-Include([string]$RelativePath) {
    if (-not $RelativePath) { return $false }
    $rel = Convert-ToPosix $RelativePath
    foreach ($prefix in $allowedPrefixes) {
        if ($rel.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }
    $fileName = [System.IO.Path]::GetFileName($rel)
    if ($allowedNames -contains $fileName) {
        return $true
    }
    $ext = [System.IO.Path]::GetExtension($rel)
    if ($ext -and ($allowedExtensions -contains $ext.ToLowerInvariant())) {
        return $true
    }
    return $false
}

function Should-Exclude([string]$RelativePath) {
    if (-not $RelativePath) { return $true }
    $rel = Convert-ToPosix $RelativePath
    if ($rel -match $denyPatternDirectories) {
        return $true
    }
    if ($rel -match $denyPatternExtensions) {
        return $true
    }
    return $false
}

$includedPaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

Get-ChildItem -Path $root -Recurse -File -Force | ForEach-Object {
    $full = $_.FullName
    $rel = $full.Substring($root.Length).TrimStart('\\', '/')
    if (Should-Include $rel -and -not (Should-Exclude $rel)) {
        $relPosix = Convert-ToPosix $rel
        if ($includedPaths.Add($relPosix)) {
            $destination = Join-Path $stage ($relPosix -replace '/', [System.IO.Path]::DirectorySeparatorChar)
            $parent = Split-Path -Parent $destination
            if ($parent -and -not (Test-Path $parent)) {
                New-Item -ItemType Directory -Force -Path $parent | Out-Null
            }
            Copy-Item -LiteralPath $full -Destination $destination -Force
        }
    }
}

$contextDir = Join-Path $stage 'bundle_context'
New-Item -ItemType Directory -Force -Path $contextDir | Out-Null

$firstFailureJson = Join-Path $root 'first_failure.json'
if (Test-Path $firstFailureJson) {
    Copy-Item -LiteralPath $firstFailureJson -Destination (Join-Path $contextDir 'first_failure.json') -Force
}

$ndjsonTargets = @('ci_test_results.ndjson', 'tests~test-results.ndjson')
foreach ($candidate in $ndjsonTargets) {
    $candidatePath = Join-Path $root $candidate
    if (Test-Path $candidatePath) {
        $headOut = Join-Path $contextDir 'ndjson_head.txt'
        $line = Get-Content -LiteralPath $candidatePath -TotalCount 1 -Encoding UTF8 -ErrorAction SilentlyContinue
        if ($line) {
            "source=$candidate" | Out-File -FilePath $headOut -Encoding UTF8
            $line | Out-File -FilePath $headOut -Encoding UTF8 -Append
        }
        break
    }
}

$manifestPath = Join-Path $contextDir 'manifest.txt'
$manifestLines = New-Object System.Collections.Generic.List[string]
$manifestLines.Add(("bundle_root: {0}" -f $root)) | Out-Null
$manifestLines.Add(("generated_at_utc: {0}" -f (Get-Date).ToUniversalTime().ToString('o'))) | Out-Null

$flaggedForRedaction = New-Object System.Collections.Generic.List[string]
$pattern = $env:ITERATE_REDACT_PATTERN
if ($pattern) {
    try {
        $regex = New-Object System.Text.RegularExpressions.Regex($pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    } catch {
        $regex = $null
    }
    if ($null -ne $regex) {
        Get-ChildItem -Path $stage -File -Recurse | ForEach-Object {
            $fileRel = Convert-ToPosix ($_.FullName.Substring($stage.Length).TrimStart('\\', '/'))
            $text = $null
            try {
                $text = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8 -ErrorAction Stop
            } catch {
                $text = $null
            }
            if ($null -ne $text -and $regex.IsMatch($text)) {
                # derived requirement: reviewer flagged rationale redaction gaps; exclude files that trigger the bundle scan to prevent leaks.
                $flaggedForRedaction.Add($fileRel) | Out-Null
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

$finalFiles = Get-ChildItem -Path $stage -File -Recurse | ForEach-Object {
    Convert-ToPosix ($_.FullName.Substring($stage.Length).TrimStart('\\', '/'))
} | Sort-Object

$manifestLines.Add(("included_files_count: {0}" -f ($finalFiles.Count))) | Out-Null
$manifestLines.Add('included_files:') | Out-Null
foreach ($entry in $finalFiles) {
    $manifestLines.Add("  - $entry") | Out-Null
}
if ($flaggedForRedaction.Count -gt 0) {
    $manifestLines.Add(("omitted_for_redaction_count: {0}" -f $flaggedForRedaction.Count)) | Out-Null
    $manifestLines.Add('omitted_for_redaction:') | Out-Null
    foreach ($flag in ($flaggedForRedaction | Sort-Object)) {
        $manifestLines.Add("  - $flag") | Out-Null
    }
} else {
    $manifestLines.Add('omitted_for_redaction: none') | Out-Null
}
$manifestLines | Out-File -FilePath $manifestPath -Encoding UTF8

if (Test-Path $OutZip) {
    Remove-Item -LiteralPath $OutZip -Force -ErrorAction SilentlyContinue
}
Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $OutZip -Force
$sizeMb = [math]::Round((Get-Item -LiteralPath $OutZip).Length / 1MB, 2)
if ($sizeMb -gt $MaxMB) {
    Write-Warning ("Bundle size {0} MB exceeds cap {1} MB" -f $sizeMb, $MaxMB)
}
Write-Host ("repo bundle: {0} ({1} MB)" -f $OutZip, $sizeMb)
