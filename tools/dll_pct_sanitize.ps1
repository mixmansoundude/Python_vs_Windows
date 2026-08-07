# Strips %/^ from one or more env var values, for :log's UNQUOTED-echo safety (see
# docs/agent-lessons-learned.md's ":log echoes UNQUOTED" entry). A literal % on the same cmd.exe
# logical line as a real %VAR% reference (e.g. %LOG%) can silently corrupt cmd.exe's own
# left-to-right %-pairing scan -- this exact hazard broke the old inline `-Command` version of
# this logic THREE times in real CI before landing here. Emitted as a real .ps1 file specifically
# so this text is NEVER parsed by cmd.exe's own tokenizer -- only the outer `-File "path" arg...`
# line is, and plain argv has no %/^-pairing hazard. &/|/</> are handled by the CALLER via plain
# cmd.exe :search=replace substitution before this runs (that part was never broken).
#
# Usage: powershell -File dll_pct_sanitize.ps1 <envVarName> <outFile> [<envVarName> <outFile> ...]
# For each pair, reads [Environment]::GetEnvironmentVariable(name), strips %/^, and writes the
# result (no trailing newline) to outFile -- read back by the caller via a plain
# "for /f "usebackq delims=" %%X in (outFile) do set".
#
# Canonical source for the HP_DLL_PCT_SANITIZE payload in run_setup.bat. After editing:
# `python tools/sync_payload.py HP_DLL_PCT_SANITIZE tools/dll_pct_sanitize.ps1`.
# tests/test_dll_pct_sanitize.py asserts the embedded payload matches (CRLF/LF normalized).
$pct = [char]37
for ($i = 0; $i -lt $args.Count; $i += 2) {
    $name = $args[$i]
    $outPath = $args[$i + 1]
    $v = [Environment]::GetEnvironmentVariable($name)
    if (-not $v) { $v = '' }
    $v = $v -replace $pct, '_' -replace '\^', '_'
    [System.IO.File]::WriteAllText($outPath, $v, [System.Text.Encoding]::ASCII)
}
