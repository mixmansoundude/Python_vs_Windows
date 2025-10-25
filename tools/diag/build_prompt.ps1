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

# derived requirement: Failure Context must reuse the iterate sanitizer's pattern so prompts never
# leak secrets when we inline first_failure.json or NDJSON rows.
$script:RedactRegex = $null
$script:RedactPlaceholder = if ($env:REDACT_PLACEHOLDER) { $env:REDACT_PLACEHOLDER } else { '***' }
$promptRedactPattern = $env:REDACT_PATTERN
if (-not $promptRedactPattern) {
    $promptRedactPattern = $env:ITERATE_REDACT_PATTERN
}
if ($promptRedactPattern) {
    try {
        $script:RedactRegex = [System.Text.RegularExpressions.Regex]::new($promptRedactPattern)
    } catch {
        $script:RedactRegex = $null
    }
}

function Invoke-RedactLine {
    param([string]$Text)

    if ($null -eq $Text) { return '' }
    if (-not $script:RedactRegex) { return $Text }
    if (-not $script:RedactRegex.IsMatch($Text)) { return $Text }

    $prefixMatch = [System.Text.RegularExpressions.Regex]::Match($Text, '^(?<prefix>\s*(?:[-*]\s+)?)')
    $prefix = $prefixMatch.Groups['prefix'].Value
    if ([string]::IsNullOrEmpty($prefix)) {
        return $script:RedactPlaceholder
    }
    return $prefix + $script:RedactPlaceholder
}

function Sanitize-TextLines {
    param([string[]]$Lines)

    $buffer = [System.Collections.Generic.List[string]]::new()
    foreach ($line in $Lines) {
        $printable = Convert-ToPrintable $line
        $buffer.Add((Invoke-RedactLine $printable)) | Out-Null
    }
    return $buffer
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

function Get-FailureContextLines {
    param([string]$DiagRoot)

    $block = [System.Collections.Generic.List[string]]::new()
    if ([string]::IsNullOrWhiteSpace($DiagRoot)) { return $block }

    $batchRoot = Join-Path $DiagRoot '_artifacts/batch-check'
    if (-not (Test-Path $batchRoot)) { return $block }

    $remaining = 40
    $block.Add('----- Failure Context -----') | Out-Null
    $remaining--

    $added = $false

    $firstFailure = $null
    try {
        $firstFailure = Get-ChildItem -Path $batchRoot -Recurse -File -Filter 'first_failure.json' -ErrorAction SilentlyContinue | Select-Object -First 1
    } catch {
        $firstFailure = $null
    }
    if ($firstFailure -and $remaining -gt 0) {
        if ($block.Count -gt 1) {
            $block.Add('') | Out-Null
            $remaining--
        }

        $relative = $firstFailure.FullName
        try {
            $relative = [System.IO.Path]::GetRelativePath($DiagRoot, $firstFailure.FullName)
        } catch {
            $relative = $firstFailure.FullName
        }
        $block.Add("first_failure.json ($relative):") | Out-Null
        $remaining--

        if ($remaining -gt 0) {
            try {
                $rawLines = Get-Content -LiteralPath $firstFailure.FullName -Encoding UTF8
            } catch {
                $rawLines = @()
            }
            foreach ($line in Sanitize-TextLines $rawLines) {
                if ($remaining -le 0) { break }
                $block.Add($line) | Out-Null
                $remaining--
            }
        }

        $added = $true
    }

    if ($remaining -gt 0) {
        $ndjsonPath = $null
        try {
            $ndjsonPath = Get-ChildItem -Path $batchRoot -Recurse -File -Filter 'ci_test_results.ndjson' -ErrorAction SilentlyContinue | Select-Object -First 1
        } catch {
            $ndjsonPath = $null
        }

        if ($ndjsonPath) {
            $firstFailLine = $null
            try {
                foreach ($line in Get-Content -LiteralPath $ndjsonPath.FullName -Encoding UTF8) {
                    $trim = $line.Trim()
                    if (-not $trim) { continue }
                    try {
                        $obj = $trim | ConvertFrom-Json
                    } catch {
                        continue
                    }
                    if ($null -ne $obj.pass -and -not [bool]$obj.pass) {
                        $firstFailLine = $trim
                        break
                    }
                }
            } catch {
                $firstFailLine = $null
            }

            if ($firstFailLine) {
                if ($block.Count -gt 1) {
                    $block.Add('') | Out-Null
                    $remaining--
                }

                $relativeNd = $ndjsonPath.FullName
                try {
                    $relativeNd = [System.IO.Path]::GetRelativePath($DiagRoot, $ndjsonPath.FullName)
                } catch {
                    $relativeNd = $ndjsonPath.FullName
                }
                $block.Add("First failing NDJSON row ($relativeNd):") | Out-Null
                $remaining--

                if ($remaining -gt 0) {
                    foreach ($line in Sanitize-TextLines @($firstFailLine)) {
                        if ($remaining -le 0) { break }
                        $block.Add($line) | Out-Null
                        $remaining--
                    }
                }

                $added = $true
            }
        }
    }

    if (-not $added) {
        return [System.Collections.Generic.List[string]]::new()
    }

    return $block
}

function Get-StagedFailureContextLines {
    param([string]$WorkspaceRoot)

    $result = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return $result }

    $fallbackRoot = Join-Path $WorkspaceRoot '.codex/fail'
    if (-not (Test-Path $fallbackRoot)) { return $result }

    # derived requirement: reviewer flagged that iterate prompts lacked failure context when
    # no diagnostics tree was present. Mirror the staged .codex/fail payloads so Codex
    # always sees the first failing clues even when _artifacts/batch-check is missing.
    $budget = 40
    $sources = @(
        @{ Header = '----- First failure -----'; Path = Join-Path $fallbackRoot 'first_failure.txt'; Limit = 5 },
        @{ Header = '----- CI structured -----'; Path = Join-Path $fallbackRoot 'ci_structured.txt'; Limit = 20 },
        @{ Header = '----- Focused job tail -----'; Path = Join-Path $fallbackRoot 'failing_job_focus.txt'; Limit = 80 }
    )

    foreach ($source in $sources) {
        if ($budget -le 0) { break }

        $path = $source.Path
        if (-not (Test-Path $path)) { continue }

        $lines = @()
        try {
            $lines = Get-Content -LiteralPath $path -Encoding UTF8 -TotalCount $source.Limit
        } catch {
            $lines = @()
        }

        if (-not $lines) { continue }

        if ($result.Count -gt 0) {
            $result.Add('') | Out-Null
            $budget--
            if ($budget -le 0) { break }
        }

        $result.Add($source.Header) | Out-Null
        $budget--
        if ($budget -le 0) { break }

        foreach ($line in Sanitize-TextLines $lines) {
            if ($budget -le 0) { break }
            $result.Add($line) | Out-Null
            $budget--
        }
    }

    return $result
}

