# ASCII only
param()
$ErrorActionPreference = 'Stop'
$TestsDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RepoDir = Split-Path -Parent $TestsDir
$BatchPath = Join-Path $RepoDir 'run_setup.bat'
if (-not (Test-Path $BatchPath)) {
  throw "run_setup.bat not found for self-tests"
}
$publicRoot = [Environment]::GetEnvironmentVariable('PUBLIC')
if (-not $publicRoot) {
  throw "PUBLIC environment variable not set"
}
$MiniRoot = Join-Path $publicRoot 'Documents\Miniconda3'
$emptyDir = Join-Path $TestsDir '~selftest_empty'
$stubDir = Join-Path $TestsDir '~selftest_stub'
$summaryPath = Join-Path $TestsDir '~selftest-summary.txt'
if (Test-Path $summaryPath) { Remove-Item -Force $summaryPath }
$nd   = Join-Path $TestsDir '~test-results.ndjson'
$ciNd = Join-Path $RepoDir  'ci_test_results.ndjson'
if (-not (Test-Path $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

$script:AnyRowFailed = $false
function Write-NdjsonRow {
    param([hashtable]$Row)
    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    # derived requirement: this file has no other central point where every one of its ~40+
    # scenarios converges -- every scenario calls this function, so tracking pass/fail here
    # (rather than at each of the ~40+ individual call sites) is what lets the script's own
    # exit code (see end of file) actually reflect whether anything failed, instead of always
    # returning PowerShell's default 0 regardless of scenario outcomes.
    if ($Row.ContainsKey('pass') -and $Row['pass'] -eq $false) { $script:AnyRowFailed = $true }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('=== Bootstrap Self-tests ===')
function Invoke-Setup {
  param(
    [string]$WorkDir,
    [string]$LogName,
    [scriptblock]$Prepare
  )
  if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  Copy-Item -Path $BatchPath -Destination $WorkDir -Force
  if ($Prepare) { & $Prepare }
  Push-Location $WorkDir
  try {
    cmd /c "call run_setup.bat > $LogName 2>&1"
    return $LASTEXITCODE
  } finally {
    Pop-Location
  }
}
$emptyExit = Invoke-Setup -WorkDir $emptyDir -LogName '~empty_bootstrap.log'
if ($emptyExit -ne 0) {
  throw "Empty-folder bootstrap failed with exit code $emptyExit"
}
$emptyStatusPath = Join-Path $emptyDir '~bootstrap.status.json'
if (-not (Test-Path $emptyStatusPath)) {
  throw "Empty-folder bootstrap missing ~bootstrap.status.json"
}
$emptyStatus = Get-Content -LiteralPath $emptyStatusPath -Encoding ASCII -Raw | ConvertFrom-Json
if ($emptyStatus.state -ne 'no_python_files') {
  throw "Expected no_python_files state for empty-folder bootstrap"
}
if ($emptyStatus.pyFiles -ne 0) {
  throw "Expected pyFiles == 0 for empty-folder bootstrap"
}
if ($emptyStatus.exitCode -ne 0) {
  throw "Expected exitCode 0 for empty-folder bootstrap"
}
$summary.Add('empty-folder bootstrap: PASS')

# CLAUDE.md Item 32: zero real .py files but a .py.txt (hidden-extension) candidate present --
# the hint should fire, and behavior (state/exit code) must stay identical to the plain
# empty-folder case above. The candidate's name itself contains '&' -- a live cmd.exe operator
# once substituted into an unquoted echo/:log line -- specifically to prove the hint's own log
# lines never echo the matched filename (see :check_hidden_ext_hint's own header comment in
# run_setup.bat). Seeded via Invoke-Setup's -Prepare hook, which runs AFTER the function's own
# workspace wipe/recreate/batch-copy -- seeding it before calling Invoke-Setup would have the
# file deleted by that same wipe before run_setup.bat ever saw it.
$pytxtDir = Join-Path $TestsDir '~selftest_pytxt_hint'
$pytxtCandidateName = 'AT&T report.py.txt'
$pytxtExit = Invoke-Setup -WorkDir $pytxtDir -LogName '~pytxt_bootstrap.log' -Prepare {
  Set-Content -LiteralPath (Join-Path $pytxtDir $pytxtCandidateName) -Value 'print("hello")' -Encoding ASCII
}
$pytxtStatusPath = Join-Path $pytxtDir '~bootstrap.status.json'
$pytxtStatus = if (Test-Path $pytxtStatusPath) { Get-Content -LiteralPath $pytxtStatusPath -Encoding ASCII -Raw | ConvertFrom-Json } else { $null }
$pytxtLogPath = Join-Path $pytxtDir '~pytxt_bootstrap.log'
$pytxtLog = if (Test-Path $pytxtLogPath) { Get-Content -LiteralPath $pytxtLogPath -Raw } else { '' }
# :check_hidden_ext_hint writes to BOTH the console (captured above) and run_setup.bat's own
# internal %LOG% stream (~setup.log) -- check both, so a leak into either stream is caught.
$pytxtSetupLogPath = Join-Path $pytxtDir '~setup.log'
$pytxtSetupLog = if (Test-Path $pytxtSetupLogPath) { Get-Content -LiteralPath $pytxtSetupLogPath -Raw } else { '' }
$pytxtHintFound = $pytxtLog -match [regex]::Escape('Hint: found a file ending in .py.txt')
$pytxtNameLeakedConsole = $pytxtLog -match [regex]::Escape($pytxtCandidateName)
$pytxtNameLeakedSetupLog = $pytxtSetupLog -match [regex]::Escape($pytxtCandidateName)
$pytxtNameLeaked = $pytxtNameLeakedConsole -or $pytxtNameLeakedSetupLog
$pytxtStatusExitOk = $pytxtStatus -and ($pytxtStatus.exitCode -eq 0)
$pytxtPass = ($pytxtExit -eq 0) -and $pytxtStatus -and ($pytxtStatus.state -eq 'no_python_files') -and ($pytxtStatus.pyFiles -eq 0) -and $pytxtStatusExitOk -and $pytxtHintFound -and (-not $pytxtNameLeaked)
Write-NdjsonRow ([ordered]@{
  id = 'self.empty_repo.pytxt_hint'
  pass = $pytxtPass
  desc = 'Item 32: zero .py files but a .py.txt candidate present -- hint fires, state/exit unchanged, filename never echoed'
  details = [ordered]@{
    exitCode = $pytxtExit
    statusExitCode = $(if ($pytxtStatus) { $pytxtStatus.exitCode } else { $null })
    state = $(if ($pytxtStatus) { $pytxtStatus.state } else { $null })
    pyFiles = $(if ($pytxtStatus) { $pytxtStatus.pyFiles } else { $null })
    hintFound = $pytxtHintFound
    nameLeakedConsole = $pytxtNameLeakedConsole
    nameLeakedSetupLog = $pytxtNameLeakedSetupLog
  }
})
if (-not $pytxtPass) {
  throw "py.txt hidden-extension hint scenario failed (exit=$pytxtExit statusExit=$($pytxtStatus.exitCode) state=$($pytxtStatus.state) hintFound=$pytxtHintFound nameLeakedConsole=$pytxtNameLeakedConsole nameLeakedSetupLog=$pytxtNameLeakedSetupLog)"
}
$summary.Add('py.txt hidden-extension hint: PASS')

# CLAUDE.md Item 43: zero top-level .py files, but a .py file sits one folder down (a
# src/-style layout unzipped with run_setup.bat dropped at the root). The hint should fire,
# and behavior (state/exit code) must stay identical to the plain empty-folder case above.
# The subfolder's name itself contains '&' -- a live cmd.exe operator once substituted into
# an unquoted echo/:log line -- specifically to prove the hint's own log lines never echo the
# matched subfolder name (see :check_subfolder_hint's own header comment in run_setup.bat).
$subfolderDir = Join-Path $TestsDir '~selftest_subfolder_hint'
$subfolderCandidateName = 'AT&T src'
$subfolderExit = Invoke-Setup -WorkDir $subfolderDir -LogName '~subfolder_bootstrap.log' -Prepare {
  $candidatePath = Join-Path $subfolderDir $subfolderCandidateName
  New-Item -ItemType Directory -Force -Path $candidatePath | Out-Null
  Set-Content -LiteralPath (Join-Path $candidatePath 'main.py') -Value 'print("hello")' -Encoding ASCII
}
$subfolderStatusPath = Join-Path $subfolderDir '~bootstrap.status.json'
$subfolderStatus = if (Test-Path $subfolderStatusPath) { Get-Content -LiteralPath $subfolderStatusPath -Encoding ASCII -Raw | ConvertFrom-Json } else { $null }
$subfolderLogPath = Join-Path $subfolderDir '~subfolder_bootstrap.log'
$subfolderLog = if (Test-Path $subfolderLogPath) { Get-Content -LiteralPath $subfolderLogPath -Raw } else { '' }
# :check_subfolder_hint writes to BOTH the console (captured above) and run_setup.bat's own
# internal %LOG% stream (~setup.log) -- check both, so a leak into either stream is caught.
$subfolderSetupLogPath = Join-Path $subfolderDir '~setup.log'
$subfolderSetupLog = if (Test-Path $subfolderSetupLogPath) { Get-Content -LiteralPath $subfolderSetupLogPath -Raw } else { '' }
$subfolderHintFound = $subfolderLog -match [regex]::Escape('Hint: found .py file(s) in a subfolder')
$subfolderNameLeakedConsole = $subfolderLog -match [regex]::Escape($subfolderCandidateName)
$subfolderNameLeakedSetupLog = $subfolderSetupLog -match [regex]::Escape($subfolderCandidateName)
$subfolderNameLeaked = $subfolderNameLeakedConsole -or $subfolderNameLeakedSetupLog
$subfolderStatusExitOk = $subfolderStatus -and ($subfolderStatus.exitCode -eq 0)
$subfolderPass = ($subfolderExit -eq 0) -and $subfolderStatus -and ($subfolderStatus.state -eq 'no_python_files') -and ($subfolderStatus.pyFiles -eq 0) -and $subfolderStatusExitOk -and $subfolderHintFound -and (-not $subfolderNameLeaked)
Write-NdjsonRow ([ordered]@{
  id = 'self.empty_repo.subfolder_hint'
  pass = $subfolderPass
  desc = 'Item 43: zero top-level .py files but a subfolder holds one -- hint fires, state/exit unchanged, subfolder name never echoed'
  details = [ordered]@{
    exitCode = $subfolderExit
    statusExitCode = $(if ($subfolderStatus) { $subfolderStatus.exitCode } else { $null })
    state = $(if ($subfolderStatus) { $subfolderStatus.state } else { $null })
    pyFiles = $(if ($subfolderStatus) { $subfolderStatus.pyFiles } else { $null })
    hintFound = $subfolderHintFound
    nameLeakedConsole = $subfolderNameLeakedConsole
    nameLeakedSetupLog = $subfolderNameLeakedSetupLog
  }
})
if (-not $subfolderPass) {
  throw "subfolder-hint scenario failed (exit=$subfolderExit statusExit=$($subfolderStatus.exitCode) state=$($subfolderStatus.state) hintFound=$subfolderHintFound nameLeakedConsole=$subfolderNameLeakedConsole nameLeakedSetupLog=$subfolderNameLeakedSetupLog)"
}
$summary.Add('subfolder Python-file hint: PASS')

# CLAUDE.md Item 43 negative coverage (CodeRabbit PR #444 review): :check_subfolder_hint must
# NOT fire for any of its own exclusions, and must not be fooled by a directory whose NAME ends
# in .py (a real bug caught by review -- the inner scan originally lacked /a-d, so a directory
# literally named "helpers.py" was misread as a Python FILE). One bootstrap run covers all five
# negative shapes at once: dist/build/tilde/dot-prefixed subfolders each holding a genuine .py
# file (all excluded by name/prefix, never reached), plus a subfolder holding only a DIRECTORY
# named nested.py with no real .py file inside it anywhere (proves /a-d works).
$subfolderNegDir = Join-Path $TestsDir '~selftest_subfolder_hint_neg'
$subfolderNegExit = Invoke-Setup -WorkDir $subfolderNegDir -LogName '~subfolder_neg_bootstrap.log' -Prepare {
  New-Item -ItemType Directory -Force -Path (Join-Path $subfolderNegDir 'dist') | Out-Null
  Set-Content -LiteralPath (Join-Path $subfolderNegDir 'dist\decoy.py') -Value 'print("hello")' -Encoding ASCII
  New-Item -ItemType Directory -Force -Path (Join-Path $subfolderNegDir 'build') | Out-Null
  Set-Content -LiteralPath (Join-Path $subfolderNegDir 'build\decoy.py') -Value 'print("hello")' -Encoding ASCII
  New-Item -ItemType Directory -Force -Path (Join-Path $subfolderNegDir '~scratch') | Out-Null
  Set-Content -LiteralPath (Join-Path $subfolderNegDir '~scratch\decoy.py') -Value 'print("hello")' -Encoding ASCII
  New-Item -ItemType Directory -Force -Path (Join-Path $subfolderNegDir '.hidden') | Out-Null
  Set-Content -LiteralPath (Join-Path $subfolderNegDir '.hidden\decoy.py') -Value 'print("hello")' -Encoding ASCII
  New-Item -ItemType Directory -Force -Path (Join-Path $subfolderNegDir 'pkg\nested.py') | Out-Null
}
$subfolderNegStatusPath = Join-Path $subfolderNegDir '~bootstrap.status.json'
$subfolderNegStatus = if (Test-Path $subfolderNegStatusPath) { Get-Content -LiteralPath $subfolderNegStatusPath -Encoding ASCII -Raw | ConvertFrom-Json } else { $null }
$subfolderNegLogPath = Join-Path $subfolderNegDir '~subfolder_neg_bootstrap.log'
$subfolderNegLog = if (Test-Path $subfolderNegLogPath) { Get-Content -LiteralPath $subfolderNegLogPath -Raw } else { '' }
$subfolderNegHintAbsent = -not ($subfolderNegLog -match [regex]::Escape('Hint: found .py file(s) in a subfolder'))
$subfolderNegStatusExitOk = $subfolderNegStatus -and ($subfolderNegStatus.exitCode -eq 0)
$subfolderNegPass = ($subfolderNegExit -eq 0) -and $subfolderNegStatus -and ($subfolderNegStatus.state -eq 'no_python_files') -and ($subfolderNegStatus.pyFiles -eq 0) -and $subfolderNegStatusExitOk -and $subfolderNegHintAbsent
Write-NdjsonRow ([ordered]@{
  id = 'self.empty_repo.subfolder_hint_neg'
  pass = $subfolderNegPass
  desc = 'Item 43: dist/build/tilde/dot-prefixed subfolders and a *.py-named directory (no real .py file) never trigger the subfolder hint'
  details = [ordered]@{
    exitCode = $subfolderNegExit
    statusExitCode = $(if ($subfolderNegStatus) { $subfolderNegStatus.exitCode } else { $null })
    state = $(if ($subfolderNegStatus) { $subfolderNegStatus.state } else { $null })
    pyFiles = $(if ($subfolderNegStatus) { $subfolderNegStatus.pyFiles } else { $null })
    hintAbsent = $subfolderNegHintAbsent
  }
})
if (-not $subfolderNegPass) {
  throw "subfolder-hint negative-coverage scenario failed (exit=$subfolderNegExit statusExit=$($subfolderNegStatus.exitCode) state=$($subfolderNegStatus.state) hintAbsent=$subfolderNegHintAbsent)"
}
$summary.Add('subfolder Python-file hint negative coverage: PASS')

# CLAUDE.md Item 43 (CodeRabbit PR #444 review round 2): :check_subfolder_hint stages the
# candidate subfolder name into HP_SFC via a plain `set` BEFORE calling
# :subfolder_hint_check_one, never as a `call` argument -- `call` re-scans its own line a
# SECOND time before dispatching (see docs/agent-lessons-learned.md's "call triggers cmd.exe's
# own second expansion pass"), so a subfolder literally named with a %-shaped substring (e.g.
# containing "%PATH%") passed as a call argument would have that text re-expanded into the
# REAL PATH variable's value, corrupting the scan target. This subfolder's name is chosen to
# contain a real, always-defined environment variable reference shape to prove the fix
# actually prevents that corruption -- if it regressed, the scan would target a nonexistent
# path (the expanded PATH value) instead of the real subfolder, and the hint would never fire.
$subfolderPctDir = Join-Path $TestsDir '~selftest_subfolder_hint_pct'
$subfolderPctCandidateName = 'has%PATH%in-name'
$subfolderPctExit = Invoke-Setup -WorkDir $subfolderPctDir -LogName '~subfolder_pct_bootstrap.log' -Prepare {
  $candidatePath = Join-Path $subfolderPctDir $subfolderPctCandidateName
  New-Item -ItemType Directory -Force -Path $candidatePath | Out-Null
  Set-Content -LiteralPath (Join-Path $candidatePath 'main.py') -Value 'print("hello")' -Encoding ASCII
}
$subfolderPctStatusPath = Join-Path $subfolderPctDir '~bootstrap.status.json'
$subfolderPctStatus = if (Test-Path $subfolderPctStatusPath) { Get-Content -LiteralPath $subfolderPctStatusPath -Encoding ASCII -Raw | ConvertFrom-Json } else { $null }
$subfolderPctLogPath = Join-Path $subfolderPctDir '~subfolder_pct_bootstrap.log'
$subfolderPctLog = if (Test-Path $subfolderPctLogPath) { Get-Content -LiteralPath $subfolderPctLogPath -Raw } else { '' }
$subfolderPctHintFound = $subfolderPctLog -match [regex]::Escape('Hint: found .py file(s) in a subfolder')
$subfolderPctStatusExitOk = $subfolderPctStatus -and ($subfolderPctStatus.exitCode -eq 0)
$subfolderPctPass = ($subfolderPctExit -eq 0) -and $subfolderPctStatus -and ($subfolderPctStatus.state -eq 'no_python_files') -and ($subfolderPctStatus.pyFiles -eq 0) -and $subfolderPctStatusExitOk -and $subfolderPctHintFound
Write-NdjsonRow ([ordered]@{
  id = 'self.empty_repo.subfolder_hint_pct'
  pass = $subfolderPctPass
  desc = 'Item 43 (CodeRabbit PR #444 round 2): a percent-shaped subfolder name (e.g. containing %PATH%) is not corrupted by call''s second expansion pass -- hint still fires correctly'
  details = [ordered]@{
    exitCode = $subfolderPctExit
    statusExitCode = $(if ($subfolderPctStatus) { $subfolderPctStatus.exitCode } else { $null })
    state = $(if ($subfolderPctStatus) { $subfolderPctStatus.state } else { $null })
    pyFiles = $(if ($subfolderPctStatus) { $subfolderPctStatus.pyFiles } else { $null })
    hintFound = $subfolderPctHintFound
  }
})
if (-not $subfolderPctPass) {
  throw "subfolder-hint percent-name scenario failed (exit=$subfolderPctExit statusExit=$($subfolderPctStatus.exitCode) state=$($subfolderPctStatus.state) hintFound=$subfolderPctHintFound)"
}
$summary.Add('subfolder Python-file hint percent-name safety: PASS')

if (Test-Path $stubDir) { Remove-Item -Recurse -Force $stubDir }
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
Copy-Item -Path $BatchPath -Destination $stubDir -Force
$stubScriptPath = Join-Path $stubDir 'hello_stub.py'
# hello_stub.py intentionally has no imports to test the zero-requirements bootstrap path.
Set-Content -Path $stubScriptPath -Value 'print("hello-from-stub")' -Encoding ASCII
# Seed empty requirements.txt so pipreqs output (requirements.auto.txt) can be compared via fc.
# real/uv lane: pipreqs exits 0 + empty auto.txt -> $bothReqExist=true, fc runs, non-placeholder diff.
# conda-full lane: pipreqs exits non-zero, no auto.txt -> $bothReqExist=false, placeholder written.
Set-Content -Path (Join-Path $stubDir 'requirements.txt') -Value '' -Encoding ASCII
function Invoke-StubSetup {
  param(
    [string]$LogName
  )
  Push-Location $stubDir
  try {
    cmd /c "call run_setup.bat > $LogName 2>&1"
    return $LASTEXITCODE
  } finally {
    Pop-Location
  }
}
$stubBootstrapLog = '~stub_bootstrap.log'
$stubExit = Invoke-StubSetup -LogName $stubBootstrapLog
if ($stubExit -ne 0) {
  throw "Stub bootstrap failed with exit code $stubExit"
}
$stubStatusPath = Join-Path $stubDir '~bootstrap.status.json'
if (-not (Test-Path $stubStatusPath)) {
  throw "Stub bootstrap missing ~bootstrap.status.json"
}
$stubStatus = Get-Content -LiteralPath $stubStatusPath -Encoding ASCII -Raw | ConvertFrom-Json
if ($stubStatus.state -ne 'ok') {
  throw "Expected ok state for stub bootstrap"
}
if ($stubStatus.pyFiles -lt 1) {
  throw "Expected at least one python file for stub bootstrap"
}
if ($stubStatus.exitCode -ne 0) {
  throw "Expected exitCode 0 for stub bootstrap"
}
# --- README REQ-015 / Item 76: the bootstrapper's own working files take a tilde ---
# Everything at the top level of the app folder after one default bootstrap must be either tilde-
# prefixed (git-ignored by the standard ignores) or a name the user is meant to see and keep. A new
# non-tilde file the bootstrapper writes is litter in the user's folder: dependency_source.txt was
# found by eye (Item 76). The allow-list is names, not patterns, except *.spec (the PyInstaller spec
# is named after the environment). Enforced on every lane from the first run. The row also proves it
# looked at the right folder (the stub entry and the bootstrapper are in the listing) and that the
# record exists under its tilde name, so an empty or wrong listing cannot pass for the right reason.
$litterAllow = @('run_setup.bat','hello_stub.py','requirements.txt','requirements.auto.txt','runtime.txt','.gitignore','.gitattributes','.uv_env','dist','build')
$litterNames = @(Get-ChildItem -LiteralPath $stubDir -Force | ForEach-Object { $_.Name })
$litterFound = @($litterNames | Where-Object { -not $_.StartsWith('~') -and ($litterAllow -notcontains $_) -and ($_ -notlike '*.spec') })
$litterListed = ($litterNames -contains 'hello_stub.py') -and ($litterNames -contains 'run_setup.bat')
$litterRecord = ($litterNames -contains '~dependency_source.txt')
Write-NdjsonRow ([ordered]@{
  id   = 'self.litter.appfolder'
  req  = 'REQ-015'
  pass = ($litterListed -and $litterRecord -and ($litterFound.Count -eq 0))
  desc = 'Default bootstrap leaves no non-tilde file of its own in the app folder'
  details = [ordered]@{
    listed   = $litterListed
    record   = $litterRecord
    litter   = $litterFound
    entries  = $litterNames
  }
})
# --- REQ-005.5 runtime validation (initial bootstrap only) ---
# ~setup.log at this point contains only the initial bootstrap's entries.
# ~pipreqs.diff.txt at this point was written only by the initial bootstrap.
$stubSetupLog  = Join-Path $stubDir '~setup.log'
$stubDiffFile  = Join-Path $stubDir '~pipreqs.diff.txt'
$diffLogFound  = $false
if (Test-Path $stubSetupLog) {
  $setupLogLines = Get-Content -LiteralPath $stubSetupLog -Encoding ASCII
  $diffLogFound  = ($setupLogLines | Where-Object { $_ -like '*REQ-005.5*' }).Count -gt 0
}
$diffFileExists = Test-Path $stubDiffFile
$stubReqTxt    = Join-Path $stubDir 'requirements.txt'
$stubAutoTxt   = Join-Path $stubDir 'requirements.auto.txt'
$bothReqExist  = (Test-Path $stubReqTxt) -and (Test-Path $stubAutoTxt)
$diffIsPlaceholder = $false
if ($diffFileExists) {
  $diffContent       = Get-Content -LiteralPath $stubDiffFile -Encoding ASCII -Raw
  $diffIsPlaceholder = $diffContent.Trim() -like '*(no diff:*'
}
# When both req files exist fc must have run (non-placeholder output expected).
# When auto.txt absent (conda-full lane): placeholder must have been written.
$diffCorrect = if ($bothReqExist) { $diffFileExists -and -not $diffIsPlaceholder } else { $diffFileExists -and $diffIsPlaceholder }
Write-NdjsonRow ([ordered]@{
  id   = 'self.dep.diff.trace'
  pass = ($diffLogFound -and $diffCorrect)
  desc = 'REQ-005.5: dependency diff log line emitted and ~pipreqs.diff.txt created during initial bootstrap'
  details = [ordered]@{
    logFound          = $diffLogFound
    fileExists        = $diffFileExists
    bothReqExist      = $bothReqExist
    diffIsPlaceholder = $diffIsPlaceholder
    diffCorrect       = $diffCorrect
  }
})
if ($diffLogFound -and $diffCorrect) { $summary.Add('self.dep.diff.trace: PASS') } else { $summary.Add('self.dep.diff.trace: FAIL') }
# CLAUDE.md Item 78: every run logs whether it is elevated, exactly once (the field run was elevated and
# the NI-VISA installer still failed; without this line nobody could tell from the log). The setup log at
# this point holds only the initial bootstrap's entries.
$elevText = if (Test-Path $stubSetupLog) { Get-Content -LiteralPath $stubSetupLog -Encoding ASCII -Raw } else { '' }
$elevMatches = [regex]::Matches($elevText, '\[INFO\] Elevated: (yes|no)\b')
$elevOnce = ($elevMatches.Count -eq 1)
Write-NdjsonRow ([ordered]@{
  id   = 'self.elevation.logged'
  req  = 'REQ-008'
  pass = $elevOnce
  desc = 'The setup log states once per run whether the process is elevated'
  details = [ordered]@{
    count = $elevMatches.Count
    value = if ($elevMatches.Count -ge 1) { $elevMatches[0].Groups[1].Value } else { $null }
  }
})
$stubEnvName = Split-Path -Leaf $stubDir
$stubEnvNameNormalized = $stubEnvName -replace '[^A-Za-z0-9_-]', '_'
if ([string]::IsNullOrWhiteSpace($stubEnvNameNormalized) -or $stubEnvNameNormalized.Trim('_').Length -eq 0) {
  $stubEnvNameNormalized = 'env'
}
$stubExePath = Join-Path $stubDir ("dist\\$stubEnvNameNormalized.exe")
if (-not (Test-Path $stubExePath)) {
  throw "Stub bootstrap missing dist/$stubEnvNameNormalized.exe after initial build"
}
$stubFastLogName = '~stub_fastpath.log'
$fastExit = Invoke-StubSetup -LogName $stubFastLogName
if ($fastExit -ne 0) {
  throw "Stub fast-path bootstrap failed with exit code $fastExit"
}
$fastLogPath = Join-Path $stubDir $stubFastLogName
$fastLog = Get-Content -LiteralPath $fastLogPath -Encoding ASCII
$fastReuseTag = "Fast path: reusing dist\$stubEnvNameNormalized.exe"
$fastSkipTag = "Fast path: skipping PyInstaller rebuild for existing dist\$stubEnvNameNormalized.exe"
if (-not ($fastLog | Where-Object { $_ -like "*${fastReuseTag}*" })) {
  throw "Fast-path run did not report EXE reuse"
}
if (-not ($fastLog | Where-Object { $_ -like "*${fastSkipTag}*" })) {
  throw "Fast-path run did not report PyInstaller skip"
}
$pyInstallerProducedTag = "PyInstaller produced dist\$stubEnvNameNormalized.exe"
$firstTwoLogs = @(
  (Join-Path $stubDir $stubBootstrapLog),
  $fastLogPath
)
$pyInstallerHits = 0
foreach ($path in $firstTwoLogs) {
  if (Test-Path $path) {
    $lines = Get-Content -LiteralPath $path -Encoding ASCII
    $pyInstallerHits += @($lines | Where-Object { $_ -like "*$pyInstallerProducedTag*" }).Count
  }
}
if ($pyInstallerHits -ne 1) {
  throw "Expected exactly one PyInstaller build across initial + fast-path runs"
}
Add-Content -Path $stubScriptPath -Value '# touched to force rebuild' -Encoding ASCII
[System.IO.File]::SetLastWriteTimeUtc($stubScriptPath, [DateTime]::UtcNow)
$stubRebuildLog = '~stub_rebuild.log'
$rebuildExit = Invoke-StubSetup -LogName $stubRebuildLog
if ($rebuildExit -ne 0) {
  throw "Stub rebuild bootstrap failed with exit code $rebuildExit"
}
$rebuildLogPath = Join-Path $stubDir $stubRebuildLog
$rebuildLines = Get-Content -LiteralPath $rebuildLogPath -Encoding ASCII
$rebuildProducedHits = @($rebuildLines | Where-Object { $_ -like "*$pyInstallerProducedTag*" }).Count
if ($rebuildProducedHits -lt 1) {
  throw "Rebuild run did not report PyInstaller producing the EXE"
}
$totalProducedHits = 0
foreach ($path in $firstTwoLogs + $rebuildLogPath) {
  if (Test-Path $path) {
    $lines = Get-Content -LiteralPath $path -Encoding ASCII
    $totalProducedHits += @($lines | Where-Object { $_ -like "*$pyInstallerProducedTag*" }).Count
  }
}
if ($totalProducedHits -ne 2) {
  throw "Expected exactly two PyInstaller builds after touching hello_stub.py"
}
$summary.Add('stub fast path + rebuild: PASS')
$stubPython = Join-Path $MiniRoot ("envs\\$stubEnvNameNormalized\\python.exe")
$pythonCmd = $null
$pythonArgs = @('-u','hello_stub.py')
if (Test-Path $stubPython) {
  $pythonCmd = $stubPython
}
if (-not $pythonCmd) {
  if (Get-Command python -ErrorAction SilentlyContinue) {
    $pythonCmd = 'python'
  } elseif (Get-Command py -ErrorAction SilentlyContinue) {
    $pythonCmd = 'py'
    $pythonArgs = @('-3','-u','hello_stub.py')
  }
}
if (-not $pythonCmd) {
  throw "Unable to locate Python interpreter for stub run"
}
Push-Location $stubDir
try {
  if ($pythonCmd -eq 'python' -or $pythonCmd -eq 'py') {
    cmd /c "$pythonCmd $($pythonArgs -join ' ') > ~stub_run.log 2>&1"
  } else {
    & $pythonCmd @pythonArgs *>&1 | Tee-Object -FilePath '~stub_run.log'
  }
  $runExit = $LASTEXITCODE
} finally {
  Pop-Location
}
if ($runExit -ne 0) {
  throw "Stub python execution failed with exit code $runExit"
}
$runLog = Get-Content -LiteralPath (Join-Path $stubDir '~stub_run.log') -Encoding ASCII
if (-not ($runLog | Where-Object { $_ -match 'hello-from-stub' })) {
  throw "Stub python execution did not emit hello-from-stub"
}
$summary.Add('stub bootstrap + python run: PASS')
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.fastpath'
  pass = ($pyInstallerHits -eq 1)
  desc = 'Stub bootstrap: fast path reuses EXE without rebuilding'
  details = [ordered]@{
    stubEnvName = $stubEnvNameNormalized
    pyInstallerBuilds = $pyInstallerHits
  }
})
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.rebuild'
  pass = ($totalProducedHits -eq 2)
  desc = 'Stub rebuild: source change triggers new EXE, subsequent run takes fast path'
  details = [ordered]@{
    totalBuilds = $totalProducedHits
    rebuildBuilds = $rebuildProducedHits
  }
})
$stateSkipPhrase = 'Env-state fast path: reusing conda env'
$uvReusePhrase = 'uv: reusing existing .uv_env'
$stateSkipFound = (($rebuildLines | Where-Object { $_ -like "*$stateSkipPhrase*" }).Count -gt 0) -or
                  (($rebuildLines | Where-Object { $_ -like "*$uvReusePhrase*" }).Count -gt 0)
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.state_skip'
  pass = $stateSkipFound
  desc = 'Stub rebuild: env-state fast path skips conda create when deps unchanged'
  details = [ordered]@{
    found = $stateSkipFound
    log = $stubRebuildLog
  }
})
if ($stateSkipFound) { $summary.Add('stub state skip: PASS') } else { $summary.Add('stub state skip: FAIL') }

