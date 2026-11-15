# ASCII only
# selfapps_dep_merge_edges.ps1 - Item 106, README REQ-005.1.6, REQ-005.1.12, REQ-005.1.13 and REQ-005.1.14: the edges of the
# dependency-list merge that selfapps_dep_merge_later.ps1 (the later runs that go right) does not reach.
#
# Four shalls had no row able to fail for them (docs/plan-test-suite-gaps.md, tests/test_req_shall_trace.py until this change):
#
#   F  a failed install records nothing (REQ-005.1.6)
#        requirements.txt = termcolor, pyproject.toml = iniconfig
#        F1 baseline   first run: the lists are merged, installed, written into the PEP 723 header and recorded (three records)
#        F2 failed     the user deletes termcolor and adds a pin no index can satisfy (six==999.0.0): the merge reports the
#                      removal, the install fails, the header is not written, and NONE of the three records changes
#        F3 same       nothing changed since F2: the next run sees the same removal again, because nothing was recorded
#   U  a header the user wrote is only ever added to (REQ-005.1.12)
#        requirements.txt = termcolor + iniconfig, a hand-written PEP 723 header = iniconfig
#        U1 baseline   first run with the header write-back switched off (HP_SKIP_PEP723_WRITEBACK): the header stays the user's
#                      own text and gets no record (only a header the bootstrapper wrote has one)
#        U2 keeps      the user deletes iniconfig from requirements.txt and the write-back runs: the header still lists
#                      iniconfig, the console says it stays, and nothing is removed from the header
#   X  the merge cannot run: the helper cannot be written (REQ-005.1.13, REQ-005.1.14)
#        requirements.txt = termcolor, pyproject.toml = iniconfig, HP_TEST_FORCE_EMIT_FAIL=HP_DEP_MERGE
#   H  the merge cannot run: the helper fails while it works (REQ-005.1.13, REQ-005.1.14)
#        the same two lists, and this script holds ~requirements.merge.tmp open without sharing for the whole run: the batch
#        file's del cannot remove it and the helper cannot open it for writing (a sharing violation, which Python reports as a
#        PermissionError that its own error line names). A lock holds against del and against del /f alike, so a later
#        hardening of that del does not turn this scenario into a run where the merge works.
#      Both X and H: the highest ranked list alone (pyproject.toml) is what requirements.txt holds and what is installed, the
#      console and the setup log carry the [WARN], and the run goes on to a normal end (state ok, exit code 0, packages installed).
#
# A row passes only on its named sub-checks, and each one also needs the precondition that makes the check mean something
# (the removal was seen, the install really failed, the write-back really ran, the forced failure really fired), so a run that
# never reached the step cannot pass. The judging lives in functions that take plain values and return a list of problems:
# tests/test_dep_merge_edges.py runs each of them through real pwsh on synthetic runs that must be red for every comparison.
#
# derived requirement: ids and req tags stay literal at each Write-DmRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell). The skip loop below uses a map on purpose; the real emissions are literal.
#
# Lane: contract-uv only (the header write-back is uv-only and this is the uv lane with the most wall-clock headroom), gating
# from its first run (AGENTS.md "New tests gate immediately"). Seven bootstraps with the build; every package comes from PyPI.
# Emits: self.depmerge.failed.records, self.depmerge.header.userwrote, self.depmerge.fallback.emit, self.depmerge.fallback.helper
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

# A call that proves numbered shalls passes a -Tag hashtable that holds the req key (a comma list for several); the tag
# stays a literal at the call site because tests/test_req_shall_trace.py reads it as static text.
function Write-DmRow {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details,
        [hashtable]$Tag = @{ req = 'REQ-005.1' }
    )
    Write-NdjsonRow ([ordered]@{ id = $Id; req = $Tag.req; pass = $Pass; desc = $Desc; details = $Details })
}

$allIds = @('self.depmerge.failed.records', 'self.depmerge.header.userwrote', 'self.depmerge.fallback.emit', 'self.depmerge.fallback.helper')
$reqOf = @{
    'self.depmerge.failed.records' = 'REQ-005.1.6'; 'self.depmerge.header.userwrote' = 'REQ-005.1.12'
    'self.depmerge.fallback.emit' = 'REQ-005.1.13, REQ-005.1.14'; 'self.depmerge.fallback.helper' = 'REQ-005.1.13, REQ-005.1.14'
}
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = $reqOf[$rowId]; pass = $true; desc = 'Dependency merge edges (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; req = $reqOf[$rowId]; pass = $false; desc = 'Dependency merge edges: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    exit 1
}

