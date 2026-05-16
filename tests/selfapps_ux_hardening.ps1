# ASCII only
# selfapps_ux_hardening.ps1 - UX Hardening tests: REQ-015 (git config), REQ-016 (postflight), REQ-013 (connectivity).
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
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

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    $skipDetails = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    foreach ($id in @(
        'self.ux.gitignore.merge',
        'self.ux.gitignore.preserve',
        'self.ux.gitignore.idem',
        'self.ux.gitattributes.merge',
        'self.ux.gitattributes.idem'
    )) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-015'
            pass    = $true
            desc    = 'UX hardening git config test skipped on non-Windows host'
            details = $skipDetails
        })
    }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.postflight'
        req     = 'REQ-016'
        pass    = $true
        desc    = 'Post-flight briefing test skipped on non-Windows host'
        details = $skipDetails
    })
    foreach ($id in @('self.ux.connectivity.offline.n', 'self.ux.connectivity.prompt.shown')) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-013'
            pass    = $true
            desc    = 'Connectivity guard test skipped on non-Windows host'
            details = $skipDetails
        })
    }
    exit 0
}

# ===== REQ-015: Idempotent Git Config Merge =====
$gitconfigDir = Join-Path $here '~selftest_gitconfig'
New-Item -ItemType Directory -Force -Path $gitconfigDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $gitconfigDir -Force

# Create pre-existing .gitignore with user content (no .py files so bootstrap exits fast)
$giPath = Join-Path $gitconfigDir '.gitignore'
$gaPath = Join-Path $gitconfigDir '.gitattributes'
Set-Content -LiteralPath $giPath -Value '/node_modules/' -Encoding Ascii

# Remove any leftover .gitattributes from a prior run
if (Test-Path -LiteralPath $gaPath) { Remove-Item -LiteralPath $gaPath -Force }

# Run 1: bootstrap with no .py files -> exits as no_python_files after merge_git_config runs
Push-Location -LiteralPath $gitconfigDir
try {
    cmd /c 'run_setup.bat > ~gitconfig_run1.log 2>&1'
    $exit1 = $LASTEXITCODE
} finally {
    Pop-Location
}

$sig1  = '# Automated Python Bootstrapper Standard Ignores'
$sigGa = '# Automated Python Bootstrapper Attributes'

$giText = ''
if (Test-Path -LiteralPath $giPath) {
    $giText = Get-Content -LiteralPath $giPath -Raw -Encoding Ascii
}

# Test 1: signature appended to .gitignore
$giMerged = $giText -match [regex]::Escape($sig1)
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitignore.merge'
    req     = 'REQ-015'
    pass    = $giMerged
    desc    = 'Standard ignores signature appended to .gitignore'
    details = [ordered]@{ sigFound = $giMerged; run1Exit = $exit1 }
})

# Test 2: original /node_modules/ content preserved
$giPreserved = $giText -match [regex]::Escape('/node_modules/')
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitignore.preserve'
    req     = 'REQ-015'
    pass    = $giPreserved
    desc    = 'Pre-existing .gitignore content preserved after merge'
    details = [ordered]@{ nodeModulesFound = $giPreserved }
})

# Run 2: idempotency check
Push-Location -LiteralPath $gitconfigDir
try {
    cmd /c 'run_setup.bat > ~gitconfig_run2.log 2>&1'
} finally {
    Pop-Location
}

$giText2 = ''
if (Test-Path -LiteralPath $giPath) {
    $giText2 = Get-Content -LiteralPath $giPath -Raw -Encoding Ascii
}
$sigCount1 = ([regex]::Matches($giText2, [regex]::Escape($sig1))).Count
$giIdem = ($sigCount1 -eq 1)
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitignore.idem'
    req     = 'REQ-015'
    pass    = $giIdem
    desc    = 'Standard ignores signature appears exactly once after two runs'
    details = [ordered]@{ sigCount = $sigCount1 }
})

# Test 4: .gitattributes created with signature and *.bat eol=crlf
$gaText = ''
if (Test-Path -LiteralPath $gaPath) {
    $gaText = Get-Content -LiteralPath $gaPath -Raw -Encoding Ascii
}
$gaMerged   = $gaText -match [regex]::Escape($sigGa)
$gaBatCrlf  = $gaText -match [regex]::Escape('*.bat eol=crlf')
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitattributes.merge'
    req     = 'REQ-015'
    pass    = ($gaMerged -and $gaBatCrlf)
    desc    = 'Standard attributes signature appended to .gitattributes'
    details = [ordered]@{ sigFound = $gaMerged; batCrlfFound = $gaBatCrlf }
})