# --- pip-install warning test ---
# Arrange: stub .py + a requirements.txt containing a nonexistent package so pip install fails.
# Assert:  the "*** Warning: Some requirements..." line appears and bootstrap still exits 0.
$pipWarnDir = Join-Path $TestsDir '~selftest_pip_warn'
if (Test-Path $pipWarnDir) { Remove-Item -Recurse -Force $pipWarnDir }
New-Item -ItemType Directory -Force -Path $pipWarnDir | Out-Null
Copy-Item -Path $BatchPath -Destination $pipWarnDir -Force
Set-Content -Path (Join-Path $pipWarnDir 'hello_stub.py') -Value 'print("hello-from-stub")' -Encoding ASCII
Set-Content -Path (Join-Path $pipWarnDir 'requirements.txt') -Value '_fake_pkg_pipwarn_xyz_' -Encoding ASCII
$pipWarnLogName = '~pip_warn_bootstrap.log'
Push-Location $pipWarnDir
try {
  cmd /c "call run_setup.bat > $pipWarnLogName 2>&1"
  $pipWarnExit = $LASTEXITCODE
} finally {
  Pop-Location
}
$pipWarnLogPath = Join-Path $pipWarnDir $pipWarnLogName
$pipWarnLines = @()
if (Test-Path $pipWarnLogPath) { $pipWarnLines = Get-Content -LiteralPath $pipWarnLogPath -Encoding ASCII }
$pipWarnTag = '*** Warning: Some requirements may have failed to install.'
$pipWarnFound = ($pipWarnLines | Where-Object { $_ -like "*$pipWarnTag*" }).Count -gt 0
$pipWarnStatusPath = Join-Path $pipWarnDir '~bootstrap.status.json'
$pipWarnContinued = $false
if (Test-Path $pipWarnStatusPath) {
  try {
    $pipWarnStatus = Get-Content -LiteralPath $pipWarnStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $pipWarnContinued = ($pipWarnStatus.exitCode -eq 0)
  } catch { }
}
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.pip_warn'
  pass = ($pipWarnFound -and $pipWarnContinued)
  desc = 'Bootstrap emits pip install warning and continues when a requirement fails to install'
  details = [ordered]@{
    warnFound = $pipWarnFound
    continued = $pipWarnContinued
  }
})
if ($pipWarnFound -and $pipWarnContinued) { $summary.Add('pip install warn + continue: PASS') } else { $summary.Add('pip install warn + continue: FAIL') }

