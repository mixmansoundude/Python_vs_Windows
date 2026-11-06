# ASCII only
# selfapps_ux_hardening.ps1 - UX Hardening tests: REQ-015 (git config), REQ-016 (postflight), REQ-013 (connectivity), REQ-014 (system gate).
# Row tags name the README sub-id a row fully proves (REQ-013.n, REQ-014.n, REQ-015.n, REQ-016.n); a row that proves only part of a shall keeps the requirement number.
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

# CLAUDE.md Active Backlog item 3: shared save/set/restore helper for the two REQ-009 Tier 5
# scenarios below (self.embed.fallback.decline / .real), each of which forces a genuinely
# different set of env vars (decline: 6; real: 5 different ones) -- so this takes a hashtable
# rather than a fixed var list. [Environment]::SetEnvironmentVariable($name, $null) both restores
# an unset var to unset AND sets a var to a value uniformly, so no separate "was it null before"
# branch is needed on restore (verified locally via pwsh before relying on it here). Runs the body
# via the call operator inside try/finally so overrides are restored even if the body throws, and
# returns whatever the body scriptblock returns so callers can still capture e.g. an exit code.
function Invoke-WithEnvOverrides {
    param(
        [Parameter(Mandatory)][hashtable]$Overrides,
        [Parameter(Mandatory)][scriptblock]$Body
    )
    $saved = @{}
    foreach ($name in $Overrides.Keys) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, [string]$Overrides[$name])
    }
    try {
        & $Body
    } finally {
        foreach ($name in $saved.Keys) {
            [Environment]::SetEnvironmentVariable($name, $saved[$name])
        }
    }
}

# Non-Windows skip
# derived requirement: $IsWindows is undefined (reads as $null, so "-not $IsWindows" is always
# true) under Windows PowerShell 5.1 -- it was only introduced in PowerShell 6+. Already fixed
# once for this exact reason in tests/selfapps_lineending_check.ps1 (CLAUDE.md Item 44's own CI
# coverage, PR #434); this sibling file had not been updated to match until a CodeRabbit review
# on PR #436 caught it. [System.Environment]::OSVersion.Platform works identically on 5.1 and 7+.
$platform = [System.Environment]::OSVersion.Platform.ToString()
if ($platform -ne 'Win32NT') {
    $skipDetails = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    foreach ($id in @(
        'self.ux.gitignore.merge',
        'self.ux.gitignore.preserve',
        'self.ux.gitignore.idem',
        'self.ux.gitignore.create',
        'self.ux.gitattributes.merge',
        'self.ux.gitattributes.idem',
        'self.ux.gitattributes.append',
        'self.ux.gitattributes.migrate'
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
    foreach ($id in @('self.ux.connectivity.offline.n', 'self.ux.connectivity.prompt.shown', 'self.ux.connectivity.offline.uv.skip', 'self.ux.connectivity.offline.conda.skip', 'self.ux.connectivity.online', 'self.ux.connectivity.retry', 'self.ux.connectivity.override', 'self.ux.connectivity.empty', 'self.ux.connectivity.noinput', 'self.ux.connectivity.nonint')) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-013'
            pass    = $true
            desc    = 'Connectivity guard test skipped on non-Windows host'
            details = $skipDetails
        })
    }
    foreach ($id in @('self.ux.system.gate.n', 'self.ux.system.gate.prompt', 'self.ux.system.gate.real', 'self.ux.system.gate.accept', 'self.ux.system.gate.empty', 'self.ux.system.gate.ci')) {
        Write-NdjsonRow ([ordered]@{
            id      = $id
            req     = 'REQ-014'
            pass    = $true
            desc    = 'System Python consent gate test skipped on non-Windows host'
            details = $skipDetails
        })
    }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.override'
        req     = 'REQ-002'
        pass    = $true
        desc    = 'REQ-002 priority-0 override test skipped on non-Windows host'
        details = $skipDetails
    })
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
# The entries README REQ-015.1 and REQ-015.2 list, each compared as a whole line.
$giEntries = @('.*_env/', '.venv/', '.uv/', '.cache/', '.conda/', 'dist/', 'build/', '*~', '~*')
$gaEntries = @('*.bat -text', '*.cmd -text', '*.exe binary')
function Get-TrimmedLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return ,@() }
    return ,@(Get-Content -LiteralPath $Path -Encoding Ascii | ForEach-Object { $_.TrimEnd() })
}
function Get-MissingEntries {
    param([string[]]$Lines, [string[]]$Entries)
    return ,@($Entries | Where-Object { $Lines -notcontains $_ })
}
function Read-RunLog {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding Ascii) }
    return ''
}
$logGiAppend = 'REQ-015: Appending standard ignores to .gitignore.'
$logGaAppend = 'REQ-015: Appending standard attributes to .gitattributes.'

$giText = ''
if (Test-Path -LiteralPath $giPath) {
    $giText = Get-Content -LiteralPath $giPath -Raw -Encoding Ascii
}

# Test 1: an existing .gitignore gets the signature and every standard entry, and the run says so (REQ-015.1, REQ-015.9)
$giMerged = $giText -match [regex]::Escape($sig1)
$giMissing = Get-MissingEntries -Lines (Get-TrimmedLines $giPath) -Entries $giEntries
$run1Text = Read-RunLog (Join-Path $gitconfigDir '~gitconfig_run1.log')
$giLogged = $run1Text -match [regex]::Escape($logGiAppend)
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitignore.merge'
    req     = 'REQ-015.1, REQ-015.9'
    pass    = ($giMerged -and ($giMissing.Count -eq 0) -and $giLogged)
    desc    = 'Existing .gitignore gets the signature and every standard entry, and the run logs the append'
    details = [ordered]@{ sigFound = $giMerged; missingEntries = $giMissing; logFound = $giLogged; run1Exit = $exit1 }
})

# Test 2: the user's own line is still the first line of the file after the merge (REQ-015.3, with self.ux.gitattributes.append)
$giPreserved = $giText -match [regex]::Escape('/node_modules/')
$giFirstLines = Get-TrimmedLines $giPath
$giFirstKept = ($giFirstLines.Count -ge 1) -and ($giFirstLines[0] -eq '/node_modules/')
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitignore.preserve'
    req     = 'REQ-015.3'
    pass    = ($giPreserved -and $giFirstKept)
    desc    = 'Pre-existing .gitignore content preserved after merge'
    details = [ordered]@{ nodeModulesFound = $giPreserved; firstLineUnchanged = $giFirstKept }
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
$run2Text = Read-RunLog (Join-Path $gitconfigDir '~gitconfig_run2.log')
$run2QuietGi = -not ($run2Text -match [regex]::Escape($logGiAppend))
$giIdem = ($sigCount1 -eq 1)
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitignore.idem'
    req     = 'REQ-015.4, REQ-015.9'
    pass    = ($giIdem -and $run2QuietGi)
    desc    = 'Standard ignores signature appears exactly once after two runs, and the second run logs no append'
    details = [ordered]@{ sigCount = $sigCount1; secondRunQuiet = $run2QuietGi }
})

# Test 4: .gitattributes created with signature and *.bat/*.cmd -text (not eol=crlf).
# derived requirement: docs/agent-lessons-learned.md's ".bat files: -text, not eol=crlf" entry
# -- eol=crlf only affects checkout, never what a raw download serves, so this bootstrapper
# must not teach a user's own project the exact pattern it just proved insufficient for itself.
$gaText = ''
if (Test-Path -LiteralPath $gaPath) {
    $gaText = Get-Content -LiteralPath $gaPath -Raw -Encoding Ascii
}
$gaMerged   = $gaText -match [regex]::Escape($sigGa)
$gaBatText  = $gaText -match [regex]::Escape('*.bat -text')
$gaCmdText  = $gaText -match [regex]::Escape('*.cmd -text')
$gaMissing  = Get-MissingEntries -Lines (Get-TrimmedLines $gaPath) -Entries $gaEntries
$gaLogged   = $run1Text -match [regex]::Escape($logGaAppend)
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitattributes.merge'
    req     = 'REQ-015.2, REQ-015.9'
    pass    = ($gaMerged -and $gaBatText -and $gaCmdText -and ($gaMissing.Count -eq 0) -and $gaLogged)
    desc    = 'A missing .gitattributes is created with the signature and every standard entry, and the run logs the append'
    details = [ordered]@{ sigFound = $gaMerged; batTextFound = $gaBatText; cmdTextFound = $gaCmdText; missingEntries = $gaMissing; logFound = $gaLogged }
})

# Test 5: .gitattributes idempotent (signature once after two runs)
$sigCount2 = ([regex]::Matches($gaText, [regex]::Escape($sigGa))).Count
$run2QuietGa = -not ($run2Text -match [regex]::Escape($logGaAppend))
$gaIdem = ($sigCount2 -eq 1)
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitattributes.idem'
    req     = 'REQ-015.4, REQ-015.9'
    pass    = ($gaIdem -and $run2QuietGa)
    desc    = 'Attributes signature appears exactly once after two runs, and the second run logs no append'
    details = [ordered]@{ sigCount = $sigCount2; secondRunQuiet = $run2QuietGa }
})

# Fresh folder, the other way round: NO .gitignore, and a .gitattributes that already holds the user's own lines.
# REQ-015.1 (a missing .gitignore is created), REQ-015.2 and REQ-015.3 (the entries are added after the user's lines,
# which stay as they were, line for line at the top of the file).
$freshDir = Join-Path $here '~selftest_gitconfig_fresh'
if (Test-Path -LiteralPath $freshDir) { Remove-Item -LiteralPath $freshDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $freshDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $freshDir -Force
$freshGiPath = Join-Path $freshDir '.gitignore'
$freshGaPath = Join-Path $freshDir '.gitattributes'
$userGaLines = @('# my own attributes', '*.md text')
Set-Content -LiteralPath $freshGaPath -Value $userGaLines -Encoding Ascii
Push-Location -LiteralPath $freshDir
try {
    cmd /c 'run_setup.bat > ~gitconfig_fresh.log 2>&1'
} finally {
    Pop-Location
}
$freshGiLines = Get-TrimmedLines $freshGiPath
$freshGaLines = Get-TrimmedLines $freshGaPath
$freshGiMissing = Get-MissingEntries -Lines $freshGiLines -Entries $giEntries
$freshGaMissing = Get-MissingEntries -Lines $freshGaLines -Entries $gaEntries
$freshGiSig = $freshGiLines -contains $sig1
$freshGaSig = $freshGaLines -contains $sigGa
$freshUserKept = ($freshGaLines.Count -ge 2) -and ($freshGaLines[0] -eq $userGaLines[0]) -and ($freshGaLines[1] -eq $userGaLines[1])
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitignore.create'
    req     = 'REQ-015.1'
    pass    = ((Test-Path -LiteralPath $freshGiPath) -and $freshGiSig -and ($freshGiMissing.Count -eq 0))
    desc    = 'A missing .gitignore is created with the signature and every standard entry'
    details = [ordered]@{ exists = (Test-Path -LiteralPath $freshGiPath); sigFound = $freshGiSig; missingEntries = $freshGiMissing }
})
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitattributes.append'
    req     = 'REQ-015.2, REQ-015.3'
    pass    = ($freshGaSig -and ($freshGaMissing.Count -eq 0) -and $freshUserKept)
    desc    = 'An existing .gitattributes keeps its own first lines and gets the signature and every standard entry after them'
    details = [ordered]@{ sigFound = $freshGaSig; missingEntries = $freshGaMissing; userLinesKeptAtTop = $freshUserKept; firstLines = @($freshGaLines | Select-Object -First 3) }
})

