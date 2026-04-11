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
$stateSkipFound = ($rebuildLines | Where-Object { $_ -like "*$stateSkipPhrase*" }).Count -gt 0
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

# --- Long-path (>=200 chars) warning test ---
# Arrange: run from a directory whose full path exceeds the 200-char guardrail threshold.
# Assert:  "[WARN] Script path is N chars" appears in log and bootstrap exits 0.
$longBase = Join-Path $TestsDir '~selftest_longpath'
$longSub  = 'pad_' + ('a' * 47)
$longSub2 = 'b' * 50
$longSub3 = 'c' * 50
$longDir  = Join-Path $longBase "$longSub\$longSub2\$longSub3"
if (Test-Path $longBase) { Remove-Item -Recurse -Force $longBase }
New-Item -ItemType Directory -Force -Path $longDir | Out-Null
Copy-Item -Path $BatchPath -Destination $longDir -Force
$lpLogName = '~longpath_bootstrap.log'
Push-Location $longDir
try {
  cmd /c "call run_setup.bat > $lpLogName 2>&1"
  $lpExit = $LASTEXITCODE
} finally {
  Pop-Location
}
$lpLogPath = Join-Path $longDir $lpLogName
$lpLines = @()
if (Test-Path $lpLogPath) { $lpLines = Get-Content -LiteralPath $lpLogPath -Encoding ASCII }
$lpWarnTag = 'Script path is'
$lpWarnFound = ($lpLines | Where-Object { $_ -like "*$lpWarnTag*chars*" }).Count -gt 0
$lpActualLen = $longDir.Length
Write-NdjsonRow ([ordered]@{
  id = 'self.warn.longpath'
  pass = ($lpWarnFound -and ($lpExit -eq 0))
  desc = 'Bootstrap emits long-path warning and exits 0 when script path is >=200 chars'
  details = [ordered]@{
    warnFound = $lpWarnFound
    exitCode = $lpExit
    pathLen = $lpActualLen
  }
})
if ($lpWarnFound -and ($lpExit -eq 0)) { $summary.Add('Long-path warning: PASS') } else { $summary.Add("Long-path warning: FAIL (len=$lpActualLen, found=$lpWarnFound, exit=$lpExit)") }

$summary | Set-Content -Path $summaryPath -Encoding ASCII
