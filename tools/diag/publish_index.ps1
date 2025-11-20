[CmdletBinding()]
param()

# Implements the prior inline "Write diagnostics index" logic as a reusable script in tools/diag
# per the request to "Create repo scripts under tools/diag".
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
} catch {
    # Professional note: extraction helpers rely on System.IO.Compression; ignore failures so diagnostics still publish.
}

$Diag       = $env:DIAG
$Artifacts  = $env:ARTIFACTS
$Repo       = $env:REPO
$SHA        = $env:SHA
$Run        = $env:RUN_ID
$Att        = $env:RUN_ATTEMPT
$UTC        = [DateTime]::UtcNow.ToString('o')
$CT         = [System.TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, 'Central Standard Time').ToString('o')
$RunUrl     = $env:RUN_URL
$Short      = $env:SHORTSHA
$InventoryB64 = $env:INVENTORY_B64
$BatchRunId   = $env:BATCH_RUN_ID
$BatchRunAttempt = $env:BATCH_RUN_ATTEMPT
$preferLocalArtifacts = $false
$preferLocalIterate = $false
$artifactsOverride = $env:ARTIFACTS_ROOT
$downloadedIterRoot = Join-Path (Get-Location) '_iter'
# derived requirement: runs such as 19218918397-1 downloaded the iterate artifact
# earlier in the workflow; reuse that staging area immediately so diagnostics
# stop waiting for the remote artifact mirrors.
$downloadedIterReady = $false
if (Test-Path -LiteralPath $downloadedIterRoot) {
    $downloadProbe = Get-ChildItem -Path $downloadedIterRoot -Recurse -File -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($downloadProbe) {
        Write-Host ("Using DOWNLOADED iterate payload from: {0}" -f $downloadedIterRoot)
        $preferLocalIterate = $true
        $downloadedIterReady = $true
    }
}
$localStatusPath = $null
$localRunJson = $null
if ($artifactsOverride -and (Test-Path -LiteralPath $artifactsOverride)) {
    # Professional note: prefer the staged diagnostics tree while giving the local mirrors up to 60 seconds to settle.
    $Artifacts = $artifactsOverride
    $preferLocalIterate = $true
    $batchDir = Join-Path $Artifacts 'batch-check'
    $localStatusPath = Join-Path $batchDir 'STATUS.txt'
    $localRunJson = Join-Path $batchDir 'run.json'
    $deadline = (Get-Date).AddSeconds(60)
    $localReady = $false
    $localCiRoot = Join-Path $batchDir '_ci_artifacts'
    if (Test-Path -LiteralPath $localCiRoot) {
        $ndjsonProbe = Get-ChildItem -Path $localCiRoot -Filter '*~test-results.ndjson' -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Length -gt 0 } |
            Select-Object -First 1
        if ($ndjsonProbe) {
            # derived requirement: when the workflow already mirrored NDJSON locally
            # (e.g., run 19218918397-1), trust the staged payload immediately instead of
            # waiting the full settle loop intended for remote fetches.
            $localReady = $true
        }
    }
    while (-not $localReady -and [DateTime]::UtcNow -lt $deadline) {
        $statusExists = Test-Path -LiteralPath $localStatusPath
        $runJsonExists = Test-Path -LiteralPath $localRunJson
        if ($statusExists -and $runJsonExists) {
            $localReady = $true
            break
        }
        Start-Sleep -Seconds 5
    }
    if ($localReady) {
        $preferLocalArtifacts = $true
    }
}

if (-not $BatchRunId -and $Artifacts) {
    $batchRunJson = Join-Path (Join-Path $Artifacts 'batch-check') 'run.json'
    if (Test-Path -LiteralPath $batchRunJson) {
        try { $batchMeta = Get-Content -Raw -LiteralPath $batchRunJson | ConvertFrom-Json } catch { $batchMeta = $null }
        if ($batchMeta) {
            # derived requirement: the diagnostics publisher must mirror batch-check logs even when
            # the workflow omits BATCH_RUN_ID/BATCH_RUN_ATTEMPT; harvest run.json so the download path
            # remains stable when analysts rely on the diag bundle alone.
            if (-not $BatchRunId -or $BatchRunId -eq 'n/a') { $BatchRunId = [string]$batchMeta.run_id }
            if (-not $BatchRunAttempt -or $BatchRunAttempt -eq 'n/a') { $BatchRunAttempt = [string]$batchMeta.run_attempt }
        }
    }
}

if ($preferLocalArtifacts) {
    $batchDir = Join-Path $Artifacts 'batch-check'
    $localStatusPath = Join-Path $batchDir 'STATUS.txt'
    if (Test-Path -LiteralPath $localStatusPath) {
        try { $localStatus = (Get-Content -Raw -LiteralPath $localStatusPath).Trim() } catch { $localStatus = $null }
        if (-not [string]::IsNullOrWhiteSpace($localStatus)) {
            $env:BATCH_STATUS_OVERRIDE = $localStatus
        }
    }
    if (Test-Path -LiteralPath $localRunJson) {
        try { $meta = Get-Content -Raw -LiteralPath $localRunJson | ConvertFrom-Json } catch { $meta = $null }
        if ($meta) {
            if ($meta.run_id) { $BatchRunId = [string]$meta.run_id }
            if ($meta.run_attempt) { $BatchRunAttempt = [string]$meta.run_attempt }
            if ($meta.html_url) { $RunUrl = [string]$meta.html_url }
        }
    }
}
if (-not $Short) {
    $Short = $SHA
}
if ($Short) {
    if ($Short.Length -gt 7) { $Short = $Short.Substring(0,7) }
}

if (-not $Run) { $Run = $env:GITHUB_RUN_ID }
if (-not $Run) { $Run = 'n/a' }
if (-not $Att) { $Att = $env:GITHUB_RUN_ATTEMPT }
if (-not $Att) { $Att = 'n/a' }

if (-not $BatchRunId -or $BatchRunId -eq 'n/a') {
    if ($Run -and $Run -ne 'n/a') {
        # derived requirement: when diagnostics publish from the batch-check workflow itself,
        # reuse the current run id so the log download path stays populated even when inputs
        # omit BATCH_RUN_ID.
        $BatchRunId = $Run
    } elseif ($env:GITHUB_RUN_ID) {
        $BatchRunId = [string]$env:GITHUB_RUN_ID
    }
}

$batchRunMatchesCurrent = $false
if ($BatchRunId -and $BatchRunId -ne 'n/a' -and $Run -and $Run -ne 'n/a' -and $BatchRunId -eq $Run) {
    $batchRunMatchesCurrent = $true
}
if (-not $BatchRunAttempt -or $BatchRunAttempt -eq 'n/a') {
    if ($batchRunMatchesCurrent -and $Att -and $Att -ne 'n/a') {
        $BatchRunAttempt = $Att
    } elseif ($BatchRunId -and $BatchRunId -ne 'n/a' -and $env:GITHUB_RUN_ID -and [string]$env:GITHUB_RUN_ID -eq $BatchRunId -and $env:GITHUB_RUN_ATTEMPT) {
        $BatchRunAttempt = [string]$env:GITHUB_RUN_ATTEMPT
    }
}

