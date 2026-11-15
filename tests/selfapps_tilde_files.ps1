# ASCII only
# selfapps_tilde_files.ps1 - README REQ-003.3, REQ-015.7 and REQ-015.8: where the bootstrapper works, which names it gives the files
# a person keeps, and what deleting its work files costs.
#
# One program folder, bootstrapped twice by default (nothing that skips a step the user would get, except the two optional write-backs
# and the autopep723 discovery, so the folder holds nothing but what the bootstrapper itself writes next to the user's program):
#
#   self.tilde.workfolder  REQ-003.3  the working files (~setup.log, ~bootstrap.status.json) and the build output (dist\<env>.exe) are in
#                                     the folder where the bootstrapper was started, and nothing was created beside that folder, in the
#                                     folder that holds the test scripts or in the repository root
#   self.tilde.keepfiles   REQ-015.7  every file the briefing tells the user to keep (it is read from the briefing the run printed), the
#                                     two git files and the EXE the briefing names are there under a name that does not start with ~,
#                                     although the program folder's own name does (so the EXE is <env>.exe with the ~ turned into _)
#   self.tilde.deletable   REQ-015.8  every ~ file and folder of the program folder is deleted, as the briefing says is safe, and the next
#                                     run still ends ok, runs the program, and leaves the user's own files (the program, requirements.txt,
#                                     runtime.txt and the two git files) as they were
#
# A row passes only on its named sub-checks, and each one also needs the precondition that makes it mean something (the first run ended
# ok, the briefing was printed, the ~ files existed and were really removed), so a run that never got that far cannot pass. The judging
# lives in functions that take plain values and return a list of problems: tests/test_tilde_files.py runs each of them through real pwsh
# on synthetic runs that must be red for every comparison.
#
# derived requirement: ids and req tags stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py and the
# requirement-trace tests scan text, not PowerShell).
#
# Lane: contract-uv only (the lane with the most wall-clock headroom), gating from its first run (AGENTS.md "New tests gate
# immediately"). Two bootstraps with a build each, the first one with the pipreqs scan that writes requirements.txt.
# Emits: self.tilde.workfolder, self.tilde.keepfiles, self.tilde.deletable
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
    Write-NdjsonRow ([ordered]@{ id = 'self.tilde.workfolder'; req = 'REQ-003.3'; pass = $true; desc = 'Working files and build output are in the start folder (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.tilde.keepfiles'; req = 'REQ-015.7'; pass = $true; desc = 'Files the user keeps have no tilde name (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.tilde.deletable'; req = 'REQ-015.8'; pass = $true; desc = 'Deleting the tilde files loses nothing (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.tilde.workfolder'; req = 'REQ-003.3'; pass = $false; desc = 'Working files and build output are in the start folder: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.tilde.keepfiles'; req = 'REQ-015.7'; pass = $false; desc = 'Files the user keeps have no tilde name: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.tilde.deletable'; req = 'REQ-015.8'; pass = $false; desc = 'Deleting the tilde files loses nothing: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

# --- pure helpers (no file system, no process): the unit test runs them through real pwsh ---

# What the briefing of a console text names: the files under "KEEP these files with your project:" (the first word of each line that
# has a " -- " after it) and the EXE under "Your standalone application is ready:" (the path on the next line).
function Get-Briefing {
    param([string]$Console)
    $all = @($Console -split "`r?`n")
    $keep = New-Object System.Collections.ArrayList
    $exe = ''
    $inKeep = $false
    for ($i = 0; $i -lt $all.Count; $i++) {
        $line = [string]$all[$i]
        if ($line -match 'KEEP these files with your project:') { $inKeep = $true; continue }
        if ($inKeep) {
            if ($line -match 'SAFE TO DELETE') { $inKeep = $false }
            else {
                $m = [regex]::Match($line, '^\s+(\S+)\s+--\s')
                if ($m.Success) { [void]$keep.Add($m.Groups[1].Value) }
            }
        }
        if (($exe -eq '') -and ($line -match 'Your standalone application is ready:') -and (($i + 1) -lt $all.Count)) {
            $m2 = [regex]::Match([string]$all[$i + 1], '^\s+(dist\\\S+\.exe)\s*$')
            if ($m2.Success) { $exe = $m2.Groups[1].Value }
        }
    }
    return [pscustomobject][ordered]@{ Keep = @($keep.ToArray()); Exe = $exe }
}

# A text as the comparison sees it: lines trimmed, blank lines dropped, line endings and a missing final newline made equal.
function ConvertTo-Normalized {
    param([string]$Text)
    $out = New-Object System.Collections.ArrayList
    foreach ($l in @(([string]$Text) -split "`r?`n")) {
        $t = ([string]$l).Trim()
        if ($t) { [void]$out.Add($t) }
    }
    return ($out.ToArray() -join "`n")
}

# The names that are new, gone or different between two snapshots, each entry "name|state".
function Get-SnapshotChanges {
    param([string[]]$Before, [string[]]$After)
    $b = @{}
    foreach ($e in @($Before)) { $i = ([string]$e).LastIndexOf('|'); if ($i -ge 0) { $b[$e.Substring(0, $i)] = $e.Substring($i + 1) } }
    $a = @{}
    foreach ($e in @($After)) { $i = ([string]$e).LastIndexOf('|'); if ($i -ge 0) { $a[$e.Substring(0, $i)] = $e.Substring($i + 1) } }
    $changed = New-Object System.Collections.ArrayList
    foreach ($k in @($a.Keys)) { if ((-not $b.ContainsKey($k)) -or ($b[$k] -ne $a[$k])) { [void]$changed.Add($k) } }
    foreach ($k in @($b.Keys)) { if (-not $a.ContainsKey($k)) { [void]$changed.Add($k) } }
    return @($changed.ToArray() | Sort-Object -Unique)
}

# What is wrong with the claim of REQ-003.3. $Inside lists the relative paths found in the program folder, $Beside the entries of the
# folder that holds the program folder, $Outside the changes found in the two folders above the scripts.
function Get-WorkfolderProblems {
    param($Run, [string[]]$Inside, [string[]]$Beside, [string]$FolderName, [string]$ExeLeaf, [string[]]$Outside)
    $out = New-Object System.Collections.ArrayList
    if (-not $Run.Finished) { return @('the bootstrap did not finish within the time limit') }
    if ($Run.State -ne 'ok') { return @(('the bootstrap ended with state [{0}], not ok, so the build output was not judged' -f $Run.State)) }
    foreach ($need in @('~setup.log', '~bootstrap.status.json', ('dist\' + $ExeLeaf))) {
        if (@($Inside) -notcontains $need) { [void]$out.Add('the program folder does not hold ' + $need) }
    }
    $others = @(@($Beside) | Where-Object { $_ -ne $FolderName })
    if ($others.Count -gt 0) { [void]$out.Add('entries were created beside the program folder: ' + ($others -join ', ')) }
    if (@($Beside) -notcontains $FolderName) { [void]$out.Add('the program folder is not in the folder the script made for it') }
    if (@($Outside).Count -gt 0) { [void]$out.Add('names were created or changed in the folder of the scripts or in the repository root: ' + (@($Outside) -join ', ')) }
    return $out.ToArray()
}

# What is wrong with the claim of REQ-015.7. $Present maps nothing: it lists the names of the files that exist in the program folder
# (relative paths). $ExpectedExe is the EXE name the folder name must give (the ~ turned into _).
function Get-KeepProblems {
    param($Run, $Briefing, [string[]]$Present, [string]$FolderName, [string]$ExpectedExe)
    $out = New-Object System.Collections.ArrayList
    if (-not $Run.Finished) { return @('the bootstrap did not finish within the time limit') }
    if ($Run.State -ne 'ok') { return @(('the bootstrap ended with state [{0}], not ok, so the briefing was not judged' -f $Run.State)) }
    if (-not $FolderName.StartsWith('~')) { [void]$out.Add('the program folder name does not start with ~, so the EXE name proves nothing about the tilde') }
    $keep = @($Briefing.Keep)
    if ($keep.Count -eq 0) { return @('the briefing printed no file under "KEEP these files with your project:", so the run never reached the state under test') }
    foreach ($need in @('requirements.txt', 'runtime.txt')) {
        if ($keep -notcontains $need) { [void]$out.Add('the briefing no longer tells the user to keep ' + $need) }
    }
    foreach ($name in $keep) {
        if ($name.StartsWith('~')) { [void]$out.Add('the briefing names a file to keep that starts with ~: ' + $name) }
        elseif (@($Present) -notcontains $name) { [void]$out.Add('the file the briefing says to keep is not in the program folder: ' + $name) }
    }
    foreach ($name in @('.gitignore', '.gitattributes')) {
        if (@($Present) -notcontains $name) { [void]$out.Add('the program folder does not hold ' + $name) }
    }
    $exe = [string]$Briefing.Exe
    if (-not $exe) {
        [void]$out.Add('the briefing does not name the standalone EXE (the line under "Your standalone application is ready:")')
    } else {
        $leaf = Split-Path -Path $exe -Leaf
        if ($leaf.StartsWith('~')) { [void]$out.Add('the EXE the briefing names starts with ~: ' + $leaf) }
        if ($leaf -ne $ExpectedExe) { [void]$out.Add(('the EXE the briefing names is {0}; a program folder named {1} must give {2}' -f $leaf, $FolderName, $ExpectedExe)) }
        if (@($Present) -notcontains $exe) { [void]$out.Add('the EXE the briefing names is not in the program folder: ' + $exe) }
    }
    return $out.ToArray()
}

# What is wrong with the claim of REQ-015.8. $Removed lists what the deletion took away, $Left what it could not remove, $Before and
# $After are "name=text" entries of the user's files as the first run left them and as the second run left them (text already
# normalized), $SeedApp the program as the user wrote it, $AppNow the program after the second run.
function Get-DeletableProblems {
    param($Run1, $Run2, [string[]]$Removed, [string[]]$Left, [string[]]$Before, [string[]]$After, [string]$SeedApp, [string]$AppNow, [string]$Marker, [string]$Out2, [bool]$ExeBack)
    $out = New-Object System.Collections.ArrayList
    if (-not $Run1.Finished) { return @('the first bootstrap did not finish within the time limit') }
    if ($Run1.State -ne 'ok') { return @(('the first bootstrap ended with state [{0}], not ok, so deleting its files was not judged' -f $Run1.State)) }
    if (@($Removed).Count -lt 3 -or @($Removed) -notcontains '~setup.log') { return @(('the deletion took away {0} entries and not ~setup.log, so there was nothing to lose' -f @($Removed).Count)) }
    if (@($Left).Count -gt 0) { return @('some ~ entries could not be removed: ' + (@($Left) -join ', ')) }
    if (-not $Run2.Finished) { return @('the bootstrap after the deletion did not finish within the time limit') }
    if ($Run2.State -ne 'ok') { [void]$out.Add(('the bootstrap after the deletion ended with state [{0}], not ok' -f $Run2.State)) }
    if ($Run2.Exit -ne 0) { [void]$out.Add(('the bootstrap after the deletion ended with exit code {0}' -f $Run2.Exit)) }
    if (-not ([string]$Out2).Contains($Marker)) { [void]$out.Add('the verification run after the deletion did not print the program''s own line (' + $Marker + ')') }
    if (-not $ExeBack) { [void]$out.Add('the EXE is not in dist after the second run') }
    $b = @{}
    foreach ($e in @($Before)) { $i = ([string]$e).IndexOf('='); if ($i -ge 0) { $b[$e.Substring(0, $i)] = $e.Substring($i + 1) } }
    $a = @{}
    foreach ($e in @($After)) { $i = ([string]$e).IndexOf('='); if ($i -ge 0) { $a[$e.Substring(0, $i)] = $e.Substring($i + 1) } }
    foreach ($k in @($b.Keys)) {
        if (-not $a.ContainsKey($k)) { [void]$out.Add('a file of the user is gone after the second run: ' + $k) }
        elseif ($a[$k] -ne $b[$k]) { [void]$out.Add('a file of the user is different after the second run: ' + $k) }
    }
    if ($AppNow -ne $SeedApp) { [void]$out.Add('the program the user wrote is different after the two runs') }
    return $out.ToArray()
}

# A short, printable excerpt of a text for the details of a row: the last lines, ASCII only, so a red row shows what the run said.
function Get-Excerpt {
    param([string]$Text, [int]$Lines = 40)
    $all = @(([string]$Text) -split "`r?`n")
    $tail = @($all | Select-Object -Last $Lines)
    return @($tail | ForEach-Object { (([string]$_) -replace '[^\x20-\x7E]', '?') })
}

# --- the file system and the bootstrapper ---

$utf8 = New-Object System.Text.UTF8Encoding($false)
$marker = 'TILDE_APP_RAN'
$program = "import colorama`nprint('$marker', colorama.__version__, flush=True)`n"
$folderName = '~tilde_work'
$expectedExe = '_tilde_work.exe'
$userFiles = @('app.py', 'requirements.txt', 'runtime.txt', '.gitignore', '.gitattributes')
# A hang must be a red row; one bootstrap of a tiny program with the build needs a few minutes at most.
$runTimeoutMs = 15 * 60 * 1000

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
        if ($null -ne $t) { return [string]$t }
    }
    return ''
}

function Get-StatusState {
    param([string]$Dir)
    $p = Join-Path $Dir '~bootstrap.status.json'
    if (-not (Test-Path -LiteralPath $p)) { return '' }
    try { return [string]((Get-Content -LiteralPath $p -Raw -Encoding ASCII | ConvertFrom-Json).state) } catch { return '' }
}

# One bootstrap of the folder; never throws. The variables the run needs are set in the launched shell and cleared again after it:
# every one that could start, skip or answer for the program is named, so the runner's own settings cannot decide the result.
function Invoke-Run {
    param([string]$Dir, [string]$LogName)
    $res = [ordered]@{ Finished = $false; Exit = -1; State = ''; Console = ''; Setup = ''; Out = ''; Error = '' }
    try {
        $wrapper = Join-Path $Dir '~tl_launch.cmd'
        $vars = [ordered]@{
            HP_SKIP_AUTOPEP_DISCOVERY = '1'; HP_SKIP_PEP723_WRITEBACK = '1'
            HP_SKIP_PIPREQS = ''; HP_SKIP_NIVISA = ''; HP_SKIP_ENTRY_SMOKE = ''; HP_SKIP_EXE_SMOKERUN = ''; HP_TEST_FORCE_EMIT_FAIL = ''
            HP_TEST_REPAIR_ANSWER = ''; HP_TEST_LASTCHANCE_ANSWER = ''; HP_TEST_CHECKPOINT_ANSWER = ''; HP_TEST_RTM_ANSWER = ''
            HP_PVW_KNOWN_IDEMPOTENT = ''; PVW_BUILDER = ''; PVW_PROVIDER = ''
        }
        if (-not [Environment]::GetEnvironmentVariable('HP_CI_LANE')) { $vars['HP_CI_LANE'] = 'test' }
        $lines = New-Object System.Collections.ArrayList
        [void]$lines.Add('@echo off')
        foreach ($k in @($vars.Keys)) {
            if ($k -notmatch '^[A-Za-z0-9_]+$' -or ([string]$vars[$k]) -notmatch '^[A-Za-z0-9_.=-]*$') { throw "unsafe variable $k" }
            [void]$lines.Add(('set "{0}={1}"' -f $k, $vars[$k]))
        }
        [void]$lines.Add("call run_setup.bat app.py > $LogName 2>&1 < nul")
        [void]$lines.Add('exit /b %ERRORLEVEL%')
        Set-Content -LiteralPath $wrapper -Value $lines.ToArray() -Encoding ASCII
        $saved = @{}
        foreach ($k in @($vars.Keys)) {
            $saved[$k] = [Environment]::GetEnvironmentVariable($k)
            if ([string]$vars[$k] -eq '') { Remove-Item -LiteralPath ('Env:' + $k) -ErrorAction SilentlyContinue } else { [Environment]::SetEnvironmentVariable($k, [string]$vars[$k]) }
        }
        try {
            $p = Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c', 'call ~tl_launch.cmd') -WorkingDirectory $Dir -NoNewWindow -PassThru
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
        $res.Console = Read-Text (Join-Path $Dir $LogName)
        $res.Setup = Read-Text (Join-Path $Dir '~setup.log')
        $res.Out = Read-Text (Join-Path $Dir '~run.out.txt')
        $res.State = Get-StatusState $Dir
    } catch {
        $res.Error = [string]$_.Exception.Message
    }
    return [pscustomobject]$res
}

# "name|state" for every entry directly inside a folder, a folder as dir, a file with its length and its last write time. The two
# files this script writes its own rows to are left out.
function Get-DirSnapshot {
    param([string]$Path)
    $skip = @('~test-results.ndjson', 'ci_test_results.ndjson')
    $list = New-Object System.Collections.ArrayList
    foreach ($e in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)) {
        if ($skip -contains $e.Name) { continue }
        if ($e.PSIsContainer) { [void]$list.Add($e.Name + '|dir') }
        else { [void]$list.Add(('{0}|file:{1}:{2}' -f $e.Name, $e.Length, $e.LastWriteTimeUtc.Ticks)) }
    }
    return @($list.ToArray())
}

# The relative paths (files and folders) that exist from a list of candidates.
function Get-Existing {
    param([string]$Dir, [string[]]$Candidates)
    $found = New-Object System.Collections.ArrayList
    foreach ($c in @($Candidates)) { if (Test-Path -LiteralPath (Join-Path $Dir $c)) { [void]$found.Add($c) } }
    return @($found.ToArray())
}

# The user's files as "name=normalized text" entries.
function Get-UserFileEntries {
    param([string]$Dir, [string[]]$Names)
    $list = New-Object System.Collections.ArrayList
    foreach ($n in @($Names)) {
        $p = Join-Path $Dir $n
        if (Test-Path -LiteralPath $p) {
            $t = ConvertTo-Normalized (Read-Text $p)
            if ($n -eq 'requirements.txt') { $t = (@($t -split "`n" | Sort-Object) -join "`n") }
            [void]$list.Add($n + '=' + $t)
        }
    }
    return @($list.ToArray())
}

# Every entry of the program folder whose name starts with ~, and the ones directly in dist and build. Returns what was removed and
# what could not be. Never throws.
function Remove-TildeEntries {
    param([string]$Dir)
    $removed = New-Object System.Collections.ArrayList
    $left = New-Object System.Collections.ArrayList
    foreach ($sub in @('', 'dist', 'build')) {
        $base = if ($sub) { Join-Path $Dir $sub } else { $Dir }
        if (-not (Test-Path -LiteralPath $base)) { continue }
        foreach ($e in @(Get-ChildItem -LiteralPath $base -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name.StartsWith('~') })) {
            $rel = if ($sub) { $sub + '\' + $e.Name } else { $e.Name }
            try {
                Remove-Item -LiteralPath $e.FullName -Recurse -Force -ErrorAction Stop
                [void]$removed.Add($rel)
            } catch {
                [void]$left.Add($rel)
            }
        }
    }
    return [pscustomobject]@{ Removed = @($removed.ToArray()); Left = @($left.ToArray()) }
}

$root = Join-Path $here '~selftest_tilde_root'
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
$dir = Join-Path $root $folderName
New-Item -ItemType Directory -Force -Path $dir | Out-Null
Copy-Item -LiteralPath $batchPath -Destination $dir -Force
[System.IO.File]::WriteAllText((Join-Path $dir 'app.py'), $program, $utf8)
$seedApp = ConvertTo-Normalized (Read-Text (Join-Path $dir 'app.py'))

# --- first run, and what it says about where things are and what they are called ---
$outsideBefore = @((Get-DirSnapshot $here) | ForEach-Object { 'tests/' + $_ }) + @((Get-DirSnapshot $repo) | ForEach-Object { 'root/' + $_ })
$run1 = Invoke-Run -Dir $dir -LogName '~tl_console1.log'
$outsideAfter = @((Get-DirSnapshot $here) | ForEach-Object { 'tests/' + $_ }) + @((Get-DirSnapshot $repo) | ForEach-Object { 'root/' + $_ })
$outside = @(Get-SnapshotChanges -Before $outsideBefore -After $outsideAfter)
$briefing = Get-Briefing $run1.Console
$beside = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
$exeRel = if ($briefing.Exe) { $briefing.Exe } else { 'dist\' + $expectedExe }
$inside = @(Get-Existing -Dir $dir -Candidates @('~setup.log', '~bootstrap.status.json', ('dist\' + $expectedExe), 'dist', '.uv_env', '~uv_bin'))
$present = @(Get-Existing -Dir $dir -Candidates (@($briefing.Keep) + @('.gitignore', '.gitattributes', $exeRel)))
Write-Host '=== tilde files: the first bootstrap ==='
Write-Host ("finished={0} exit={1} state={2} keep=[{3}] exe=[{4}]" -f $run1.Finished, $run1.Exit, $run1.State, ($briefing.Keep -join ','), $briefing.Exe)
foreach ($l in @(Get-Excerpt $run1.Console 25)) { Write-Host ('console1: ' + $l) }
if ($run1.Error) { Write-Host ('error: ' + $run1.Error) }

$entries1 = @(Get-UserFileEntries -Dir $dir -Names $userFiles)
$anyRed = $false

$workProblems = @(Get-WorkfolderProblems -Run $run1 -Inside $inside -Beside $beside -FolderName $folderName -ExeLeaf $expectedExe -Outside $outside)
$workPass = ($workProblems.Count -eq 0)
if (-not $workPass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id      = 'self.tilde.workfolder'
    req     = 'REQ-003.3'
    pass    = $workPass
    desc    = 'The working files and the build output are created in the folder where the bootstrapper was started, and nothing beside it'
    details = [ordered]@{
        problems = @($workProblems); finished = [bool]$run1.Finished; exitCode = $run1.Exit; state = $run1.State
        inside = @($inside); beside = @($beside); outside = @($outside)
        excerpt = $(if ($workPass) { @() } else { @(Get-Excerpt $run1.Console 40) })
    }
})

$keepProblems = @(Get-KeepProblems -Run $run1 -Briefing $briefing -Present $present -FolderName $folderName -ExpectedExe $expectedExe)
$keepPass = ($keepProblems.Count -eq 0)
if (-not $keepPass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id      = 'self.tilde.keepfiles'
    req     = 'REQ-015.7'
    pass    = $keepPass
    desc    = 'Every file the user is told to keep or share has a name that does not start with a tilde, also when the program folder does'
    details = [ordered]@{
        problems = @($keepProblems); finished = [bool]$run1.Finished; state = $run1.State; folder = $folderName
        keep = @($briefing.Keep); exe = [string]$briefing.Exe; present = @($present)
        excerpt = $(if ($keepPass) { @() } else { @(Get-Excerpt $run1.Console 40) })
    }
})

# --- the deletion the briefing calls safe, and the second run ---
$run2 = [pscustomobject]@{ Finished = $false; Exit = -1; State = ''; Console = ''; Setup = ''; Out = ''; Error = '' }
$deleted = [pscustomobject]@{ Removed = @(); Left = @() }
$entries2 = @()
$appNow = ''
$exeBack = $false
if ($run1.Finished -and $run1.State -eq 'ok') {
    $deleted = Remove-TildeEntries -Dir $dir
    Write-Host ('removed: ' + (@($deleted.Removed) -join ', '))
    if (@($deleted.Left).Count -gt 0) { Write-Host ('left: ' + (@($deleted.Left) -join ', ')) }
    if (@($deleted.Left).Count -eq 0) {
        $run2 = Invoke-Run -Dir $dir -LogName '~tl_console2.log'
        $entries2 = @(Get-UserFileEntries -Dir $dir -Names $userFiles)
        $appNow = ConvertTo-Normalized (Read-Text (Join-Path $dir 'app.py'))
        $exeBack = Test-Path -LiteralPath (Join-Path $dir ('dist\' + $expectedExe))
        Write-Host '=== tilde files: the bootstrap after the deletion ==='
        Write-Host ("finished={0} exit={1} state={2} exeBack={3}" -f $run2.Finished, $run2.Exit, $run2.State, $exeBack)
        foreach ($l in @(Get-Excerpt $run2.Console 25)) { Write-Host ('console2: ' + $l) }
        if ($run2.Error) { Write-Host ('error: ' + $run2.Error) }
    }
}
$delProblems = @(Get-DeletableProblems -Run1 $run1 -Run2 $run2 -Removed @($deleted.Removed) -Left @($deleted.Left) -Before $entries1 -After $entries2 -SeedApp $seedApp -AppNow $appNow -Marker $marker -Out2 $run2.Out -ExeBack $exeBack)
$delPass = ($delProblems.Count -eq 0)
if (-not $delPass) { $anyRed = $true }
Write-NdjsonRow ([ordered]@{
    id      = 'self.tilde.deletable'
    req     = 'REQ-015.8'
    pass    = $delPass
    desc    = 'Deleting every tilde file and folder loses nothing: the next run ends ok, runs the program and leaves the files of the user as they were'
    details = [ordered]@{
        problems = @($delProblems); firstState = $run1.State; secondFinished = [bool]$run2.Finished; secondState = $run2.State; secondExit = $run2.Exit
        removed = @($deleted.Removed); left = @($deleted.Left); exeBack = [bool]$exeBack
        userFiles = @($entries1 | ForEach-Object { ($_ -split '=', 2)[0] })
        excerpt = $(if ($delPass) { @() } else { @(Get-Excerpt $run2.Console 40) })
    }
})

# The deletion removes the first bootstrap's own console log and setup log together with the other ~ files, so what that run said is
# kept here, outside the program folder (the second run's files stay in the program folder and are uploaded as they are). It is
# written last, after every folder was listed, so it cannot be mistaken for something the bootstrapper created. ASCII only, and only
# the last lines of each text, so a long log cannot fill the artifact.
$evidence = New-Object System.Collections.ArrayList
[void]$evidence.Add(('=== first bootstrap: finished={0} exit={1} state={2}' -f $run1.Finished, $run1.Exit, $run1.State))
foreach ($l in @(Get-Excerpt $run1.Console 600)) { [void]$evidence.Add([string]$l) }
[void]$evidence.Add('=== first bootstrap: the setup log it wrote (the deletion removes that file)')
foreach ($l in @(Get-Excerpt $run1.Setup 400)) { [void]$evidence.Add([string]$l) }
[void]$evidence.Add('=== removed by the deletion: ' + (@($deleted.Removed) -join ', '))
[void]$evidence.Add('=== left by the deletion: ' + (@($deleted.Left) -join ', '))
[void]$evidence.Add(('=== second bootstrap: finished={0} exit={1} state={2} exeBack={3}' -f $run2.Finished, $run2.Exit, $run2.State, $exeBack))
foreach ($l in @(Get-Excerpt $run2.Out 40)) { [void]$evidence.Add([string]$l) }
try {
    [System.IO.File]::WriteAllLines((Join-Path $here '~tilde_files_evidence.txt'), [string[]]$evidence.ToArray(), $utf8)
} catch {
    Write-Host ('could not write the evidence file: ' + $_.Exception.Message)
}

if ($anyRed) { exit 1 }
exit 0
