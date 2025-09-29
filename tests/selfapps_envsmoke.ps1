$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
if (-not (Test-Path $nd)) { New-Item -ItemType File -Path $nd -Force | Out-Null }

# Emit a tiny app that imports a small conda-forge package and prints a token
$app = Join-Path $here '~envsmoke'
New-Item -ItemType Directory -Force -Path $app | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $app -Force
Set-Content -LiteralPath (Join-Path $app 'app.py') -Value @'
import colorama
print("smoke-ok")
'@ -NoNewline

Push-Location -LiteralPath $app
try {
    # FULL bootstrap here: do NOT set HP_CI_SKIP_ENV
    cmd /c .\run_setup.bat *> '~envsmoke_bootstrap.log'
    $exit = $LASTEXITCODE
} finally {
    Pop-Location
}

$log = if (Test-Path (Join-Path $app '~envsmoke_bootstrap.log')) {
    Get-Content -LiteralPath (Join-Path $app '~envsmoke_bootstrap.log') -Raw
} else { '' }

# Record two rows: env setup + app run
Add-Content -LiteralPath $nd -Value (@{
    id='env.smoke.conda'
    pass=($exit -eq 0)
    desc='Miniconda bootstrap + environment creation'
    details=@{ exitCode=$exit }
} | ConvertTo-Json -Compress)

$passRun = ($exit -eq 0) -and ($log -match 'smoke-ok')
Add-Content -LiteralPath $nd -Value (@{
    id='env.smoke.run'
    pass=$passRun
    desc='App runs in created environment'
    details=@{ exitCode=$exit }
} | ConvertTo-Json -Compress)