# --- pipreqs version-forced-failure fallback test ---
# Arrange: stub app imports a real third-party package (six) with NO requirements.txt/
# pyproject.toml/PEP-723 metadata, so pipreqs is the only thing that could have declared it.
# HP_PIPREQS_VERSION=99.99.99 forces the "pip install pipreqs" step to fail deterministically:
# no version "99.99.99" of pipreqs has ever existed on PyPI, so "pip install pipreqs==99.99.99"
# (or the uv-mode equivalent) always fails with "No matching distribution found", independent
# of the Python interpreter version or resolver leniency. This is deliberately NOT the same
# mechanism as pipreqs 0.5.0's real Requires-Python<3.13 cap (see the pipreqs pin rationale in
# CLAUDE.md) -- an earlier version of this test used HP_PIPREQS_VERSION=0.5.0 and it only fails
# to install when the *ambient* Python actually exceeds 3.13; confirmed locally that
# `pip install pipreqs==0.5.0` resolves and installs cleanly on Python 3.11, and CI run #1522
# showed the same non-failure on at least one lane (installFailWarnFound=false even though
# warnfix still had to recover `six`, i.e. pipreqs's own scan produced nothing usable by some
# other path). A nonexistent version number removes that external dependency entirely.
# Assert: the pipreqs-install-failed WARN fires, DEP_SOURCE never becomes "pipreqs" (nothing
# declares `six`), SOME fallback layer (REQ-005.12's autopep723 discovery merge, or the
# PyInstaller warn-file/warnfix repair loop) recovers `six`, and the rebuilt program still runs
# and prints its token. All four must hold -- checking only "did it exit 0" would let this test
# silently pass for the wrong reason.
#
# derived requirement: this test originally asserted warnfix SPECIFICALLY was the recovery
# mechanism (both here and in the REQ-005.12 discovery-merge-complete log line's own era, that
# was still true -- see the pipreqs 0.5.0 footnote above). Since REQ-005.12 shipped, a plain
# top-level `import six` with no requirements source is caught by the autopep723 discovery merge
# BEFORE the PyInstaller build ever runs, so warnfix's own repair loop no longer has anything left
# to do for `six` itself -- it only kept firing as an accidental side effect of `StringIO` (an
# unrelated, always-doomed-to-fail conditional import inside six's own Python 2/3 compatibility
# layer) still being treated as a genuine repair target. Once tools/parse_warn.py's SKIP set was
# extended to filter StringIO/cStringIO (a real fix -- see CLAUDE.md's warnfix SKIP documentation
# for why), that accidental trigger went away and warnfixEngaged correctly reads false whenever
# the discovery merge already did the job. Asserting warnfix specifically would now be testing a
# stale implementation detail, not a genuine safety property -- the actual invariant this test
# exists to protect is "pipreqs failing doesn't strand the user," and that holds regardless of
# which layered fallback mechanism recovers the dependency.
$pipreqsFailDir = Join-Path $TestsDir '~selftest_pipreqs_version_fail'
if (Test-Path $pipreqsFailDir) { Remove-Item -Recurse -Force $pipreqsFailDir }
New-Item -ItemType Directory -Force -Path $pipreqsFailDir | Out-Null
Copy-Item -Path $BatchPath -Destination $pipreqsFailDir -Force
Set-Content -Path (Join-Path $pipreqsFailDir 'app_pipreqs_fail_test.py') -Value @'
import six
print("pipreqs-fail-ok")
'@ -Encoding ASCII
$pipreqsFailLogName = '~pipreqs_version_fail_bootstrap.log'
$prevPipreqsVersion = $env:HP_PIPREQS_VERSION
$env:HP_PIPREQS_VERSION = '99.99.99'
# derived requirement: this app is expected to build+warnfix-recover+run successfully, which
# reaches the REQ-018 post-execution checkpoint (:run_postexec_checkpoint) -- a set /p consent
# prompt that only auto-declines when HP_CI_LANE (or a few other flags) is defined. Real CI
# always sets HP_CI_LANE at the job level, so this is masked there, but a contributor running
# this script locally without it set would hang forever on the prompt. Pin it locally exactly
# like the neighboring conda_retry/conda_perpkg blocks do (see docs/agent-lessons-learned.md
# "Accepted gap").
$prevCILanePipreqs = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $pipreqsFailDir
try {
  cmd /c "call run_setup.bat > $pipreqsFailLogName 2>&1"
  $pipreqsFailExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_PIPREQS_VERSION = $prevPipreqsVersion
  $env:HP_CI_LANE = $prevCILanePipreqs
}
$pipreqsFailLogPath = Join-Path $pipreqsFailDir $pipreqsFailLogName
$pipreqsFailLines = @()
if (Test-Path $pipreqsFailLogPath) { $pipreqsFailLines = Get-Content -LiteralPath $pipreqsFailLogPath -Encoding ASCII }
$pipreqsInstallFailFound = ($pipreqsFailLines | Where-Object { $_ -like '*pipreqs install failed*' }).Count -gt 0
$pipreqsWarnfixEngaged = ($pipreqsFailLines | Where-Object { $_ -like '*rebuild complete after warnfix*' }).Count -gt 0
# derived requirement: `six` is recovered either by warnfix's own repair loop OR by REQ-005.12's
# autopep723 discovery merge finding it before the build ever runs (see the comment block above --
# both are legitimate, and which one actually fires is an implementation detail, not the property
# under test). "added: six" comes from tools/autopep_merge.py's own stdout -- run_setup.bat's
# REQ-005.12 call site redirects that helper's stdout directly into %LOG% (">> "%LOG%" 2>&1"),
# NOT the parent process's own stdout, so this line is written to ~setup.log ONLY and never
# reaches ~pipreqs_version_fail_bootstrap.log (the outer `cmd /c ... > log 2>&1` capture
# $pipreqsFailLines is read from above) -- unlike :log-emitted lines (e.g. warnfixEngaged's own
# check), which dual-write to both streams. Must be read from ~setup.log specifically.
$pipreqsSetupLogPath = Join-Path $pipreqsFailDir '~setup.log'
$pipreqsSetupLines = @()
if (Test-Path $pipreqsSetupLogPath) { $pipreqsSetupLines = Get-Content -LiteralPath $pipreqsSetupLogPath -Encoding ASCII }
$pipreqsDiscoveryRecovered = ($pipreqsSetupLines | Where-Object { $_ -like '*added: six*' }).Count -gt 0
$pipreqsRecovered = $pipreqsWarnfixEngaged -or $pipreqsDiscoveryRecovered
# derived requirement: the app's own stdout is never echoed into run_setup.bat's own console/log
# (both the EXE-smoke path at run_setup.bat:2783 and the no-EXE interpreter path at :2616 redirect
# the child process's stdout to a standalone ~run.out.txt in the app root instead) -- so the printed
# token must be read from THAT file, not grepped out of the bootstrap log, or this assertion would
# always be false regardless of whether the app actually ran. Matches the convention already used
# by tests/selfapps_envsmoke.ps1 ($runout = Join-Path $app '~run.out.txt').
$pipreqsFailRunOutPath = Join-Path $pipreqsFailDir '~run.out.txt'
$pipreqsFailRunOut = ''
if (Test-Path $pipreqsFailRunOutPath) { $pipreqsFailRunOut = Get-Content -LiteralPath $pipreqsFailRunOutPath -Raw -Encoding ASCII }
$pipreqsAppRan = ($pipreqsFailRunOut -like '*pipreqs-fail-ok*')
$pipreqsFailStatusPath = Join-Path $pipreqsFailDir '~bootstrap.status.json'
$pipreqsFailBootstrapOk = $false
if (Test-Path $pipreqsFailStatusPath) {
  try {
    $pipreqsFailStatus = Get-Content -LiteralPath $pipreqsFailStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $pipreqsFailBootstrapOk = ($pipreqsFailStatus.state -eq 'ok' -and $pipreqsFailStatus.exitCode -eq 0)
  } catch { }
}
$pipreqsFailAllPass = ($pipreqsInstallFailFound -and $pipreqsRecovered -and $pipreqsAppRan -and $pipreqsFailBootstrapOk)
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.pipreqs_version_fail'
  pass = $pipreqsFailAllPass
  desc = 'HP_PIPREQS_VERSION=99.99.99 forces pipreqs install to fail; a layered fallback recovers the missing import and the app still runs'
  details = [ordered]@{
    installFailWarnFound = $pipreqsInstallFailFound
    warnfixEngaged = $pipreqsWarnfixEngaged
    discoveryMergeRecovered = $pipreqsDiscoveryRecovered
    appRan = $pipreqsAppRan
    bootstrapOk = $pipreqsFailBootstrapOk
    exitCode = $pipreqsFailExit
  }
})
if ($pipreqsFailAllPass) { $summary.Add('pipreqs version-forced-failure fallback: PASS') } else { $summary.Add('pipreqs version-forced-failure fallback: FAIL') }

# --- Concurrent-instance lock (REQ-024) tests ---
# Part A (zero extra bootstrap cost): the pipreqs-fail run above already completed a full,
# successful bootstrap in $pipreqsFailDir. Its own lock directory must not persist afterward --
# reuses that already-completed run instead of paying for a fourth full bootstrap just to prove
# cleanup-on-success.
$lockNoLeakPath = Join-Path $pipreqsFailDir '~bootstrap.lock'
$lockNoLeak = -not (Test-Path $lockNoLeakPath)
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.lock_no_leak'
  req = 'REQ-024.8'
  pass = $lockNoLeak
  desc = 'REQ-024: the lock directory does not persist after a normal successful bootstrap'
  details = [ordered]@{ lockDirPresent = (Test-Path $lockNoLeakPath) }
})
if ($lockNoLeak) { $summary.Add('lock cleanup after success: PASS') } else { $summary.Add('lock cleanup after success: FAIL') }

# Part B: a fresh (non-stale) pre-existing lock directory must cause a second instance to decline
# gracefully -- exit non-zero, log the "already running" message, and critically must NOT delete
# or otherwise touch a lock it does not own (it never set HP_LOCK_OWNED). The decline happens
# before any real bootstrap work, so no ~bootstrap.status.json should be written at all.
$lockHeldDir = Join-Path $TestsDir '~selftest_lock_held'
if (Test-Path $lockHeldDir) { Remove-Item -Recurse -Force $lockHeldDir }
New-Item -ItemType Directory -Force -Path $lockHeldDir | Out-Null
Copy-Item -Path $BatchPath -Destination $lockHeldDir -Force
Set-Content -Path (Join-Path $lockHeldDir 'hello_stub.py') -Value 'print("hello-from-stub")' -Encoding ASCII
$lockHeldPreexisting = Join-Path $lockHeldDir '~bootstrap.lock'
New-Item -ItemType Directory -Force -Path $lockHeldPreexisting | Out-Null
Set-Content -Path (Join-Path $lockHeldPreexisting 'owner.txt') -Value "pid=999999`nstarted=simulated" -Encoding ASCII
$lockHeldOwnerPath = Join-Path $lockHeldPreexisting 'owner.txt'
$lockHeldOwnerBefore = Get-Content -LiteralPath $lockHeldOwnerPath -Raw -Encoding ASCII
$lockHeldLogName = '~lock_held_bootstrap.log'
Push-Location $lockHeldDir
try {
  cmd /c "call run_setup.bat > $lockHeldLogName 2>&1"
  $lockHeldExit = $LASTEXITCODE
} finally {
  Pop-Location
}
$lockHeldLogPath = Join-Path $lockHeldDir $lockHeldLogName
$lockHeldLines = @()
if (Test-Path $lockHeldLogPath) { $lockHeldLines = Get-Content -LiteralPath $lockHeldLogPath -Encoding ASCII }
$lockHeldText = ($lockHeldLines -join "`n")
$lockHeldMsgFound = ($lockHeldLines | Where-Object { $_ -like '*already running*' }).Count -gt 0
# derived requirement: one declined run, five README shalls. Each of REQ-024.2 to REQ-024.5 gets its own row
# (read from this run's text, files and exit code, no extra bootstrap), so a red row names the shall that failed.
# REQ-024.2: the message says another instance appears to be running and names the lock folder to delete.
$lockHeldSaysRunning = $lockHeldText -like '*Another instance of this setup appears to be running in this folder*'
$lockHeldNamesFolder = $lockHeldText -like '*delete the "~bootstrap.lock" folder*'
$lockHeldMessagePass = ($lockHeldSaysRunning -and $lockHeldNamesFolder)
# REQ-024.3: the second instance stops with exit code 1.
$lockHeldDeclined = ($lockHeldExit -eq 1)
# REQ-024.4: the lock folder is still there and is still the one that was planted (a run that removed it and made
# its own would have written its own owner.txt).
$lockHeldOwnerAfter = $null
if (Test-Path -LiteralPath $lockHeldOwnerPath) { $lockHeldOwnerAfter = Get-Content -LiteralPath $lockHeldOwnerPath -Raw -Encoding ASCII }
$lockHeldKept = ((Test-Path $lockHeldPreexisting) -and ($lockHeldOwnerAfter -eq $lockHeldOwnerBefore))
# REQ-024.5: no status file.
$lockHeldStatusPath = Join-Path $lockHeldDir '~bootstrap.status.json'
$lockHeldNoStatus = -not (Test-Path $lockHeldStatusPath)
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.lock_held_message'
  req = 'REQ-024.2'
  pass = $lockHeldMessagePass
  desc = 'REQ-024: a fresh (non-stale) lock directory makes a second instance say that another instance appears to be running and name the lock folder to delete'
  details = [ordered]@{ saysRunning = $lockHeldSaysRunning; namesLockFolder = $lockHeldNamesFolder; logLineFound = $lockHeldMsgFound }
})
if ($lockHeldMessagePass) { $summary.Add('lock held message: PASS') } else { $summary.Add('lock held message: FAIL') }
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.lock_held_decline'
  req = 'REQ-024.3'
  pass = $lockHeldDeclined
  desc = 'REQ-024: a fresh (non-stale) lock directory makes a second instance stop with exit code 1'
  details = [ordered]@{ declined = $lockHeldDeclined; exitCode = $lockHeldExit }
})
if ($lockHeldDeclined) { $summary.Add('lock held decline: PASS') } else { $summary.Add('lock held decline: FAIL') }
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.lock_held_kept'
  req = 'REQ-024.4'
  pass = $lockHeldKept
  desc = 'REQ-024: a second instance that stops on a fresh lock directory leaves that directory, and the owner file in it, as they were'
  details = [ordered]@{ lockPresent = (Test-Path $lockHeldPreexisting); ownerUnchanged = ($lockHeldOwnerAfter -eq $lockHeldOwnerBefore) }
})
if ($lockHeldKept) { $summary.Add('lock held kept: PASS') } else { $summary.Add('lock held kept: FAIL') }
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.lock_held_nostatus'
  req = 'REQ-024.5'
  pass = $lockHeldNoStatus
  desc = 'REQ-024: a second instance that stops on a fresh lock directory writes no ~bootstrap.status.json'
  details = [ordered]@{ statusFilePresent = (Test-Path $lockHeldStatusPath) }
})
if ($lockHeldNoStatus) { $summary.Add('lock held no status: PASS') } else { $summary.Add('lock held no status: FAIL') }

