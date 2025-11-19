# ASCII only
param()

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$logsDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

function Get-FailingTests {
  param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot
  )

  $directRoots = @(
    (Join-Path -Path $WorkspaceRoot -ChildPath '_artifacts/batch-check/batchcheck_failing.txt'),
    (Join-Path -Path $WorkspaceRoot -ChildPath '_mirrors/batchcheck_failing.txt')
  )
  foreach ($direct in $directRoots) {
    if (Test-Path -LiteralPath $direct) {
      return $direct
    }
  }

  $candidates = New-Object System.Collections.Generic.List[System.String]
  $explicitBatchCheck = @(
    (Join-Path -Path $WorkspaceRoot -ChildPath '_artifacts/batch-check'),
    (Join-Path -Path $WorkspaceRoot -ChildPath '_mirrors')
  )
  foreach ($batchRoot in $explicitBatchCheck) {
    if (-not [string]::IsNullOrWhiteSpace($batchRoot)) { $candidates.Add($batchRoot) | Out-Null }
  }
  $diagEnv = $env:DIAG
  if (-not [string]::IsNullOrWhiteSpace($diagEnv)) { $candidates.Add($diagEnv) | Out-Null }
  $runnerTemp = $env:RUNNER_TEMP
  if (-not [string]::IsNullOrWhiteSpace($runnerTemp)) { $candidates.Add($runnerTemp) | Out-Null }

  foreach ($suffix in @('diag', '_mirrors', '_artifacts', '.')) {
    $candidates.Add((Join-Path -Path $WorkspaceRoot -ChildPath $suffix)) | Out-Null
  }

  $seen = New-Object 'System.Collections.Generic.HashSet[string]'
  foreach ($candidate in $candidates) {
    if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
    try {
      $resolved = (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
    } catch {
      continue
    }
    if (-not $seen.Add($resolved)) { continue }
    foreach ($fileName in @('batchcheck_failing.txt', 'failing-tests.txt')) {
      $direct = Join-Path -Path $resolved -ChildPath $fileName
      if (Test-Path -LiteralPath $direct) {
        return $direct
      }
      try {
        $probe = Get-ChildItem -LiteralPath $resolved -Filter $fileName -File -Recurse -ErrorAction Stop | Select-Object -First 1
        if ($probe -and $probe.FullName) { return $probe.FullName }
      } catch {
        continue
      }
    }
  }
  return $null
}

function Get-BatchStatus {
  param(
    [Parameter(Mandatory = $true)][string]$WorkspaceRoot
  )

  $candidates = @(
    (Join-Path -Path $WorkspaceRoot -ChildPath 'STATUS.txt'),
    (Join-Path -Path $WorkspaceRoot -ChildPath 'batch-check/STATUS.txt'),
    (Join-Path -Path $WorkspaceRoot -ChildPath '_mirrors/STATUS.txt'),
    (Join-Path -Path $WorkspaceRoot -ChildPath '_mirrors/batch-check/STATUS.txt')
  )
  foreach ($candidate in $candidates) {
    if (-not (Test-Path -LiteralPath $candidate)) { continue }
    try {
      $lines = Get-Content -LiteralPath $candidate -ErrorAction Stop
      foreach ($line in $lines) {
        $trimmed = [string]::IsNullOrWhiteSpace($line) ? $null : $line.Trim()
        if ($trimmed) { return $trimmed }
      }
    } catch {
      continue
    }
  }
  return $null
}

$apiKey = $env:OPENAI_API_KEY
$baseUri = $env:OPENAI_API_BASE
if ([string]::IsNullOrWhiteSpace($baseUri)) {
  $baseUri = 'https://api.openai.com/v1'
}

$state = [ordered]@{
  api_key_present = $false
  auth_ok = $false
  chat_ok = $false
  models_status = '000'
  chat_status = '000'
}

$failListPath = Get-FailingTests -WorkspaceRoot $repoRoot
$statusText = Get-BatchStatus -WorkspaceRoot $repoRoot
if ($failListPath) {
  $state.failing_tests_path = $failListPath
  try {
    $failEntries = Get-Content -LiteralPath $failListPath -ErrorAction Stop | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $failEntries = $failEntries | Where-Object { $_ -and $_.ToLowerInvariant() -ne 'none' }
  } catch {
    $failEntries = @()
  }
  $state.failing_tests_count = $failEntries.Count
  if ($failEntries.Count -eq 0) {
    $state.skip_reason = 'no_failing_tests'
    if ($statusText) { $state.batch_status = $statusText }
    $state | ConvertTo-Json -Compress | Out-File -LiteralPath (Join-Path $logsDir 'iterate_auth.json') -Encoding ascii
    $statusLabel = if ($statusText) { $statusText } else { 'n/a' }
    Write-Host ("gate: no failing tests detected (status: {0}); skipping iterate." -f $statusLabel)
    return
  }
}
if ($statusText) {
  $state.batch_status = $statusText
}

if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
  $state.api_key_present = $true
  $headers = @{ Authorization = "Bearer $apiKey" }

  try {
    $modelsStatus = '000'
    Invoke-WebRequest -Uri ("{0}/models" -f $baseUri.TrimEnd('/')) -Headers $headers -UseBasicParsing -MaximumRedirection 5 -ErrorAction Stop -OutFile (Join-Path $logsDir 'iterate_models.tmp') -StatusCodeVariable modelsStatusCode | Out-Null
    $modelsStatus = [string]$modelsStatusCode
    if ($modelsStatus -eq '200') { $state.auth_ok = $true }
    $state.models_status = $modelsStatus
  } catch {
    $code = '000'
    if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__) {
      $code = [string]$_.Exception.Response.StatusCode.value__
    }
    $state.models_status = $code
    Write-Warning ("/models probe failed: {0}" -f $_.Exception.Message)
  } finally {
    $tmpModels = Join-Path $logsDir 'iterate_models.tmp'
    if (Test-Path $tmpModels) { Remove-Item -LiteralPath $tmpModels -Force -ErrorAction SilentlyContinue }
  }

  if ($state.auth_ok) {
    $body = @{ model = 'gpt-4o-mini'; messages = @(@{ role = 'user'; content = 'Reply with PONG' }); max_tokens = 1 } | ConvertTo-Json -Depth 4
    try {
      $chatStatus = '000'
      $response = Invoke-RestMethod -Method Post -Uri ("{0}/chat/completions" -f $baseUri.TrimEnd('/')) -Headers ($headers + @{ 'Content-Type' = 'application/json' }) -Body $body -ErrorAction Stop -StatusCodeVariable chatStatusCode
      $chatStatus = [string]$chatStatusCode
      $state.chat_status = $chatStatus
      if ($chatStatus -eq '200') {
        $text = ''
        foreach ($choice in ($response.choices | ForEach-Object { $_ })) {
          $message = $choice.message
          if ($message -and $message.content) { $text += [string]$message.content }
        }
        if ($text.ToUpperInvariant().Contains('PONG')) {
          $state.chat_ok = $true
        }
      }
    } catch {
      $code = '000'
      if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__) {
        $code = [string]$_.Exception.Response.StatusCode.value__
      }
      $state.chat_status = $code
      Write-Warning ("chat completion probe failed: {0}" -f $_.Exception.Message)
    }
  }
}

$outPath = Join-Path $logsDir 'iterate_auth.json'
$state | ConvertTo-Json -Compress | Out-File -LiteralPath $outPath -Encoding ascii
Write-Host ("gate: auth_ok={0} chat_ok={1}" -f $state.auth_ok, $state.chat_ok)
