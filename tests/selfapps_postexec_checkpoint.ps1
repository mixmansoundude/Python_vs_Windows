# ASCII only
# selfapps_postexec_checkpoint.ps1 - Slice 2b-C post-execution checkpoint. After the FIRST
# verification run (EXE smoke or no-EXE interpreter run) prints its [STATUS] telemetry,
# :run_postexec_checkpoint offers an ELECTIVE second run via the interpreter, gated by the
# same 3-branch consent-gate pattern as :system_build_consent_gate/:cascade_consent_gate
# (HP_TEST_CHECKPOINT_ANSWER override -> HP_CI_LANE auto-decline -> interactive set /p).
#
#   self.checkpoint.accept  - HP_TEST_CHECKPOINT_ANSWER=Y forces acceptance; asserts the
#     "accepted" log line, the prompt text (echoed unconditionally), and that the entry ran a
#     SECOND time (two "Entry smoke exit=0" lines: the EXE smoke, then the checkpoint's own
#     :run_failfast_probe-driven interpreter run).
#
#   self.checkpoint.decline - default/HP_CI_LANE auto-decline; asserts the "declined" log line,
#     the same unconditional prompt text, and that the run footprint stays at exactly one
#     execution (a single "Entry smoke exit=0" line).
#
#   self.checkpoint.risk    - README REQ-018.8 (REQ-018.2 stays untraced, see UNTRACED_SHALLS): read from the console text of the two runs above, the
#     prompt (from its heading to the line that records the decision) says "running it twice could cause harm", so
#     the user is told the risk before choosing. An empty block (heading or decision line missing) fails the row.
#
# Lane: real and conda-full only (matches selfapps_exefastpath.ps1 / selfapps_failfast_probe.ps1).
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

$ndjsonIds = @('self.checkpoint.accept', 'self.checkpoint.decline', 'self.checkpoint.risk')

# Non-Windows skip
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    foreach ($id in $ndjsonIds) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-018'
            pass    = $true
            desc    = 'Post-execution checkpoint test skipped on non-Windows host'
            details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
        })
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($id in $ndjsonIds) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-018'
            pass    = $false
            desc    = 'Post-execution checkpoint test: run_setup.bat not found'
            details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
        })
    }
    exit 1
}

