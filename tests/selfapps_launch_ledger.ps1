# ASCII only
# selfapps_launch_ledger.ps1 - launch ledger (docs/plan-test-suite-gaps.md gap T1, slices A to E).
#
# Nothing in the suite observed WHERE and HOW OFTEN the user's program really runs. A stub program
# appends one JSON line per launch to ~ledger.jsonl in its working directory, recording its argv,
# whether it is frozen, its interpreter, and PYTHONHOME. The scenarios then count and compare:
#
#   A  fresh folder, run_setup.bat ledger_app.py "a b" "" c d e f g h i
#        REQ-026: positions 2 to 9 are forwarded, an explicitly empty one is dropped, the 10th is
#        ignored, so the EXE smoke run must see exactly ["a b","c","d","e","f","g","h"].
#        REQ-018: mandatory verification runs the user's code exactly once, so exactly one line.
#   B  same folder again: the cached-EXE fast path launches the EXE with the same argv (one more line).
#   C  fresh folder with PyInstaller and Nuitka forced to fail (interpreter verification). REQ-026 on the
#        interpreter launch site, plus REQ-010: a poisoned PYTHONHOME must be cleared before anything
#        runs, and a decoy python.cmd first on PATH must never be run (every call is interpreter-anchored).
#   D  fresh folder with HP_TEST_CHECKPOINT_ANSWER=Y: the elective second run adds exactly one more line,
#        launched through the interpreter, with the same argv.
#   E  fresh folder, run_setup.bat ledger_app.py with no program arguments: the EXE smoke run gets none (an
#        empty argument must not turn into an argv element).
#
# The ledger is written by the program itself, so unlike the log-line counts the older tests use, a
# second launch that logs nothing is still seen. The batch is invoked through a generated ~ledger_launch.cmd
# so the quoting (including the empty argument) is exactly what a user typing it would produce.
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py
# scans text, not PowerShell). The skip loop below uses a variable id on purpose; the real emissions are literal.
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"). The provider-prefix check
# assumes a uv environment, so it skips itself in conda-full (HP_FORCE_CONDA_ONLY=1).
#
# Emits: self.launch.argv.fresh, self.launch.argv.cap, self.launch.count.default, self.launch.argv.fastpath,
#        self.launch.argv.interpreter, self.isolation.req010.pythonhome, self.isolation.req010.path_shadow,
#        self.launch.count.checkpoint, self.launch.argv.checkpoint, self.launch.argv.none
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

$allIds = @(
    'self.launch.argv.fresh', 'self.launch.argv.cap', 'self.launch.count.default',
    'self.launch.argv.fastpath', 'self.launch.argv.interpreter',
    'self.isolation.req010.pythonhome', 'self.isolation.req010.path_shadow',
    'self.launch.count.checkpoint', 'self.launch.argv.checkpoint', 'self.launch.argv.none'
)

$reqOf = @{
    'self.launch.argv.fresh' = 'REQ-026.1'; 'self.launch.argv.cap' = 'REQ-026.5'; 'self.launch.count.default' = 'REQ-018'
    'self.launch.argv.fastpath' = 'REQ-026.2'; 'self.launch.argv.interpreter' = 'REQ-026.3'
    'self.isolation.req010.pythonhome' = 'REQ-010'; 'self.isolation.req010.path_shadow' = 'REQ-010'
    'self.launch.count.checkpoint' = 'REQ-018'; 'self.launch.argv.checkpoint' = 'REQ-026.4'; 'self.launch.argv.none' = 'REQ-026.6'
}

function Write-AllRows {
    param([bool]$Pass, [string]$Desc, [hashtable]$Details)
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = $reqOf[$rowId]; pass = $Pass; desc = $Desc; details = $Details })
    }
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Desc 'Launch ledger (skipped on non-Windows)' -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}
if ($env:HP_FORCE_CONDA_ONLY -eq '1') {
    Write-AllRows -Pass $true -Desc 'Launch ledger (skipped: HP_FORCE_CONDA_ONLY, the prefix check assumes uv)' -Details ([ordered]@{ skip = $true; reason = 'HP_FORCE_CONDA_ONLY' })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-AllRows -Pass $false -Desc 'Launch ledger: run_setup.bat not found' -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# --- helpers (pure; exercised by the self-check below so a vacuous comparator fails every run) ---
$US = [string][char]31
function Test-ArgvEqual {
    param($Actual, [string[]]$Expected)
    $a = @($Actual | ForEach-Object { [string]$_ })
    $e = @($Expected)
    if ($a.Count -ne $e.Count) { return $false }
    return (($a -join $US) -ceq ($e -join $US))
}

function Read-Ledger {
    param([string]$Dir)
    $path = Join-Path $Dir '~ledger.jsonl'
    $out = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $path) {
        foreach ($line in (Get-Content -LiteralPath $path -Encoding ASCII)) {
            if ($line.Trim().Length -eq 0) { continue }
            try { [void]$out.Add(($line | ConvertFrom-Json)) } catch { [void]$out.Add([pscustomobject]@{ parseError = $line }) }
        }
    }
    return ,$out.ToArray()
}

