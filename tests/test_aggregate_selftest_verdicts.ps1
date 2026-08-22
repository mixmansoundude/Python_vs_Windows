# ASCII only
# test_aggregate_selftest_verdicts.ps1 - deterministic regression test for
# tools/aggregate_selftest_verdicts.ps1 (the selftest-gate "Aggregate verdicts" logic,
# CLAUDE.md Active Backlog Item 35's "Precondition" caveat).
#
# Unlike a real batch-check.yml run (which would need all 8 matrix lanes to actually finish and
# upload their own lane_verdict.json artifacts before the aggregation step ever runs), this test
# exercises the extracted script directly against fixture directories built to mimic exactly what
# actions/download-artifact@v6 produces (each artifact under its own
# <VerdictsDir>/selftest-verdict-<lane>/lane_verdict.json subdirectory, no merge-multiple) -- no
# dependency on a real CI run or real artifact upload/download round trip. Wired into the `real`
# lane (a GATING lane, not in the job-level continue-on-error list) so a regression in the
# aggregation logic itself actually fails CI, mirroring tests/test_ci_cache_selfheal.ps1's own
# precedent for tools/ci_cache_selfheal.ps1 (see that file and docs/agent-closed-backlog.md's
# Item 19 entry).
#
# Six scenarios, all against fake lane_verdict.json fixtures (never real matrix-lane output):
#   healthy          - all 8 expected lanes present exactly once, all has_failures:false ->
#                       exit 0.
#   lane_failed       - all 8 expected lanes present, but ONE genuinely reports
#                       has_failures:true -> exit 1 (regression-guard for the pre-existing,
#                       unchanged per-lane has_failures union behavior).
#   missing_lane      - only 7 of 8 expected lanes present (one never uploaded) -> exit 1 (the
#                       actual gap this item's Precondition caveat closes -- the ORIGINAL inline
#                       logic could not detect this at all, since $files was non-empty).
#   unexpected_lane   - all 8 expected lanes present PLUS one lane not in the expected set -> exit
#                       1.
#   duplicate_lane    - all 8 expected lanes present, but ONE lane's verdict was uploaded twice
#                       (two separate artifact directories, same "lane" field inside the JSON) ->
#                       exit 1.
#   empty_fallback    - no verdict directory at all, with FallbackResult='success' -- proves the
#                       new lane-set check fires independent of the fallback result (a genuine
#                       improvement over the OLD behavior, which only fired here when
#                       FallbackResult was NOT 'success') -> exit 1.
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$script = Join-Path $repo 'tools/aggregate_selftest_verdicts.ps1'
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

