# ASCII only. REQ-015 Item 60: migrate a pre-existing .gitattributes still carrying the
# disproven "*.bat eol=crlf"/"*.cmd eol=crlf" rule (written by an older copy of this
# bootstrapper, before the eol=crlf -> -text fix) to "-text", in place. Replaces ONLY lines
# that exactly match one of the two known-stale strings -- every other line, including any
# user hand-edits elsewhere in the file, passes through byte-identical. See
# docs/agent-lessons-learned.md's ".bat files: -text, not eol=crlf" entry for why -text is
# correct and eol=crlf is not. Prints a plain result marker to stdout for the caller to log.
param(
    [Parameter(Mandatory = $true)][string]$Path
)

if (-not (Test-Path -LiteralPath $Path)) {
    Write-Output 'NOOP:missing'
    exit 0
}

$lines = [System.IO.File]::ReadAllLines($Path)
$changed = $false
$out = New-Object System.Collections.Generic.List[string]
foreach ($line in $lines) {
    if ($line -ceq '*.bat eol=crlf') {
        $out.Add('*.bat -text')
        $changed = $true
    } elseif ($line -ceq '*.cmd eol=crlf') {
        $out.Add('*.cmd -text')
        $changed = $true
    } else {
        $out.Add($line)
    }
}

if (-not $changed) {
    Write-Output 'NOOP:no-stale-lines'
    exit 0
}

[System.IO.File]::WriteAllLines($Path, $out.ToArray())
Write-Output 'MIGRATED'
exit 0