# --- pure helpers (no file system, no process): the unit test runs them through real pwsh ---

# True when two lists of names hold the same names, whatever the order and the case; a missing list ($null) is not an empty one.
function Test-SameNames {
    param($Actual, [string[]]$Expected)
    if ($null -eq $Actual) { return $false }
    $a = @($Actual | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
    $e = @($Expected | ForEach-Object { ([string]$_).ToLowerInvariant() } | Sort-Object)
    return ((@($a) -join ',') -ceq (@($e) -join ','))
}

# What a run's console and setup log say, as plain facts. The texts are the batch file's and the helper's own (the unit test
# pins that each one is still written by a live line there).
function Get-DmFacts {
    param([string]$Console, [string]$Setup)
    return [pscustomobject][ordered]@{
        removedTermcolor    = [regex]::IsMatch($Console, 'Removed termcolor: you removed it from requirements\.txt')
        removedIniconfig    = [regex]::IsMatch($Console, 'Removed iniconfig: you removed it from')
        headerRemovedLogged = [regex]::IsMatch($Console, 'Removed iniconfig from the PEP 723 header')
        staysHeader         = [regex]::IsMatch($Console, 'iniconfig was removed from requirements\.txt but the PEP 723 header still lists it, so it stays')
        installFailed       = [regex]::IsMatch($Console, 'uv pip install -r requirements\.txt failed')
        writebackSkippedInstall = [regex]::IsMatch($Console, 'PEP 723 write-back skipped \(dependency install did not fully succeed\)')
        writebackSkippedFlag = [regex]::IsMatch($Console, 'PEP 723 write-back skipped \(HP_SKIP_PEP723_WRITEBACK set\)')
        writebackSucceeded  = [regex]::IsMatch($Console, 'PEP 723 header write-back succeeded via uv add --script')
        recordedLine        = [regex]::IsMatch($Console, 'Dependency lists recorded for the next run')
        mergedLine          = [regex]::IsMatch($Console, 'Dependency lists merged')
        couldNotMergeConsole = [regex]::IsMatch($Console, '\[WARN\] The dependency lists could not be merged')
        couldNotMergeSetup  = [regex]::IsMatch($Setup, '\[WARN\] The dependency lists could not be merged; using the highest ranked list only\.')
        forcedEmitFailure   = [regex]::IsMatch($Setup, '\[TEST\] HP_TEST_FORCE_EMIT_FAIL=HP_DEP_MERGE')
        helperError         = [regex]::IsMatch($Setup, '(?m)^dep_merge: .*requirements\.merge\.tmp')
    }
}

# REQ-005.1.6: what is wrong with the three runs of scenario F; nothing when they show a failed install recording nothing.
# $R1 is the first run, $R2 and $R3 the failed ones; each holds Finished, Facts (Get-DmFacts) and the record facts the caller took.
function Get-FailedRecordsProblems {
    param($R1, $R2, $R3)
    $out = New-Object System.Collections.ArrayList
    foreach ($pair in @(@('F1', $R1), @('F2', $R2), @('F3', $R3))) {
        if (-not $pair[1].Finished) { [void]$out.Add(("{0}: the bootstrap did not finish within the time limit" -f $pair[0])) }
    }
    if ($out.Count -gt 0) { return $out.ToArray() }
    if (($R1.Exit -ne 0) -or ($R1.State -cne 'ok')) { [void]$out.Add('F1: the first run did not end ok, so there is no good run to compare with') }
    if (-not (Test-SameNames $R1.ReqNames @('termcolor', 'iniconfig'))) { [void]$out.Add('F1: requirements.txt does not hold the merged list (termcolor and iniconfig)') }
    if (-not (Test-SameNames $R1.HdrNames @('termcolor', 'iniconfig'))) { [void]$out.Add('F1: the PEP 723 header does not hold the merged list (termcolor and iniconfig)') }
    if (-not $R1.Facts.recordedLine) { [void]$out.Add('F1: the run did not say that it recorded the lists for the next run') }
    if (-not (Test-SameNames $R1.RecReq @('termcolor', 'iniconfig'))) { [void]$out.Add('F1: ~dep_base.requirements.txt is missing or does not hold the list as it stood after the run') }
    if (-not (Test-SameNames $R1.RecPy @('iniconfig'))) { [void]$out.Add('F1: ~dep_base.pyproject.txt is missing or does not hold the pyproject.toml list') }
    if (-not (Test-SameNames $R1.RecHdr @('termcolor', 'iniconfig'))) { [void]$out.Add('F1: ~dep_base.pep723.txt is missing or does not hold the header list') }
    if ($out.Count -gt 0) { return $out.ToArray() }
    foreach ($pair in @(@('F2', $R2), @('F3', $R3))) {
        $name = $pair[0]; $r = $pair[1]
        if (-not $r.Facts.removedTermcolor) { [void]$out.Add("${name}: the merge did not report the removal of termcolor, so the run never saw the user's change") }
        if (-not $r.Facts.installFailed) { [void]$out.Add("${name}: the install did not fail, so the run is not the failed install the shall is about") }
        if ($r.Facts.recordedLine) { [void]$out.Add("${name}: the run said it recorded the lists for the next run although its install failed") }
        if (-not $r.RecReqKept) { [void]$out.Add("${name}: ~dep_base.requirements.txt changed (or is gone) after a failed install") }
        if (-not $r.RecPyKept) { [void]$out.Add("${name}: ~dep_base.pyproject.txt changed (or is gone) after a failed install") }
        if (-not $r.RecHdrKept) { [void]$out.Add("${name}: ~dep_base.pep723.txt changed (or is gone) after a failed install") }
    }
    if (-not $R2.Facts.writebackSkippedInstall) { [void]$out.Add('F2: the header write-back was not reported as skipped after the failed install') }
    return $out.ToArray()
}

# REQ-005.1.12: what is wrong with scenario U; nothing when a header the user wrote keeps everything the user put in it.
function Get-UserHeaderProblems {
    param($R1, $R2)
    $out = New-Object System.Collections.ArrayList
    if (-not $R1.Finished) { [void]$out.Add('U1: the bootstrap did not finish within the time limit') }
    if (-not $R2.Finished) { [void]$out.Add('U2: the bootstrap did not finish within the time limit') }
    if ($out.Count -gt 0) { return $out.ToArray() }
    if (($R1.Exit -ne 0) -or ($R1.State -cne 'ok')) { [void]$out.Add('U1: the first run did not end ok') }
    if (-not $R1.Facts.writebackSkippedFlag) { [void]$out.Add('U1: the header write-back was not reported as switched off, so the header may have been written') }
    if (-not $R1.HeaderTextSame) { [void]$out.Add('U1: the header text changed in the first run, so it is no longer the text the user wrote') }
    if (-not (Test-SameNames $R1.RecReq @('termcolor', 'iniconfig'))) { [void]$out.Add('U1: ~dep_base.requirements.txt is missing or does not hold the list as it stood after the run') }
    if ($R1.HdrRecordExists) { [void]$out.Add('U1: a record of the header exists, but the bootstrapper never wrote this header') }
    if ($out.Count -gt 0) { return $out.ToArray() }
    if (($R2.Exit -ne 0) -or ($R2.State -cne 'ok')) { [void]$out.Add('U2: the second run did not end ok') }
    if (-not $R2.Facts.writebackSucceeded) { [void]$out.Add('U2: the header write-back did not run and succeed, so the header could not have been changed at all') }
    if (-not $R2.Facts.staysHeader) { [void]$out.Add('U2: the console did not say that iniconfig stays because the PEP 723 header still lists it') }
    if ($R2.Facts.removedIniconfig) { [void]$out.Add('U2: the console says iniconfig was removed everywhere, although the user wrote it in the header') }
    if ($R2.Facts.headerRemovedLogged) { [void]$out.Add('U2: iniconfig was removed from the PEP 723 header, which the user wrote') }
    if (-not (Test-SameNames $R2.HdrNames @('iniconfig', 'termcolor'))) { [void]$out.Add('U2: the header does not hold iniconfig (kept) and termcolor (added)') }
    if (-not (Test-SameNames $R2.ReqNames @('iniconfig', 'termcolor'))) { [void]$out.Add('U2: requirements.txt does not hold both packages again') }
    return $out.ToArray()
}

# REQ-005.1.13 and REQ-005.1.14: what is wrong with one run whose merge could not run. $Variant is 'emit' or 'helper'.
function Get-FallbackProblems {
    param([string]$Variant, $R)
    $out = New-Object System.Collections.ArrayList
    if (-not $R.Finished) { [void]$out.Add("${Variant}: the bootstrap did not finish within the time limit"); return $out.ToArray() }
    if ($Variant -eq 'emit' -and -not $R.Facts.forcedEmitFailure) { [void]$out.Add('emit: the setup log has no line for the forced failure to write the merge helper, so the merge was not made to fail') }
    if ($Variant -eq 'helper' -and -not $R.Facts.helperError) { [void]$out.Add('helper: the setup log has no error line from the merge helper about ~requirements.merge.tmp, so the helper did not fail while it worked') }
    if ($R.Facts.mergedLine) { [void]$out.Add("${Variant}: the console says the lists were merged, although the merge could not run") }
    if (-not $R.Facts.couldNotMergeConsole) { [void]$out.Add("${Variant}: the console has no [WARN] that the lists could not be merged (REQ-005.1.13)") }
    if (-not $R.Facts.couldNotMergeSetup) { [void]$out.Add("${Variant}: the setup log has no [WARN] that the lists could not be merged") }
    if (-not (Test-SameNames $R.ReqNames @('iniconfig'))) { [void]$out.Add("${Variant}: requirements.txt is not the highest ranked list alone (pyproject.toml: iniconfig)") }
    if (-not ($R.Installed -contains 'iniconfig')) { [void]$out.Add("${Variant}: the highest ranked list's package (iniconfig) was not installed") }
    if ($R.Installed -contains 'termcolor') { [void]$out.Add("${Variant}: termcolor was installed, so the lower ranked list was used as well") }
    if (($R.Exit -ne 0) -or ($R.State -cne 'ok')) { [void]$out.Add("${Variant}: the run did not end ok (exit code $($R.Exit), state '$($R.State)'), so the failed merge stopped it (REQ-005.1.14)") }
    return $out.ToArray()
}

# A few log lines that explain a red row, printable ASCII only and cut short.
function Get-Excerpt {
    param([string]$Text, [int]$Max = 20)
    $keep = New-Object System.Collections.ArrayList
    foreach ($l in ($Text -split "`r?`n")) {
        if ($l -match 'Dependency lists|Removed |Conflict for|still lists it|could not be merged|REQ-005\.11|Dep-check|DEP_SOURCE=|uv pip install|HP_TEST_FORCE_EMIT_FAIL|^dep_merge:|\[ERROR\]') {
            $clean = ($l -replace '[^\x20-\x7E]', '?')
            if ($clean.Length -gt 160) { $clean = $clean.Substring(0, 160) }
            [void]$keep.Add($clean)
            if ($keep.Count -ge $Max) { break }
        }
    }
    return $keep.ToArray()
}

# --- the file system and the bootstrapper ---

$utf8 = New-Object System.Text.UTF8Encoding($false)
$stub = "import sys`nprint('dep-merge-edge-ok')`n"
# A hang must be a red row; a bootstrap of a tiny program with the build needs a few minutes at most.
$runTimeoutMs = 12 * 60 * 1000

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
        if ($null -ne $t) { return [string]$t }
    }
    return ''
}

