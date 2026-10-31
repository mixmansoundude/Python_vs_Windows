# ASCII only
# selfapps_lastchance.ps1 - CLAUDE.md Item 82 slice 1 (README REQ-018 and REQ-009): the last-chance offer.
#
# After a fresh uv build whose verification run ended with a real non-zero exit, the bootstrapper asks ONE
# untimed question: [W] it actually worked, [C] try again with Miniconda, [N] neither (the default). The
# answer comes from HP_TEST_LASTCHANCE_ANSWER (override), the automated-run guards (HP_CI_LANE and friends
# resolve to neither with no wait), or a real set /p read, which HP_TEST_FORCE_INTERACTIVE_LASTCHANCE forces
# under CI. Every scenario first proves its precondition (the first run really exited with the code the
# fixture gives it) so a fixture that stops reproducing the symptom cannot pass or fail vacuously. HP_NDJSON
# points at a private file per scenario; the bootstrapper's self.lastchance.offer row is read back from it.
#
# Group "real" (lane real, GATING, no download beyond what every uv bootstrap does):
#   self.lastchance.worked        answer W: no cascade, build kept, pass type user_confirmed, row worked
#   self.lastchance.errline       no answer given (automated guard): resolves to neither without waiting, and an
#                                 error line holding < > & | % ^ is shown intact on the console and in the setup
#                                 log, with no stray file left behind
#   self.lastchance.enter         interpreter site (HP_SKIP_EXE_SMOKERUN), the real set /p read answers with a bare
#                                 Enter (default neither), and the error-line helper failing to emit
#                                 (HP_TEST_FORCE_EMIT_FAIL) only costs the "last line" part of the prompt
#   self.lastchance.risk          README REQ-018.2 and REQ-018.25: read from the console text of the worked and errline
#                                 runs, the [C] choice says the program runs once more AND that running it twice could
#                                 cause harm (the text between [C] and [N]); no extra bootstrap
#   self.lastchance.checkpoint_ok the accepted post-execution checkpoint ran the program through the interpreter
#                                 and it exited 0 (an EXE packaging problem, not the environment): no prompt
#   self.lastchance.exit0         a run that exits 0 never gets the prompt and no row is written
# Group "uv" (lane uv, non-gating: a silent EXE is force-stopped, and the cascade downloads Miniconda, so
# both can fail for transient network or provider reasons; flagged in the PR):
#   self.lastchance.timeout       a silent run that the smoke runner force-stops (exit -1) is a window app, not an
#                                 error: no prompt
#   self.lastchance.cascade       answer C: the cascade runs uv to conda and the program passes on conda, with
#                                 the prompt shown exactly once
#   self.lastchance.cascade_again the program fails on conda too: the prompt is not shown a second time
#   self.lastchance.window_yes    Item 82 slice 2: on the conda tier reached through the cascade, a silent program the
#                                 smoke runner really force-stopped raises the question "Did it open and work?";
#                                 an explicit yes is recorded as pass type user_confirmed
#   self.lastchance.window_enter  the same question read from a real set /p, a bare Enter means no and records nothing
#   self.lastchance.window_auto   no override in an automated run: the question is shown, resolves to no, nothing recorded
#   self.lastchance.window_selfexit a program that exits by itself with -1 on the conda tier (the same exit code as a
#                                 force-stop) and a stale kill marker left by the earlier tier: the question is absent,
#                                 because only the smoke runner stopping a silent process may raise it
#
# The group comes from LASTCHANCE_GROUP (real or uv); unset runs both. Windows only.
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

# True when $Text appears in $Console AFTER the offer's heading. The EXE verification run live-tees its own
# stderr to the console, so the same words can appear before the offer; only text after the heading proves the
# offer itself showed it.
function Test-AfterOffer {
    param([string]$Console, [string]$Text)
    $at = $Console.IndexOf('Your program stopped with an error')
    if ($at -lt 0) { return $false }
    return ($Console.IndexOf($Text, $at, [System.StringComparison]::Ordinal) -ge 0)
}

# The prompt text between its heading and the first line that records the decision, whitespace flattened to single
# spaces. Empty when either marker is missing, so a prompt that moved or changed its heading cannot pass.
function Get-PromptBlock {
    param([string]$Text, [string]$Heading, [string]$Decision)
    if (-not $Text) { return '' }
    $from = $Text.IndexOf($Heading, [System.StringComparison]::Ordinal)
    if ($from -lt 0) { return '' }
    $rest = $Text.Substring($from)
    $m = [regex]::Match($rest, $Decision)
    if (-not $m.Success) { return '' }
    return ($rest.Substring(0, $m.Index) -replace '\s+', ' ').Trim()
}