# Test 6 (CLAUDE.md Item 60): migrate a PRE-EXISTING .gitattributes already carrying the
# disproven "*.bat eol=crlf"/"*.cmd eol=crlf" rule -- and the shared HP_GA_SIG signature, so
# the idempotency guard would otherwise skip the whole append block and never touch it -- to
# "-text". Separate scratch dir from Tests 4/5 above, since those start with NO .gitattributes
# at all; this one specifically seeds content matching what an OLDER copy of this bootstrapper
# would have already written, simulating a user re-running a newer copy.
$migrateDir = Join-Path $here '~selftest_gitconfig_migrate'
New-Item -ItemType Directory -Force -Path $migrateDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $migrateDir -Force
$migrateGaPath = Join-Path $migrateDir '.gitattributes'
Set-Content -LiteralPath $migrateGaPath -Encoding Ascii -Value @(
    '# some user content'
    '*.md text'
    $sigGa
    '*.bat eol=crlf'
    '*.cmd eol=crlf'
    '*.exe binary'
)

Push-Location -LiteralPath $migrateDir
try {
    cmd /c 'run_setup.bat > ~gitconfig_migrate.log 2>&1'
} finally {
    Pop-Location
}

$migrateGaText = ''
if (Test-Path -LiteralPath $migrateGaPath) {
    $migrateGaText = Get-Content -LiteralPath $migrateGaPath -Raw -Encoding Ascii
}
$migrateBatText   = $migrateGaText -match [regex]::Escape('*.bat -text')
$migrateCmdText   = $migrateGaText -match [regex]::Escape('*.cmd -text')
$migrateBatStale  = $migrateGaText -match [regex]::Escape('*.bat eol=crlf')
$migrateCmdStale  = $migrateGaText -match [regex]::Escape('*.cmd eol=crlf')
$migratePreserved = $migrateGaText -match [regex]::Escape('# some user content')
$migrateLines = Get-TrimmedLines $migrateGaPath
$migrateOtherKept = ($migrateLines -contains '*.md text') -and ($migrateLines -contains '*.exe binary') -and ($migrateLines -contains $sigGa)
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.gitattributes.migrate'
    req     = 'REQ-015.5'
    pass    = ($migrateBatText -and $migrateCmdText -and -not $migrateBatStale -and -not $migrateCmdStale -and $migratePreserved -and $migrateOtherKept)
    desc    = 'Pre-existing eol=crlf rule migrated to -text; other content untouched'
    details = [ordered]@{
        batTextFound   = $migrateBatText
        cmdTextFound   = $migrateCmdText
        batStaleFound  = $migrateBatStale
        cmdStaleFound  = $migrateCmdStale
        otherPreserved = $migratePreserved
        otherLinesKept = $migrateOtherKept
    }
})

# ===== REQ-016: Post-flight briefing =====
$envsmokeDir = Join-Path $here '~envsmoke'
$envsmokeLog = Join-Path $envsmokeDir '~setup.log'
$postflightSig = 'REQ-016: Post-flight briefing printed'
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
    $pfLogLine = $envsmokeText -match [regex]::Escape($postflightSig)
    # REQ-016 requires the panel to identify the output EXE, files to keep, and files safe to
    # delete -- not merely that a "printed" log line fired. The panel is echoed to stdout
    # (captured in ~envsmoke_bootstrap.log), not ~setup.log, so verify its content there.
    $pfDetails = [ordered]@{ logLineFound = $pfLogLine }
    $pfContent = $true
    $envsmokeBootLog = Join-Path $envsmokeDir '~envsmoke_bootstrap.log'
    if (Test-Path -LiteralPath $envsmokeBootLog) {
        $bootText = Get-Content -LiteralPath $envsmokeBootLog -Raw -Encoding Ascii
        # Accept either the normal-path header or the caveat-path header; both confirm the panel printed.
        $pfNormalExe  = $bootText -match [regex]::Escape('Your standalone application is ready:')
        $pfCaveatHead = $bootText -match [regex]::Escape('SETUP COMPLETE -- WITH A CAVEAT')
        $pfExe = ($pfNormalExe -or $pfCaveatHead)
        $pfKeep     = $bootText -match [regex]::Escape('KEEP these files')
        $pfDelete   = $bootText -match [regex]::Escape('SAFE TO DELETE')
        # REQ-016 also requires a RUNNING YOUR APP section with two specific beginner-confusion items:
        # (1) console-window flash advice (open Command Prompt to keep it open)
        # (2) stdout buffering difference note -- "buffering difference" is on one echo line;
        #     "stdout" ends the preceding line so we match the single-line phrase here.
        $pfRunApp    = $bootText -match [regex]::Escape('RUNNING YOUR APP')
        # "Command Prompt" is the REQ-016-mandated term for Windows beginners; rephrase only with a req update.
        $pfCmdPrompt = $bootText -match [regex]::Escape('Command Prompt')
        $pfStdBuf    = $bootText -match [regex]::Escape('buffering difference')
        # REQ-016.2 and REQ-016.4 name a sentence each, not a word: the flash advice and its "keeps the window open"
        # result, and the slow-start heading.
        $pfFlash     = $bootText -match [regex]::Escape('If the window flashes and closes instantly')
        $pfKeepOpen  = $bootText -match [regex]::Escape('This keeps the window open')
        $pfSlow      = $bootText -match [regex]::Escape('STARTUP MAY BE SLOW')
        $pfContent = ($pfExe -and $pfKeep -and $pfDelete -and $pfRunApp -and $pfCmdPrompt -and $pfStdBuf -and $pfFlash -and $pfKeepOpen -and $pfSlow)
        $pfDetails.exeSectionFound     = $pfExe
        $pfDetails.keepSectionFound    = $pfKeep
        $pfDetails.deleteSectionFound  = $pfDelete
        $pfDetails.runAppSectionFound  = $pfRunApp
        $pfDetails.cmdPromptFound      = $pfCmdPrompt
        $pfDetails.stdBufferingFound   = $pfStdBuf
        $pfDetails.flashAdviceFound    = $pfFlash
        $pfDetails.keepsOpenFound      = $pfKeepOpen
        $pfDetails.slowStartFound      = $pfSlow
    } else {
        # Defensive: never false-fail if the stdout capture is absent; fall back to the log line.
        $pfDetails.bootLogMissing = $true
    }
    $pfFound = ($pfLogLine -and $pfContent)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.postflight'
        req     = 'REQ-016.1, REQ-016.2, REQ-016.3, REQ-016.4'
        pass    = $pfFound
        desc    = 'Post-flight briefing: log line plus panel (EXE + keep + delete + RUNNING YOUR APP + Command Prompt + stdout buffering)'
        details = $pfDetails
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
# derived requirement: CLAUDE.md Item 50 changed this prompt from a set /p prompt string (which
# carried a trailing ": ") to an unconditional echo line (no trailing space) so the prompt text
# is visible even on the new NOINPUT/HP_NONINTERACTIVE auto-decline paths -- match without the
# trailing space accordingly.
$connPromptStr = 'WARNING: No internet connection detected. Remote providers may fail. Retry? (Fix connection then press Y) or proceed offline (N):'
$connPromptFound = $connText -match [regex]::Escape($connPromptStr)
$connOfflineLog = $connText -match [regex]::Escape('[INFO] REQ-013: Connectivity prompt: user chose offline (N).')

Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.offline.n'
    req     = 'REQ-013.4, REQ-013.6'
    pass    = ($connPromptFound -and $connOfflineLog)
    desc    = 'Connectivity guard: N response triggers offline mode'
    details = [ordered]@{ promptFound = $connPromptFound; offlineLogFound = $connOfflineLog }
})
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.prompt.shown'
    req     = 'REQ-013.4'
    pass    = $connPromptFound
    desc    = 'Connectivity guard: exact prompt string appears in output'
    details = [ordered]@{ promptFound = $connPromptFound }
})

$uvOfflineLog    = $connText -match [regex]::Escape('[INFO] REQ-013: Offline mode: skipping uv download.')
$condaOfflineLog = $connText -match [regex]::Escape('[INFO] REQ-013: Offline mode: skipping Miniconda download.')

# uv offline skip: the log fires only when uv would be downloaded. In the conda-full lane,
# HP_FORCE_CONDA_ONLY=1 (inherited by the sub-invocation) exits the uv section before the
# offline check -- that is the correct alternative path, not a coverage gap.
# In the justme-test lane, HP_TEST_FORCE_UV_FAIL=1 is inherited and exits the uv section
# before the offline check -- also a legitimate bypass, not a coverage gap.
$uvCondaOnlySkip  = $connText -match [regex]::Escape('[INFO] uv: skipped (HP_FORCE_CONDA_ONLY=1).')
$uvForcedFailSkip = $connText -match [regex]::Escape('[WARN] uv: HP_TEST_FORCE_UV_FAIL: simulating uv acquisition failure.')
$uvOfflinePass    = $uvOfflineLog -or $uvCondaOnlySkip -or $uvForcedFailSkip
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.offline.uv.skip'
    req     = 'REQ-013.9'
    pass    = $uvOfflinePass
    desc    = 'Connectivity guard: offline mode skips uv download (or uv legitimately bypassed)'
    details = [ordered]@{ offlineLogFound = $uvOfflineLog; condaOnlySkip = $uvCondaOnlySkip; forcedFailSkip = $uvForcedFailSkip }
})

# conda offline skip: :download_miniconda_exe is only called when conda.bat is missing.
# In all CI lanes the main bootstrap already installed Miniconda before selfapps tests run,
# so the download subroutine is never reached and the offline skip cannot fire.
# Pass if: offline skip log appeared, OR no Miniconda download was attempted (pre-installed).
$condaDownloadAttempted = $connText -match [regex]::Escape('[INFO] Downloading Miniconda from ')
$condaOfflinePass = $condaOfflineLog -or (-not $condaDownloadAttempted)
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.offline.conda.skip'
    req     = 'REQ-013'
    pass    = $condaOfflinePass
    desc    = 'Connectivity guard: offline mode skips Miniconda download (or pre-installed)'
    details = [ordered]@{ offlineLogFound = $condaOfflineLog; downloadAttempted = $condaDownloadAttempted }
})

# ===== REQ-013: Connectivity guard ONLINE (reachable) cascade path =====
# Covers the "internet reachable" branch of :check_net_after_dl_fail -- the common
# real-world case where a primary download fails but internet is up, so the bootstrapper
# cascades to the fallback URL. This branch is otherwise untested: the dl-fallback lane
# skips the connectivity check (HP_TEST_CONDA_DL_FALLBACK=1) and the offline test above
# forces ping failure (HP_TEST_OFFLINE=1). Here we trigger the check directly with
# HP_TEST_FORCE_CONNECTIVITY_CHECK=1 and NO HP_TEST_OFFLINE, so the runner's live network
# drives either the ICMP or HTTPS reachable path. No app.py is staged, so the bootstrap
# exits early at no_python_files after the check fires -- keeping the test cheap.
$connOnlineDir = Join-Path $here '~selftest_connectivity_online'
New-Item -ItemType Directory -Force -Path $connOnlineDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $connOnlineDir -Force