function ConvertTo-Key {
    param([string]$Name)
    return (($Name.ToLowerInvariant()) -replace '[-_.]+', '-')
}

# requirements.txt style: key (normalized name) -> the spec line as written. $null for a file that does not exist.
function Get-ListSpecs {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
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

function Get-StatusState {
    param([string]$Dir)
    $p = Join-Path $Dir '~bootstrap.status.json'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { return [string]((Get-Content -LiteralPath $p -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { return '' }
}

function New-Folder {
    param([string]$Name, [hashtable]$Files)
    $dir = Join-Path $here ("~selftest_dmedge_" + $Name)
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -LiteralPath $batchPath -Destination $dir -Force
    foreach ($f in @($Files.Keys)) { [System.IO.File]::WriteAllText((Join-Path $dir $f), [string]$Files[$f], $utf8) }
    return $dir
}

# One bootstrap of the folder; never throws. -ForceFlow removes dist and the fast-path hash first, so an unchanged folder runs the
# whole dependency flow instead of reusing the EXE. -Env sets extra variables (a value of '' clears one) for this run only.
function Invoke-Run {
    param([string]$Dir, [string]$Label, [switch]$ForceFlow, [hashtable]$Env = @{})
    $res = [ordered]@{ Label = $Label; Dir = $Dir; Finished = $false; Exit = -1; State = ''; Console = ''; Setup = ''; ReqNames = @(); HdrNames = @(); Installed = @(); Error = '' }
    try {
        if ($ForceFlow) {
            if (Test-Path -LiteralPath (Join-Path $Dir 'dist')) { Remove-Item -LiteralPath (Join-Path $Dir 'dist') -Recurse -Force }
            if (Test-Path -LiteralPath (Join-Path $Dir '~fast_check.hash.txt')) { Remove-Item -LiteralPath (Join-Path $Dir '~fast_check.hash.txt') -Force }
        }
        $setupPath = Join-Path $Dir '~setup.log'
        $setupBefore = 0
        if (Test-Path -LiteralPath $setupPath) { $setupBefore = [int](Get-Item -LiteralPath $setupPath).Length }
        $logName = "~dme_$Label.log"
        $wrapper = Join-Path $Dir '~dme_launch.cmd'
        $vars = [ordered]@{
            HP_SKIP_ENTRY_SMOKE = '1'; HP_SKIP_EXE_SMOKERUN = '1'; HP_SKIP_AUTOPEP_DISCOVERY = '1'; HP_SKIP_NIVISA = '1'
            HP_SKIP_PIPREQS = ''; HP_SKIP_PEP723_WRITEBACK = ''; HP_TEST_FORCE_EMIT_FAIL = ''
        }
        foreach ($k in @($Env.Keys)) { $vars[[string]$k] = [string]$Env[$k] }
        if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
        # Set in the launched shell as well: clearing a variable through SetEnvironmentVariable(name, $null) alone is not trusted
        # (docs/agent-lessons-learned.md). Names and values are fixed words in this script, so no quoting is needed.
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('@echo off')
        foreach ($k in @($vars.Keys)) {
            if ($k -notmatch '^[A-Za-z0-9_]+$' -or ([string]$vars[$k]) -notmatch '^[A-Za-z0-9_.=-]*$') { throw "unsafe variable $k" }
            [void]$lines.Add(('set "{0}={1}"' -f $k, $vars[$k]))
        }
        [void]$lines.Add("call run_setup.bat app.py > $logName 2>&1 < nul")
        [void]$lines.Add('exit /b %ERRORLEVEL%')
        Set-Content -LiteralPath $wrapper -Value $lines.ToArray() -Encoding ASCII
        $saved = @{}
        foreach ($k in @($vars.Keys)) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            if ([string]$vars[$k] -eq '') { Remove-Item -LiteralPath ('Env:' + $k) -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, [string]$vars[$k]) }
        }
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'call ~dme_launch.cmd') -WorkingDirectory $Dir -NoNewWindow -PassThru
            $null = $p.Handle   # keeps ExitCode readable after WaitForExit(ms)
            if ($p.WaitForExit($runTimeoutMs)) {
                $res.Finished = $true
                $res.Exit = $p.ExitCode
            } else {
                & taskkill.exe /F /T /PID $p.Id 2>&1 | Out-Null
                $null = $p.WaitForExit(30000)
            }
        } finally {
            foreach ($k in @($saved.Keys)) {
                if ($null -eq $saved[$k]) { Remove-Item -LiteralPath ('Env:' + $k) -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, [string]$saved[$k]) }
            }
        }
        $res.Console = Read-Text (Join-Path $Dir $logName)
        if (Test-Path -LiteralPath $setupPath) {
            $bytes = [System.IO.File]::ReadAllBytes($setupPath)
            if ($bytes.Length -ge $setupBefore) { $res.Setup = [System.Text.Encoding]::ASCII.GetString($bytes, $setupBefore, $bytes.Length - $setupBefore) }
        }
        $res.State = Get-StatusState $Dir
        $req = Get-ListSpecs -Path (Join-Path $Dir 'requirements.txt')
        if ($null -ne $req) { $res.ReqNames = @($req.Keys) }
        $res.HdrNames = @((Get-HeaderSpecs -Path (Join-Path $Dir 'app.py')).Keys)
        $res.Installed = @(Get-InstalledNames -Dir $Dir)
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    Write-Host ("=== dependency merge edges: {0} ===" -f $Label)
    Write-Host ("finished={0} exit={1} state={2} requirements.txt=[{3}] header=[{4}] installed=[{5}]" -f $res.Finished, $res.Exit, $res.State, (@($res.ReqNames) -join ','), (@($res.HdrNames) -join ','), (@($res.Installed) -join ','))
    foreach ($l in @(Get-Excerpt $res.Console)) { Write-Host ('console: ' + $l) }
    if ($res.Error) { Write-Host ('error: ' + $res.Error) }
    return [pscustomobject]$res
}

