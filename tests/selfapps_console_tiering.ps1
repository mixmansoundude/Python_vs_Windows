# CLAUDE.md Active Backlog Item 42 (lever 1): proves the :log console-tiering mechanism actually
# behaves at runtime, not just that the code exists. [DEBUG]/[TRACE]/[INSTALL]-tagged lines are
# now suppressed from the LIVE console by default (full detail always still lands in ~setup.log,
# unaffected by tiering) and restorable via the new HP_VERBOSE_CONSOLE=1 opt-in flag.
#
# Two scenarios via CONSOLE_TIER_SCENARIO env var: "default" (no flag) asserts all three tags are
# ABSENT from the console capture but PRESENT in ~setup.log; "verbose" (HP_VERBOSE_CONSOLE=1)
# asserts all three are present in BOTH.
#
# Forces HP_FORCE_CONDA_ONLY=1 -- conda is the only provider with a real [INSTALL]-tagged call
# site ("[INSTALL] conda bulk from ~reqs_conda.txt" / "pip gap fill from requirements.txt");
# uv/venv/embed's own dependency-install branches carry no [INSTALL] tag at all (see
# docs/agent-interconnect.md's uv-First Provider Architecture section for the per-provider
# dependency-install dispatch). A trivial `six` requirement keeps the real conda solve/install
# fast. HP_SKIP_PIPREQS is deliberately left UNSET so pipreqs runs normally and fires its own
# [DEBUG] line. Self-contained (own HP_FORCE_CONDA_ONLY=1 override, matching
# selfapps_pipgap.ps1's pattern) -- wired into the uv lane (non-gating), placed after
# selfapps_cascade.ps1/selfapps_cascade_conda_create_fail.ps1 so Miniconda is already
# installed/cached from those steps rather than triggering a second fresh download.
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Path $here -Parent
$nd   = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$ciNd = Join-Path -Path $repoRoot -ChildPath 'ci_test_results.ndjson'
if (-not (Test-Path -LiteralPath $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

$script:AnyRowFailed = $false
function Write-NdjsonRow {
    param([hashtable]$Row)
    if ($Row.ContainsKey('pass') -and -not $Row['pass']) { $script:AnyRowFailed = $true }
    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

if (-not $IsWindows) {
    Write-NdjsonRow ([ordered]@{
        id = 'self.console.tiering'; pass = $true
        desc = 'console tiering skipped on non-Windows host'
        details = [ordered]@{ skip = $true; reason = 'non-windows-host' }
    })
    exit 0
}

$scenario = $env:CONSOLE_TIER_SCENARIO
if (-not $scenario) { $scenario = 'default' }

$work    = Join-Path -Path $here -ChildPath "~selftest_console_tier_$scenario"
$logName = "~console_tier_${scenario}_bootstrap.log"
$logPath = Join-Path -Path $work -ChildPath $logName
$setupLogPath = Join-Path -Path $work -ChildPath '~setup.log'

if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $work -Force
Set-Content -LiteralPath (Join-Path -Path $work -ChildPath 'main.py') -Value 'import six; print("console-tier-ok")' -Encoding Ascii
Set-Content -LiteralPath (Join-Path -Path $work -ChildPath 'requirements.txt') -Value 'six' -Encoding Ascii -NoNewline

$exitCode = $null
$errorMessage = $null
$savedForceConda = $env:HP_FORCE_CONDA_ONLY
$savedVerbose = $env:HP_VERBOSE_CONSOLE
$env:HP_FORCE_CONDA_ONLY = '1'
if ($scenario -eq 'verbose') { $env:HP_VERBOSE_CONSOLE = '1' } else { $env:HP_VERBOSE_CONSOLE = $null }
try {
    Push-Location -LiteralPath $work
    try {
        cmd /c .\run_setup.bat *> $logName
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }
} catch {
    $errorMessage = $_.Exception.Message
} finally {
    $env:HP_FORCE_CONDA_ONLY = $savedForceConda
    $env:HP_VERBOSE_CONSOLE = $savedVerbose
}

$consoleLog = if (Test-Path -LiteralPath $logPath) { Get-Content -LiteralPath $logPath -Raw -Encoding Ascii } else { '' }
$setupLog   = if (Test-Path -LiteralPath $setupLogPath) { Get-Content -LiteralPath $setupLogPath -Raw -Encoding Ascii } else { '' }

$tags = @('[DEBUG]', '[TRACE]', '[INSTALL]')
$consoleHas = [ordered]@{}
$setupHas   = [ordered]@{}
foreach ($t in $tags) {
    $consoleHas[$t] = [bool]($consoleLog -match [regex]::Escape($t))
    $setupHas[$t]   = [bool]($setupLog -match [regex]::Escape($t))
}

# ~setup.log must ALWAYS carry all three tags regardless of scenario -- console tiering only
# ever changes what's echoed live, never what :log writes to LOG.
$setupAlwaysComplete = -not ($setupHas.Values -contains $false)

if ($scenario -eq 'verbose') {
    $consoleCorrect = -not ($consoleHas.Values -contains $false)
    $desc = 'HP_VERBOSE_CONSOLE=1 restores [DEBUG]/[TRACE]/[INSTALL] to the live console'
} else {
    $consoleCorrect = -not ($consoleHas.Values -contains $true)
    $desc = 'default run suppresses [DEBUG]/[TRACE]/[INSTALL] from the live console'
}

$pass = ($exitCode -eq 0) -and $consoleCorrect -and $setupAlwaysComplete
Write-NdjsonRow ([ordered]@{
    id = 'self.console.tiering'; pass = $pass; desc = $desc
    details = [ordered]@{
        scenario  = $scenario
        exitCode  = $exitCode
        consoleHas = $consoleHas
        setupHas   = $setupHas
        error      = $errorMessage
    }
})

if (-not $pass) {
    Write-Host "[console_tiering:$scenario] FAIL -- exitCode=$exitCode consoleHas=$($consoleHas | ConvertTo-Json -Compress) setupHas=$($setupHas | ConvertTo-Json -Compress)"
}

if ($script:AnyRowFailed) { exit 1 }
exit 0