function Get-FirstDir {
    param([string]$root)
    if (-not $root) { return $null }
    if (-not (Test-Path $root)) { return $null }
    return Get-ChildItem -Path $root -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
}

$iterateRoot = $null
$artifactIterRoot = $null
if ($downloadedIterReady) {
    # derived requirement: runs such as 19232295127-1 produced the iterate payload in
    # the downloaded staging directory while ARTIFACTS_ROOT stayed empty; prefer the
    # freshly downloaded copy so diagnostics mirror the same evidence analysts see on
    # the Actions artifacts page.
    $iterateRoot = $downloadedIterRoot
}
if ($Artifacts) {
    $artifactIterRoot = Join-Path $Artifacts 'iterate'
    if (-not $iterateRoot) {
        $iterateRoot = $artifactIterRoot
    } elseif ((Test-Path -LiteralPath $artifactIterRoot) -and -not (Test-Path -LiteralPath $iterateRoot)) {
        # derived requirement: fallback when the downloaded directory vanished between
        # steps (e.g., manual runs that skip the download-artifact stage).
        $iterateRoot = $artifactIterRoot
    }
}
if (-not $iterateRoot -and $downloadedIterReady) {
    # derived requirement: fallback to the downloaded payload when the diagnostics
    # artifacts root is unavailable (e.g., local dry runs).
    $iterateRoot = $downloadedIterRoot
}
$iterateDir = Get-FirstDir $iterateRoot
if ($iterateRoot -and (Test-Path $iterateRoot)) {
    $candidateDirs = Get-ChildItem -Path $iterateRoot -Directory -ErrorAction SilentlyContinue
    foreach ($candidate in $candidateDirs) {
        $decisionProbe = Join-Path $candidate.FullName 'decision.txt'
        if (Test-Path $decisionProbe) {
            # Professional note: some artifacts expose `_temp` alongside the sanitized iterate
            # folder; prefer the directory that carries decision.txt so metadata stays accurate.
            $iterateDir = $candidate.FullName
            break
        }
    }
}

$iterateTemp = $null
if ($iterateRoot -and (Test-Path $iterateRoot)) {
    $candidateTemp = Join-Path $iterateRoot '_temp'
    if (Test-Path $candidateTemp) {
        $iterateTemp = $candidateTemp
    } elseif ($iterateDir) {
        $altTemp = Join-Path $iterateDir '_temp'
        if (Test-Path $altTemp) { $iterateTemp = $altTemp }
    }
    if (-not $iterateTemp) {
        $maybeTemp = Get-ChildItem -Path $iterateRoot -Directory -Filter '_temp' -Recurse -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($maybeTemp) { $iterateTemp = $maybeTemp.FullName }
    }
}

$responseData = $null
if ($iterateTemp) {
    $responsePath = Join-Path $iterateTemp 'response.json'
    if (Test-Path $responsePath) {
        try { $responseData = Get-Content -Raw -LiteralPath $responsePath | ConvertFrom-Json } catch {}
    }
}

$statusData = $null
if ($iterateTemp) {
    $statusPath = Join-Path $iterateTemp 'iterate_status.json'
    if (Test-Path $statusPath) {
        try { $statusData = Get-Content -Raw -LiteralPath $statusPath | ConvertFrom-Json } catch {}
    }
}

$whyOutcome = $null
if ($iterateTemp) {
    $whyPath = Join-Path $iterateTemp 'why_no_diff.txt'
    if (Test-Path $whyPath) {
        $line = (Get-Content -LiteralPath $whyPath -TotalCount 1 | Select-Object -First 1)
        if ($line) { $whyOutcome = $line.Trim() }
    }
}

function Get-Relative {
    param([string]$fullPath)
    if (-not $fullPath) { return $null }
    if (-not $Diag) { return $fullPath }
    if ($fullPath.StartsWith($Diag, [StringComparison]::OrdinalIgnoreCase)) {
        return $fullPath.Substring($Diag.Length + 1).Replace('\\','/')
    }
    return $fullPath
}

function Normalize-Link {
    param([string]$value)
    if (-not $value) { return $value }
    # Professional note: GitHub Pages treats backslashes as %5C and 404s; convert to
    # forward slashes per maintainer request to "fix broken links caused by backslashes".
    return ($value -replace '\\','/')
}

function Read-Value {
    param([string]$dir, [string]$name)
    if (-not $dir) { return 'n/a' }
    $path = Join-Path $dir $name
    if (Test-Path $path) {
        return (Get-Content -Raw -LiteralPath $path).Trim()
    }
    return 'n/a'
}

function Get-IterateArtifactForRun {
    param(
        [string]$Owner,
        [string]$RepoName,
        [string]$TargetRunId,
        [string[]]$BaseNames,
        [hashtable]$Headers
    )

    if (-not $TargetRunId -or -not $BaseNames) { return $null }
    $filtered = $BaseNames | Where-Object { $_ }
    if (-not $filtered -or $filtered.Count -eq 0) { return $null }

    $perPage = 100
    $page = 1
    $candidates = @()

    while ($page -le 10) {
        $apiUri = "https://api.github.com/repos/$Owner/$RepoName/actions/runs/$TargetRunId/artifacts?per_page=$perPage&page=$page"
        $response = $null
        try {
            $response = Invoke-RestMethod -Uri $apiUri -Headers $Headers -ErrorAction Stop
        } catch {}

        if (-not $response -or -not $response.artifacts) { break }

        foreach ($artifact in $response.artifacts) {
            $name = [string]$artifact.name
            if (-not $name) { continue }
            $lower = $name.ToLowerInvariant()
            foreach ($base in $filtered) {
                $baseLower = $base.ToLowerInvariant()
                if ($lower -eq $baseLower -or $lower -eq ($baseLower + '.zip') -or $lower.StartsWith($baseLower + '-')) {
                    $candidates += [pscustomobject]@{ Artifact = $artifact; Base = $base; Name = $name }
                    break
                }
                if ($lower.EndsWith('.zip') -and $lower.Contains($baseLower)) {
                    $candidates += [pscustomobject]@{ Artifact = $artifact; Base = $base; Name = $name }
                    break
                }
            }
        }

        if ($candidates.Count -gt 0) { break }
        if ($response.artifacts.Count -lt $perPage) { break }
        $page += 1
    }

    if ($candidates.Count -eq 0) { return $null }

    $sorted = $candidates | Sort-Object -Property @{ Expression = {
                $base = $_.Base
                $candidateName = $_.Name
                if ($candidateName -eq $base) { return 0 }
                if ($candidateName -eq "$base.zip") { return 1 }
                if ($candidateName -like "$base-*") { return 2 }
                return 3
            } }, @{ Expression = { $_.Name } }

    return $sorted[0]
}