# The three records of a folder: raw text with LF line ends, $null for a record that is not there, plus the names each holds.
function Get-Records {
    param([string]$Dir)
    $read = {
        param($name)
        $p = Join-Path $Dir $name
        if (Test-Path -LiteralPath $p) { return ((Read-Text $p) -replace "`r`n", "`n") }
        return $null
    }
    $names = {
        param($name)
        $m = Get-ListSpecs -Path (Join-Path $Dir $name)
        if ($null -eq $m) { return $null }
        return @($m.Keys)
    }
    return [pscustomobject]@{
        ReqText = (& $read '~dep_base.requirements.txt'); PyText = (& $read '~dep_base.pyproject.txt'); HdrText = (& $read '~dep_base.pep723.txt')
        ReqNames = (& $names '~dep_base.requirements.txt'); PyNames = (& $names '~dep_base.pyproject.txt'); HdrNames = (& $names '~dep_base.pep723.txt')
    }
}

function Test-SameText {
    param($A, $B)
    if (($null -eq $A) -or ($null -eq $B)) { return $false }
    return ([string]$A -ceq [string]$B)
}

$anyRed = $false

# ---------------------------------------------------------------- F: a failed install records nothing (REQ-005.1.6)
$pyprojectF = "[project]`nname = `"dmedgef`"`nversion = `"0.1.0`"`ndependencies = [`"iniconfig`"]`n"
$dirF = New-Folder -Name 'f' -Files @{ 'app.py' = $stub; 'pyproject.toml' = $pyprojectF; 'requirements.txt' = "termcolor`n" }
$f1 = Invoke-Run -Dir $dirF -Label 'f1'
$rec1 = Get-Records $dirF
# The user deletes termcolor and adds a pin that no index can satisfy (a version no release will ever have).
[System.IO.File]::WriteAllText((Join-Path $dirF 'requirements.txt'), "iniconfig`nsix==999.0.0`n", $utf8)
$f2 = Invoke-Run -Dir $dirF -Label 'f2'
$rec2 = Get-Records $dirF
# Nothing changed since F2; ForceFlow, because F2 may have left a build whose hash matches and the fast path would skip the merge.
$f3 = Invoke-Run -Dir $dirF -Label 'f3' -ForceFlow
$rec3 = Get-Records $dirF
$factsF1 = Get-DmFacts -Console $f1.Console -Setup $f1.Setup
$factsF2 = Get-DmFacts -Console $f2.Console -Setup $f2.Setup
$factsF3 = Get-DmFacts -Console $f3.Console -Setup $f3.Setup
$r1 = [pscustomobject]@{
    Finished = $f1.Finished; Exit = $f1.Exit; State = $f1.State; ReqNames = $f1.ReqNames; HdrNames = $f1.HdrNames; Facts = $factsF1
    RecReq = $rec1.ReqNames; RecPy = $rec1.PyNames; RecHdr = $rec1.HdrNames
}
$r2 = [pscustomobject]@{
    Finished = $f2.Finished; Facts = $factsF2
    RecReqKept = (Test-SameText $rec2.ReqText $rec1.ReqText); RecPyKept = (Test-SameText $rec2.PyText $rec1.PyText); RecHdrKept = (Test-SameText $rec2.HdrText $rec1.HdrText)
}
$r3 = [pscustomobject]@{
    Finished = $f3.Finished; Facts = $factsF3
    RecReqKept = (Test-SameText $rec3.ReqText $rec1.ReqText); RecPyKept = (Test-SameText $rec3.PyText $rec1.PyText); RecHdrKept = (Test-SameText $rec3.HdrText $rec1.HdrText)
}
$problems = @(Get-FailedRecordsProblems -R1 $r1 -R2 $r2 -R3 $r3)
$pass = ($problems.Count -eq 0)
if (-not $pass) { $anyRed = $true }
$detailsF = [ordered]@{
    firstExit = $f1.Exit; firstState = $f1.State; firstRequirements = @($f1.ReqNames); firstHeader = @($f1.HdrNames)
    recordsAfterFirst = [ordered]@{ requirements = @($rec1.ReqNames); pyproject = @($rec1.PyNames); header = @($rec1.HdrNames) }
    failedRun = [ordered]@{ removalSeen = [bool]$factsF2.removedTermcolor; installFailed = [bool]$factsF2.installFailed; writebackSkipped = [bool]$factsF2.writebackSkippedInstall; recordedLine = [bool]$factsF2.recordedLine; recordsKept = [ordered]@{ requirements = $r2.RecReqKept; pyproject = $r2.RecPyKept; header = $r2.RecHdrKept }; headerNames = @($f2.HdrNames) }
    nextRun = [ordered]@{ removalSeenAgain = [bool]$factsF3.removedTermcolor; installFailed = [bool]$factsF3.installFailed; recordedLine = [bool]$factsF3.recordedLine; recordsKept = [ordered]@{ requirements = $r3.RecReqKept; pyproject = $r3.RecPyKept; header = $r3.RecHdrKept } }
}
if (-not $pass) { $detailsF['problems'] = @($problems); $detailsF['excerptF2'] = @(Get-Excerpt $f2.Console) }
Write-DmRow -Id 'self.depmerge.failed.records' -Tag @{ req = 'REQ-005.1.6' } -Pass ([bool]$pass) -Desc 'REQ-005.1: after a good run each input is recorded as it stood, and a run whose install fails records nothing, so the next run sees the same changes again' -Details $detailsF

