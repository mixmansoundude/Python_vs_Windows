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

function Clip-Lines {
    param(
        [string[]]$Lines,
        [int]$Max = 60
    )

    if ($null -eq $Lines) { return @() }
    if ($Max -le 0) { return @() }
    if ($Lines.Count -le $Max) { return $Lines }

    if ($Max -le 1) {
        return @($Lines[0])
    }

    $tailBudget = [Math]::Min(40, [Math]::Max(0, $Max - 21))
    $headBudget = $Max - $tailBudget - 1
    if ($headBudget -lt 1) { $headBudget = 1 }
    if ($headBudget -gt 20) { $headBudget = 20 }

    if ($headBudget -gt ($Lines.Count - $tailBudget)) {
        $headBudget = [Math]::Max(1, $Lines.Count - $tailBudget)
    }

    $tailBudget = [Math]::Min($tailBudget, [Math]::Max(0, $Lines.Count - $headBudget))

    $buffer = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $headBudget; $i++) {
        $buffer.Add($Lines[$i]) | Out-Null
    }

    if (($headBudget + $tailBudget) -lt $Lines.Count) {
        $buffer.Add('... [clipped] ...') | Out-Null
    }

    if ($tailBudget -gt 0) {
        $start = $Lines.Count - $tailBudget
        for ($j = $start; $j -lt $Lines.Count; $j++) {
            $buffer.Add($Lines[$j]) | Out-Null
        }
    }

    return $buffer
}

function Read-TextIfExists {
    param(
        [string]$Path,
        [int]$Max = 60
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return @() }
    if (-not (Test-Path $Path)) { return @() }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    } catch {
        return @()
    }

    if ($null -eq $raw) { return @() }

    $lines = $raw -split "`n"
    if ($null -eq $lines) { return @() }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($null -ne $lines[$i]) {
            $lines[$i] = $lines[$i].TrimEnd("`r")
        }
    }

    return Clip-Lines $lines $Max
}

