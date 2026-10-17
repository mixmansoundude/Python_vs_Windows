# ASCII only
# selfapps_entryarg.ps1 - CLAUDE.md Active Backlog Item 67: the first argument of run_setup.bat
# must be an existing .py file in the bootstrapper folder (as typed, or with .py appended).
#
# Field symptom (2026-08-31): `run_setup.bat arg1 arg2` (the entry file forgotten) reported
# "compile errors" for a file that runs fine, and a working EXE was deleted. Mechanism before
# the fix: :determine_entry took any EXISTING first argument as the entry (a .csv or .pdf
# passed first became the "entry") and silently ignored a first argument that did not exist,
# while the forwarded program arguments always start at %2, so the cached-EXE fast path
# launched the good EXE with the wrong arguments, saw it fail fast, and discarded it.
#
# One real bootstrap builds a tiny two-file app (main.py and entry.py; both exit 2 when they
# receive any argument, which is what makes the old behaviour destroy the EXE), then the
# remaining runs drive the cached-EXE path with bad first arguments:
#   self.entryarg.noext      - run 1: `run_setup.bat entry` (no extension) while main.py also
#                              exists; entry.py must be chosen, not main.py by auto-detection
#   self.entryarg.csv        - run 2: first argument is an existing non-Python file: stop with a
#                              usage message, EXE untouched
#   self.entryarg.missing    - run 3: `arg1 arg2` (the 2026-08-31 command): stop, EXE untouched,
#                              no "discarding cached EXE"
#   self.entryarg.wildcard   - run 4: `*` (a wildcard matches every file, so it must never be
#                              taken as a name): stop, EXE untouched
#   self.entryarg.directory  - a folder named folder.py exists: `folder.py` and `folder` must be
#                              rejected like any other non-file (if exist is true for a folder, so a
#                              folder would otherwise be taken as the entry), EXE untouched
#   self.entryarg.stops_release_lock - run 5 is a cross-folder file (the REQ-011 stop), run 6 is
#                              `entry` again and must reuse the EXE: proves every early stop
#                              releases the REQ-024 lock
#
# Lane: real only (gating). The check runs before provider selection, so one lane is enough and
# conda-full (the slowest lane) is not lengthened.
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

# derived requirement: tools/check_ndjson_registry.py finds a row id only as a quoted string
# right after the id key or the -Id parameter, so every call site below spells the id out in
# quotes and never passes a variable.
function Write-EntryArgRow {
    param([string]$Id, [bool]$Pass, [string]$Desc, $Details)
    Write-NdjsonRow ([ordered]@{
        id      = $Id
        req     = 'REQ-002'
        pass    = $Pass
        desc    = $Desc
        details = $Details
    })
}

# Non-Windows skip (OSVersion.Platform works under pwsh and Windows PowerShell 5.1; $IsWindows does not).
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $skipDetails = [ordered]@{ skip = $true; platform = [System.Environment]::OSVersion.Platform.ToString(); reason = 'non-windows-host' }
    Write-EntryArgRow -Id 'self.entryarg.noext' -Pass $true -Desc 'First argument without .py (skipped on non-Windows)' -Details $skipDetails
    Write-EntryArgRow -Id 'self.entryarg.csv' -Pass $true -Desc 'First argument that is not a .py file stops the run (skipped on non-Windows)' -Details $skipDetails
    Write-EntryArgRow -Id 'self.entryarg.missing' -Pass $true -Desc 'First argument that is not a file stops the run (skipped on non-Windows)' -Details $skipDetails
    Write-EntryArgRow -Id 'self.entryarg.wildcard' -Pass $true -Desc 'Wildcard first argument stops the run (skipped on non-Windows)' -Details $skipDetails
    Write-EntryArgRow -Id 'self.entryarg.directory' -Pass $true -Desc 'A folder as first argument stops the run (skipped on non-Windows)' -Details $skipDetails
    Write-EntryArgRow -Id 'self.entryarg.stops_release_lock' -Pass $true -Desc 'Early stops release the lock (skipped on non-Windows)' -Details $skipDetails
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    $missingDetails = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    Write-EntryArgRow -Id 'self.entryarg.noext' -Pass $false -Desc 'First argument without .py: run_setup.bat not found' -Details $missingDetails
    Write-EntryArgRow -Id 'self.entryarg.csv' -Pass $false -Desc 'First argument that is not a .py file: run_setup.bat not found' -Details $missingDetails
    Write-EntryArgRow -Id 'self.entryarg.missing' -Pass $false -Desc 'First argument that is not a file: run_setup.bat not found' -Details $missingDetails
    Write-EntryArgRow -Id 'self.entryarg.wildcard' -Pass $false -Desc 'Wildcard first argument: run_setup.bat not found' -Details $missingDetails
    Write-EntryArgRow -Id 'self.entryarg.directory' -Pass $false -Desc 'A folder as first argument: run_setup.bat not found' -Details $missingDetails
    Write-EntryArgRow -Id 'self.entryarg.stops_release_lock' -Pass $false -Desc 'Early stops release the lock: run_setup.bat not found' -Details $missingDetails
    exit 1
}