function Find-StrayLedger {
    param([string]$Dir)
    @(Get-ChildItem -LiteralPath $Dir -Recurse -Filter '~ledger.jsonl' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}

function Invoke-LedgerBootstrap {
    param([string]$Dir, [string]$ArgLine, [string]$LogName)
    $wrapper = Join-Path $Dir '~ledger_launch.cmd'
    Set-Content -LiteralPath $wrapper -Value @('@echo off', "call run_setup.bat $ArgLine > $LogName 2>&1", 'exit /b %ERRORLEVEL%') -Encoding ASCII
    Push-Location -LiteralPath $Dir
    try {
        cmd /c "call ~ledger_launch.cmd" | Out-Null
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

function Set-TestEnv {
    param([System.Collections.IDictionary]$Vars)
    $saved = @{}
    foreach ($k in @($Vars.Keys)) {
        $saved[$k] = [Environment]::GetEnvironmentVariable($k)
        [Environment]::SetEnvironmentVariable($k, $Vars[$k])
    }
    return $saved
}

function Restore-TestEnv {
    param([hashtable]$Saved)
    foreach ($k in @($Saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $Saved[$k]) }
}

function New-LedgerFolder {
    param([string]$Name)
    $dir = Join-Path $here $Name
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -Path $batchPath -Destination $dir -Force
    Set-Content -Path (Join-Path $dir 'ledger_app.py') -Value $ledgerApp -Encoding ASCII
    return $dir
}

function Show-Evidence {
    param([string]$Title, [string]$Dir, [string]$LogName)
    Write-Host ("=== launch ledger evidence: {0} ===" -f $Title)
    $raw = Join-Path $Dir '~ledger.jsonl'
    if (Test-Path -LiteralPath $raw) { Get-Content -LiteralPath $raw -Encoding ASCII | ForEach-Object { Write-Host ("ledger: " + $_) } } else { Write-Host 'ledger: (no ~ledger.jsonl in the app folder)' }
    $log = Join-Path $Dir $LogName
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Encoding ASCII | Where-Object { $_ -match 'REQ-026|REQ-018|REQ-012|Fast path|Entry smoke|checkpoint|\[ERROR\]|\[WARN\] (PyInstaller|Nuitka)|HP_TEST' } | Select-Object -First 40 | ForEach-Object { Write-Host $_ }
    } else { Write-Host ("log missing: " + $LogName) }
}

$ledgerApp = @'
import json
import os
import sys

rec = {
    "argv": sys.argv[1:],
    "frozen": bool(getattr(sys, "frozen", False)),
    "prefix": sys.prefix,
    "executable": sys.executable,
    "pythonhome": os.environ.get("PYTHONHOME", ""),
    "cwd": os.getcwd(),
}
with open("~ledger.jsonl", "a") as f:
    f.write(json.dumps(rec) + "\n")
print("ledger-ok")
'@

# REQ-026.5: positions 2 to 9 are forwarded, the explicitly empty one ("") is dropped, the 10th ("i") is ignored.
$expectedArgv = @('a b', 'c', 'd', 'e', 'f', 'g', 'h')
$argLine = 'ledger_app.py "a b" "" c d e f g h i'
# REQ-026.6: a run without program arguments records an EMPTY argv.
$expectedNone = @()

# Self-check: the comparator must be able to fail, or every argv row below would be vacuous.
$comparatorOk = (Test-ArgvEqual @('a b', 'c') @('a b', 'c')) -and
    (-not (Test-ArgvEqual @('a b', 'c') @('a', 'b', 'c'))) -and
    (-not (Test-ArgvEqual @('a b', 'c', 'h') @('a b', 'c'))) -and
    (-not (Test-ArgvEqual @() @('a b'))) -and
    (Test-ArgvEqual @() @())

# Defaults every scenario shares: skip the dependency scan (stdlib-only stub), never prompt.
$baseEnv = [ordered]@{ HP_SKIP_PIPREQS = '1' }
if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $baseEnv['HP_CI_LANE'] = 'test' }

$failed = $false

# ---------------------------------------------------------------- Scenario A and B
$dirA = New-LedgerFolder -Name '~selftest_launch_ledger_a'
$savedA = Set-TestEnv $baseEnv
try {
    $exitA = Invoke-LedgerBootstrap -Dir $dirA -ArgLine $argLine -LogName '~ledger_a.log'
    $linesA = Read-Ledger -Dir $dirA
    $strayA = Find-StrayLedger -Dir $dirA
    Show-Evidence -Title 'A fresh build' -Dir $dirA -LogName '~ledger_a.log'

    $exitB = Invoke-LedgerBootstrap -Dir $dirA -ArgLine $argLine -LogName '~ledger_b.log'
    $linesB = Read-Ledger -Dir $dirA
    $logB = if (Test-Path -LiteralPath (Join-Path $dirA '~ledger_b.log')) { Get-Content -LiteralPath (Join-Path $dirA '~ledger_b.log') -Raw -Encoding ASCII } else { '' }
    Show-Evidence -Title 'B rerun (fast path)' -Dir $dirA -LogName '~ledger_b.log'
} finally {
    Restore-TestEnv $savedA
}

$a0 = if ($linesA.Count -ge 1) { $linesA[0] } else { $null }
$aFrozen = ($null -ne $a0) -and ($a0.frozen -eq $true)
$aFirstTwoOk = ($null -ne $a0) -and (@($a0.argv).Count -ge 2) -and (@($a0.argv)[0] -ceq 'a b') -and (@($a0.argv)[1] -ceq 'c')
$aFullOk = ($null -ne $a0) -and (Test-ArgvEqual $a0.argv $expectedArgv)
$aCountOk = ($linesA.Count -eq 1)

$freshPass = $comparatorOk -and $aFrozen -and $aFirstTwoOk
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.argv.fresh'; req = 'REQ-026.1'; pass = [bool]$freshPass
    desc = 'REQ-026: the EXE smoke run receives the forwarded launch arguments, an argument with a space stays one element'
    details = [ordered]@{ exitCode = $exitA; ledgerLines = $linesA.Count; frozen = $aFrozen; firstTwoOk = $aFirstTwoOk; comparatorOk = $comparatorOk; argv = if ($a0) { @($a0.argv) } else { $null }; strayLedgers = @($strayA) }
})
$capPass = $comparatorOk -and $aFullOk
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.argv.cap'; req = 'REQ-026.5'; pass = [bool]$capPass
    desc = 'REQ-026: positions 2 to 9 forwarded, an explicitly empty argument dropped, the 10th ignored'
    details = [ordered]@{ expected = $expectedArgv; argv = if ($a0) { @($a0.argv) } else { $null }; argLine = $argLine }
})
$countPass = $aCountOk
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.count.default'; req = 'REQ-018'; pass = [bool]$countPass
    desc = 'REQ-018: a default fresh bootstrap runs the user program exactly once'
    details = [ordered]@{ ledgerLines = $linesA.Count; expected = 1; exitCode = $exitA }
})

