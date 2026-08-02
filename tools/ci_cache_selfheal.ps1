<#
ASCII only. Validates a restored Miniconda cache directory and self-heals a corrupted
restore-keys PREFIX match (the common case -- run_setup.bat hashes into the cache key, which
changes on nearly every PR) by deleting the stale directory so the caller falls through to a
real fresh install + fresh save. An EXACT primary-key hit that's corrupted cannot be
self-healed this way (a GitHub Actions cache blob is immutable once saved under a key) --
that narrower case still just reports "skip this run." See docs/agent-closed-backlog.md's
Item 19 entry for the full incident/mechanism history this closes.

Extracted out of .github/workflows/batch-check.yml's "Validate restored conda binary" step so
it can be exercised deterministically by tests/test_ci_cache_selfheal.ps1 on every CI run --
the ambient `cache` lane only reaches this logic when GitHub's own cache happens to be
organically corrupted, which is rare and unpredictable, and that lane is intentionally
non-gating besides (see CLAUDE.md's CI lane gating maturity notes).

Exit codes:
  0 = healthy -- conda.bat present and "conda info" succeeded, or no conda.bat restored at
      all (a genuine cache miss; nothing to heal, fresh install proceeds normally either way)
  1 = corrupted on an EXACT key hit -- cannot self-heal; caller should skip this run
  2 = corrupted on a PREFIX match -- self-healed (stale directory deleted)
  3 = corrupted on a PREFIX match -- self-heal FAILED (directory could not be fully cleared,
      e.g. an AV/indexer file lock); caller should fall back to skip-this-run
#>
param(
    [Parameter(Mandatory = $true)][string]$CondaDir,
    [switch]$ExactHit
)

$condaMain = Join-Path $CondaDir 'condabin\conda.bat'
$condaAlt  = Join-Path $CondaDir 'Scripts\conda.bat'
$condaBat = if (Test-Path -LiteralPath $condaMain) { $condaMain } elseif (Test-Path -LiteralPath $condaAlt) { $condaAlt } else { $null }

if ($null -eq $condaBat) {
    Write-Host "No conda binary found at $CondaDir; nothing to validate."
    exit 0
}

$output = & cmd /c "`"$condaBat`" info" 2>&1
if ($LASTEXITCODE -eq 0) {
    Write-Host "Conda health OK: $output"
    exit 0
}

if ($ExactHit) {
    # derived requirement: an EXACT primary-key hit that's corrupted can never be replaced in
    # place (a GitHub Actions cache entry's blob is immutable once saved under a key) -- fully
    # closing this needs an explicit cache-deletion API call, a smaller follow-on not
    # implemented here. Keep the original skip-this-run behavior for this narrow case.
    Write-Host "::warning::Conda binary health check failed (exit=$LASTEXITCODE) on an EXACT cache-key hit; cache corrupted, skipping fast-path tests this run."
    exit 1
}

# derived requirement: a restore-keys PREFIX match is not a guarantee the restored blob is
# still valid. Treat it like a genuine cache miss instead of a hard skip -- delete the stale
# directory and let the caller fall through to a real fresh install and a real fresh save
# under the current key, breaking the self-perpetuating-corruption loop (Item 19).
Write-Host "::warning::Conda binary health check failed (exit=$LASTEXITCODE) on a restore-keys prefix match; deleting stale cache directory and proceeding as a fresh install."
Remove-Item -LiteralPath $CondaDir -Recurse -Force -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $CondaDir) {
    # derived requirement: same AV/indexer file-lock hazard class already documented for
    # :try_embed_fallback's own directory swap in run_setup.bat -- if deletion didn't fully
    # succeed, do not proceed into an uncertain half-deleted state; fall back to the original,
    # safe skip-this-run behavior instead.
    Write-Host "::warning::Stale cache directory could not be fully removed (possible file lock); falling back to skip-this-run."
    exit 3
}

Write-Host "Stale cache directory removed; fresh install will proceed normally."
exit 2
