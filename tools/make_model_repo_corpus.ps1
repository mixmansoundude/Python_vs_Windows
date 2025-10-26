[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$OutDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# derived requirement: keep corpus generation anchored to the repo checkout so the
# workflow can run from any working directory without drifting from tracked files.
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

if (-not $OutDir) {
    throw 'OutDir is required.'
}

$resolvedOutDir = $OutDir
if (-not [System.IO.Path]::IsPathRooted($resolvedOutDir)) {
    $resolvedOutDir = (Resolve-Path -LiteralPath $resolvedOutDir -ErrorAction SilentlyContinue)
    if ($null -eq $resolvedOutDir) {
        $resolvedOutDir = (Resolve-Path -LiteralPath (Join-Path (Get-Location) $OutDir) -ErrorAction SilentlyContinue)
    }
    if ($null -eq $resolvedOutDir) {
        $resolvedOutDir = (Join-Path (Get-Location) $OutDir)
    } else {
        $resolvedOutDir = $resolvedOutDir.Path
    }
} else {
    $resolvedOutDir = [System.IO.Path]::GetFullPath($OutDir)
}

if (Test-Path -LiteralPath $resolvedOutDir) {
    Remove-Item -LiteralPath $resolvedOutDir -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedOutDir -Force | Out-Null

$allowedExtensions = @('.ps1', '.psm1', '.py', '.bat', '.cmd', '.yml', '.yaml', '.md', '.txt')
$denyFragments = @(
    '/.git/', '/__pycache__/', '/node_modules/', '/.venv/', '/env/'
)
$denyExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.zip', '.pdf', '.exe', '.dll', '.so', '.dylib', '.7z', '.tgz')

$redactPattern = $env:BUNDLE_REDACT_PATTERN
if ([string]::IsNullOrWhiteSpace($redactPattern)) {
    # derived requirement: keep the default pattern literal so PowerShell treats the
    # quote characters as plain text and avoids parser regressions when publishing.
    $redactPattern = @'
(?ix)(sk-[A-Za-z0-9]{20,}|api[_-]?key|client[_-]?secret|auth[_-]?token|access[_-]?token|password|passphrase|secret)\s*(?:[:=]\s*["'][A-Za-z0-9_-]{8,}["'])?
'@
}

try {
    $redactRegex = [System.Text.RegularExpressions.Regex]::new(
        $redactPattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Multiline
    )
} catch {
    Write-Warning "Failed to compile redaction pattern. Redaction disabled."
    $redactRegex = $null
}

function Convert-ToRelativePath {
    param([string]$Path)
    $normalized = $Path -replace '/', [System.IO.Path]::DirectorySeparatorChar
    return [System.IO.Path]::Combine($repoRoot, $normalized)
}

function Should-IncludeFile {
    param([string]$Relative)

    foreach ($fragment in $denyFragments) {
        if ($Relative -like "*$fragment*") { return $false }
    }

    $ext = [System.IO.Path]::GetExtension($Relative)
    if ($denyExtensions -contains $ext) { return $false }

    if ($allowedExtensions -contains $ext.ToLowerInvariant()) { return $true }

    return $false
}

$gitFiles = & git -C $repoRoot ls-files
if ($LASTEXITCODE -ne 0) {
    throw 'git ls-files failed'
}

$selected = @()
foreach ($entry in $gitFiles) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    if (-not (Should-IncludeFile $entry)) { continue }
    $selected += $entry
}

$redactedList = New-Object System.Collections.Generic.List[string]
$totalCopied = 0
foreach ($relative in $selected) {
    $sourcePath = Convert-ToRelativePath $relative
    if (-not (Test-Path -LiteralPath $sourcePath)) { continue }

    $destRelative = $relative -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $destPath = Join-Path $resolvedOutDir $destRelative
    $destDir = Split-Path -Parent $destPath
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $content = try { Get-Content -LiteralPath $sourcePath -Raw -Encoding UTF8 } catch { '' }
    $wasRedacted = $false
    if ($redactRegex -and $redactRegex.IsMatch($content)) {
        # derived requirement: substring-only redaction keeps files present for embeddings
        # while masking tokens that could trip corpus uploads.
        $content = $redactRegex.Replace($content, '***')
        $wasRedacted = $true
    }
    Set-Content -LiteralPath $destPath -Value $content -Encoding UTF8
    if ($wasRedacted) {
        $redactedList.Add($relative) | Out-Null
    }
    $totalCopied++
}

function New-RepoTree {
    param([string[]]$Files)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('Repo tree summary (tracked text corpus)') | Out-Null
    $lines.Add("Total files: $($Files.Count)") | Out-Null
    $lines.Add('') | Out-Null

    $groups = $Files | Group-Object { if ($_.Contains('/')) { $_.Split('/')[0] } else { '.' } } | Sort-Object Name

    foreach ($group in $groups) {
        $top = $group.Name
        $count = $group.Count
        if ($top -eq '.') {
            $lines.Add("./ (root files): $count") | Out-Null
            $rootNames = $group.Group | ForEach-Object { $_.Split('/')[-1] }
            foreach ($name in ($rootNames | Sort-Object | Select-Object -First 10)) {
                $lines.Add("  - $name") | Out-Null
            }
            $lines.Add('') | Out-Null
            continue
        }

        $lines.Add("$top/: $count") | Out-Null
        $subGroups = $group.Group | Group-Object {
            $parts = $_.Split('/')
            if ($parts.Length -ge 2) { $parts[1] } else { '' }
        } | Sort-Object Name

        foreach ($sub in $subGroups) {
            $name = $sub.Name
            $subCount = $sub.Count
            if ([string]::IsNullOrEmpty($name)) {
                $lines.Add("  └─ (files): $subCount") | Out-Null
            } else {
                $lines.Add("  ├─ $name/: $subCount") | Out-Null
            }
        }
        $lines.Add('') | Out-Null
    }

    return $lines
}

$treePath = Join-Path $resolvedOutDir 'REPO_TREE.txt'
$treeLines = New-RepoTree $selected
[System.IO.File]::WriteAllLines($treePath, $treeLines, [System.Text.Encoding]::UTF8)

function Get-FirstFailNdjsonLine {
    param([string]$Root)

    # derived requirement: the Windows runner logged "Cannot convert 'System.Object[]' ... AdditionalChildPath"
    # because the trailing comma array syntax coerced each Join-Path result into a single-element
    # System.Object[]. Wrap each call in parentheses without a trailing comma so the binder receives
    # plain strings on every platform.
    $candidates = @(
        (Join-Path $Root 'ci_test_results.ndjson'),
        (Join-Path $Root 'tests~test-results.ndjson')
    )

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate)) { continue }
        try {
            foreach ($line in Get-Content -LiteralPath $candidate -Encoding UTF8) {
                $trim = $line.Trim()
                if (-not $trim) { continue }
                try {
                    $obj = $trim | ConvertFrom-Json
                } catch {
                    continue
                }
                if ($null -ne $obj.pass -and -not [bool]$obj.pass) {
                    return $trim
                }
            }
        } catch {
            continue
        }
    }

    return $null
}