$decision   = Read-Value $iterateDir 'decision.txt'
$model      = Read-Value $iterateDir 'model.txt'
$endpoint   = Read-Value $iterateDir 'endpoint.txt'
$httpStatus = Read-Value $iterateDir 'http_status.txt'
if ($responseData) {
    if ($null -ne $responseData.http_status) { $httpStatus = [string]$responseData.http_status }
    if ($responseData.model) { $model = [string]$responseData.model }
}
$tokens     = @{}
$tokens['prompt']     = 'n/a'
$tokens['completion'] = 'n/a'
$tokens['total']      = 'n/a'
if ($responseData -and $responseData.usage) {
    if ($null -ne $responseData.usage.prompt_tokens) { $tokens['prompt'] = [string]$responseData.usage.prompt_tokens }
    if ($null -ne $responseData.usage.completion_tokens) { $tokens['completion'] = [string]$responseData.usage.completion_tokens }
    if ($null -ne $responseData.usage.total_tokens) { $tokens['total'] = [string]$responseData.usage.total_tokens }
}
if ($iterateDir) {
    $tokensPath = Join-Path $iterateDir 'tokens.txt'
    if (Test-Path $tokensPath) {
        foreach ($line in Get-Content -LiteralPath $tokensPath) {
            if ($line -match '^(?<k>[^=]+)=(?<v>.*)$') {
                $key = $matches['k']
                $value = $matches['v']
                if (-not $tokens.ContainsKey($key)) { $tokens[$key] = $value; continue }
                if ([string]::IsNullOrWhiteSpace($tokens[$key]) -or $tokens[$key] -eq 'n/a') {
                    $tokens[$key] = $value
                }
            }
        }
    }
}

$patchDiffPath = $null
if ($iterateDir) {
    $candidatePatch = Join-Path $iterateDir 'patch.diff'
    if (Test-Path $candidatePatch) { $patchDiffPath = $candidatePatch }
}

$diffProduced = $false
if ($patchDiffPath -and (Test-Path $patchDiffPath)) {
    $head = Get-Content -LiteralPath $patchDiffPath -TotalCount 20
    if ($head) {
        $allNoChanges = ($head.Count -eq 1 -and $head[0].Trim() -eq '# no changes')
        if (-not $allNoChanges) { $diffProduced = $true }
    }
}

$outcome = 'n/a'
if ($whyOutcome) {
    $outcome = $whyOutcome
} elseif ($diffProduced) {
    $outcome = 'diff produced'
}

function Format-StatusValue {
    param($value)
    if ($null -eq $value) { return 'n/a' }
    if ($value -is [bool]) { return $value.ToString().ToLowerInvariant() }
    return [string]$value
}

$attemptSummary = $null
if ($statusData) {
    $attemptSummary = [string]::Format(
        'attempted={0} gate={1} auth_ok={2} attempts_left={3}',
        (Format-StatusValue $statusData.attempted),
        (Format-StatusValue $statusData.gate),
        (Format-StatusValue $statusData.auth_ok),
        (Format-StatusValue $statusData.attempts_left)
    )
}

$ndjsonSummaries = @()
if ($Artifacts) {
    $ndjsonSummaries = Get-ChildItem -Path $Artifacts -Filter 'ndjson_summary.txt' -File -Recurse -ErrorAction SilentlyContinue
}

$logDir = if ($Diag) { Join-Path $Diag 'logs' } else { $null }
if ($logDir) {
    try { New-Item -ItemType Directory -Path $logDir -Force | Out-Null } catch {}
}

$iterateZipName = "iterate-$Run-$Att.zip"
$iterateZipPath = if ($logDir) { Join-Path $logDir $iterateZipName } else { $null }
$iterateSentinelPath = if ($logDir) { Join-Path $logDir 'iterate.MISSING.txt' } else { $null }
$iterateErrorPath = if ($logDir) { Join-Path $logDir 'iterate-log-error.txt' } else { $null }
$batchRunAttempt = if ($BatchRunAttempt) { $BatchRunAttempt } else { 'n/a' }
$batchZipName = $null
$batchZipPath = $null
$batchZipReady = $false
$batchSentinelPath = if ($logDir) { Join-Path $logDir 'batch-check.MISSING.txt' } else { $null }

function Write-BatchSentinel {
    param([string]$Reason)

    if (-not $batchSentinelPath) { return }
    $message = 'batch-check logs not located for this commit'
    if (-not [string]::IsNullOrWhiteSpace($Reason)) { $message = $Reason }
    try { $message | Set-Content -Encoding UTF8 -LiteralPath $batchSentinelPath } catch {}
}

function ConvertTo-MirrorText {
    param(
        [string]$SourcePath,
        [int]$BinaryThreshold = 4096
    )

    # derived requirement: the supervisor needs text-friendly mirrors without
    # forcing GitHub-auth; keep mirrors resilient even when the source is
    # binary or oversized.
    if (-not (Test-Path -LiteralPath $SourcePath)) { return $null }
    try {
        $bytes = [System.IO.File]::ReadAllBytes($SourcePath)
    } catch {
        return $null
    }
    if ($null -eq $bytes -or $bytes.Length -eq 0) {
        # derived requirement: zero-byte files (e.g., .nojekyll, empty sentinels) must not
        # fault diagnostics; return an empty preview so mirrors stay stable without slicing.
        return ""
    }
    $length = $bytes.Length
    $probeLength = [Math]::Min($BinaryThreshold, $length)
    $binaryCount = 0
    if ($probeLength -gt 0) {
        $probe = $bytes[0..($probeLength - 1)]
        foreach ($b in $probe) {
            if ($b -lt 9 -or $b -eq 11 -or $b -eq 12 -or ($b -gt 13 -and $b -lt 32)) {
                $binaryCount += 1
            }
        }
    }
    if ($binaryCount -gt ($probeLength / 8)) {
        return "binary file stub ({0:N0} bytes)" -f $length
    }

    $limit = 128KB
    if ($length -gt $limit) {
        $prefix = [Math]::Min($limit, $length)
        $bytes = $bytes[0..($prefix - 1)]
    }
    try {
        $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    } catch {
        return "binary file stub ({0:N0} bytes)" -f $length
    }
    if (-not $text.EndsWith("`n")) { $text += "`n" }
    if ($length -gt $bytes.Length) {
        $text += "... [truncated from {0:N0} bytes]`n" -f $length
    }
    return $text
}

function Write-MirrorFile {
    param(
        [string]$SourcePath,
        [string]$MirrorPath,
        [System.Collections.Generic.List[object]]$Registry
    )

    if (-not $SourcePath -or -not (Test-Path -LiteralPath $SourcePath)) { return }
    if (-not $MirrorPath) { return }
    try { $null = New-Item -ItemType Directory -Path (Split-Path -Parent $MirrorPath) -Force } catch { return }

    $text = ConvertTo-MirrorText -SourcePath $SourcePath
    if ($null -eq $text) { return }

    try {
        $text | Set-Content -LiteralPath $MirrorPath -Encoding UTF8
        if ($Registry -ne $null) {
            $Registry.Add([pscustomobject]@{ Source = $SourcePath; Mirror = $MirrorPath }) | Out-Null
        }
    } catch {}
}