# Part C: HP_TEST_FORCE_LOCK_STALE=1 forces the staleness check to report stale (deterministic --
# avoids waiting out the real ~2 hour threshold in CI), so a pre-existing lock directory
# (simulating a crashed prior instance that never released it) is evicted and the bootstrap
# proceeds and completes normally.
$lockStaleDir = Join-Path $TestsDir '~selftest_lock_stale'
if (Test-Path $lockStaleDir) { Remove-Item -Recurse -Force $lockStaleDir }
New-Item -ItemType Directory -Force -Path $lockStaleDir | Out-Null
Copy-Item -Path $BatchPath -Destination $lockStaleDir -Force
Set-Content -Path (Join-Path $lockStaleDir 'hello_stub.py') -Value 'print("hello-from-stub")' -Encoding ASCII
$lockStalePreexisting = Join-Path $lockStaleDir '~bootstrap.lock'
New-Item -ItemType Directory -Force -Path $lockStalePreexisting | Out-Null
Set-Content -Path (Join-Path $lockStalePreexisting 'owner.txt') -Value "pid=999998`nstarted=simulated-stale" -Encoding ASCII
$lockStaleLogName = '~lock_stale_bootstrap.log'
$prevForceLockStale = $env:HP_TEST_FORCE_LOCK_STALE
$env:HP_TEST_FORCE_LOCK_STALE = '1'
# derived requirement: same HP_CI_LANE pinning as the pipreqs-fail block above -- a successful
# run reaches the REQ-018 post-execution checkpoint prompt, which only auto-declines under
# HP_CI_LANE (see docs/agent-lessons-learned.md "Accepted gap").
$prevCILaneLockStale = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $lockStaleDir
try {
  cmd /c "call run_setup.bat > $lockStaleLogName 2>&1"
  $lockStaleExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_FORCE_LOCK_STALE = $prevForceLockStale
  $env:HP_CI_LANE = $prevCILaneLockStale
}
$lockStaleLogPath = Join-Path $lockStaleDir $lockStaleLogName
$lockStaleLines = @()
if (Test-Path $lockStaleLogPath) { $lockStaleLines = Get-Content -LiteralPath $lockStaleLogPath -Encoding ASCII }
$lockStaleEvictedFound = ($lockStaleLines | Where-Object { $_ -like '*stale lock evicted*' }).Count -gt 0
$lockStaleStatusPath = Join-Path $lockStaleDir '~bootstrap.status.json'
$lockStaleBootstrapOk = $false
if (Test-Path $lockStaleStatusPath) {
  try {
    $lockStaleStatus = Get-Content -LiteralPath $lockStaleStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $lockStaleBootstrapOk = ($lockStaleStatus.state -eq 'ok' -and $lockStaleStatus.exitCode -eq 0)
  } catch { }
}
$lockStaleAllPass = ($lockStaleEvictedFound -and $lockStaleBootstrapOk)
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.lock_stale_evict'
  req = 'REQ-024.6'
  pass = $lockStaleAllPass
  desc = 'REQ-024: HP_TEST_FORCE_LOCK_STALE evicts a pre-existing lock directory and the bootstrap proceeds normally'
  details = [ordered]@{
    evictedFound = $lockStaleEvictedFound
    bootstrapOk = $lockStaleBootstrapOk
    exitCode = $lockStaleExit
  }
})
if ($lockStaleAllPass) { $summary.Add('lock stale eviction: PASS') } else { $summary.Add('lock stale eviction: FAIL') }

# Part D (CLAUDE.md Item 49): HP_TEST_FORCE_LOCK_INDETERMINATE=1 forces :lock_is_stale's
# PowerShell probe to report neither 'stale' nor 'fresh' (exit /b 2), deterministically
# simulating a transient probe hiccup. Unlike Part B (fresh -> hard decline) and Part C (stale
# -> evict-and-proceed), an indeterminate result must fall through gracefully WITHOUT deleting
# the pre-existing lock directory -- it might genuinely still be held by a live instance, so
# eviction would be as wrong as a hard block would be for a condition unrelated to a real
# concurrent run.
$lockIndeterminateDir = Join-Path $TestsDir '~selftest_lock_indeterminate'
if (Test-Path $lockIndeterminateDir) { Remove-Item -Recurse -Force $lockIndeterminateDir }
New-Item -ItemType Directory -Force -Path $lockIndeterminateDir | Out-Null
Copy-Item -Path $BatchPath -Destination $lockIndeterminateDir -Force
Set-Content -Path (Join-Path $lockIndeterminateDir 'hello_stub.py') -Value 'print("hello-from-stub")' -Encoding ASCII
$lockIndeterminatePreexisting = Join-Path $lockIndeterminateDir '~bootstrap.lock'
New-Item -ItemType Directory -Force -Path $lockIndeterminatePreexisting | Out-Null
Set-Content -Path (Join-Path $lockIndeterminatePreexisting 'owner.txt') -Value "pid=999997`nstarted=simulated-indeterminate" -Encoding ASCII
$lockIndeterminateLogName = '~lock_indeterminate_bootstrap.log'
$prevForceLockIndeterminate = $env:HP_TEST_FORCE_LOCK_INDETERMINATE
$env:HP_TEST_FORCE_LOCK_INDETERMINATE = '1'
# derived requirement: same HP_CI_LANE pinning as the pipreqs-fail/lock-stale blocks above -- a
# successful run reaches the REQ-018 post-execution checkpoint prompt, which only auto-declines
# under HP_CI_LANE (see docs/agent-lessons-learned.md "Accepted gap").
$prevCILaneLockIndeterminate = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $lockIndeterminateDir
try {
  cmd /c "call run_setup.bat > $lockIndeterminateLogName 2>&1"
  $lockIndeterminateExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_FORCE_LOCK_INDETERMINATE = $prevForceLockIndeterminate
  $env:HP_CI_LANE = $prevCILaneLockIndeterminate
}
$lockIndeterminateLogPath = Join-Path $lockIndeterminateDir $lockIndeterminateLogName
$lockIndeterminateLines = @()
if (Test-Path $lockIndeterminateLogPath) { $lockIndeterminateLines = Get-Content -LiteralPath $lockIndeterminateLogPath -Encoding ASCII }
$lockIndeterminateWarnFound = ($lockIndeterminateLines | Where-Object { $_ -like '*could not determine whether the existing lock is stale*' }).Count -gt 0
$lockIndeterminateStatusPath = Join-Path $lockIndeterminateDir '~bootstrap.status.json'
$lockIndeterminateBootstrapOk = $false
if (Test-Path $lockIndeterminateStatusPath) {
  try {
    $lockIndeterminateStatus = Get-Content -LiteralPath $lockIndeterminateStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $lockIndeterminateBootstrapOk = ($lockIndeterminateStatus.state -eq 'ok' -and $lockIndeterminateStatus.exitCode -eq 0)
  } catch { }
}
$lockIndeterminatePreserved = Test-Path $lockIndeterminatePreexisting
$lockIndeterminateAllPass = ($lockIndeterminateExit -eq 0 -and $lockIndeterminateWarnFound -and $lockIndeterminateBootstrapOk -and $lockIndeterminatePreserved)
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.lock_indeterminate'
  req = 'REQ-024.7'
  pass = $lockIndeterminateAllPass
  desc = 'REQ-024 (CLAUDE.md Item 49): an indeterminate lock-staleness result continues without the lock, without evicting the pre-existing lock directory'
  details = [ordered]@{
    warnFound = $lockIndeterminateWarnFound
    bootstrapOk = $lockIndeterminateBootstrapOk
    lockPreserved = $lockIndeterminatePreserved
    exitCode = $lockIndeterminateExit
  }
})
if ($lockIndeterminateAllPass) { $summary.Add('lock indeterminate continue: PASS') } else { $summary.Add('lock indeterminate continue: FAIL') }

# Part E (README REQ-024.1): the lock folder exists from the start of a run, before any download, installation
# or environment creation. A normal run removes its lock at its end, so the folder is watched while the run goes
# on: the run is started in the background, polled until the lock appears, the first sighting is checked against
# the folders and files that a download or an environment would create, and the whole process tree is stopped
# (a stopped run never releases its lock, see the README notes of REQ-024).
$lockStartDir = Join-Path $TestsDir '~selftest_lock_start'
if (Test-Path $lockStartDir) { Remove-Item -Recurse -Force $lockStartDir }
New-Item -ItemType Directory -Force -Path $lockStartDir | Out-Null
Copy-Item -Path $BatchPath -Destination $lockStartDir -Force
Set-Content -Path (Join-Path $lockStartDir 'hello_stub.py') -Value 'print("hello-from-stub")' -Encoding ASCII
$lockStartLock = Join-Path $lockStartDir '~bootstrap.lock'
$lockStartLogName = '~lock_start_bootstrap.log'
$lockStartEarly = @('~uv_bin', '~miniconda.exe', '.uv_env', 'dist', 'build')
$prevCILaneLockStart = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
$lockStartSeen = $false
$lockStartPresent = @()
$lockStartWaitMs = 0
$lockStartError = ''
$lockStartProc = $null
try {
  $lockStartPsi = New-Object System.Diagnostics.ProcessStartInfo
  $lockStartPsi.FileName = $env:ComSpec
  $lockStartPsi.Arguments = '/c "call run_setup.bat > ' + $lockStartLogName + ' 2>&1"'
  $lockStartPsi.WorkingDirectory = $lockStartDir
  $lockStartPsi.UseShellExecute = $false
  $lockStartPsi.CreateNoWindow = $true
  $lockStartProc = [System.Diagnostics.Process]::Start($lockStartPsi)
  $lockStartClock = [System.Diagnostics.Stopwatch]::StartNew()
  while ($lockStartClock.Elapsed.TotalSeconds -lt 90) {
    if (Test-Path -LiteralPath $lockStartLock) {
      $lockStartSeen = $true
      $lockStartPresent = @($lockStartEarly | Where-Object { Test-Path -LiteralPath (Join-Path $lockStartDir $_) })
      break
    }
    if ($lockStartProc.HasExited) { break }
    Start-Sleep -Milliseconds 20
  }
  $lockStartWaitMs = [int]$lockStartClock.ElapsedMilliseconds
} catch {
  $lockStartError = $_.Exception.Message
} finally {
  $env:HP_CI_LANE = $prevCILaneLockStart
  if ($null -ne $lockStartProc -and -not $lockStartProc.HasExited) {
    & taskkill.exe /F /T /PID $lockStartProc.Id 2>&1 | Out-Null
    [void]$lockStartProc.WaitForExit(20000)
  }
}
$lockStartPass = ($lockStartSeen -and ($lockStartPresent.Count -eq 0))
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.lock_start'
  req = 'REQ-024.1'
  pass = $lockStartPass
  desc = 'REQ-024: the lock directory exists while a run is still at its start, before any download, installation or environment creation'
  details = [ordered]@{
    lockSeen = $lockStartSeen
    firstSightingMs = $lockStartWaitMs
    createdBeforeLock = ($lockStartPresent -join ',')
    error = $lockStartError
  }
})
if ($lockStartPass) { $summary.Add('lock created at start: PASS') } else { $summary.Add('lock created at start: FAIL') }

# Part F (README REQ-024.9): a stale lock directory that cannot be removed. The planted lock holds a file that
# this script keeps open without delete sharing, so the batch file's rd cannot clear the folder and its mkdir
# then finds the folder still there. The run must go on without a lock and say so, and must leave the folder alone.
$lockBlockedDir = Join-Path $TestsDir '~selftest_lock_blocked'
if (Test-Path $lockBlockedDir) { Remove-Item -Recurse -Force $lockBlockedDir }
New-Item -ItemType Directory -Force -Path $lockBlockedDir | Out-Null
Copy-Item -Path $BatchPath -Destination $lockBlockedDir -Force
Set-Content -Path (Join-Path $lockBlockedDir 'hello_stub.py') -Value 'print("hello-from-stub")' -Encoding ASCII
$lockBlockedLock = Join-Path $lockBlockedDir '~bootstrap.lock'
New-Item -ItemType Directory -Force -Path $lockBlockedLock | Out-Null
$lockBlockedFile = Join-Path $lockBlockedLock 'owner.txt'
Set-Content -Path $lockBlockedFile -Value "pid=999996`nstarted=simulated-blocked" -Encoding ASCII
$lockBlockedLogName = '~lock_blocked_bootstrap.log'
$lockBlockedHold = $null
$lockBlockedHeld = $false
$lockBlockedExit = $null
$prevForceLockBlocked = $env:HP_TEST_FORCE_LOCK_STALE
$prevCILaneLockBlocked = $env:HP_CI_LANE
try {
  $lockBlockedHold = [System.IO.File]::Open($lockBlockedFile, 'Open', 'Read', 'Read')
  # prove the hold: deleting the file must fail while it is open (a delete that works means there is no hold)
  try { [System.IO.File]::Delete($lockBlockedFile) } catch { $lockBlockedHeld = $true }
  $env:HP_TEST_FORCE_LOCK_STALE = '1'
  if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
  Push-Location $lockBlockedDir
  try {
    cmd /c "call run_setup.bat > $lockBlockedLogName 2>&1"
    $lockBlockedExit = $LASTEXITCODE
  } finally {
    Pop-Location
  }
} finally {
  $env:HP_TEST_FORCE_LOCK_STALE = $prevForceLockBlocked
  $env:HP_CI_LANE = $prevCILaneLockBlocked
}
$lockBlockedStillThere = (Test-Path -LiteralPath $lockBlockedLock) -and (Test-Path -LiteralPath $lockBlockedFile)
if ($null -ne $lockBlockedHold) { $lockBlockedHold.Dispose() }
$lockBlockedLogPath = Join-Path $lockBlockedDir $lockBlockedLogName
$lockBlockedLines = @()
if (Test-Path $lockBlockedLogPath) { $lockBlockedLines = Get-Content -LiteralPath $lockBlockedLogPath -Encoding ASCII }
$lockBlockedWarnFound = ($lockBlockedLines | Where-Object { $_ -like '*could not acquire lock after evicting stale lock*' }).Count -gt 0
$lockBlockedDeclinedMsg = ($lockBlockedLines | Where-Object { $_ -like '*already running*' }).Count -gt 0
$lockBlockedStatusPath = Join-Path $lockBlockedDir '~bootstrap.status.json'
$lockBlockedBootstrapOk = $false
if (Test-Path $lockBlockedStatusPath) {
  try {
    $lockBlockedStatus = Get-Content -LiteralPath $lockBlockedStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $lockBlockedBootstrapOk = ($lockBlockedStatus.state -eq 'ok' -and $lockBlockedStatus.exitCode -eq 0)
  } catch { }
}
$lockBlockedPass = ($lockBlockedHeld -and $lockBlockedWarnFound -and (-not $lockBlockedDeclinedMsg) -and $lockBlockedBootstrapOk -and $lockBlockedStillThere)
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.lock_evict_blocked'
  req = 'REQ-024.9'
  pass = $lockBlockedPass
  desc = 'REQ-024: when a stale lock directory cannot be removed the run continues without a lock, warns in the log and leaves the directory alone'
  details = [ordered]@{
    holdProven = $lockBlockedHeld
    warnFound = $lockBlockedWarnFound
    declinedMsg = $lockBlockedDeclinedMsg
    bootstrapOk = $lockBlockedBootstrapOk
    lockStillThere = $lockBlockedStillThere
    exitCode = $lockBlockedExit
  }
})
if ($lockBlockedPass) { $summary.Add('lock evict blocked continue: PASS') } else { $summary.Add('lock evict blocked continue: FAIL') }

