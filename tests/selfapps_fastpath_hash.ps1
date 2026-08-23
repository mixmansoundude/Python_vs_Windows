# ASCII only
# selfapps_fastpath_hash.ps1 - regression guard for CLAUDE.md Active Backlog Item 39: the
# EXE fast path's freshness check must detect a genuine content change even when the
# changed file's mtime is backdated below the built EXE's own mtime -- the exact failure
# mode a timestamp-preserving delivery method (a ZIP, xcopy, robocopy) produces. Before this
# fix, freshness was mtime-only over *.py files, so this scenario silently reused the stale
# EXE with no signal to the user (see CLAUDE.md's Item 39 "Realistic scenario").
#
# Run 1: builds the EXE from entry.py printing FASTPATH_TOKEN_V1.
# Run 2: entry.py is rewritten to print FASTPATH_TOKEN_V2 instead, but its mtime is set to a
#        date well BEFORE dist\<env>.exe's own mtime (simulating a delivery method that
#        preserves the file's original authored timestamp). The OLD mtime-only check would
#        have wrongly reused the stale V1 EXE here; the new content-hash check
#        (tools/fast_check.ps1) must detect the change regardless of mtime and rebuild.
# Assert: run 2's captured EXE stdout (~run.out.txt, written by both the fast-path-reuse
# launch and the fresh-build smokerun -- see docs/agent-interconnect.md's "EXE fast path"
# section) shows FASTPATH_TOKEN_V2, not V1 -- direct evidence the NEW content actually ran,
# not just that some log line happened to say "rebuilding". Also asserts the "Fast path:
# reusing" log line is ABSENT for run 2, confirming a genuine rebuild occurred rather than
# the new token coincidentally reaching the old EXE some other way.
#
# Lane: uv, non-gating for its first landing -- the isolated tools/fast_check.ps1 script is
# already verified via real pwsh (tests/test_fast_check.py), but this is the first time the
# full :try_fast_exe -> :run_entry_smoke -> :success -> :write_fast_hash cycle is exercised
# end-to-end on real Windows CI. Promote once proven stable across several real runs,
# matching this repo's established graduation pattern (CLAUDE.md's "CI lane gating
# maturity" periodic check).
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
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

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.fastpath.hash.backdated_mtime'
        req     = 'REQ-018'
        pass    = $true
        desc    = 'EXE fast path content-hash freshness (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.fastpath.hash.backdated_mtime'
        req     = 'REQ-018'
        pass    = $false
        desc    = 'EXE fast path content-hash freshness: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_fastpath_hash'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
print("FASTPATH_TOKEN_V1")
'@ -Encoding ASCII

$prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'

function Invoke-Bootstrap {
    param([string]$LogName)
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $LogName 2>&1"
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

try {
    # Run 1: fresh build, entry.py prints V1.
    $run1Exit = Invoke-Bootstrap '~fastpath_hash_run1.log'

    # derived requirement (CodeRabbit review, PR #460): without this, a completely broken
    # :write_fast_hash (e.g. HP_FRESH_BUILD_OK never getting set) would be indistinguishable
    # from a working one -- a MISSING hash file also forces run 2 to rebuild (the safe
    # default), so every assertion below would still pass even if the write side never fired
    # at all. Assert the write side was genuinely exercised, not just coincidentally masked.
    $hashFileAfterRun1 = Join-Path $workDir '~fast_check.hash.txt'
    $hashWrittenAfterRun1 = Test-Path -LiteralPath $hashFileAfterRun1

    # Rewrite entry.py to print V2, then backdate its mtime well before dist\<env>.exe's own
    # mtime -- simulating a ZIP/xcopy/robocopy delivery that preserves the original
    # authored timestamp instead of stamping "now" on extraction.
    $entryPath = Join-Path $workDir 'entry.py'
    Set-Content -Path $entryPath -Value @'
print("FASTPATH_TOKEN_V2")
'@ -Encoding ASCII
    $backdated = Get-Date -Year 2001 -Month 9 -Day 9
    (Get-Item -LiteralPath $entryPath).LastWriteTime = $backdated
    (Get-Item -LiteralPath $entryPath).LastWriteTimeUtc = $backdated.ToUniversalTime()

    # Run 2: sources genuinely changed (V2), but entry.py's mtime lies about it.
    $run2Exit = Invoke-Bootstrap '~fastpath_hash_run2.log'
} finally {
    if ($null -eq $prev) {
        Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PIPREQS = $prev
    }
}

$run2LogPath  = Join-Path $workDir '~fastpath_hash_run2.log'
$run2SetupLog = Join-Path $workDir '~setup.log'
$run2Lines = if (Test-Path $run2LogPath)  { Get-Content -LiteralPath $run2LogPath  -Encoding ASCII } else { @() }
$run2Setup = if (Test-Path $run2SetupLog) { Get-Content -LiteralPath $run2SetupLog -Raw -Encoding ASCII } else { '' }
$run2Combined = ($run2Lines -join "`n") + "`n" + $run2Setup

$runOutPath = Join-Path $workDir '~run.out.txt'
$runOutText = if (Test-Path $runOutPath) { Get-Content -LiteralPath $runOutPath -Raw -Encoding ASCII } else { '' }

$tokenV2Seen  = $runOutText -match 'FASTPATH_TOKEN_V2'
$tokenV1Seen  = $runOutText -match 'FASTPATH_TOKEN_V1'
$fastPathReusedRun2 = $run2Combined -match [regex]::Escape('Fast path: reusing')

# Genuine rebuild detected: run 2 shows the NEW token, not the old one, did not take the
# "reusing" fast path, AND run 1 genuinely exercised the write side (not just coincidentally
# masked by the missing-hash-file safe default).
$pass = ($run1Exit -eq 0) -and ($run2Exit -eq 0) -and $hashWrittenAfterRun1 -and $tokenV2Seen -and (-not $tokenV1Seen) -and (-not $fastPathReusedRun2)

Write-NdjsonRow ([ordered]@{
    id      = 'self.fastpath.hash.backdated_mtime'
    req     = 'REQ-018'
    pass    = $pass
    desc    = 'EXE fast path content-hash freshness detects a genuine change even when the changed file mtime is backdated below the EXE'
    details = [ordered]@{
        run1Exit            = $run1Exit
        run2Exit            = $run2Exit
        hashWrittenAfterRun1 = $hashWrittenAfterRun1
        tokenV2Seen         = $tokenV2Seen
        tokenV1Seen         = $tokenV1Seen
        fastPathReusedRun2  = $fastPathReusedRun2
        run2Log             = '~fastpath_hash_run2.log'
    }
})

if (-not $pass) { exit 1 }
exit 0
