$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path $nd)) { New-Item -ItemType File -Path $nd -Force | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

function Write-NdjsonRow {
    param([hashtable]$Row)

    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

function Get-LineSnippet {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if (-not $Text) { return '' }
    foreach ($line in $Text -split "`r?`n") {
        if ($line -match $Pattern) {
            $trimmed = $line.Trim()
            if ($trimmed.Length -gt 160) { return $trimmed.Substring(0,160) }
            return $trimmed
        }
    }
    return ''
}

$script:RecordedPipreqs = $false

function Check-PipreqsFailure {
    param(
        [string]$LogPath,
        [string]$LogText
    )

    if ($script:RecordedPipreqs -or -not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return }
    if (-not $LogText) { $LogText = Get-Content -LiteralPath $LogPath -Raw -Encoding Ascii }

    $patterns = @(
        'No module named pipreqs\.__main__',
        'ERROR\s+conda\.cli\.main_run:execute\(127\):'
    )

    foreach ($pattern in $patterns) {
        if ($LogText -match $pattern) {
            $snippet = Get-LineSnippet -Text $LogText -Pattern $pattern
            $details = [ordered]@{ file = $LogPath }
            if ($snippet) { $details.snippet = $snippet }
            Write-NdjsonRow ([ordered]@{
                id      = 'pipreqs.run'
                pass    = $false
                desc    = 'pipreqs invocation failed during bootstrap'
                details = $details
            })
            $script:RecordedPipreqs = $true
            break
        }
    }
}

# Non-Windows runners cannot exercise the Windows bootstrap; Windows CI still
# covers the real envsmoke flow, so explicitly mark these checks as skipped.
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    $details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.env.smoke.conda'
        pass    = $true
        desc    = 'Miniconda bootstrap skipped on non-Windows host'
        details = $details
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.env.smoke.run'
        pass    = $true
        desc    = 'App run skipped on non-Windows host'
        details = $details
    })
    exit 0
}

# Emit a tiny app that imports a small conda-forge package and prints a token
$app = Join-Path $here '~envsmoke'
$setupLog = Join-Path $app '~setup.log'
New-Item -ItemType Directory -Force -Path $app | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $app -Force
Set-Content -LiteralPath (Join-Path $app 'app.py') -Value @'
import colorama
print("smoke-ok")
'@ -NoNewline

if (Test-Path -LiteralPath $setupLog) {
    Remove-Item -LiteralPath $setupLog -Force
}

$prevVenvFallback = if (Test-Path Env:HP_ALLOW_VENV_FALLBACK) { $env:HP_ALLOW_VENV_FALLBACK } else { $null }
$env:HP_ALLOW_VENV_FALLBACK = '1'

Push-Location -LiteralPath $app
try {
    # FULL bootstrap here: do NOT set HP_CI_SKIP_ENV
    cmd /c .\run_setup.bat *> '~envsmoke_bootstrap.log'
    $exit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prevVenvFallback) {
        Remove-Item Env:HP_ALLOW_VENV_FALLBACK -ErrorAction SilentlyContinue
    } else {
        $env:HP_ALLOW_VENV_FALLBACK = $prevVenvFallback
    }
}

$blog   = Join-Path $app '~envsmoke_bootstrap.log'
$runout = Join-Path $app '~run.out.txt'
$setup  = (Test-Path $setupLog) ? (Get-Content -LiteralPath $setupLog -Raw -Encoding Ascii) : ''
$bltxt  = (Test-Path $blog)   ? (Get-Content -LiteralPath $blog   -Raw -Encoding Ascii) : ''
$outxt  = (Test-Path $runout) ? (Get-Content -LiteralPath $runout -Raw -Encoding Ascii) : ''

$smokeCommand = ''
if ($setup) {
    $cmdMatch = [regex]::Match($setup, '^Smoke command:\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($cmdMatch.Success) {
        $smokeCommand = $cmdMatch.Groups[1].Value.Trim()
    }
}

# derived requirement: envsmoke failures must surface the bootstrap command
$bootstrapCommand = 'cmd /c .\run_setup.bat (envsmoke bootstrap)'
$displayCommand = if ($smokeCommand) { $smokeCommand } else { $bootstrapCommand }

Check-PipreqsFailure -LogPath $setupLog -LogText $setup

$haveRunOut = Test-Path -LiteralPath $runout
$tokenFound = $haveRunOut -and (($outxt -match 'hello-from-stub') -or ($outxt -match 'smoke-ok'))

# derived requirement: supervisors consume iterate inputs as plain text. Mirror the
# smoke transcripts into _artifacts/iterate/inputs so agents on small devices can
# review failures without downloading large archives.
$inputsRoot = Join-Path $repo '_artifacts/iterate/inputs'
try {
    New-Item -ItemType Directory -Force -Path $inputsRoot | Out-Null
} catch {
    # best effort; diagnostics should proceed even if the mirror cannot be written.
}

$condaMirror = Join-Path $inputsRoot 'env_smoke_conda.log.txt'
$runMirror = Join-Path $inputsRoot 'env_smoke_run.log.txt'

try {
    $condaLines = @()
    if ($setup) {
        $condaLines += '# ~setup.log'
        $condaLines += $setup
    }
    if ($bltxt) {
        $condaLines += '# ~envsmoke_bootstrap.log'
        $condaLines += $bltxt
    }
    if (-not $condaLines) { $condaLines = @('(no bootstrap logs captured)') }
    Set-Content -LiteralPath $condaMirror -Value ($condaLines -join "`n") -Encoding Ascii
} catch {
    # keep diagnostics stable if the mirror write fails.
}

try {
    $runLines = @()
    if ($outxt) {
        $runLines += '# ~run.out.txt'
        $runLines += $outxt
    } else {
        $runLines += '(no run output captured)'
    }
    Set-Content -LiteralPath $runMirror -Value ($runLines -join "`n") -Encoding Ascii
} catch {
    # keep diagnostics stable if the mirror write fails.
}

# Record two rows: env setup + app run
Write-NdjsonRow ([ordered]@{
    id='self.env.smoke.conda'
    pass=($exit -eq 0)
    desc='Miniconda bootstrap + environment creation'
    details=[ordered]@{ exitCode=$exit; command=$displayCommand }
})

$passRun = ($exit -eq 0) -and $tokenFound
Write-NdjsonRow ([ordered]@{
    id='self.env.smoke.run'
    pass=$passRun
    desc='App runs in created environment'
    details=[ordered]@{ exitCode=$exit; tokenFound=$tokenFound; haveRunOut=$haveRunOut; command=$displayCommand }
})

if (($exit -eq 0) -and (-not $tokenFound)) {
    $snippet = Get-LineSnippet -Text $outxt -Pattern 'smoke-ok'
    $details = [ordered]@{ file = $runout; exitCode = $exit; tokenFound = $tokenFound; haveRunOut = $haveRunOut; command = $displayCommand }
    if ($snippet) { $details.snippet = $snippet }
    Write-NdjsonRow ([ordered]@{
        id='envsmoke.run'
        pass=$false
        desc='Environment smoke run missing expected output token after success'
        details=$details
    })
}
