# ASCII only
# selfapps_preflight_pycache.ps1 - REQ-021.4, REQ-021.5 and REQ-021.6: the pre-flight syntax check must
# not change the outcome of a run whose entry file is valid, must leave the folder as it found it, and
# must still reject everything the Python compiler rejects.
#
# Today :preflight_compile runs `python -m py_compile` on the entry. py_compile writes a .pyc into
# __pycache__; when it cannot (a read-only __pycache__, or a FILE named __pycache__) it exits 1 for a
# perfectly valid program and the bootstrapper reports a syntax error that is not there. Even when it
# can write, it leaves __pycache__\entry.cpython-*.pyc behind in the user's folder.
#
# Three scenarios, each a full default bootstrap of a one-line program:
#   unwritable : a regular FILE named __pycache__ sits in the folder (py_compile cannot create the
#                directory). Row self.preflight.pycache.unwritable (REQ-021.4, critical).
#   litter     : a normal folder. Nothing in this run imports a local module, so the only writer of
#                __pycache__\entry.cpython-*.pyc is the pre-flight. Row self.preflight.pycache.litter
#                (REQ-021.5, minor).
#   compiler   : an entry with a `return` outside a function. The parser (ast.parse) accepts it and only the
#                compiler rejects it, so a pre-flight that only parses would let a real syntax error through.
#                Row self.preflight.syntax.compiler (REQ-021.6, major). It passes before and after the
#                Item 83 fix on purpose: it pins that the in-memory check is as strict as py_compile was.
#
# HP_SKIP_PIPREQS=1 keeps pipreqs from any network lookup, as selfapps_preflight.ps1 does.
# Lane: real only (the pre-flight is provider independent; one lane is enough to prove it).
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

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.pycache.unwritable'
        req     = 'REQ-021.4'
        pass    = $true
        desc    = 'REQ-021.4 pre-flight does not abort a valid program (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.pycache.litter'
        req     = 'REQ-021.5'
        pass    = $true
        desc    = 'REQ-021.5 pre-flight leaves no file behind (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.syntax.compiler'
        req     = 'REQ-021.6'
        pass    = $true
        desc    = 'REQ-021.6 pre-flight rejects what the compiler rejects (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    $missing = 'run_setup.bat not found at ' + $batchPath
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.pycache.unwritable'
        req     = 'REQ-021.4'
        pass    = $false
        desc    = 'REQ-021.4 pre-flight does not abort a valid program (run_setup.bat not found)'
        details = [ordered]@{ error = $missing }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.pycache.litter'
        req     = 'REQ-021.5'
        pass    = $false
        desc    = 'REQ-021.5 pre-flight leaves no file behind (run_setup.bat not found)'
        details = [ordered]@{ error = $missing }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.preflight.syntax.compiler'
        req     = 'REQ-021.6'
        pass    = $false
        desc    = 'REQ-021.6 pre-flight rejects what the compiler rejects (run_setup.bat not found)'
        details = [ordered]@{ error = $missing }
    })
    exit 1
}

$token = 'preflight pycache token'

# Runs one default bootstrap in a fresh folder and returns what the assertions need.
function Invoke-Scenario {
    param([string]$Name, [bool]$BlockPycache, [string]$EntrySource = ("print('" + $token + "')"))
    $workDir = Join-Path $here ('~selftest_preflight_' + $Name)
    if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
    New-Item -ItemType Directory -Force -Path $workDir | Out-Null
    Copy-Item -Path $batchPath -Destination $workDir -Force
    Set-Content -Path (Join-Path $workDir 'entry.py') -Value $EntrySource -Encoding ASCII
    if ($BlockPycache) {
        # A regular file where py_compile wants a directory: it cannot create __pycache__ or write into it.
        Set-Content -Path (Join-Path $workDir '__pycache__') -Value 'not a directory' -Encoding ASCII
    }
    $bootstrapLog = '~preflight_pycache_' + $Name + '.log'
    $prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
    $env:HP_SKIP_PIPREQS = '1'
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $runExit = $LASTEXITCODE
    } finally {
        if ($null -eq $prev) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prev }
        Pop-Location
    }
    $logLines = if (Test-Path (Join-Path $workDir $bootstrapLog)) { Get-Content -LiteralPath (Join-Path $workDir $bootstrapLog) -Encoding ASCII } else { @() }
    $setupTxt = if (Test-Path (Join-Path $workDir '~setup.log')) { Get-Content -LiteralPath (Join-Path $workDir '~setup.log') -Raw -Encoding ASCII } else { '' }
    $combined = ($logLines -join "`n") + "`n" + $setupTxt
    $state = ''
    $statusF = Join-Path $workDir '~bootstrap.status.json'
    if (Test-Path $statusF) {
        try { $state = (Get-Content -LiteralPath $statusF -Raw -Encoding ASCII | ConvertFrom-Json).state } catch { $state = 'unparseable' }
    }
    $runOut = if (Test-Path (Join-Path $workDir '~run.out.txt')) { Get-Content -LiteralPath (Join-Path $workDir '~run.out.txt') -Raw -Encoding ASCII } else { '' }
    $pyc = @()
    if (Test-Path -LiteralPath (Join-Path $workDir '__pycache__') -PathType Container) {
        $pyc = @(Get-ChildItem -LiteralPath (Join-Path $workDir '__pycache__') -Filter 'entry*.pyc' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    }
    return [ordered]@{
        runExit          = $runExit
        state            = $state
        falseSyntaxError = [bool]($combined -match 'Your Python program has a syntax error' -or $combined -match 'REQ-021: entry failed (py_compile|the syntax check)')
        returnDetail     = [bool]($combined -match "'return' outside function")
        reachedBuild     = [bool]($combined -match 'PyInstaller execution failed')
        exeBuilt         = [bool](Test-Path -LiteralPath (Join-Path $workDir 'dist'))
        programRan       = [bool](($combined -match [regex]::Escape($token)) -or ($runOut -match [regex]::Escape($token)))
        pycFiles         = ($pyc -join ',')
        log              = $bootstrapLog
    }
}