# The text of the [C] choice: from "[C]" up to "[N]" in a prompt block. Empty when either is missing or out of order.
function Get-ChoiceC {
    param([string]$Block)
    $c = $Block.IndexOf('[C]', [System.StringComparison]::Ordinal)
    $n = $Block.IndexOf('[N]', [System.StringComparison]::Ordinal)
    if ($c -lt 0 -or $n -le $c) { return '' }
    return $Block.Substring($c, $n - $c)
}

$group = [Environment]::GetEnvironmentVariable('LASTCHANCE_GROUP')
if (-not $group) { $group = 'all' }
$runReal = ($group -eq 'real') -or ($group -eq 'all')
$runUv   = ($group -eq 'uv')   -or ($group -eq 'all')

# Non-Windows skip (parity with other selfapps tests).
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.worked'
        req     = 'REQ-018'
        pass    = $true
        desc    = 'the last-chance offer (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.worked'
        req     = 'REQ-018'
        pass    = $false
        desc    = 'last-chance offer: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

# ---- fixtures: all standard library only, so no dependency step can interfere ----
# Fails on every run, with a traceback whose last line is the one the prompt must show.
$appFail = @'
import sys

print("lastchance app starting")
print("Traceback (most recent call last):", file=sys.stderr)
print('  File "app.py", line 8, in <module>', file=sys.stderr)
print("RuntimeError: simulated environment problem", file=sys.stderr)
sys.exit(3)
'@

# The last error line holds every character the batch file treats as an operator.
$appMeta = @'
import sys

print("lastchance app starting")
print('Error: a<b>c&d|e%PATH%^f "q" end', file=sys.stderr)
sys.exit(3)
'@

# Fails only as the packaged EXE; the plain interpreter run (the checkpoint) passes.
$appFrozen = @'
import sys

if getattr(sys, "frozen", False):
    print("RuntimeError: only the packaged EXE fails", file=sys.stderr)
    sys.exit(3)
print("interpreter run ok")
'@

$appOk = @'
print("lastchance app ok")
'@

# Silent and long running, like a window app waiting for the user.
$appSilent = @'
import time

time.sleep(600)
'@

# Fails unless the provider is conda (the bootstrapper's HP_ENV_MODE is inherited by every run it starts).
$appCondaTemplate = @'
import os
import sys

if os.environ.get("HP_ENV_MODE", "") == "conda":
    print("conda tier run")
    sys.exit(__CONDA_EXIT__)
print("Traceback (most recent call last):", file=sys.stderr)
print("RuntimeError: this provider cannot run the program", file=sys.stderr)
sys.exit(3)
'@

# Fails on uv (leaving a stale kill marker first when __UV_EXTRA__ asks for it) and behaves like a window app, or exits
# by itself with -1, on conda. HP_ENV_MODE is inherited from the bootstrapper.
$appWindowTemplate = @'
import os
import sys
import time

if os.environ.get("HP_ENV_MODE", "") == "conda":
    __CONDA_BODY__
__UV_EXTRA__
print("Traceback (most recent call last):", file=sys.stderr)
print("RuntimeError: this provider cannot run the program", file=sys.stderr)
sys.exit(3)
'@
$condaSilent   = 'time.sleep(600)'
$condaSelfExit = 'print("conda tier exits by itself", flush=True); sys.exit(-1)'
$uvStaleMarker = 'open("~smokerun_killed.txt", "w").write("stale"); print("stale marker written")'

