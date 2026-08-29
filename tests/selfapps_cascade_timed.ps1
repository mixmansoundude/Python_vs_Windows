# ASCII only
# selfapps_cascade_timed.ps1 - REQ-009/REQ-005.10: cascade consent gate's TIMED prompt.
#
# CLAUDE.md item 9 / docs/open-questions.md item 1 follow-up: before this fix, an interactive
# user who was not physically present when the cascade consent prompt appeared would hang the
# whole bootstrap forever (a bare `set /p` has no timeout). :cascade_consent_gate now uses a
# `choice /T` timed prompt (default: 30s, mirrors :pick_entry_interactive's own established
# pattern) that defaults to N (decline) if nobody answers -- so an unattended run still tries
# the current build once, unprompted, instead of hanging.
#
# HP_TEST_FORCE_INTERACTIVE_CASCADE=1 forces the timed-choice branch to be reached even under
# HP_CI_LANE (which would otherwise auto-decline with no prompt at all) and shrinks the timeout
# to 2s, mirroring HP_TEST_FORCE_PICKER's own established pattern for :pick_entry_interactive
# (see tests/selfapps_entry_picker.ps1). With no interactive console and no HP_TEST_CASCADE_ANSWER
# override, `choice` degrades to its default (N) within ~2s -- proving the timed mechanism itself
# works (reaches the prompt, does not hang, resolves to decline) without needing a real human.
#
# Also verifies the companion "dependencies may be incomplete" note (HP_DEP_MAYBE_INCOMPLETE)
# fires on decline and appears before the EXE launch, and that the postexec-offers-skip message
# (added for the SAME item, tested positively in self.cascade.exec's approved-cascade path) does
# NOT fire here, since cascade was declined, not approved -- the offers should still be shown.
#
# The app imports a nonexistent module so warnfix's repair genuinely fails and a cascade
# candidate is detected, exactly like selfapps_cascade.ps1's own app -- but this test never lets
# the cascade proceed, so it never reaches conda/embed/venv/system and stays fast.
#
# Emits: self.cascade.timed
#
# Lane: conda-full only (one real bootstrap; HP_FORCE_CONDA_ONLY keeps the provider deterministic
# and this test needs only ONE warnfix/cascade-candidate cycle, not a full multi-tier walk).
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

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.cascade.timed'
        req     = 'REQ-009'
        pass    = $true
        desc    = 'Cascade consent timed prompt (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.cascade.timed'
        req     = 'REQ-009'
        pass    = $false
        desc    = 'run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_cascade_timed'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

$appCode = @'
import fake_pkg_cascade_timed_xyz
print('cascade-timed-app-ran')
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

$prevSkipPip  = if (Test-Path Env:HP_SKIP_PIPREQS)                  { $env:HP_SKIP_PIPREQS }                  else { $null }
$prevDisableH = if (Test-Path Env:HP_DISABLE_HEURISTICS)            { $env:HP_DISABLE_HEURISTICS }            else { $null }
$prevForce    = if (Test-Path Env:HP_TEST_FORCE_INTERACTIVE_CASCADE){ $env:HP_TEST_FORCE_INTERACTIVE_CASCADE }else { $null }
$env:HP_SKIP_PIPREQS       = '1'
$env:HP_DISABLE_HEURISTICS = '1'
$env:HP_TEST_FORCE_INTERACTIVE_CASCADE = '1'

$bootstrapLog = '~cascade_timed_bootstrap.log'
$runExit = -1
Push-Location -LiteralPath $workDir
try {
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prevSkipPip)  { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue }                  else { $env:HP_SKIP_PIPREQS = $prevSkipPip }
    if ($null -eq $prevDisableH) { Remove-Item Env:HP_DISABLE_HEURISTICS -ErrorAction SilentlyContinue }            else { $env:HP_DISABLE_HEURISTICS = $prevDisableH }
    if ($null -eq $prevForce)    { Remove-Item Env:HP_TEST_FORCE_INTERACTIVE_CASCADE -ErrorAction SilentlyContinue }else { $env:HP_TEST_FORCE_INTERACTIVE_CASCADE = $prevForce }
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# The timed prompt itself was actually shown (not silently skipped like the plain HP_CI_LANE
# auto-decline path would) -- proves HP_TEST_FORCE_INTERACTIVE_CASCADE reached the interactive
# branch, not the CI auto-decline shortcut.
$promptShown = $combined -match [regex]::Escape('Try the next Python provider to resolve them?')
# It resolved to decline (the /D N default, since nothing answered it within 2s) -- not a hang
# (proven by runExit being a real exit code at all) and not an accidental accept.
$consentDeclined = $combined -match [regex]::Escape('[INFO] REQ-009: cascade consent: declined.')
$consentAccepted = $combined -match [regex]::Escape('[INFO] REQ-009: cascade consent: accepted.')
# The dirty-flag note fired at both its injection points: the decline-time WARN and the
# pre-launch reminder in :warn_user_code_launch.
$declineNoteFired = $combined -match [regex]::Escape('[WARN] REQ-009: dependencies for this provider may still be incomplete.')
$launchNoteFired  = $combined -match [regex]::Escape('[WARN] Note: dependency installation for this run may be incomplete')
# Since cascade was DECLINED (not approved), the postexec-offers-skip message must NOT fire --
# only cascade approval skips those offers (self.cascade.exec proves the positive case).
$offersSkipWronglyFired = $combined -match [regex]::Escape('REQ-009: cascade approved; skipping the post-verification offers')
# The run still completed gracefully (declining is not a bootstrapper failure).
$statusPath = Join-Path $workDir '~bootstrap.status.json'
$statusState = $null
if (Test-Path -LiteralPath $statusPath) {
    try { $statusState = (Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json).state } catch { }
}

$pass = $promptShown -and $consentDeclined -and (-not $consentAccepted) -and $declineNoteFired -and $launchNoteFired -and (-not $offersSkipWronglyFired) -and ($statusState -eq 'ok')

Write-NdjsonRow ([ordered]@{
    id      = 'self.cascade.timed'
    req     = 'REQ-009'
    pass    = $pass
    desc    = 'Cascade consent gate uses a TIMED choice prompt (not an unbounded set /p); with no answer it defaults to decline within 2s, and the dependency-incomplete note reaches the user'
    details = [ordered]@{
        promptShown             = $promptShown
        consentDeclined         = $consentDeclined
        consentAccepted         = $consentAccepted
        declineNoteFired        = $declineNoteFired
        launchNoteFired         = $launchNoteFired
        offersSkipWronglyFired  = $offersSkipWronglyFired
        statusState             = $statusState
        runExit                 = $runExit
        log                     = $bootstrapLog
    }
})

if (-not $pass) { exit 1 }
exit 0
