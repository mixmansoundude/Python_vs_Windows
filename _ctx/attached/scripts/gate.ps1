# ASCII only
param()

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$ProgressPreference = 'SilentlyContinue'

$repoRoot = Split-Path -Parent $PSScriptRoot
$logsDir = Join-Path $repoRoot 'logs'
New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

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
