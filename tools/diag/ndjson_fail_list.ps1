[CmdletBinding()]
param()

# Fulfills "Summarize failing tests" extraction requirement by moving the logic into a
# reusable script under tools/diag while preserving existing behavior.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$diag = $env:DIAG
if (-not $diag) {
    throw 'DIAG environment variable is required.'
}

$batchRoot = Join-Path $diag '_artifacts/batch-check'
$target = Join-Path $diag 'batchcheck_failing.txt'
$debugTarget = Join-Path $diag 'batchcheck_fail-debug.txt'
$collected = [System.Collections.Generic.List[string]]::new()
$debugLines = [System.Collections.Generic.List[string]]::new()

if (Test-Path $batchRoot) {
    $artifactFiles = Get-ChildItem -Path $batchRoot -Recurse -File -Filter 'failing-tests.txt' -ErrorAction SilentlyContinue
    foreach ($artifact in $artifactFiles) {
        # Professional note: prefer the precomputed failing-tests artifact from batch-check when it exists;
        # falling back to NDJSON parsing keeps backwards compatibility with older runs. The literal "none"
        # from the artifact is a placeholder per "skip lines that equal none (trim + case-insensitive)".
        Get-Content -LiteralPath $artifact.FullName -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            if ($line -and -not ($line -ieq 'none')) {
                $collected.Add($line)
            }
        }
    }

    $debugArtifacts = Get-ChildItem -Path $batchRoot -Recurse -File -Filter 'fail-debug.txt' -ErrorAction SilentlyContinue
    foreach ($debug in $debugArtifacts) {
        $rel = [System.IO.Path]::GetRelativePath($batchRoot, $debug.FullName)
        $null = $debugLines.Add([string]::Format('# {0}', $rel))
        Get-Content -LiteralPath $debug.FullName -Encoding UTF8 | ForEach-Object {
            $debugLines.Add($_) | Out-Null
        }
        $null = $debugLines.Add('')
    }
}