function Write-NdjsonRow {
    param([hashtable]$Row)
    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

# derived requirement: unlike tests/test_ci_cache_selfheal.ps1 (which genuinely shells out to
# conda.bat via cmd.exe and needs real Windows file-locking semantics), the script under test
# here is pure PowerShell -- JSON parsing and plain file I/O only, no OS-specific calls. It runs
# identically under pwsh on Linux or Windows, so this test deliberately does NOT skip on
# non-Windows -- doing so would only lose local pre-push verification for no real safety benefit
# (this repo's own CI still only runs Windows runners regardless).

$expectedLanes = @('cache', 'real', 'conda-full', 'justme-test', 'uv', 'contract-uv', 'contract-uv-fail', 'uv-dl-fallback')

function New-VerdictFixture {
    # derived requirement: build a fresh, empty VerdictsDir for each scenario -- fixtures must
    # never leak between scenarios, or a missing-lane scenario could accidentally "see" a lane
    # directory left over from a prior scenario and pass for the wrong reason.
    param([string]$Dir)
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
}

function Add-VerdictRecord {
    # derived requirement: $ArtifactLane names the FOLDER (mimicking the artifact name
    # download-artifact@v6 creates); $RecordLane is the "lane" field written INSIDE the JSON --
    # kept as separate parameters (usually equal) so the duplicate_lane scenario can construct
    # two differently-NAMED folders that both claim the SAME record lane, exactly like a real
    # double-upload would look once downloaded.
    param([string]$Dir, [string]$ArtifactLane, [string]$RecordLane, [bool]$HasFailures)
    $artifactDir = Join-Path $Dir "selftest-verdict-$ArtifactLane"
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
    $record = [ordered]@{
        lane = $RecordLane
        has_failures = $HasFailures
        raw = $HasFailures.ToString().ToLowerInvariant()
        run_id = '999999'
        run_attempt = '1'
        sources = @('tests~test-results.ndjson', 'ci_test_results.ndjson')
    }
    $record | ConvertTo-Json -Compress -Depth 8 | Out-File -FilePath (Join-Path $artifactDir 'lane_verdict.json') -Encoding ascii
}

function Invoke-Aggregate {
    param([string]$VerdictsDir, [string]$FallbackResult, [string]$ReportPath)
    & $script -VerdictsDir $VerdictsDir -FallbackResult $FallbackResult -ExpectedLanes $expectedLanes -ReportPath $ReportPath
    return $LASTEXITCODE
}

$scratchRoot = Join-Path $here '~selftest_aggregate_verdicts'
if (Test-Path -LiteralPath $scratchRoot) { Remove-Item -LiteralPath $scratchRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null

$allPass = $true

# --- Scenario 1: healthy ---
$dir1 = Join-Path $scratchRoot 'healthy'
$report1 = Join-Path $scratchRoot 'healthy_report.json'
New-VerdictFixture -Dir $dir1
foreach ($lane in $expectedLanes) { Add-VerdictRecord -Dir $dir1 -ArtifactLane $lane -RecordLane $lane -HasFailures $false }
$rc1 = Invoke-Aggregate -VerdictsDir $dir1 -FallbackResult 'success' -ReportPath $report1
$pass1 = ($rc1 -eq 0) -and (Test-Path -LiteralPath $report1)
Write-NdjsonRow ([ordered]@{
    id='self.ci.aggregate_selftest_verdicts.healthy'; pass=$pass1
    desc='aggregate_selftest_verdicts.ps1: all 8 expected lanes present exactly once, none failing -> has_failures false'
    details=[ordered]@{ exitCode=$rc1 }
})
if (-not $pass1) { $allPass = $false }

# --- Scenario 2: one lane genuinely fails ---
$dir2 = Join-Path $scratchRoot 'lane_failed'
$report2 = Join-Path $scratchRoot 'lane_failed_report.json'
New-VerdictFixture -Dir $dir2
foreach ($lane in $expectedLanes) {
    $failed = ($lane -eq 'real')
    Add-VerdictRecord -Dir $dir2 -ArtifactLane $lane -RecordLane $lane -HasFailures $failed
}
$rc2 = Invoke-Aggregate -VerdictsDir $dir2 -FallbackResult 'success' -ReportPath $report2
$pass2 = ($rc2 -eq 1)
Write-NdjsonRow ([ordered]@{
    id='self.ci.aggregate_selftest_verdicts.lane_failed'; pass=$pass2
    desc='aggregate_selftest_verdicts.ps1: a genuine per-lane has_failures:true is still detected (regression guard for the pre-existing behavior)'
    details=[ordered]@{ exitCode=$rc2 }
})
if (-not $pass2) { $allPass = $false }

# --- Scenario 3: a lane never uploaded at all ---
# derived requirement: this is the actual gap Item 35's Precondition caveat closes -- the
# ORIGINAL inline aggregation logic had no way to detect this at all, since $files was non-empty
# (7 of 8 lanes still landed fine) and no individual record reported has_failures:true.
$dir3 = Join-Path $scratchRoot 'missing_lane'
$report3 = Join-Path $scratchRoot 'missing_lane_report.json'
New-VerdictFixture -Dir $dir3
foreach ($lane in $expectedLanes) {
    if ($lane -eq 'contract-uv-fail') { continue }
    Add-VerdictRecord -Dir $dir3 -ArtifactLane $lane -RecordLane $lane -HasFailures $false
}
$rc3 = Invoke-Aggregate -VerdictsDir $dir3 -FallbackResult 'success' -ReportPath $report3
$pass3 = $false
if ($rc3 -eq 1 -and (Test-Path -LiteralPath $report3)) {
    $reportData3 = Get-Content -Raw -LiteralPath $report3 | ConvertFrom-Json
    $pass3 = ($reportData3.lane_check.missing_lanes -contains 'contract-uv-fail')
}
Write-NdjsonRow ([ordered]@{
    id='self.ci.aggregate_selftest_verdicts.missing_lane'; pass=$pass3
    desc='aggregate_selftest_verdicts.ps1: a single missing lane (7 of 8 present) is detected and named in the report -- the ORIGINAL inline logic could not see this at all'
    details=[ordered]@{ exitCode=$rc3 }
})
if (-not $pass3) { $allPass = $false }

# --- Scenario 4: an unexpected extra lane ---
$dir4 = Join-Path $scratchRoot 'unexpected_lane'
$report4 = Join-Path $scratchRoot 'unexpected_lane_report.json'
New-VerdictFixture -Dir $dir4
foreach ($lane in $expectedLanes) { Add-VerdictRecord -Dir $dir4 -ArtifactLane $lane -RecordLane $lane -HasFailures $false }
Add-VerdictRecord -Dir $dir4 -ArtifactLane 'bogus-lane' -RecordLane 'bogus-lane' -HasFailures $false
$rc4 = Invoke-Aggregate -VerdictsDir $dir4 -FallbackResult 'success' -ReportPath $report4
$pass4 = $false
if ($rc4 -eq 1 -and (Test-Path -LiteralPath $report4)) {
    $reportData4 = Get-Content -Raw -LiteralPath $report4 | ConvertFrom-Json
    $pass4 = ($reportData4.lane_check.unexpected_lanes -contains 'bogus-lane')
}
Write-NdjsonRow ([ordered]@{
    id='self.ci.aggregate_selftest_verdicts.unexpected_lane'; pass=$pass4
    desc='aggregate_selftest_verdicts.ps1: an unexpected lane not in the matrix mode list is detected and named in the report'
    details=[ordered]@{ exitCode=$rc4 }
})
if (-not $pass4) { $allPass = $false }

# --- Scenario 5: a lane uploaded twice (duplicate) ---
$dir5 = Join-Path $scratchRoot 'duplicate_lane'
$report5 = Join-Path $scratchRoot 'duplicate_lane_report.json'
New-VerdictFixture -Dir $dir5
foreach ($lane in $expectedLanes) { Add-VerdictRecord -Dir $dir5 -ArtifactLane $lane -RecordLane $lane -HasFailures $false }
# derived requirement: a SECOND, differently-named artifact directory whose JSON record still
# claims lane 'cache' -- simulates a real double-upload (e.g. a retried step re-uploading under a
# fresh artifact name) surviving the download step, not just a filesystem-level name collision.
Add-VerdictRecord -Dir $dir5 -ArtifactLane 'cache-retry' -RecordLane 'cache' -HasFailures $false
$rc5 = Invoke-Aggregate -VerdictsDir $dir5 -FallbackResult 'success' -ReportPath $report5
$pass5 = $false
if ($rc5 -eq 1 -and (Test-Path -LiteralPath $report5)) {
    $reportData5 = Get-Content -Raw -LiteralPath $report5 | ConvertFrom-Json
    $pass5 = ($reportData5.lane_check.duplicate_lanes -contains 'cache')
}
Write-NdjsonRow ([ordered]@{
    id='self.ci.aggregate_selftest_verdicts.duplicate_lane'; pass=$pass5
    desc='aggregate_selftest_verdicts.ps1: a lane whose verdict was uploaded twice is detected and named in the report'
    details=[ordered]@{ exitCode=$rc5 }
})
if (-not $pass5) { $allPass = $false }

# --- Scenario 6: no verdict directory at all, fallback result is 'success' ---
# derived requirement: proves the NEW lane-set check fires regardless of FallbackResult -- the
# OLD inline logic's own missing-artifact fallback only set has_failures=true here when
# FallbackResult was NOT 'success'; this scenario deliberately passes 'success' to prove the new
# check no longer depends on that value for the "zero lanes observed" case.
$dir6 = Join-Path $scratchRoot 'empty_fallback'
$report6 = Join-Path $scratchRoot 'empty_fallback_report.json'
# derived requirement: VerdictsDir itself does not even exist for this scenario (simulates the
# download step never creating the directory at all, not just an empty one) -- New-VerdictFixture
# is deliberately NOT called here.
$rc6 = Invoke-Aggregate -VerdictsDir $dir6 -FallbackResult 'success' -ReportPath $report6
$pass6 = $false
if ($rc6 -eq 1 -and (Test-Path -LiteralPath $report6)) {
    $reportData6 = Get-Content -Raw -LiteralPath $report6 | ConvertFrom-Json
    $pass6 = ($reportData6.lane_check.missing_lanes.Count -eq $expectedLanes.Count)
}
Write-NdjsonRow ([ordered]@{
    id='self.ci.aggregate_selftest_verdicts.empty_fallback'; pass=$pass6
    desc='aggregate_selftest_verdicts.ps1: zero verdict files with FallbackResult=success still reports has_failures true (all expected lanes missing), independent of the fallback result'
    details=[ordered]@{ exitCode=$rc6 }
})
if (-not $pass6) { $allPass = $false }

Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue

if (-not $allPass) { exit 1 }
exit 0
