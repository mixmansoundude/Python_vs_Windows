# ASCII only
# selfapps_dep_merge_later.ps1 - Item 89, README REQ-005.1: what a LATER run does with the dependency lists.
#
# selfapps_dep_source_matrix.ps1 covers a cold first run (the lists are a union). This script covers the runs after
# it. A run that installed everything leaves requirements.txt and the PEP 723 header holding the same list, plus a
# snapshot of each list (~dep_base.*.txt). The next run compares each list with its snapshot, and a difference is the
# user's change: an added package is added everywhere, a package removed from a list the bootstrapper wrote is removed
# everywhere (unless pyproject.toml, which the bootstrapper never rewrites, still lists it), and an edited pin beats
# the other lists' older pins without being called a conflict. Until Item 89 the PEP 723 header the first run wrote
# outranked every later edit to requirements.txt, so the edit was thrown away while the console said it was used.
#
# Every folder holds a stdlib-only stub plus one distinct tiny pure-Python package per use, so no scan can add
# anything and the user's program never runs (both skip hooks are set; the build still does):
#
#   A  requirements.txt = termcolor + iniconfig, then four runs in one folder
#        A1 baseline   first run: requirements.txt and the header the run wrote agree, snapshots exist
#        A2 delete     iniconfig removed from requirements.txt            -> removed from the header too
#        A3 add        toolz appended to requirements.txt                 -> in the header too, installed
#        A4 stable     nothing changed (dist removed so the flow runs)    -> files unchanged, no merge messages
#   B  pyproject.toml = iniconfig, requirements.txt = termcolor
#        B2 keeps      iniconfig removed from requirements.txt            -> stays (pyproject.toml still lists it), said so
#   C  requirements.txt = six==1.16.0
#        C2 pin_edit   edited to six==1.17.0                              -> installed at 1.17.0, header follows, no conflict line
#   D  requirements.txt = termcolor
#        D2 header_add toolz added to the header by hand                  -> in requirements.txt too, installed
#
# A row passes only on its named sub-checks (the files, the log line and the installed set), and each later row also
# requires its own baseline run to have agreed, so a broken first run cannot hide behind a later pass.
#
# derived requirement: ids stay literal at each Write-DmRow call site (tools/check_ndjson_registry.py scans text and
# matches a literal -Id argument the same way as an id = '...' key).
#
# Lane: real only (the header write-back is uv-only), gating from its first run (AGENTS.md "New tests gate
# immediately"). Ten bootstraps with the build; every package comes from PyPI, which the lane already depends on.
# Emits: self.depmerge.later.baseline, .delete, .add, .stable, .pyproject_keeps, .pin_edit, .header_add
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

function Write-DmRow {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = $Id; req = 'REQ-005.1'; pass = $Pass; desc = $Desc; details = $Details })
}

$allIds = @(
    'self.depmerge.later.baseline', 'self.depmerge.later.delete', 'self.depmerge.later.add', 'self.depmerge.later.stable',
    'self.depmerge.later.pyproject_keeps', 'self.depmerge.later.pin_edit', 'self.depmerge.later.header_add'
)
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-005.1'; pass = $true; desc = 'Later-run dependency merge (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = 'REQ-005.1'; pass = $false; desc = 'Later-run dependency merge: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    exit 1
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
$stub = "import sys`nprint('dep-merge-later-ok')`n"

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw -Encoding ASCII) }
    return ''
}

function ConvertTo-Key {
    param([string]$Name)
    return (($Name.ToLowerInvariant()) -replace '[-_.]+', '-')
}

# requirements.txt style: key (normalized name) -> the spec line as written.
function Get-ListSpecs {
    param([string]$Path)
    $map = [ordered]@{}
    foreach ($line in ((Read-Text $Path) -split "`r?`n")) {
        $t = ($line -replace '\s+#.*$', '').Trim()
        if ((-not $t) -or $t.StartsWith('#') -or $t.StartsWith('-')) { continue }
        $m = [regex]::Match($t, '^([A-Za-z0-9][A-Za-z0-9._-]*)')
        if ($m.Success) { $map[(ConvertTo-Key $m.Groups[1].Value)] = $t }
    }
    return $map
}

