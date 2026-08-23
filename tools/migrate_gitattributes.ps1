# ASCII only. REQ-015 Item 60: migrate a pre-existing .gitattributes still carrying the
# disproven "*.bat eol=crlf"/"*.cmd eol=crlf" rule (written by an older copy of this
# bootstrapper, before the eol=crlf -> -text fix) to "-text", in place. Replaces ONLY the
# TEXT of lines that exactly match one of the two known-stale strings -- every other line's
# content, AND every line terminator in the file (including the terminators immediately
# around the two replaced lines), pass through byte-identical. See
# docs/agent-lessons-learned.md's ".bat files: -text, not eol=crlf" entry for why -text is
# correct and eol=crlf is not. Prints a plain result marker to stdout for the caller to log.
#
# derived requirement (CodeRabbit review, PR #455): an earlier draft used
# [System.IO.File]::ReadAllLines/WriteAllLines, which strips every line's own terminator and
# reimposes a single uniform one (Environment.NewLine -- CRLF on real Windows, where this
# script actually runs) on write. That would have silently converted an LF-only
# .gitattributes' ENTIRE content to CRLF even though only two lines were ever meant to
# change -- invisible to local testing on a Linux sandbox, where Environment.NewLine is LF,
# so the earlier version's own local verification could not have caught this. Fixed by
# working on the raw text with a scoped regex replace (touches only the two target lines'
# own text, using lookaround to recognize line boundaries without consuming or altering the
# terminators themselves) instead of ever splitting into / rejoining from a lines array.
param(
    [Parameter(Mandatory = $true)][string]$Path
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output 'NOOP:missing'
    exit 0
}

# derived requirement (real CI failure on PR #455's first run, on genuine Windows PowerShell
# 5.1 -- root cause not identified, since only Linux pwsh 7 is available for local
# verification): the whole body below is now wrapped in try/catch, emitting a single-line
# "ERROR:<type>: <message>" marker instead of letting a raw, possibly multi-line terminating
# error reach the caller unexplained. run_setup.bat's own :merge_git_config caller already
# treats any non-MIGRATED/NOOP result as a non-fatal WARN (this feature never gates the lane,
# see CLAUDE.md's Item 60 entry) and now types this script's raw stdout/stderr to both console
# and %LOG% on that branch -- collapsing embedded newlines here keeps that dump to one line.
try {
    # derived requirement: preserve the file's own encoding exactly too, not just line
    # endings. StreamReader with detectEncodingFromByteOrderMarks=true auto-detects a real
    # BOM (UTF8/UTF16LE/UTF16BE/UTF32) and reports it via CurrentEncoding; when no BOM is
    # present it falls back to the supplied default -- UTF8 WITHOUT a BOM (matching what this
    # bootstrapper's own plain-ASCII `>> echo` writes produce), not
    # [System.Text.Encoding]::UTF8's own static instance, which has BOM emission enabled and
    # would have added a BOM that was never there.
    #
    # derived requirement (CodeRabbit, PR #456): throwOnInvalidBytes=$true, not implicit
    # $false. A no-BOM file with genuinely non-UTF8 bytes would otherwise decode SILENTLY
    # (U+FFFD per bad byte, confirmed, no exception) and get rewritten as corrupted UTF8 --
    # throwing routes it into the try/catch below instead, a safe ERROR: marker, untouched file.
    $noBomUtf8 = New-Object System.Text.UTF8Encoding($false, $true)
    $reader = New-Object System.IO.StreamReader($Path, $noBomUtf8, $true)
    try {
        $text = $reader.ReadToEnd()
        $encoding = $reader.CurrentEncoding
    } finally {
        $reader.Close()
    }

    $changed = $false

    # (?<=\A|\r\n|\n) / (?=\r\n|\n|\z): the stale text must be a genuine whole line --
    # preceded by the start of the file or a line terminator, and followed by a line
    # terminator or the end of the file -- without the match itself consuming any terminator,
    # so whatever mix of CRLF/LF/no-trailing-newline the file already has is left completely
    # alone. A partial match (the stale text with something else appended on the same line)
    # never satisfies the lookahead, so it is correctly never touched -- the safety property
    # protecting a user's own hand-edited content. \A alone (not also a bare
    # alternative) is deliberate (CodeRabbit review, PR #455): StreamReader's own
    # BOM-stripping-on-read already consumes a genuine leading BOM as encoding metadata
    # before $text is ever set, so $text never actually starts with U+FEFF here -- \A already
    # covers the real "first line" case with no extra alternative needed. A bare
    # alternative would instead be a genuine false-positive hazard: it is not itself anchored
    # to the start of the file, so a line with its OWN prefix text followed by a literal
    # embedded U+FEFF character (e.g. "user <BOM>*.bat eol=crlf") would wrongly satisfy the
    # lookbehind and get rewritten, even though that is not an exact whole-line match at all.
    $new = [regex]::Replace($text, '(?<=\A|\r\n|\n)\*\.bat eol=crlf(?=\r\n|\n|\z)', '*.bat -text')
    if ($new -ne $text) { $changed = $true; $text = $new }
    $new = [regex]::Replace($text, '(?<=\A|\r\n|\n)\*\.cmd eol=crlf(?=\r\n|\n|\z)', '*.cmd -text')
    if ($new -ne $text) { $changed = $true; $text = $new }

    if (-not $changed) {
        Write-Output 'NOOP:no-stale-lines'
        exit 0
    }

    [System.IO.File]::WriteAllText($Path, $text, $encoding)
    Write-Output 'MIGRATED'
    exit 0
} catch {
    $msg = "$($_.Exception.GetType().FullName): $($_.Exception.Message)" -replace '[\r\n]+', ' '
    Write-Output "ERROR:$msg"
    exit 0
}
