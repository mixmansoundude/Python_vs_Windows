# ASCII only
# selfapps_ux_hardening.ps1 - UX Hardening tests: REQ-015 (git config), REQ-016 (postflight), REQ-013 (connectivity), REQ-014 (system gate).
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
    foreach ($id in @('self.ux.connectivity.offline.n', 'self.ux.connectivity.prompt.shown', 'self.ux.connectivity.offline.uv.skip', 'self.ux.connectivity.offline.conda.skip')) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-013'
            pass    = $true
            desc    = 'Connectivity guard test skipped on non-Windows host'
            details = $skipDetails
        })
    }
    foreach ($id in @('self.ux.system.gate.n', 'self.ux.system.gate.prompt', 'self.ux.system.gate.real')) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-014'
            pass    = $true
            desc    = 'System Python consent gate test skipped on non-Windows host'
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
$env:HP_TEST_FORCE_CONNECTIVITY_CHECK = '1'
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
$env:HP_TEST_FORCE_CONNECTIVITY_CHECK = ''

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

$uvOfflineLog    = $connText -match [regex]::Escape('[INFO] REQ-013: Offline mode: skipping uv download.')
$condaOfflineLog = $connText -match [regex]::Escape('[INFO] REQ-013: Offline mode: skipping Miniconda download.')
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.offline.uv.skip'
    req     = 'REQ-013'
    pass    = $uvOfflineLog
    desc    = 'Connectivity guard: offline mode skips uv download'
    details = [ordered]@{ logFound = $uvOfflineLog }
})
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.offline.conda.skip'
    req     = 'REQ-013'
    pass    = $condaOfflineLog
    desc    = 'Connectivity guard: offline mode skips Miniconda download'
    details = [ordered]@{ logFound = $condaOfflineLog }
})

# ===== REQ-014: System Python Consent Gate =====
$sysGateDir = Join-Path $here '~selftest_sysgate'
New-Item -ItemType Directory -Force -Path $sysGateDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $sysGateDir -Force
Set-Content -LiteralPath (Join-Path $sysGateDir 'app.py') -Value 'print("hello")' -Encoding Ascii

# Trigger consent gate directly via HP_TEST_FORCE_CONSENT_CHECK=1; pipe n to decline.
# Direct trigger avoids dependency on HP_FORCE_CONDA_ONLY blocking the fallback chain.
$savedLane2 = $env:HP_CI_LANE
$env:HP_CI_LANE = 'test'
$env:HP_TEST_FORCE_CONSENT_CHECK = '1'
$sysLog = Join-Path $sysGateDir '~sys_test.log'
$sysResp = Join-Path $sysGateDir '~resp.txt'
Set-Content -LiteralPath $sysResp -Value "n`r`n" -Encoding Ascii
Push-Location -LiteralPath $sysGateDir
try {
    cmd /c "run_setup.bat < ~resp.txt > ~sys_test.log 2>&1"
} finally {
    Pop-Location
}
$env:HP_CI_LANE = $savedLane2
$env:HP_TEST_FORCE_CONSENT_CHECK = ''

$sysText = ''
if (Test-Path -LiteralPath $sysLog) {
    $sysText = Get-Content -LiteralPath $sysLog -Raw -Encoding Ascii
}
$sysPromptStr = 'Proceed with System Python? (Global pollution risk) [y/n]: '
$sysPromptFound = $sysText -match [regex]::Escape($sysPromptStr)
$sysDeclineLog = $sysText -match [regex]::Escape('[INFO] REQ-014: System Python consent: user declined.')

Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.system.gate.n'
    req     = 'REQ-014'
    pass    = ($sysPromptFound -and $sysDeclineLog)
    desc    = 'System Python consent gate: N response declines'
    details = [ordered]@{ promptFound = $sysPromptFound; declineLogFound = $sysDeclineLog }
})
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.system.gate.prompt'
    req     = 'REQ-014'
    pass    = $sysPromptFound
    desc    = 'System Python consent gate: exact prompt string appears in output'
    details = [ordered]@{ promptFound = $sysPromptFound }
})