# --- Free-disk-space guard (REQ-025) test ---
# Arrange: HP_TEST_FORCE_LOW_DISK=1 deterministically forces the "low disk space" branch instead
# of depending on the real free space of the CI runner's drive (which is never actually low).
# Assert: the WARN line fires and the bootstrap still completes normally -- this guard is
# warn-only and must NEVER abort the run, per REQ-001 (env-var flags are scaffolding, never a
# Prime-Directive gate).
$lowDiskDir = Join-Path $TestsDir '~selftest_low_disk'
if (Test-Path $lowDiskDir) { Remove-Item -Recurse -Force $lowDiskDir }
New-Item -ItemType Directory -Force -Path $lowDiskDir | Out-Null
Copy-Item -Path $BatchPath -Destination $lowDiskDir -Force
Set-Content -Path (Join-Path $lowDiskDir 'hello_stub.py') -Value 'print("hello-from-stub")' -Encoding ASCII
$lowDiskLogName = '~low_disk_bootstrap.log'
$prevForceLowDisk = $env:HP_TEST_FORCE_LOW_DISK
$env:HP_TEST_FORCE_LOW_DISK = '1'
# derived requirement: same HP_CI_LANE pinning as the pipreqs-fail/lock-stale blocks above -- a
# successful run reaches the REQ-018 post-execution checkpoint prompt, which only auto-declines
# under HP_CI_LANE (see docs/agent-lessons-learned.md "Accepted gap").
$prevCILaneLowDisk = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $lowDiskDir
try {
  cmd /c "call run_setup.bat > $lowDiskLogName 2>&1"
  $lowDiskExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_FORCE_LOW_DISK = $prevForceLowDisk
  $env:HP_CI_LANE = $prevCILaneLowDisk
}
$lowDiskLogPath = Join-Path $lowDiskDir $lowDiskLogName
$lowDiskLines = @()
if (Test-Path $lowDiskLogPath) { $lowDiskLines = Get-Content -LiteralPath $lowDiskLogPath -Encoding ASCII }
$lowDiskText = ($lowDiskLines -join "`n")
$lowDiskWarnFound = ($lowDiskLines | Where-Object { $_ -like '*low disk space detected*' }).Count -gt 0
# REQ-025.1: the warning gives the free space in whole gigabytes (the hook forces a reading of 0) and names
# freeing disk space as the likely fix if the setup fails.
$lowDiskFigure = ($lowDiskText -like '*Only ~0 GB free disk space detected*') -and ($lowDiskText -like '*(~0 GB free)*')
$lowDiskFixWording = $lowDiskText -like '*freeing up disk space is a likely fix*'
$lowDiskWarnPass = ($lowDiskWarnFound -and $lowDiskFigure -and $lowDiskFixWording)
$lowDiskStatusPath = Join-Path $lowDiskDir '~bootstrap.status.json'
$lowDiskBootstrapOk = $false
if (Test-Path $lowDiskStatusPath) {
  try {
    $lowDiskStatus = Get-Content -LiteralPath $lowDiskStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $lowDiskBootstrapOk = ($lowDiskStatus.state -eq 'ok' -and $lowDiskStatus.exitCode -eq 0)
  } catch { }
}
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.low_disk_warn'
  req = 'REQ-025.1'
  pass = $lowDiskWarnPass
  desc = 'REQ-025: HP_TEST_FORCE_LOW_DISK forces the low-disk-space warning, which gives the free space in whole gigabytes and names freeing disk space as the likely fix'
  details = [ordered]@{
    warnFound = $lowDiskWarnFound
    figureFound = $lowDiskFigure
    fixWordingFound = $lowDiskFixWording
    exitCode = $lowDiskExit
  }
})
if ($lowDiskWarnPass) { $summary.Add('low disk space warn: PASS') } else { $summary.Add('low disk space warn: FAIL') }
# REQ-025.2: after the warning the setup goes on and ends well (warn-only, never an abort).
$lowDiskContinuePass = ($lowDiskWarnFound -and $lowDiskBootstrapOk -and ($lowDiskExit -eq 0))
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.low_disk_continues'
  req = 'REQ-025.2'
  pass = $lowDiskContinuePass
  desc = 'REQ-025: after the low-disk-space warning the setup continues and ends with state ok and exit code 0'
  details = [ordered]@{
    warnFound = $lowDiskWarnFound
    bootstrapOk = $lowDiskBootstrapOk
    exitCode = $lowDiskExit
  }
})
if ($lowDiskContinuePass) { $summary.Add('low disk space continues: PASS') } else { $summary.Add('low disk space continues: FAIL') }
# REQ-025.3: with 2 GB or more free the warning does not appear. The free space is read here the way the batch
# file reads it; the logs of the three lock runs above (no low-disk hook set) are the evidence. A drive this script
# cannot read, or one that really is short, proves nothing, so the row passes with the inconclusive flag set.
$diskFreeGb = $null
try {
  $diskLetter = ([System.IO.Path]::GetPathRoot($TestsDir)).Substring(0, 1)
  $diskFreeGb = [math]::Floor((Get-PSDrive -Name $diskLetter).Free / 1GB)
} catch { }
$diskAmple = (($null -ne $diskFreeGb) -and ($diskFreeGb -ge 2))
$diskWarnRuns = @($lockHeldLines, $lockStaleLines, $lockIndeterminateLines)
$diskWarnLines = 0
foreach ($diskRunLines in $diskWarnRuns) { $diskWarnLines += @($diskRunLines | Where-Object { $_ -like '*low disk space detected*' }).Count }
$diskRunsRead = (($lockHeldLines.Count -gt 0) -and ($lockStaleLines.Count -gt 0) -and ($lockIndeterminateLines.Count -gt 0))
$diskAbsentPass = $true
if ($diskAmple) { $diskAbsentPass = ($diskRunsRead -and ($diskWarnLines -eq 0)) }
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.low_disk_absent'
  req = 'REQ-025.3'
  pass = $diskAbsentPass
  desc = 'REQ-025: with 2 GB or more of free space on the drive no low-disk-space warning is shown'
  details = [ordered]@{
    freeGb = $diskFreeGb
    inconclusive = (-not $diskAmple)
    runsRead = $diskRunsRead
    warningLines = $diskWarnLines
  }
})
if ($diskAbsentPass) { $summary.Add('low disk space absent: PASS') } else { $summary.Add('low disk space absent: FAIL') }

# --- OneDrive/synced-folder path warning test ---
# Arrange: run from a directory whose name contains "OneDrive" so the guardrail fires.
# Assert:  "[WARN] OneDrive path detected" appears in log and bootstrap exits 0.
$oneDriveDir = Join-Path $TestsDir '~selftest_OneDrive'
if (Test-Path $oneDriveDir) { Remove-Item -Recurse -Force $oneDriveDir }
New-Item -ItemType Directory -Force -Path $oneDriveDir | Out-Null
Copy-Item -Path $BatchPath -Destination $oneDriveDir -Force
$odLogName = '~onedrive_bootstrap.log'
Push-Location $oneDriveDir
try {
  cmd /c "call run_setup.bat > $odLogName 2>&1"
  $odExit = $LASTEXITCODE
} finally {
  Pop-Location
}
$odLogPath = Join-Path $oneDriveDir $odLogName
$odLines = @()
if (Test-Path $odLogPath) { $odLines = Get-Content -LiteralPath $odLogPath -Encoding ASCII }
$odWarnTag = 'OneDrive path detected'
$odWarnFound = ($odLines | Where-Object { $_ -like "*$odWarnTag*" }).Count -gt 0
Write-NdjsonRow ([ordered]@{
  id = 'self.warn.onedrive'
  pass = ($odWarnFound -and ($odExit -eq 0))
  desc = 'Bootstrap emits OneDrive warning and exits 0 when script path contains OneDrive'
  details = [ordered]@{
    warnFound = $odWarnFound
    exitCode = $odExit
  }
})
if ($odWarnFound -and ($odExit -eq 0)) { $summary.Add('OneDrive path warning: PASS') } else { $summary.Add('OneDrive path warning: FAIL') }

# --- System-directory guard test ---
# Arrange: run from a real folder under %WINDIR% (Windows\Temp is writable without elevation,
#          unlike Program Files) so the check-and-abort guard fires for real -- same "real
#          environmental trigger" approach as the OneDrive test above, not a test-hook flag.
# Assert:  "[ERROR] System-directory guard" appears in log and bootstrap exits 1 -- unlike the
#          OneDrive/path-length/disk-space guards (warn-only, exit 0), this one aborts.
$sdWindir = [Environment]::GetEnvironmentVariable('WINDIR')
if ($sdWindir) {
  $sysDir = Join-Path $sdWindir 'Temp\~selftest_sysdir_guard'
  if (Test-Path $sysDir) { Remove-Item -Recurse -Force $sysDir }
  New-Item -ItemType Directory -Force -Path $sysDir | Out-Null
  Copy-Item -Path $BatchPath -Destination $sysDir -Force
  $sdLogName = '~sysdir_bootstrap.log'
  Push-Location $sysDir
  try {
    cmd /c "call run_setup.bat > $sdLogName 2>&1"
    $sdExit = $LASTEXITCODE
  } finally {
    Pop-Location
  }
  $sdLogPath = Join-Path $sysDir $sdLogName
  $sdLines = @()
  if (Test-Path $sdLogPath) { $sdLines = Get-Content -LiteralPath $sdLogPath -Encoding ASCII }
  $sdErrFound = ($sdLines | Where-Object { $_ -like '*System-directory guard*' }).Count -gt 0
  $sdPass = ($sdErrFound -and ($sdExit -eq 1))
  Remove-Item -Recurse -Force $sysDir -ErrorAction SilentlyContinue
  Write-NdjsonRow ([ordered]@{
    id = 'self.warn.sysdir'
    pass = $sdPass
    desc = 'Bootstrap emits system-directory guard error and aborts (exit 1) when script root is under a Windows system folder'
    details = [ordered]@{
      errFound = $sdErrFound
      exitCode = $sdExit
    }
  })
  if ($sdPass) { $summary.Add('System-directory guard: PASS') } else { $summary.Add('System-directory guard: FAIL') }
} else {
  Write-NdjsonRow ([ordered]@{
    id = 'self.warn.sysdir'
    pass = $true
    desc = 'System-directory guard test skipped (WINDIR not set)'
    details = [ordered]@{ skip = $true; reason = 'no-windir' }
  })
  $summary.Add('System-directory guard: SKIP (no WINDIR)')
}

# The long folder path warning (REQ-003.5) is tested by tests/selfapps_longpath_near.ps1 (self.longpath.near.*),
# which uses folder paths of 199, 200 and 215 characters. The earlier row here needed a path over 260 characters,
# which a default runner cannot enter, so it reported skip on every run (docs/plan-test-suite-gaps.md T9).

# --- PATH-negative (minimal PATH env) test ---
# Arrange: run from a clean dir with hello_stub.py and a requirements.txt containing
#          a nonexistent package, using a stripped PATH env var that excludes
#          conda/python/pip. The bootstrapper discovers conda via its hardcoded
#          location (%PUBLIC%\Documents\Miniconda3); the fake package triggers
#          [WARN] proving no silent failure when packages cannot install.
# Assert:  [WARN] appears in the log and bootstrap exits 0 (fallback works).
$pathNegDir = Join-Path $TestsDir '~selftest_path_negative'
if (Test-Path $pathNegDir) { Remove-Item -Recurse -Force $pathNegDir }
New-Item -ItemType Directory -Force -Path $pathNegDir | Out-Null
Copy-Item -Path $BatchPath -Destination $pathNegDir -Force
Set-Content -Path (Join-Path $pathNegDir 'hello_stub.py') -Value 'print("hello-from-stub")' -Encoding ASCII
Set-Content -Path (Join-Path $pathNegDir 'requirements.txt') -Value '_fake_pkg_pathwarn_xyz_' -Encoding ASCII
$pnLogName = '~path_negative_bootstrap.log'
$pnMinPath = "$env:SystemRoot\System32;$env:SystemRoot;$env:SystemRoot\System32\WindowsPowerShell\v1.0"
Push-Location $pathNegDir
try {
  cmd /c "set PATH=$pnMinPath&call run_setup.bat > $pnLogName 2>&1"
  $pnExit = $LASTEXITCODE
} finally {
  Pop-Location
}
$pnLogPath = Join-Path $pathNegDir $pnLogName
$pnLines = @()
if (Test-Path $pnLogPath) { $pnLines = Get-Content -LiteralPath $pnLogPath -Encoding ASCII }
$pnWarnFound = ($pnLines | Where-Object { $_ -match '\[WARN\]' }).Count -gt 0
$pnStatusPath = Join-Path $pathNegDir '~bootstrap.status.json'
$pnExitedOk = $false
if (Test-Path $pnStatusPath) {
  try {
    $pnStatus = Get-Content -LiteralPath $pnStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $pnExitedOk = ($pnStatus.exitCode -eq 0)
  } catch { }
}
Write-NdjsonRow ([ordered]@{
  id = 'self.warn.path_negative'
  pass = ($pnWarnFound -and $pnExitedOk)
  desc = 'Bootstrap emits [WARN] and exits 0 with minimal PATH (hardcoded conda fallback; no silent failure)'
  details = [ordered]@{
    warnFound = $pnWarnFound
    exitCode = $pnExit
    continued = $pnExitedOk
  }
})
if ($pnWarnFound -and $pnExitedOk) { $summary.Add('PATH-negative (minimal PATH): PASS') } else { $summary.Add('PATH-negative (minimal PATH): FAIL') }


# --- G1 guardrail: ENVNAME derivation warns when folder name is all non-word chars ---
# Arrange: dir named '~@~' so every char is outside [A-Za-z0-9_-]; sanitizes to '___'
# which Trim('_') empties, forcing the default 'env' and triggering [WARN].
$g1Base   = Join-Path $TestsDir '~selftest_guardrail_g1'
$g1RunDir = Join-Path $g1Base   '~@~'
if (Test-Path $g1Base) { Remove-Item -Recurse -Force $g1Base }
New-Item -ItemType Directory -Force -Path $g1RunDir | Out-Null
Copy-Item -Path $BatchPath -Destination $g1RunDir -Force
$g1LogName = '~g1_bootstrap.log'
Push-Location $g1RunDir
try {
  cmd /c "call run_setup.bat > $g1LogName 2>&1"
  $g1Exit = $LASTEXITCODE
} finally {
  Pop-Location
}
$g1LogPath = Join-Path $g1RunDir $g1LogName
$g1Lines   = @()
if (Test-Path $g1LogPath) { $g1Lines = Get-Content -LiteralPath $g1LogPath -Encoding ASCII }
$g1WarnTag   = 'Env name could not be derived from'
$g1WarnFound = ($g1Lines | Where-Object { $_ -like "*$g1WarnTag*" }).Count -gt 0
Write-NdjsonRow ([ordered]@{
  id   = 'self.guardrail.g1'
  pass = ($g1WarnFound -and ($g1Exit -eq 0))
  desc = 'G1: all-non-word folder name emits [WARN] and exits 0 (no silent ENVNAME expansion)'
  details = [ordered]@{ warnFound = $g1WarnFound; exitCode = $g1Exit }
})
if ($g1WarnFound -and ($g1Exit -eq 0)) { $summary.Add('G1 (ENVNAME guard warn): PASS') } else { $summary.Add('G1 (ENVNAME guard warn): FAIL') }

# --- G2 guardrail: interpreter resolved to non-empty path (no empty-command expansion) ---
# Assert: the stub bootstrap log contains 'Interpreter: <non-empty-path>' proving
# HP_PY was guarded before use and no empty-string command was expanded.
$g2LogPath   = Join-Path $stubDir $stubBootstrapLog
$g2Lines     = @()
if (Test-Path $g2LogPath) { $g2Lines = Get-Content -LiteralPath $g2LogPath -Encoding ASCII }
$g2InterpLine = $g2Lines | Where-Object { $_ -like 'Interpreter: ?*' } | Select-Object -First 1
$g2InterpOk   = $null -ne $g2InterpLine
Write-NdjsonRow ([ordered]@{
  id   = 'self.guardrail.g2'
  pass = $g2InterpOk
  desc = 'G2: interpreter resolved to non-empty path before execution (no empty-command expansion)'
  details = [ordered]@{
    found    = $g2InterpOk
    interpLine = if ($g2InterpLine) { $g2InterpLine.Substring(0, [Math]::Min(80, $g2InterpLine.Length)) } else { '' }
  }
})
if ($g2InterpOk) { $summary.Add('G2 (interpreter non-empty): PASS') } else { $summary.Add('G2 (interpreter non-empty): FAIL') }

# --- G3 guardrail: dependency failure path is observable and non-fatal ---
# Reuses pip-install-warn scenario: a bad requirements.txt causes pip install to fail;
# bootstrap must emit [WARN] and continue (state=ok), not silently stop.
$g3Pass = ($pipWarnFound -and $pipWarnContinued)
Write-NdjsonRow ([ordered]@{
  id   = 'self.guardrail.g3'
  pass = $g3Pass
  desc = 'G3: dependency install failure emits [WARN] and bootstrap exits 0 (no silent failure)'
  details = [ordered]@{ warnInLog = $pipWarnFound; bootstrapContinued = $pipWarnContinued }
})
if ($g3Pass) { $summary.Add('G3 (no-silent-failure): PASS') } else { $summary.Add('G3 (no-silent-failure): FAIL') }