# ---------------------------------------------------------------- U: a header the user wrote is only ever added to (REQ-005.1.12)
$headerU = "# /// script`n# dependencies = [`n#     `"iniconfig`",`n# ]`n# ///`n"
$appU = $headerU + $stub
$dirU = New-Folder -Name 'u' -Files @{ 'app.py' = $appU; 'requirements.txt' = "termcolor`niniconfig`n" }
$u1 = Invoke-Run -Dir $dirU -Label 'u1' -Env @{ HP_SKIP_PEP723_WRITEBACK = '1' }
$headerTextSameU1 = ((Get-Content -LiteralPath (Join-Path $dirU 'app.py') -Raw -Encoding UTF8) -replace "`r`n", "`n") -ceq $appU
$recU1 = Get-Records $dirU
$hdrRecordExistsU1 = Test-Path -LiteralPath (Join-Path $dirU '~dep_base.pep723.txt')
# The user deletes iniconfig from requirements.txt; the header, which the user wrote, still lists it. The write-back runs now.
[System.IO.File]::WriteAllText((Join-Path $dirU 'requirements.txt'), "termcolor`n", $utf8)
$u2 = Invoke-Run -Dir $dirU -Label 'u2'
$factsU1 = Get-DmFacts -Console $u1.Console -Setup $u1.Setup
$factsU2 = Get-DmFacts -Console $u2.Console -Setup $u2.Setup
$ru1 = [pscustomobject]@{
    Finished = $u1.Finished; Exit = $u1.Exit; State = $u1.State; Facts = $factsU1; HeaderTextSame = [bool]$headerTextSameU1
    RecReq = $recU1.ReqNames; HdrRecordExists = [bool]$hdrRecordExistsU1
}
$ru2 = [pscustomobject]@{ Finished = $u2.Finished; Exit = $u2.Exit; State = $u2.State; Facts = $factsU2; HdrNames = $u2.HdrNames; ReqNames = $u2.ReqNames }
$problems = @(Get-UserHeaderProblems -R1 $ru1 -R2 $ru2)
$pass = ($problems.Count -eq 0)
if (-not $pass) { $anyRed = $true }
$detailsU = [ordered]@{
    firstExit = $u1.Exit; firstState = $u1.State; writebackSwitchedOff = [bool]$factsU1.writebackSkippedFlag; headerTextUnchanged = [bool]$headerTextSameU1
    recordOfRequirements = @($recU1.ReqNames); recordOfHeaderExists = [bool]$hdrRecordExistsU1
    secondExit = $u2.Exit; secondState = $u2.State; writebackSucceeded = [bool]$factsU2.writebackSucceeded; staysLine = [bool]$factsU2.staysHeader
    removedLine = [bool]$factsU2.removedIniconfig; headerRemovedLogged = [bool]$factsU2.headerRemovedLogged
    requirementsNames = @($u2.ReqNames); headerNames = @($u2.HdrNames)
}
if (-not $pass) { $detailsU['problems'] = @($problems); $detailsU['excerptU2'] = @(Get-Excerpt $u2.Console) }
Write-DmRow -Id 'self.depmerge.header.userwrote' -Tag @{ req = 'REQ-005.1.12' } -Pass ([bool]$pass) -Desc 'REQ-005.1: a PEP 723 header the user wrote is only added to; a package the user deleted from requirements.txt but wrote in that header stays in it' -Details $detailsU

