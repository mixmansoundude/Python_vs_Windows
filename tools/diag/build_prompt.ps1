[CmdletBinding()]
param()

# Derived from workflow inline logic per "Create repo scripts under tools/diag" to keep the
# prompt builder maintainable while preserving current behavior.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Convert-ToPrintable {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    return [System.Text.RegularExpressions.Regex]::Replace($Text, '[^\u0009\u0020-\u007E]', '?')
}

function Add-Lines {
    param([System.Collections.Generic.List[string]]$Buffer, [string[]]$Lines)
    foreach ($line in $Lines) {
        $Buffer.Add($line) | Out-Null
    }
}

function Find-DiagRoot {
    param([string[]]$Hints)

    foreach ($hint in $Hints) {
        if ([string]::IsNullOrWhiteSpace($hint)) { continue }
        $resolved = @()
        try {
            $resolved = Resolve-Path -LiteralPath $hint -ErrorAction Stop
        } catch {
            continue
        }

        foreach ($entry in $resolved) {
            $candidate = $entry.Path
            if (Test-Path (Join-Path $candidate '_artifacts/batch-check')) {
                return $candidate
            }

            try {
                $match = Get-ChildItem -Path $candidate -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                    Where-Object { Test-Path (Join-Path $_.FullName '_artifacts/batch-check') } |
                    Select-Object -First 1
            } catch {
                $match = $null
            }

            if ($match) {
                return $match.FullName
            }
        }
    }

    return $null
}

$promptPath = Join-Path $env:RUNNER_TEMP 'prompt.txt'
$repoFilesPath = Join-Path $env:RUNNER_TEMP 'repo-files.txt'

$repo    = $env:REPO
$branch  = $env:BRANCH
$sha     = $env:HEAD_SHA
$attempt = $env:ATTEMPT_NEXT
$maxAttempts = if ($env:MAX_ATTEMPTS) { $env:MAX_ATTEMPTS } else { 'n/a' }

$workspaceRoot = (Get-Location).Path
$failDir = Join-Path $workspaceRoot '.codex/fail'
if (-not (Test-Path $failDir)) {
    New-Item -ItemType Directory -Path $failDir -Force | Out-Null
}

try {
    $gitOutput = & git ls-files 2>$null
    if ($LASTEXITCODE -eq 0 -and $gitOutput) {
        [IO.File]::WriteAllLines($repoFilesPath, $gitOutput, [System.Text.Encoding]::UTF8)
    } elseif (Test-Path $repoFilesPath) {
        Remove-Item -LiteralPath $repoFilesPath -ErrorAction SilentlyContinue
    }
} catch {
    if (Test-Path $repoFilesPath) {
        Remove-Item -LiteralPath $repoFilesPath -ErrorAction SilentlyContinue
    }
}

$lines = [System.Collections.Generic.List[string]]::new()
Add-Lines $lines @(
    'You are Codex. You have a working copy of the repo checked out.',
    'Read README.md and AGENTS.md (if present) in the workspace for local policy.',
    '',
    'Task: diagnose and fix CI failures for the GitHub Actions workflow(s).',
    'Prefer minimal edits and explain changes in commit messages.',
    '',
    "Repo: $repo",
    "Branch: $branch",
    "Commit: $sha",
    "Attempt: $attempt/$maxAttempts",
    '',
    "Strict output instruction: Return a unified diff patch inside a single fenced code block labeled 'diff'.",
    "Immediately follow the diff block with a fenced block labeled 'summary_text' (max 10 lines) explaining:",
    "- the top 1-3 candidate fixes you considered (file + hunk hint)",
    "- why you rejected each candidate",
    "- what additional evidence would unblock progress",
    'If no changes are needed, the diff fence must contain exactly "# no changes" and the summary_text fence must still satisfy the points above.',
    '```diff',
    '# no changes',
    '```'
)

if (Test-Path $repoFilesPath) {
    $head = Get-Content -LiteralPath $repoFilesPath -TotalCount 300
    if ($head) {
        Add-Lines $lines @('', '----- Repo files (head) -----')
        foreach ($entry in $head) {
            $lines.Add($entry) | Out-Null
        }
    }
}