$workDir = Join-Path $here '~selftest_entryarg'
$extDir  = Join-Path $here '~selftest_entryarg_ext'
foreach ($d in @($workDir, $extDir)) {
    if (Test-Path $d) { Remove-Item -Recurse -Force $d }
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}
Copy-Item -Path $batchPath -Destination $workDir -Force

# Both programs exit 2 when handed ANY argument: a good EXE launched with a stray argument
# fails fast, which is exactly what made the old fast path discard it.
Set-Content -Path (Join-Path $workDir 'main.py') -Value @'
import sys
if len(sys.argv) > 1:
    print("main-got-args")
    sys.exit(2)
print("from-main")
'@ -Encoding ASCII
Set-Content -Path (Join-Path $workDir 'entry.py') -Value @'
import sys
if len(sys.argv) > 1:
    print("entry-got-args")
    sys.exit(2)
print("hello-entryarg")
'@ -Encoding ASCII
Set-Content -Path (Join-Path $workDir 'data.csv') -Value "a,b`n1,2" -Encoding ASCII
Set-Content -Path (Join-Path $extDir 'external.py') -Value 'print("external")' -Encoding ASCII

$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevLane        = if (Test-Path Env:HP_CI_LANE) { $env:HP_CI_LANE } else { $null }
$env:HP_SKIP_PIPREQS = '1'
# A real stop pauses for a keypress unless HP_CI_LANE is set (CI sets it); never hang a local run.
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'test' }

function Read-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
    if ($null -eq $t) { return '' }
    return $t
}

# derived requirement: ~setup.log is only rotated past 10 MB, so it keeps growing across runs in
# one folder. Every per-run check therefore reads only the bytes this run appended (offset taken
# before the run), or an earlier run's "Fast path" or "discarding cached EXE" line would be seen as
# this run's.
function Read-AppendedText {
    param([string]$Path, [long]$Offset)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -le $Offset) { return '' }
    return [System.Text.Encoding]::ASCII.GetString($bytes, [int]$Offset, [int]($bytes.Length - $Offset))
}

# Runs run_setup.bat with the given argument text, keeps the console capture and this run's slice of
# ~setup.log under per-run names, and returns the facts.
function Invoke-EntryRun {
    param([string]$BatArgs, [string]$Tag)
    $consoleName = "~entryarg_$Tag.log"
    $setupSrc = Join-Path $workDir '~setup.log'
    $setupOffset = 0
    if (Test-Path -LiteralPath $setupSrc) { $setupOffset = (Get-Item -LiteralPath $setupSrc).Length }
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat $BatArgs > $consoleName 2>&1"
        $rc = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $setupText = Read-AppendedText -Path $setupSrc -Offset $setupOffset
    Set-Content -LiteralPath (Join-Path $workDir "~entryarg_${Tag}_setup.log") -Value $setupText -Encoding ASCII
    $statusState = ''
    $statusPath = Join-Path $workDir '~bootstrap.status.json'
    if (Test-Path -LiteralPath $statusPath) {
        try { $statusState = [string]((Read-Text $statusPath) | ConvertFrom-Json).state } catch { $statusState = 'unparseable' }
    }
    return [pscustomobject]@{
        Exit    = $rc
        Console = (Read-Text (Join-Path $workDir $consoleName))
        Setup   = $setupText
        State   = $statusState
        Log     = $consoleName
    }
}

