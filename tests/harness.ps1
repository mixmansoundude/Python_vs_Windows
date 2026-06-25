# ASCII only
param()
$ErrorActionPreference = "Stop"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'
$OutDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjDir = Split-Path -Parent $OutDir
$BatchPath = Join-Path $ProjDir "run_setup.bat"
$ResultsPath = Join-Path $OutDir "~test-results.ndjson"
$SummaryPath = Join-Path $OutDir "~test-summary.txt"
$ExtractDir = Join-Path $OutDir "extracted"

function Invoke-Download {
  param(
    [string]$Url,
    [string]$Dest,
    [int]$Retries = 3
  )
  for ($i = 1; $i -le $Retries; $i++) {
    try {
      Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop
      if ((Test-Path $Dest) -and ((Get-Item $Dest).Length -gt 0)) {
        return $true
      }
      throw "Zero-length download: $Url"
    } catch {
      Write-Warning ("Download attempt {0} failed: {1}" -f $i, $_.Exception.Message)
      Start-Sleep -Seconds ([int][Math]::Min(3 * $i, 15))
    }
  }
  return $false
}

function Test-MinicondaUrl {
  param([string]$Url)
  $tmp = Join-Path $env:RUNNER_TEMP "conda_probe.tmp"
  if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  $ok = Invoke-Download -Url $Url -Dest $tmp -Retries 3
  if (-not $ok) {
    Write-Host ("[ERROR] Miniconda download probe failed for URL: {0}" -f $Url)
  }
  if (Test-Path $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  return $ok
}
$bootstrapRows = @()
if (Test-Path $ResultsPath) {
  foreach ($line in Get-Content -LiteralPath $ResultsPath -Encoding Ascii) {
    $trim = $line.Trim()
    if (-not $trim) { continue }
    try {
      $bootstrapRows += ($trim | ConvertFrom-Json)
    } catch {
      # derived requirement: tolerate legacy rows when harvesting helper status.
    }
  }
  Remove-Item -Force $ResultsPath
}
$entryHelperRow = $bootstrapRows | Where-Object { $_.id -eq 'helper.find_entry.syntax' } | Select-Object -First 1
if (!(Test-Path $BatchPath)) { Write-Host "run_setup.bat not found next to run_tests.bat." -ForegroundColor Red; exit 2 }
if ($env:HP_CACHE_CORRUPTED -eq '1') {
  Write-Host "::warning:: Cache corruption detected; harness tests skipped (HP_CACHE_CORRUPTED=1)"
  $rec = [ordered]@{ id='self.cache.corrupted'; pass=$true; desc='Cache corruption detected; harness tests skipped'; details=[ordered]@{ corrupted=$true } }
  Add-Content -Path $ResultsPath -Value ($rec | ConvertTo-Json -Compress -Depth 8) -Encoding Ascii
  exit 0
}
if (-not (Test-Path ".\.ci_bootstrap_marker")) {
  throw "CI bootstrap marker not found. Did run_setup.bat run?"
}
$StatusFile = Join-Path $ProjDir "~bootstrap.status.json"
if (-not (Test-Path $StatusFile)) {
  throw "Bootstrap status file ~bootstrap.status.json missing. Did run_setup.bat emit status?"
}
try {
  $BootstrapStatus = Get-Content -LiteralPath $StatusFile -Encoding ASCII -Raw | ConvertFrom-Json
} catch {
  throw "Bootstrap status JSON invalid: $($_.Exception.Message)"
}
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
function Write-Result { param($Id,$Desc,[bool]$Pass,$Details)
  $rec = [ordered]@{ id=$Id; pass=$Pass; desc=$Desc; details=$Details }
  $json = $rec | ConvertTo-Json -Compress -Depth 8
  Add-Content -Path $ResultsPath -Value $json -Encoding Ascii
}
if ($entryHelperRow) {
  Write-Result 'entry.helper.ok' 'Entry helper compile probe succeeded' ([bool]$entryHelperRow.pass) ([ordered]@{
    source = 'run_setup.ndjson'
    pass   = $entryHelperRow.pass
    details = $entryHelperRow.details
  })
}
$Lines = Get-Content -LiteralPath $BatchPath -Encoding ASCII
$AllText = [string]::Join("`n", $Lines)
if (Get-Command Get-FileHash -ErrorAction SilentlyContinue) {
  $sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $BatchPath).Hash
} else {
  $stream = [IO.File]::Open($BatchPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  try {
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    $hashBytes = $sha256.ComputeHash($stream)
  } finally {
    $stream.Dispose()
  }
  $builder = New-Object System.Text.StringBuilder
  foreach ($b in $hashBytes) {
    [void]$builder.AppendFormat("{0:X2}", $b)
  }
  $sha = $builder.ToString()
  Write-Host ("SHA256 (fallback): {0}" -f $sha)
}
Write-Result "file.hash" "SHA256 of run_setup.bat" $true @{ sha256 = $sha }
$allowedStates = @('ok','no_python_files','venv_env','degraded_env','cache_corrupted')
$stateOk = $allowedStates -contains $BootstrapStatus.state
Write-Result "bootstrap.state" "Bootstrap status state is ok/no_python_files/venv_env/degraded_env" $stateOk @{ state=$BootstrapStatus.state; exitCode=$BootstrapStatus.exitCode; pyFiles=$BootstrapStatus.pyFiles; allowed=$allowedStates }
Write-Result "bootstrap.exit" "Bootstrap exitCode is 0" ($BootstrapStatus.exitCode -eq 0) @{ exitCode=$BootstrapStatus.exitCode }
$payloads = @{}
foreach ($line in $Lines) {
  if ($line -match '^set "([A-Za-z0-9_]+)=([^\"]+)"$') {
    $name = $Matches[1]
    $value = $Matches[2]
    if ($name -like 'HP_*') {
      $payloads[$name] = $value
    }
  }
}
$emitMatches = [regex]::Matches($AllText, 'call\s+:emit_from_base64\s+"([^"]+)"\s+([A-Za-z0-9_]+)')
$emitted = @()
foreach ($match in $emitMatches) {
  $outFile = $match.Groups[1].Value
  $varName = $match.Groups[2].Value
  $dest = Join-Path $ExtractDir $outFile
  if ($payloads.ContainsKey($varName)) {
    try {
      $bytes = [Convert]::FromBase64String($payloads[$varName])
      [IO.File]::WriteAllBytes($dest, $bytes)
      $emitted += $outFile
      Write-Result "emit.extract" "Extracted $outFile from run_setup.bat payloads" $true @{ file=$outFile; var=$varName }
    } catch {
      Write-Result "emit.extract" "Failed to decode payload for $outFile ($varName)" $false @{ error=$_.Exception.Message }
    }
  } else {
    Write-Result "emit.extract" "Missing payload for $outFile ($varName)" $false @{ var=$varName }
  }
}
$hasDisable = ($Lines | Select-String -SimpleMatch "setlocal DisableDelayedExpansion").Count -gt 0
Write-Result "batch.delayed.off" "DisableDelayedExpansion present" $hasDisable @{}
$hasEnable = ($Lines | Select-String -SimpleMatch "EnableDelayedExpansion").Count -gt 0
Write-Result "batch.delayed.enable_absent" "EnableDelayedExpansion not present" (-not $hasEnable) @{}
$bangHits = @()
$inHere = $false
for ($i=0; $i -lt $Lines.Count; $i++) {
  $ln = $Lines[$i]
  if (-not $inHere -and $ln -match "@'") { $inHere = $true; continue }
  if ($inHere) {
    if ($ln -match "'@") { $inHere = $false }
    continue
  }
  if ($ln -match '^\s*(rem|echo)\b') { continue }
  if ($ln -like "*!*") { $bangHits += ("line {0}: {1}" -f ($i+1), $ln.Trim()) }
}
Write-Result "batch.bang.scan" "No '!' in live batch code lines" ($bangHits.Count -eq 0) @{ hits=$bangHits }
$badConda = @()
for ($i=0; $i -lt $Lines.Count; $i++) {
  $ln = $Lines[$i]
  if ($ln -match '^\s*call\s+(?!:)(?:(?:"?%[^%\s]*conda[^%\s]*%"?)|(?:"[^"]*conda\.bat"|[^\s]*conda\.bat))\s+(create|install)\b') {
    $window = ($ln + " " + ($(if ($i+1 -lt $Lines.Count) { $Lines[$i+1] } else { "" })) + " " + ($(if ($i+2 -lt $Lines.Count) { $Lines[$i+2] } else { "" })))
    if ($window -notmatch "--override-channels" -or $window -notmatch "-c\s+conda-forge") {
      $badConda += ("line {0}: {1}" -f ($i+1), $ln.Trim())
    }
  }
}
Write-Result "conda.channels" "All conda create/install use --override-channels -c conda-forge" ($badConda.Count -eq 0) @{ misses=$badConda }
$expectedPipreqs = @('pipreqs.pipreqs', '.', '--force', '--mode', 'compat', '--savepath', 'requirements.auto.txt')
# Prefer the actual Python -m invocation; fall back to logged command text when
# the run only records the pipreqs CLI (e.g., bootstrap log summaries).
$pipreqsLine = $Lines | Where-Object { $_ -match '\-m\s+pipreqs\.pipreqs\b' -and $_ -match '--savepath' } | Select-Object -First 1
$pipreqsSource = 'script'
if (-not $pipreqsLine) {
  $pipreqsLine = $Lines | Where-Object { $_ -match 'pipreqs\.pipreqs\s+\.\s+--force\s+--mode\s+compat\s+--savepath' } | Select-Object -First 1
  if ($pipreqsLine) { $pipreqsSource = 'log' } else { $pipreqsSource = 'missing' }
}
$observedTokens = @()
if ($pipreqsLine) {
  $tail = $pipreqsLine.Substring($pipreqsLine.IndexOf('pipreqs'))
  $tail = ($tail -replace '\s+>>.*$', '').Trim()
  foreach ($m in [regex]::Matches($tail, '("[^"]*"|[^\s]+)')) {
    $observedTokens += $m.Value
  }
}
$normalized = @()
foreach ($token in $observedTokens) {
  switch ($token) {
    '"%HP_PIPREQS_TARGET%"' { $normalized += 'requirements.auto.txt'; continue }
    '%HP_PIPREQS_TARGET%'   { $normalized += 'requirements.auto.txt'; continue }
    default { $normalized += $token }
  }
}
$pipreqsOk = $false
$expectedPrefixCount = $expectedPipreqs.Count - 1
if ($normalized.Count -ge $expectedPipreqs.Count) {
  $pipreqsOk = $true
  for ($i = 0; $i -lt $expectedPrefixCount; $i++) {
    if ($normalized[$i] -ne $expectedPipreqs[$i]) {
      $pipreqsOk = $false
      break
    }
  }
}
$expectedCommand = $expectedPipreqs -join ' '
$observedCommand = if ($normalized.Count -gt 0) { $normalized -join ' ' } else { '<missing>' }
$details = [ordered]@{
  expected = $expectedPipreqs
  observed = $normalized
  rawTokens = $observedTokens
  line = if ($pipreqsLine) { $pipreqsLine.Trim() } else { '<pipreqs invocation not found>' }
  source = $pipreqsSource
  hasModulePrefix = ($pipreqsLine -match '\-m\s+pipreqs\.pipreqs\b')
  hasIgnore = ($normalized -contains '--ignore')
  extraArgs = if ($normalized.Count -gt $expectedPipreqs.Count) { $normalized[$expectedPipreqs.Count..($normalized.Count-1)] } else { @() }
  message = "expected: $expectedCommand | observed: $observedCommand"
}
Write-Result 'pipreqs.flags' 'pipreqs argv matches canonical flags' $pipreqsOk $details
$hasPyInst = ($AllText -match "pyinstaller\s+-y\s+--onefile.*--name\s+""%ENVNAME%""")
Write-Result "pyi.onefile" "PyInstaller one-file named %ENVNAME%" $hasPyInst @{} 
$hasRotate = ($AllText -match "Length -gt 10485760")
Write-Result "log.rotate" "Log rotation ~10MB present" $hasRotate @{} 
$tildeCount = ([regex]::Matches($AllText, "~setup\.log|~reqs_conda\.txt|~pipreqs\.diff\.txt|~entry\.txt|~run\.err\.txt")).Count
Write-Result "tilde.naming" "Tilde prefix used for crashable artifacts" ($tildeCount -ge 3) @{ count=$tildeCount }
$visa = ($AllText -match "pyvisa" -or $AllText -match "import[ ]*visa")
Write-Result "visa.detect" "NI-VISA import detection present" $visa @{} 
$need = @("~detect_python.py","~prep_requirements.py","~print_pyver.py","~find_entry.py","~env_state.py","~dep_check.py")
$missing = $need | Where-Object { $_ -notin $emitted }
Write-Result "emit.helpers" "All helper scripts extractable from run_setup.bat" ($missing.Count -eq 0) @{ missing=$missing }
$esPath = Join-Path $ExtractDir "~env_state.py"
$esHasWrite = $false
if (Test-Path $esPath) { $esHasWrite = ((Get-Content $esPath -Encoding ASCII) | Select-String -SimpleMatch 'write_state').Count -gt 0 }
Write-Result "env.state.write" "env_state has write_state function" $esHasWrite @{}
$dcPath = Join-Path $ExtractDir "~dep_check.py"
$dcHasLock = $false
if (Test-Path $dcPath) { $dcHasLock = ((Get-Content $dcPath -Encoding ASCII) | Select-String -SimpleMatch 'parse_lock').Count -gt 0 }
Write-Result "dep.check.parse_lock" "dep_check has parse_lock function" $dcHasLock @{}
$dpPath = Join-Path $ExtractDir "~detect_python.py"
$dpHasCompat = $false
if (Test-Path $dpPath) { $dpHasCompat = ((Get-Content $dpPath -Encoding ASCII) | Select-String -SimpleMatch 'op == "~="').Count -gt 0 }
Write-Result "dp.compat" "detect_python handles ~= in requires-python" $dpHasCompat @{} 
$prPath = Join-Path $ExtractDir "~prep_requirements.py"
$fmtOK = $false
if (Test-Path $prPath) {
  $txt = Get-Content $prPath -Encoding ASCII
  $fmtOK = ($txt | Select-String -SimpleMatch 'return [f"{name} " + ",".join(ops)] if ops else [name]').Count -gt 0
}
Write-Result "prep.multi.constraint" "prep_requirements formats multi-constraints as name >=X,<Y" $fmtOK @{} 
$paren = 0; $imbalance = @()
for ($k=0; $k -lt $Lines.Count; $k++) {
  $ln = $Lines[$k]
  $open = ([regex]::Matches($ln, "\(")).Count
  $close = ([regex]::Matches($ln, "\)")).Count
  $paren += ($open - $close)
  if ($paren -lt 0) { $imbalance += ("line {0}: {1} (paren={2})" -f ($k+1), $ln.Trim(), $paren) }
}
Write-Result "batch.paren.balance" "No negative parenthesis balance while scanning" ($imbalance.Count -eq 0) @{ issues=$imbalance }
$pauseHits = @(); $ungatedPauses = @()
for ($k = 0; $k -lt $Lines.Count; $k++) {
  if ($Lines[$k] -match '^\s*pause\s*$') {
    $pauseHits += $k
    $start = [Math]::Max(0, $k - 2)
    $preceding = if ($k -ge 1) { $Lines[$start..($k-1)] -join ' ' } else { '' }
    if ($preceding -notmatch 'not defined HP_CI_LANE') {
      $ungatedPauses += ("line {0}: {1}" -f ($k+1), $Lines[$k].Trim())
    }
  }
}
$pauseGated = ($pauseHits.Count -ge 1) -and ($ungatedPauses.Count -eq 0)
Write-Result 'batch.ux.pause.gated' 'REQ-016: all pause statements gated on HP_CI_LANE' $pauseGated @{ pauseCount = $pauseHits.Count; ungated = $ungatedPauses }
$envLine = ($AllText -match 'for %%I in \("%CD%"\) do set "ENVNAME=%%~nI"')
Write-Result "env.foldername" "Env name equals folder name" $envLine @{} 
$instPathOk = ($AllText -match "%PUBLIC%\\Documents\\Miniconda3")
Write-Result "conda.path" "Miniconda path is %PUBLIC%\Documents\Miniconda3" $instPathOk @{}
$hasVersionMetadata = ($AllText -match '\[VERSION_METADATA\]')
Write-Result "version.metadata" "VERSION_METADATA block present in run_setup.bat" $hasVersionMetadata @{}
$hasHostOS = ($AllText -match 'Host OS:')
Write-Result "host.env.os" "Host OS diagnostic print present" $hasHostOS @{}
$hasHostPS = ($AllText -match 'Host PowerShell:')
Write-Result "host.env.ps" "Host PowerShell diagnostic print present" $hasHostPS @{}
$hasHostPython = ($AllText -match 'Host Python:')
Write-Result "host.env.python" "Host Python diagnostic print present" $hasHostPython @{}
$hasReq010 = ($AllText -match 'set\s+"PYTHONPATH="') -and ($AllText -match 'set\s+"PYTHONHOME="')
Write-Result "batch.req010.isolation" "REQ-010: PYTHONPATH and PYTHONHOME cleared at script start" $hasReq010 @{}
$hasReq011 = ($AllText -match 'REQ-011') -and ($AllText -match '%~dp1')
Write-Result "batch.req011.dircheck" "REQ-011: directory integrity check present in run_setup.bat" $hasReq011 @{}
$req012Patterns = @('HP_SKIP_ENTRY_SMOKE set; skipping entry-script smoke', 'HP_SKIP_EXE_SMOKERUN set; skipping EXE verification')
$hasReq012 = ($req012Patterns | Where-Object { -not ($AllText -match $_) }).Count -eq 0
Write-Result "batch.req012.skiphooks" "REQ-012: HP_SKIP_ENTRY_SMOKE and HP_SKIP_EXE_SMOKERUN execution-skip log lines present in run_setup.bat" $hasReq012 @{}
$req009Patterns = @('\[BOOT\] REQ-009.*Selected.*UV', '\[BOOT\] REQ-009.*Selected.*Conda', '\[BOOT\] REQ-009.*Selected.*Local venv', '\[BOOT\] REQ-009.*Selected.*System Python')
$hasReq009 = ($req009Patterns | Where-Object { -not ($AllText -match $_) }).Count -eq 0
Write-Result "batch.req009.provider_logs" "REQ-009: all four provider log lines present in run_setup.bat" $hasReq009 @{}
$venvGuardFound = $AllText -match [regex]::Escape('"%HP_ALLOW_VENV_FALLBACK%"=="1"')
Write-Result "batch.req009.venv_unconditional" "REQ-009: venv fallback not guarded by HP_ALLOW_VENV_FALLBACK (fallback is unconditional)" (-not $venvGuardFound) @{ guardFound = $venvGuardFound }
$cascadeDetectPatterns = @(':warnfix_cascade_detect', 'cascade candidate detected', 'HP_TEST_FORCE_WARNFIX_UNRESOLVED', 'HP_CASCADE_CANDIDATE')
$hasCascadeDetect = ($cascadeDetectPatterns | Where-Object { -not ($AllText -match [regex]::Escape($_)) }).Count -eq 0
Write-Result "batch.req009.cascade_detect" "REQ-009/REQ-005.10: warnfix cascade-candidate detection (subroutine + log + test flag) present in run_setup.bat" $hasCascadeDetect @{}
$cascadeConsentPatterns = @(':cascade_consent_gate', 'cascade consent: accepted', 'cascade consent: declined', 'HP_TEST_CASCADE_ANSWER')
$hasCascadeConsent = ($cascadeConsentPatterns | Where-Object { -not ($AllText -match [regex]::Escape($_)) }).Count -eq 0
Write-Result "batch.req009.cascade_consent" "REQ-009/REQ-005.10: cascade consent gate (subroutine + accept/decline logs + test flag) present in run_setup.bat" $hasCascadeConsent @{}
# REQ-009/REQ-005.10 slice 3: cascade EXECUTION scaffolding -- dispatch label, the priority
# uv->conda tier, per-tier no-retry guards, the on-demand Miniconda acquisition, and the
# approval-gated dispatch on the main line. All five must be present in run_setup.bat.
$cascadeExecPatterns = @(':provider_cascade', ':cascade_from_uv', 'cascading provider uv to conda', 'HP_CASCADE_TRIED_UV', ':cascade_acquire_conda', 'if defined HP_CASCADE_APPROVED goto :provider_cascade')
$hasCascadeExec = ($cascadeExecPatterns | Where-Object { -not ($AllText -match [regex]::Escape($_)) }).Count -eq 0
Write-Result "batch.req009.cascade_exec" "REQ-009/REQ-005.10: provider cascade execution (dispatch + uv->conda tier + per-tier no-retry guards + on-demand conda acquire) present in run_setup.bat" $hasCascadeExec @{}
$hasReq002Entry = $AllText -match '\[BOOT\] REQ-002.*Entry selected'
Write-Result "batch.req002.entry_log" "REQ-002: entry selection log line present in run_setup.bat" $hasReq002Entry @{}
$feMatch = [regex]::Match($AllText, 'set "HP_FIND_ENTRY=([A-Za-z0-9+/=]+)"')
if ($feMatch.Success) {
  $feDecoded = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($feMatch.Groups[1].Value))
  $hasReq002Payload = $feDecoded -match '\[BOOT\] REQ-002:'
} else { $hasReq002Payload = $false }
Write-Result "batch.req002.findentry_payload" "REQ-002: HP_FIND_ENTRY payload has decision-chain logging" $hasReq002Payload @{}
$hasCli = $feMatch.Success -and ($feDecoded -match '"cli\.py"')
Write-Result "batch.req002.findentry_cli" "REQ-002: HP_FIND_ENTRY PREFERRED includes cli.py" $hasCli @{}
$hasRun = $feMatch.Success -and ($feDecoded -match '"run\.py"')
Write-Result "batch.req002.findentry_run" "REQ-002: HP_FIND_ENTRY PREFERRED includes run.py" $hasRun @{}
$hasPickerSub    = $AllText -match ':pick_entry_interactive'
$hasNoinputGuard = ($AllText -match 'if\s+defined\s+NOINPUT') -and ($AllText -match 'if\s+defined\s+HP_NONINTERACTIVE')
$hasPickerForce  = $AllText -match 'HP_TEST_FORCE_PICKER'
$hasPickerLog    = $AllText.Contains('[INFO] REQ-002: Picker entry selected:')
$pickerOk = $hasPickerSub -and $hasNoinputGuard -and $hasPickerForce -and $hasPickerLog
Write-Result 'batch.req002.picker' 'REQ-002: interactive picker subroutine, non-interactive guards, test-force flag, and resolution log present' $pickerOk @{
    hasPickerSub    = $hasPickerSub
    hasNoinputGuard = $hasNoinputGuard
    hasPickerForce  = $hasPickerForce
    hasPickerLog    = $hasPickerLog
}
$hasDiffTrace = ($Lines | Select-String -SimpleMatch 'REQ-005.5').Count -gt 0
Write-Result "batch.dep.diff.trace" "REQ-005.5: dependency diff log line present in run_setup.bat source" $hasDiffTrace @{}
$hasCondaWarmup = ($AllText -match 'if defined HP_CONDA_JUST_INSTALLED\s+if defined CONDA_BAT') -and ($AllText -match 'call\s+"%CONDA_BAT%"\s+info\s+>nul')
Write-Result "batch.conda.warmup" "REQ-020: fresh-install conda warm-up (HP_CONDA_JUST_INSTALLED guard) present in run_setup.bat" $hasCondaWarmup @{}
$req013Patterns = @('REQ-013: Connectivity check: internet reachable', 'REQ-013: Offline mode: skipping', 'HP_TEST_OFFLINE')
$hasReq013 = ($req013Patterns | Where-Object { -not ($AllText -match $_) }).Count -eq 0
Write-Result 'batch.req013.connectivity' 'REQ-013: connectivity guard log lines and HP_TEST_OFFLINE CI flag present in run_setup.bat' $hasReq013 @{}
$req014Patterns = @('REQ-014: System Python fallback aborted', 'REQ-014: System Python consent: user accepted', 'HP_TEST_FORCE_CONSENT_CHECK', 'HP_TEST_SYSCON_ANSWER')
$hasReq014 = ($req014Patterns | Where-Object { -not ($AllText -match $_) }).Count -eq 0
Write-Result 'batch.req014.consent' 'REQ-014: system Python consent gate log lines + HP_TEST_FORCE_CONSENT_CHECK/HP_TEST_SYSCON_ANSWER CI flags present in run_setup.bat' $hasReq014 @{}
# Configuration-presence check (NOT a runtime assertion): confirms the orchestration layer
# pins uv to managed-only CPython so it cannot pick up an ambient/system interpreter. The
# runtime proof that this is actually honored lives in self.uv.managed.interpreter
# (tests/selfapps_envsmoke.ps1). See docs/agent-lessons-learned.md.
$hasUvPref = ($AllText -match 'set\s+"UV_PYTHON_PREFERENCE=only-managed"')
Write-Result 'uv.python.preference.configured' 'config: run_setup.bat sets UV_PYTHON_PREFERENCE=only-managed (managed-only orchestration; no ambient Python)' $hasUvPref @{}
$warnGatePatterns = @('if not defined DEP_SOURCE (', 'Dependencies were auto-detected (pipreqs)', 'pipreqs augmenting')
$hasWarnGate = ($warnGatePatterns | Where-Object { -not ($AllText -match [regex]::Escape($_)) }).Count -eq 0
Write-Result 'batch.req005.warn_gate' 'REQ-005: pipreqs auto-detect WARN gated on DEP_SOURCE unset (suppressed when requirements.txt/pyproject present)' $hasWarnGate @{}
$results = Get-Content -LiteralPath $ResultsPath -Encoding ASCII | ForEach-Object { $_ | ConvertFrom-Json }
$fail = @($results | Where-Object { -not $_.pass })
$pass = @($results | Where-Object { $_.pass })
$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("=== Static Test Summary ===")
$null = $sb.AppendLine("run_setup.bat sha256: " + $sha.ToLower())
$null = $sb.AppendLine("PASS: " + $pass.Count + "    FAIL: " + $fail.Count)
if ($BootstrapStatus.state -eq 'no_python_files') {
  $null = $sb.AppendLine("Bootstrap reported no Python files; environment bootstrap skipped.")
}
if ($fail.Count -gt 0) { $null = $sb.AppendLine("---- Failures ----"); foreach ($f in $fail) { $null = $sb.AppendLine(("* " + $f.id + " :: " + $f.desc)) } }
$null = $sb.AppendLine("Artifacts:")
$null = $sb.AppendLine("  tests\~test-results.ndjson")
$null = $sb.AppendLine("  tests\extracted\ (helper sources)")
[IO.File]::WriteAllText($SummaryPath, $sb.ToString(), [Text.Encoding]::ASCII)
if ($fail.Count -gt 0) { exit 1 } else { exit 0 }