function Invoke-Bootstrap {
    param([string]$WorkDir, [string]$LogName)
    Push-Location -LiteralPath $WorkDir
    try {
        cmd /c "call run_setup.bat > $LogName 2>&1"
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function New-CheckpointTestApp {
    param([string]$WorkDir)
    if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
    New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
    Copy-Item -Path $batchPath -Destination $WorkDir -Force
    Set-Content -Path (Join-Path $WorkDir 'entry.py') -Value 'print("smoke-ok")' -Encoding ASCII
}

# --- Scenario A: accept -- HP_TEST_CHECKPOINT_ANSWER=Y forces the elective second run ---
$acceptPass = $false
$acceptDetails = [ordered]@{}
try {
    $accDir = Join-Path $here '~selftest_checkpoint_accept'
    New-CheckpointTestApp -WorkDir $accDir

    $savedSkipPipreqsAcc = $env:HP_SKIP_PIPREQS
    $savedLaneAcc = $env:HP_CI_LANE
    $savedCheckpointAcc = $env:HP_TEST_CHECKPOINT_ANSWER
    $savedNdjsonAcc = $env:HP_NDJSON
    $env:HP_SKIP_PIPREQS = '1'
    $env:HP_CI_LANE = 'test'
    $env:HP_TEST_CHECKPOINT_ANSWER = 'Y'
    # Defensive (mirrors selfapps_failfast_probe.ps1 / selfapps_exefastpath.ps1): an accepted
    # checkpoint triggers a SECOND self.failfast.probe row (details.site='checkpoint') when
    # HP_NDJSON is defined; this test asserts via log text instead, so keep it out of the gated
    # NDJSON stream regardless of whether run_setup.bat's own auto-detection would set it.
    Remove-Item Env:HP_NDJSON -ErrorAction SilentlyContinue

    $accExit = Invoke-Bootstrap -WorkDir $accDir -LogName '~checkpoint_accept.log'

    if ($null -eq $savedSkipPipreqsAcc) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $savedSkipPipreqsAcc }
    if ($null -eq $savedLaneAcc) { Remove-Item Env:HP_CI_LANE -ErrorAction SilentlyContinue } else { $env:HP_CI_LANE = $savedLaneAcc }
    if ($null -eq $savedCheckpointAcc) { Remove-Item Env:HP_TEST_CHECKPOINT_ANSWER -ErrorAction SilentlyContinue } else { $env:HP_TEST_CHECKPOINT_ANSWER = $savedCheckpointAcc }
    if ($null -ne $savedNdjsonAcc) { $env:HP_NDJSON = $savedNdjsonAcc }

    $accLogPath = Join-Path $accDir '~checkpoint_accept.log'
    $accLines = if (Test-Path $accLogPath) { Get-Content -LiteralPath $accLogPath -Encoding ASCII } else { @() }
    $accText = $accLines -join "`n"

    $accPromptShown = $accText -match [regex]::Escape('Verification finished -- see the Run Status above.')
    # Log line now carries a site tag, e.g. "checkpoint (exe): accepted..." -- match either site.
    $accAccepted = $accText -match 'post-execution checkpoint \((exe|interpreter)\): accepted; running a second time via the interpreter\.'
    $accRunCount = ([regex]::Matches($accText, [regex]::Escape('Entry smoke exit=0'))).Count

    $acceptPass = ($accExit -eq 0) -and $accPromptShown -and $accAccepted -and ($accRunCount -ge 2)
    $acceptDetails = [ordered]@{
        exitCode     = $accExit
        promptShown  = $accPromptShown
        accepted     = $accAccepted
        runCount     = $accRunCount
        log          = '~checkpoint_accept.log'
    }
} catch {
    $acceptDetails = [ordered]@{ error = $_.Exception.Message }
}

Write-NdjsonRow ([ordered]@{
    id      = 'self.checkpoint.accept'
    req     = 'REQ-018, REQ-018.8'
    pass    = $acceptPass
    desc    = 'Post-execution checkpoint: HP_TEST_CHECKPOINT_ANSWER=Y accepts and runs the entry a second time via the interpreter'
    details = $acceptDetails
})

# --- Scenario B: decline -- default/HP_CI_LANE auto-decline keeps the run footprint at one ---
$declinePass = $false
$declineDetails = [ordered]@{}
try {
    $decDir = Join-Path $here '~selftest_checkpoint_decline'
    New-CheckpointTestApp -WorkDir $decDir

    $savedSkipPipreqsDec = $env:HP_SKIP_PIPREQS
    $savedLaneDec = $env:HP_CI_LANE
    $savedCheckpointDec = $env:HP_TEST_CHECKPOINT_ANSWER
    $savedNdjsonDec = $env:HP_NDJSON
    $env:HP_SKIP_PIPREQS = '1'
    $env:HP_CI_LANE = 'test'
    Remove-Item Env:HP_TEST_CHECKPOINT_ANSWER -ErrorAction SilentlyContinue
    # Defensive (mirrors Scenario A): keep this run out of the gated self.failfast.probe NDJSON
    # stream regardless of run_setup.bat's own HP_NDJSON auto-detection.
    Remove-Item Env:HP_NDJSON -ErrorAction SilentlyContinue

    $decExit = Invoke-Bootstrap -WorkDir $decDir -LogName '~checkpoint_decline.log'

    if ($null -eq $savedSkipPipreqsDec) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $savedSkipPipreqsDec }
    if ($null -eq $savedLaneDec) { Remove-Item Env:HP_CI_LANE -ErrorAction SilentlyContinue } else { $env:HP_CI_LANE = $savedLaneDec }
    if ($null -ne $savedCheckpointDec) { $env:HP_TEST_CHECKPOINT_ANSWER = $savedCheckpointDec }
    if ($null -ne $savedNdjsonDec) { $env:HP_NDJSON = $savedNdjsonDec }

    $decLogPath = Join-Path $decDir '~checkpoint_decline.log'
    $decLines = if (Test-Path $decLogPath) { Get-Content -LiteralPath $decLogPath -Encoding ASCII } else { @() }
    $decText = $decLines -join "`n"

    $decPromptShown = $decText -match [regex]::Escape('Verification finished -- see the Run Status above.')
    # Log line now carries a site tag, e.g. "checkpoint (exe): declined..." -- match either site.
    $decDeclined = $decText -match 'post-execution checkpoint \((exe|interpreter)\): declined \(run footprint stays at one execution\)\.'
    $decNotAccepted = -not ($decText -match 'post-execution checkpoint \((exe|interpreter)\): accepted')
    $decRunCount = ([regex]::Matches($decText, [regex]::Escape('Entry smoke exit=0'))).Count

    $declinePass = ($decExit -eq 0) -and $decPromptShown -and $decDeclined -and $decNotAccepted -and ($decRunCount -eq 1)
    $declineDetails = [ordered]@{
        exitCode     = $decExit
        promptShown  = $decPromptShown
        declined     = $decDeclined
        notAccepted  = $decNotAccepted
        runCount     = $decRunCount
        log          = '~checkpoint_decline.log'
    }
} catch {
    $declineDetails = [ordered]@{ error = $_.Exception.Message }
}

Write-NdjsonRow ([ordered]@{
    id      = 'self.checkpoint.decline'
    req     = 'REQ-018, REQ-018.8'
    pass    = $declinePass
    desc    = 'Post-execution checkpoint: default/HP_CI_LANE auto-decline keeps the run footprint at exactly one execution'
    details = $declineDetails
})

# --- Risk wording (README REQ-018.8): the prompt names the risk of running the program twice ---
# Judged on the console text of the two scenarios above. The accepted and the declined run print the same prompt, so
# both must say it, and each must have a prompt block at all.
$riskMarker   = 'running it twice could cause harm'
$riskHeading  = 'Verification finished -- see the Run Status above.'
$riskDecision = 'post-execution checkpoint \((exe|interpreter)\): (accepted|declined)'
$accBlock = Get-PromptBlock -Text $accText -Heading $riskHeading -Decision $riskDecision
$decBlock = Get-PromptBlock -Text $decText -Heading $riskHeading -Decision $riskDecision
$accNamesRisk = $accBlock.Contains($riskMarker)
$decNamesRisk = $decBlock.Contains($riskMarker)
$riskPass = ($accBlock.Length -gt 0) -and ($decBlock.Length -gt 0) -and $accNamesRisk -and $decNamesRisk
$riskShown = $accBlock
if ($riskShown.Length -gt 500) { $riskShown = $riskShown.Substring(0, 500) }
Write-NdjsonRow ([ordered]@{
    id      = 'self.checkpoint.risk'
    req     = 'REQ-018.8'
    pass    = $riskPass
    desc    = 'Post-execution checkpoint: the prompt tells the user that running the program twice could cause harm, in the accepted and the declined run'
    details = [ordered]@{
        acceptBlockFound  = ($accBlock.Length -gt 0)
        declineBlockFound = ($decBlock.Length -gt 0)
        acceptNamesRisk   = $accNamesRisk
        declineNamesRisk  = $decNamesRisk
        promptText        = $riskShown
    }
})

if (-not ($acceptPass -and $declinePass -and $riskPass)) { exit 1 }
exit 0
