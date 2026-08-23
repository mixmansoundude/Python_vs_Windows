# ASCII only. CLAUDE.md Active Backlog Item 39: the EXE fast path's freshness check was
# mtime-only over *.py files, so (a) a timestamp-preserving delivery method (a ZIP, xcopy,
# robocopy) could carry a genuinely changed file whose mtime still predates the built EXE,
# silently reusing stale logic with no signal to the user, and (b) a requirements.txt/
# pyproject.toml/runtime.txt change was invisible to the scan entirely, mtime or not. Fixes
# both: freshness is now a content-hash comparison (never fooled by a preserved/backdated
# mtime) over the SAME *.py file set already scanned, extended to include those three
# dependency files.
#
# Two modes, selected by the second positional argument (default 'check'):
#   check  (run from :try_fast_exe): print 'fresh' iff a stored hash exists AND matches the
#          hash of the CURRENT source set. Prints nothing (falls through to a rebuild) on any
#          mismatch, or when no stored hash exists yet (e.g. the first run under this fix,
#          or dist\<env>.exe was built by an older run_setup.bat with no hash file at all) --
#          a safe, one-time-cost default that never mis-reports staleness as freshness.
#   write  (run from :success, only when a fresh build attempt just happened -- see the
#          call site's own HP_FASTPATH_USED gate for why the fast-reuse case skips this and
#          avoids a redundant second hash pass): unconditionally (re)write the hash of the
#          CURRENT source set. Always run from the app root as CWD (both call sites already
#          guarantee this), so relative paths captured via Resolve-Path -Relative match
#          between the write and a later check.
#
# Uses [System.Security.Cryptography.SHA256] directly, not Get-FileHash -- see
# docs/agent-lessons-learned.md's "Prefer raw .NET types over Utility-module cmdlets" entry:
# Microsoft.PowerShell.Utility is not guaranteed to auto-load in the for/f-backtick and
# -File invocation shapes this repo's embedded helpers run under on real Windows PowerShell
# 5.1, and this class of gap is invisible to local pwsh (Linux, PowerShell 7) testing.
#
# This is the canonical source for the HP_FAST_CHECK base64 payload embedded in
# run_setup.bat. After editing, re-sync via:
#   python tools/sync_payload.py HP_FAST_CHECK tools/fast_check.ps1
# tests/test_fast_check.py asserts the embedded payload matches this file byte-for-byte
# (after CRLF/LF normalization, since this file is eol=crlf but was authored on LF).

$exe = $args[0]
if (-not $exe) { $exe = $env:HP_FAST_EXE }
$mode = $args[1]
if (-not $mode) { $mode = 'check' }

$hashFile = '~fast_check.hash.txt'
$infraPattern = '(?i)(^|[/\\])(\.git|\.github|dist|\.venv|\.uv_env|__pycache__|\.conda)([/\\]|$)'
$py = @(Get-ChildItem -Recurse -File -Filter '*.py' | Where-Object { $_.FullName -notmatch $infraPattern -and $_.Name -notlike '~*.py' })
$depNames = @('requirements.txt', 'pyproject.toml', 'runtime.txt')
$deps = @($depNames | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | ForEach-Object { Get-Item -LiteralPath $_ })
$sources = @($py) + @($deps)

if (-not $sources) {
  if ($mode -eq 'check') { exit 1 } else { exit 0 }
}

$sha = [System.Security.Cryptography.SHA256]::Create()
$lines = foreach ($f in ($sources | Sort-Object -Property FullName)) {
  $relPath = Resolve-Path -LiteralPath $f.FullName -Relative
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  $hashBytes = $sha.ComputeHash($bytes)
  $hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
  "$relPath|$hex"
}
$combined = [string]::Join("`n", $lines)
$combinedBytes = [System.Text.Encoding]::UTF8.GetBytes($combined)
$digestBytes = $sha.ComputeHash($combinedBytes)
$digest = -join ($digestBytes | ForEach-Object { $_.ToString('x2') })

if ($mode -eq 'write') {
  [System.IO.File]::WriteAllText($hashFile, $digest)
  exit 0
}

if (-not (Test-Path -LiteralPath $hashFile)) { exit 1 }
if (-not $exe) { exit 1 }
if (-not (Test-Path -LiteralPath $exe)) { exit 1 }
$stored = [System.IO.File]::ReadAllText($hashFile).Trim()
if ($stored -eq $digest) { 'fresh' }