function Mirror-RepoFiles {
    param(
        [string]$SourceRoot,
        [string]$MirrorRoot
    )

    $created = [System.Collections.Generic.List[object]]::new()
    if (-not $SourceRoot -or -not (Test-Path -LiteralPath $SourceRoot)) { return $created }
    if (-not $MirrorRoot) { return $created }

    $files = Get-ChildItem -Path $SourceRoot -File -Recurse -ErrorAction SilentlyContinue
    foreach ($file in $files) {
        try {
            $relative = $file.FullName.Substring($SourceRoot.Length).TrimStart('\\','/')
        } catch {
            continue
        }
        $target = Join-Path $MirrorRoot $relative
        if (-not $target.EndsWith('.txt')) { $target += '.txt' }
        # derived requirement: only mirror the branch payload staged for this run;
        # skip other branches by following the extracted repo/files tree the
        # workflow prepared for the current commit.
        Write-MirrorFile -SourcePath $file.FullName -MirrorPath $target -Registry $created
    }
    return $created
}

function Mirror-LogZip {
    param(
        [string]$ZipPath,
        [string]$MirrorRoot
    )

    $created = [System.Collections.Generic.List[object]]::new()
    if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath)) { return $created }
    if (-not $MirrorRoot) { return $created }

    try {
        $null = New-Item -ItemType Directory -Path $MirrorRoot -Force
    } catch {}

    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($ZipPath)
    } catch {
        return $created
    }

    foreach ($entry in $archive.Entries) {
        if (-not $entry) { continue }
        if (-not $entry.Name) { continue }
        $safeName = $entry.FullName.Replace('\\','/').TrimStart('/')
        if ($safeName.StartsWith('..')) { continue }
        $targetPath = Join-Path $MirrorRoot $safeName
        if (-not $targetPath.EndsWith('.txt')) { $targetPath += '.txt' }
        try {
            $null = New-Item -ItemType Directory -Path (Split-Path -Parent $targetPath) -Force
        } catch {}
        try {
            $reader = New-Object System.IO.StreamReader($entry.Open(), [System.Text.Encoding]::UTF8, $true)
            $content = $reader.ReadToEnd()
            $reader.Close()
            if ($null -eq $content) { continue }
            if (-not $content.EndsWith("`n")) { $content += "`n" }
            $content | Set-Content -LiteralPath $targetPath -Encoding UTF8
            $created.Add([pscustomobject]@{ Source = $ZipPath; Mirror = $targetPath }) | Out-Null
        } catch {
            continue
        }
    }

    try { $archive.Dispose() } catch {}
    return $created
}

if (-not $BatchRunId -or $BatchRunId -eq 'n/a') {
    Write-BatchSentinel 'batch-check logs not located for this commit'
}

if ($BatchRunId) {
    $batchZipName = "batch-check-$BatchRunId-$batchRunAttempt.zip"
    if ($logDir) { $batchZipPath = Join-Path $logDir $batchZipName }
    if ($batchZipPath -and (Test-Path $batchZipPath)) {
        try {
            $info = Get-Item -LiteralPath $batchZipPath -ErrorAction Stop
            if ($info -and $info.Length -gt 0) {
                $batchZipReady = $true
                if ($batchSentinelPath) { Remove-Item -LiteralPath $batchSentinelPath -ErrorAction SilentlyContinue }
            }
        } catch {}
    }
}

$zipReady = $false
if ($iterateZipPath -and (Test-Path $iterateZipPath)) {
    try {
        $info = Get-Item -LiteralPath $iterateZipPath -ErrorAction Stop
        if ($info -and $info.Length -gt 0) {
            $zipReady = $true
            if ($iterateSentinelPath) { Remove-Item -LiteralPath $iterateSentinelPath -ErrorAction SilentlyContinue }
            if ($iterateErrorPath) { Remove-Item -LiteralPath $iterateErrorPath -ErrorAction SilentlyContinue }
        }
    } catch {}
}

if (-not $zipReady -and $logDir -and -not $preferLocalIterate) {
    # Professional note: the workflow maps the Actions token to GH_TOKEN; fall back
    # to GITHUB_TOKEN so local runs stay compatible with the published contract.
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    $repoSlug = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } elseif ($Repo) { $Repo } else { $null }
    $runId = $null
    if ($Run -and $Run -ne 'n/a') { $runId = $Run }
    elseif ($env:GITHUB_RUN_ID) { $runId = $env:GITHUB_RUN_ID }
    if ($token -and $repoSlug -and $repoSlug.Contains('/') -and $runId) {
        $parts = $repoSlug.Split('/', 2)
        $owner = $parts[0]
        $repoName = $parts[1]
        $baseName = "iterate-logs-$Run-$Att"
        $headers = @{
            Accept                 = 'application/vnd.github+json'
            Authorization          = "Bearer $token"
            'User-Agent'           = 'publish_index.ps1 diagnostics'
            'X-GitHub-Api-Version' = '2022-11-28'
        }
        $downloadSelection = Get-IterateArtifactForRun -Owner $owner -RepoName $repoName -TargetRunId $runId -BaseNames @($baseName) -Headers $headers
        $downloadRunId = $runId
        if (-not $downloadSelection -and $SHA -and $SHA -ne 'n/a') {
            $workflowUri = "https://api.github.com/repos/$owner/$repoName/actions/workflows/codex-auto-iterate.yml/runs?head_sha=$SHA&per_page=10"
            $workflowResponse = $null
            try {
                $workflowResponse = Invoke-RestMethod -Uri $workflowUri -Headers $headers -ErrorAction Stop
            } catch {}
            if ($workflowResponse -and $workflowResponse.workflow_runs) {
                # Professional note: the iterate bundle originates from codex-auto-iterate.yml,
                # not the diagnostics workflow.
                # Falling back by head SHA keeps publishing truthful when the archive lives on a sibling run.
                foreach ($wfRun in $workflowResponse.workflow_runs) {
                    $wfId = [string]$wfRun.id
                    if (-not $wfId) { continue }
                    $wfAttempt = if ($wfRun.run_attempt) { [string]$wfRun.run_attempt } else { '1' }
                    $altBase = "iterate-logs-$wfId-$wfAttempt"
                    $candidateSelection = Get-IterateArtifactForRun -Owner $owner -RepoName $repoName -TargetRunId $wfId -BaseNames @($altBase) -Headers $headers
                    if ($candidateSelection) {
                        $downloadSelection = $candidateSelection
                        $downloadRunId = $wfId
                        break
                    }
                }
            }
        }

        if ($downloadSelection) {
            $choice = $downloadSelection.Artifact
            $downloadUri = $null
            $acceptHeader = 'application/octet-stream'
            if ($choice.id -is [int]) {
                $artifactId = [int]$choice.id
                $downloadUri = "https://api.github.com/repos/$owner/$repoName/actions/artifacts/$artifactId/zip"
                $acceptHeader = 'application/vnd.github+json'
            } elseif ($choice.archive_download_url) {
                $downloadUri = [string]$choice.archive_download_url
            }

            if ($downloadUri) {
                Remove-Item -LiteralPath $iterateZipPath -ErrorAction SilentlyContinue
                try {
                    Invoke-WebRequest -Uri $downloadUri -Headers @{
                        Authorization          = "Bearer $token"
                        'User-Agent'           = 'publish_index.ps1 diagnostics'
                        Accept                 = $acceptHeader
                        'X-GitHub-Api-Version' = '2022-11-28'
                    } -OutFile $iterateZipPath -ErrorAction Stop
                    $info = Get-Item -LiteralPath $iterateZipPath -ErrorAction Stop
                    if ($info -and $info.Length -gt 0) {
                        # Professional note: Runs like 19122439464-1 uploaded the iterate artifact
                        # successfully, but the prior publisher fell back to the run-log endpoint.
                        # Clearing the sentinels here keeps the diagnostics page truthful once the
                        # artifact download succeeds.
                        if ($iterateSentinelPath) { Remove-Item -LiteralPath $iterateSentinelPath -ErrorAction SilentlyContinue }
                        if ($iterateErrorPath) { Remove-Item -LiteralPath $iterateErrorPath -ErrorAction SilentlyContinue }
                        $zipReady = $true
                    } else {
                        Remove-Item -LiteralPath $iterateZipPath -ErrorAction SilentlyContinue
                    }
                } catch {
                    Remove-Item -LiteralPath $iterateZipPath -ErrorAction SilentlyContinue
                }
            }
        }
    }
}