# ---------------------------------------------------------------- X and H: the merge cannot run (REQ-005.1.13, REQ-005.1.14)
$pyprojectX = "[project]`nname = `"dmedgex`"`nversion = `"0.1.0`"`ndependencies = [`"iniconfig`"]`n"

# X: the helper cannot be written (the test hook makes the one payload's write fail, as a full disk or an antivirus lock would)
$dirX = New-Folder -Name 'x' -Files @{ 'app.py' = $stub; 'pyproject.toml' = $pyprojectX; 'requirements.txt' = "termcolor`n" }
$x1 = Invoke-Run -Dir $dirX -Label 'x1' -Env @{ HP_TEST_FORCE_EMIT_FAIL = 'HP_DEP_MERGE' }
$factsX = Get-DmFacts -Console $x1.Console -Setup $x1.Setup
$rx = [pscustomobject]@{ Finished = $x1.Finished; Exit = $x1.Exit; State = $x1.State; Facts = $factsX; ReqNames = $x1.ReqNames; Installed = $x1.Installed }
$problems = @(Get-FallbackProblems -Variant 'emit' -R $rx)
$pass = ($problems.Count -eq 0)
if (-not $pass) { $anyRed = $true }
$detailsX = [ordered]@{
    exitCode = $x1.Exit; state = $x1.State; requirementsNames = @($x1.ReqNames); installed = @($x1.Installed)
    forcedFailureLogged = [bool]$factsX.forcedEmitFailure; warnConsole = [bool]$factsX.couldNotMergeConsole; warnSetupLog = [bool]$factsX.couldNotMergeSetup; mergedLine = [bool]$factsX.mergedLine
}
if (-not $pass) { $detailsX['problems'] = @($problems); $detailsX['excerpt'] = @(Get-Excerpt $x1.Console) }
Write-DmRow -Id 'self.depmerge.fallback.emit' -Tag @{ req = 'REQ-005.1.13, REQ-005.1.14' } -Pass ([bool]$pass) -Desc 'REQ-005.1: when the merge helper cannot be written the bootstrapper warns, uses the highest ranked list alone and still finishes the run' -Details $detailsX

