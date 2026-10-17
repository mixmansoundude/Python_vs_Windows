# ASCII only
# selfapps_honest_wording.ps1 - CLAUDE.md Active Backlog Item 68: the console and the files the
# bootstrapper writes must say what actually happened. Three of the wording defects in that item
# can be reproduced with one small app and three real runs in one folder:
#
#   self.wording.dep_source_warn_shown   - run 1, no requirements.txt and pipreqs on: the console
#                              carries the "Dependencies were auto-detected via pipreqs" warning and
#                              ~dependency_source.txt says pipreqs. The warning's gate tested
#                              `if not defined DEP_SOURCE`, but DEP_SOURCE is initialized to
#                              `unknown` near the top of the file, so the warning could never print
#                              and the file never said pipreqs (the old static row
#                              batch.req005.warn_gate only matched the dead text).
#   self.wording.rebuild_notice          - runs 2 and 3: main.py is edited, so the cached EXE is
#                              stale and is rebuilt. That used to happen silently; one line must now
#                              say the EXE is not being reused and why. Run 1 (no EXE yet) must not
#                              print it. The EXE must really be rebuilt and show the new output, so a
#                              notice that is printed while nothing is rebuilt cannot pass.
#   self.wording.diff_placeholder        - runs 2 and 3: ~pipreqs.diff.txt says which requirements
#                              file is missing instead of "requirements files not both present".
#                              Run 2 has neither file (pipreqs skipped, none written), run 3 has
#                              requirements.txt only.
#
# The other Item 68 fixes are covered where their messages already appear: the fail-fast probe
# line in selfapps_failfast_probe.ps1 and the two Nuitka messages in the static harness.
#
# Lane: real only (gating). One lane is enough: none of this depends on the provider.
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