# --- PEP 723 valid block test ---
# Arrange: script with a well-formed PEP 723 inline dependency block.
# Assert:  bootstrap log contains "Using PEP 723 inline dependency metadata" and exits 0.
$pep723ValidDir = Join-Path $TestsDir '~selftest_pep723_valid'
if (Test-Path $pep723ValidDir) { Remove-Item -Recurse -Force $pep723ValidDir }
New-Item -ItemType Directory -Force -Path $pep723ValidDir | Out-Null
Copy-Item -Path $BatchPath -Destination $pep723ValidDir -Force
$pep723ValidScript = @'
# /// script
# dependencies = [
# "packaging"
# ]
# ///
print("pep723-valid")
'@
Set-Content -Path (Join-Path $pep723ValidDir 'app_pep723.py') -Value $pep723ValidScript -Encoding ASCII
$pep723ValidLogName = '~pep723_valid_bootstrap.log'
Push-Location $pep723ValidDir
try {
  cmd /c "call run_setup.bat > $pep723ValidLogName 2>&1"
  $pep723ValidExit = $LASTEXITCODE
} finally {
  Pop-Location
}
$pep723ValidLogPath = Join-Path $pep723ValidDir $pep723ValidLogName
$pep723ValidLines = @()
if (Test-Path $pep723ValidLogPath) { $pep723ValidLines = Get-Content -LiteralPath $pep723ValidLogPath -Encoding ASCII }
$pep723ValidTag = 'Using PEP 723 inline dependency metadata'
$pep723ValidFound = ($pep723ValidLines | Where-Object { $_ -like "*$pep723ValidTag*" }).Count -gt 0
$pep723ValidStatusPath = Join-Path $pep723ValidDir '~bootstrap.status.json'
$pep723ValidContinued = $false
if (Test-Path $pep723ValidStatusPath) {
  try {
    $pep723ValidStatus = Get-Content -LiteralPath $pep723ValidStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $pep723ValidContinued = ($pep723ValidStatus.exitCode -eq 0)
  } catch { }
}
Write-NdjsonRow ([ordered]@{
  id = 'self.pep723.valid'
  pass = ($pep723ValidFound -and $pep723ValidContinued)
  desc = 'PEP 723 valid block: bootstrap uses inline metadata as dep source and exits 0'
  details = [ordered]@{
    metadataFound = $pep723ValidFound
    continued = $pep723ValidContinued
  }
})
if ($pep723ValidFound -and $pep723ValidContinued) { $summary.Add('PEP 723 valid block: PASS') } else { $summary.Add('PEP 723 valid block: FAIL') }

# --- PEP 723 block exactly as uv writes it (CLAUDE.md Item 62) ---
# Arrange: a block byte-for-byte in the shape `uv add --script` produces: CRLF line endings, a
#          `requires-python` line, items indented four spaces after the `# ` and a trailing comma
#          after every item (the bootstrapper's own write-back and any user who ran uv write this shape).
#          The sibling `self.pep723.valid` fixture (one space, no comma) is kept as the hand-written case.
# Assert:  the block is accepted as the dependency source (no "no valid dependencies extracted" WARN)
#          and `~requirements.pep723.txt` holds exactly the two bare specs, in order, with no quote,
#          comma or leading whitespace left over.
# derived requirement: the extractor previously accepted only `# "<item>"` (one space, no comma), so a
# header uv had just written was reported as malformed and the dependencies were silently dropped.
$pep723UvDir = Join-Path $TestsDir '~selftest_pep723_uvformat'
if (Test-Path $pep723UvDir) { Remove-Item -Recurse -Force $pep723UvDir }
New-Item -ItemType Directory -Force -Path $pep723UvDir | Out-Null
Copy-Item -Path $BatchPath -Destination $pep723UvDir -Force
$pep723UvLines = @(
  '# /// script',
  '# requires-python = ">=3.9"',
  '# dependencies = [',
  '#     "packaging>=24.0",',
  '#     "colorama>=0.4.6",',
  '# ]',
  '# ///',
  'print("pep723-uvformat")'
)
# Written as raw ASCII bytes with explicit CRLF so the fixture is identical on every checkout.
$pep723UvBytes = [System.Text.Encoding]::ASCII.GetBytes(($pep723UvLines -join "`r`n") + "`r`n")
[System.IO.File]::WriteAllBytes((Join-Path $pep723UvDir 'app_pep723_uv.py'), $pep723UvBytes)
$pep723UvLogName = '~pep723_uvformat_bootstrap.log'
Push-Location $pep723UvDir
try {
  cmd /c "call run_setup.bat > $pep723UvLogName 2>&1"
  $pep723UvExit = $LASTEXITCODE
} finally {
  Pop-Location
}
$pep723UvLogPath = Join-Path $pep723UvDir $pep723UvLogName
$pep723UvLog = @()
if (Test-Path $pep723UvLogPath) { $pep723UvLog = Get-Content -LiteralPath $pep723UvLogPath -Encoding ASCII }
$pep723UvFound = ($pep723UvLog | Where-Object { $_ -like '*Using PEP 723 inline dependency metadata*' }).Count -gt 0
$pep723UvEmptyWarn = ($pep723UvLog | Where-Object { $_ -like '*PEP 723 block found but no valid dependencies extracted*' }).Count -gt 0
$pep723UvReqPath = Join-Path $pep723UvDir '~requirements.pep723.txt'
$pep723UvExtracted = @()
# Compare raw lines, no Trim(): the helper's contract is bare specs, so stray whitespace must fail.
if (Test-Path $pep723UvReqPath) {
  $pep723UvExtracted = @(Get-Content -LiteralPath $pep723UvReqPath -Encoding ASCII | Where-Object { $_ -ne '' })
}
$pep723UvExpected = @('packaging>=24.0', 'colorama>=0.4.6')
$pep723UvExtractedOk = (($pep723UvExtracted -join '|') -ceq ($pep723UvExpected -join '|'))
$pep723UvStatusPath = Join-Path $pep723UvDir '~bootstrap.status.json'
$pep723UvContinued = $false
if (Test-Path $pep723UvStatusPath) {
  try {
    $pep723UvStatus = Get-Content -LiteralPath $pep723UvStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $pep723UvContinued = ($pep723UvStatus.exitCode -eq 0)
  } catch { }
}
$pep723UvPass = ($pep723UvFound -and (-not $pep723UvEmptyWarn) -and $pep723UvExtractedOk -and $pep723UvContinued)
Write-NdjsonRow ([ordered]@{
  id = 'self.pep723.uvformat'
  pass = $pep723UvPass
  desc = 'PEP 723 block in uv-written shape (CRLF, indented items, trailing commas) is accepted and its deps extracted'
  details = [ordered]@{
    metadataFound = $pep723UvFound
    emptyWarn = $pep723UvEmptyWarn
    extracted = ($pep723UvExtracted -join ' ; ')
    extractedOk = $pep723UvExtractedOk
    continued = $pep723UvContinued
  }
})
if ($pep723UvPass) { $summary.Add('PEP 723 uv-written block: PASS') } else { $summary.Add('PEP 723 uv-written block: FAIL') }

# --- PEP 723 malformed block test ---
# Arrange: script with "# /// script" present but no valid dependencies block.
# Assert:  bootstrap log contains "[WARN] PEP 723 block found but no valid" and exits 0 (pipreqs fallback).
$pep723MalDir = Join-Path $TestsDir '~selftest_pep723_mal'
if (Test-Path $pep723MalDir) { Remove-Item -Recurse -Force $pep723MalDir }
New-Item -ItemType Directory -Force -Path $pep723MalDir | Out-Null
Copy-Item -Path $BatchPath -Destination $pep723MalDir -Force
$pep723MalScript = @'
# /// script
# malformed: missing dependencies array and no closing marker
print("pep723-mal")
'@
Set-Content -Path (Join-Path $pep723MalDir 'app_pep723_mal.py') -Value $pep723MalScript -Encoding ASCII
$pep723MalLogName = '~pep723_mal_bootstrap.log'
Push-Location $pep723MalDir
try {
  cmd /c "call run_setup.bat > $pep723MalLogName 2>&1"
  $pep723MalExit = $LASTEXITCODE
} finally {
  Pop-Location
}
$pep723MalLogPath = Join-Path $pep723MalDir $pep723MalLogName
$pep723MalLines = @()
if (Test-Path $pep723MalLogPath) { $pep723MalLines = Get-Content -LiteralPath $pep723MalLogPath -Encoding ASCII }
$pep723MalWarnTag = 'PEP 723 block found but no valid dependencies extracted'
$pep723MalWarnFound = ($pep723MalLines | Where-Object { $_ -like "*$pep723MalWarnTag*" }).Count -gt 0
$pep723MalStatusPath = Join-Path $pep723MalDir '~bootstrap.status.json'
$pep723MalContinued = $false
if (Test-Path $pep723MalStatusPath) {
  try {
    $pep723MalStatus = Get-Content -LiteralPath $pep723MalStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $pep723MalContinued = ($pep723MalStatus.exitCode -eq 0)
  } catch { }
}
Write-NdjsonRow ([ordered]@{
  id = 'self.pep723.malformed'
  pass = ($pep723MalWarnFound -and $pep723MalContinued)
  desc = 'PEP 723 malformed block: bootstrap emits [WARN] and exits 0 (pipreqs fallback, no hard failure)'
  details = [ordered]@{
    warnFound = $pep723MalWarnFound
    continued = $pep723MalContinued
  }
})
if ($pep723MalWarnFound -and $pep723MalContinued) { $summary.Add('PEP 723 malformed block: PASS') } else { $summary.Add('PEP 723 malformed block: FAIL') }

