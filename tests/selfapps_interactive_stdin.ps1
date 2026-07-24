# ASCII only
# selfapps_interactive_stdin.ps1 - closes the remaining gap in
# docs/plan-cli-interactive-verification.md's live-echo redesign: requirement 1 (live tee) is
# shipped and unit-tested (tests/test_failfast_probe.py, tests/test_exe_smokerun.py) via direct
# pwsh subprocess calls, but nothing had exercised the FULL real-Windows nesting a double-clicked
# run_setup.bat actually uses (cmd.exe -> :run_exe_smokerun -> the emitted ~exe_smokerun.ps1
# helper -> the built EXE) with genuine interactive stdin flowing all the way through. This test
# builds a real PyInstaller EXE from a multi-round input()-driven stub app (the owner's actual
# target program shape: no launch args, ask setup questions, loop on stdin until a quit command)
# and pipes a scripted sequence of answers into cmd.exe's OWN stdin -- since nothing in this
# chain (:run_exe_smokerun, ~exe_smokerun.ps1, the frozen EXE's own Process launch) redirects
# stdin away, it should propagate unbroken from cmd.exe's inherited stdin down to the EXE's
# input() calls.
#
# This is provider-agnostic by construction: :run_exe_smokerun/~exe_smokerun.ps1 run identically
# regardless of which REQ-009 tier (uv/conda/embed/venv/system) built the environment -- once
# dist\<env>.exe exists, verification does not care how it got there. One passing run in one
# lane is therefore representative of the mechanism working across all lanes; a per-provider
# repeat of this exact test would not exercise any different code path. Placed in the uv lane
# (non-gating) matching this repo's established pattern for new/risky test additions -- promote
# once proven stable across several real runs (see CLAUDE.md's "CI lane gating maturity" note).
#
# Does NOT prove a live human's own typing timing (impossible to automate) -- it proves the
# PLUMBING (the full process-launch chain) does not silently drop or reorder stdin/stdout, which
# is the part that was genuinely unconfirmed. See docs/plan-cli-interactive-verification.md
# requirement 2 for what remains open after this.
#
# Lane: uv only, non-gating.
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

if (-not $IsWindows) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.interactive.stdin.roundtrip'
        req     = 'REQ-018'
        pass    = $true
        desc    = 'Interactive stdin round-trip test skipped on non-Windows host'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.interactive.stdin.roundtrip'
        req     = 'REQ-018'
        pass    = $false
        desc    = 'Interactive stdin round-trip test: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$roundtripPass = $false
$details = [ordered]@{}
try {
    $wd = Join-Path $here '~selftest_interactive_stdin'
    if (Test-Path $wd) { Remove-Item -Recurse -Force $wd }
    New-Item -ItemType Directory -Force -Path $wd | Out-Null
    Copy-Item -Path $batchPath -Destination $wd -Force

    # The owner's actual target shape: no launch args, setup questions via input(), a loop that
    # exits on a quit command. Mirrors tests/test_failfast_probe.py's INTERACTIVE_SCRIPT so the
    # local unit test and this real-Windows test exercise the same conversation shape.
    Set-Content -Path (Join-Path $wd 'entry.py') -Value @'
name = input("Enter your name: ")
print("Hello, " + name + "!")
while True:
    cmd = input("Type ping or exit: ")
    if cmd == "exit":
        print("Goodbye!")
        break
    elif cmd == "ping":
        print("pong")
    else:
        print("unknown command: " + cmd)
'@ -Encoding ASCII

    $answersPath = Join-Path $wd '~answers.txt'
    # No trailing newline quirks: three lines, LF-terminated, matches Python's input() one
    # line-per-call contract.
    [System.IO.File]::WriteAllText($answersPath, "Alice`nping`nexit`n", [System.Text.Encoding]::ASCII)

    $savedSkipPipreqs = $env:HP_SKIP_PIPREQS
    $savedLane = $env:HP_CI_LANE
    $env:HP_SKIP_PIPREQS = '1'
    $env:HP_CI_LANE = 'test'

    $logName = '~interactive_bootstrap.log'
    Push-Location -LiteralPath $wd
    try {
        # Redirects cmd.exe's OWN stdin from the answers file. Nothing between here and the
        # built EXE's own input() calls (:run_exe_smokerun, ~exe_smokerun.ps1) redirects stdin
        # away, so this exercises the real inheritance chain, not a synthetic shortcut.
        cmd /c "call run_setup.bat < `"$answersPath`" > $logName 2>&1"
        $bootstrapExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($null -eq $savedSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $savedSkipPipreqs }
    if ($null -eq $savedLane) { Remove-Item Env:HP_CI_LANE -ErrorAction SilentlyContinue } else { $env:HP_CI_LANE = $savedLane }

    $logPath = Join-Path $wd $logName
    $logLines = if (Test-Path $logPath) { Get-Content -LiteralPath $logPath -Encoding ASCII } else { @() }
    $logText = $logLines -join "`n"

    $statusPath = Join-Path $wd '~bootstrap.status.json'
    $statusState = $null
    if (Test-Path $statusPath) {
        try { $statusState = (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).state } catch { $statusState = $null }
    }
    $exeCandidates = @(Get-ChildItem -Path (Join-Path $wd 'dist') -Filter '*.exe' -ErrorAction SilentlyContinue)
    $capturedOutPath = Join-Path $wd '~run.out.txt'
    $capturedOut = if (Test-Path $capturedOutPath) { Get-Content -LiteralPath $capturedOutPath -Raw -Encoding ASCII } else { '' }

    # Ordering, not just presence -- proves each answer was consumed by the RIGHT prompt in the
    # RIGHT round, not just that all expected substrings happen to appear somewhere in the log.
    $iName = $logText.IndexOf('Enter your name:')
    $iHello = $logText.IndexOf('Hello, Alice!')
    $iPrompt2 = $logText.IndexOf('Type ping or exit:')
    $iPong = $logText.IndexOf('pong')
    $iBye = $logText.IndexOf('Goodbye!')
    $orderedCorrectly = ($iName -ge 0) -and ($iHello -gt $iName) -and ($iPrompt2 -gt $iHello) -and ($iPong -gt $iPrompt2) -and ($iBye -gt $iPong)

    $exeBuilt = $exeCandidates.Count -gt 0
    $capturedFileMatches = ($capturedOut -match [regex]::Escape('Hello, Alice!')) -and ($capturedOut -match [regex]::Escape('pong')) -and ($capturedOut -match [regex]::Escape('Goodbye!'))
    $bootstrapOk = ($bootstrapExit -eq 0) -and ($statusState -eq 'ok')

    $roundtripPass = $orderedCorrectly -and $exeBuilt -and $capturedFileMatches -and $bootstrapOk
    $details = [ordered]@{
        bootstrapExit       = $bootstrapExit
        statusState         = $statusState
        exeBuilt            = $exeBuilt
        orderedCorrectly    = $orderedCorrectly
        capturedFileMatches = $capturedFileMatches
        log                 = $logName
    }
} catch {
    $details = [ordered]@{ error = $_.Exception.Message }
}

Write-NdjsonRow ([ordered]@{
    id      = 'self.interactive.stdin.roundtrip'
    req     = 'REQ-018'
    pass    = $roundtripPass
    desc    = 'A multi-round input()-driven program, built into a real EXE, receives piped stdin answers correctly through the full cmd.exe -> :run_exe_smokerun -> ~exe_smokerun.ps1 -> EXE chain, in order, and the bootstrap reports state=ok'
    details = $details
})

if (-not $roundtripPass) { exit 1 }
exit 0