$batchDownloadAttempt = if ($batchRunAttempt -and $batchRunAttempt -ne 'n/a') { $batchRunAttempt } else { '1' }
if (-not $batchZipReady -and $logDir -and $BatchRunId -and $BatchRunId -ne 'n/a' -and $batchZipPath) {
    $token = if ($env:GH_TOKEN) { $env:GH_TOKEN } else { $env:GITHUB_TOKEN }
    $repoSlug = if ($env:GITHUB_REPOSITORY) { $env:GITHUB_REPOSITORY } elseif ($Repo) { $Repo } else { $null }
    if ($token -and $repoSlug -and $repoSlug.Contains('/')) {
        $parts = $repoSlug.Split('/', 2)
        $owner = $parts[0]
        $repoName = $parts[1]
        $downloadUri = "https://api.github.com/repos/$owner/$repoName/actions/runs/$BatchRunId/attempts/$batchDownloadAttempt/logs"

        Remove-Item -LiteralPath $batchZipPath -ErrorAction SilentlyContinue
        try {
            Invoke-WebRequest -Uri $downloadUri -Headers @{
                Authorization          = "Bearer $token"
                'User-Agent'           = 'publish_index.ps1 diagnostics'
                Accept                 = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2022-11-28'
            } -OutFile $batchZipPath -ErrorAction Stop

            $info = Get-Item -LiteralPath $batchZipPath -ErrorAction Stop
            if ($info -and $info.Length -gt 0) {
                $batchZipReady = $true
                if ($batchSentinelPath) { Remove-Item -LiteralPath $batchSentinelPath -ErrorAction SilentlyContinue }
            } else {
                Remove-Item -LiteralPath $batchZipPath -ErrorAction SilentlyContinue
                Write-BatchSentinel ("batch-check log download returned empty archive: {0}" -f $downloadUri)
            }
        } catch {
            Remove-Item -LiteralPath $batchZipPath -ErrorAction SilentlyContinue
            Write-BatchSentinel ("batch-check log download failed: {0}" -f $downloadUri)
        }
    } else {
        Write-BatchSentinel 'batch-check log download prerequisites missing (token/repository)'
    }
} elseif (-not $batchZipReady -and $BatchRunId -and $BatchRunId -ne 'n/a' -and -not $batchZipPath) {
    Write-BatchSentinel 'batch-check log download prerequisites missing (log path unavailable)'
}