# H: the helper fails while it works. The file the helper writes its result to is held open without sharing, so the batch file's del
# cannot remove it and the helper cannot open it (the lock is released as soon as the run is over).
$dirH = New-Folder -Name 'h' -Files @{ 'app.py' = $stub; 'pyproject.toml' = $pyprojectX; 'requirements.txt' = "termcolor`n" }
$lockH = $null
$lockError = ''
try {
    $lockH = [System.IO.File]::Open((Join-Path $dirH '~requirements.merge.tmp'), [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
} catch {
    $lockError = [string]$_.Exception.Message
}
try {
    $h1 = Invoke-Run -Dir $dirH -Label 'h1'
} finally {
    if ($null -ne $lockH) { $lockH.Dispose() }
}
$factsH = Get-DmFacts -Console $h1.Console -Setup $h1.Setup
$rh = [pscustomobject]@{ Finished = $h1.Finished; Exit = $h1.Exit; State = $h1.State; Facts = $factsH; ReqNames = $h1.ReqNames; Installed = $h1.Installed }
$problems = @(Get-FallbackProblems -Variant 'helper' -R $rh)
$pass = ($problems.Count -eq 0)
if (-not $pass) { $anyRed = $true }
$detailsH = [ordered]@{
    exitCode = $h1.Exit; state = $h1.State; requirementsNames = @($h1.ReqNames); installed = @($h1.Installed)
    helperErrorLogged = [bool]$factsH.helperError; warnConsole = [bool]$factsH.couldNotMergeConsole; warnSetupLog = [bool]$factsH.couldNotMergeSetup; mergedLine = [bool]$factsH.mergedLine
    lockHeld = [bool]($null -ne $lockH)
}
if ($lockError) { $detailsH['lockError'] = $lockError }
if (-not $pass) { $detailsH['problems'] = @($problems); $detailsH['excerpt'] = @(Get-Excerpt $h1.Console) }
Write-DmRow -Id 'self.depmerge.fallback.helper' -Tag @{ req = 'REQ-005.1.13, REQ-005.1.14' } -Pass ([bool]$pass) -Desc 'REQ-005.1: when the merge helper fails while it works the bootstrapper warns, uses the highest ranked list alone and still finishes the run' -Details $detailsH

if ($anyRed) { exit 1 }
exit 0
