# ASCII only
# selfapps_skiphooks_single.ps1 - REQ-012, each skip hook ALONE (docs/plan-test-suite-gaps.md gap T1, slice E).
#
# selfapps_skiphooks.ps1 sets HP_SKIP_ENTRY_SMOKE and HP_SKIP_EXE_SMOKERUN together and proves no user code ran.
# Neither hook was ever run alone, so nothing said how many times the program runs when only one is set. A stub
# program appends one JSON line per launch to ~ledger.jsonl (same idea as selfapps_launch_ledger.ps1), so a launch
# that logs nothing is still counted. Each scenario is a fresh folder bootstrapped twice (build, then the repeat).
#
#   F  HP_SKIP_ENTRY_SMOKE=1 alone
#        The interpreter smoke test is skipped, the EXE verification run is NOT: a fresh bootstrap builds the EXE
#        and the EXE runs the program once (frozen=true). The repeat reuses the unchanged cached EXE and runs it
#        once more, so two lines in all.
#        F3 (Item 99, REQ-018.5): the source is changed after the repeat, so the cached EXE is stale and the
#        bootstrapper rebuilds. A build or rebuild is verified by running the EXE once, after the warning that
#        this run is a throwaway check (do not start real work in it): the ledger gains exactly one line (three
#        in all) and the warning is printed once, before the program's own output. The repeat (F2) builds
#        nothing and prints no such warning.
#   G  HP_SKIP_EXE_SMOKERUN=1 alone
#        The EXE is built but not run. Skipping the EXE run must not leave the build unverified, so the
#        interpreter runs the program once instead (frozen=false). The repeat reuses the cached EXE WITHOUT
#        running it ("reusing cached EXE without running it"), so the ledger stays at one line.
#        The post-flight panel (Item 99, REQ-012.5) shows the neutral note that the EXE verification was skipped
#        by request, under the plain "SETUP COMPLETE" heading, and not the unverified caveat.
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py
# scans text, not PowerShell).
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately"); the behavior does not depend on
# the provider, so one lane is enough. Five bootstraps (two builds, one rebuild, two repeats).
# Emits: self.skiphooks.entry_only, self.skiphooks.exe_only, self.skiphooks.exe_only.panel,
#        self.launch.warning.throwaway
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
    foreach ($rowId in @('self.skiphooks.entry_only', 'self.skiphooks.exe_only', 'self.skiphooks.exe_only.panel')) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-012'; pass = $true; desc = 'Single skip hook (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    Write-NdjsonRow ([ordered]@{ id = 'self.launch.warning.throwaway'; req = 'REQ-018.5'; pass = $true; desc = 'Throwaway warning before the verification run (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in @('self.skiphooks.entry_only', 'self.skiphooks.exe_only', 'self.skiphooks.exe_only.panel')) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-012'; pass = $false; desc = 'Single skip hook: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    Write-NdjsonRow ([ordered]@{ id = 'self.launch.warning.throwaway'; req = 'REQ-018.5'; pass = $false; desc = 'Throwaway warning before the verification run: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

$ledgerApp = @'
import json
import sys

rec = {"argv": sys.argv[1:], "frozen": bool(getattr(sys, "frozen", False))}
with open("~ledger.jsonl", "a") as f:
    f.write(json.dumps(rec) + "\n")
print("ledger-ok")
'@

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

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
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

function New-HookFolder {
    param([string]$Name)
    $dir = Join-Path $here $Name
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -Path $batchPath -Destination $dir -Force
    Set-Content -Path (Join-Path $dir 'ledger_app.py') -Value $ledgerApp -Encoding ASCII
    return $dir
}

function Invoke-HookBootstrap {
    param([string]$Dir, [string]$LogName)
    $wrapper = Join-Path $Dir '~hook_launch.cmd'
    Set-Content -LiteralPath $wrapper -Value @('@echo off', "call run_setup.bat ledger_app.py > $LogName 2>&1", 'exit /b %ERRORLEVEL%') -Encoding ASCII
    Push-Location -LiteralPath $Dir
    try {
        cmd /c "call ~hook_launch.cmd" | Out-Null
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

# Item 99 (REQ-018.5): what one bootstrap log says about the warning that the verification run is a throwaway
# check. Count is the number of lines that carry both halves of the warning, Before is true when the first such
# line comes ahead of the first line of the program's own output (the live tee of the verification run).
function Get-WarningFacts {
    param([string]$Log, [string]$Marker)
    $count = 0
    $warnAt = -1
    $outAt = -1
    $i = 0
    foreach ($line in @($Log -split "\r?\n")) {
        $i++
        if ($line.Contains('Verifying the built standalone EXE') -and $line.Contains('do not start real work in it')) {
            $count++
            if ($warnAt -lt 0) { $warnAt = $i }
        }
        if ($outAt -lt 0 -and $line.Contains($Marker)) { $outAt = $i }
    }
    return [pscustomobject]@{ Count = $count; WarnLine = $warnAt; OutputLine = $outAt; Before = (($warnAt -gt 0) -and ($outAt -gt $warnAt)) }
}

function Show-Evidence {
    param([string]$Title, [string]$Dir, [string]$LogName)
    Write-Host ("=== single skip hook evidence: {0} ===" -f $Title)
    $raw = Join-Path $Dir '~ledger.jsonl'
    if (Test-Path -LiteralPath $raw) { Get-Content -LiteralPath $raw -Encoding ASCII | ForEach-Object { Write-Host ("ledger: " + $_) } } else { Write-Host 'ledger: (no ~ledger.jsonl in the app folder)' }
    $log = Join-Path $Dir $LogName
    if (Test-Path -LiteralPath $log) {
        Get-Content -LiteralPath $log -Encoding ASCII | Where-Object { $_ -match 'REQ-012|Fast path|Entry smoke|EXE smokerun|Verifying the built|Building standalone|PyInstaller produced|SETUP COMPLETE|skipped by request|\[ERROR\]' } | Select-Object -First 30 | ForEach-Object { Write-Host $_ }
    } else { Write-Host ("log missing: " + $LogName) }
}

function Test-BuiltExe {
    param([string]$Dir)
    $distDir = Join-Path $Dir 'dist'
    if (-not (Test-Path -LiteralPath $distDir)) { return $false }
    return (@(Get-ChildItem -LiteralPath $distDir -Filter '*.exe' -File -ErrorAction SilentlyContinue).Count -gt 0)
}

# Defaults every scenario shares: skip the dependency scan (stdlib-only stub), never prompt, and start from a
# clean slate for the two hooks so an inherited value cannot turn a "single hook" run into the combined one.
$baseEnv = [ordered]@{ HP_SKIP_PIPREQS = '1'; HP_SKIP_ENTRY_SMOKE = $null; HP_SKIP_EXE_SMOKERUN = $null }
if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $baseEnv['HP_CI_LANE'] = 'test' }

# ---------------------------------------------------------------- Scenario F: HP_SKIP_ENTRY_SMOKE alone
$entryEnv = [ordered]@{}
foreach ($k in $baseEnv.Keys) { $entryEnv[$k] = $baseEnv[$k] }
$entryEnv['HP_SKIP_ENTRY_SMOKE'] = '1'
$dirF = New-HookFolder -Name '~selftest_skiphooks_entry_only'
$savedF = Set-TestEnv $entryEnv
try {
    $exitF1 = Invoke-HookBootstrap -Dir $dirF -LogName '~hook_f1.log'
    $linesF1 = Read-Ledger -Dir $dirF
    $exeF1 = Test-BuiltExe -Dir $dirF
    Show-Evidence -Title 'F1 HP_SKIP_ENTRY_SMOKE alone, fresh build' -Dir $dirF -LogName '~hook_f1.log'
    $exitF2 = Invoke-HookBootstrap -Dir $dirF -LogName '~hook_f2.log'
    $linesF2 = Read-Ledger -Dir $dirF
    Show-Evidence -Title 'F2 HP_SKIP_ENTRY_SMOKE alone, repeat' -Dir $dirF -LogName '~hook_f2.log'
    # F3: change the program so the cached EXE is stale. The rebuild is verified by one more run of the EXE.
    Add-Content -LiteralPath (Join-Path $dirF 'ledger_app.py') -Value '# changed after the first build, so the cached EXE is stale' -Encoding ASCII
    $exitF3 = Invoke-HookBootstrap -Dir $dirF -LogName '~hook_f3.log'
    $linesF3 = Read-Ledger -Dir $dirF
    Show-Evidence -Title 'F3 HP_SKIP_ENTRY_SMOKE alone, rebuild after a source change' -Dir $dirF -LogName '~hook_f3.log'
} finally {
    Restore-TestEnv $savedF
}
$logF1 = Read-Text -Path (Join-Path $dirF '~hook_f1.log')
$logF2 = Read-Text -Path (Join-Path $dirF '~hook_f2.log')
$logF3 = Read-Text -Path (Join-Path $dirF '~hook_f3.log')
$entrySkipLogged = $logF1 -match [regex]::Escape('REQ-012: HP_SKIP_ENTRY_SMOKE set; skipping entry-script smoke test')
$exeSmokeRanF1 = $logF1 -match [regex]::Escape('EXE smokerun: testing')
$f1 = if ($linesF1.Count -ge 1) { $linesF1[0] } else { $null }
$f2 = if ($linesF2.Count -ge 2) { $linesF2[1] } else { $null }
$expectedF1Lines = 1   # the EXE verification run is not skipped by this hook, so the first run launches the program once
$expectedF2Lines = 2
$entryPass = ($exitF1 -eq 0) -and ($exitF2 -eq 0) -and $exeF1 -and $entrySkipLogged -and $exeSmokeRanF1 -and
    ($linesF1.Count -eq $expectedF1Lines) -and ($null -ne $f1) -and ($f1.frozen -eq $true) -and
    ($linesF2.Count -eq $expectedF2Lines) -and ($null -ne $f2) -and ($f2.frozen -eq $true)
Write-NdjsonRow ([ordered]@{
    id = 'self.skiphooks.entry_only'; req = 'REQ-012.1, REQ-012.2'; pass = [bool]$entryPass
    desc = 'REQ-012: HP_SKIP_ENTRY_SMOKE alone skips the interpreter smoke test but not the EXE verification run (one launch on the build, one more on the repeat)'
    details = [ordered]@{
        exitFirst = $exitF1; exitRepeat = $exitF2; exeBuilt = [bool]$exeF1
        skipLineLogged = [bool]$entrySkipLogged; exeSmokeRan = [bool]$exeSmokeRanF1
        ledgerLinesFirst = $linesF1.Count; expectedLinesFirst = $expectedF1Lines
        ledgerLinesRepeat = $linesF2.Count; expectedLinesRepeat = $expectedF2Lines
        firstFrozen = if ($f1) { $f1.frozen } else { $null }; repeatFrozen = if ($f2) { $f2.frozen } else { $null }
        repeatReusedCachedExe = [bool]($logF2 -match [regex]::Escape('Fast path: reusing'))
        repeatRebuilt = [bool]($logF2 -match [regex]::Escape('Building standalone executable'))
    }
})

# REQ-018.5: a build or a rebuild is verified by running the EXE once, after the warning that this run is a throwaway
# check. F1 is a fresh build, F2 builds nothing (no warning), F3 is a rebuild after a source change.
$wF1 = Get-WarningFacts -Log $logF1 -Marker 'ledger-ok'
$wF2 = Get-WarningFacts -Log $logF2 -Marker 'ledger-ok'
$wF3 = Get-WarningFacts -Log $logF3 -Marker 'ledger-ok'
$f3 = if ($linesF3.Count -ge 3) { $linesF3[2] } else { $null }
$rebuiltF3 = $logF3 -match [regex]::Escape('Building standalone executable')
$warnPass = ($exitF1 -eq 0) -and ($exitF2 -eq 0) -and ($exitF3 -eq 0) -and $exeF1 -and $rebuiltF3 -and
    ($wF1.Count -eq 1) -and $wF1.Before -and ($wF2.Count -eq 0) -and ($wF3.Count -eq 1) -and $wF3.Before -and
    ($linesF1.Count -eq 1) -and ($linesF2.Count -eq 2) -and ($linesF3.Count -eq 3) -and ($null -ne $f3) -and ($f3.frozen -eq $true)
Write-NdjsonRow ([ordered]@{
    id = 'self.launch.warning.throwaway'; req = 'REQ-018.5'; pass = [bool]$warnPass
    desc = 'REQ-018.5: the verification run of a build or a rebuild comes after the warning that it is a throwaway check, and runs the EXE once'
    details = [ordered]@{
        exitFirst = $exitF1; exitRepeat = $exitF2; exitRebuild = $exitF3; exeBuilt = [bool]$exeF1; rebuilt = [bool]$rebuiltF3
        warningsFirst = $wF1.Count; warningFirstBeforeOutput = [bool]$wF1.Before; warnLineFirst = $wF1.WarnLine; outputLineFirst = $wF1.OutputLine
        warningsRepeat = $wF2.Count
        warningsRebuild = $wF3.Count; warningRebuildBeforeOutput = [bool]$wF3.Before; warnLineRebuild = $wF3.WarnLine; outputLineRebuild = $wF3.OutputLine
        ledgerLinesFirst = $linesF1.Count; ledgerLinesRepeat = $linesF2.Count; ledgerLinesRebuild = $linesF3.Count
        rebuildFrozen = if ($f3) { $f3.frozen } else { $null }
    }
})

# ---------------------------------------------------------------- Scenario G: HP_SKIP_EXE_SMOKERUN alone
$exeEnv = [ordered]@{}
foreach ($k in $baseEnv.Keys) { $exeEnv[$k] = $baseEnv[$k] }
$exeEnv['HP_SKIP_EXE_SMOKERUN'] = '1'
$dirG = New-HookFolder -Name '~selftest_skiphooks_exe_only'
$savedG = Set-TestEnv $exeEnv
try {
    $exitG1 = Invoke-HookBootstrap -Dir $dirG -LogName '~hook_g1.log'
    $linesG1 = Read-Ledger -Dir $dirG
    $exeG1 = Test-BuiltExe -Dir $dirG
    Show-Evidence -Title 'G1 HP_SKIP_EXE_SMOKERUN alone, fresh build' -Dir $dirG -LogName '~hook_g1.log'
    $exitG2 = Invoke-HookBootstrap -Dir $dirG -LogName '~hook_g2.log'
    $linesG2 = Read-Ledger -Dir $dirG
    Show-Evidence -Title 'G2 HP_SKIP_EXE_SMOKERUN alone, repeat' -Dir $dirG -LogName '~hook_g2.log'
} finally {
    Restore-TestEnv $savedG
}
$logG1 = Read-Text -Path (Join-Path $dirG '~hook_g1.log')
$logG2 = Read-Text -Path (Join-Path $dirG '~hook_g2.log')
$exeSkipLogged = $logG1 -match [regex]::Escape('REQ-012: HP_SKIP_EXE_SMOKERUN set; skipping EXE verification (skipped by request)')
$exeSmokeRanG1 = $logG1 -match [regex]::Escape('EXE smokerun: testing')
$repeatSkipLogged = $logG2 -match [regex]::Escape('reusing cached EXE without running it')
$g1 = if ($linesG1.Count -ge 1) { $linesG1[0] } else { $null }
$expectedG1Lines = 1
$expectedG2Lines = 1   # the repeat reuses the cached EXE without running it, so the total stays 1
$exePass = ($exitG1 -eq 0) -and ($exitG2 -eq 0) -and $exeG1 -and $exeSkipLogged -and (-not $exeSmokeRanG1) -and
    ($linesG1.Count -eq $expectedG1Lines) -and ($null -ne $g1) -and ($g1.frozen -eq $false) -and
    $repeatSkipLogged -and ($linesG2.Count -eq $expectedG2Lines)
Write-NdjsonRow ([ordered]@{
    id = 'self.skiphooks.exe_only'; req = 'REQ-012.3, REQ-012.4'; pass = [bool]$exePass
    desc = 'REQ-012: HP_SKIP_EXE_SMOKERUN alone leaves the EXE unrun, the interpreter verifies the build once, and the repeat runs nothing'
    details = [ordered]@{
        exitFirst = $exitG1; exitRepeat = $exitG2; exeBuilt = [bool]$exeG1
        skipLineLogged = [bool]$exeSkipLogged; exeSmokeRan = [bool]$exeSmokeRanG1; repeatSkipLogged = [bool]$repeatSkipLogged
        ledgerLinesFirst = $linesG1.Count; expectedLinesFirst = $expectedG1Lines
        ledgerLinesRepeat = $linesG2.Count; expectedLinesRepeat = $expectedG2Lines
        firstFrozen = if ($g1) { $g1.frozen } else { $null }
    }
})

# REQ-012.5: the post-flight panel of the skipped run. The panel's lines wrap over several echo statements in the
# batch file, so the console text is read with its whitespace flattened. The plain heading must be there, or "no
# caveat" would also pass when no panel was printed at all.
$flatG1 = ($logG1 -replace '\s+', ' ')
$panelHeading = $flatG1 -match [regex]::Escape('SETUP COMPLETE')
$panelNote = $flatG1 -match [regex]::Escape('Note: EXE verification was skipped by request (HP_SKIP_EXE_SMOKERUN).')
$caveatHeading = $flatG1 -match [regex]::Escape('SETUP COMPLETE -- WITH A CAVEAT')
$caveatSentence = $flatG1 -match [regex]::Escape("couldn't fully verify it runs as a standalone program")
$cantConfirm = $flatG1 -match [regex]::Escape("BUT WE CAN'T CONFIRM")
$panelPass = ($exitG1 -eq 0) -and $exeG1 -and $exeSkipLogged -and $panelHeading -and $panelNote -and
    (-not $caveatHeading) -and (-not $caveatSentence) -and (-not $cantConfirm)
Write-NdjsonRow ([ordered]@{
    id = 'self.skiphooks.exe_only.panel'; req = 'REQ-012.5'; pass = [bool]$panelPass
    desc = 'REQ-012.5: with HP_SKIP_EXE_SMOKERUN the post-flight panel notes that the EXE verification was skipped by request and shows no unverified caveat'
    details = [ordered]@{
        exitFirst = $exitG1; exeBuilt = [bool]$exeG1; skipLineLogged = [bool]$exeSkipLogged
        panelHeading = [bool]$panelHeading; panelNote = [bool]$panelNote
        caveatHeading = [bool]$caveatHeading; caveatSentence = [bool]$caveatSentence; cantConfirmHeading = [bool]$cantConfirm
    }
})

if (-not ($entryPass -and $exePass -and $warnPass -and $panelPass)) { exit 1 }
exit 0