# ===== REQ-014: Real system fallback consent gate (behavioral path) =====
# Drives the full fallback chain naturally: conda-fail -> venv-fail -> :try_system_fallback -> consent gate.
# Skipped in conda-full lane where HP_FORCE_CONDA_ONLY=1 blocks system fallback unconditionally.
$sysRealDir = Join-Path $here '~selftest_sysgate_real'
New-Item -ItemType Directory -Force -Path $sysRealDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $sysRealDir -Force
Set-Content -LiteralPath (Join-Path $sysRealDir 'app.py') -Value 'print("hello")' -Encoding Ascii

$sysRealPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.system.gate.real'
        req     = 'REQ-014'
        pass    = $true
        desc    = 'Real system fallback consent path test'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-blocks-system-fallback' }
    })
} else {
    $savedOfflineMode  = $env:HP_OFFLINE_MODE
    $savedCondaFail    = $env:HP_TEST_FORCE_CONDA_FAIL
    $savedVenvFail     = $env:HP_TEST_FORCE_VENV_FAIL
    $savedVenvAllow    = $env:HP_ALLOW_VENV_FALLBACK
    $savedSysAllow     = $env:HP_ALLOW_SYSTEM_FALLBACK
    $savedLane3        = $env:HP_CI_LANE
    $env:HP_OFFLINE_MODE            = '1'
    $env:HP_TEST_FORCE_CONDA_FAIL   = '1'
    $env:HP_TEST_FORCE_VENV_FAIL    = '1'
    $env:HP_ALLOW_VENV_FALLBACK     = '1'
    $env:HP_ALLOW_SYSTEM_FALLBACK   = '1'
    $env:HP_CI_LANE                 = 'test'
    $sysRealLog  = Join-Path $sysRealDir '~sys_real_test.log'
    $sysRealResp = Join-Path $sysRealDir '~resp.txt'
    Set-Content -LiteralPath $sysRealResp -Value "n`r`n" -Encoding Ascii
    Push-Location -LiteralPath $sysRealDir
    try {
        cmd /c "run_setup.bat < ~resp.txt > ~sys_real_test.log 2>&1"
    } finally {
        Pop-Location
    }
    $env:HP_OFFLINE_MODE            = $savedOfflineMode
    $env:HP_TEST_FORCE_CONDA_FAIL   = $savedCondaFail
    $env:HP_TEST_FORCE_VENV_FAIL    = $savedVenvFail
    $env:HP_ALLOW_VENV_FALLBACK     = $savedVenvAllow
    $env:HP_ALLOW_SYSTEM_FALLBACK   = $savedSysAllow
    $env:HP_CI_LANE                 = $savedLane3

    $sysRealText = ''
    if (Test-Path -LiteralPath $sysRealLog) {
        $sysRealText = Get-Content -LiteralPath $sysRealLog -Raw -Encoding Ascii
    }
    $sysRealPromptFound = $sysRealText -match [regex]::Escape($sysPromptStr)
    $sysRealDeclineLog  = $sysRealText -match [regex]::Escape('[INFO] REQ-014: System Python consent: user declined.')
    $sysRealPass = ($sysRealPromptFound -and $sysRealDeclineLog)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.system.gate.real'
        req     = 'REQ-014'
        pass    = $sysRealPass
        desc    = 'System Python consent gate: real fallback chain reaches consent gate'
        details = [ordered]@{ promptFound = $sysRealPromptFound; declineLogFound = $sysRealDeclineLog }
    })
}

$allPass = $giMerged -and $giPreserved -and $giIdem -and ($gaMerged -and $gaBatCrlf) -and $gaIdem -and $pfFound -and ($connPromptFound -and $connOfflineLog) -and $connPromptFound -and $uvOfflineLog -and $condaOfflineLog -and ($sysPromptFound -and $sysDeclineLog) -and $sysPromptFound -and $sysRealPass
if (-not $allPass) { exit 1 }
exit 0