$iterateExtracted = $false
if ($zipReady -and $Artifacts -and $iterateZipPath) {
    $iterateRoot = Join-Path $Artifacts 'iterate'
    $expectedDir = Join-Path $iterateRoot ("iterate-logs-$Run-$Att")
    try {
        New-Item -ItemType Directory -Path $iterateRoot -Force | Out-Null
    } catch {}
    $needsExtract = $true
    if (Test-Path $expectedDir) {
        try {
            $probe = Get-ChildItem -Path $expectedDir -Recurse -Force -File -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($probe) { $needsExtract = $false }
        } catch {}
    }
    if ($needsExtract) {
        try {
            if (Test-Path $expectedDir) {
                Remove-Item -LiteralPath $expectedDir -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Path $expectedDir -Force | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($iterateZipPath, $expectedDir)
            $iterateExtracted = $true
        } catch {
            # Professional note: partial or corrupted bundles should not block publishing;
            # keep the archive but skip extraction so fallback logic preserves breadcrumbs.
        }
    }
}

$iterateStatus = 'found'
if (-not $iterateZipPath -or -not (Test-Path $iterateZipPath)) {
    $iterateStatus = 'missing (see logs/iterate.MISSING.txt)'
}

$batchStatusOverride = $env:BATCH_STATUS_OVERRIDE
$batchStatus = 'missing'
if ($batchStatusOverride) {
    $batchStatus = $batchStatusOverride
} elseif ($BatchRunId) {
    if (-not $batchZipName) { $batchZipName = "batch-check-$BatchRunId-$batchRunAttempt.zip" }
    if (-not $batchZipPath -and $Diag -and $batchZipName) { $batchZipPath = Join-Path $Diag ('logs\' + $batchZipName) }
    if ($batchZipPath -and (Test-Path $batchZipPath)) {
        $batchStatus = "found (run $BatchRunId, attempt $batchRunAttempt)"
    } else {
        $batchStatus = "missing archive (run $BatchRunId, attempt $batchRunAttempt)"
    }
} elseif ($Diag -and $batchSentinelPath -and (Test-Path $batchSentinelPath)) {
    $batchStatus = 'missing (see logs/batch-check.MISSING.txt)'
}

$mirrorRoot = if ($Diag) { Join-Path $Diag '_mirrors' } else { $null }
$mirrorRegistry = [System.Collections.Generic.List[object]]::new()
if ($mirrorRoot) {
    try { New-Item -ItemType Directory -Path $mirrorRoot -Force | Out-Null } catch {}

    $repoSource = $null
    if ($Diag) {
        $candidateRepo = Join-Path $Diag 'repo/files'
        if (Test-Path $candidateRepo) { $repoSource = $candidateRepo }
        if (-not $repoSource) {
            $candidateRepo = Join-Path $Diag 'repo'
            if (Test-Path $candidateRepo) { $repoSource = $candidateRepo }
        }
    }
    if ($repoSource) {
        $repoMirrorRoot = Join-Path $mirrorRoot 'repo'
        foreach ($entry in (Mirror-RepoFiles -SourceRoot $repoSource -MirrorRoot $repoMirrorRoot)) { $mirrorRegistry.Add($entry) | Out-Null }
    }

    $logsMirrorRoot = Join-Path $mirrorRoot 'logs'
    if ($iterateZipPath -and (Test-Path $iterateZipPath)) {
        $iterateMirror = Join-Path $logsMirrorRoot 'iterate'
        foreach ($entry in (Mirror-LogZip -ZipPath $iterateZipPath -MirrorRoot $iterateMirror)) { $mirrorRegistry.Add($entry) | Out-Null }
    }
    if ($batchZipReady -and $batchZipPath -and (Test-Path $batchZipPath)) {
        $batchMirror = Join-Path $logsMirrorRoot 'batch-check'
        foreach ($entry in (Mirror-LogZip -ZipPath $batchZipPath -MirrorRoot $batchMirror)) { $mirrorRegistry.Add($entry) | Out-Null }
    }
    if ($logDir -and (Test-Path $logDir)) {
        foreach ($logFile in Get-ChildItem -Path $logDir -File -Recurse -ErrorAction SilentlyContinue) {
            $relative = Get-Relative $logFile.FullName
            if (-not $relative) { continue }
            $relative = $relative.TrimStart('./')
            $target = Join-Path (Join-Path $logsMirrorRoot 'bundle') $relative
            if (-not $target.EndsWith('.txt')) { $target += '.txt' }
            Write-MirrorFile -SourcePath $logFile.FullName -MirrorPath $target -Registry $mirrorRegistry
        }
    }

    $mirrorInventory = Join-Path $mirrorRoot 'inventory.txt'
    $mirrorFiles = Get-ChildItem -Path $mirrorRoot -File -Recurse -ErrorAction SilentlyContinue
    if ($mirrorFiles) {
        $inventoryLines = @()
        foreach ($mf in $mirrorFiles) {
            $rel = Get-Relative $mf.FullName
            $inventoryLines += ('{0} bytes {1}' -f $mf.Length, $rel)
        }
        try { $inventoryLines | Set-Content -LiteralPath $mirrorInventory -Encoding UTF8 } catch {}
    }
}

$artifactFiles = @()
if ($Artifacts) {
    $artifactFiles = Get-ChildItem -Path $Artifacts -Recurse -File -ErrorAction SilentlyContinue
}
$artifactCount = 0
if ($artifactFiles) { $artifactCount = (@($artifactFiles)).Count }
$artifactMissing = $null
$artifactMissingPath = if ($Artifacts) { Join-Path $Artifacts 'MISSING.txt' } else { $null }
if ($artifactMissingPath -and (Test-Path $artifactMissingPath)) {
    $artifactMissing = (Get-Content -Raw -LiteralPath $artifactMissingPath).Trim()
}

$allFiles = @()
if ($Diag) {
    $allFiles = Get-ChildItem -Path $Diag -Recurse -File -ErrorAction SilentlyContinue | Sort-Object FullName
}

$lines = [System.Collections.Generic.List[string]]::new()
foreach ($seed in @(
        '# CI Diagnostics',
        "Repo: $Repo",
        "Commit: $SHA",
        "Run: $Run (attempt $Att)",
        "Built (UTC): $UTC",
        "Built (CT): $CT",
        "Run page: $RunUrl",
        '',
        # Professional note: surface sentinel results up front so unauthenticated readers know which assets landed.
        '## Status',
        [string]::Format('- Iterate logs: {0}', $iterateStatus),
        [string]::Format('- Batch-check run id: {0}', $batchStatus),
        [string]::Format('- Artifact files enumerated: {0}', $artifactCount)
    )) {
    $null = $lines.Add($seed)
}

if ($artifactMissing) {
    $null = $lines.Add([string]::Format('- Artifact sentinel: {0}', $artifactMissing))
}

$null = $lines.Add('')
$null = $lines.Add('## Quick links')
$bundleLinks = @(
    @{ Label = 'Inventory (HTML)'; Path = 'inventory.html'; Exists = ($Diag -and (Test-Path (Join-Path $Diag 'inventory.html'))) },
    @{ Label = 'Inventory (text)'; Path = 'inventory.txt'; Exists = ($Diag -and (Test-Path (Join-Path $Diag 'inventory.txt'))) },
    @{ Label = 'Inventory (markdown)'; Path = 'inventory.md'; Exists = ($Diag -and (Test-Path (Join-Path $Diag 'inventory.md'))) },
    @{ Label = 'Inventory (json)'; Path = 'inventory.json'; Exists = ($Diag -and (Test-Path (Join-Path $Diag 'inventory.json'))) },
    @{ Label = 'Iterate logs zip'; Path = "logs/$iterateZipName"; Exists = ($iterateZipPath -and (Test-Path $iterateZipPath)) },
    @{ Label = 'Batch-check logs zip'; Path = if ($batchZipName) { "logs/$batchZipName" } else { $null }; Exists = if ($batchZipName -and $Diag) { Test-Path (Join-Path $Diag ('logs\' + $batchZipName)) } else { $false } },
    @{ Label = 'Batch-check failing tests'; Path = 'batchcheck_failing.txt'; Exists = ($Diag -and (Test-Path (Join-Path $Diag 'batchcheck_failing.txt'))) },
    @{ Label = 'Batch-check fail debug'; Path = 'batchcheck_fail-debug.txt'; Exists = ($Diag -and (Test-Path (Join-Path $Diag 'batchcheck_fail-debug.txt'))) },
    @{ Label = 'Repository zip'; Path = "repo/repo-$Short.zip"; Exists = ($Diag -and (Test-Path (Join-Path $Diag ("repo\repo-$Short.zip")))) },
    @{ Label = 'Repository files (unzipped)'; Path = 'repo/files/'; Exists = ($Diag -and (Test-Path (Join-Path $Diag 'repo\files'))) }
)

if ($iterateDir) {
    $ciLogsCandidate = Join-Path $iterateDir 'logs.zip'
    if (Test-Path $ciLogsCandidate) {
        try { $ciInfo = Get-Item -LiteralPath $ciLogsCandidate -ErrorAction Stop } catch { $ciInfo = $null }
        if ($ciInfo -and $ciInfo.Length -gt 0) {
            $ciRelative = Get-Relative $ciLogsCandidate
            if ($ciRelative) {
                # derived requirement: surface GitHub Actions run logs so analysts do not need to re-download them from the UI.
                $bundleLinks += @{ Label = 'CI job logs'; Path = $ciRelative; Exists = $true }
            }
        }
    }
}

if ($Diag) {
    $wfTxts = Get-ChildItem -Path (Join-Path $Diag 'wf') -Filter '*.yml.txt' -File -ErrorAction SilentlyContinue
    foreach ($w in $wfTxts) {
        $name = $w.Name
        $bundleLinks += @{ Label = "Workflow: $name"; Path = ("wf/" + $name); Exists = $true }
    }
}

foreach ($entry in $bundleLinks) {
    if (-not $entry.Path) { continue }
    if ($entry.Exists) {
        $linkPath = Normalize-Link $entry.Path
        $link = [string]::Format('- {0}: [{1}]({1})', $entry.Label, $linkPath)
        $null = $lines.Add($link)
    } else {
        $note = [string]::Format('- {0}: missing', $entry.Label)
        $null = $lines.Add($note)
    }
}

$null = $lines.Add('')
$null = $lines.Add('## Iterate metadata')
foreach ($seed in @(
        [string]::Format('- Decision: {0}', $decision),
        [string]::Format('- Outcome: {0}', $outcome),
        [string]::Format('- HTTP status: {0}', $httpStatus),
        [string]::Format('- Model: {0}', $model),
        [string]::Format('- Endpoint: {0}', $endpoint),
        [string]::Format('- Tokens: prompt={0} completion={1} total={2}', $tokens['prompt'], $tokens['completion'], $tokens['total'])
    )) {
    $null = $lines.Add($seed)
}

if (-not $responseData -and $attemptSummary) {
    # Professional note: surface gate/auth outcomes when no response payload exists so
    # analysts immediately see why the iterate call was skipped.
    $null = $lines.Add([string]::Format('- Attempt summary: {0}', $attemptSummary))
}

if ($iterateDir) {
    $iterFiles = Get-ChildItem -Path $iterateDir -File -ErrorAction SilentlyContinue
    if ($iterFiles) {
        $null = $lines.Add('')
        $null = $lines.Add('### Iterate files')
        foreach ($file in $iterFiles) {
            $rel = Get-Relative $file.FullName
            $relNorm = Normalize-Link $rel
            $iterLine = [string]::Format('- [`{0}`]({1})', $relNorm, $relNorm)
            $null = $lines.Add($iterLine)
        }
    }
}

$batchRunMeta = if ($Artifacts) { Join-Path (Join-Path $Artifacts 'batch-check') 'run.json' } else { $null }
if ($batchRunMeta -and (Test-Path $batchRunMeta)) {
    try {
        $meta = Get-Content -Raw -LiteralPath $batchRunMeta | ConvertFrom-Json
        $null = $lines.Add('')
        $null = $lines.Add('## Batch-check run')
        $runLine = [string]::Format('- Run id: {0} (attempt {1})', $meta.run_id, $meta.run_attempt)
        $statusLine = [string]::Format('- Status: {0} / {1}', $meta.status, $meta.conclusion)
        $null = $lines.Add($runLine)
        $null = $lines.Add($statusLine)
        if ($meta.html_url) {
            $runPageLine = [string]::Format('- Run page: {0}', $meta.html_url)
            $null = $lines.Add($runPageLine)
        }
    } catch {}
}

if ($ndjsonSummaries) {
    $null = $lines.Add('')
    $null = $lines.Add('## NDJSON summaries')
    foreach ($file in $ndjsonSummaries) {
        $rel = Get-Relative $file.FullName
        $heading = [string]::Format('### {0}', $rel)
        $null = $lines.Add($heading)
        $null = $lines.Add('```text')
        foreach ($segment in Get-Content -LiteralPath $file.FullName) {
            $null = $lines.Add($segment)
        }
        $null = $lines.Add('```')
    }
}

if ($allFiles) {
    $null = $lines.Add('')
    $null = $lines.Add('## File listing')
    foreach ($item in $allFiles) {
        $rel = Get-Relative $item.FullName
        $size = '{0:N0}' -f $item.Length
        $relNorm = Normalize-Link $rel
        $line = [string]::Format('- [{0} bytes]({1})', $size, $relNorm)
        $null = $lines.Add($line)
    }
}

if ($InventoryB64) {
    try {
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($InventoryB64))
        if ($decoded) {
            $null = $lines.Add('')
            $null = $lines.Add('## Inventory (raw)')
            foreach ($entry in $decoded.Split("`n")) {
                $null = $lines.Add($entry)
            }
        }
    } catch {}
}

$markdown = $lines.ToArray() -join "`n"
$mdPath = if ($Diag) { Join-Path $Diag 'index.md' } else { $null }
if ($mdPath) {
    $markdown | Set-Content -Encoding UTF8 -NoNewline $mdPath
}

function Escape-Html {
    param([string]$value)
    if ($null -eq $value) { return '' }
    $encoded = $value -replace '&', '&amp;'
    $encoded = $encoded -replace '<', '&lt;'
    return $encoded -replace '>', '&gt;'
}

function Escape-Href {
    param([string]$value)
    if ([string]::IsNullOrWhiteSpace($value)) { return $value }
    try {
        return [System.Uri]::EscapeUriString($value)
    } catch {
        return $value
    }
}

$statusPairs = @(
    @{ Label = 'Iterate logs'; Value = $iterateStatus },
    @{ Label = 'Batch-check run id'; Value = $batchStatus },
    @{ Label = 'Artifact files enumerated'; Value = [string]$artifactCount }
)
if ($artifactMissing) {
    $statusPairs += @{ Label = 'Artifact sentinel'; Value = $artifactMissing }
}

$metadataPairs = @(
    @{ Label = 'Repo'; Value = $Repo },
    @{ Label = 'Commit'; Value = $SHA },
    @{ Label = 'Run'; Value = [string]::Format('{0} (attempt {1})', $Run, $Att) },
    @{ Label = 'Built (UTC)'; Value = $UTC },
    @{ Label = 'Built (CT)'; Value = $CT },
    @{ Label = 'Run page'; Value = $RunUrl; Href = $RunUrl }
)

$iteratePairs = @(
    @{ Label = 'Decision'; Value = $decision },
    @{ Label = 'Outcome'; Value = $outcome },
    @{ Label = 'HTTP status'; Value = $httpStatus },
    @{ Label = 'Model'; Value = $model },
    @{ Label = 'Endpoint'; Value = $endpoint },
    @{ Label = 'Tokens'; Value = [string]::Format('prompt={0} completion={1} total={2}', $tokens['prompt'], $tokens['completion'], $tokens['total']) }
)
if (-not $responseData -and $attemptSummary) {
    $iteratePairs += @{ Label = 'Attempt summary'; Value = $attemptSummary }
}

$html = [System.Collections.Generic.List[string]]::new()
$html.Add('<!doctype html>') | Out-Null
$html.Add('<html lang="en">') | Out-Null
$html.Add('<head>') | Out-Null
$html.Add('<meta charset="utf-8">') | Out-Null
$html.Add('<title>CI Diagnostics</title>') | Out-Null
$html.Add('</head>') | Out-Null
$html.Add('<body>') | Out-Null
$html.Add('<h1>CI Diagnostics</h1>') | Out-Null
$html.Add('<section>') | Out-Null
$html.Add('<h2>Metadata</h2>') | Out-Null
$html.Add('<ul>') | Out-Null
# Professional note: Invoke the Escape-* helpers without parentheses here;
# hyphenated function names like Escape-Html() can be parsed as parameter
# switches if written as Escape-Html($value), which triggers hosted runner
# syntax errors during publishing.
foreach ($pair in $metadataPairs) {
    $label = Escape-Html $pair.Label
    if ($pair.ContainsKey('Href') -and $pair.Href) {
        $href = Escape-Href $pair.Href
        $value = Escape-Html $pair.Value
        $html.Add([string]::Format('<li><strong>{0}:</strong> <a href="{1}">{2}</a></li>', $label, $href, $value)) | Out-Null
    } else {
        $html.Add([string]::Format('<li><strong>{0}:</strong> {1}</li>', $label, $(Escape-Html $pair.Value))) | Out-Null
    }
}
$html.Add('</ul>') | Out-Null
$html.Add('</section>') | Out-Null

$html.Add('<section>') | Out-Null
$html.Add('<h2>Status</h2>') | Out-Null
$html.Add('<ul>') | Out-Null
foreach ($pair in $statusPairs) {
    $html.Add([string]::Format('<li><strong>{0}:</strong> {1}</li>', $(Escape-Html $pair.Label), $(Escape-Html $pair.Value))) | Out-Null
}
$html.Add('</ul>') | Out-Null
$html.Add('</section>') | Out-Null

$html.Add('<section>') | Out-Null
$html.Add('<h2>Quick links</h2>') | Out-Null
$html.Add('<ul>') | Out-Null
foreach ($entry in $bundleLinks) {
    if (-not $entry.Path) { continue }
    $label = Escape-Html $entry.Label
    if ($entry.Exists) {
        $href = Escape-Href (Normalize-Link $entry.Path)
        $html.Add([string]::Format('<li><a href="{0}">{1}</a></li>', $href, $label)) | Out-Null
    } else {
        $html.Add([string]::Format('<li>{0}: missing</li>', $label)) | Out-Null
    }
}
$html.Add('</ul>') | Out-Null
$html.Add('</section>') | Out-Null

$html.Add('<section>') | Out-Null
$html.Add('<h2>Iterate metadata</h2>') | Out-Null
$html.Add('<ul>') | Out-Null
foreach ($pair in $iteratePairs) {
    $html.Add([string]::Format('<li><strong>{0}:</strong> {1}</li>', $(Escape-Html $pair.Label), $(Escape-Html $pair.Value))) | Out-Null
}
$html.Add('</ul>') | Out-Null
$html.Add('</section>') | Out-Null

if ($iterateDir -and $iterFiles) {
    $html.Add('<section>') | Out-Null
    $html.Add('<h3>Iterate files</h3>') | Out-Null
    $html.Add('<ul>') | Out-Null
    foreach ($file in $iterFiles) {
        $rel = Get-Relative $file.FullName
        $relNorm = Normalize-Link $rel
        $href = Escape-Href $relNorm
        $text = Escape-Html $relNorm
        $html.Add([string]::Format('<li><code><a href="{0}">{1}</a></code></li>', $href, $text)) | Out-Null
    }
    $html.Add('</ul>') | Out-Null
    $html.Add('</section>') | Out-Null
}

if ($batchRunMeta -and (Test-Path $batchRunMeta)) {
    try {
        $meta = Get-Content -Raw -LiteralPath $batchRunMeta | ConvertFrom-Json
        $html.Add('<section>') | Out-Null
        $html.Add('<h2>Batch-check run</h2>') | Out-Null
        $html.Add('<ul>') | Out-Null
        $html.Add([string]::Format('<li>Run id: {0} (attempt {1})</li>', $(Escape-Html $meta.run_id), $(Escape-Html $meta.run_attempt))) | Out-Null
        $html.Add([string]::Format('<li>Status: {0} / {1}</li>', $(Escape-Html $meta.status), $(Escape-Html $meta.conclusion))) | Out-Null
        if ($meta.html_url) {
            $html.Add([string]::Format('<li><a href="{0}">Run page</a></li>', $(Escape-Href $meta.html_url))) | Out-Null
        }
        $html.Add('</ul>') | Out-Null
        $html.Add('</section>') | Out-Null
    } catch {}
}

if ($ndjsonSummaries) {
    $html.Add('<section>') | Out-Null
    $html.Add('<h2>NDJSON summaries</h2>') | Out-Null
    foreach ($file in $ndjsonSummaries) {
        $rel = Get-Relative $file.FullName
        $html.Add([string]::Format('<h3>{0}</h3>', $(Escape-Html $rel))) | Out-Null
        $html.Add('<pre>') | Out-Null
        foreach ($segment in Get-Content -LiteralPath $file.FullName) {
            $html.Add($(Escape-Html $segment)) | Out-Null
        }
        $html.Add('</pre>') | Out-Null
    }
    $html.Add('</section>') | Out-Null
}

if ($allFiles) {
    $html.Add('<section>') | Out-Null
    $html.Add('<h2>File listing</h2>') | Out-Null
    $html.Add('<ul>') | Out-Null
    foreach ($item in $allFiles) {
        $rel = Get-Relative $item.FullName
        $relNorm = Normalize-Link $rel
        $href = Escape-Href $relNorm
        $text = Escape-Html $relNorm
        $size = Escape-Html ('{0:N0} bytes' -f $item.Length)
        $html.Add([string]::Format('<li><a href="{0}">{1}</a> — {2}</li>', $href, $text, $size)) | Out-Null
    }
    $html.Add('</ul>') | Out-Null
    $html.Add('</section>') | Out-Null
}

if ($InventoryB64) {
    try {
        $decoded = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($InventoryB64))
        if ($decoded) {
            $html.Add('<section>') | Out-Null
            $html.Add('<h2>Inventory (raw)</h2>') | Out-Null
            $html.Add('<pre>') | Out-Null
            foreach ($entry in $decoded.Split("`n")) {
                $html.Add($(Escape-Html $entry)) | Out-Null
            }
            $html.Add('</pre>') | Out-Null
            $html.Add('</section>') | Out-Null
        }
    } catch {}
}

$html.Add('</body>') | Out-Null
$html.Add('</html>') | Out-Null

if ($Diag) {
    ($html -join "`n") | Set-Content -Encoding UTF8 -NoNewline (Join-Path $Diag 'index.html')
}

$site = $env:SITE
if ($site -and $Diag -and $Run -and $Att -and $Repo -and $SHA) {
    $obj = [pscustomobject]@{
        repo        = $Repo
        run_id      = $Run
        run_attempt = $Att
        sha         = $SHA
        bundle_url  = "diag/$Run-$Att/index.html"
        inventory   = "diag/$Run-$Att/inventory.json"
        workflow    = "diag/$Run-$Att/wf/codex-auto-iterate.yml.txt"
        iterate = @{
            prompt   = "diag/$Run-$Att/_artifacts/iterate/iterate/prompt.txt"
            response = "diag/$Run-$Att/_artifacts/iterate/iterate/response.json"
            diff     = "diag/$Run-$Att/_artifacts/iterate/iterate/patch.diff"
            log      = "diag/$Run-$Att/_artifacts/iterate/iterate/exec.log"
        }
    }
    $obj | ConvertTo-Json -Depth 4 | Set-Content -Encoding UTF8 (Join-Path $site 'latest.json')
}