# Runs one bootstrap of a fixture and returns everything the rows need. $EnvVars is a hashtable of extra
# environment variables for this run; $Stdin, when given, is the text the bootstrapper reads as the console.
function Invoke-LastChance {
    param([string]$Name, [string]$AppCode, [hashtable]$EnvVars = @{}, [string]$Stdin = $null)
    $workDir = Join-Path $here ('~selftest_lastchance_' + $Name)
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Copy-Item -Path $batchPath -Destination $workDir -Force
    Set-Content -Path (Join-Path $workDir 'app.py') -Value $AppCode -Encoding ASCII
    $stdinName = '~stdin.txt'
    if ($null -ne $Stdin) {
        [System.IO.File]::WriteAllText((Join-Path $workDir $stdinName), $Stdin, (New-Object System.Text.ASCIIEncoding))
    }

    $bootstrapLog = '~lc_' + $Name + '_bootstrap.log'
    $subNdjson    = Join-Path $workDir '~sub.ndjson'
    $names = @('HP_NDJSON') + @($EnvVars.Keys)
    $saved = @{}
    foreach ($n in $names) { $saved[$n] = [Environment]::GetEnvironmentVariable($n) }
    Push-Location $workDir
    try {
        [Environment]::SetEnvironmentVariable('HP_NDJSON', $subNdjson)
        foreach ($k in $EnvVars.Keys) { [Environment]::SetEnvironmentVariable($k, [string]$EnvVars[$k]) }
        if ($null -ne $Stdin) {
            cmd /c "call run_setup.bat < $stdinName > $bootstrapLog 2>&1"
        } else {
            cmd /c "call run_setup.bat < nul > $bootstrapLog 2>&1"
        }
        $runExit = $LASTEXITCODE
    } finally {
        foreach ($n in $names) { [Environment]::SetEnvironmentVariable($n, $saved[$n]) }
        Pop-Location
    }

    $logPath   = Join-Path $workDir $bootstrapLog
    $setupLog  = Join-Path $workDir '~setup.log'
    $errPath   = Join-Path $workDir '~run.err.txt'
    $ckptOut   = Join-Path $workDir '~checkpoint_run.out.txt'
    $console   = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Raw -Encoding ASCII } else { '' }
    $setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
    $errText   = if (Test-Path $errPath)  { Get-Content -LiteralPath $errPath  -Raw -Encoding ASCII } else { '' }
    $ckptText  = if (Test-Path $ckptOut)  { Get-Content -LiteralPath $ckptOut  -Raw -Encoding ASCII } else { '' }

    $rows = @()
    if (Test-Path -LiteralPath $subNdjson) {
        foreach ($line in (Get-Content -LiteralPath $subNdjson -Encoding ASCII)) {
            if (-not $line.Trim()) { continue }
            try { $rows += ($line | ConvertFrom-Json) } catch { continue }
        }
    }
    $offerRows = @($rows | Where-Object { $_.id -eq 'self.lastchance.offer' })
    $offerRow  = $offerRows | Select-Object -First 1
    $lastRow   = $offerRows | Select-Object -Last 1
    $exeFiles  = @()
    $distDir = Join-Path $workDir 'dist'
    if (Test-Path -LiteralPath $distDir) { $exeFiles = @(Get-ChildItem -LiteralPath $distDir -Filter '*.exe' -ErrorAction SilentlyContinue) }
    # Top-level names that are not the bootstrapper's own tilde-prefixed working files; a prompt that let an
    # operator in the error line through to cmd.exe would add one (for example a file named c).
    $topNames = @(Get-ChildItem -LiteralPath $workDir -Force | Where-Object { $_.Name -notlike '~*' } | ForEach-Object { $_.Name } | Sort-Object)

    [pscustomobject]@{
        RunExit    = $runExit
        Console    = $console
        SetupText  = $setupText
        ErrText    = $errText
        CheckpointOut = $ckptText
        OfferRows  = $offerRows.Count
        State      = if ($offerRow) { [string]$offerRow.details.state } else { $null }
        Reason     = if ($offerRow) { [string]$offerRow.details.reason } else { $null }
        Site       = if ($offerRow) { [string]$offerRow.details.site } else { $null }
        Provider   = if ($offerRow) { [string]$offerRow.details.provider } else { $null }
        RowExit    = if ($offerRow) { [string]$offerRow.details.exitCode } else { $null }
        PassType   = if ($offerRow) { [string]$offerRow.details.passType } else { $null }
        HasLine    = if ($offerRow) { [string]$offerRow.details.hasLine } else { $null }
        LastState    = if ($lastRow) { [string]$lastRow.details.state } else { $null }
        LastPassType = if ($lastRow) { [string]$lastRow.details.passType } else { $null }
        LastProvider = if ($lastRow) { [string]$lastRow.details.provider } else { $null }
        LastExit     = if ($lastRow) { [string]$lastRow.details.exitCode } else { $null }
        StaleLeft    = (Test-Path -LiteralPath (Join-Path $workDir '~smokerun_killed.txt'))
        StateFile    = $(if (Test-Path -LiteralPath (Join-Path $workDir '~provider.state.json')) { (Get-Content -LiteralPath (Join-Path $workDir '~provider.state.json') -Raw -Encoding ASCII).Trim() } else { $null })
        WindowPrompt = ($console -match 'Did it open and work')
        ExeKept    = ($exeFiles.Count -gt 0)
        TopNames   = $topNames
        PromptCount = ([regex]::Matches($console, 'Your program stopped with an error')).Count
    }
}

$allPass = $true