function Grep-Context {
    param(
        [string]$Path,
        [string[]]$Patterns,
        [int]$Radius = 6,
        [int]$Max = 80
    )

    if (-not (Test-Path $Path)) { return @() }

    try {
        $lines = Get-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        return @()
    }

    if ($null -eq $lines) { return @() }

    $hits = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $current = $lines[$i]
        foreach ($pattern in $Patterns) {
            if ($current -match $pattern) {
                $start = [Math]::Max(0, $i - $Radius)
                $end = [Math]::Min($lines.Count - 1, $i + $Radius)
                for ($j = $start; $j -le $end; $j++) {
                    $hits.Add($lines[$j]) | Out-Null
                }
                $hits.Add('---') | Out-Null
                break
            }
        }
    }

    if ($hits.Count -eq 0) { return @() }
    if ($hits[$hits.Count - 1] -eq '---') {
        $hits.RemoveAt($hits.Count - 1)
    }

    return Clip-Lines ($hits.ToArray()) $Max
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
            $inputsProbe = Join-Path $candidate '_artifacts/iterate/inputs'
            $batchProbe = Join-Path $candidate '_artifacts/batch-check'
            if (Test-Path $inputsProbe) {
                return $candidate
            }
            if (Test-Path $batchProbe) {
                return $candidate
            }

            try {
                $match = Get-ChildItem -Path $candidate -Directory -Recurse -Depth 4 -ErrorAction SilentlyContinue |
                    Where-Object {
                        $iterProbe = Join-Path $_.FullName '_artifacts/iterate/inputs'
                        if (Test-Path $iterProbe) { $true }
                        else {
                            $batchProbeInner = Join-Path $_.FullName '_artifacts/batch-check'
                            if (Test-Path $batchProbeInner) { $true } else { $false }
                        }
                    } |
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

    $inputsRoot = Join-Path $DiagRoot '_artifacts/iterate/inputs'
    $batchRoot = Join-Path $DiagRoot '_artifacts/batch-check'
    $hasInputs = Test-Path $inputsRoot
    $hasBatch = Test-Path $batchRoot
    if (-not $hasInputs -and -not $hasBatch) { return $block }

    $remaining = 40
    $block.Add('----- Failure Context -----') | Out-Null
    $remaining--

    $added = $false

    if ($hasInputs) {
        foreach ($candidate in @('ci_test_results.ndjson', 'tests~test-results.ndjson')) {
            if ($remaining -le 0) { break }
            $path = Join-Path $inputsRoot $candidate
            if (-not (Test-Path $path)) { continue }

            if ($block.Count -gt 1) {
                $block.Add('') | Out-Null
                $remaining--
                if ($remaining -le 0) { break }
            }

            $block.Add("$candidate (public diag poller):") | Out-Null
            $remaining--
            if ($remaining -le 0) { break }

            $firstFailLine = $null
            try {
                foreach ($line in Get-Content -LiteralPath $path -Encoding UTF8) {
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
                    if (-not $firstFailLine) { $firstFailLine = $trim }
                }
            } catch {
                $firstFailLine = $null
            }

            if ($firstFailLine) {
                foreach ($line in Sanitize-TextLines @($firstFailLine)) {
                    if ($remaining -le 0) { break }
                    $block.Add($line) | Out-Null
                    $remaining--
                }
            }

            $added = $true
        }
    }

    if ($hasBatch -and $remaining -gt 0) {
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

    # derived requirement: earlier iterate runs produced empty prompts when diagnostics
    # artifacts were absent. Mirror the staged .codex/fail payloads and mirrored NDJSON to
    # keep Codex anchored to the real failure regardless of artifact layout.
    $budget = 120
    $headerAdded = $false

    $sources = @(
        @{ Header = '----- First failure -----'; Path = Join-Path $fallbackRoot 'first_failure.txt'; Limit = 5 },
        @{ Header = '----- CI structured -----'; Path = Join-Path $fallbackRoot 'ci_structured.txt'; Limit = 20 },
        @{ Header = '----- Focused job tail -----'; Path = Join-Path $fallbackRoot 'failing_job_focus.txt'; Limit = 80 }
    )

    foreach ($source in $sources) {
        if ($budget -le 0) { break }

        $lines = Read-TextIfExists $source.Path $source.Limit
        if (-not $lines -or $lines.Count -eq 0) { continue }

        if (-not $headerAdded) {
            $result.Add('----- Failure Context (staged) -----') | Out-Null
            $budget--
            $headerAdded = $true
            if ($budget -le 0) { break }
        }

        if ($result.Count -gt 1) {
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

    if ($budget -le 0) { return $result }

    $ndjsonCandidates = @('ci_test_results.ndjson', 'tests~test-results.ndjson')
    foreach ($candidate in $ndjsonCandidates) {
        if ($budget -le 0) { break }

        $candidatePath = Join-Path $WorkspaceRoot $candidate
        if (-not (Test-Path $candidatePath)) { continue }

        try {
            $line = Get-Content -LiteralPath $candidatePath -Encoding UTF8 -TotalCount 1
        } catch {
            $line = @()
        }

        if (-not $line) { continue }

        if (-not $headerAdded) {
            $result.Add('----- Failure Context (staged) -----') | Out-Null
            $budget--
            $headerAdded = $true
            if ($budget -le 0) { break }
        }

        if ($result.Count -gt 1) {
            $result.Add('') | Out-Null
            $budget--
            if ($budget -le 0) { break }
        }

        $result.Add('first failing NDJSON row:') | Out-Null
        $budget--
        if ($budget -le 0) { break }

        foreach ($entry in Sanitize-TextLines $line) {
            if ($budget -le 0) { break }
            $result.Add($entry) | Out-Null
            $budget--
        }

        break
    }

    return $result
}

function Get-CodeSnippetLines {
    param([string]$WorkspaceRoot)

    $result = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($WorkspaceRoot)) { return $result }

    $budget = 160
    $headerAdded = $false

    $snippets = @(
        @{ Label = 'run_setup.bat (helper invocation):'; Path = Join-Path $WorkspaceRoot 'run_setup.bat'; Patterns = @('~find_entry\.py', 'HP_SYS_PY', 'HP_HELPER_(CMD|ARGS)'); Radius = 6; Max = 80 },
        @{ Label = 'tests/selfapps_entry.ps1 (entry checks):'; Path = Join-Path $WorkspaceRoot 'tests/selfapps_entry.ps1'; Patterns = @('entry\.single\.direct', 'breadcrumb', 'Chosen entry'); Radius = 4; Max = 60 },
        @{ Label = 'tests/harness.ps1 (NDJSON emitters):'; Path = Join-Path $WorkspaceRoot 'tests/harness.ps1'; Patterns = @('ndjson', 'emit', 'id='); Radius = 4; Max = 60 }
    )

    foreach ($snippet in $snippets) {
        if ($budget -le 0) { break }

        $lines = Grep-Context $snippet.Path $snippet.Patterns $snippet.Radius $snippet.Max
        if (-not $lines -or $lines.Count -eq 0) { continue }

        if (-not $headerAdded) {
            $result.Add('----- Candidate code snippets -----') | Out-Null
            $budget--
            $headerAdded = $true
            if ($budget -le 0) { break }
        }

        if ($result.Count -gt 1) {
            $result.Add('') | Out-Null
            $budget--
            if ($budget -le 0) { break }
        }

        $result.Add($snippet.Label) | Out-Null
        $budget--
        if ($budget -le 0) { break }

        foreach ($line in Sanitize-TextLines $lines) {
            if ($budget -le 0) { break }
            $result.Add("  $line") | Out-Null
            $budget--
        }
    }

    if ($headerAdded -and $result.Count -gt 0 -and $result[$result.Count - 1] -eq '') {
        $result.RemoveAt($result.Count - 1)
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

# derived requirement: iterate now relies on the vector store corpus, so keep
# the guidance explicit to steer file_search toward the critical entry points.
Add-Lines $lines @(
    '',
    '----- File Search Guidance -----',
    'Use the file_search tool to open and inspect these, in order:',
    '- README.md, AGENTS.md',
    '- .github/workflows/codex-auto-iterate.yml',
    '- tools/ensure_ndjson_sources.ps1, tools/diag/build_prompt.ps1',
    '- run_setup.bat (and any *.bat/*.cmd invoked in logs)',
    '- tests/selfapps_entry.ps1, tests/harness.ps1',
    '- latest NDJSON (_artifacts/iterate/inputs/ci_test_results.ndjson and _artifacts/iterate/inputs/tests~test-results.ndjson)',
    'Use these exact path hints and REPO_TREE.txt to locate files; then propose a minimal unified diff.'
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

# derived requirement: iterate reviewers asked for actionable code anchors when Codex saw
# only failure metadata. Surface small repo excerpts near helper and NDJSON emitters so the
# model can jump directly to likely edit points without scanning the full tree.
$codeSnippets = Get-CodeSnippetLines $workspaceRoot
if ($codeSnippets.Count -gt 0) {
    Add-Lines $lines @('')
    Add-Lines $lines $codeSnippets
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

    $inputsRoot = Join-Path $diagRoot '_artifacts/iterate/inputs'
    if (Test-Path $inputsRoot) {
        $publicHead = Get-ChildItem -Path $inputsRoot -Filter '*.ndjson' -ErrorAction SilentlyContinue |
            Sort-Object Name |
            Select-Object -First 1
        if ($publicHead) {
            $ndLines = @()
            try {
                $ndLines = Get-Content -LiteralPath $publicHead.FullName -TotalCount 8
            } catch {
                $ndLines = @()
            }
            if ($ndLines) {
                Add-Lines $lines @('', '----- NDJSON head (public diag poller) -----')
                foreach ($entry in Sanitize-TextLines $ndLines) {
                    $lines.Add($entry) | Out-Null
                }
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
