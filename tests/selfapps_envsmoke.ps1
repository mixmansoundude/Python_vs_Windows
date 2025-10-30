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

$bootstrapCmd = 'cmd /c .\run_setup.bat'
$blog   = Join-Path $app '~envsmoke_bootstrap.log'
if (Test-Path -LiteralPath $blog) {
    Remove-Item -LiteralPath $blog -Force
}
Set-Content -LiteralPath $blog -Encoding Ascii -Value ("Bootstrap command: {0}`r`n" -f $bootstrapCmd)

Push-Location -LiteralPath $app
try {
    # FULL bootstrap here: do NOT set HP_CI_SKIP_ENV
    # derived requirement: append the captured command line so syntax regressions remain visible in CI logs.
    cmd /c .\run_setup.bat *>> '~envsmoke_bootstrap.log'
    $exit = $LASTEXITCODE
} finally {
    Pop-Location
}

$runout = Join-Path $app '~run.out.txt'
$setup  = (Test-Path $setupLog) ? (Get-Content -LiteralPath $setupLog -Raw -Encoding Ascii) : ''
$bltxt  = (Test-Path $blog)   ? (Get-Content -LiteralPath $blog   -Raw -Encoding Ascii) : ''
$outxt  = (Test-Path $runout) ? (Get-Content -LiteralPath $runout -Raw -Encoding Ascii) : ''

Check-PipreqsFailure -LogPath $setupLog -LogText $setup

$haveRunOut = Test-Path -LiteralPath $runout
$tokenFound = $haveRunOut -and (($outxt -match 'hello-from-stub') -or ($outxt -match 'smoke-ok'))

# Record two rows: env setup + app run
Write-NdjsonRow ([ordered]@{
    id='self.env.smoke.conda'
    pass=($exit -eq 0)
    desc='Miniconda bootstrap + environment creation'
    details=[ordered]@{ exitCode=$exit; bootstrapCommand=$bootstrapCmd }
})

$passRun = ($exit -eq 0) -and $tokenFound
Write-NdjsonRow ([ordered]@{
    id='self.env.smoke.run'
    pass=$passRun
    desc='App runs in created environment'
    details=[ordered]@{ exitCode=$exit; tokenFound=$tokenFound; haveRunOut=$haveRunOut; bootstrapCommand=$bootstrapCmd }
})

if (($exit -eq 0) -and (-not $tokenFound)) {
    $snippet = Get-LineSnippet -Text $outxt -Pattern 'smoke-ok'
    $details = [ordered]@{ file = $runout; exitCode = $exit; tokenFound = $tokenFound; haveRunOut = $haveRunOut }
    if ($snippet) { $details.snippet = $snippet }
    Write-NdjsonRow ([ordered]@{
        id='envsmoke.run'
        pass=$false
        desc='Environment smoke run missing expected output token after success'
        details=$details
    })
}