if ($runReal) {
    # ---- worked: answer W keeps the build and records the pass type ----
    $w = Invoke-LastChance -Name 'worked' -AppCode $appFail -EnvVars @{ HP_TEST_LASTCHANCE_ANSWER = 'W' }
    $wPrecond  = ($w.SetupText -match 'Entry smoke exit=3') -and ($w.ErrText -match 'RuntimeError: simulated environment problem')
    $wPrompted = ($w.Console -match 'Your program stopped with an error, exit code 3') -and ($w.Console -match '\[W\]') -and
                 ($w.Console -match '\[C\]') -and ($w.Console -match '\[N\]') -and (Test-AfterOffer $w.Console 'RuntimeError: simulated environment problem')
    $wSaidWorked = $w.SetupText -match 'Last chance: you said it worked'
    $wNoCascade  = $w.SetupText -notmatch 'cascading provider'
    $wPass = $wPrecond -and $wPrompted -and $wSaidWorked -and $wNoCascade -and $w.ExeKept -and
             ($w.PromptCount -eq 1) -and ($w.OfferRows -eq 1) -and ($w.State -eq 'worked') -and
             ($w.PassType -eq 'user_confirmed') -and ($w.Site -eq 'exe') -and ($w.RowExit -eq '3') -and ($w.Provider -eq 'uv')
    if (-not $wPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.worked'
        req     = 'REQ-018.23, REQ-018.24'
        pass    = $wPass
        desc    = 'after a failed verification run on uv, answer W keeps the build, starts no cascade and records user_confirmed'
        details = [ordered]@{
            exitCode      = $w.RunExit
            precondition  = $wPrecond
            prompted      = $wPrompted
            saidWorked    = $wSaidWorked
            noCascade     = $wNoCascade
            exeKept       = $w.ExeKept
            promptCount   = $w.PromptCount
            offerRows     = $w.OfferRows
            rowState      = $w.State
            rowPassType   = $w.PassType
            rowSite       = $w.Site
            rowExitCode   = $w.RowExit
            rowProvider   = $w.Provider
        }
    })

    # ---- errline: no answer (automated run), and a hostile error line shown intact ----
    $metaLine = 'Error: a<b>c&d|e%PATH%^f "q" end'
    $e = Invoke-LastChance -Name 'errline' -AppCode $appMeta
    $ePrecond  = ($e.SetupText -match 'Entry smoke exit=3') -and $e.ErrText.Contains($metaLine)
    $ePrompted = ($e.Console -match 'Your program stopped with an error, exit code 3') -and (Test-AfterOffer $e.Console $metaLine)
    $eInLog    = $e.SetupText.Contains($metaLine)
    $eAutomated = $e.SetupText -match 'Last chance: automated run, no question asked'
    $eNoCascade = $e.SetupText -notmatch 'cascading provider'
    # The offer's own log line comes after the hostile line, so seeing it there proves the log kept going.
    $eLineAt = $e.SetupText.IndexOf($metaLine, [System.StringComparison]::Ordinal)
    $eLogIntact = ($eLineAt -ge 0) -and ($e.SetupText.IndexOf('Last chance: automated run', $eLineAt, [System.StringComparison]::Ordinal) -gt $eLineAt)
    $eStray = @($e.TopNames | Where-Object { @('b', 'c', 'd', 'e', 'f', 'q', 'PATH', 'end') -contains $_ })
    $eSameNames = (($e.TopNames -join '|') -eq (($w.TopNames) -join '|'))
    $ePass = $ePrecond -and $ePrompted -and $eInLog -and $eAutomated -and $eNoCascade -and $eLogIntact -and
             ($eStray.Count -eq 0) -and $eSameNames -and $e.ExeKept -and ($e.PromptCount -eq 1) -and
             ($e.State -eq 'automated') -and ($e.HasLine -eq 'True')
    if (-not $ePass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.errline'
        req     = 'REQ-018.23, REQ-018.24'
        pass    = $ePass
        desc    = 'with no answer in an automated run the offer resolves to neither without waiting, and an error line holding < > & | % ^ is shown intact with no stray file'
        details = [ordered]@{
            exitCode     = $e.RunExit
            precondition = $ePrecond
            prompted     = $ePrompted
            lineInSetupLog = $eInLog
            automated    = $eAutomated
            noCascade    = $eNoCascade
            logIntact    = $eLogIntact
            strayNames   = ($eStray -join ',')
            sameNamesAsWorked = $eSameNames
            exeKept      = $e.ExeKept
            promptCount  = $e.PromptCount
            rowState     = $e.State
            rowHasLine   = $e.HasLine
        }
    })

    # ---- risk (README REQ-018.2 and REQ-018.25): the [C] choice says the program runs once more and names the risk ----
    # Read from the console of the worked and errline runs above (the same prompt in both), so no extra bootstrap.
    $riskMarker   = 'running it twice could cause harm'
    $riskHeading  = 'Your program stopped with an error, exit code'
    $riskDecision = 'Last chance: (you said it worked|automated run, no question asked|neither|cascade approved)'
    $wChoice = Get-ChoiceC (Get-PromptBlock -Text $w.Console -Heading $riskHeading -Decision $riskDecision)
    $eChoice = Get-ChoiceC (Get-PromptBlock -Text $e.Console -Heading $riskHeading -Decision $riskDecision)
    $wSaysOnceMore = $wChoice.Contains('Try again with Miniconda') -and $wChoice.Contains('once more')
    $eSaysOnceMore = $eChoice.Contains('Try again with Miniconda') -and $eChoice.Contains('once more')
    $wNamesRisk = $wChoice.Contains($riskMarker)
    $eNamesRisk = $eChoice.Contains($riskMarker)
    $rPass = ($wChoice.Length -gt 0) -and ($eChoice.Length -gt 0) -and $wSaysOnceMore -and $eSaysOnceMore -and $wNamesRisk -and $eNamesRisk
    if (-not $rPass) { $allPass = $false }
    $rShown = $wChoice
    if ($rShown.Length -gt 400) { $rShown = $rShown.Substring(0, 400) }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.risk'
        req     = 'REQ-018.2, REQ-018.25'
        pass    = $rPass
        desc    = 'the Miniconda choice of the last-chance offer says the program runs once more and that running it twice could cause harm'
        details = [ordered]@{
            workedChoiceFound  = ($wChoice.Length -gt 0)
            errlineChoiceFound = ($eChoice.Length -gt 0)
            workedSaysOnceMore = $wSaysOnceMore
            errlineSaysOnceMore = $eSaysOnceMore
            workedNamesRisk    = $wNamesRisk
            errlineNamesRisk   = $eNamesRisk
            choiceText         = $rShown
        }
    })

    # ---- enter: interpreter site, a real set /p read with a bare Enter, and the line helper unavailable ----
    $n = Invoke-LastChance -Name 'enter' -AppCode $appFail -Stdin "`r`n" -EnvVars @{
        HP_SKIP_EXE_SMOKERUN = '1'
        HP_TEST_FORCE_INTERACTIVE_LASTCHANCE = '1'
        HP_TEST_FORCE_EMIT_FAIL = 'HP_LAST_ERROR_LINE'
    }
    $nPrecond  = ($n.SetupText -match 'Running entry script smoke test via uv interpreter') -and ($n.SetupText -match 'Entry smoke exit=3')
    $nPrompted = ($n.Console -match 'Your program stopped with an error, exit code 3') -and ($n.Console -match '\[N\]')
    $nNoLine   = -not (Test-AfterOffer $n.Console 'RuntimeError: simulated environment problem')
    $nNeither  = $n.SetupText -match 'Last chance: neither'
    $nNoCascade = $n.SetupText -notmatch 'cascading provider'
    $nPass = $nPrecond -and $nPrompted -and $nNoLine -and $nNeither -and $nNoCascade -and ($n.PromptCount -eq 1) -and
             ($n.State -eq 'neither') -and ($n.Site -eq 'interpreter') -and ($n.HasLine -eq 'False') -and ($n.RowExit -eq '3')
    if (-not $nPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.enter'
        req     = 'REQ-018.23'
        pass    = $nPass
        desc    = 'at the interpreter site a bare Enter at the real prompt means neither, and a failed error-line helper only drops the last-line part'
        details = [ordered]@{
            exitCode     = $n.RunExit
            precondition = $nPrecond
            prompted     = $nPrompted
            lineOmitted  = $nNoLine
            saidNeither  = $nNeither
            noCascade    = $nNoCascade
            promptCount  = $n.PromptCount
            rowState     = $n.State
            rowSite      = $n.Site
            rowHasLine   = $n.HasLine
            rowExitCode  = $n.RowExit
        }
    })

    # ---- checkpoint_ok: the accepted checkpoint ran the interpreter and it exited 0, so no prompt ----
    $c = Invoke-LastChance -Name 'ckpt' -AppCode $appFrozen -EnvVars @{ HP_TEST_CHECKPOINT_ANSWER = 'Y' }
    $cPrecond = ($c.SetupText -match 'Entry smoke exit=3') -and ($c.SetupText -match 'post-execution checkpoint \(exe\): accepted') -and
                ($c.CheckpointOut -match 'interpreter run ok')
    $cNoPrompt = ($c.Console -notmatch 'Your program stopped with an error') -and ($c.SetupText -notmatch 'Last chance: you said') -and
                 ($c.SetupText -notmatch 'Last chance: neither') -and ($c.SetupText -notmatch 'cascading provider')
    $cLogged = $c.SetupText -match 'Last chance: not offered \(checkpoint_ok\)'
    $cPass = $cPrecond -and $cNoPrompt -and $cLogged -and ($c.OfferRows -eq 1) -and ($c.State -eq 'not_offered') -and
             ($c.Reason -eq 'checkpoint_ok') -and ($c.RowExit -eq '3')
    if (-not $cPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.checkpoint_ok'
        req     = 'REQ-018.26'
        pass    = $cPass
        desc    = 'when the accepted checkpoint run through the interpreter exits 0 the failed EXE run does not raise the offer'
        details = [ordered]@{
            exitCode     = $c.RunExit
            precondition = $cPrecond
            noPrompt     = $cNoPrompt
            logged       = $cLogged
            offerRows    = $c.OfferRows
            rowState     = $c.State
            rowReason    = $c.Reason
            rowExitCode  = $c.RowExit
        }
    })

    # ---- exit0: a successful run never gets the prompt and writes no row ----
    $o = Invoke-LastChance -Name 'exit0' -AppCode $appOk
    $oPrecond = ($o.SetupText -match 'Entry smoke exit=0') -and ($o.SetupText -match 'Run Status: SUCCESS')
    $oPass = $oPrecond -and ($o.Console -notmatch 'Your program stopped with an error') -and ($o.SetupText -notmatch 'Last chance') -and
             ($o.OfferRows -eq 0)
    if (-not $oPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.exit0'
        req     = 'REQ-018.26'
        pass    = $oPass
        desc    = 'a run that exits 0 never raises the offer and leaves no trace of it'
        details = [ordered]@{
            exitCode     = $o.RunExit
            precondition = $oPrecond
            promptCount  = $o.PromptCount
            offerRows    = $o.OfferRows
        }
    })
}