$savedLaneOn    = $env:HP_CI_LANE
$savedOfflineOn = $env:HP_TEST_OFFLINE
$env:HP_CI_LANE = 'test'
$env:HP_TEST_OFFLINE = ''
$env:HP_TEST_FORCE_CONNECTIVITY_CHECK = '1'
$connOnlineLog = Join-Path $connOnlineDir '~conn_online_test.log'
$connOnlineResp = Join-Path $connOnlineDir '~resp.txt'
# Defensive stdin: if both ICMP and HTTPS unexpectedly fail, this answers the offline
# prompt with N so the test fails fast (branch did not fire) instead of hanging.
Set-Content -LiteralPath $connOnlineResp -Value "N`r`n" -Encoding Ascii
# derived requirement: this row's premise is that the runner itself has internet. The product check already
# retries its ping and its curl once, and a shared runner can still lose its network for longer than that
# (run 41034407669, uv-dl-fallback: "no internet detected (ICMP and HTTPS check failed)" about a second after
# the start, the row red, nothing in this repository changed). Under the aggregate gate that alone holds a PR,
# so when the product's own "no internet detected" line is the reason, wait and run the scenario again, up to
# three runs in all. Any other outcome (no reachable line and no offline line) is not retried: that is a real
# failure. A network that stays down for all three runs stays red, with the attempt count in the row.
$connAttempts = 0
$connReachableFound = $false
$connOnlineText = ''
$connNoInternetSeen = $false
while ($true) {
    $connAttempts++
    Remove-Item -LiteralPath $connOnlineLog -Force -ErrorAction SilentlyContinue
    Push-Location -LiteralPath $connOnlineDir
    try {
        cmd /c "run_setup.bat < ~resp.txt > ~conn_online_test.log 2>&1"
    } finally {
        Pop-Location
    }
    $connOnlineText = ''
    if (Test-Path -LiteralPath $connOnlineLog) {
        $connOnlineText = Get-Content -LiteralPath $connOnlineLog -Raw -Encoding Ascii
    }
    # Match the common substring shared by both reachable lines (ICMP-direct and HTTPS-fallback).
    $connReachableFound = $connOnlineText -match [regex]::Escape('REQ-013: Connectivity check: internet reachable')
    $connNoInternetSeen = $connOnlineText -match [regex]::Escape('REQ-013: Connectivity check: no internet detected')
    if ($connReachableFound -or -not $connNoInternetSeen -or $connAttempts -ge 3) { break }
    Write-Host "[INFO] self.ux.connectivity.online: the runner reported no internet (attempt $connAttempts of 3); waiting 20 seconds and trying again."
    Start-Sleep -Seconds 20
}
$env:HP_CI_LANE = $savedLaneOn
$env:HP_TEST_OFFLINE = $savedOfflineOn
$env:HP_TEST_FORCE_CONNECTIVITY_CHECK = ''

Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.online'
    req     = 'REQ-013.2'
    pass    = $connReachableFound
    desc    = 'Connectivity guard: reachable network cascades to fallback (internet reachable branch)'
    details = [ordered]@{ reachableLogFound = $connReachableFound; attempts = $connAttempts; noInternetSeen = $connNoInternetSeen }
})

# ===== REQ-013: Connectivity guard Y-RETRY re-prompt loop =====
# Covers the "Y retry -> still offline -> re-prompt" branch of :check_net_after_dl_fail.
# The existing offline.n test pipes "N" (explicit decline, first prompt). The retry
# loop-back (set HP_TEST_OFFLINE=1, answer Y, which logs the test-mode "still simulating
# offline" line and jumps back to :cndf_ping_failed to re-prompt) had no coverage. Pipe
# "Y" then "N": Y triggers the retry branch and re-prompts, N then exits offline. Uses the
# same proven character-on-stdin mechanism as offline.n (reliable, unlike empty-input
# simulation where set /p captures a leading CR). No app.py -> cheap no_python_files exit.
$connRetryDir = Join-Path $here '~selftest_connectivity_retry'
New-Item -ItemType Directory -Force -Path $connRetryDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $connRetryDir -Force

$savedLaneRt    = $env:HP_CI_LANE
$savedOfflineRt = $env:HP_TEST_OFFLINE
$env:HP_CI_LANE = 'test'
$env:HP_TEST_OFFLINE = '1'
$env:HP_TEST_FORCE_CONNECTIVITY_CHECK = '1'
$connRetryLog = Join-Path $connRetryDir '~conn_retry_test.log'
$connRetryResp = Join-Path $connRetryDir '~resp.txt'
# Y on the first prompt exercises the retry branch; N on the re-prompt exits offline.
Set-Content -LiteralPath $connRetryResp -Value "Y`r`nN`r`n" -Encoding Ascii
Push-Location -LiteralPath $connRetryDir
try {
    cmd /c "run_setup.bat < ~resp.txt > ~conn_retry_test.log 2>&1"
} finally {
    Pop-Location
}
$env:HP_CI_LANE = $savedLaneRt
$env:HP_TEST_OFFLINE = $savedOfflineRt
$env:HP_TEST_FORCE_CONNECTIVITY_CHECK = ''

$connRetryText = ''
if (Test-Path -LiteralPath $connRetryLog) {
    $connRetryText = Get-Content -LiteralPath $connRetryLog -Raw -Encoding Ascii
}
# Retry branch fired if the test-mode "still simulating offline" line appears, and the
# subsequent N decline confirms the loop re-prompted and then exited offline.
$connRetryFired   = $connRetryText -match [regex]::Escape('[TEST] HP_TEST_OFFLINE: Y selected; still simulating offline.')
$connRetryDecline = $connRetryText -match [regex]::Escape('REQ-013: Connectivity prompt: user chose offline (N).')
$connRetryFound   = $connRetryFired -and $connRetryDecline
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.retry'
    req     = 'REQ-013.5'
    pass    = $connRetryFound
    desc    = 'Connectivity guard: Y answer re-prompts while still offline, then N exits offline'
    details = [ordered]@{ retryBranchFired = $connRetryFired; declineAfterRetry = $connRetryDecline }
})

# ===== REQ-013: Connectivity guard HP_TEST_CNDF_ANSWER override (CLAUDE.md Item 50) =====
# Proves the new deterministic test override (mirroring HP_TEST_SYSCON_ANSWER/HP_TEST_
# CHECKPOINT_ANSWER's established shape) actually drives the prompt's own choice, distinct
# from falling through to set /p and merely defaulting via the pre-existing empty-input path
# (both would independently resolve to offline, so asserting the DECLINE log line alone would
# not distinguish "override worked" from "override silently ignored" -- stdin is closed via
# `< nul` specifically so a broken override would still resolve via empty-input, and the
# assertion below requires the empty-input line to be ABSENT to catch that case).
$connOverrideDir = Join-Path $here '~selftest_connectivity_override'
New-Item -ItemType Directory -Force -Path $connOverrideDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $connOverrideDir -Force

$connOverrideLog = Join-Path $connOverrideDir '~conn_override_test.log'
Invoke-WithEnvOverrides -Overrides @{
    HP_CI_LANE                       = 'test'
    HP_TEST_OFFLINE                  = '1'
    HP_TEST_FORCE_CONNECTIVITY_CHECK = '1'
    HP_TEST_CNDF_ANSWER              = 'N'
} -Body {
    Push-Location -LiteralPath $connOverrideDir
    try {
        cmd /c "run_setup.bat < nul > ~conn_override_test.log 2>&1"
    } finally {
        Pop-Location
    }
} | Out-Null

$connOverrideText = ''
if (Test-Path -LiteralPath $connOverrideLog) {
    $connOverrideText = Get-Content -LiteralPath $connOverrideLog -Raw -Encoding Ascii
}
$connOverridePromptFound = $connOverrideText -match [regex]::Escape($connPromptStr)
$connOverrideDeclineLog  = $connOverrideText -match [regex]::Escape('REQ-013: Connectivity prompt: user chose offline (N).')
$connOverrideEmptyLog    = $connOverrideText -match [regex]::Escape('REQ-013: Connectivity prompt: empty input; defaulting offline.')
$connOverridePass        = ($connOverridePromptFound -and $connOverrideDeclineLog -and (-not $connOverrideEmptyLog))
Write-NdjsonRow ([ordered]@{
    id      = 'self.ux.connectivity.override'
    req     = 'REQ-013.6'
    pass    = $connOverridePass
    desc    = 'Connectivity guard: HP_TEST_CNDF_ANSWER=N resolves via the explicit-decline path, not the empty-input fallback'
    details = [ordered]@{
        promptFound    = $connOverridePromptFound
        declineLogFound = $connOverrideDeclineLog
        emptyLogFound   = $connOverrideEmptyLog
    }
})

