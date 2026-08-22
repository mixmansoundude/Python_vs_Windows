<#
ASCII only. Aggregates per-lane lane_verdict.json artifacts (one per matrix.mode, uploaded by
batch-check.yml's "Upload iterate gate verdict" step) into a single has_failures verdict for the
"Aggregate self-test verdicts" (selftest-gate) job.

Extracted out of that job's inline "Aggregate verdicts" step so tests/test_aggregate_selftest_
verdicts.ps1 can exercise it deterministically against fixture directories on every CI run --
mirrors tools/ci_cache_selfheal.ps1's own extraction (see that file and docs/agent-closed-
backlog.md's Item 19 entry for the precedent this follows).

CLAUDE.md Active Backlog Item 35's own "Precondition" caveat: the ORIGINAL inline version's
missing-artifact fallback only set has_failures=true when the downloaded set was EMPTY ACROSS
ALL LANES -- a single lane's lane_verdict.json silently missing (upload glitch, artifact-service
hiccup) while other lanes' artifacts landed fine was invisible. This version instead compares the
SET of expected lane IDs against the SET of observed lane IDs (read from each JSON record's own
"lane" field, falling back to the containing artifact directory's name when that field is absent)
and treats any expected lane that's missing -- or any unexpected/duplicate lane present -- as
has_failures=true, independent of what the overall matrix job's own result was.

Exit codes:
  0 = has_failures is false (no lane reported a real failure; every expected lane observed
      exactly once; no unexpected lane present)
  1 = has_failures is true (see the written report and Write-Host output for exactly why)

Always writes a JSON report to -ReportPath (same shape as the original inline step's
selftest-gate.json, with an added "lane_check" section covering the new missing/unexpected/
duplicate detection) for the caller to surface in the job summary.
#>
param(
    [Parameter(Mandatory = $true)][string]$VerdictsDir,
    [Parameter(Mandatory = $true)][string]$FallbackResult,
    [Parameter(Mandatory = $true)][string[]]$ExpectedLanes,
    [Parameter(Mandatory = $true)][string]$ReportPath
)

function Convert-ToBooleanOrNull {
    param(
        [Parameter(Mandatory = $false)]
        $Value
    )

    if ($null -eq $Value) { return $null }
    if ($Value -is [bool]) { return $Value }
    if ($Value -is [string]) {
        $text = $Value.Trim().ToLowerInvariant()
        switch ($text) {
            'true' { return $true }
            't' { return $true }
            'yes' { return $true }
            'y' { return $true }
            '1' { return $true }
            'false' { return $false }
            'f' { return $false }
            'no' { return $false }
            'n' { return $false }
            '0' { return $false }
        }
        return $null
    }
    if ($Value -is [int] -or $Value -is [long]) {
        if ($Value -eq 0) { return $false }
        if ($Value -eq 1) { return $true }
    }
    return $null
}

$files = @()
if (Test-Path -LiteralPath $VerdictsDir) {
    $files = Get-ChildItem -Path $VerdictsDir -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue
}

$has = $false
$lanes = @()
# derived requirement: a plain string[] (not a hashtable) so a lane appearing 0, 1, or 2+ times
# is all directly visible in $observedLanes.Count per key -- easier to reason about than a
# running boolean.
$observedLanes = [ordered]@{}

foreach ($file in $files) {
    # derived requirement: download-artifact@v6 (no merge-multiple) places each artifact under
    # its own <VerdictsDir>/<artifact-name>/ subdirectory -- the artifact name IS
    # "selftest-verdict-<lane>" (see batch-check.yml's "Upload iterate gate verdict" step), so
    # the immediate parent directory name is a second, independent source for the lane identity
    # besides the JSON record's own "lane" field.
    $dirLane = $null
    $prefix = 'selftest-verdict-'
    if ($file.Directory -and $file.Directory.Name -and $file.Directory.Name.StartsWith($prefix)) {
        $dirLane = $file.Directory.Name.Substring($prefix.Length)
    }

    try {
        $content = Get-Content -Raw -LiteralPath $file.FullName
        if ([string]::IsNullOrWhiteSpace($content)) { continue }
        $data = $content | ConvertFrom-Json -Depth 16
        if ($null -eq $data) { continue }

        $records = if ($data -is [array]) { $data } else { @($data) }
        foreach ($record in $records) {
            if ($null -eq $record) { continue }

            $value = $null
            if ($record.PSObject.Properties.Name -contains 'has_failures') {
                $value = Convert-ToBooleanOrNull -Value $record.has_failures
            }

            if ($record.PSObject.Properties.Name -notcontains 'source_file') {
                $record | Add-Member -NotePropertyName source_file -NotePropertyValue $file.FullName -Force
            }

            if ($null -eq $value) {
                $record | Add-Member -NotePropertyName parse_warning -NotePropertyValue 'has_failures missing or unparseable' -Force
            } elseif ($value) {
                $has = $true
            }

            $recordLane = $null
            if ($record.PSObject.Properties.Name -contains 'lane' -and $record.lane) {
                $recordLane = [string]$record.lane
            }
            $lane = if ($recordLane) { $recordLane } elseif ($dirLane) { $dirLane } else { $null }
            if ($lane) {
                if ($observedLanes.Contains($lane)) { $observedLanes[$lane] += 1 } else { $observedLanes[$lane] = 1 }
            } else {
                # derived requirement: a record with NEITHER a usable "lane" field NOR a
                # recognizable artifact directory name is itself an anomaly worth flagging --
                # attribute it to a synthetic '(unattributed)' bucket so it shows up as an
                # "unexpected lane" below rather than silently vanishing from the lane count.
                if ($observedLanes.Contains('(unattributed)')) { $observedLanes['(unattributed)'] += 1 } else { $observedLanes['(unattributed)'] = 1 }
            }

            $lanes += $record
        }
    } catch {
        $lanes += [ordered]@{
            lane = $file.BaseName
            error = $_.Exception.Message
            source_file = $file.FullName
        }
        $errLane = if ($dirLane) { $dirLane } else { '(unattributed)' }
        if ($observedLanes.Contains($errLane)) { $observedLanes[$errLane] += 1 } else { $observedLanes[$errLane] = 1 }
    }
}

# derived requirement: kept as an additional, independent safety net alongside the lane-set
# comparison below (which already catches the "zero lanes observed" case on its own, since every
# expected lane would show up as missing) -- this one also fires when the download directory
# itself never materialized for reasons the lane-set check alone would not distinguish, and
# preserves the original step's own "the matrix job itself did not report success" signal.
if (-not $files -and $FallbackResult -and $FallbackResult -ne 'success') {
    $has = $true
}

$expectedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$ExpectedLanes)
$observedSet = [System.Collections.Generic.HashSet[string]]::new([string[]]$observedLanes.Keys)