if ($collected.Count -eq 0) {
    # Professional note: retain the existing NDJSON scan so legacy runs still emit a fail list even when the
    # artifact is missing (e.g., historic runs or partial fetches).
    $ndjsonFiles = @()
    if (Test-Path $batchRoot) {
        $ndjsonFiles = Get-ChildItem -Path $batchRoot -Recurse -File -Filter '*.ndjson' -ErrorAction SilentlyContinue
    }

    $perFileCounts = @{}

    function Get-FailureIdFromObject {
        param([object]$Root)

        if ($null -eq $Root) { return $null }

        $stack = [System.Collections.Stack]::new()
        $stack.Push($Root)

        $hasFailure = $false
        $nodeId = $null
        $nameVal = $null

        while ($stack.Count -gt 0) {
            $current = $stack.Pop()
            if ($null -eq $current) { continue }

            if ($current -is [System.Collections.IDictionary] -or $current -is [PSCustomObject]) {
                foreach ($prop in $current.PSObject.Properties) {
                    $propName = $prop.Name
                    $propValue = $prop.Value

                    if ([string]::IsNullOrEmpty($propName)) { continue }

                    if ($propName -ieq 'outcome') {
                        if ($propValue -is [string] -and $propValue -eq 'failed') { $hasFailure = $true }
                    } elseif ($propName -ieq 'nodeid') {
                        if (-not $nodeId -and $propValue) { $nodeId = [string]$propValue }
                    } elseif ($propName -ieq 'name') {
                        if (-not $nameVal -and $propValue) { $nameVal = [string]$propValue }
                    }

                    if ($propValue -ne $null -and -not ($propValue -is [string])) {
                        if ($propValue -is [System.Collections.IDictionary] -or $propValue -is [PSCustomObject]) {
                            $stack.Push($propValue)
                            continue
                        }
                        if ($propValue -is [System.Collections.IEnumerable]) {
                            foreach ($item in $propValue) { $stack.Push($item) }
                        }
                    }
                }
            } elseif ($current -is [System.Collections.IEnumerable] -and -not ($current -is [string])) {
                foreach ($item in $current) { $stack.Push($item) }
            }
        }

        if (-not $hasFailure) { return $null }
        if ($nodeId) { return $nodeId }
        return $nameVal
    }

    function Get-NdjsonSegments {
        param(
            [Parameter(Mandatory = $true)][string]$RawText
        )

        $segments = [System.Collections.Generic.List[string]]::new()
        if ([string]::IsNullOrEmpty($RawText)) { return $segments }

        $builder = [System.Text.StringBuilder]::new()
        $depth = 0
        $inString = $false
        $escapeNext = $false

        foreach ($ch in $RawText.ToCharArray()) {
            if ($inString) {
                $null = $builder.Append($ch)

                if ($escapeNext) {
                    $escapeNext = $false
                    continue
                }

                if ($ch -eq '\\') {
                    $escapeNext = $true
                    continue
                }

                if ($ch -eq '"') {
                    $inString = $false
                }

                continue
            }

            switch ($ch) {
                '"' {
                    $inString = $true
                    $null = $builder.Append($ch)
                    continue
                }
                '{' {
                    $depth += 1
                    $null = $builder.Append($ch)
                    continue
                }
                '}' {
                    if ($depth -gt 0) { $depth -= 1 }
                    $null = $builder.Append($ch)

                    if ($depth -eq 0) {
                        $segment = $builder.ToString().Trim()
                        if ($segment.Length -gt 0) {
                            $segments.Add($segment) | Out-Null
                        }
                        $null = $builder.Clear()
                    }

                    continue
                }
                default {
                    if ($depth -gt 0) {
                        $null = $builder.Append($ch)
                    }
                }
            }
        }

        $tail = $builder.ToString().Trim()
        if ($tail.Length -gt 0) { $segments.Add($tail) | Out-Null }

        return $segments
    }

    foreach ($file in $ndjsonFiles) {
        $rel = [System.IO.Path]::GetRelativePath($batchRoot, $file.FullName)
        if (-not $perFileCounts.ContainsKey($rel)) { $perFileCounts[$rel] = [System.Collections.Generic.List[string]]::new() }

        $raw = [IO.File]::ReadAllText($file.FullName, [Text.Encoding]::UTF8)
        if ([string]::IsNullOrWhiteSpace($raw)) { continue }

        # Professional note: upstream bundles sometimes concatenate JSON objects into one line. A
        # character-by-character tokenizer keeps `}{` sequences found inside strings intact while
        # still surfacing individual objects for ConvertFrom-Json.
        $segments = Get-NdjsonSegments -RawText $raw

        foreach ($segment in $segments) {
            $line = $segment.Trim()
            if (-not $line) { continue }

            try {
                $obj = $line | ConvertFrom-Json -ErrorAction Stop

                $failed = $false
                $name = $null

                $legacyId = Get-FailureIdFromObject -Root $obj
                if ($legacyId) {
                    $failed = $true
                    $name = $legacyId
                }

                if (-not $failed) {
                    # Professional note: batch-check emits compact NDJSON where `pass:false` marks
                    # failures instead of pytest-style "outcome" fields. Preserve the legacy scan
                    # while honoring the new signal so diagnostics stay in sync with Codex.
                    if ($obj.PSObject.Properties.Name -contains 'pass') {
                        if ($obj.pass -is [bool] -and -not $obj.pass) { $failed = $true }
                        elseif (($obj.pass -is [string]) -and ($obj.pass -ieq 'false')) { $failed = $true }
                    }
                    if (-not $failed -and $obj.status) {
                        $s = [string]$obj.status
                        if ($s -eq 'fail' -or $s -eq 'failure') { $failed = $true }
                    }
                    if ($failed) {
                        if ($obj.id) {
                            $name = [string]$obj.id
                        } elseif ($obj.desc) {
                            $name = [string]$obj.desc
                        }
                    }
                }

                if ($failed -and $name) {
                    $collected.Add($name)
                    $perFileCounts[$rel].Add($name) | Out-Null
                }
            } catch {}
        }
    }

    if ($perFileCounts.Count -gt 0) {
        foreach ($entry in $perFileCounts.GetEnumerator() | Sort-Object Key) {
            $count = 0
            if ($entry.Value) { $count = (@($entry.Value | Sort-Object -Unique)).Count }
            $debugLines.Add([string]::Format('fallback:{0}`t{1}', $entry.Key, $count)) | Out-Null
        }
    } elseif ($debugLines.Count -eq 0) {
        $debugLines.Add('fallback: no ndjson located') | Out-Null
    }
}

$final = @()
if ($collected.Count -gt 0) {
    $final = @($collected | Sort-Object -Unique)
    $realItems = @($final | Where-Object { $_ -and -not ($_ -ieq 'none') })
    if ($realItems.Count -gt 0) {
        $final = $realItems
    }
}

if (-not $final -or $final.Count -eq 0) { $final = @('none') }
$final | Set-Content -Encoding UTF8 $target

if ($debugLines.Count -eq 0) {
    $debugLines.Add('none') | Out-Null
}
$debugLines | Set-Content -Encoding UTF8 $debugTarget
