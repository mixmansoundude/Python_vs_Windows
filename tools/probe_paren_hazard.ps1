# ASCII only. CLAUDE.md Active Backlog Item 61 / docs/open-questions.md item 5: does a SAME-LINE,
# self-contained (`(`/`)`) pair nested inside a real cmd.exe `if (...)` block corrupt parsing the
# way a cross-line pair already does -- and if so, is nesting DEPTH or the `>>` file-redirection
# prefix the actual trigger? Static reasoning about this exact hazard class has been wrong three
# separate times already in this repo (see docs/agent-lessons-learned.md's "A literal `(`/`)`
# inside `echo` text..." entry) -- only a genuine cmd.exe run counts as evidence, never reasoning
# alone. This is that evidence-gathering script: dispatched via
# .github/workflows/batch-paren-hazard-probe.yml (workflow_dispatch-only, real Windows runner).
#
# Generates a small matrix of standalone .bat fixtures (nesting depth 1-4, with/without a `>>`
# redirection prefix on the paren-bearing line) plus one POSITIVE-CONTROL fixture using the
# already-CONFIRMED-broken cross-line shape (PR #408/#445), executes each via a real cmd.exe, and
# reports whether the fixture "survived" (printed its own trailing SURVIVED marker, proving
# cmd.exe parsed the whole block correctly) or corrupted (anything else -- a parse error, a
# truncated block, a nonzero exit with no marker). The positive control exists so a clean same-line
# matrix can actually be trusted: if the control does NOT show corruption, something about this
# harness itself is wrong, not cmd.exe.
#
# Run standalone: pwsh -File tools/probe_paren_hazard.ps1
# Self-contained -- writes fixtures to a temp directory, no other repo files needed.

$ErrorActionPreference = 'Continue'
$results = @()
$tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ('paren_probe_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmpDir | Out-Null

function Invoke-Fixture {
    param([string]$Name, [string[]]$Lines)

    $batPath = Join-Path $tmpDir "$Name.bat"
    # CRLF, matching this repo's own .bat convention -- cmd.exe's own parsing is under test, so
    # the fixture must be byte-identical to how a real .bat ships (see docs/agent-lessons-
    # learned.md's ".bat/.cmd files: -text, not eol=crlf" entry for why this repo cares).
    [System.IO.File]::WriteAllText($batPath, (($Lines -join "`r`n") + "`r`n"))

    Push-Location $tmpDir
    try {
        $raw = & cmd /c "$Name.bat" 2>&1
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $output = ($raw | Out-String)
    $survived = $output -match 'SURVIVED'

    [pscustomobject]@{
        Name       = $Name
        ExitCode   = $exitCode
        Survived   = [bool]$survived
        Output     = ($output -replace "`r?`n", ' | ').Trim()
    }
}

# Same-line matrix: nesting depth 1-4 x with/without a `>>` redirection prefix on the
# paren-bearing line. `(exit 3)` mirrors the exact real-world shape that broke in PR #445.
foreach ($depth in 1..4) {
    foreach ($redirected in @($false, $true)) {
        $lines = @('@echo off')
        for ($i = 0; $i -lt $depth; $i++) { $lines += 'if 1==1 (' }
        if ($redirected) {
            $lines += '  >> "out.txt" echo probe text (exit 3); marker_after'
        } else {
            $lines += '  echo probe text (exit 3); marker_after'
        }
        for ($i = 0; $i -lt $depth; $i++) { $lines += ')' }
        $lines += 'echo SURVIVED'

        $redirTag = if ($redirected) { 'redir' } else { 'plain' }
        $results += Invoke-Fixture -Name "depth${depth}_$redirTag" -Lines $lines
    }
}

# Positive control: a CROSS-LINE pair at depth 4, no redirection -- the exact shape already
# CONFIRMED to corrupt cmd.exe's parser (PR #408, PR #445). Proves this harness can actually
# detect real corruption, not just that nothing in the same-line matrix above happens to break.
$controlLines = @(
    '@echo off',
    'if 1==1 (',
    'if 1==1 (',
    'if 1==1 (',
    'if 1==1 (',
    '  echo probe text (',
    '  echo continued text ) marker_after',
    ')',
    ')',
    ')',
    ')',
    'echo SURVIVED'
)
$results += Invoke-Fixture -Name 'control_crossline_depth4' -Lines $controlLines

$results | Format-Table -Property Name, ExitCode, Survived, Output -AutoSize | Out-String -Width 220 | Write-Host

$broken = @($results | Where-Object { -not $_.Survived })
Write-Host ''
if ($broken.Count -gt 0) {
    Write-Host 'CORRUPTED (did not print SURVIVED):'
    foreach ($r in $broken) {
        Write-Host "  $($r.Name): exit=$($r.ExitCode) output=$($r.Output)"
    }
} else {
    Write-Host 'All same-line fixtures survived.'
}

$control = $results | Where-Object { $_.Name -eq 'control_crossline_depth4' }
if ($control -and $control.Survived) {
    Write-Host ''
    Write-Host 'WARNING: the positive control did NOT show corruption -- treat every other result'
    Write-Host 'above as unproven until this harness itself is fixed (the control is expected to'
    Write-Host 'be in the CORRUPTED list; if it is not, something about this script or this'
    Write-Host 'runner differs from the conditions that produced the original PR #408/#445 breakage.'
}

Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue

if ($env:GITHUB_STEP_SUMMARY) {
    $summary = $results | ForEach-Object {
        "| $($_.Name) | $($_.ExitCode) | $($_.Survived) | $($_.Output) |"
    }
    @(
        '### Paren-nesting hazard probe results',
        '',
        '| Fixture | ExitCode | Survived | Output (pipe-joined lines) |',
        '|---|---|---|---|'
    ) + $summary | Out-File -FilePath $env:GITHUB_STEP_SUMMARY -Append -Encoding utf8
}