function Get-ExeFacts {
    $dist = Join-Path $workDir 'dist'
    $exe = $null
    if (Test-Path -LiteralPath $dist) {
        $exe = Get-ChildItem -LiteralPath $dist -Filter *.exe -File | Select-Object -First 1
    }
    if (-not $exe) { return [pscustomobject]@{ Exists = $false; Path = ''; Sha = ''; Ticks = 0 } }
    return [pscustomobject]@{
        Exists = $true
        Path   = $exe.FullName
        Sha    = (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash
        Ticks  = $exe.LastWriteTimeUtc.Ticks
    }
}

function Test-ExeUntouched {
    param($Before)
    $now = Get-ExeFacts
    return ($Before.Exists -and $now.Exists -and ($now.Path -eq $Before.Path) -and ($now.Sha -eq $Before.Sha) -and ($now.Ticks -eq $Before.Ticks))
}

$usagePhrase    = 'Usage: run_setup.bat your_script.py'
$discardPhrase  = 'discarding cached EXE'
$fastPathPhrase = 'Fast path'
$allPass = $true

try {
    # ---- Run 1: `entry` without .py; main.py would win auto-detection by name ----
    $r1 = Invoke-EntryRun -BatArgs 'entry' -Tag 'run1'
    $runOut1 = Read-Text (Join-Path $workDir '~run.out.txt')
    $exe1 = Get-ExeFacts
    $r1Hello    = $runOut1 -match 'hello-entryarg'
    $r1NotMain  = -not ($runOut1 -match 'from-main')
    $r1Selected = ($r1.Setup -match [regex]::Escape('[BOOT] REQ-002: Entry selected:')) -and ($r1.Setup -match 'entry\.py')
    $r1Resolved = ($r1.Console + "`n" + $r1.Setup) -match [regex]::Escape('first argument had no .py extension')
    $pass1 = ($r1.Exit -eq 0) -and $exe1.Exists -and $r1Hello -and $r1NotMain -and $r1Selected -and $r1Resolved
    if (-not $pass1) { $allPass = $false }
    Write-EntryArgRow -Id 'self.entryarg.noext' -Pass $pass1 -Desc 'run_setup.bat entry (no .py) chooses entry.py over main.py; the .py is appended' -Details ([ordered]@{
        exit = $r1.Exit; exeBuilt = $exe1.Exists; helloEntry = $r1Hello; notMain = $r1NotMain
        entrySelected = $r1Selected; resolvedMsg = $r1Resolved; log = $r1.Log
    })

    $exeBase = Get-ExeFacts

    # ---- Run 2: first argument is an existing non-Python file ----
    $r2 = Invoke-EntryRun -BatArgs 'data.csv' -Tag 'run2'
    $c2 = $r2.Console + "`n" + $r2.Setup
    $r2Usage     = $r2.Console -match [regex]::Escape($usagePhrase)
    $r2Untouched = Test-ExeUntouched $exeBase
    $r2NoFast    = -not ($c2 -match [regex]::Escape($fastPathPhrase)) -and -not ($c2 -match [regex]::Escape($discardPhrase))
    $pass2 = $exeBase.Exists -and ($r2.Exit -eq 1) -and $r2Usage -and ($r2.State -eq 'error') -and $r2Untouched -and $r2NoFast
    if (-not $pass2) { $allPass = $false }
    Write-EntryArgRow -Id 'self.entryarg.csv' -Pass $pass2 -Desc 'A first argument that exists but is not a .py file stops the run with a usage message and leaves the EXE alone' -Details ([ordered]@{
        exit = $r2.Exit; usage = $r2Usage; status = $r2.State; exeUntouched = $r2Untouched; noFastPath = $r2NoFast
        exeBuilt = $exeBase.Exists; log = $r2.Log
    })

    # ---- Run 3: the 2026-08-31 command, entry file forgotten ----
    $r3 = Invoke-EntryRun -BatArgs 'arg1 arg2' -Tag 'run3'
    $c3 = $r3.Console + "`n" + $r3.Setup
    $r3Usage     = $r3.Console -match [regex]::Escape($usagePhrase)
    $r3Untouched = Test-ExeUntouched $exeBase
    $r3NoDiscard = -not ($c3 -match [regex]::Escape($discardPhrase))
    $r3NoFast    = -not ($c3 -match [regex]::Escape($fastPathPhrase))
    $pass3 = $exeBase.Exists -and ($r3.Exit -eq 1) -and $r3Usage -and ($r3.State -eq 'error') -and $r3Untouched -and $r3NoDiscard -and $r3NoFast
    if (-not $pass3) { $allPass = $false }
    Write-EntryArgRow -Id 'self.entryarg.missing' -Pass $pass3 -Desc 'run_setup.bat arg1 arg2 (no entry file) stops with a usage message; the good EXE is not run with wrong arguments or discarded' -Details ([ordered]@{
        exit = $r3.Exit; usage = $r3Usage; status = $r3.State; exeUntouched = $r3Untouched
        noDiscard = $r3NoDiscard; noFastPath = $r3NoFast; exeBuilt = $exeBase.Exists; log = $r3.Log
    })

    # ---- Run 4: a wildcard must never be taken as a file name ----
    $r4 = Invoke-EntryRun -BatArgs '*' -Tag 'run4'
    $c4 = $r4.Console + "`n" + $r4.Setup
    $r4Usage     = $r4.Console -match [regex]::Escape($usagePhrase)
    $r4Untouched = Test-ExeUntouched $exeBase
    $r4NoFast    = -not ($c4 -match [regex]::Escape($fastPathPhrase)) -and -not ($c4 -match [regex]::Escape($discardPhrase))
    $pass4 = $exeBase.Exists -and ($r4.Exit -eq 1) -and $r4Usage -and ($r4.State -eq 'error') -and $r4Untouched -and $r4NoFast
    if (-not $pass4) { $allPass = $false }
    Write-EntryArgRow -Id 'self.entryarg.wildcard' -Pass $pass4 -Desc 'A wildcard first argument is rejected like any other non-file, never expanded to match a file' -Details ([ordered]@{
        exit = $r4.Exit; usage = $r4Usage; status = $r4.State; exeUntouched = $r4Untouched; noFastPath = $r4NoFast
        exeBuilt = $exeBase.Exists; log = $r4.Log
    })

    # ---- A folder named like a script: `if exist` is true for a folder, so it must be screened out ----
    # The folder exists only for these two runs, so run 5 and 6 see the same folder as before.
    $dirPath = Join-Path $workDir 'folder.py'
    New-Item -ItemType Directory -Force -Path $dirPath | Out-Null
    try {
        $rd1 = Invoke-EntryRun -BatArgs 'folder.py' -Tag 'dir1'
        $rd2 = Invoke-EntryRun -BatArgs 'folder' -Tag 'dir2'
    } finally {
        Remove-Item -LiteralPath $dirPath -Recurse -Force -ErrorAction SilentlyContinue
    }
    $cd1 = $rd1.Console + "`n" + $rd1.Setup
    $cd2 = $rd2.Console + "`n" + $rd2.Setup
    $rd1Usage = $rd1.Console -match [regex]::Escape($usagePhrase)
    $rd2Usage = $rd2.Console -match [regex]::Escape($usagePhrase)
    $rdUntouched = Test-ExeUntouched $exeBase
    $rdNoFast = -not ($cd1 -match [regex]::Escape($fastPathPhrase)) -and -not ($cd2 -match [regex]::Escape($fastPathPhrase))
    $passDir = $exeBase.Exists -and ($rd1.Exit -eq 1) -and ($rd2.Exit -eq 1) -and $rd1Usage -and $rd2Usage -and ($rd1.State -eq 'error') -and ($rd2.State -eq 'error') -and $rdUntouched -and $rdNoFast
    if (-not $passDir) { $allPass = $false }
    Write-EntryArgRow -Id 'self.entryarg.directory' -Pass $passDir -Desc 'A first argument that names a folder (folder.py, or folder) is rejected like any other non-file and leaves the EXE alone' -Details ([ordered]@{
        dotPyExit = $rd1.Exit; dotPyUsage = $rd1Usage; dotPyStatus = $rd1.State
        bareExit = $rd2.Exit; bareUsage = $rd2Usage; bareStatus = $rd2.State
        exeUntouched = $rdUntouched; noFastPath = $rdNoFast; exeBuilt = $exeBase.Exists; log1 = $rd1.Log; log2 = $rd2.Log
    })

    # ---- Run 5: cross-folder file (REQ-011 stop), then run 6: a normal run must not meet a stale lock ----
    $extPy = Join-Path $extDir 'external.py'
    # Quoted: cmd /c would split a checkout path that holds a space and test the wrong input.
    $r5 = Invoke-EntryRun -BatArgs ('"' + $extPy + '"') -Tag 'run5'
    $r5Req011 = ($r5.Console + "`n" + $r5.Setup) -match 'REQ-011'
    $r6 = Invoke-EntryRun -BatArgs 'entry' -Tag 'run6'
    $c6 = $r6.Console + "`n" + $r6.Setup
    $r6NoLock    = -not ($c6 -match 'REQ-024')
    $r6Fast      = $c6 -match [regex]::Escape('Fast path: reusing')
    $r6Untouched = Test-ExeUntouched $exeBase
    $pass5 = $exeBase.Exists -and ($r5.Exit -eq 1) -and $r5Req011 -and ($r6.Exit -eq 0) -and $r6NoLock -and $r6Fast -and $r6Untouched
    if (-not $pass5) { $allPass = $false }
    Write-EntryArgRow -Id 'self.entryarg.stops_release_lock' -Pass $pass5 -Desc 'After an early argument stop, the next run in the same folder does not meet a stale lock and reuses the EXE' -Details ([ordered]@{
        run5Exit = $r5.Exit; run5Req011 = $r5Req011; run6Exit = $r6.Exit; run6NoLockMessage = $r6NoLock
        run6FastPath = $r6Fast; exeUntouched = $r6Untouched; exeBuilt = $exeBase.Exists; run5Log = $r5.Log; run6Log = $r6.Log
    })
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevLane) { Remove-Item Env:HP_CI_LANE -ErrorAction SilentlyContinue } else { $env:HP_CI_LANE = $prevLane }
}

if (-not $allPass) { exit 1 }
exit 0
