# ASCII only
# test_ci_cache_selfheal.ps1 - deterministic regression test for tools/ci_cache_selfheal.ps1
# (the cache-lane self-heal logic, Item 19 follow-on -- docs/agent-closed-backlog.md).
#
# Unlike the ambient `cache` CI lane, which only exercises the corrupted-and-heal path when
# GitHub's own cache happens to be organically corrupted (rare, unpredictable) and is entirely
# swallowed by that lane's job-level continue-on-error either way (see batch-check.yml's CI lane
# gating maturity notes), this test exercises every branch of ci_cache_selfheal.ps1 directly
# against a scratch temp directory, on every single CI run, with no dependency on real cache
# state. Wired into the `real` lane (a GATING lane, not in the job-level continue-on-error list)
# so a regression in the self-heal logic actually fails CI, not just logs a warning nobody sees.
#
# Windows-only: the script under test shells out to `conda.bat` via cmd.exe (a Windows batch
# wrapper) and the locked-directory scenario depends on Windows file-locking semantics, neither
# of which is meaningfully reproducible on Linux.
#
# Four scenarios, all against fake `condabin\conda.bat` stand-ins (never a real Miniconda
# install -- this test is pure logic, no conda/network dependency):
#   healthy              - conda.bat exits 0 -> exit code 0, directory untouched.
#   prefix_healed         - conda.bat exits 1, PREFIX match -> exit code 2, directory deleted
#                            (the ordinary self-heal path).
#   exact_hit_corrupted   - conda.bat exits 1, EXACT hit -> exit code 1, directory left in place
#                            (documented, accepted -- cannot self-heal an exact-key blob in place).
#   prefix_heal_failed     - conda.bat exits 1, PREFIX match, but a held file handle blocks
#                            deletion (simulates an AV/indexer lock) -> exit code 3, directory
#                            still present. This is the scenario that would have silently
#                            regressed back into Item 19's original "always corrupted, never
#                            self-heals" trap if it went undetected.
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$script = Join-Path $repo 'tools\ci_cache_selfheal.ps1'
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

if (-not $IsWindows) {
    Write-NdjsonRow ([ordered]@{
        id='self.ci.cache_selfheal'; req='N/A'; pass=$true
        desc='ci_cache_selfheal.ps1 regression test (skipped on non-Windows: shells out to conda.bat via cmd.exe, and the locked-directory scenario needs Windows file-locking semantics)'
        details=[ordered]@{ skip=$true; reason='non-windows-host' }
    })
    exit 0
}

function New-FakeCondaDir {
    param([string]$Dir, [int]$ExitCode)
    if (Test-Path -LiteralPath $Dir) { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Force -Path (Join-Path $Dir 'condabin') | Out-Null
    $bat = Join-Path $Dir 'condabin\conda.bat'
    Set-Content -LiteralPath $bat -Value "@echo off`r`nexit /b $ExitCode`r`n" -Encoding Ascii
}

$scratchRoot = Join-Path $here '~selftest_cache_selfheal'
if (Test-Path -LiteralPath $scratchRoot) { Remove-Item -LiteralPath $scratchRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null

$allPass = $true

# --- Scenario 1: healthy ---
$dir1 = Join-Path $scratchRoot 'healthy'
New-FakeCondaDir -Dir $dir1 -ExitCode 0
& $script -CondaDir $dir1
$rc1 = $LASTEXITCODE
$pass1 = ($rc1 -eq 0) -and (Test-Path -LiteralPath $dir1)
Write-NdjsonRow ([ordered]@{
    id='self.ci.cache_selfheal.healthy'; pass=$pass1
    desc='ci_cache_selfheal.ps1: a healthy conda.bat exits 0 and is left untouched'
    details=[ordered]@{ exitCode=$rc1; dirStillExists=(Test-Path -LiteralPath $dir1) }
})
if (-not $pass1) { $allPass = $false }

# --- Scenario 2: prefix match, corrupted, self-heals ---
$dir2 = Join-Path $scratchRoot 'prefix_healed'
New-FakeCondaDir -Dir $dir2 -ExitCode 1
& $script -CondaDir $dir2
$rc2 = $LASTEXITCODE
$pass2 = ($rc2 -eq 2) -and (-not (Test-Path -LiteralPath $dir2))
Write-NdjsonRow ([ordered]@{
    id='self.ci.cache_selfheal.prefix_healed'; pass=$pass2
    desc='ci_cache_selfheal.ps1: a corrupted conda.bat on a restore-keys prefix match self-heals (stale dir deleted)'
    details=[ordered]@{ exitCode=$rc2; dirRemoved=(-not (Test-Path -LiteralPath $dir2)) }
})
if (-not $pass2) { $allPass = $false }

# --- Scenario 3: exact hit, corrupted, cannot self-heal ---
$dir3 = Join-Path $scratchRoot 'exact_hit'
New-FakeCondaDir -Dir $dir3 -ExitCode 1
& $script -CondaDir $dir3 -ExactHit
$rc3 = $LASTEXITCODE
$pass3 = ($rc3 -eq 1) -and (Test-Path -LiteralPath $dir3)
Write-NdjsonRow ([ordered]@{
    id='self.ci.cache_selfheal.exact_hit_corrupted'; pass=$pass3
    desc='ci_cache_selfheal.ps1: a corrupted conda.bat on an EXACT key hit cannot self-heal; directory is left in place (documented, accepted gap)'
    details=[ordered]@{ exitCode=$rc3; dirStillExists=(Test-Path -LiteralPath $dir3) }
})
if (-not $pass3) { $allPass = $false }

# --- Scenario 4: prefix match, corrupted, self-heal FAILS (locked directory) ---
# derived requirement: this is the specific case tools/ci_cache_selfheal.ps1's exit code 3
# exists for -- if a future edit ever silently swallows a Remove-Item failure and reports exit
# code 2 (healed) instead, this is the assertion that catches it.
$dir4 = Join-Path $scratchRoot 'prefix_heal_failed'
New-FakeCondaDir -Dir $dir4 -ExitCode 1
$lockedFile = Join-Path $dir4 'locked.txt'
Set-Content -LiteralPath $lockedFile -Value 'lock' -Encoding Ascii
$handle = [System.IO.File]::Open($lockedFile, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
try {
    & $script -CondaDir $dir4
    $rc4 = $LASTEXITCODE
} finally {
    $handle.Close()
}
$pass4 = ($rc4 -eq 3) -and (Test-Path -LiteralPath $dir4)
Write-NdjsonRow ([ordered]@{
    id='self.ci.cache_selfheal.prefix_heal_failed'; pass=$pass4
    desc='ci_cache_selfheal.ps1: a locked file prevents full directory removal; self-heal correctly reports failure (exit 3) instead of silently proceeding'
    details=[ordered]@{ exitCode=$rc4; dirStillExists=(Test-Path -LiteralPath $dir4) }
})
if (-not $pass4) { $allPass = $false }

Remove-Item -LiteralPath $scratchRoot -Recurse -Force -ErrorAction SilentlyContinue

if (-not $allPass) { exit 1 }
exit 0