$promptPath = Join-Path $env:RUNNER_TEMP 'prompt.txt'

$repo    = $env:REPO
$branch  = $env:BRANCH
$sha     = $env:HEAD_SHA
$attempt = $env:ATTEMPT_NEXT
$maxAttempts = if ($env:MAX_ATTEMPTS) { $env:MAX_ATTEMPTS } else { 'n/a' }

$workspaceRoot = (Get-Location).Path

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

$failureContext = [System.Collections.Generic.List[string]]::new()
if ($diagRoot) {
    $failureContext = Get-FailureContextLines $diagRoot
    if ($failureContext.Count -gt 0) {
        Add-Lines $lines @('')
        Add-Lines $lines $failureContext
    }
}

if (-not $diagRoot -or $failureContext.Count -eq 0) {
    $stagedContext = Get-StagedFailureContextLines $workspaceRoot
    if ($stagedContext.Count -gt 0) {
        Add-Lines $lines @('')
        Add-Lines $lines $stagedContext
    }
}
if ($diagRoot) {
    $failListPath = Join-Path $diagRoot 'batchcheck_failing.txt'
    if (Test-Path $failListPath) {
        $failLines = @()
        try {
            $failLines = Get-Content -LiteralPath $failListPath -TotalCount 10
        } catch {
            $failLines = @()
        }
        if ($failLines) {
            Add-Lines $lines @('', '----- Batch-check failing IDs -----')
            foreach ($entry in Sanitize-TextLines $failLines) {
                $lines.Add($entry) | Out-Null
            }
        }
    }

    $batchRoot = Join-Path $diagRoot '_artifacts/batch-check'
    if (Test-Path $batchRoot) {
        $ndjsonHead = Get-ChildItem -Path $batchRoot -Recurse -File -Filter '*~test-results.ndjson' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($ndjsonHead) {
            $ndLines = @()
            try {
                $ndLines = Get-Content -LiteralPath $ndjsonHead.FullName -TotalCount 8
            } catch {
                $ndLines = @()
            }
            if ($ndLines) {
                Add-Lines $lines @('', '----- NDJSON head (batch-check) -----')
                foreach ($entry in Sanitize-TextLines $ndLines) {
                    $lines.Add($entry) | Out-Null
                }
            }
        }
    }
}

[IO.File]::WriteAllLines($promptPath, $lines, [System.Text.Encoding]::UTF8)

if ($env:GITHUB_OUTPUT) {
    "path=$promptPath" | Out-File -FilePath $env:GITHUB_OUTPUT -Encoding utf8 -Append
}