# ===== REQ-013.7 / REQ-013.8: the question when no answer is read, and when no answer is asked for =====
# The scenario of self.ux.connectivity.offline.n with no answer on standard input and a forced "no internet" outcome, run
# three ways. Standard input is closed (< nul), as in selfapps_offers_noninteractive.ps1, so a read that does happen gets
# end-of-file at once instead of hanging the job. The branches log DIFFERENT things, which is what tells them apart:
#   empty    no signal: the question reads the keyboard (its "Your choice [y/n]:" prompt is printed), finds nothing and logs
#            "empty input; defaulting offline" (REQ-013.7). HP_CI_LANE is set, as in every other row of this section: the
#            question does not skip the read for it (open question 2), and this row is where that is shown.
#   noinput  NOINPUT set: no read, so the "Your choice" prompt is absent and the log says "user chose offline (N)" (REQ-013.8)
#   nonint   HP_NONINTERACTIVE set: the same
# The wrapper clears the answer hook and the other signal itself, in the launched shell, because a variable the job set is not
# reliably removed from a child by SetEnvironmentVariable (docs/agent-lessons-learned.md). No program is staged, so the run
# ends at no_python_files right after the check.
function Invoke-ConnGateRun {
    param([string]$Name, [string[]]$SetLines)
    $dir = Join-Path $here ('~selftest_connectivity_' + $Name)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $dir -Force
    $wrapperLines = @(
        '@echo off',
        'set "NOINPUT="', 'set "HP_NONINTERACTIVE="', 'set "HP_TEST_CNDF_ANSWER="',
        'set "HP_CI_LANE=test"', 'set "HP_TEST_OFFLINE=1"', 'set "HP_TEST_FORCE_CONNECTIVITY_CHECK=1"'
    ) + $SetLines + @('call run_setup.bat > ~conn_gate_console.log 2>&1 < nul', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $dir '~conn_gate_launch.cmd') -Value $wrapperLines -Encoding Ascii
    $started = Get-Date
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', 'call ~conn_gate_launch.cmd') -WorkingDirectory $dir -NoNewWindow -PassThru
    $finished = $proc.WaitForExit(300000)
    if (-not $finished) {
        & taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null
        $null = $proc.WaitForExit(30000)
    }
    $text = ''
    $consolePath = Join-Path $dir '~conn_gate_console.log'
    if (Test-Path -LiteralPath $consolePath) { $text = Get-Content -LiteralPath $consolePath -Raw -Encoding Ascii }
    return [pscustomobject]@{ Finished = [bool]$finished; Seconds = [int]((Get-Date) - $started).TotalSeconds; Text = $text }
}
$connGateScenarios = @(
    @{ Name = 'empty'; SetLines = @() },
    @{ Name = 'noinput'; SetLines = @('set "NOINPUT=1"') },
    @{ Name = 'nonint'; SetLines = @('set "HP_NONINTERACTIVE=1"') }
)
$connGateRuns = @{}
foreach ($scenario in $connGateScenarios) { $connGateRuns[$scenario.Name] = Invoke-ConnGateRun -Name $scenario.Name -SetLines $scenario.SetLines }
foreach ($scenarioName in @('empty', 'noinput', 'nonint')) {
    $run = $connGateRuns[$scenarioName]
    $asked      = $run.Text -match [regex]::Escape($connPromptStr)
    $readPrompt = $run.Text -match [regex]::Escape('Your choice [y/n]:')
    $emptyLog   = $run.Text -match [regex]::Escape('REQ-013: Connectivity prompt: empty input; defaulting offline.')
    $declineLog = $run.Text -match [regex]::Escape('REQ-013: Connectivity prompt: user chose offline (N).')
    $retryLog   = $run.Text -match [regex]::Escape('REQ-013: Still offline after Y; re-prompting.')
    if ($scenarioName -eq 'empty') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.ux.connectivity.empty'
            req     = 'REQ-013.7'
            pass    = ($run.Finished -and $asked -and $readPrompt -and $emptyLog -and (-not $declineLog) -and (-not $retryLog))
            desc    = 'Connectivity guard: no answer at all (no signal, standard input closed) proceeds offline'
            details = [ordered]@{ finished = $run.Finished; seconds = $run.Seconds; promptFound = $asked; readPromptFound = $readPrompt; emptyInputLog = $emptyLog; declinedLog = $declineLog; retryLog = $retryLog }
        })
    } elseif ($scenarioName -eq 'noinput') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.ux.connectivity.noinput'
            req     = 'REQ-013.8'
            pass    = ($run.Finished -and $asked -and (-not $readPrompt) -and $declineLog -and (-not $emptyLog) -and (-not $retryLog))
            desc    = 'Connectivity guard: with NOINPUT set the question is shown, no answer is read and the run proceeds offline'
            details = [ordered]@{ finished = $run.Finished; seconds = $run.Seconds; promptFound = $asked; readPromptFound = $readPrompt; declinedLog = $declineLog; emptyInputLog = $emptyLog; retryLog = $retryLog }
        })
    } else {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.ux.connectivity.nonint'
            req     = 'REQ-013.8'
            pass    = ($run.Finished -and $asked -and (-not $readPrompt) -and $declineLog -and (-not $emptyLog) -and (-not $retryLog))
            desc    = 'Connectivity guard: with HP_NONINTERACTIVE set the question is shown, no answer is read and the run proceeds offline'
            details = [ordered]@{ finished = $run.Finished; seconds = $run.Seconds; promptFound = $asked; readPromptFound = $readPrompt; declinedLog = $declineLog; emptyInputLog = $emptyLog; retryLog = $retryLog }
        })
    }
}

# ===== REQ-014: System Python Consent Gate =====
$sysGateDir = Join-Path $here '~selftest_sysgate'
New-Item -ItemType Directory -Force -Path $sysGateDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $sysGateDir -Force
Set-Content -LiteralPath (Join-Path $sysGateDir 'app.py') -Value 'print("hello")' -Encoding Ascii

# Trigger consent gate directly via HP_TEST_FORCE_CONSENT_CHECK=1; HP_TEST_SYSCON_ANSWER=N
# deterministically answers the prompt with N (genuine decline branch, no set /p / stdin race).
# Direct trigger avoids dependency on HP_FORCE_CONDA_ONLY blocking the fallback chain.
$savedLane2 = $env:HP_CI_LANE
$savedSyscon2 = $env:HP_TEST_SYSCON_ANSWER
$env:HP_CI_LANE = 'test'
$env:HP_TEST_FORCE_CONSENT_CHECK = '1'
$env:HP_TEST_SYSCON_ANSWER = 'N'
$sysLog = Join-Path $sysGateDir '~sys_test.log'
Push-Location -LiteralPath $sysGateDir
try {
    cmd /c "run_setup.bat > ~sys_test.log 2>&1"
} finally {
    Pop-Location
}
$env:HP_CI_LANE = $savedLane2
$env:HP_TEST_FORCE_CONSENT_CHECK = ''
if ($null -eq $savedSyscon2) { Remove-Item Env:HP_TEST_SYSCON_ANSWER -ErrorAction SilentlyContinue } else { $env:HP_TEST_SYSCON_ANSWER = $savedSyscon2 }

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

# ===== REQ-014: Real system fallback consent gate (behavioral path, DEFAULT no-flag run) =====
# Drives the full fallback chain naturally: conda-fail -> venv-fail -> :try_system_fallback -> consent gate.
# Proves the system tier is reachable WITHOUT HP_ALLOW_SYSTEM_FALLBACK (deprecated as a gate);
# HP_TEST_SYSCON_ANSWER=N declines deterministically and the build is kept.
# Skipped in conda-full lane where HP_FORCE_CONDA_ONLY=1 blocks all non-conda fallbacks.
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
    $savedSyscon3      = $env:HP_TEST_SYSCON_ANSWER
    $savedLane3        = $env:HP_CI_LANE
    $env:HP_OFFLINE_MODE            = '1'
    $env:HP_TEST_FORCE_CONDA_FAIL   = '1'
    $env:HP_TEST_FORCE_VENV_FAIL    = '1'
    $env:HP_TEST_SYSCON_ANSWER      = 'N'
    $env:HP_CI_LANE                 = 'test'
    $sysRealLog  = Join-Path $sysRealDir '~sys_real_test.log'
    Push-Location -LiteralPath $sysRealDir
    try {
        cmd /c "run_setup.bat > ~sys_real_test.log 2>&1"
    } finally {
        Pop-Location
    }
    $env:HP_OFFLINE_MODE            = $savedOfflineMode
    $env:HP_TEST_FORCE_CONDA_FAIL   = $savedCondaFail
    $env:HP_TEST_FORCE_VENV_FAIL    = $savedVenvFail
    $env:HP_CI_LANE                 = $savedLane3
    if ($null -eq $savedSyscon3) { Remove-Item Env:HP_TEST_SYSCON_ANSWER -ErrorAction SilentlyContinue } else { $env:HP_TEST_SYSCON_ANSWER = $savedSyscon3 }

    $sysRealText = ''
    if (Test-Path -LiteralPath $sysRealLog) {
        $sysRealText = Get-Content -LiteralPath $sysRealLog -Raw -Encoding Ascii
    }
    $sysRealPromptFound = $sysRealText -match [regex]::Escape($sysPromptStr)
    $sysRealDeclineLog  = $sysRealText -match [regex]::Escape('[INFO] REQ-014: System Python consent: user declined.')
    $sysRealAbortLog    = $sysRealText -match [regex]::Escape('[INFO] REQ-014: System Python fallback aborted: consent not granted.')
    # REQ-014.3: a decline must leave the system Python unused, not only log that it declined. The provider line is what
    # an accept logs (self.ux.system.gate.accept), and the final state of an accept is degraded_env.
    $sysRealSelected = $sysRealText -match [regex]::Escape('Selected Python provider: System Python')
    $sysRealState = $null
    $sysRealStatePath = Join-Path $sysRealDir '~bootstrap.status.json'
    if (Test-Path -LiteralPath $sysRealStatePath) {
        try { $sysRealState = [string]((Get-Content -LiteralPath $sysRealStatePath -Raw -Encoding Ascii | ConvertFrom-Json).state) } catch { $sysRealState = 'unparseable' }
    }
    $sysRealPass = ($sysRealPromptFound -and $sysRealDeclineLog -and $sysRealAbortLog -and (-not $sysRealSelected) -and ($sysRealState -ne 'degraded_env'))
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.system.gate.real'
        req     = 'REQ-014.3, REQ-014.5'
        pass    = $sysRealPass
        desc    = 'System Python consent gate: default (no-flag) fallback chain reaches consent gate; decline leaves the system Python unused'
        details = [ordered]@{ promptFound = $sysRealPromptFound; declineLogFound = $sysRealDeclineLog; abortLogFound = $sysRealAbortLog; systemSelected = $sysRealSelected; state = $sysRealState }
    })
}

# ===== REQ-014/REQ-009: System Python ACCEPT path enters Tier 4 (provider independence) =====
# The previously-missing end-to-end proof: in a DEFAULT (no-flag) run with uv/conda/venv all
# forced to fail, accepting the REQ-014 consent prompt (HP_TEST_SYSCON_ANSWER=Y) routes into the
# REQ-009 Tier 4 system provider and the bootstrapper proceeds under system Python ("system
# Python alone"). No HP_ALLOW_SYSTEM_FALLBACK is set -- the consent prompt is the only gate.
# Skipped in conda-full lane (HP_FORCE_CONDA_ONLY=1 suppresses non-conda tiers).
$sysAcceptDir = Join-Path $here '~selftest_sysgate_accept'
New-Item -ItemType Directory -Force -Path $sysAcceptDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $sysAcceptDir -Force
Set-Content -LiteralPath (Join-Path $sysAcceptDir 'app.py') -Value 'print("hello from system python")' -Encoding Ascii

$sysAcceptPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.system.gate.accept'
        req     = 'REQ-014'
        pass    = $true
        desc    = 'System Python accept path test'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-blocks-system-fallback' }
    })
} else {
    $savedOfflineModeA = $env:HP_OFFLINE_MODE
    $savedCondaFailA   = $env:HP_TEST_FORCE_CONDA_FAIL
    $savedVenvFailA    = $env:HP_TEST_FORCE_VENV_FAIL
    $savedSysconA      = $env:HP_TEST_SYSCON_ANSWER
    $savedLaneA        = $env:HP_CI_LANE
    $env:HP_OFFLINE_MODE          = '1'
    $env:HP_TEST_FORCE_CONDA_FAIL = '1'
    $env:HP_TEST_FORCE_VENV_FAIL  = '1'
    $env:HP_TEST_SYSCON_ANSWER    = 'Y'
    $env:HP_CI_LANE               = 'test'
    $sysAcceptLog = Join-Path $sysAcceptDir '~sys_accept_test.log'
    Push-Location -LiteralPath $sysAcceptDir
    try {
        cmd /c "run_setup.bat > ~sys_accept_test.log 2>&1"
    } finally {
        Pop-Location
    }
    $env:HP_OFFLINE_MODE          = $savedOfflineModeA
    $env:HP_TEST_FORCE_CONDA_FAIL = $savedCondaFailA
    $env:HP_TEST_FORCE_VENV_FAIL  = $savedVenvFailA
    $env:HP_CI_LANE               = $savedLaneA
    if ($null -eq $savedSysconA) { Remove-Item Env:HP_TEST_SYSCON_ANSWER -ErrorAction SilentlyContinue } else { $env:HP_TEST_SYSCON_ANSWER = $savedSysconA }

    $sysAcceptText = ''
    if (Test-Path -LiteralPath $sysAcceptLog) {
        $sysAcceptText = Get-Content -LiteralPath $sysAcceptLog -Raw -Encoding Ascii
    }
    $sysAcceptConsentLog = $sysAcceptText -match [regex]::Escape('[INFO] REQ-014: System Python consent: user accepted.')
    $sysAcceptSelected   = $sysAcceptText -match [regex]::Escape('[BOOT] REQ-009: Selected Python provider: System Python (degraded).')
    # Informational: degraded_env is the state written when system Python is the provider.
    $sysAcceptStatePath = Join-Path $sysAcceptDir '~bootstrap.status.json'
    $sysAcceptState = $null
    $sysAcceptExit  = $null
    if (Test-Path -LiteralPath $sysAcceptStatePath) {
        try {
            $st = Get-Content -LiteralPath $sysAcceptStatePath -Raw -Encoding Ascii | ConvertFrom-Json
            $sysAcceptState = $st.state
            $sysAcceptExit  = $st.exitCode
        } catch { }
    }
    # REQ-014.1: the warning that the system Python is shared and the question are printed BEFORE the provider is
    # selected, not only somewhere in the log.
    $sysAcceptWarned   = $sysAcceptText -match [regex]::Escape('may pollute shared packages')
    $sysAcceptAskedAt  = $sysAcceptText.IndexOf($sysPromptStr)
    $sysAcceptSelAt    = $sysAcceptText.IndexOf('[BOOT] REQ-009: Selected Python provider: System Python (degraded).')
    $sysAcceptOrdered  = ($sysAcceptAskedAt -ge 0) -and ($sysAcceptSelAt -gt $sysAcceptAskedAt)
    $sysAcceptPass = ($sysAcceptConsentLog -and $sysAcceptSelected -and $sysAcceptWarned -and $sysAcceptOrdered)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.system.gate.accept'
        req     = 'REQ-014.1, REQ-014.2, REQ-014.5, REQ-019.2'
        pass    = $sysAcceptPass
        desc    = 'System Python consent ACCEPT routes into Tier 4 system provider in a default no-flag run (REQ-009 provider independence), after the warning and the question'
        details = [ordered]@{ consentAcceptLog = $sysAcceptConsentLog; systemSelected = $sysAcceptSelected; warned = $sysAcceptWarned; askedBeforeSelected = $sysAcceptOrdered; state = $sysAcceptState; exitCode = $sysAcceptExit }
    })
}

# ===== REQ-014.3 / REQ-014.4: no answer, and the CI marker, in the same default fallback chain =====
# The scenario of self.ux.system.gate.real (every earlier provider fails, offline) with NO answer hook, so the gate resolves
# the answer itself. Standard input is closed (< nul), as in selfapps_offers_noninteractive.ps1, so a read that does happen
# gets end-of-file at once instead of hanging the job. The two branches log DIFFERENT lines, which is what tells them apart
# (a closed input would also decline quickly in the CI branch's place):
#   empty  no CI marker: the gate reads the keyboard, finds nothing and logs "empty input; declining" (REQ-014.3)
#   ci     only the CI marker: the gate declines without a read and logs "user declined" (REQ-014.4)
# The wrapper clears the answer hook and the other signals itself, in the launched shell, because a variable the job set
# is not reliably removed from a child by SetEnvironmentVariable (docs/agent-lessons-learned.md).
# Skipped in the conda-only lane, where the other providers are switched off by design.
function Invoke-SysGateRun {
    param([string]$Name, [string[]]$SetLines)
    $dir = Join-Path $here ('~selftest_sysgate_' + $Name)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $dir -Force
    Set-Content -LiteralPath (Join-Path $dir 'app.py') -Value 'print("hello")' -Encoding Ascii
    $wrapperLines = @(
        '@echo off',
        'set "HP_CI_LANE="', 'set "NOINPUT="', 'set "HP_NONINTERACTIVE="',
        'set "HP_TEST_SYSCON_ANSWER="', 'set "HP_TEST_FORCE_CONSENT_CHECK="',
        'set "HP_OFFLINE_MODE=1"', 'set "HP_TEST_FORCE_CONDA_FAIL=1"', 'set "HP_TEST_FORCE_VENV_FAIL=1"'
    ) + $SetLines + @('call run_setup.bat > ~sysgate_console.log 2>&1 < nul', 'exit /b %ERRORLEVEL%')
    Set-Content -LiteralPath (Join-Path $dir '~sysgate_launch.cmd') -Value $wrapperLines -Encoding Ascii
    $started = Get-Date
    $proc = Start-Process -FilePath $env:ComSpec -ArgumentList @('/c', 'call ~sysgate_launch.cmd') -WorkingDirectory $dir -NoNewWindow -PassThru
    $finished = $proc.WaitForExit(600000)
    if (-not $finished) {
        & taskkill.exe /F /T /PID $proc.Id 2>&1 | Out-Null
        $null = $proc.WaitForExit(30000)
    }
    $text = ''
    $consolePath = Join-Path $dir '~sysgate_console.log'
    if (Test-Path -LiteralPath $consolePath) { $text = Get-Content -LiteralPath $consolePath -Raw -Encoding Ascii }
    $state = $null
    $statePath = Join-Path $dir '~bootstrap.status.json'
    if (Test-Path -LiteralPath $statePath) {
        try { $state = [string]((Get-Content -LiteralPath $statePath -Raw -Encoding Ascii | ConvertFrom-Json).state) } catch { $state = 'unparseable' }
    }
    return [pscustomobject]@{ Finished = [bool]$finished; Seconds = [int]((Get-Date) - $started).TotalSeconds; Text = $text; State = $state }
}
$sysEmptyCi = @(
    @{ Name = 'empty'; SetLines = @() },
    @{ Name = 'ci'; SetLines = @('set "HP_CI_LANE=test"') }
)
$sysEmptyCiRuns = @{}
if ($env:HP_FORCE_CONDA_ONLY -ne '1') {
    foreach ($scenario in $sysEmptyCi) { $sysEmptyCiRuns[$scenario.Name] = Invoke-SysGateRun -Name $scenario.Name -SetLines $scenario.SetLines }
}
foreach ($scenarioName in @('empty', 'ci')) {
    if ($env:HP_FORCE_CONDA_ONLY -eq '1') { continue }
    $run = $sysEmptyCiRuns[$scenarioName]
    $asked      = $run.Text -match [regex]::Escape($sysPromptStr)
    $abortLog   = $run.Text -match [regex]::Escape('[INFO] REQ-014: System Python fallback aborted: consent not granted.')
    $emptyLog   = $run.Text -match [regex]::Escape('[INFO] REQ-014: System Python consent: empty input; declining.')
    $declineLog = $run.Text -match [regex]::Escape('[INFO] REQ-014: System Python consent: user declined.')
    $acceptLog  = $run.Text -match [regex]::Escape('[INFO] REQ-014: System Python consent: user accepted.')
    $selected   = $run.Text -match [regex]::Escape('Selected Python provider: System Python')
    $unused     = (-not $selected) -and (-not $acceptLog) -and ($run.State -ne 'degraded_env')
    # The answer line of the interactive read. The empty row requires it (the gate read the keyboard); the ci row only records it,
    # because the log lines already tell the branches apart and a prompt of an earlier gate would print the same words.
    $readPrompt = $run.Text -match [regex]::Escape('Your choice [y/n]:')
    if ($scenarioName -eq 'empty') {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.ux.system.gate.empty'
            req     = 'REQ-014.3'
            pass    = ($run.Finished -and $asked -and $readPrompt -and $emptyLog -and (-not $declineLog) -and $abortLog -and $unused)
            desc    = 'System Python consent gate: no answer at all (no CI marker, standard input closed) declines and leaves the system Python unused'
            details = [ordered]@{ finished = $run.Finished; seconds = $run.Seconds; promptFound = $asked; readPromptFound = $readPrompt; emptyInputLog = $emptyLog; declinedLog = $declineLog; abortLogFound = $abortLog; systemUnused = $unused; state = $run.State }
        })
    } else {
        Write-NdjsonRow ([ordered]@{
            id      = 'self.ux.system.gate.ci'
            req     = 'REQ-014.4'
            pass    = ($run.Finished -and $asked -and $declineLog -and (-not $emptyLog) -and $abortLog -and $unused)
            desc    = 'System Python consent gate: with only the CI marker set the gate declines without reading an answer'
            details = [ordered]@{ finished = $run.Finished; seconds = $run.Seconds; promptFound = $asked; readPromptFound = $readPrompt; declinedLog = $declineLog; emptyInputLog = $emptyLog; abortLogFound = $abortLog; systemUnused = $unused; state = $run.State }
        })
    }
}
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.system.gate.empty'
        req     = 'REQ-014'
        pass    = $true
        desc    = 'System Python consent gate with no answer (skipped in the conda-only lane)'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-blocks-system-fallback' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.ux.system.gate.ci'
        req     = 'REQ-014'
        pass    = $true
        desc    = 'System Python consent gate with only the CI marker (skipped in the conda-only lane)'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-blocks-system-fallback' }
    })
}

# ===== REQ-009 Tier 3: Venv fallback success path =====
# Forces conda to fail; verifies venv fallback fires automatically and app bootstraps via .venv.
# Skipped in conda-full lane where HP_FORCE_CONDA_ONLY=1 blocks all fallbacks unconditionally.
$venvFbDir = Join-Path $here '~selftest_venv_fallback'
if (Test-Path $venvFbDir) { Remove-Item -Recurse -Force $venvFbDir }
New-Item -ItemType Directory -Force -Path $venvFbDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $venvFbDir -Force
Set-Content -LiteralPath (Join-Path $venvFbDir 'app.py') -Value 'print("venv-fallback-ok")' -Encoding Ascii

$venvFbPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.venv.fallback'
        req     = 'REQ-009'
        pass    = $true
        desc    = 'REQ-009 Tier 3: venv fallback success path test'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-prohibits-venv-fallback' }
    })
} else {
    $savedCondaFail4 = $env:HP_TEST_FORCE_CONDA_FAIL
    $savedOffline4   = $env:HP_OFFLINE_MODE
    $savedSkipPR4    = $env:HP_SKIP_PIPREQS
    $savedLane4      = $env:HP_CI_LANE
    $env:HP_TEST_FORCE_CONDA_FAIL = '1'
    $env:HP_OFFLINE_MODE          = '1'
    $env:HP_SKIP_PIPREQS          = '1'
    $env:HP_CI_LANE               = 'test'
    $venvFbLog = Join-Path $venvFbDir '~venv_fallback.log'
    Push-Location -LiteralPath $venvFbDir
    try {
        cmd /c "run_setup.bat > ~venv_fallback.log 2>&1"
        $venvFbExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $env:HP_TEST_FORCE_CONDA_FAIL = $savedCondaFail4
    $env:HP_OFFLINE_MODE          = $savedOffline4
    $env:HP_SKIP_PIPREQS          = $savedSkipPR4
    $env:HP_CI_LANE               = $savedLane4

    $venvFbSetupLog = Join-Path $venvFbDir '~setup.log'
    $venvFbSetupText = ''
    if (Test-Path -LiteralPath $venvFbSetupLog) {
        $venvFbSetupText = Get-Content -LiteralPath $venvFbSetupLog -Raw -Encoding Ascii
    }
    $venvFbRunOut = Join-Path $venvFbDir '~run.out.txt'
    $venvFbRunText = ''
    if (Test-Path -LiteralPath $venvFbRunOut) {
        $venvFbRunText = Get-Content -LiteralPath $venvFbRunOut -Raw -Encoding Ascii
    }
    $venvFbReady    = ($venvFbSetupText -match [regex]::Escape('[INFO] venv fallback ready:'))
    $venvFbProvider = ($venvFbSetupText -match [regex]::Escape('[BOOT] REQ-009: Selected Python provider: Local venv (fallback).'))
    $venvFbAppRan   = ($venvFbRunText -match [regex]::Escape('venv-fallback-ok'))
    $venvFbPass = ($venvFbReady -and $venvFbProvider -and $venvFbAppRan)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.venv.fallback'
        req     = 'REQ-009, REQ-019.2'
        pass    = $venvFbPass
        desc    = 'REQ-009 Tier 3: venv fallback fires when conda fails and app bootstraps via .venv'
        details = [ordered]@{
            venvReadyLog     = $venvFbReady
            providerLogFound = $venvFbProvider
            appRan           = $venvFbAppRan
            exit             = $venvFbExit
        }
    })
}

# ===== REQ-023: venv canary probe declines a created-but-broken venv =====
# Forces conda to fail (reaching the venv tier) and forces the post-creation canary probe itself
# to fail via HP_TEST_FORCE_VENV_CANARY_FAIL=1 (venv creation succeeds normally -- only the
# "python -c import sys" health check is simulated as failing). Asserts the new WARN fires and
# venv is correctly NOT selected as the provider, instead of silently declaring a broken venv
# "ready". HP_TEST_SYSCON_ANSWER=N keeps the downstream system-Python consent gate
# non-interactive so the run terminates deterministically (declining is expected/correct here --
# every tier is forced to fail in this scenario on purpose).
# Skipped in conda-full lane where HP_FORCE_CONDA_ONLY=1 blocks all fallbacks unconditionally.
$venvCanaryDir = Join-Path $here '~selftest_venv_canary_fail'
if (Test-Path $venvCanaryDir) { Remove-Item -Recurse -Force $venvCanaryDir }
New-Item -ItemType Directory -Force -Path $venvCanaryDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $venvCanaryDir -Force
Set-Content -LiteralPath (Join-Path $venvCanaryDir 'app.py') -Value 'print("venv-canary-ok")' -Encoding Ascii

$venvCanaryPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.venv.canary_fail'
        req     = 'REQ-023.2, REQ-023.3, REQ-023.4'
        pass    = $true
        desc    = 'REQ-023: venv canary probe test'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-prohibits-venv-fallback' }
    })
} else {
    $savedCondaFail5 = $env:HP_TEST_FORCE_CONDA_FAIL
    $savedOffline5   = $env:HP_OFFLINE_MODE
    $savedSkipPR5    = $env:HP_SKIP_PIPREQS
    $savedLane5      = $env:HP_CI_LANE
    $savedCanaryFail = $env:HP_TEST_FORCE_VENV_CANARY_FAIL
    $savedSyscon5    = $env:HP_TEST_SYSCON_ANSWER
    $env:HP_TEST_FORCE_CONDA_FAIL       = '1'
    $env:HP_OFFLINE_MODE                = '1'
    $env:HP_SKIP_PIPREQS                = '1'
    $env:HP_CI_LANE                     = 'test'
    $env:HP_TEST_FORCE_VENV_CANARY_FAIL = '1'
    $env:HP_TEST_SYSCON_ANSWER          = 'N'
    $venvCanaryLog = Join-Path $venvCanaryDir '~venv_canary.log'
    Push-Location -LiteralPath $venvCanaryDir
    try {
        cmd /c "run_setup.bat > ~venv_canary.log 2>&1"
        $venvCanaryExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $env:HP_TEST_FORCE_CONDA_FAIL       = $savedCondaFail5
    $env:HP_OFFLINE_MODE                = $savedOffline5
    $env:HP_SKIP_PIPREQS                = $savedSkipPR5
    $env:HP_CI_LANE                     = $savedLane5
    $env:HP_TEST_FORCE_VENV_CANARY_FAIL = $savedCanaryFail
    $env:HP_TEST_SYSCON_ANSWER          = $savedSyscon5

    $venvCanarySetupLog = Join-Path $venvCanaryDir '~setup.log'
    $venvCanarySetupText = ''
    if (Test-Path -LiteralPath $venvCanarySetupLog) {
        $venvCanarySetupText = Get-Content -LiteralPath $venvCanarySetupLog -Raw -Encoding Ascii
    }
    $venvCanaryWarnFound = ($venvCanarySetupText -match [regex]::Escape('[WARN] venv fallback: interpreter created but failed canary probe (import sys).'))
    $venvCanaryNotSelected = -not ($venvCanarySetupText -match [regex]::Escape('[BOOT] REQ-009: Selected Python provider: Local venv (fallback).'))
    # REQ-023.4: the next provider of the chain must actually be tried. The system tier logs this line the moment it
    # starts, and the venv tier's own warning comes first, so the line is found only after the warning.
    $venvCanaryWarnAt = $venvCanarySetupText.IndexOf('[WARN] venv fallback: interpreter created but failed canary probe (import sys).')
    $venvCanaryNextAt = $venvCanarySetupText.IndexOf('[WARN] Attempting system Python fallback (degraded)...')
    $venvCanaryNextTier = ($venvCanaryWarnAt -ge 0) -and ($venvCanaryNextAt -gt $venvCanaryWarnAt)
    $venvCanaryPass = ($venvCanaryWarnFound -and $venvCanaryNotSelected -and $venvCanaryNextTier)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.venv.canary_fail'
        req     = 'REQ-023.2, REQ-023.3, REQ-023.4'
        pass    = $venvCanaryPass
        desc    = 'REQ-023: venv canary probe correctly declines a created-but-broken venv instead of selecting it, and the next provider is tried'
        details = [ordered]@{
            canaryWarnFound = $venvCanaryWarnFound
            venvNotSelected = $venvCanaryNotSelected
            nextTierAttempted = $venvCanaryNextTier
            exit            = $venvCanaryExit
        }
    })
}

# ===== REQ-023b: venv --without-pip retry + get-pip.py bootstrap =====
# Forces the FIRST plain "python -m venv" attempt to fail via HP_TEST_FORCE_VENV_CREATE_FAIL=1
# (simulating a stripped-down host Python missing ensurepip) so the --without-pip retry path is
# exercised for real, followed by a real get-pip.py download+bootstrap (needs actual network --
# unlike the neighboring venv tests, HP_OFFLINE_MODE=1 is still set here purely to cheaply skip
# the unrelated Miniconda download; :download_get_pip carves out an explicit exception for this
# exact test flag so the get-pip.py fetch itself is not skipped). Asserts the retry WARN, the
# pip-bootstrap success INFO, the venv-selected line, and that the app actually ran.
# Skipped in conda-full lane where HP_FORCE_CONDA_ONLY=1 blocks all fallbacks unconditionally.
$venvNoPipDir = Join-Path $here '~selftest_venv_nopip_retry'
if (Test-Path $venvNoPipDir) { Remove-Item -Recurse -Force $venvNoPipDir }
New-Item -ItemType Directory -Force -Path $venvNoPipDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $venvNoPipDir -Force
Set-Content -LiteralPath (Join-Path $venvNoPipDir 'app.py') -Value 'print("venv-nopip-retry-ok")' -Encoding Ascii

$venvNoPipPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.venv.nopip_retry'
        req     = 'REQ-023b'
        pass    = $true
        desc    = 'REQ-023b: venv --without-pip retry + get-pip.py bootstrap test'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-prohibits-venv-fallback' }
    })
} else {
    $savedCondaFail6    = $env:HP_TEST_FORCE_CONDA_FAIL
    $savedOffline6      = $env:HP_OFFLINE_MODE
    $savedSkipPR6       = $env:HP_SKIP_PIPREQS
    $savedLane6         = $env:HP_CI_LANE
    $savedVenvCreateFail = $env:HP_TEST_FORCE_VENV_CREATE_FAIL
    $env:HP_TEST_FORCE_CONDA_FAIL      = '1'
    $env:HP_OFFLINE_MODE               = '1'
    $env:HP_SKIP_PIPREQS                = '1'
    $env:HP_CI_LANE                     = 'test'
    $env:HP_TEST_FORCE_VENV_CREATE_FAIL = '1'
    $venvNoPipLog = Join-Path $venvNoPipDir '~venv_nopip.log'
    Push-Location -LiteralPath $venvNoPipDir
    try {
        cmd /c "run_setup.bat > ~venv_nopip.log 2>&1"
        $venvNoPipExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $env:HP_TEST_FORCE_CONDA_FAIL       = $savedCondaFail6
    $env:HP_OFFLINE_MODE                = $savedOffline6
    $env:HP_SKIP_PIPREQS                = $savedSkipPR6
    $env:HP_CI_LANE                     = $savedLane6
    $env:HP_TEST_FORCE_VENV_CREATE_FAIL = $savedVenvCreateFail

    $venvNoPipSetupLog = Join-Path $venvNoPipDir '~setup.log'
    $venvNoPipSetupText = ''
    if (Test-Path -LiteralPath $venvNoPipSetupLog) {
        $venvNoPipSetupText = Get-Content -LiteralPath $venvNoPipSetupLog -Raw -Encoding Ascii
    }
    $venvNoPipRunOut = Join-Path $venvNoPipDir '~run.out.txt'
    $venvNoPipRunText = ''
    if (Test-Path -LiteralPath $venvNoPipRunOut) {
        $venvNoPipRunText = Get-Content -LiteralPath $venvNoPipRunOut -Raw -Encoding Ascii
    }
    $venvNoPipRetryFound = ($venvNoPipSetupText -match [regex]::Escape('[WARN] venv fallback: python -m venv failed; retrying once with --without-pip.'))
    $venvNoPipBootstrapOk = ($venvNoPipSetupText -match [regex]::Escape('[INFO] venv fallback: pip bootstrapped successfully via get-pip.py.'))
    $venvNoPipProvider = ($venvNoPipSetupText -match [regex]::Escape('[BOOT] REQ-009: Selected Python provider: Local venv (fallback).'))
    $venvNoPipAppRan = ($venvNoPipRunText -match [regex]::Escape('venv-nopip-retry-ok'))
    $venvNoPipPass = ($venvNoPipRetryFound -and $venvNoPipBootstrapOk -and $venvNoPipProvider -and $venvNoPipAppRan)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.venv.nopip_retry'
        req     = 'REQ-013.19'
        pass    = $venvNoPipPass
        desc    = 'REQ-023b: venv fallback retries with --without-pip and bootstraps pip via get-pip.py when plain venv creation fails'
        details = [ordered]@{
            retryWarnFound  = $venvNoPipRetryFound
            pipBootstrapOk  = $venvNoPipBootstrapOk
            providerLogFound = $venvNoPipProvider
            appRan          = $venvNoPipAppRan
            exit            = $venvNoPipExit
        }
    })
}

