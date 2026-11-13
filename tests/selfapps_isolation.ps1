# ASCII only
# selfapps_isolation.ps1 - REQ-011 directory integrity and REQ-010 session isolation tests.
# These tests run unconditionally (no pyFileCount gate) in all non-cache lanes.
# NDJSON rows produced:
#   self.entry.req011.crossdir  - REQ-011.1 and REQ-011.3: cross-dir arg is rejected immediately with exit 1,
#                                 the message and state error
#   self.entry.req011.sameDir   - REQ-011: same-dir arg must succeed
#   self.entry.req011.case      - REQ-011.2: the same folder spelled in other letter case is accepted
#   self.isolation.req010.pythonpath - REQ-010: PYTHONPATH cleared before Python subprocess
param()
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent $here
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

# Pre-initialize pass flags so finally/allPass always has a defined value.
$passC   = $false
$passD   = $false
$passE   = $false
$pass010 = $false

# ===== REQ-011: cross-dir explicit arg must abort (negative test) =====
# Verifies that the early pre-flight check in run_setup.bat rejects an argument
# whose parent directory does not match the bootstrapper directory.
# Boot dir has no .py files; the early check fires before the no_python_files path.
$crossBoot = Join-Path $here '~entryC_boot'
$crossExt  = Join-Path $here '~entryC_ext'
try {
    foreach ($d in @($crossBoot, $crossExt)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $crossBoot -Force
    $extPy = Join-Path $crossExt 'external.py'
    Set-Content -LiteralPath $extPy -Value 'print("external")' -Encoding Ascii -NoNewline

    Push-Location -LiteralPath $crossBoot
    try {
        cmd /c ".\run_setup.bat `"$extPy`"" *> '~entryC_bootstrap.log'
        $exitC = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $logCPath = Join-Path $crossBoot '~entryC_bootstrap.log'
    $logCText = if (Test-Path -LiteralPath $logCPath) { Get-Content $logCPath -Raw -Encoding Ascii } else { '' }
    $req011InLog = [bool]($logCText -match 'REQ-011')
    # REQ-011.1 names the whole message and exit code 1; REQ-011.3 names the status state. The check
    # of REQ-002.6 comes after this one, so a file from another folder must not get the usage text.
    $fullMessage = $logCText.Contains('[ERROR] REQ-011: Dragged files must reside in the bootstrapper root folder for environment cleanliness.')
    $noUsageText = -not $logCText.Contains('Usage: run_setup.bat')
    $statusCPath = Join-Path $crossBoot '~bootstrap.status.json'
    $statusCState = ''
    if (Test-Path -LiteralPath $statusCPath) {
        try { $statusCState = [string]((Get-Content -LiteralPath $statusCPath -Raw -Encoding Ascii) | ConvertFrom-Json).state } catch { $statusCState = 'unparseable' }
    }
    $passC = ($exitC -eq 1) -and $req011InLog -and $fullMessage -and $noUsageText -and ($statusCState -eq 'error')

    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.crossdir'
        req     = 'REQ-011.1, REQ-011.3'
        pass    = $passC
        desc    = 'REQ-011: cross-dir file argument must abort bootstrap (early pre-flight rejection): exit 1, the full message, state error'
        details = [ordered]@{ exitCode = $exitC; req011InLog = $req011InLog; fullMessage = $fullMessage; noUsageText = $noUsageText; statusState = $statusCState }
    })
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.crossdir'
        req     = 'REQ-011.1, REQ-011.3'
        pass    = $false
        desc    = 'REQ-011: cross-dir test threw an exception'
        details = [ordered]@{ error = $_.Exception.Message }
    })
}

# ===== REQ-011: same-dir explicit arg must succeed (positive test) =====
# With HP_CI_SKIP_ENV=1 (inherited), the bootstrap uses system Python to run the entry.
# The early check passes because %~dp1 == %~dp0, so bootstrap continues normally.
$sameDir = Join-Path $here '~entryD_boot'
try {
    if (Test-Path -LiteralPath $sameDir) { Remove-Item -LiteralPath $sameDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $sameDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $sameDir -Force
    Set-Content -LiteralPath (Join-Path $sameDir 'direct.py') -Value 'print("direct")' -Encoding Ascii -NoNewline

    Push-Location -LiteralPath $sameDir
    try {
        cmd /c '.\run_setup.bat ".\direct.py"' *> '~entryD_bootstrap.log'
        $exitD = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $setupDPath = Join-Path $sameDir '~setup.log'
    $setupDText = if (Test-Path -LiteralPath $setupDPath) { Get-Content $setupDPath -Raw -Encoding Ascii } else { '' }
    $entryInLog = [bool]($setupDText -match 'direct\.py')
    $req011InLogD = [bool]($setupDText -match 'REQ-011')
    $passD = $entryInLog -and (-not $req011InLogD)

    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.sameDir'
        req     = 'REQ-011'
        pass    = $passD
        desc    = 'REQ-011: same-dir file argument must succeed (early check passes, bootstrap continues)'
        details = [ordered]@{ exitCode = $exitD; entryInLog = $entryInLog; req011InLog = $req011InLogD }
    })
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.sameDir'
        req     = 'REQ-011'
        pass    = $false
        desc    = 'REQ-011: same-dir test threw an exception'
        details = [ordered]@{ error = $_.Exception.Message }
    })
}

# ===== REQ-011.2: the same folder in other letter case is the same folder (positive test) =====
# The dragged file's folder is written in capitals; the file system finds it, the comparison with the
# folder of run_setup.bat must not tell them apart. A rejected argument prints the REQ-011 message and
# exits 1. This run uses HP_CI_SKIP_ENV, whose entry step ignores the argument by design (:ci_skip_entry
# picks its own file), so the row proves the pre-flight comparison only: what is chosen as the entry is
# the business of REQ-002.3 (self.entry.override), not of this shall. The first version of this row
# also required the dragged file to be chosen, which this mode never does (run 42409621915, every lane).
$caseDir = Join-Path $here '~entryE_boot'
try {
    if (Test-Path -LiteralPath $caseDir) { Remove-Item -LiteralPath $caseDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $caseDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $caseDir -Force
    Set-Content -LiteralPath (Join-Path $caseDir 'direct.py') -Value 'print("direct")' -Encoding Ascii -NoNewline
    $realArg = (Join-Path $caseDir 'direct.py')
    $upperArg = (Join-Path $caseDir.ToUpperInvariant() 'direct.py')
    # The premise: the spelling really differs from the folder's own, and only in letter case.
    $caseSpellingDiffers = ($upperArg -cne $realArg) -and ($upperArg -ieq $realArg)

    Push-Location -LiteralPath $caseDir
    try {
        cmd /c ".\run_setup.bat `"$upperArg`"" *> '~entryE_bootstrap.log'
        $exitE = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $logEPath = Join-Path $caseDir '~entryE_bootstrap.log'
    $logEText = if (Test-Path -LiteralPath $logEPath) { Get-Content $logEPath -Raw -Encoding Ascii } else { '' }
    $setupEPath = Join-Path $caseDir '~setup.log'
    $setupEText = if (Test-Path -LiteralPath $setupEPath) { Get-Content $setupEPath -Raw -Encoding Ascii } else { '' }
    $caseAll = $logEText + "`n" + $setupEText
    $caseRejected = $caseAll.Contains('Dragged files must reside')
    # The pre-flight comparison comes before the skip-mode entry step, so this line is written only after the
    # argument was accepted; without it an early stop for another reason would also read as "not rejected".
    $casePastPreflight = $setupEText.Contains('CI self-test: skipping environment bootstrap')
    $passE = ($exitE -eq 0) -and $caseSpellingDiffers -and $casePastPreflight -and (-not $caseRejected)

    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.case'
        req     = 'REQ-011.2'
        pass    = $passE
        desc    = 'REQ-011: a dragged file whose folder is written in other letter case is accepted as the same folder'
        details = [ordered]@{ exitCode = $exitE; argument = $upperArg; spellingDiffers = $caseSpellingDiffers; pastPreflight = $casePastPreflight; rejected = $caseRejected }
    })
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.case'
        req     = 'REQ-011.2'
        pass    = $false
        desc    = 'REQ-011: letter-case test threw an exception'
        details = [ordered]@{ error = $_.Exception.Message }
    })
}