# Test 5: .gitattributes idempotent (signature once after two runs)
$sigCount2 = ([regex]::Matches($gaText, [regex]::Escape($sigGa))).Count
$gaIdem = ($sigCount2 -eq 1)
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitattributes.idem'
    req     = 'REQ-015'
    pass    = $gaIdem
    desc    = 'Attributes signature appears exactly once after two runs'
    details = [ordered]@{ sigCount = $sigCount2 }
})

# ===== REQ-016: Post-flight briefing =====
$envsmokeDir = Join-Path $here '~envsmoke'
$envsmokeLog = Join-Path $envsmokeDir '~setup.log'
$postflightSig = '[INFO] REQ-016: Post-flight briefing printed.'
$pfFound = $true
if (-not (Test-Path -LiteralPath $envsmokeLog)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.postflight'
        req     = 'REQ-016'
        pass    = $true
        desc    = 'Post-flight briefing log line in envsmoke setup log'
        details = [ordered]@{ skip = $true; reason = 'envsmoke-log-not-found' }
    })
} else {
    $envsmokeText = Get-Content -LiteralPath $envsmokeLog -Raw -Encoding Ascii
    $pfFound = $envsmokeText -match [regex]::Escape($postflightSig)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.postflight'
        req     = 'REQ-016'
        pass    = $pfFound
        desc    = 'Post-flight briefing log line in envsmoke setup log'
        details = [ordered]@{ sigFound = $pfFound }
    })
}

# ===== REQ-013: Internet Connectivity Guard =====
$connDir = Join-Path $here '~selftest_connectivity'
New-Item -ItemType Directory -Force -Path $connDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $connDir -Force
# Create an app.py so bootstrap proceeds past the no_python_files early exit
Set-Content -LiteralPath (Join-Path $connDir 'app.py') -Value 'print("hello")' -Encoding Ascii

# Run with HP_TEST_OFFLINE=1 + forced download failures + HP_CI_LANE=test (suppresses pause)
# Pipe N to stdin to select "proceed offline"
$savedLane = $env:HP_CI_LANE
$env:HP_CI_LANE = 'test'
$env:HP_TEST_OFFLINE = '1'
$env:HP_TEST_CONDA_DL_FALLBACK = '1'
$env:HP_TEST_UV_DL_FALLBACK = '1'
$connLog = Join-Path $connDir '~conn_test.log'
$respFile = Join-Path $connDir '~resp.txt'
Set-Content -LiteralPath $respFile -Value "N`r`n" -Encoding Ascii
Push-Location -LiteralPath $connDir
try {
    cmd /c "run_setup.bat < ~resp.txt > ~conn_test.log 2>&1"
} finally {
    Pop-Location
}
$env:HP_CI_LANE = $savedLane
$env:HP_TEST_OFFLINE = ''
$env:HP_TEST_CONDA_DL_FALLBACK = ''
$env:HP_TEST_UV_DL_FALLBACK = ''

$connText = ''
if (Test-Path -LiteralPath $connLog) {
    $connText = Get-Content -LiteralPath $connLog -Raw -Encoding Ascii
}
$connPromptStr = 'WARNING: No internet connection detected. Remote providers may fail. Retry? (Fix connection then press Y) or proceed offline (N): '
$connPromptFound = $connText -match [regex]::Escape($connPromptStr)
$connOfflineLog = $connText -match [regex]::Escape('[INFO] REQ-013: Connectivity prompt: user chose offline (N).')

Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.offline.n'
    req     = 'REQ-013'
    pass    = ($connPromptFound -and $connOfflineLog)
    desc    = 'Connectivity guard: N response triggers offline mode'
    details = [ordered]@{ promptFound = $connPromptFound; offlineLogFound = $connOfflineLog }
})
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.prompt.shown'
    req     = 'REQ-013'
    pass    = $connPromptFound
    desc    = 'Connectivity guard: exact prompt string appears in output'
    details = [ordered]@{ promptFound = $connPromptFound }
})

$allPass = $giMerged -and $giPreserved -and $giIdem -and ($gaMerged -and $gaBatCrlf) -and $gaIdem -and $pfFound -and ($connPromptFound -and $connOfflineLog) -and $connPromptFound
if (-not $allPass) { exit 1 }
exit 0
