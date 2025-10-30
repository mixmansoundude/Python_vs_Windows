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

# derived requirement: the EACCES failure originated from enumerations that escaped
# the GitHub workspace. Use the Actions-provided workspace root as the hard guard
# and refuse to traverse anything outside of it (including symlinks).
$workspaceRoot = if ([string]::IsNullOrWhiteSpace($env:GITHUB_WORKSPACE)) { $repoRoot } else { $env:GITHUB_WORKSPACE }
try {
    $workspaceFull = (Resolve-Path -LiteralPath $workspaceRoot -ErrorAction Stop).Path
} catch {
    throw "repo_corpus: workspace root missing or invalid: '$workspaceRoot'"
}

# derived requirement: reviewers flagged that vector-store uploads reject certain
# extensions (e.g., .ps1, .yml). Maintain originals for diagnostics while emitting
# .txt mirrors with provenance headers so the uploader can ingest text-friendly
# copies without losing context. Mirrors live under txt_mirror/relative_path.txt.
$vectorSafeExtensions = @('.txt', '.md', '.py', '.json', '.csv', '.html', '.xml', '.js', '.ts')
$additionalCorpusExt = @('.ps1', '.psm1', '.bat', '.cmd', '.yml', '.yaml', '.ini', '.cfg', '.toml')
$inclusionExtensions = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($ext in ($vectorSafeExtensions + $additionalCorpusExt)) {
    if (-not [string]::IsNullOrWhiteSpace($ext)) {
        [void]$inclusionExtensions.Add($ext.ToLowerInvariant())
    }
}
$vectorSafeSet = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($ext in $vectorSafeExtensions) {
    if (-not [string]::IsNullOrWhiteSpace($ext)) {
        [void]$vectorSafeSet.Add($ext.ToLowerInvariant())
    }
}

function Get-TxtMirrorPath {
    param(
        [string]$Relative,
        [string]$OutRoot
    )

    $mirrorRoot = Join-Path $OutRoot 'txt_mirror'
    $mirrorRel = ($Relative -replace '/', [System.IO.Path]::DirectorySeparatorChar) + '.txt'
    return Join-Path $mirrorRoot $mirrorRel
}

function Test-IsAccessDenied {
    param([System.Exception]$Exception)

    if ($null -eq $Exception) { return $false }
    if ($Exception -is [System.UnauthorizedAccessException]) { return $true }
    $message = $Exception.Message
    return $message -match '(?i)(access is denied|permission denied|eacces|eperm|unauthorized)'
}

function Test-IsWithinWorkspace {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    } catch {
        return $false
    }
    return $full.StartsWith($workspaceFull, [System.StringComparison]::OrdinalIgnoreCase)
}

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

function Get-AbsoluteRepoPath {
    param([string]$Relative)
    $normalized = $Relative -replace '/', [System.IO.Path]::DirectorySeparatorChar
    return Join-Path $repoRoot $normalized
}

function Should-IncludeFile {
    param([string]$Relative)

    foreach ($fragment in $denyFragments) {
        if ($Relative -like "*$fragment*") { return $false }
    }

    $ext = [System.IO.Path]::GetExtension($Relative)
    if ($denyExtensions -contains $ext) { return $false }

    if ([string]::IsNullOrWhiteSpace($ext)) { return $false }
    if ($inclusionExtensions.Contains($ext.ToLowerInvariant())) { return $true }

    return $false
}

$gitFiles = & git -C $repoRoot ls-files
if ($LASTEXITCODE -ne 0) {
    throw 'git ls-files failed'
}

$selected = @()
$mirrorCreated = 0
$skippedPermission = 0
$skippedOutside = 0
$uniqueDirs = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $gitFiles) {
    if ([string]::IsNullOrWhiteSpace($entry)) { continue }
    if (-not (Should-IncludeFile $entry)) { continue }
    $selected += $entry
}