# The dependencies of the PEP 723 block in a .py file: key -> spec as written.
function Get-HeaderSpecs {
    param([string]$Path)
    $map = [ordered]@{}
    $in = $false
    foreach ($line in ((Read-Text $Path) -split "`r?`n")) {
        if (-not $in) {
            if ($line -match '^#\s*///\s*script\s*$') { $in = $true }
            continue
        }
        if ($line -match '^#\s*///\s*$') { break }
        $m = [regex]::Match($line, '^#\s+"([^"]+)"\s*,?\s*$')
        if ($m.Success) {
            $n = [regex]::Match($m.Groups[1].Value, '^([A-Za-z0-9][A-Za-z0-9._-]*)')
            if ($n.Success) { $map[(ConvertTo-Key $n.Groups[1].Value)] = $m.Groups[1].Value }
        }
    }
    return $map
}

function Get-InstalledNames {
    param([string]$Dir)
    $names = New-Object System.Collections.ArrayList
    $path = Join-Path $Dir '~dependency_installed.txt'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    foreach ($line in (Get-Content -LiteralPath $path -Encoding ASCII)) {
        $m = [regex]::Match($line.Trim(), '^([A-Za-z0-9][A-Za-z0-9._-]*)\s*(==|@|\s|$)')
        if ($m.Success) { [void]$names.Add((ConvertTo-Key $m.Groups[1].Value)) }
    }
    return $names.ToArray()
}