$firstFail = Get-FirstFailNdjsonLine $repoRoot
if ($firstFail) {
    if ($redactRegex -and $redactRegex.IsMatch($firstFail)) {
        $firstFail = $redactRegex.Replace($firstFail, '***')
        if (-not ($redactedList -contains 'CONTEXT_first_failure.txt')) {
            $redactedList.Add('CONTEXT_first_failure.txt') | Out-Null
        }
    }
    $contextPath = Join-Path $resolvedOutDir 'CONTEXT_first_failure.txt'
    Set-Content -LiteralPath $contextPath -Value $firstFail -Encoding UTF8
}

$manifestPath = Join-Path $resolvedOutDir 'manifest.txt'
$manifest = New-Object System.Collections.Generic.List[string]
$manifest.Add("generated=$(Get-Date -Format o)") | Out-Null
$manifest.Add("repo_root=$repoRoot") | Out-Null
$manifest.Add("output_dir=$resolvedOutDir") | Out-Null
$manifest.Add("files_total=$totalCopied") | Out-Null
$manifest.Add("files_redacted=$($redactedList.Count)") | Out-Null
$manifest.Add('redacted_files:') | Out-Null
if ($redactedList.Count -eq 0) {
    $manifest.Add('  - none') | Out-Null
} else {
    foreach ($item in ($redactedList | Sort-Object)) {
        $manifest.Add("  - $item") | Out-Null
    }
}
[System.IO.File]::WriteAllLines($manifestPath, $manifest, [System.Text.Encoding]::UTF8)

$outFiles = Get-ChildItem -Path $resolvedOutDir -Recurse -File
if ($outFiles.Count -le 20) {
    throw "Corpus output contains only $($outFiles.Count) files; expected > 20."
}

Write-Host "Repo corpus generated at $resolvedOutDir with $($outFiles.Count) files."