$missingLanes = @($ExpectedLanes | Where-Object { -not $observedSet.Contains($_) })
$unexpectedLanes = @($observedLanes.Keys | Where-Object { -not $expectedSet.Contains($_) })
$duplicateLanes = @($observedLanes.Keys | Where-Object { $observedLanes[$_] -gt 1 })

$laneCheckFailed = ($missingLanes.Count -gt 0) -or ($unexpectedLanes.Count -gt 0) -or ($duplicateLanes.Count -gt 0)
if ($laneCheckFailed) {
    $has = $true
    if ($missingLanes.Count -gt 0) {
        Write-Host ("::error::selftest-gate: expected lane(s) never reported a verdict: {0}" -f ($missingLanes -join ', '))
    }
    if ($unexpectedLanes.Count -gt 0) {
        Write-Host ("::error::selftest-gate: unexpected lane(s) reported a verdict: {0}" -f ($unexpectedLanes -join ', '))
    }
    if ($duplicateLanes.Count -gt 0) {
        Write-Host ("::error::selftest-gate: lane(s) reported a verdict more than once: {0}" -f ($duplicateLanes -join ', '))
    }
}

$report = [ordered]@{
    fallback_result = $FallbackResult
    has_failures = $has
    lanes = @($lanes)
    verdict_files = if ($files) { $files.FullName } else { @() }
    lane_check = [ordered]@{
        expected_lanes = @($ExpectedLanes)
        observed_lanes = [ordered]@{}
        missing_lanes = $missingLanes
        unexpected_lanes = $unexpectedLanes
        duplicate_lanes = $duplicateLanes
        failed = $laneCheckFailed
    }
}
foreach ($key in $observedLanes.Keys) { $report.lane_check.observed_lanes[$key] = $observedLanes[$key] }
$report | ConvertTo-Json -Depth 6 | Out-File -FilePath $ReportPath -Encoding utf8

if ($has) { exit 1 }
exit 0