if ($runUv) {
    # ---- timeout: a silent run the smoke runner force-stops is a window app, not an error ----
    $t = Invoke-LastChance -Name 'timeout' -AppCode $appSilent -EnvVars @{ HP_SMOKERUN_KILL_MS = '6000'; HP_TEST_LASTCHANCE_ANSWER = 'C' }
    $tPrecond = ($t.SetupText -match 'Entry smoke exit=-1') -and ($t.SetupText -match 'Run Status: TIMED OUT')
    $tPass = $tPrecond -and ($t.Console -notmatch 'Your program stopped with an error') -and ($t.SetupText -notmatch 'Last chance') -and
             ($t.SetupText -notmatch 'cascading provider') -and ($t.OfferRows -eq 0) -and (-not $t.WindowPrompt)
    if (-not $tPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.timeout'
        req     = 'REQ-018.26'
        pass    = $tPass
        desc    = 'a silent run that the smoke runner force-stops (exit -1) does not raise the offer even when an answer is supplied'
        details = [ordered]@{
            exitCode     = $t.RunExit
            precondition = $tPrecond
            promptCount  = $t.PromptCount
            offerRows    = $t.OfferRows
            windowPrompt = $t.WindowPrompt
        }
    })

    # ---- cascade: answer C runs uv to conda, the program passes there, the prompt is shown once ----
    $hc = Invoke-LastChance -Name 'cascade' -AppCode ($appCondaTemplate.Replace('__CONDA_EXIT__', '0')) -EnvVars @{
        HP_TEST_LASTCHANCE_ANSWER = 'C'
        HP_TEST_SYSCON_ANSWER = 'N'
    }
    $hcPrecond = ($hc.SetupText -match 'Entry smoke exit=3')
    $hcCascaded = ($hc.SetupText -match 'cascading provider uv to conda') -and ($hc.SetupText -match 'Last chance: cascade approved')
    $hcPassedOnConda = ($hc.SetupText -match 'Entry smoke exit=0') -and ($hc.SetupText -match 'Run Status: SUCCESS')
    $hcOnce = ($hc.PromptCount -eq 1) -and ($hc.OfferRows -eq 1)
    $hcPass = $hcPrecond -and $hcCascaded -and $hcPassedOnConda -and $hcOnce -and ($hc.State -eq 'cascade') -and ($hc.Provider -eq 'uv') -and
              (-not $hc.WindowPrompt)
    if (-not $hcPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.cascade'
        req     = 'REQ-009, REQ-018.27'
        pass    = $hcPass
        desc    = 'answer C re-attempts the program under conda, which passes it, and the prompt is shown exactly once'
        details = [ordered]@{
            exitCode      = $hc.RunExit
            precondition  = $hcPrecond
            cascaded      = $hcCascaded
            passedOnConda = $hcPassedOnConda
            promptCount   = $hc.PromptCount
            offerRows     = $hc.OfferRows
            rowState      = $hc.State
            rowProvider   = $hc.Provider
            windowPrompt  = $hc.WindowPrompt
        }
    })

    # ---- cascade_again: the program fails on conda as well, and the offer is not repeated ----
    $ha = Invoke-LastChance -Name 'again' -AppCode ($appCondaTemplate.Replace('__CONDA_EXIT__', '4')) -EnvVars @{
        HP_TEST_LASTCHANCE_ANSWER = 'C'
        HP_TEST_SYSCON_ANSWER = 'N'
    }
    $haPrecond = ($ha.SetupText -match 'Entry smoke exit=3')
    $haCascaded = $ha.SetupText -match 'cascading provider uv to conda'
    $haFailedOnConda = $ha.SetupText -match 'Entry smoke exit=4'
    $haNotAgain = ($ha.PromptCount -eq 1) -and ($ha.OfferRows -eq 2)
    $haSecondRow = @($ha.SetupText -split "`n" | Where-Object { $_ -match 'Last chance: not offered \(provider\)' }).Count -ge 1
    $haPass = $haPrecond -and $haCascaded -and $haFailedOnConda -and $haNotAgain -and $haSecondRow -and ($ha.State -eq 'cascade') -and
              (-not $ha.WindowPrompt)
    if (-not $haPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.cascade_again'
        req     = 'REQ-009, REQ-018.26'
        pass    = $haPass
        desc    = 'when the program also fails on conda the prompt is not shown a second time'
        details = [ordered]@{
            exitCode       = $ha.RunExit
            precondition   = $haPrecond
            cascaded       = $haCascaded
            failedOnConda  = $haFailedOnConda
            promptCount    = $ha.PromptCount
            offerRows      = $ha.OfferRows
            notOfferedLogged = $haSecondRow
            rowState       = $ha.State
            windowPrompt   = $ha.WindowPrompt
        }
    })

    # ---- window_*: Item 82 slice 2. uv fails, answer C cascades, conda runs a silent program the runner stops ----
    $windowApp = $appWindowTemplate.Replace('__CONDA_BODY__', $condaSilent).Replace('__UV_EXTRA__', '')
    $windowEnv = @{ HP_TEST_LASTCHANCE_ANSWER = 'C'; HP_TEST_SYSCON_ANSWER = 'N'; HP_SMOKERUN_KILL_MS = '6000' }
    $windowQuestionShown = 'Did it open and work'

    $wy = Invoke-LastChance -Name 'window_yes' -AppCode $windowApp -EnvVars ($windowEnv + @{ HP_TEST_WINDOWOK_ANSWER = 'Y' })
    $wyPrecond = ($wy.SetupText -match 'Entry smoke exit=3') -and ($wy.SetupText -match 'cascading provider uv to conda') -and
                 ($wy.SetupText -match 'Entry smoke exit=-1') -and ($wy.SetupText -match 'Run Status: TIMED OUT')
    $wyAsked = $wy.WindowPrompt -and ($wy.PromptCount -eq 1)
    $wyLogged = $wy.SetupText -match 'Last chance: you said the window opened and worked'
    $wyRecorded = ($wy.OfferRows -eq 2) -and ($wy.LastState -eq 'window_confirmed') -and ($wy.LastPassType -eq 'user_confirmed') -and
                  ($wy.LastProvider -eq 'conda') -and ($wy.LastExit -eq '-1') -and ($wy.State -eq 'cascade')
    # Item 66: only an explicit yes on the cascade-reached conda tier is remembered, tagged user_confirmed.
    $wyRemembered = ($wy.StateFile -match '"provider":"conda"') -and ($wy.StateFile -match '"passType":"user_confirmed"')
    $wyPass = $wyPrecond -and $wyAsked -and $wyLogged -and $wyRecorded -and $wyRemembered -and (-not $wy.StaleLeft)
    if (-not $wyPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.window_yes'
        req     = 'REQ-018.28, REQ-018.29'
        pass    = $wyPass
        desc    = 'on the conda tier a silent program the runner force-stopped raises the question and an explicit yes records user_confirmed'
        details = [ordered]@{
            exitCode     = $wy.RunExit
            precondition = $wyPrecond
            asked        = $wyAsked
            logged       = $wyLogged
            recorded     = $wyRecorded
            remembered   = $wyRemembered
            stateFile    = $wy.StateFile
            offerRows    = $wy.OfferRows
            lastState    = $wy.LastState
            lastPassType = $wy.LastPassType
            lastProvider = $wy.LastProvider
            lastExitCode = $wy.LastExit
            markerLeft   = $wy.StaleLeft
            promptCount  = $wy.PromptCount
        }
    })

    $we = Invoke-LastChance -Name 'window_enter' -AppCode $windowApp -Stdin "`r`n" -EnvVars ($windowEnv + @{ HP_TEST_FORCE_INTERACTIVE_WINDOWOK = '1' })
    $wePrecond = ($we.SetupText -match 'Entry smoke exit=3') -and ($we.SetupText -match 'cascading provider uv to conda') -and
                 ($we.SetupText -match 'Entry smoke exit=-1')
    $weAsked = $we.WindowPrompt -and ($we.Console -match '\[y/N\]')
    $weNothing = ($we.SetupText -match 'Last chance: window not confirmed') -and ($we.SetupText -notmatch 'user_confirmed') -and
                 ($we.OfferRows -eq 2) -and ($we.LastState -eq 'window_declined') -and ([string]::IsNullOrEmpty($we.LastPassType))
    $weNothing = $weNothing -and ($null -eq $we.StateFile)
    $wePass = $wePrecond -and $weAsked -and $weNothing
    if (-not $wePass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.window_enter'
        req     = 'REQ-018.28, REQ-018.29'
        pass    = $wePass
        desc    = 'a bare Enter at the real window question means no and records nothing'
        details = [ordered]@{
            exitCode     = $we.RunExit
            precondition = $wePrecond
            asked        = $weAsked
            recordedNothing = $weNothing
            offerRows    = $we.OfferRows
            lastState    = $we.LastState
            lastPassType = $we.LastPassType
        }
    })

    $wa = Invoke-LastChance -Name 'window_auto' -AppCode $windowApp -EnvVars $windowEnv
    $waPrecond = ($wa.SetupText -match 'Entry smoke exit=3') -and ($wa.SetupText -match 'cascading provider uv to conda') -and
                 ($wa.SetupText -match 'Entry smoke exit=-1')
    $waNothing = ($wa.SetupText -match 'Last chance: automated run, no window question asked') -and ($wa.OfferRows -eq 2) -and
                 ($wa.LastState -eq 'window_automated') -and ([string]::IsNullOrEmpty($wa.LastPassType))
    $waNothing = $waNothing -and ($null -eq $wa.StateFile)
    $waPass = $waPrecond -and $wa.WindowPrompt -and $waNothing
    if (-not $waPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.window_auto'
        req     = 'REQ-018.28, REQ-018.29'
        pass    = $waPass
        desc    = 'in an automated run with no override the window question resolves to no without waiting and records nothing'
        details = [ordered]@{
            exitCode     = $wa.RunExit
            precondition = $waPrecond
            promptShown  = $wa.WindowPrompt
            recordedNothing = $waNothing
            offerRows    = $wa.OfferRows
            lastState    = $wa.LastState
        }
    })

    # The uv tier leaves a stale kill marker behind; the conda tier's program exits by itself with -1, the same code
    # a force-stop produces. Only the runner stopping a silent process may raise the question, so it must be absent
    # even with a yes supplied. The precondition shows the -1 really arises and the marker really was left.
    $selfApp = $appWindowTemplate.Replace('__CONDA_BODY__', $condaSelfExit).Replace('__UV_EXTRA__', $uvStaleMarker)
    $ws = Invoke-LastChance -Name 'window_selfexit' -AppCode $selfApp -EnvVars ($windowEnv + @{ HP_TEST_WINDOWOK_ANSWER = 'Y' })
    $wsPrecond = ($ws.SetupText -match 'Entry smoke exit=3') -and ($ws.SetupText -match 'cascading provider uv to conda') -and
                 ($ws.SetupText -match 'Entry smoke exit=-1') -and ($ws.Console -match 'stale marker written') -and
                 ($ws.Console -match 'conda tier exits by itself')
    $wsAbsent = (-not $ws.WindowPrompt) -and ($ws.SetupText -notmatch 'Last chance: you said the window') -and
                ($ws.SetupText -notmatch 'Last chance: window not confirmed') -and ($ws.OfferRows -eq 1) -and ($ws.State -eq 'cascade')
    $wsPass = $wsPrecond -and $wsAbsent -and (-not $ws.StaleLeft)
    if (-not $wsPass) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.lastchance.window_selfexit'
        req     = 'REQ-018.31'
        pass    = $wsPass
        desc    = 'a program that exits by itself with -1 on the conda tier does not raise the window question, and a stale kill marker is cleared'
        details = [ordered]@{
            exitCode     = $ws.RunExit
            precondition = $wsPrecond
            questionAbsent = $wsAbsent
            offerRows    = $ws.OfferRows
            markerLeft   = $ws.StaleLeft
        }
    })
}

if (-not $allPass) { exit 1 }
exit 0
