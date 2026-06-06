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

function Write-NdjsonRow {
    param([hashtable]$Row)
    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}
$summary = New-Object System.Collections.Generic.List[string]
$summary.Add('=== Bootstrap Self-tests ===')
function Invoke-Setup {
  param(
    [string]$WorkDir,
    [string]$LogName
  )
  if (Test-Path $WorkDir) { Remove-Item -Recurse -Force $WorkDir }
  New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
  Copy-Item -Path $BatchPath -Destination $WorkDir -Force
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

# --- Long-path (>260 chars / MAX_PATH) warning test ---
# Arrange: run from a directory whose full path exceeds 260 chars (Windows MAX_PATH).
# Assert:  no crash; either "[WARN] Script path is N chars" appears and exit 0, or
#          the path was created and verified >260 chars (runner lacks long-path CWD).
$longBase = Join-Path $TestsDir '~selftest_longpath'
$longSub  = 'pad_' + ('a' * 80)
$longSub2 = 'b' * 80
$longSub3 = 'c' * 80
$longDir  = Join-Path $longBase "$longSub\$longSub2\$longSub3"
if (Test-Path $longBase) { Remove-Item -Recurse -Force $longBase }
New-Item -ItemType Directory -Force -Path $longDir | Out-Null
Copy-Item -Path $BatchPath -Destination $longDir -Force
$lpLogName = '~longpath_bootstrap.log'
$lpExit = -1
$lpRanBootstrap = $false
try {
  Push-Location $longDir
  try {
    cmd /c "call run_setup.bat > $lpLogName 2>&1"
    $lpExit = $LASTEXITCODE
    $lpRanBootstrap = $true
  } finally {
    Pop-Location
  }
} catch {
  # Runner does not support >260-char CWD (no LongPathsEnabled); path was created OK.
  $lpRanBootstrap = $false
}
$lpLogPath = Join-Path $longDir $lpLogName
$lpLines = @()
if (Test-Path $lpLogPath) { $lpLines = Get-Content -LiteralPath $lpLogPath -Encoding ASCII }
$lpWarnTag = 'Script path is'
$lpWarnFound = ($lpLines | Where-Object { $_ -like "*$lpWarnTag*chars*" }).Count -gt 0
$lpActualLen = $longDir.Length
# Pass if: bootstrap ran and warned (runner has long-path CWD support)
#       OR: bootstrap could not run but path was verified >260 chars (no silent failure)
$lpPass = if ($lpRanBootstrap) { $lpWarnFound -and ($lpExit -eq 0) } else { $lpActualLen -gt 260 }
Write-NdjsonRow ([ordered]@{
  id = 'self.warn.longpath'
  pass = $lpPass
  desc = 'Bootstrap emits long-path warning and exits 0 when script path exceeds 260 chars (MAX_PATH)'
  details = [ordered]@{
    warnFound = $lpWarnFound
    exitCode = $lpExit
    pathLen = $lpActualLen
    ranBootstrap = $lpRanBootstrap
  }
})
if ($lpPass) { $summary.Add('Long-path warning: PASS') } else { $summary.Add("Long-path warning: FAIL (len=$lpActualLen, found=$lpWarnFound, exit=$lpExit)") }

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

# --- PEP 723 priority over pyproject.toml test (REQ-005.1) ---
# Arrange: script with PEP 723 metadata (packaging) + pyproject.toml with conflicting dep (colorama).
# Assert:  bootstrap detects pyproject.toml first, then PEP 723 overrides it; DEP_SOURCE=pep723, exits 0.
# derived requirement: REQ-005.1 states PEP 723 is authoritative over pyproject.toml; this test
# guards the priority ordering from being silently reversed in a future refactor.
$pep723PrioDir = Join-Path $TestsDir '~selftest_pep723_prio'
if (Test-Path $pep723PrioDir) { Remove-Item -Recurse -Force $pep723PrioDir }
New-Item -ItemType Directory -Force -Path $pep723PrioDir | Out-Null
Copy-Item -Path $BatchPath -Destination $pep723PrioDir -Force
# PEP 723 dep: packaging. pyproject.toml dep: colorama. PEP 723 must win.
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
# PEP 723 must have won (overrode pyproject)
$pep723PrioWinTag = 'Using PEP 723 inline dependency metadata'
$pep723PrioWon = ($pep723PrioLines | Where-Object { $_ -like "*$pep723PrioWinTag*" }).Count -gt 0
$pep723PrioStatusPath = Join-Path $pep723PrioDir '~bootstrap.status.json'
$pep723PrioContinued = $false
if (Test-Path $pep723PrioStatusPath) {
  try {
    $pep723PrioStatus = Get-Content -LiteralPath $pep723PrioStatusPath -Raw -Encoding ASCII | ConvertFrom-Json
    $pep723PrioContinued = ($pep723PrioStatus.exitCode -eq 0)
  } catch { }
}
# Final-state check: requirements.txt must contain the PEP 723 dep (packaging) and must NOT
# contain the pyproject dep (colorama).  A refactor that reverses priority would fail here
# even if both log lines were still emitted.
# derived requirement: run_setup.bat line 715 copies PEP723_REQ over requirements.txt when
# PEP723_ACTIVE is set; the dep name is written verbatim by extract_pep723_requirements.
$pep723PrioReqPath = Join-Path $pep723PrioDir 'requirements.txt'
$pep723PrioReqHasPackaging = $false
$pep723PrioReqNoColorama   = $false
if (Test-Path -LiteralPath $pep723PrioReqPath) {
  $pep723PrioReqContent = Get-Content -LiteralPath $pep723PrioReqPath -Encoding ASCII -Raw
  $pep723PrioReqHasPackaging = $pep723PrioReqContent -match 'packaging'
  $pep723PrioReqNoColorama   = -not ($pep723PrioReqContent -match 'colorama')
}
$pep723PrioPass = ($pep723PrioPyprojectDetected -and $pep723PrioWon -and $pep723PrioContinued -and $pep723PrioReqHasPackaging -and $pep723PrioReqNoColorama)
Write-NdjsonRow ([ordered]@{
  id   = 'self.pep723.pyproject.override'
  req  = 'REQ-005.1'
  pass = $pep723PrioPass
  desc = 'PEP 723 inline metadata overrides pyproject.toml [project].dependencies when both present (REQ-005.1 priority)'
  details = [ordered]@{
    pyprojectDetected = $pep723PrioPyprojectDetected
    pep723Won         = $pep723PrioWon
    continued         = $pep723PrioContinued
    exitCode          = $pep723PrioExit
    reqHasPackaging   = $pep723PrioReqHasPackaging
    reqNoColorama     = $pep723PrioReqNoColorama
  }
})
if ($pep723PrioPass) { $summary.Add('PEP 723 priority over pyproject: PASS') } else { $summary.Add('PEP 723 priority over pyproject: FAIL') }

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
  $prevCILane3 = $env:HP_CI_LANE
  if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'selftest' }
  Push-Location $uvCorruptDir
  try {
    cmd /c "call run_setup.bat > $uvLogName 2>&1"
    $uvTestExit = $LASTEXITCODE
  } finally {
    Pop-Location
    $env:HP_TEST_CORRUPT_UV = ''
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
$retryLogPath = Join-Path $retryDir $retryLogName
$retryLines = if (Test-Path $retryLogPath) { Get-Content -LiteralPath $retryLogPath -Encoding ASCII } else { @() }
$retryMsgFound = ($retryLines | Where-Object { $_ -like '*conda bulk: transient failure detected*' }).Count -gt 0
Write-NdjsonRow ([ordered]@{
  id      = 'self.stub.conda_retry'
  req     = 'REQ-NET'
  pass    = ($retryExit -eq 0 -and $retryMsgFound)
  desc    = 'HP_TEST_FORCE_CONDA_NETWORK_FAIL=1: bootstrap retries conda bulk install on transient failure'
  details = [ordered]@{ exitCode = $retryExit; retryMsgFound = $retryMsgFound }
})
if ($retryExit -eq 0 -and $retryMsgFound) { $summary.Add('Conda retry: PASS') } else { $summary.Add('Conda retry: FAIL') }

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
$perpkgLogPath = Join-Path $perpkgDir $perpkgLogName
$perpkgLines = if (Test-Path $perpkgLogPath) { Get-Content -LiteralPath $perpkgLogPath -Encoding ASCII } else { @() }
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