$firstFailurePath = Join-Path $failDir 'first_failure.txt'
if (Test-Path $firstFailurePath) {
    $firstLine = Get-Content -LiteralPath $firstFailurePath -TotalCount 1 | Select-Object -First 1
    if ($firstLine) {
        Add-Lines $lines @('', 'First failure:', $firstLine)
    }
}

$contextSource = $null
$structuredPath = Join-Path $failDir 'ci_structured.txt'
if (Test-Path $structuredPath) {
    $contextSource = $structuredPath
} else {
    $focusFallback = Join-Path $failDir 'failing_job_focus.txt'
    if (Test-Path $focusFallback) {
        $contextSource = $focusFallback
    }
}
if (-not $contextSource) {
    $contextSource = $env:LOGFOCUS_PATH
    if (-not $contextSource -or -not (Test-Path $contextSource)) {
        $contextSource = $env:LOGTAIL_PATH
    }
}
if ($contextSource -and (Test-Path $contextSource)) {
    $head120 = Get-Content -LiteralPath $contextSource -TotalCount 120 | ForEach-Object { Convert-ToPrintable $_ }
    if ($head120) {
        Add-Lines $lines @('', 'Failing job log tail (first 120 lines):')
        foreach ($entry in $head120) { $lines.Add($entry) | Out-Null }
    }
}

if ($env:STRUCT_PATH -and (Test-Path $env:STRUCT_PATH)) {
    $structHead = Get-Content -LiteralPath $env:STRUCT_PATH -TotalCount 120 | ForEach-Object { Convert-ToPrintable $_ }
    if ($structHead) {
        Add-Lines $lines @('', '----- CI structured error (first record / head) -----')
        foreach ($entry in $structHead) { $lines.Add($entry) | Out-Null }
    }
}

$focusLog = $env:LOGFOCUS_PATH
if ($focusLog -and (Test-Path $focusLog)) {
    $focusLines = Get-Content -LiteralPath $focusLog | ForEach-Object { Convert-ToPrintable $_ }
    if ($focusLines) {
        Add-Lines $lines @('', '----- Focused failing job log (matched identifier) -----')
        foreach ($entry in $focusLines) { $lines.Add($entry) | Out-Null }
    }
} elseif ($env:LOGTAIL_PATH -and (Test-Path $env:LOGTAIL_PATH)) {
    $tailLines = Get-Content -LiteralPath $env:LOGTAIL_PATH | Select-Object -Last 200 | ForEach-Object { Convert-ToPrintable $_ }
    if ($tailLines) {
        Add-Lines $lines @('', '----- Failing job log tail (last 200 lines) -----')
        foreach ($entry in $tailLines) { $lines.Add($entry) | Out-Null }
    }
}

$diagRoot = $env:DIAG
if (-not $diagRoot) {
    $diagRoot = Find-DiagRoot @(
        $workspaceRoot,
        (Join-Path $workspaceRoot 'diag'),
        (Join-Path $workspaceRoot '.codex'),
        (Join-Path $workspaceRoot 'iterate'),
        $env:RUNNER_TEMP
    )
}
if ($diagRoot) {
    $failListPath = Join-Path $diagRoot 'batchcheck_failing.txt'
    if (Test-Path $failListPath) {
        Add-Lines $lines @('', '----- Batch-check failing IDs -----')
        Get-Content -LiteralPath $failListPath -TotalCount 10 | ForEach-Object {
            $lines.Add($_) | Out-Null
        }
    }

    $batchRoot = Join-Path $diagRoot '_artifacts/batch-check'
    if (Test-Path $batchRoot) {
        $ndjsonHead = Get-ChildItem -Path $batchRoot -Recurse -File -Filter '*~test-results.ndjson' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ndjsonHead) {
            Add-Lines $lines @('', '----- NDJSON head (batch-check) -----')
            Get-Content -LiteralPath $ndjsonHead.FullName -TotalCount 8 | ForEach-Object {
                $lines.Add((Convert-ToPrintable $_)) | Out-Null
            }
        }
    }
}

[IO.File]::WriteAllLines($promptPath, $lines, [System.Text.Encoding]::UTF8)

if ($env:GITHUB_OUTPUT) {
    "path=$promptPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