# --- scenario 1: unwritable __pycache__ (REQ-021.4) ---
$u = Invoke-Scenario -Name 'unwritable' -BlockPycache $true
# A valid program must reach its run: no false syntax error, a state other than error, and the
# program's own output seen at least once (the verification run).
$uPass = (-not $u.falseSyntaxError) -and ($u.state -ne 'error') -and $u.programRan
Write-NdjsonRow ([ordered]@{
    id      = 'self.preflight.pycache.unwritable'
    req     = 'REQ-021.4'
    pass    = [bool]$uPass
    desc    = 'REQ-021.4: a valid entry next to a FILE named __pycache__ is not reported as a syntax error and the run continues'
    details = [ordered]@{
        bootstrapExit    = $u.runExit
        falseSyntaxError = $u.falseSyntaxError
        statusState      = $u.state
        programRan       = $u.programRan
        log              = $u.log
    }
})

# --- scenario 2: nothing left behind (REQ-021.5) ---
$l = Invoke-Scenario -Name 'litter' -BlockPycache $false
$lPass = ($l.pycFiles -eq '') -and (-not $l.falseSyntaxError) -and $l.programRan
Write-NdjsonRow ([ordered]@{
    id      = 'self.preflight.pycache.litter'
    req     = 'REQ-021.5'
    pass    = [bool]$lPass
    desc    = 'REQ-021.5: a valid entry leaves no __pycache__\entry.cpython-*.pyc behind (the pre-flight is its only possible writer)'
    details = [ordered]@{
        bootstrapExit    = $l.runExit
        falseSyntaxError = $l.falseSyntaxError
        statusState      = $l.state
        programRan       = $l.programRan
        pycFiles         = $l.pycFiles
        log              = $l.log
    }
})

# --- scenario 3: what the compiler rejects, the pre-flight rejects (REQ-021.6) ---
# `return` outside a function is not a parser error: ast.parse accepts it and only compile() raises it.
# The program must be reported as a syntax error before any build, must not run, and must not leave a dist folder.
$cSource = "print('" + $token + "')`nreturn 1"
$c = Invoke-Scenario -Name 'compiler' -BlockPycache $false -EntrySource $cSource
$cPass = $c.falseSyntaxError -and ($c.state -eq 'error') -and $c.returnDetail -and (-not $c.programRan) -and (-not $c.reachedBuild) -and (-not $c.exeBuilt)
Write-NdjsonRow ([ordered]@{
    id      = 'self.preflight.syntax.compiler'
    req     = 'REQ-021.6'
    pass    = [bool]$cPass
    desc    = 'REQ-021.6: a `return` outside a function (accepted by the parser, rejected by the compiler) is reported as a syntax error before any build'
    details = [ordered]@{
        bootstrapExit = $c.runExit
        reported      = $c.falseSyntaxError
        statusState   = $c.state
        returnDetail  = $c.returnDetail
        programRan    = $c.programRan
        reachedBuild  = $c.reachedBuild
        exeBuilt      = $c.exeBuilt
        log           = $c.log
    }
})

if (-not ($uPass -and $lPass -and $cPass)) { exit 1 }
exit 0