function Get-InstalledVersion {
    param([string]$Dir, [string]$Name)
    $path = Join-Path $Dir '~dependency_installed.txt'
    if (-not (Test-Path -LiteralPath $path)) { return '' }
    foreach ($line in (Get-Content -LiteralPath $path -Encoding ASCII)) {
        $m = [regex]::Match($line.Trim(), '^' + [regex]::Escape($Name) + '==(\S+)$', 'IgnoreCase')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ''
}

function Get-StatusState {
    param([string]$Dir)
    $p = Join-Path $Dir '~bootstrap.status.json'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { return [string]((Get-Content -LiteralPath $p -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { return '' }
}

function New-Folder {
    param([string]$Name, [hashtable]$Files)
    $dir = Join-Path $here ("~selftest_depmerge_" + $Name)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $batchPath -Destination $dir -Force
    foreach ($f in @($Files.Keys)) { [System.IO.File]::WriteAllText((Join-Path $dir $f), [string]$Files[$f], $utf8) }
    return $dir
}

# One bootstrap of the folder. -ForceFlow removes dist and the fast-path hash first, so an unchanged folder runs the
# whole dependency flow instead of reusing the EXE.
function Invoke-Run {
    param([string]$Dir, [string]$Label, [switch]$ForceFlow)
    if ($ForceFlow) {
        if (Test-Path -LiteralPath (Join-Path $Dir 'dist')) { Remove-Item -LiteralPath (Join-Path $Dir 'dist') -Recurse -Force }
        if (Test-Path -LiteralPath (Join-Path $Dir '~fast_check.hash.txt')) { Remove-Item -LiteralPath (Join-Path $Dir '~fast_check.hash.txt') -Force }
    }
    $logName = "~dml_$Label.log"
    $wrapper = Join-Path $Dir '~dml_launch.cmd'
    # set "HP_SKIP_PIPREQS=" in the launched shell as well: clearing a variable through SetEnvironmentVariable(name, $null)
    # alone is not trusted (docs/agent-lessons-learned.md). HP_SKIP_PEP723_WRITEBACK is not set: the header is the point.
    Set-Content -LiteralPath $wrapper -Value @('@echo off', 'set "HP_SKIP_PIPREQS="', 'set "HP_SKIP_PEP723_WRITEBACK="', "call run_setup.bat app.py > $logName 2>&1", 'exit /b %ERRORLEVEL%') -Encoding ASCII
    $vars = [ordered]@{
        HP_SKIP_ENTRY_SMOKE = '1'; HP_SKIP_EXE_SMOKERUN = '1'; HP_SKIP_AUTOPEP_DISCOVERY = '1'; HP_SKIP_NIVISA = '1'
        HP_SKIP_PIPREQS = $null; HP_SKIP_PEP723_WRITEBACK = $null
    }
    if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
    $saved = @{}
    foreach ($k in @($vars.Keys)) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
    $exitCode = -1
    Push-Location -LiteralPath $Dir
    try {
        cmd /c "call ~dml_launch.cmd" | Out-Null
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
        foreach ($k in @($saved.Keys)) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
    }
    $log = Read-Text (Join-Path $Dir $logName)
    $req = Get-ListSpecs -Path (Join-Path $Dir 'requirements.txt')
    $hdr = Get-HeaderSpecs -Path (Join-Path $Dir 'app.py')
    Write-Host ("=== dependency merge, later runs: {0} ===" -f $Label)
    Write-Host ("exit={0} state={1} requirements.txt=[{2}] header=[{3}]" -f $exitCode, (Get-StatusState $Dir), (@($req.Keys) -join ','), (@($hdr.Keys) -join ','))
    foreach ($l in (($log -split "`r?`n") | Where-Object { $_ -match 'Dependency lists|Removed |Conflict for|still lists it|REQ-005\.11|Dep-check|DEP_SOURCE=|\[ERROR\]' } | Select-Object -First 16)) { Write-Host $l }
    return [pscustomobject]@{
        Label = $Label; Dir = $Dir; Exit = $exitCode; Log = $log; State = (Get-StatusState $Dir)
        Req = $req; Hdr = $hdr; ReqText = (Read-Text (Join-Path $Dir 'requirements.txt'))
        Installed = @(Get-InstalledNames -Dir $Dir)
    }
}

function Test-Keys {
    param($Map, [string[]]$Expected)
    return ((@($Map.Keys | Sort-Object) -join ',') -eq (@($Expected | Sort-Object) -join ','))
}

$anyRed = $false

# ---- A: requirements.txt = termcolor + iniconfig
$dirA = New-Folder -Name 'a' -Files @{ 'app.py' = $stub; 'requirements.txt' = "termcolor`niniconfig`n" }
$a1 = Invoke-Run -Dir $dirA -Label 'a1'
$snapReqA1 = Test-Path -LiteralPath (Join-Path $dirA '~dep_base.requirements.txt')
$snapHdrA1 = Test-Path -LiteralPath (Join-Path $dirA '~dep_base.pep723.txt')
$recordedA1 = $a1.Log -match [regex]::Escape('Dependency lists recorded for the next run')
$agreeA1 = (Test-Keys $a1.Req @('termcolor', 'iniconfig')) -and (Test-Keys $a1.Hdr @('termcolor', 'iniconfig'))
# preA is what every later row needs from the first run (it ran and the lists agree); the records are the baseline row's own check,
# so a missing record turns the baseline row red and the later rows red only on their own sub-checks.
$preA = ($a1.Exit -eq 0) -and ($a1.State -ceq 'ok') -and $agreeA1
$baselineA = $preA -and $snapReqA1 -and $snapHdrA1 -and $recordedA1
if (-not $baselineA) { $anyRed = $true }
Write-DmRow -Id 'self.depmerge.later.baseline' -Pass ([bool]$baselineA) -Desc 'REQ-005.1: after a first run that installed everything, requirements.txt and the PEP 723 header hold the same list and both are recorded for the next run' -Details ([ordered]@{
    exitCode = $a1.Exit; state = $a1.State; requirementsNames = @($a1.Req.Keys); headerNames = @($a1.Hdr.Keys); agree = [bool]$agreeA1
    snapshotRequirements = [bool]$snapReqA1; snapshotHeader = [bool]$snapHdrA1; recordedLogged = [bool]$recordedA1
})

# A2: the user deletes iniconfig from requirements.txt
[System.IO.File]::WriteAllText((Join-Path $dirA 'requirements.txt'), "termcolor`n", $utf8)
$a2 = Invoke-Run -Dir $dirA -Label 'a2'
$removedLine2 = $a2.Log -match 'Removed iniconfig: you removed it from requirements\.txt'
$headerRemoved2 = $a2.Log -match [regex]::Escape('Removed iniconfig from the PEP 723 header')
$reqOk2 = Test-Keys $a2.Req @('termcolor')
$hdrOk2 = Test-Keys $a2.Hdr @('termcolor')
$pass = $preA -and ($a2.Exit -eq 0) -and ($a2.State -ceq 'ok') -and $reqOk2 -and $hdrOk2 -and $removedLine2 -and $headerRemoved2
if (-not $pass) { $anyRed = $true }
Write-DmRow -Id 'self.depmerge.later.delete' -Pass ([bool]$pass) -Desc 'REQ-005.1: a package the user deletes from requirements.txt after a run is removed from the PEP 723 header too, and the console says so' -Details ([ordered]@{
    baselineOk = [bool]$preA; exitCode = $a2.Exit; state = $a2.State; requirementsNames = @($a2.Req.Keys); headerNames = @($a2.Hdr.Keys)
    requirementsOk = [bool]$reqOk2; headerOk = [bool]$hdrOk2; removedLine = [bool]$removedLine2; headerRemovedLogged = [bool]$headerRemoved2
})

# A3: the user adds toolz to requirements.txt
[System.IO.File]::WriteAllText((Join-Path $dirA 'requirements.txt'), "termcolor`ntoolz`n", $utf8)
$a3 = Invoke-Run -Dir $dirA -Label 'a3'
$reqOk3 = Test-Keys $a3.Req @('termcolor', 'toolz')
$hdrOk3 = Test-Keys $a3.Hdr @('termcolor', 'toolz')
$toolzInstalled3 = $a3.Installed -contains 'toolz'
$noRemoved3 = -not ($a3.Log -match 'you removed it from')
$pass = $preA -and ($a3.Exit -eq 0) -and ($a3.State -ceq 'ok') -and $reqOk3 -and $hdrOk3 -and $toolzInstalled3 -and $noRemoved3
if (-not $pass) { $anyRed = $true }
Write-DmRow -Id 'self.depmerge.later.add' -Pass ([bool]$pass) -Desc 'REQ-005.1: a package the user adds to requirements.txt after a run is installed and written into the PEP 723 header, not thrown away' -Details ([ordered]@{
    baselineOk = [bool]$preA; exitCode = $a3.Exit; state = $a3.State; requirementsNames = @($a3.Req.Keys); headerNames = @($a3.Hdr.Keys)
    requirementsOk = [bool]$reqOk3; headerOk = [bool]$hdrOk3; toolzInstalled = [bool]$toolzInstalled3; noRemovedLine = [bool]$noRemoved3
})

# A3s: one unchanged run to settle. uv writes a lower bound into the header for a bare name (toolz becomes toolz>=x.y), and a run that
# changes nothing then writes that bound into requirements.txt once (a bare name never beats a constrained entry). The run after this
# one is the stable state the next row judges byte for byte; the settling run's own effect is recorded, not hidden.
$reqTextBeforeSettle = $a3.ReqText
$a3s = Invoke-Run -Dir $dirA -Label 'a3s' -ForceFlow
$settleRewrote = ($a3s.ReqText -cne $reqTextBeforeSettle)
$settleOk = ($a3s.Exit -eq 0) -and ($a3s.State -ceq 'ok') -and (Test-Keys $a3s.Req @('termcolor', 'toolz')) -and (Test-Keys $a3s.Hdr @('termcolor', 'toolz'))

# A4: nothing changed since the settling run; dist removed so the dependency flow runs instead of the EXE fast path
$reqTextBefore4 = $a3s.ReqText
$hdrKeysBefore4 = @($a3s.Hdr.Keys)
$a4 = Invoke-Run -Dir $dirA -Label 'a4' -ForceFlow
$flowRan4 = $a4.Log -match 'DEP_SOURCE=|Dependency lists merged'
$unchanged4 = ($a4.ReqText -ceq $reqTextBefore4) -and (Test-Keys $a4.Hdr $hdrKeysBefore4)
$quiet4 = -not ($a4.Log -match 'you removed it from|Conflict for|still lists it|could not be merged')
$pass = $preA -and $settleOk -and ($a4.Exit -eq 0) -and ($a4.State -ceq 'ok') -and $flowRan4 -and $unchanged4 -and $quiet4
if (-not $pass) { $anyRed = $true }
Write-DmRow -Id 'self.depmerge.later.stable' -Pass ([bool]$pass) -Desc 'REQ-005.1: a later run with no change to any list leaves requirements.txt and the header as they were and prints no removal, conflict or merge-failure line' -Details ([ordered]@{
    baselineOk = [bool]$preA; settleOk = [bool]$settleOk; settleRewroteRequirements = [bool]$settleRewrote; exitCode = $a4.Exit; state = $a4.State
    dependencyFlowRan = [bool]$flowRan4; filesUnchanged = [bool]$unchanged4; quiet = [bool]$quiet4; requirementsNames = @($a4.Req.Keys); headerNames = @($a4.Hdr.Keys)
    requirementsText = ($a4.ReqText -replace "`r?`n", '|')
})

# ---- B: pyproject.toml = iniconfig, requirements.txt = termcolor; the user deletes iniconfig from requirements.txt
$pyprojectB = "[project]`nname = `"depmergelater`"`nversion = `"0.1.0`"`ndependencies = [`"iniconfig`"]`n"
$dirB = New-Folder -Name 'b' -Files @{ 'app.py' = $stub; 'pyproject.toml' = $pyprojectB; 'requirements.txt' = "termcolor`n" }
$b1 = Invoke-Run -Dir $dirB -Label 'b1'
$baselineB = ($b1.Exit -eq 0) -and ($b1.State -ceq 'ok') -and (Test-Keys $b1.Req @('termcolor', 'iniconfig')) -and (Test-Keys $b1.Hdr @('termcolor', 'iniconfig'))
[System.IO.File]::WriteAllText((Join-Path $dirB 'requirements.txt'), "termcolor`n", $utf8)
$b2 = Invoke-Run -Dir $dirB -Label 'b2'
$stayLine2 = $b2.Log -match 'iniconfig was removed from requirements\.txt but pyproject\.toml still lists it, so it stays'
$reqOkB2 = Test-Keys $b2.Req @('termcolor', 'iniconfig')
$hdrOkB2 = Test-Keys $b2.Hdr @('termcolor', 'iniconfig')
$pass = $baselineB -and ($b2.Exit -eq 0) -and ($b2.State -ceq 'ok') -and $reqOkB2 -and $hdrOkB2 -and $stayLine2
if (-not $pass) { $anyRed = $true }
Write-DmRow -Id 'self.depmerge.later.pyproject_keeps' -Pass ([bool]$pass) -Desc 'REQ-005.1: a package deleted from requirements.txt while pyproject.toml still lists it stays everywhere, and the console says where to remove it' -Details ([ordered]@{
    baselineOk = [bool]$baselineB; exitCode = $b2.Exit; state = $b2.State; requirementsNames = @($b2.Req.Keys); headerNames = @($b2.Hdr.Keys)
    requirementsOk = [bool]$reqOkB2; headerOk = [bool]$hdrOkB2; staysLine = [bool]$stayLine2
})

# ---- C: requirements.txt = six==1.16.0; the user edits the pin to 1.17.0
$dirC = New-Folder -Name 'c' -Files @{ 'app.py' = $stub; 'requirements.txt' = "six==1.16.0`n" }
$c1 = Invoke-Run -Dir $dirC -Label 'c1'
$baselineC = ($c1.Exit -eq 0) -and ($c1.State -ceq 'ok') -and (Test-Keys $c1.Req @('six')) -and (Test-Keys $c1.Hdr @('six')) -and ((Get-InstalledVersion -Dir $dirC -Name 'six') -eq '1.16.0')
[System.IO.File]::WriteAllText((Join-Path $dirC 'requirements.txt'), "six==1.17.0`n", $utf8)
$c2 = Invoke-Run -Dir $dirC -Label 'c2'
$sixVersion2 = Get-InstalledVersion -Dir $dirC -Name 'six'
$reqPin2 = ($c2.Req['six'] -ceq 'six==1.17.0')
$hdrPin2 = ($c2.Hdr['six'] -ceq 'six==1.17.0')
$noConflict2 = -not ($c2.Log -match 'Conflict for six')
$pass = $baselineC -and ($c2.Exit -eq 0) -and ($c2.State -ceq 'ok') -and ($sixVersion2 -eq '1.17.0') -and $reqPin2 -and $hdrPin2 -and $noConflict2
if (-not $pass) { $anyRed = $true }
Write-DmRow -Id 'self.depmerge.later.pin_edit' -Pass ([bool]$pass) -Desc 'REQ-005.1: a pin the user edits in requirements.txt after a run is installed and written into the header, and is not reported as a conflict with the older header pin' -Details ([ordered]@{
    baselineOk = [bool]$baselineC; exitCode = $c2.Exit; state = $c2.State; installedSixVersion = $sixVersion2
    requirementsSpec = [string]$c2.Req['six']; headerSpec = [string]$c2.Hdr['six']; requirementsPinned = [bool]$reqPin2; headerPinned = [bool]$hdrPin2; noConflictLine = [bool]$noConflict2
})

# ---- D: requirements.txt = termcolor; the user adds toolz to the header the first run wrote
$dirD = New-Folder -Name 'd' -Files @{ 'app.py' = $stub; 'requirements.txt' = "termcolor`n" }
$d1 = Invoke-Run -Dir $dirD -Label 'd1'
$baselineD = ($d1.Exit -eq 0) -and ($d1.State -ceq 'ok') -and (Test-Keys $d1.Req @('termcolor')) -and (Test-Keys $d1.Hdr @('termcolor'))
$appPathD = Join-Path $dirD 'app.py'
$appTextD = Get-Content -LiteralPath $appPathD -Raw -Encoding UTF8
$editedD = [regex]::Replace($appTextD, '(?m)^# \]', ('#     "toolz",' + "`n" + '# ]'), 1)
$headerEditApplied = ($editedD -ne $appTextD)
[System.IO.File]::WriteAllText($appPathD, $editedD, $utf8)
$d2 = Invoke-Run -Dir $dirD -Label 'd2'
$reqOkD2 = Test-Keys $d2.Req @('termcolor', 'toolz')
$hdrOkD2 = Test-Keys $d2.Hdr @('termcolor', 'toolz')
$toolzInstalledD2 = $d2.Installed -contains 'toolz'
$pass = $baselineD -and $headerEditApplied -and ($d2.Exit -eq 0) -and ($d2.State -ceq 'ok') -and $reqOkD2 -and $hdrOkD2 -and $toolzInstalledD2
if (-not $pass) { $anyRed = $true }
Write-DmRow -Id 'self.depmerge.later.header_add' -Pass ([bool]$pass) -Desc 'REQ-005.1: a package the user adds to the PEP 723 header after a run is installed and written into requirements.txt' -Details ([ordered]@{
    baselineOk = [bool]$baselineD; headerEditApplied = [bool]$headerEditApplied; exitCode = $d2.Exit; state = $d2.State
    requirementsNames = @($d2.Req.Keys); headerNames = @($d2.Hdr.Keys); requirementsOk = [bool]$reqOkD2; headerOk = [bool]$hdrOkD2; toolzInstalled = [bool]$toolzInstalledD2
})

if ($anyRed) { exit 1 }
exit 0