$redactedList = New-Object System.Collections.Generic.List[string]
$copiedRelatives = New-Object System.Collections.Generic.List[string]
$totalCopied = 0
foreach ($relative in $selected) {
    $sourcePath = Get-AbsoluteRepoPath $relative
    if (-not (Test-Path -LiteralPath $sourcePath)) { continue }

    try {
        $resolvedSource = (Resolve-Path -LiteralPath $sourcePath -ErrorAction Stop).Path
    } catch {
        if (Test-IsAccessDenied $_.Exception) {
            Write-Host ("WARN  repo_corpus: EACCES on {0} (skipped)" -f $sourcePath)
            $skippedPermission++
            continue
        }
        throw
    }

    if (-not (Test-IsWithinWorkspace $resolvedSource)) {
        # derived requirement: keep traversal confined to the checkout even when symlinks
        # exist. Treat any escape attempt as a warning so diagnostics stay trustworthy.
        Write-Host ("WARN  repo_corpus: outside workspace skipped {0}" -f $relative)
        $skippedOutside++
        continue
    }

    $destRelative = $relative -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $destPath = Join-Path $resolvedOutDir $destRelative
    $destDir = Split-Path -Parent $destPath
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }
    $normalizedDir = $destDir
    try {
        $normalizedDir = [System.IO.Path]::GetFullPath($destDir)
    } catch {
        # derived requirement: keep counting even if GetFullPath trips over a UNC or empty path.
    }
    [void]$uniqueDirs.Add($normalizedDir)

    $content = $null
    try {
        $content = Get-Content -LiteralPath $resolvedSource -Raw -Encoding UTF8
    } catch {
        if (Test-IsAccessDenied $_.Exception) {
            Write-Host ("WARN  repo_corpus: EACCES on {0} (skipped)" -f $resolvedSource)
            $skippedPermission++
            continue
        }
        throw
    }
    if ($null -eq $content) { $content = '' }

    $wasRedacted = $false
    if ($redactRegex -and $redactRegex.IsMatch($content)) {
        # derived requirement: substring-only redaction keeps files present for embeddings
        # while masking tokens that could trip corpus uploads.
        $content = $redactRegex.Replace($content, '***')
        $wasRedacted = $true
    }

    Set-Content -LiteralPath $destPath -Value $content -Encoding UTF8

    $extLower = [System.IO.Path]::GetExtension($relative).ToLowerInvariant()
    if (-not $vectorSafeSet.Contains($extLower)) {
        $mirrorPath = Get-TxtMirrorPath -Relative $relative -OutRoot $resolvedOutDir
        $mirrorDir = Split-Path -Parent $mirrorPath
        if (-not (Test-Path -LiteralPath $mirrorDir)) {
            New-Item -ItemType Directory -Path $mirrorDir -Force | Out-Null
        }
        $mirrorHeader = "# MIRROR of non-allowlisted file`r`n# original: $relative`r`n# extension: $extLower`r`n# note: not sent to vector store`r`n`r`n"
        Set-Content -LiteralPath $mirrorPath -Value ($mirrorHeader + $content) -Encoding UTF8
        $mirrorCreated++
    }

    if ($wasRedacted) {
        $redactedList.Add($relative) | Out-Null
    }
    $copiedRelatives.Add($relative) | Out-Null
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
$treeLines = New-RepoTree $copiedRelatives
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
$manifest.Add("files_mirrored=$mirrorCreated") | Out-Null
$manifest.Add("files_skipped_permission=$skippedPermission") | Out-Null
$manifest.Add("files_skipped_outside=$skippedOutside") | Out-Null
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

Write-Host ("INFO  repo_corpus: scanned={0} dirs={1} skipped_perm={2} mirrored_txt={3}" -f $totalCopied, $uniqueDirs.Count, $skippedPermission, $mirrorCreated)
if ($skippedOutside -gt 0) {
    Write-Host ("INFO  repo_corpus: skipped_outside={0}" -f $skippedOutside)
}
Write-Host "Repo corpus generated at $resolvedOutDir with $($outFiles.Count) files."