# --- pyproject.toml malformed TOML test (REQ-005.1) ---
# Arrange: a .py file + pyproject.toml containing invalid TOML (missing closing bracket on [project).
# Assert:  bootstrap emits [WARN] pyproject.toml TOML parse error and exits 0 (pipreqs fallback).
# derived requirement: REQ-005.1 silent-fallback rule; malformed TOML must surface a warning so the
# user knows their dependency spec was not used, consistent with the PEP 723 malformed behavior.
$pypmtMalDir = Join-Path $TestsDir '~selftest_pyproj_malformed'
if (Test-Path $pypmtMalDir) { Remove-Item -Recurse -Force $pypmtMalDir }
New-Item -ItemType Directory -Force -Path $pypmtMalDir | Out-Null
Copy-Item -Path $BatchPath -Destination $pypmtMalDir -Force
Set-Content -Path (Join-Path $pypmtMalDir 'app_ppm.py') -Value 'print("pyproject-mal")' -Encoding ASCII
# pyproject.toml with a missing closing bracket on the section header -- invalid TOML.
$pypmtMalToml = @'
[project
name = "malformed-app"
'@
Set-Content -Path (Join-Path $pypmtMalDir 'pyproject.toml') -Value $pypmtMalToml -Encoding ASCII
$pypmtLogName = '~pyproj_mal_bootstrap.log'
Push-Location $pypmtMalDir
try {
  cmd /c "call run_setup.bat > $pypmtLogName 2>&1"
} finally {
  Pop-Location
}
$pypmtMalLogPath = Join-Path $pypmtMalDir $pypmtLogName
$pypmtMalLines = @()
if (Test-Path $pypmtMalLogPath) { $pypmtMalLines = Get-Content -LiteralPath $pypmtMalLogPath -Encoding ASCII }
$pypmtMalWarnTag = 'pyproject.toml TOML parse error'
$pypmtMalWarnFound = ($pypmtMalLines | Where-Object { $_ -like "*$pypmtMalWarnTag*" }).Count -gt 0
$pypmtMalStatusPath = Join-Path $pypmtMalDir '~bootstrap.status.json'
$pypmtMalContinued = $false
if (Test-Path $pypmtMalStatusPath) {
  try {
    $pypmtMalStatus = Get-Content -LiteralPath $pypmtMalStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $pypmtMalContinued = ($pypmtMalStatus.exitCode -eq 0)
  } catch { }
}
Write-NdjsonRow ([ordered]@{
  id = 'self.pyproject.malformed'
  pass = ($pypmtMalWarnFound -and $pypmtMalContinued)
  desc = 'pyproject.toml TOML parse error: bootstrap emits [WARN] and exits 0 (pipreqs fallback, no hard failure)'
  req = 'REQ-005.1'
  details = [ordered]@{
    warnFound = $pypmtMalWarnFound
    continued = $pypmtMalContinued
  }
})
if ($pypmtMalWarnFound -and $pypmtMalContinued) { $summary.Add('pyproject.toml malformed: PASS') } else { $summary.Add('pyproject.toml malformed: FAIL') }

# --- PEP 723 header and pyproject.toml are merged, not chosen between (REQ-005.1, Item 89) ---
# Arrange: script with PEP 723 metadata (packaging) + pyproject.toml with a different dep (colorama), no requirements.txt.
# Assert:  bootstrap detects both lists and merges them (a cold first run is a union); DEP_SOURCE=pep723 (the
#          highest ranked input, which settles conflicts), requirements.txt holds both, exits 0.
# derived requirement: REQ-005.1 ranks the header over pyproject.toml only for a CONFLICT about one package;
# a package only one of them lists is still a dependency. Before Item 89 the row proved the header threw
# the pyproject list away, which is the behavior the maintainer rejected.
$pep723PrioDir = Join-Path $TestsDir '~selftest_pep723_prio'
if (Test-Path $pep723PrioDir) { Remove-Item -Recurse -Force $pep723PrioDir }
New-Item -ItemType Directory -Force -Path $pep723PrioDir | Out-Null
Copy-Item -Path $BatchPath -Destination $pep723PrioDir -Force
# PEP 723 dep: packaging. pyproject.toml dep: colorama. Both must end up in requirements.txt.
# Extract subroutine expects exactly "# " + quote (one space); extra spaces would break parsing.
$pep723PrioScript = @'
# /// script
# dependencies = [
# "packaging"
# ]
# ///
print("pep723-priority-test")
'@
Set-Content -Path (Join-Path $pep723PrioDir 'app_pep723_prio.py') -Value $pep723PrioScript -Encoding ASCII
$pep723PrioPyproj = @'
[project]
name = "pep723-prio-test"
dependencies = [
  "colorama"
]
'@
Set-Content -Path (Join-Path $pep723PrioDir 'pyproject.toml') -Value $pep723PrioPyproj -Encoding ASCII
$pep723PrioLogName = '~pep723_prio_bootstrap.log'
Push-Location $pep723PrioDir
try {
  cmd /c "call run_setup.bat > $pep723PrioLogName 2>&1"
  $pep723PrioExit = $LASTEXITCODE
} finally {
  Pop-Location
}
$pep723PrioLogPath = Join-Path $pep723PrioDir $pep723PrioLogName
$pep723PrioLines = @()
if (Test-Path $pep723PrioLogPath) { $pep723PrioLines = Get-Content -LiteralPath $pep723PrioLogPath -Encoding ASCII }
# pyproject.toml must have been detected (exercises the priority code path, not a degenerate skip).
# Use .Contains() instead of -like because -like treats [project] as a char-class wildcard.
$pep723PrioPyprojectTag = 'pyproject.toml [project].dependencies found'
$pep723PrioPyprojectDetected = ($pep723PrioLines | Where-Object { $_.Contains($pep723PrioPyprojectTag) }).Count -gt 0
# The header is the highest ranked input, so it is the recorded source; the merge must have said so.
$pep723PrioWinTag = 'Using PEP 723 inline dependency metadata'
$pep723PrioWon = ($pep723PrioLines | Where-Object { $_ -like "*$pep723PrioWinTag*" }).Count -gt 0
$pep723PrioMergeTag = 'Dependency lists merged'
$pep723PrioMerged = ($pep723PrioLines | Where-Object { $_.Contains($pep723PrioMergeTag) }).Count -gt 0
$pep723PrioStatusPath = Join-Path $pep723PrioDir '~bootstrap.status.json'
$pep723PrioContinued = $false
if (Test-Path $pep723PrioStatusPath) {
  try {
    $pep723PrioStatus = Get-Content -LiteralPath $pep723PrioStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $pep723PrioContinued = ($pep723PrioStatus.exitCode -eq 0)
  } catch { }
}
# Final-state check: requirements.txt must contain the PEP 723 dep (packaging) AND the pyproject dep
# (colorama). A refactor that goes back to copying one list over the other would fail here even if
# both log lines were still emitted.
$pep723PrioReqPath = Join-Path $pep723PrioDir 'requirements.txt'
$pep723PrioReqHasPackaging = $false
$pep723PrioReqHasColorama  = $false
if (Test-Path -LiteralPath $pep723PrioReqPath) {
  $pep723PrioReqContent = Get-Content -LiteralPath $pep723PrioReqPath -Encoding ASCII -Raw
  $pep723PrioReqHasPackaging = $pep723PrioReqContent -match 'packaging'
  $pep723PrioReqHasColorama  = $pep723PrioReqContent -match 'colorama'
}
$pep723PrioPass = ($pep723PrioPyprojectDetected -and $pep723PrioWon -and $pep723PrioMerged -and $pep723PrioContinued -and $pep723PrioReqHasPackaging -and $pep723PrioReqHasColorama)
Write-NdjsonRow ([ordered]@{
  id   = 'self.pep723.pyproject.merge'
  req  = 'REQ-005.1'
  pass = $pep723PrioPass
  desc = 'PEP 723 header and pyproject.toml [project].dependencies are merged on a first run: both lists end up in requirements.txt, the header is the recorded source (REQ-005.1)'
  details = [ordered]@{
    pyprojectDetected = $pep723PrioPyprojectDetected
    pep723Won         = $pep723PrioWon
    merged            = $pep723PrioMerged
    continued         = $pep723PrioContinued
    exitCode          = $pep723PrioExit
    reqHasPackaging   = $pep723PrioReqHasPackaging
    reqHasColorama    = $pep723PrioReqHasColorama
  }
})
if ($pep723PrioPass) { $summary.Add('PEP 723 and pyproject merged: PASS') } else { $summary.Add('PEP 723 and pyproject merged: FAIL') }

# derived requirement: CONDA_BAT is set by :select_conda_bat only when
# %PUBLIC%\Documents\Miniconda3\condabin\conda.bat exists on disk. In uv-first
# fresh lanes, Miniconda is never installed so the corruption check precondition
# is never met. The cache lane still exercises these tests (Miniconda cached).
$condaBatOnDisk = Test-Path -LiteralPath (Join-Path $MiniRoot 'condabin\conda.bat')
if ($condaBatOnDisk) {

# --- Conda binary corruption detection test (REQ-020) ---
# Arrange: HP_TEST_CORRUPT_CONDA=1 simulates a corrupt conda binary.
# Assert:  bootstrap exits 2 and log contains the corruption-detected error message.
# Note: test runs only when conda is already installed from the prior bootstrap run;
#       HP_CONDA_JUST_INSTALLED guards fresh-install runs from triggering the check.
$corruptDir = Join-Path $TestsDir '~selftest_corrupt_conda'
if (Test-Path $corruptDir) { Remove-Item -Recurse -Force $corruptDir }
New-Item -ItemType Directory -Force -Path $corruptDir | Out-Null
Copy-Item -Path $BatchPath -Destination $corruptDir -Force
Set-Content -Path (Join-Path $corruptDir 'app_corrupt_test.py') -Value 'print("should-not-reach")' -Encoding ASCII
$corruptLogName = '~corrupt_bootstrap.log'
$env:HP_TEST_CORRUPT_CONDA = '1'
$prevCILane = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $corruptDir
try {
  cmd /c "call run_setup.bat > $corruptLogName 2>&1"
  $corruptExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_CORRUPT_CONDA = ''
  $env:HP_CI_LANE = $prevCILane
}
$corruptLogPath = Join-Path $corruptDir $corruptLogName
$corruptLines = if (Test-Path $corruptLogPath) { Get-Content -LiteralPath $corruptLogPath -Encoding ASCII } else { @() }
$corruptMsgFound = ($corruptLines | Where-Object { $_ -like '*Corrupt conda binary*' }).Count -gt 0
Write-NdjsonRow ([ordered]@{
  id      = 'self.corrupt.conda.detect'
  req     = 'REQ-020'
  pass    = ($corruptExit -eq 2 -and $corruptMsgFound)
  desc    = 'HP_TEST_CORRUPT_CONDA=1: bootstrap detects corruption, logs error, exits 2'
  details = [ordered]@{ exitCode = $corruptExit; msgFound = $corruptMsgFound }
})
if ($corruptExit -eq 2 -and $corruptMsgFound) { $summary.Add('Corrupt conda detect: PASS') } else { $summary.Add('Corrupt conda detect: FAIL') }

# --- Conda binary corruption heal-decline test (REQ-020 Task 3) ---
# Arrange: HP_TEST_CORRUPT_CONDA=1 + HP_TEST_HEAL_ANSWER=N simulates user declining self-heal.
# Assert:  bootstrap exits 2 and log contains "declined".
# Note: HP_TEST_HEAL_ANSWER bypasses the HP_CI_LANE gate so this test works in CI without pausing.
$healDir = Join-Path $TestsDir '~selftest_heal_decline'
if (Test-Path $healDir) { Remove-Item -Recurse -Force $healDir }
New-Item -ItemType Directory -Force -Path $healDir | Out-Null
Copy-Item -Path $BatchPath -Destination $healDir -Force
Set-Content -Path (Join-Path $healDir 'app_heal_decline_test.py') -Value 'print("should-not-reach")' -Encoding ASCII
$healLogName = '~heal_decline_bootstrap.log'
$env:HP_TEST_CORRUPT_CONDA = '1'
$env:HP_TEST_HEAL_ANSWER = 'N'
$prevCILane2 = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $healDir
try {
  cmd /c "call run_setup.bat > $healLogName 2>&1"
  $healExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_CORRUPT_CONDA = ''
  $env:HP_TEST_HEAL_ANSWER = ''
  $env:HP_CI_LANE = $prevCILane2
}
$healLogPath = Join-Path $healDir $healLogName
$healLines = if (Test-Path $healLogPath) { Get-Content -LiteralPath $healLogPath -Encoding ASCII } else { @() }
$healDeclineMsgFound = ($healLines | Where-Object { $_ -like '*declined*' }).Count -gt 0
Write-NdjsonRow ([ordered]@{
  id      = 'self.corrupt.conda.heal.decline'
  req     = 'REQ-020'
  pass    = ($healExit -eq 2 -and $healDeclineMsgFound)
  desc    = 'HP_TEST_HEAL_ANSWER=N: user declines self-heal, bootstrap logs declined and exits 2'
  details = [ordered]@{ exitCode = $healExit; declineMsgFound = $healDeclineMsgFound }
})
if ($healExit -eq 2 -and $healDeclineMsgFound) { $summary.Add('Heal decline: PASS') } else { $summary.Add('Heal decline: FAIL') }

# --- Conda binary corruption heal-accept test (REQ-020) ---
# Arrange: HP_TEST_CORRUPT_CONDA=1 + HP_TEST_HEAL_ANSWER=Y + HP_TEST_SKIP_EVICT=1.
# HP_TEST_SKIP_EVICT prevents the actual rmdir + Miniconda re-download so CI conda stays intact.
# The eviction log line is still emitted, proving the Y-branch (goto :evict_and_rebuild) fired.
# Assert: exit 0, eviction log line present, bootstrap status ok.
$healAcceptDir = Join-Path $TestsDir '~selftest_heal_accept'
if (Test-Path $healAcceptDir) { Remove-Item -Recurse -Force $healAcceptDir }
New-Item -ItemType Directory -Force -Path $healAcceptDir | Out-Null
Copy-Item -Path $BatchPath -Destination $healAcceptDir -Force
Set-Content -Path (Join-Path $healAcceptDir 'app_heal_accept_test.py') -Value 'print("heal-accept-ok")' -Encoding ASCII
$healAcceptLogName = '~heal_accept_bootstrap.log'
$env:HP_TEST_CORRUPT_CONDA = '1'
$env:HP_TEST_HEAL_ANSWER = 'Y'
$env:HP_TEST_SKIP_EVICT = '1'
$prevCILaneHA = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $healAcceptDir
try {
  cmd /c "call run_setup.bat > $healAcceptLogName 2>&1"
  $healAcceptExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_CORRUPT_CONDA = ''
  $env:HP_TEST_HEAL_ANSWER = ''
  $env:HP_TEST_SKIP_EVICT = ''
  $env:HP_CI_LANE = $prevCILaneHA
}
$healAcceptLogPath = Join-Path $healAcceptDir $healAcceptLogName
$healAcceptLines = if (Test-Path $healAcceptLogPath) { Get-Content -LiteralPath $healAcceptLogPath -Encoding ASCII } else { @() }
$healAcceptEvictMsgFound = ($healAcceptLines | Where-Object { $_ -like '*Self-healing: corrupt conda evicted*' }).Count -gt 0
$healAcceptStatusPath = Join-Path $healAcceptDir '~bootstrap.status.json'
$healAcceptState = if (Test-Path $healAcceptStatusPath) {
  try { (Get-Content -LiteralPath $healAcceptStatusPath -Raw | ConvertFrom-Json).state } catch { 'read-error' }
} else { 'missing' }
Write-NdjsonRow ([ordered]@{
  id      = 'self.corrupt.conda.heal.accept'
  req     = 'REQ-020'
  pass    = ($healAcceptExit -eq 0 -and $healAcceptEvictMsgFound -and $healAcceptState -eq 'ok')
  desc    = 'HP_TEST_HEAL_ANSWER=Y + HP_TEST_SKIP_EVICT=1: accept branch fires, eviction logged, bootstrap ok'
  details = [ordered]@{
    exitCode   = $healAcceptExit
    evictFound = $healAcceptEvictMsgFound
    state      = $healAcceptState
  }
})
if ($healAcceptExit -eq 0 -and $healAcceptEvictMsgFound -and $healAcceptState -eq 'ok') {
  $summary.Add('Heal accept: PASS')
} else {
  $summary.Add('Heal accept: FAIL')
}
} else {
  foreach ($id in @('self.corrupt.conda.detect', 'self.corrupt.conda.heal.decline', 'self.corrupt.conda.heal.accept')) {
    Write-NdjsonRow ([ordered]@{
      id      = $id
      req     = 'REQ-020'
      pass    = $true
      desc    = 'Corrupt conda test: Miniconda not on disk in uv-first lane; skip'
      details = [ordered]@{ skip = $true; reason = 'miniconda-not-on-disk' }
    })
  }
  $summary.Add('Corrupt conda tests: SKIP (miniconda-not-on-disk)')
}

# --- Conda binary corruption, PVW_CONDA_EXE super-user-override path (CLAUDE.md Active
#     Backlog item 12) ---
# Arrange: PVW_CONDA_EXE=<any path, does not need to exist -- HP_TEST_CORRUPT_CONDA=1 routes
#          straight to :conda_binary_corrupt before "%CONDA_BAT%" info is ever actually called>
#          + HP_TEST_CORRUPT_CONDA=1. Unlike the three scenarios above, this one does NOT need
#          real Miniconda pre-installed on disk: run_setup.bat unconditionally sets
#          CONDA_BAT=%PVW_CONDA_EXE% the moment PVW_CONDA_EXE is defined (before the Miniconda
#          install-if-missing block even runs), so "if defined CONDA_BAT" is satisfied and the
#          corruption-check gate fires regardless of whether Miniconda was ever installed
#          anywhere in this job -- self-contained by construction, no CI-ordering dependency.
# Assert:  :conda_binary_corrupt routes to :corrupt_override_exit (skipping self-heal entirely,
#          since the conda root is user-managed, not bootstrapper-owned) -- bootstrap exits 2,
#          logs the distinct "fix manually" error, and the on-screen guidance names the
#          PVW_CONDA_EXE path and says automatic self-healing is unavailable.
$overrideDir = Join-Path $TestsDir '~selftest_corrupt_override'
if (Test-Path $overrideDir) { Remove-Item -Recurse -Force $overrideDir }
New-Item -ItemType Directory -Force -Path $overrideDir | Out-Null
Copy-Item -Path $BatchPath -Destination $overrideDir -Force
Set-Content -Path (Join-Path $overrideDir 'app_corrupt_override_test.py') -Value 'print("should-not-reach")' -Encoding ASCII
$overrideLogName = '~corrupt_override_bootstrap.log'
$fakeCondaExe = Join-Path $overrideDir 'fake_user_managed_conda.bat'
$env:HP_TEST_CORRUPT_CONDA = '1'
$prevPvwCondaExe = if (Test-Path Env:PVW_CONDA_EXE) { $env:PVW_CONDA_EXE } else { $null }
$env:PVW_CONDA_EXE = $fakeCondaExe
$prevCILaneOverride = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $overrideDir
try {
  cmd /c "call run_setup.bat > $overrideLogName 2>&1"
  $overrideExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_CORRUPT_CONDA = ''
  if ($null -eq $prevPvwCondaExe) { Remove-Item Env:PVW_CONDA_EXE -ErrorAction SilentlyContinue } else { $env:PVW_CONDA_EXE = $prevPvwCondaExe }
  $env:HP_CI_LANE = $prevCILaneOverride
}
$overrideLogPath = Join-Path $overrideDir $overrideLogName
$overrideLines = if (Test-Path $overrideLogPath) { Get-Content -LiteralPath $overrideLogPath -Encoding ASCII } else { @() }
$overrideMsgFound = ($overrideLines | Where-Object { $_ -like '*Corrupt user-managed conda (PVW_CONDA_EXE); fix manually.*' }).Count -gt 0
$overrideGuidanceFound = ($overrideLines | Where-Object { $_ -like '*Automatic self-healing is not available for user-managed conda.*' }).Count -gt 0
Write-NdjsonRow ([ordered]@{
  id      = 'self.corrupt.conda.override_exit'
  req     = 'REQ-020'
  pass    = ($overrideExit -eq 2 -and $overrideMsgFound -and $overrideGuidanceFound)
  desc    = 'PVW_CONDA_EXE + HP_TEST_CORRUPT_CONDA=1: self-heal skipped for user-managed conda, exits 2 with manual-fix guidance'
  details = [ordered]@{ exitCode = $overrideExit; msgFound = $overrideMsgFound; guidanceFound = $overrideGuidanceFound }
})
if ($overrideExit -eq 2 -and $overrideMsgFound -and $overrideGuidanceFound) {
  $summary.Add('Corrupt conda PVW_CONDA_EXE override: PASS')
} else {
  $summary.Add('Corrupt conda PVW_CONDA_EXE override: FAIL')
}

# --- UV binary corruption eviction test (REQ-020 Task 4) ---
# Arrange: create fake ~uv_bin\uv.exe + HP_TEST_CORRUPT_UV=1 simulates corrupt cached uv binary.
# Assert:  bootstrap logs the eviction warning.
# Skip in conda-only lane (HP_FORCE_CONDA_ONLY=1 bypasses uv path entirely).
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
  Write-NdjsonRow ([ordered]@{
    id      = 'self.corrupt.uv.detect'
    req     = 'REQ-020'
    pass    = $true
    desc    = 'HP_TEST_CORRUPT_UV: uv eviction test skipped in conda-only lane'
    details = [ordered]@{ skipped = $true; reason = 'HP_FORCE_CONDA_ONLY=1' }
  })
  $summary.Add('Corrupt uv detect: SKIP (conda-only)')
} else {
  $uvCorruptDir = Join-Path $TestsDir '~selftest_corrupt_uv'
  if (Test-Path $uvCorruptDir) { Remove-Item -Recurse -Force $uvCorruptDir }
  New-Item -ItemType Directory -Force -Path $uvCorruptDir | Out-Null
  Copy-Item -Path $BatchPath -Destination $uvCorruptDir -Force
  Set-Content -Path (Join-Path $uvCorruptDir 'app_corrupt_uv_test.py') -Value 'print("corrupt-uv-test")' -Encoding ASCII
  $uvBinDir = Join-Path $uvCorruptDir '~uv_bin'
  New-Item -ItemType Directory -Force -Path $uvBinDir | Out-Null
  Set-Content -Path (Join-Path $uvBinDir 'uv.exe') -Value '' -Encoding ASCII
  $uvLogName = '~corrupt_uv_bootstrap.log'
  $env:HP_TEST_CORRUPT_UV = '1'
  # derived requirement: HP_TEST_FORCE_UV_FAIL (e.g. justme-test lane) must be cleared;
  # the gate at line 296 fires before the cached-uv check at line 302 where HP_TEST_CORRUPT_UV fires.
  $prevForceUvFail3 = $env:HP_TEST_FORCE_UV_FAIL
  $env:HP_TEST_FORCE_UV_FAIL = ''
  $prevCILane3 = $env:HP_CI_LANE
  if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
  Push-Location $uvCorruptDir
  try {
    cmd /c "call run_setup.bat > $uvLogName 2>&1"
    $uvTestExit = $LASTEXITCODE
  } finally {
    Pop-Location
    $env:HP_TEST_CORRUPT_UV = ''
    $env:HP_TEST_FORCE_UV_FAIL = $prevForceUvFail3
    $env:HP_CI_LANE = $prevCILane3
  }
  $uvLogPath = Join-Path $uvCorruptDir $uvLogName
  $uvLines = if (Test-Path $uvLogPath) { Get-Content -LiteralPath $uvLogPath -Encoding ASCII } else { @() }
  $uvEvictMsgFound = ($uvLines | Where-Object { $_ -like '*HP_TEST_CORRUPT_UV*' }).Count -gt 0
  Write-NdjsonRow ([ordered]@{
    id      = 'self.corrupt.uv.detect'
    req     = 'REQ-020'
    pass    = $uvEvictMsgFound
    desc    = 'HP_TEST_CORRUPT_UV=1: bootstrap evicts cached uv binary and logs warning'
    details = [ordered]@{ exitCode = $uvTestExit; evictMsgFound = $uvEvictMsgFound }
  })
  if ($uvEvictMsgFound) { $summary.Add('Corrupt uv detect: PASS') } else { $summary.Add('Corrupt uv detect: FAIL') }
}