# ===== REQ-010: PYTHONPATH cleared before Python subprocess runs =====
# Injects a poison marker into PYTHONPATH, then bootstraps a script that records
# the env var value. Verifies run_setup.bat cleared PYTHONPATH before Python ran.
# With HP_CI_SKIP_ENV=1 (inherited), system Python executes the entry script.
$req010Root     = Join-Path $here '~req010_test'
$prevPythonPath = $env:PYTHONPATH
try {
    if (Test-Path -LiteralPath $req010Root) { Remove-Item -LiteralPath $req010Root -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $req010Root | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $req010Root -Force

    $entryContent = @'
import os
pythonpath = os.environ.get('PYTHONPATH', '')
pythonhome = os.environ.get('PYTHONHOME', '')
with open('~isolation_check.txt', 'w') as fh:
    fh.write('PYTHONPATH={}\nPYTHONHOME={}\n'.format(pythonpath, pythonhome))
'@
    Set-Content -LiteralPath (Join-Path $req010Root 'isolation_check.py') -Value $entryContent -Encoding Ascii

    $env:PYTHONPATH = 'C:\req010_poison_marker'

    Push-Location -LiteralPath $req010Root
    try {
        cmd /c .\run_setup.bat *> '~req010_bootstrap.log'
        $exit010 = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $checkPath = Join-Path $req010Root '~isolation_check.txt'
    if (-not (Test-Path -LiteralPath $checkPath)) {
        $pass010 = $false
        $checkText = 'FILE_NOT_CREATED'
        $pythonpathCleared = $false
    } else {
        $checkText = Get-Content -LiteralPath $checkPath -Raw -Encoding Ascii
        $ppLine = ($checkText -split '\r?\n' | Where-Object { $_ -match '^PYTHONPATH=' } | Select-Object -First 1)
        $pythonpathCleared = $ppLine -eq 'PYTHONPATH='
        $pass010 = $pythonpathCleared
    }

    Write-NdjsonRow ([ordered]@{
        id      = 'self.isolation.req010.pythonpath'
        req     = 'REQ-010.1'
        pass    = $pass010
        desc    = 'REQ-010: PYTHONPATH is cleared before Python subprocesses run'
        details = [ordered]@{ exitCode = $exit010; pythonpathCleared = $pythonpathCleared }
    })
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.isolation.req010.pythonpath'
        req     = 'REQ-010.1'
        pass    = $false
        desc    = 'REQ-010: isolation test threw an exception'
        details = [ordered]@{ error = $_.Exception.Message }
    })
} finally {
    if ($null -eq $prevPythonPath) {
        Remove-Item -Path 'env:PYTHONPATH' -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONPATH = $prevPythonPath
    }
}

$allPass = $passC -and $passD -and $passE -and $pass010
if (-not $allPass) { exit 1 }
exit 0