# Non-Windows skip (OSVersion.Platform works under pwsh and Windows PowerShell 5.1; $IsWindows does not).
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $skipDetails = [ordered]@{ skip = $true; platform = [System.Environment]::OSVersion.Platform.ToString(); reason = 'non-windows-host' }
    Write-NdjsonRow ([ordered]@{ id = 'self.wording.dep_source_warn_shown'; req = 'REQ-005'; pass = $true; desc = 'pipreqs auto-detect warning shown when pipreqs is the only source (skipped on non-Windows)'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.wording.rebuild_notice'; req = 'REQ-007'; pass = $true; desc = 'A stale cached EXE is rebuilt with a notice saying why (skipped on non-Windows)'; details = $skipDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.wording.diff_placeholder'; req = 'REQ-005.5'; pass = $true; desc = 'The pipreqs diff placeholder names the missing file (skipped on non-Windows)'; details = $skipDetails })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    $missingDetails = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    Write-NdjsonRow ([ordered]@{ id = 'self.wording.dep_source_warn_shown'; req = 'REQ-005'; pass = $false; desc = 'pipreqs auto-detect warning: run_setup.bat not found'; details = $missingDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.wording.rebuild_notice'; req = 'REQ-007'; pass = $false; desc = 'Stale EXE rebuild notice: run_setup.bat not found'; details = $missingDetails })
    Write-NdjsonRow ([ordered]@{ id = 'self.wording.diff_placeholder'; req = 'REQ-005.5'; pass = $false; desc = 'pipreqs diff placeholder: run_setup.bat not found'; details = $missingDetails })
    exit 1
}

$workDir = Join-Path $here '~selftest_honest_wording'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

# A standard-library-only program: nothing to install, so every run is mostly the build.
function Set-AppVersion {
    param([string]$Tag)
    Set-Content -Path (Join-Path $workDir 'main.py') -Value "print(`"wording-app-$Tag`")" -Encoding ASCII
}
Set-AppVersion 'v1'

$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$prevLane        = if (Test-Path Env:HP_CI_LANE) { $env:HP_CI_LANE } else { $null }
# A real stop pauses for a keypress unless HP_CI_LANE is set (CI sets it); never hang a local run.
if (-not $env:HP_CI_LANE) { $env:HP_CI_LANE = 'test' }

function Read-Text {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $t = Get-Content -LiteralPath $Path -Raw -Encoding ASCII
    if ($null -eq $t) { return '' }
    return $t
}

# derived requirement: ~setup.log is only rotated past 10 MB, so it keeps growing across runs in one
# folder. Every per-run check reads only the bytes this run appended (offset taken before the run),
# or an earlier run's "Fast path" line would be seen as this run's.
function Read-AppendedText {
    param([string]$Path, [long]$Offset)
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -le $Offset) { return '' }
    return [System.Text.Encoding]::ASCII.GetString($bytes, [int]$Offset, [int]($bytes.Length - $Offset))
}

function Get-ExeFacts {
    $dist = Join-Path $workDir 'dist'
    $exe = $null
    if (Test-Path -LiteralPath $dist) {
        $exe = Get-ChildItem -LiteralPath $dist -Filter *.exe -File | Select-Object -First 1
    }
    if (-not $exe) { return [pscustomobject]@{ Exists = $false; Sha = ''; Ticks = 0 } }
    return [pscustomobject]@{
        Exists = $true
        Sha    = (Get-FileHash -LiteralPath $exe.FullName -Algorithm SHA256).Hash
        Ticks  = $exe.LastWriteTimeUtc.Ticks
    }
}

# Runs the bootstrapper in the work folder, keeps the console capture and this run's slice of
# ~setup.log under per-run names, and returns the facts.
function Invoke-WordingRun {
    param([string]$Tag)
    $consoleName = "~wording_$Tag.log"
    $setupSrc = Join-Path $workDir '~setup.log'
    $setupOffset = 0
    if (Test-Path -LiteralPath $setupSrc) { $setupOffset = (Get-Item -LiteralPath $setupSrc).Length }
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $consoleName 2>&1"
        $rc = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $setupText = Read-AppendedText -Path $setupSrc -Offset $setupOffset
    Set-Content -LiteralPath (Join-Path $workDir "~wording_${Tag}_setup.log") -Value $setupText -Encoding ASCII
    return [pscustomobject]@{
        Exit    = $rc
        Console = (Read-Text (Join-Path $workDir $consoleName))
        Setup   = $setupText
        Diff    = (Read-Text (Join-Path $workDir '~pipreqs.diff.txt')).Trim()
        RunOut  = (Read-Text (Join-Path $workDir '~run.out.txt'))
        Log     = $consoleName
    }
}

$noticePhrase = 'Fast path: not reusing'
$allPass = $true

try {
    # ---- Run 1: no requirements.txt, pipreqs on: pipreqs is the only dependency source ----
    Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    $r1 = Invoke-WordingRun -Tag 'run1'
    $exe1 = Get-ExeFacts
    $c1 = $r1.Console + "`n" + $r1.Setup
    $r1WarnShown   = $c1 -match [regex]::Escape('Dependencies were auto-detected via pipreqs')
    $depFile       = (Read-Text (Join-Path $workDir '~dependency_source.txt')).Trim()
    $r1SourceFile  = $depFile -eq 'dependency_source=pipreqs'
    $r1NoNotice    = -not ($c1 -match [regex]::Escape($noticePhrase))
    $pass1 = ($r1.Exit -eq 0) -and $exe1.Exists -and ($r1.RunOut -match 'wording-app-v1') -and $r1WarnShown -and $r1SourceFile
    if (-not $pass1) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.wording.dep_source_warn_shown'
        req     = 'REQ-005'
        pass    = $pass1
        desc    = 'With no requirements.txt and pipreqs on, the console warns that dependencies were auto-detected and ~dependency_source.txt says pipreqs'
        details = [ordered]@{
            exit = $r1.Exit; exeBuilt = $exe1.Exists; warnShown = $r1WarnShown
            dependencySourceFile = $depFile; sourceFileSaysPipreqs = $r1SourceFile; log = $r1.Log
        }
    })

    # ---- Run 2: edit main.py; neither requirements file exists; pipreqs skipped ----
    Set-AppVersion 'v2'
    foreach ($f in @('requirements.txt', 'requirements.auto.txt')) {
        $p = Join-Path $workDir $f
        if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force }
    }
    $env:HP_SKIP_PIPREQS = '1'
    $exeBefore2 = Get-ExeFacts
    $r2 = Invoke-WordingRun -Tag 'run2'
    $exe2 = Get-ExeFacts
    $c2 = $r2.Console + "`n" + $r2.Setup
    $r2Notice    = $c2 -match [regex]::Escape($noticePhrase)
    $r2Rebuilt   = $exe2.Exists -and (($exe2.Sha -ne $exeBefore2.Sha) -or ($exe2.Ticks -ne $exeBefore2.Ticks))
    $r2NewOutput = $r2.RunOut -match 'wording-app-v2'
    $r2Names     = ($r2.Diff -match [regex]::Escape('requirements.txt')) -and ($r2.Diff -match [regex]::Escape('requirements.auto.txt'))

    # ---- Run 3: edit main.py again; requirements.txt only; pipreqs skipped ----
    Set-AppVersion 'v3'
    Set-Content -Path (Join-Path $workDir 'requirements.txt') -Value 'six' -Encoding ASCII
    $exeBefore3 = Get-ExeFacts
    $r3 = Invoke-WordingRun -Tag 'run3'
    $exe3 = Get-ExeFacts
    $c3 = $r3.Console + "`n" + $r3.Setup
    $r3Notice    = $c3 -match [regex]::Escape($noticePhrase)
    $r3Rebuilt   = $exe3.Exists -and (($exe3.Sha -ne $exeBefore3.Sha) -or ($exe3.Ticks -ne $exeBefore3.Ticks))
    $r3NewOutput = $r3.RunOut -match 'wording-app-v3'
    # Only requirements.auto.txt is missing here, so the placeholder must name that file and must not
    # claim requirements.txt is missing.
    $r3Names     = ($r3.Diff -match [regex]::Escape('requirements.auto.txt')) -and ($r3.Diff -notmatch '(?i)requirements\.txt (is |was )?(missing|not found)')

    $passNotice = $r1NoNotice -and $r2Notice -and $r2Rebuilt -and $r2NewOutput -and $r3Notice -and $r3Rebuilt -and $r3NewOutput -and ($r2.Exit -eq 0) -and ($r3.Exit -eq 0)
    if (-not $passNotice) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.wording.rebuild_notice'
        req     = 'REQ-007'
        pass    = $passNotice
        desc    = 'A stale cached EXE is rebuilt with one line saying it is not being reused; a first build prints no such line'
        details = [ordered]@{
            run1NoNotice = $r1NoNotice
            run2Exit = $r2.Exit; run2Notice = $r2Notice; run2Rebuilt = $r2Rebuilt; run2NewOutput = $r2NewOutput
            run3Exit = $r3.Exit; run3Notice = $r3Notice; run3Rebuilt = $r3Rebuilt; run3NewOutput = $r3NewOutput
            run2Log = $r2.Log; run3Log = $r3.Log
        }
    })

    $passDiff = $r2Names -and $r3Names
    if (-not $passDiff) { $allPass = $false }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.wording.diff_placeholder'
        req     = 'REQ-005.5'
        pass    = $passDiff
        desc    = 'The pipreqs diff placeholder names the requirements file that is missing instead of saying the files are not both present'
        details = [ordered]@{
            run2NamesBothFiles = $r2Names; run2Text = $r2.Diff
            run3NamesAutoFile = $r3Names; run3Text = $r3.Diff
        }
    })
} finally {
    if ($null -eq $prevSkipPipreqs) { Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue } else { $env:HP_SKIP_PIPREQS = $prevSkipPipreqs }
    if ($null -eq $prevLane) { Remove-Item Env:HP_CI_LANE -ErrorAction SilentlyContinue } else { $env:HP_CI_LANE = $prevLane }
}

if (-not $allPass) { exit 1 }
exit 0