# --- Conda bulk install retry test ---
# Arrange: HP_TEST_FORCE_CONDA_NETWORK_FAIL=1 simulates a transient CondaHTTPError on the
#          first bulk install attempt. Assert: log contains the retry sentinel line and
#          bootstrap exits 0 (the retry with real conda succeeds).
# Note: test runs only when conda is already installed from the prior bootstrap run.
$retryDir = Join-Path $TestsDir '~selftest_conda_retry'
if (Test-Path $retryDir) { Remove-Item -Recurse -Force $retryDir }
New-Item -ItemType Directory -Force -Path $retryDir | Out-Null
Copy-Item -Path $BatchPath -Destination $retryDir -Force
Set-Content -Path (Join-Path $retryDir 'app_retry_test.py') -Value 'import six; print("six-ok")' -Encoding ASCII
Set-Content -Path (Join-Path $retryDir 'requirements.txt') -Value 'six' -Encoding ASCII
$retryLogName = '~conda_retry_bootstrap.log'
$prevForceCondaOnly4 = $env:HP_FORCE_CONDA_ONLY
$env:HP_TEST_FORCE_CONDA_NETWORK_FAIL = '1'
$env:HP_FORCE_CONDA_ONLY = '1'
$prevCILane4 = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $retryDir
try {
  cmd /c "call run_setup.bat > $retryLogName 2>&1"
  $retryExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_FORCE_CONDA_NETWORK_FAIL = ''
  $env:HP_FORCE_CONDA_ONLY = $prevForceCondaOnly4
  $env:HP_CI_LANE = $prevCILane4
}
# derived requirement (CLAUDE.md Item 42, lever 1): the "[INSTALL] conda bulk: transient failure
# detected" line is suppressed from the live console by default, so the redirected $retryLogName
# capture no longer carries it -- read the always-complete ~setup.log instead (:log writes it
# unconditionally regardless of console tiering).
$retrySetupLogPath = Join-Path $retryDir '~setup.log'
$retryLines = if (Test-Path $retrySetupLogPath) { Get-Content -LiteralPath $retrySetupLogPath -Encoding ASCII } else { @() }
$retryMsgFound = ($retryLines | Where-Object { $_ -like '*conda bulk: transient failure detected*' }).Count -gt 0
Write-NdjsonRow ([ordered]@{
  id      = 'self.stub.conda_retry'
  req     = 'REQ-005.2'
  pass    = ($retryExit -eq 0 -and $retryMsgFound)
  desc    = 'HP_TEST_FORCE_CONDA_NETWORK_FAIL=1: bootstrap retries conda bulk install on transient failure'
  details = [ordered]@{ exitCode = $retryExit; retryMsgFound = $retryMsgFound }
})
if ($retryExit -eq 0 -and $retryMsgFound) { $summary.Add('Conda retry: PASS') } else { $summary.Add('Conda retry: FAIL') }
# REQ-005: pipreqs WARN gate -- reuses the conda_retry log (has requirements.txt=six).
# The "Dependencies were auto-detected via pipreqs" WARN must NOT appear when user has requirements.txt.
# Guard: if the retry log is empty (prior scenario produced no output), fail rather than false-pass.
$warnFound = ($retryLines | Where-Object { $_ -like '*Dependencies were auto-detected via pipreqs*' }).Count -gt 0
$warnGatePass = ($retryLines.Count -gt 0) -and (-not $warnFound)
Write-NdjsonRow ([ordered]@{
  id      = 'self.pipreqs.warn.gated'
  req     = 'REQ-005'
  pass    = $warnGatePass
  desc    = 'pipreqs auto-detect WARN absent when user requirements.txt present (not shown to user who already declared deps)'
  details = [ordered]@{ warnFound = $warnFound; logLines = $retryLines.Count }
})
if ($warnGatePass) { $summary.Add('Pipreqs WARN gate: PASS') } else { $summary.Add('Pipreqs WARN gate: FAIL') }

# --- Conda env-create retry test ---
# Arrange: HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL=1 simulates a transient CondaHTTPError on the
#          first `conda create` attempt (the env-CREATION phase, distinct from the bulk-INSTALL
#          retry test above -- :try_conda_create and :conda_bulk_install are separate code paths
#          with separate test hooks so one flag can't cross-trigger the other's retry).
#          Assert: log contains the create-phase retry sentinel line and bootstrap exits 0 (the
#          retry with a real `conda create` succeeds).
# Note: test runs only when conda is already installed from the prior bootstrap run.
$createRetryDir = Join-Path $TestsDir '~selftest_conda_create_retry'
if (Test-Path $createRetryDir) { Remove-Item -Recurse -Force $createRetryDir }
New-Item -ItemType Directory -Force -Path $createRetryDir | Out-Null
Copy-Item -Path $BatchPath -Destination $createRetryDir -Force
Set-Content -Path (Join-Path $createRetryDir 'app_create_retry_test.py') -Value 'print("create-retry-ok")' -Encoding ASCII
$createRetryLogName = '~conda_create_retry_bootstrap.log'
$prevForceCondaOnly6 = $env:HP_FORCE_CONDA_ONLY
$env:HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL = '1'
$env:HP_FORCE_CONDA_ONLY = '1'
$prevCILane6 = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $createRetryDir
try {
  cmd /c "call run_setup.bat > $createRetryLogName 2>&1"
  $createRetryExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL = ''
  $env:HP_FORCE_CONDA_ONLY = $prevForceCondaOnly6
  $env:HP_CI_LANE = $prevCILane6
}
$createRetryLogPath = Join-Path $createRetryDir $createRetryLogName
$createRetryLines = if (Test-Path $createRetryLogPath) { Get-Content -LiteralPath $createRetryLogPath -Encoding ASCII } else { @() }
$createRetryMsgFound = ($createRetryLines | Where-Object { $_ -like '*conda create: transient failure detected*' }).Count -gt 0
Write-NdjsonRow ([ordered]@{
  id      = 'self.stub.conda_create_retry'
  req     = 'REQ-022.1'
  pass    = ($createRetryExit -eq 0 -and $createRetryMsgFound)
  desc    = 'HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL=1: bootstrap retries conda env creation on transient failure'
  details = [ordered]@{ exitCode = $createRetryExit; retryMsgFound = $createRetryMsgFound }
})
if ($createRetryExit -eq 0 -and $createRetryMsgFound) { $summary.Add('Conda create retry: PASS') } else { $summary.Add('Conda create retry: FAIL') }

# --- Conda env-create outcomes (README REQ-022.2 and REQ-022.3) ---
# Both runs use the Miniconda installed by the scenarios above and fail at the env-create step through a test
# hook, so no real conda create runs. BOTH_FAIL fails the first attempt and the retry; PLAIN_FAIL fails the first
# attempt with output that holds none of the four transient phrases of REQ-022.1.
$createExhaustDir = Join-Path $TestsDir '~selftest_conda_create_exhausted'
if (Test-Path $createExhaustDir) { Remove-Item -Recurse -Force $createExhaustDir }
New-Item -ItemType Directory -Force -Path $createExhaustDir | Out-Null
Copy-Item -Path $BatchPath -Destination $createExhaustDir -Force
Set-Content -Path (Join-Path $createExhaustDir 'app.py') -Value 'print("should-not-run")' -Encoding ASCII
$createExhaustLogName = '~conda_create_exhausted_bootstrap.log'
$prevForceCondaOnlyEx = $env:HP_FORCE_CONDA_ONLY
$prevSkipPipreqsEx = $env:HP_SKIP_PIPREQS
$prevCILaneEx = $env:HP_CI_LANE
$env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL = '1'
$env:HP_FORCE_CONDA_ONLY = '1'
$env:HP_SKIP_PIPREQS = '1'
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $createExhaustDir
try {
  cmd /c "call run_setup.bat > $createExhaustLogName 2>&1"
  $createExhaustExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_FORCE_CONDA_CREATE_BOTH_FAIL = ''
  $env:HP_FORCE_CONDA_ONLY = $prevForceCondaOnlyEx
  $env:HP_SKIP_PIPREQS = $prevSkipPipreqsEx
  $env:HP_CI_LANE = $prevCILaneEx
}
$createExhaustSetupPath = Join-Path $createExhaustDir '~setup.log'
$createExhaustLines = if (Test-Path -LiteralPath $createExhaustSetupPath) { Get-Content -LiteralPath $createExhaustSetupPath -Encoding ASCII } else { @() }
$createExhaustRetried = @($createExhaustLines | Where-Object { $_ -like '*conda create: transient failure detected*' }).Count -eq 1
$createExhaustAlsoFailed = @($createExhaustLines | Where-Object { $_ -like '*conda create: retry after transient failure also failed*' }).Count -gt 0
$createExhaustReported = @($createExhaustLines | Where-Object { $_ -match [regex]::Escape('[ERROR] conda env create failed.') }).Count -gt 0
$createExhaustState = $null
$createExhaustStatusPath = Join-Path $createExhaustDir '~bootstrap.status.json'
if (Test-Path -LiteralPath $createExhaustStatusPath) {
  try { $createExhaustState = (Get-Content -LiteralPath $createExhaustStatusPath -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { }
}
$createExhaustPass = ($createExhaustRetried -and $createExhaustAlsoFailed -and $createExhaustReported -and ($createExhaustState -eq 'error'))
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.conda_create_exhausted'
  req = 'REQ-022.2'
  pass = $createExhaustPass
  desc = 'REQ-022: when the retry of a failed conda env creation also fails the environment creation is treated as failed (state error)'
  details = [ordered]@{
    retriedOnce = $createExhaustRetried
    retryAlsoFailed = $createExhaustAlsoFailed
    failureReported = $createExhaustReported
    state = $createExhaustState
    exitCode = $createExhaustExit
  }
})
if ($createExhaustPass) { $summary.Add('Conda create retry exhausted: PASS') } else { $summary.Add('Conda create retry exhausted: FAIL') }

$createPlainDir = Join-Path $TestsDir '~selftest_conda_create_plain'
if (Test-Path $createPlainDir) { Remove-Item -Recurse -Force $createPlainDir }
New-Item -ItemType Directory -Force -Path $createPlainDir | Out-Null
Copy-Item -Path $BatchPath -Destination $createPlainDir -Force
Set-Content -Path (Join-Path $createPlainDir 'app.py') -Value 'print("should-not-run")' -Encoding ASCII
$createPlainLogName = '~conda_create_plain_bootstrap.log'
$prevForceCondaOnlyPl = $env:HP_FORCE_CONDA_ONLY
$prevSkipPipreqsPl = $env:HP_SKIP_PIPREQS
$prevCILanePl = $env:HP_CI_LANE
$env:HP_TEST_FORCE_CONDA_CREATE_PLAIN_FAIL = '1'
$env:HP_FORCE_CONDA_ONLY = '1'
$env:HP_SKIP_PIPREQS = '1'
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $createPlainDir
try {
  cmd /c "call run_setup.bat > $createPlainLogName 2>&1"
  $createPlainExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_FORCE_CONDA_CREATE_PLAIN_FAIL = ''
  $env:HP_FORCE_CONDA_ONLY = $prevForceCondaOnlyPl
  $env:HP_SKIP_PIPREQS = $prevSkipPipreqsPl
  $env:HP_CI_LANE = $prevCILanePl
}
$createPlainSetupPath = Join-Path $createPlainDir '~setup.log'
$createPlainLines = if (Test-Path -LiteralPath $createPlainSetupPath) { Get-Content -LiteralPath $createPlainSetupPath -Encoding ASCII } else { @() }
$createPlainLogPath = Join-Path $createPlainDir $createPlainLogName
$createPlainConsole = if (Test-Path -LiteralPath $createPlainLogPath) { Get-Content -LiteralPath $createPlainLogPath -Encoding ASCII } else { @() }
$createPlainHookRan = @($createPlainLines | Where-Object { $_ -like '*PackagesNotFoundError*' }).Count -eq 1
$createPlainNoRetryLog = @($createPlainLines | Where-Object { $_ -like '*conda create: transient failure detected*' -or $_ -like '*conda create: retry after transient failure*' }).Count -eq 0
$createPlainNoRetryConsole = @($createPlainConsole | Where-Object { $_ -like '*Retrying environment creation*' }).Count -eq 0
$createPlainNoRetry = ($createPlainNoRetryLog -and $createPlainNoRetryConsole)
$createPlainReported = @($createPlainLines | Where-Object { $_ -match [regex]::Escape('[ERROR] conda env create failed.') }).Count -gt 0
$createPlainState = $null
$createPlainStatusPath = Join-Path $createPlainDir '~bootstrap.status.json'
if (Test-Path -LiteralPath $createPlainStatusPath) {
  try { $createPlainState = (Get-Content -LiteralPath $createPlainStatusPath -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { }
}
$createPlainPass = ($createPlainHookRan -and $createPlainNoRetry -and $createPlainReported -and ($createPlainState -eq 'error'))
Write-NdjsonRow ([ordered]@{
  id = 'self.stub.conda_create_nonretry'
  req = 'REQ-022.3'
  pass = $createPlainPass
  desc = 'REQ-022: a failed conda env creation whose output has none of the four transient phrases is treated as failed without a second attempt'
  details = [ordered]@{
    hookRan = $createPlainHookRan
    noRetry = $createPlainNoRetry
    failureReported = $createPlainReported
    state = $createPlainState
    exitCode = $createPlainExit
  }
})
if ($createPlainPass) { $summary.Add('Conda create no retry: PASS') } else { $summary.Add('Conda create no retry: FAIL') }

# --- REQ-005.3 conda per-package fallback test ---
# Arrange: HP_TEST_FORCE_CONDA_BULK_FAIL=1 forces a non-transient bulk-install failure, so the
#          bootstrapper falls back to installing each package individually via conda. Assert:
#          the per-pkg fallback log line fired and the bootstrap still exits 0 (six installed
#          individually and the app ran). HP_FORCE_CONDA_ONLY pins the conda path.
$perpkgDir = Join-Path $TestsDir '~selftest_conda_perpkg'
if (Test-Path $perpkgDir) { Remove-Item -Recurse -Force $perpkgDir }
New-Item -ItemType Directory -Force -Path $perpkgDir | Out-Null
Copy-Item -Path $BatchPath -Destination $perpkgDir -Force
Set-Content -Path (Join-Path $perpkgDir 'app_perpkg_test.py') -Value 'import six; print("six-ok")' -Encoding ASCII
Set-Content -Path (Join-Path $perpkgDir 'requirements.txt') -Value 'six' -Encoding ASCII
$perpkgLogName = '~conda_perpkg_bootstrap.log'
$prevForceCondaOnly5 = $env:HP_FORCE_CONDA_ONLY
$env:HP_TEST_FORCE_CONDA_BULK_FAIL = '1'
$env:HP_FORCE_CONDA_ONLY = '1'
$prevCILane5 = $env:HP_CI_LANE
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
Push-Location $perpkgDir
try {
  cmd /c "call run_setup.bat > $perpkgLogName 2>&1"
  $perpkgExit = $LASTEXITCODE
} finally {
  Pop-Location
  $env:HP_TEST_FORCE_CONDA_BULK_FAIL = ''
  $env:HP_FORCE_CONDA_ONLY = $prevForceCondaOnly5
  $env:HP_CI_LANE = $prevCILane5
}
# derived requirement (CLAUDE.md Item 42, lever 1): the "[INSTALL] conda per-pkg fallback" line
# is suppressed from the live console by default, so the redirected $perpkgLogName capture no
# longer carries it -- read the always-complete ~setup.log instead (:log writes it unconditionally
# regardless of console tiering).
$perpkgSetupLogPath = Join-Path $perpkgDir '~setup.log'
$perpkgLines = if (Test-Path $perpkgSetupLogPath) { Get-Content -LiteralPath $perpkgSetupLogPath -Encoding ASCII } else { @() }
# NOTE: -like treats [INSTALL] as a character-class wildcard, so match the bracket-free
# phrase (unique to this log line) instead of the literal "[INSTALL] ..." prefix.
$perpkgMsgFound = ($perpkgLines | Where-Object { $_ -like '*conda per-pkg fallback*' }).Count -gt 0
Write-NdjsonRow ([ordered]@{
  id      = 'self.stub.conda_perpkg'
  req     = 'REQ-005.3'
  pass    = ($perpkgExit -eq 0 -and $perpkgMsgFound)
  desc    = 'HP_TEST_FORCE_CONDA_BULK_FAIL=1: bulk-install failure falls back to per-package conda install'
  details = [ordered]@{ exitCode = $perpkgExit; perpkgMsgFound = $perpkgMsgFound }
})
if ($perpkgExit -eq 0 -and $perpkgMsgFound) { $summary.Add('Conda per-pkg fallback: PASS') } else { $summary.Add('Conda per-pkg fallback: FAIL') }

$summary | Set-Content -Path $summaryPath -Encoding ASCII

# derived requirement: this script previously had no exit statement at all, so PowerShell's
# default exit code (0, absent an unhandled exception) was returned regardless of how many
# of the scenarios above failed. run_tests.bat's own exit code depends on this ("if errorlevel
# 1 set ERR=1" right after invoking this file), and that in turn is the "Run tests" CI step's
# own exit code in every lane including the real/conda-full gating ones -- so a genuinely
# broken scenario here was previously invisible to both a human scanning the Actions UI and to
# the CI step's own pass/fail status, not just to the NDJSON-content-based verdict mechanisms.
if ($script:AnyRowFailed) { exit 1 }
exit 0