$b1 = if ($linesB.Count -ge 2) { $linesB[1] } else { $null }
$fastLogged = $logB -match [regex]::Escape('Fast path: reusing')
$bPass = ($linesB.Count -eq 2) -and ($null -ne $b1) -and ($b1.frozen -eq $true) -and (Test-ArgvEqual $b1.argv $expectedArgv) -and $fastLogged
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.argv.fastpath'; req = 'REQ-026.2'; pass = [bool]$bPass
    desc = 'REQ-026: the cached-EXE fast path launches the EXE once with the same forwarded arguments'
    details = [ordered]@{ exitCode = $exitB; ledgerLines = $linesB.Count; expectedLines = 2; fastPathLogged = [bool]$fastLogged; argv = if ($b1) { @($b1.argv) } else { $null } }
})

# ---------------------------------------------------------------- Scenario C
$dirC = New-LedgerFolder -Name '~selftest_launch_ledger_c'
$decoyDir = Join-Path $here '~selftest_launch_ledger_decoy'
if (Test-Path $decoyDir) { Remove-Item -Recurse -Force $decoyDir }
New-Item -ItemType Directory -Force -Path $decoyDir | Out-Null
$decoyMarker = Join-Path $decoyDir '~decoy_ran.txt'
foreach ($decoyName in @('python.cmd', 'py.cmd')) {
    Set-Content -LiteralPath (Join-Path $decoyDir $decoyName) -Value @('@echo off', "echo %~nx0 %* > `"$decoyMarker`"", 'exit /b 1') -Encoding ASCII
}
$poison = 'C:\hp_poison_pythonhome_does_not_exist'
$cEnv = [ordered]@{
    HP_SKIP_PIPREQS = '1'
    HP_TEST_FORCE_PYINSTALLER_FAIL = '1'
    HP_TEST_FORCE_NUITKA_FAIL = '1'
    PYTHONHOME = $poison
    PATH = $decoyDir + ';' + [Environment]::GetEnvironmentVariable('PATH')
}
if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $cEnv['HP_CI_LANE'] = 'test' }
$savedC = Set-TestEnv $cEnv
try {
    $exitC = Invoke-LedgerBootstrap -Dir $dirC -ArgLine $argLine -LogName '~ledger_c.log'
    $linesC = Read-Ledger -Dir $dirC
} finally {
    Restore-TestEnv $savedC
}
Show-Evidence -Title 'C interpreter verification (PyInstaller and Nuitka forced to fail)' -Dir $dirC -LogName '~ledger_c.log'
$c0 = if ($linesC.Count -ge 1) { $linesC[0] } else { $null }
$decoyRan = Test-Path -LiteralPath $decoyMarker
$cInProvider = ($null -ne $c0) -and ([string]$c0.executable).ToLowerInvariant().StartsWith($dirC.ToLowerInvariant())

$cArgvPass = ($linesC.Count -eq 1) -and ($null -ne $c0) -and ($c0.frozen -eq $false) -and (Test-ArgvEqual $c0.argv $expectedArgv)
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.argv.interpreter'; req = 'REQ-026.3'; pass = [bool]$cArgvPass
    desc = 'REQ-026: the interpreter verification run receives the forwarded launch arguments once'
    details = [ordered]@{ exitCode = $exitC; ledgerLines = $linesC.Count; frozen = if ($c0) { $c0.frozen } else { $null }; argv = if ($c0) { @($c0.argv) } else { $null }; executable = if ($c0) { $c0.executable } else { $null } }
})
$homePass = ($null -ne $c0) -and ([string]$c0.pythonhome -eq '')
Write-NdjsonRow ([ordered]@{
    id = 'self.isolation.req010.pythonhome'; req = 'REQ-010'; pass = [bool]$homePass
    desc = 'REQ-010: a poisoned PYTHONHOME is cleared before the user program runs'
    details = [ordered]@{ poison = $poison; seenByProgram = if ($c0) { $c0.pythonhome } else { $null }; ledgerLines = $linesC.Count }
})
$shadowPass = (-not $decoyRan) -and $cInProvider
Write-NdjsonRow ([ordered]@{
    id = 'self.isolation.req010.path_shadow'; req = 'REQ-010'; pass = [bool]$shadowPass
    desc = 'REQ-010: a decoy python.cmd first on PATH is never run; the program runs under the provider interpreter'
    details = [ordered]@{ decoyRan = $decoyRan; programRanUnderAppFolder = $cInProvider; executable = if ($c0) { $c0.executable } else { $null }; decoyDir = $decoyDir }
})

# ---------------------------------------------------------------- Scenario D
$dirD = New-LedgerFolder -Name '~selftest_launch_ledger_d'
$dEnv = [ordered]@{ HP_SKIP_PIPREQS = '1'; HP_TEST_CHECKPOINT_ANSWER = 'Y'; HP_NDJSON = $null }
if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $dEnv['HP_CI_LANE'] = 'test' }
$savedD = Set-TestEnv $dEnv
try {
    $exitD = Invoke-LedgerBootstrap -Dir $dirD -ArgLine $argLine -LogName '~ledger_d.log'
    $linesD = Read-Ledger -Dir $dirD
} finally {
    Restore-TestEnv $savedD
}
Show-Evidence -Title 'D accepted checkpoint (second run through the interpreter)' -Dir $dirD -LogName '~ledger_d.log'
$logD = if (Test-Path -LiteralPath (Join-Path $dirD '~ledger_d.log')) { Get-Content -LiteralPath (Join-Path $dirD '~ledger_d.log') -Raw -Encoding ASCII } else { '' }
$checkpointAccepted = $logD -match 'post-execution checkpoint \((exe|interpreter)\): accepted'
$d0 = if ($linesD.Count -ge 1) { $linesD[0] } else { $null }
$d1 = if ($linesD.Count -ge 2) { $linesD[1] } else { $null }
$dCountPass = ($linesD.Count -eq 2) -and $checkpointAccepted -and ($null -ne $d0) -and ($null -ne $d1) -and
    ($d0.frozen -eq $true) -and ($d1.frozen -eq $false)
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.count.checkpoint'; req = 'REQ-018'; pass = [bool]$dCountPass
    desc = 'REQ-018: an accepted post-execution checkpoint adds exactly one interpreter run after the EXE run'
    details = [ordered]@{ exitCode = $exitD; ledgerLines = $linesD.Count; expectedLines = 2; checkpointAccepted = [bool]$checkpointAccepted; firstFrozen = if ($d0) { $d0.frozen } else { $null }; secondFrozen = if ($d1) { $d1.frozen } else { $null } }
})
# REQ-026.4: the checkpoint run gets the SAME arguments as the first run, so both launches are checked (CodeRabbit, PR #494).
$dArgvPass = ($linesD.Count -eq 2) -and ($null -ne $d0) -and ($null -ne $d1) -and ($d1.frozen -eq $false) -and
    (Test-ArgvEqual $d0.argv $expectedArgv) -and (Test-ArgvEqual $d1.argv $d0.argv)
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.argv.checkpoint'; req = 'REQ-026.4'; pass = [bool]$dArgvPass
    desc = 'REQ-026: the accepted post-execution checkpoint run receives the same forwarded arguments'
    details = [ordered]@{ ledgerLines = $linesD.Count; secondFrozen = if ($d1) { $d1.frozen } else { $null }; firstArgv = if ($d0) { @($d0.argv) } else { $null }; secondArgv = if ($d1) { @($d1.argv) } else { $null }; expected = $expectedArgv }
})

# ---------------------------------------------------------------- Scenario E
$dirE = New-LedgerFolder -Name '~selftest_launch_ledger_e'
$eEnv = [ordered]@{ HP_SKIP_PIPREQS = '1' }
if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $eEnv['HP_CI_LANE'] = 'test' }
$savedE = Set-TestEnv $eEnv
try {
    $exitE = Invoke-LedgerBootstrap -Dir $dirE -ArgLine 'ledger_app.py' -LogName '~ledger_e.log'
    $linesE = Read-Ledger -Dir $dirE
} finally {
    Restore-TestEnv $savedE
}
Show-Evidence -Title 'E fresh build without program arguments' -Dir $dirE -LogName '~ledger_e.log'
$e0 = if ($linesE.Count -ge 1) { $linesE[0] } else { $null }
# derived requirement: an empty argv must be the program's own record of an empty list, so the key has to be present.
# A ledger line without it (a broken stub) would otherwise compare equal to the empty expectation.
$e0HasArgv = ($null -ne $e0) -and ($e0.PSObject.Properties.Name -contains 'argv')
$nonePass = ($linesE.Count -eq 1) -and ($null -ne $e0) -and ($e0.frozen -eq $true) -and $e0HasArgv -and (Test-ArgvEqual $e0.argv $expectedNone)
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.argv.none'; req = 'REQ-026.6'; pass = [bool]$nonePass
    desc = 'REQ-026: without program arguments the EXE smoke run starts the program with none'
    details = [ordered]@{ exitCode = $exitE; ledgerLines = $linesE.Count; frozen = if ($e0) { $e0.frozen } else { $null }; argvPresent = [bool]$e0HasArgv; argvCount = if ($e0HasArgv) { @($e0.argv).Count } else { $null }; expected = @($expectedNone) }
})

if (-not ($freshPass -and $capPass -and $countPass -and $bPass -and $cArgvPass -and $homePass -and $shadowPass -and $dCountPass -and $dArgvPass -and $nonePass)) { exit 1 }
exit 0