# ===== REQ-009 Tier 5: embedded Python fallback declines gracefully when all tiers fail =====
# Since the provider-chain reorder (uv -> conda -> embed -> venv -> system), embed is reached
# directly after conda fails -- HP_TEST_FORCE_CONDA_FAIL=1 alone is enough to reach it. This
# test still also forces venv-fail and system-decline (HP_TEST_SYSCON_ANSWER=N) because it wants
# to prove TIER EXHAUSTION, not just reachability: without those, a real venv/system on the CI
# runner could silently recover after embed's forced failure, defeating the point of this test.
# Then forces the embed tier itself to fail via HP_TEST_FORCE_EMBED_FAIL=1. Proves
# :handle_conda_failure's reordered embed call is wired correctly and, when every tier is
# exhausted, the bootstrap reaches :die cleanly instead of hanging or silently reporting success.
# Also asserts the embed attempt log line appears BEFORE the venv-fallback log line, proving the
# new order actually executes (not just that embed is reachable at all).
# Skipped in conda-full lane where HP_FORCE_CONDA_ONLY=1 blocks all fallbacks unconditionally.
$embedDeclineDir = Join-Path $here '~selftest_embed_decline'
if (Test-Path $embedDeclineDir) { Remove-Item -Recurse -Force $embedDeclineDir }
New-Item -ItemType Directory -Force -Path $embedDeclineDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $embedDeclineDir -Force
Set-Content -LiteralPath (Join-Path $embedDeclineDir 'app.py') -Value 'print("embed-decline-should-not-run")' -Encoding Ascii

$embedDeclinePass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.embed.fallback.decline'
        req     = 'REQ-009'
        pass    = $true
        desc    = 'REQ-009 Tier 5: embed fallback graceful-decline test'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-prohibits-non-conda-fallbacks' }
    })
} else {
    $embedDeclineLog = Join-Path $embedDeclineDir '~embed_decline.log'
    $embedDeclineExit = Invoke-WithEnvOverrides -Overrides @{
        HP_TEST_FORCE_CONDA_FAIL = '1'
        HP_TEST_FORCE_VENV_FAIL  = '1'
        HP_TEST_SYSCON_ANSWER    = 'N'
        HP_OFFLINE_MODE          = '1'
        HP_CI_LANE               = 'test'
        HP_TEST_FORCE_EMBED_FAIL = '1'
    } -Body {
        Push-Location -LiteralPath $embedDeclineDir
        try {
            cmd /c "run_setup.bat > ~embed_decline.log 2>&1"
            $LASTEXITCODE
        } finally {
            Pop-Location
        }
    }

    $embedDeclineText = ''
    if (Test-Path -LiteralPath $embedDeclineLog) {
        $embedDeclineText = Get-Content -LiteralPath $embedDeclineLog -Raw -Encoding Ascii
    }
    $embedDeclineAttempted = ($embedDeclineText -match [regex]::Escape('[WARN] Attempting embedded Python download (REQ-009 Tier 5)...'))
    $embedDeclineForced    = ($embedDeclineText -match [regex]::Escape('[TEST] HP_TEST_FORCE_EMBED_FAIL: simulating embed tier failure.'))
    $embedDeclineStatePath = Join-Path $embedDeclineDir '~bootstrap.status.json'
    $embedDeclineState = $null
    $embedDeclineStExit = $null
    if (Test-Path -LiteralPath $embedDeclineStatePath) {
        try {
            $st = Get-Content -LiteralPath $embedDeclineStatePath -Raw -Encoding Ascii | ConvertFrom-Json
            $embedDeclineState = $st.state
            $embedDeclineStExit = $st.exitCode
        } catch { }
    }
    # derived requirement: run_setup.bat's own :die uses "exit /b" (a subroutine return, not a
    # process exit) -- per agent-lessons-learned.md's ":die" entry, the batch process can still
    # exit 0 even after a logical failure, so ~bootstrap.status.json's state (not the raw exit code)
    # is this codebase's own documented source of truth for "did it actually fail". processExit is
    # captured in details for diagnostics only, not asserted.
    $embedDeclineDied = ($embedDeclineState -eq 'error')
    # derived requirement: proves the reordered chain (uv -> conda -> embed -> venv -> system)
    # actually executes in that order, not just that embed is reachable -- the embed attempt
    # line must appear strictly before the venv-fallback line in the same log.
    $embedDeclineVenvIdx = $embedDeclineText.IndexOf('[WARN] Attempting venv fallback')
    $embedDeclineEmbedIdx = $embedDeclineText.IndexOf('[WARN] Attempting embedded Python download')
    $embedDeclineOrdered = ($embedDeclineEmbedIdx -ge 0) -and ($embedDeclineVenvIdx -ge 0) -and ($embedDeclineEmbedIdx -lt $embedDeclineVenvIdx)
    # derived requirement (CLAUDE.md Active Backlog item 14, closed): total REQ-009 provider-tier
    # exhaustion leaves HP_PY empty, which used to make :preflight_compile run py_compile against
    # an empty interpreter path and report a fabricated "syntax error" instead of the real cause.
    # This scenario (uv/conda/embed/venv all forced-fail, system declined) is the one real path
    # that reaches total exhaustion, so it is also the regression test for that fix: the honest
    # no-interpreter message must appear, the old fabricated message must NOT, and no PyInstaller
    # build may be attempted against a broken interpreter.
    $embedDeclineHonestMsg = ($embedDeclineText -match [regex]::Escape('No Python interpreter is available'))
    $embedDeclineNoFakeSyntaxErr = -not ($embedDeclineText -match [regex]::Escape('Your Python program has a syntax error'))
    $embedDeclineNoBuildAttempt = -not ($embedDeclineText -match [regex]::Escape('Building standalone executable'))
    $embedDeclinePass = ($embedDeclineAttempted -and $embedDeclineForced -and $embedDeclineDied -and $embedDeclineOrdered -and
                          $embedDeclineHonestMsg -and $embedDeclineNoFakeSyntaxErr -and $embedDeclineNoBuildAttempt)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.embed.fallback.decline'
        req     = 'REQ-009'
        pass    = $embedDeclinePass
        desc    = 'REQ-009 Tier 5 (reordered): embed fallback is attempted right after conda fails (before venv/system), and a forced embed failure reaches :die once venv/system also fail (bootstrap.status.json reports state=error); also covers item 14: total exhaustion reports the real no-interpreter cause, not a fabricated syntax error, and skips the doomed build'
        details = [ordered]@{
            attemptedLog   = $embedDeclineAttempted
            forcedLog      = $embedDeclineForced
            orderedLog     = $embedDeclineOrdered
            embedIdx       = $embedDeclineEmbedIdx
            venvIdx        = $embedDeclineVenvIdx
            state          = $embedDeclineState
            exitCode       = $embedDeclineStExit
            processExit    = $embedDeclineExit
            honestMsg      = $embedDeclineHonestMsg
            noFakeSyntaxErr = $embedDeclineNoFakeSyntaxErr
            noBuildAttempt = $embedDeclineNoBuildAttempt
        }
    })
}

# ===== REQ-009 Tier 5: embedded Python fallback real download-through-run path =====
# Since the provider-chain reorder, embed is reached directly after conda fails -- only
# HP_TEST_FORCE_CONDA_FAIL=1 is needed to reach it (HP_TEST_FORCE_VENV_FAIL/HP_TEST_SYSCON_ANSWER
# are no longer needed here: embed succeeding short-circuits the chain before venv/system are
# ever attempted, so forcing them to fail too would just be dead setup). Uses
# HP_TEST_FORCE_EMBED_REAL=1 -- a narrow hole through the HP_OFFLINE_MODE gate for this tier only
# (mirrors HP_TEST_FORCE_VENV_CREATE_FAIL's existing exception for :download_get_pip) -- so the
# real checksum-verified download, extraction, ._pth patch, get-pip.py bootstrap, canary probe,
# dependency install, EXE build, and run all execute for real. Proves the tier is not just wired
# but actually functional end-to-end, and that success short-circuits before reaching venv.
# Skipped in conda-full lane where HP_FORCE_CONDA_ONLY=1 blocks all fallbacks unconditionally.
$embedRealDir = Join-Path $here '~selftest_embed_real'
if (Test-Path $embedRealDir) { Remove-Item -Recurse -Force $embedRealDir }
New-Item -ItemType Directory -Force -Path $embedRealDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $embedRealDir -Force
Set-Content -LiteralPath (Join-Path $embedRealDir 'app.py') -Value 'print("embed-real-ok")' -Encoding Ascii

$embedRealPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.embed.fallback.real'
        req     = 'REQ-009'
        pass    = $true
        desc    = 'REQ-009 Tier 5: embed fallback real download-through-run test'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-prohibits-non-conda-fallbacks' }
    })
} else {
    $embedRealLog = Join-Path $embedRealDir '~embed_real.log'
    $embedRealExit = Invoke-WithEnvOverrides -Overrides @{
        HP_TEST_FORCE_CONDA_FAIL = '1'
        HP_OFFLINE_MODE          = '1'
        HP_SKIP_PIPREQS          = '1'
        HP_CI_LANE               = 'test'
        HP_TEST_FORCE_EMBED_REAL = '1'
    } -Body {
        Push-Location -LiteralPath $embedRealDir
        try {
            cmd /c "run_setup.bat > ~embed_real.log 2>&1"
            $LASTEXITCODE
        } finally {
            Pop-Location
        }
    }

    $embedRealSetupLog = Join-Path $embedRealDir '~setup.log'
    $embedRealSetupText = ''
    if (Test-Path -LiteralPath $embedRealSetupLog) {
        $embedRealSetupText = Get-Content -LiteralPath $embedRealSetupLog -Raw -Encoding Ascii
    }
    $embedRealRunOut = Join-Path $embedRealDir '~run.out.txt'
    $embedRealRunText = ''
    if (Test-Path -LiteralPath $embedRealRunOut) {
        $embedRealRunText = Get-Content -LiteralPath $embedRealRunOut -Raw -Encoding Ascii
    }
    $embedRealExtracted = ($embedRealSetupText -match [regex]::Escape('[INFO] embed fallback: ') ) -and ($embedRealSetupText -match [regex]::Escape('extracted and verified.'))
    $embedRealReady     = ($embedRealSetupText -match [regex]::Escape('[INFO] embed fallback ready:'))
    $embedRealProvider  = ($embedRealSetupText -match [regex]::Escape('[BOOT] REQ-009: Selected Python provider: Embedded Python (python.org).'))
    $embedRealAppRan    = ($embedRealRunText -match [regex]::Escape('embed-real-ok'))
    # derived requirement: proves embed's success short-circuits the reordered chain before
    # venv is ever attempted -- the venv-fallback log line must be entirely absent.
    $embedRealVenvAbsent = -not ($embedRealSetupText -match [regex]::Escape('[WARN] Attempting venv fallback'))
    $embedRealPass = ($embedRealExtracted -and $embedRealReady -and $embedRealProvider -and $embedRealAppRan -and $embedRealVenvAbsent)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.embed.fallback.real'
        req     = 'REQ-009'
        pass    = $embedRealPass
        desc    = 'REQ-009 Tier 5 (reordered): real embed download/extract/patch/get-pip/canary/build/run succeeds end-to-end right after conda fails, short-circuiting before venv is ever attempted'
        details = [ordered]@{
            extractedLog     = $embedRealExtracted
            readyLog         = $embedRealReady
            providerLogFound = $embedRealProvider
            appRan           = $embedRealAppRan
            venvAbsent       = $embedRealVenvAbsent
            exit             = $embedRealExit
        }
    })
}

