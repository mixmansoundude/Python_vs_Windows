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
        # falling back to NDJSON parsing keeps backwards compatibility with older runs.
        Get-Content -LiteralPath $artifact.FullName -Encoding UTF8 | ForEach-Object {
            $line = $_.Trim()
            if ($line) { $collected.Add($line) }
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

    foreach ($file in $ndjsonFiles) {
        $rel = [System.IO.Path]::GetRelativePath($batchRoot, $file.FullName)
        if (-not $perFileCounts.ContainsKey($rel)) { $perFileCounts[$rel] = [System.Collections.Generic.List[string]]::new() }

        Get-Content -LiteralPath $file.FullName -Encoding UTF8 | ForEach-Object {
            try {
                $obj = $_ | ConvertFrom-Json -ErrorAction Stop
                $id = Get-FailureIdFromObject -Root $obj
                if ($id) {
                    $collected.Add($id)
                    $perFileCounts[$rel].Add($id) | Out-Null
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
    if ($final.Count -gt 1 -and ($final -contains 'none')) {
        $final = @($final | Where-Object { $_ -ne 'none' })
    }
}

if (-not $final -or $final.Count -eq 0) { $final = @('none') }
$final | Set-Content -Encoding UTF8 $target

if ($debugLines.Count -eq 0) {
    $debugLines.Add('none') | Out-Null
}
$debugLines | Set-Content -Encoding UTF8 $debugTarget