# ===== REQ-009 Tier 5: embed download-failure-then-retry-once path (former CLAUDE.md Active =====
# ===== Backlog item 12) =====
# :embed_dl_retry's genuine mid-download-failure-then-retry-once path had no CI test hook at
# all -- HP_TEST_FORCE_EMBED_DL_FAIL_ONCE=1 (run_setup.bat) deterministically fails ONLY the
# first download attempt (no network touched, cleared immediately after firing), so attempt 2
# goes through for real -- mirrors HP_TEST_FORCE_CONDA_CREATE_NETWORK_FAIL's established
# one-shot-then-succeed pattern. Combined with HP_TEST_FORCE_EMBED_REAL=1 (same narrow
# HP_OFFLINE_MODE hole as the .real scenario above) so the SECOND, real attempt genuinely
# downloads/extracts/verifies/runs -- proving both the retry log line fires AND the tier still
# succeeds end-to-end afterward. Skipped in conda-full lane, same reasoning as .real above.
$embedRetryDir = Join-Path $here '~selftest_embed_dl_retry'
if (Test-Path $embedRetryDir) { Remove-Item -Recurse -Force $embedRetryDir }
New-Item -ItemType Directory -Force -Path $embedRetryDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $embedRetryDir -Force
Set-Content -LiteralPath (Join-Path $embedRetryDir 'app.py') -Value 'print("embed-retry-ok")' -Encoding Ascii

$embedRetryPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.embed.dl.retry'
        req     = 'REQ-009'
        pass    = $true
        desc    = 'REQ-009 Tier 5: embed download-failure-then-retry-once path'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-prohibits-non-conda-fallbacks' }
    })
} else {
    $embedRetryLog = Join-Path $embedRetryDir '~embed_retry.log'
    $embedRetryExit = Invoke-WithEnvOverrides -Overrides @{
        HP_TEST_FORCE_CONDA_FAIL         = '1'
        HP_OFFLINE_MODE                  = '1'
        HP_SKIP_PIPREQS                  = '1'
        HP_CI_LANE                       = 'test'
        HP_TEST_FORCE_EMBED_REAL         = '1'
        HP_TEST_FORCE_EMBED_DL_FAIL_ONCE = '1'
    } -Body {
        Push-Location -LiteralPath $embedRetryDir
        try {
            cmd /c "run_setup.bat > ~embed_retry.log 2>&1"
            $LASTEXITCODE
        } finally {
            Pop-Location
        }
    }

    $embedRetrySetupLog = Join-Path $embedRetryDir '~setup.log'
    $embedRetrySetupText = ''
    if (Test-Path -LiteralPath $embedRetrySetupLog) {
        $embedRetrySetupText = Get-Content -LiteralPath $embedRetrySetupLog -Raw -Encoding Ascii
    }
    $embedRetryRunOut = Join-Path $embedRetryDir '~run.out.txt'
    $embedRetryRunText = ''
    if (Test-Path -LiteralPath $embedRetryRunOut) {
        $embedRetryRunText = Get-Content -LiteralPath $embedRetryRunOut -Raw -Encoding Ascii
    }
    $embedRetryHookFired = ($embedRetrySetupText -match [regex]::Escape('[TEST] HP_TEST_FORCE_EMBED_DL_FAIL_ONCE: simulating download failure on attempt 1'))
    $embedRetryWarnFired = ($embedRetrySetupText -match [regex]::Escape('[WARN] embed fallback: download failed; retrying once.'))
    $embedRetryExtracted = ($embedRetrySetupText -match [regex]::Escape('[INFO] embed fallback: ')) -and ($embedRetrySetupText -match [regex]::Escape('extracted and verified.'))
    $embedRetryReady     = ($embedRetrySetupText -match [regex]::Escape('[INFO] embed fallback ready:'))
    $embedRetryAppRan    = ($embedRetryRunText -match [regex]::Escape('embed-retry-ok'))
    $embedRetryPass = ($embedRetryHookFired -and $embedRetryWarnFired -and $embedRetryExtracted -and $embedRetryReady -and $embedRetryAppRan)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.embed.dl.retry'
        req     = 'REQ-009, REQ-013.16'
        pass    = $embedRetryPass
        desc    = 'REQ-009 Tier 5: first download attempt deterministically fails (no network touched), second (real) attempt succeeds end-to-end'
        details = [ordered]@{
            hookFired  = $embedRetryHookFired
            warnFired  = $embedRetryWarnFired
            extracted  = $embedRetryExtracted
            ready      = $embedRetryReady
            appRan     = $embedRetryAppRan
            exit       = $embedRetryExit
        }
    })
}

# ===== REQ-002 priority 0: manual %1 override beats auto-detection (main.py) =====
# REQ-002 ranks a co-located %1 argument (drag-and-drop) above every auto-detected name:
# it is used directly and skips all auto-detection. Prior tests only cover auto-detection
# ordering (entryA-D) and REQ-011 same-dir with a SOLE file -- none prove the override
# WINS over a higher-priority name. The :ci_skip_entry path (HP_CI_SKIP_ENV=1) ignores %1,
# so this needs the real (non-skip) determine_entry. Reuse the proven forced-venv pattern
# (cheaper than conda; gated by real/uv lanes): stage main.py (would win auto-detection by
# name = priority 1) plus zzz_override.py, pass ".\zzz_override.py" as %1, and assert the
# override is chosen and run -- not main.py. Skipped in conda-full where HP_FORCE_CONDA_ONLY
# blocks the venv fallback (same as the venv/sysgate-real tests above).
$entryOvDir = Join-Path $here '~selftest_entry_override'
if (Test-Path $entryOvDir) { Remove-Item -Recurse -Force $entryOvDir }
New-Item -ItemType Directory -Force -Path $entryOvDir | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $entryOvDir -Force
Set-Content -LiteralPath (Join-Path $entryOvDir 'main.py') -Value 'print("from-main")' -Encoding Ascii
Set-Content -LiteralPath (Join-Path $entryOvDir 'zzz_override.py') -Value 'print("from-override")' -Encoding Ascii

$entryOvPass = $true
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.override'
        req     = 'REQ-002'
        pass    = $true
        desc    = 'REQ-002 priority 0: manual %1 override beats auto-detection'
        details = [ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY-prohibits-venv-fallback' }
    })
} else {
    $savedCondaFailOv = $env:HP_TEST_FORCE_CONDA_FAIL
    $savedOfflineOv   = $env:HP_OFFLINE_MODE
    $savedSkipPROv    = $env:HP_SKIP_PIPREQS
    $savedLaneOv      = $env:HP_CI_LANE
    $env:HP_TEST_FORCE_CONDA_FAIL = '1'
    $env:HP_OFFLINE_MODE          = '1'
    $env:HP_SKIP_PIPREQS          = '1'
    $env:HP_CI_LANE               = 'test'
    Push-Location -LiteralPath $entryOvDir
    try {
        cmd /c "run_setup.bat .\zzz_override.py > ~override.log 2>&1"
        $entryOvExit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $env:HP_TEST_FORCE_CONDA_FAIL = $savedCondaFailOv
    $env:HP_OFFLINE_MODE          = $savedOfflineOv
    $env:HP_SKIP_PIPREQS          = $savedSkipPROv
    $env:HP_CI_LANE               = $savedLaneOv

    $entryOvBootText = ''
    $entryOvBootLog = Join-Path $entryOvDir '~override.log'
    if (Test-Path -LiteralPath $entryOvBootLog) {
        $entryOvBootText = Get-Content -LiteralPath $entryOvBootLog -Raw -Encoding Ascii
    }
    $entryOvSetupText = ''
    $entryOvSetupLog = Join-Path $entryOvDir '~setup.log'
    if (Test-Path -LiteralPath $entryOvSetupLog) {
        $entryOvSetupText = Get-Content -LiteralPath $entryOvSetupLog -Raw -Encoding Ascii
    }
    $entryOvRunText = ''
    $entryOvRunOut = Join-Path $entryOvDir '~run.out.txt'
    if (Test-Path -LiteralPath $entryOvRunOut) {
        $entryOvRunText = Get-Content -LiteralPath $entryOvRunOut -Raw -Encoding Ascii
    }
    # Priority-0 branch fired and the drag message now prints the filename (regression guard
    # for the parse-time-expansion fix in :determine_entry, which previously printed an empty
    # name). Also confirm the chosen entry is the override, not main.py.
    $entryOvDragMsg  = ($entryOvBootText -match [regex]::Escape('Using drag-and-drop file: .\zzz_override.py'))
    $entryOvSelected = ($entryOvSetupText -match [regex]::Escape('[BOOT] REQ-002: Entry selected:')) -and ($entryOvSetupText -match [regex]::Escape('zzz_override.py'))
    $entryOvRanOverride = ($entryOvRunText -match [regex]::Escape('from-override'))
    $entryOvNotMain  = -not ($entryOvRunText -match [regex]::Escape('from-main'))
    $entryOvPass = ($entryOvDragMsg -and $entryOvSelected -and $entryOvRanOverride -and $entryOvNotMain)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.override'
        req     = 'REQ-002'
        pass    = $entryOvPass
        desc    = 'REQ-002 priority 0: co-located %1 override is chosen and run over main.py'
        details = [ordered]@{
            dragMsgFound  = $entryOvDragMsg
            entrySelected = $entryOvSelected
            ranOverride   = $entryOvRanOverride
            notMain       = $entryOvNotMain
            exit          = $entryOvExit
        }
    })
}

$allPass = $giMerged -and $giPreserved -and $giIdem -and ($gaMerged -and $gaBatText -and $gaCmdText) -and $gaIdem -and $pfFound -and ($connPromptFound -and $connOfflineLog) -and $connPromptFound -and $uvOfflinePass -and $condaOfflinePass -and $connReachableFound -and $connRetryFound -and $connOverridePass -and ($sysPromptFound -and $sysDeclineLog) -and $sysPromptFound -and $sysRealPass -and $sysAcceptPass -and $venvFbPass -and $venvCanaryPass -and $venvNoPipPass -and $embedDeclinePass -and $embedRealPass -and $entryOvPass
if (-not $allPass) { exit 1 }
exit 0
