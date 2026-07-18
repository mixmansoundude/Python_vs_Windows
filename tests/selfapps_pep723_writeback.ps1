# ASCII only
# selfapps_pep723_writeback.ps1 - Test REQ-005.11 PEP 723 header write-back (uv add --script).
#
# Scenarios (controlled by PEP723_SCENARIO env var; default: fresh):
#
#   fresh                - No existing header; stub imports requests (pipreqs/heuristic
#                          resolves requests+certifi); no requirements.txt/pyproject.toml.
#                          Emits: self.pep723.writeback.fresh
#
#   idempotent           - Runs the bootstrapper twice in the same scratch dir without
#                          deleting or modifying the entry file. dist\<env>.exe is removed
#                          between runs so the EXE fast path cannot short-circuit run 2
#                          before it reaches :lock_done -- forces a genuine second
#                          uv add --script invocation, not a trivially-unchanged file from
#                          an early exit.
#                          Emits: self.pep723.writeback.idempotent
#
#   skipflag              - HP_SKIP_PEP723_WRITEBACK=1; no pre-existing header.
#                          Emits: self.pep723.writeback.skipflag
#
#   malformed             - Entry pre-seeded with a deliberately broken # /// script block.
#                          Strip-and-retry must succeed and remove the broken content.
#                          Emits: self.pep723.writeback.malformed
#
#   trailing_ws_malformed - Entry pre-seeded with an otherwise-valid header whose closing
#                          # /// fence has trailing whitespace (astral-sh/uv#10918) --
#                          looks fine to a human, invalid to uv's strict parser.
#                          Emits: self.pep723.writeback.trailing_ws_malformed
#
#   existing_lockfile     - No pre-existing header, but a <entry>.py.lock sidecar is
#                          pre-created before the run. Helper must never invoke uv.
#                          Emits: self.pep723.writeback.existing_lockfile
#
#   non_utf8              - Entry's body is written with a deliberately non-UTF-8 byte
#                          sequence (cp1252 smart quotes) under a PEP 263 coding cookie
#                          (so Python itself can still compile it). HP_SKIP_PIPREQS=1 and
#                          a plain requirements.txt are used so pipreqs -- which crashes
#                          unhandled on non-UTF-8 source regardless of any coding cookie,
#                          a pre-existing limitation independent of this feature -- never
#                          touches the file; only the write-back helper's own encoding
#                          pre-check needs to be exercised here.
#                          Emits: self.pep723.writeback.non_utf8
#
#   warnfix                - Entry imports xlrd (not heuristic-covered, HP_SKIP_PIPREQS=1
#                          so pipreqs never discovers it) forcing the warnfix repair loop
#                          to fire during the build; the SECOND (warnfix) trigger point
#                          must write back the warnfix-only-discovered module.
#                          Emits: self.pep723.writeback.warnfix
#
# v1 scope gate: the feature only runs under HP_ENV_MODE=uv (docs/plan-pep723-writeback.md
# Part 2.2). Any lane/run that resolves to a non-uv provider (e.g. conda-full, where
# HP_FORCE_CONDA_ONLY=1 blocks uv entirely) emits skip=true reason=provider_not_uv, mirroring
# the established Get-CondaBatPath skip-pattern used elsewhere in this suite (see
# docs/agent-interconnect.md "Skip pattern template").
#
# Lane: real/cache/uv/contract-uv (any uv-first lane).
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

# derived requirement: a small wrapper so every call site below only needs a single line
# with a LITERAL -Id value -- tools/check_ndjson_registry.py's PowerShell scanner
# (CODE_NAMEDPARAM_ID_RE) matches a literal `-Id '...'` the same way it matches a literal
# `id = '...'` hashtable key, so this keeps every row id scanner-visible without repeating
# a 5-key hashtable literal at each of the ~20 call sites this file needs.
function Write-Pep723Row {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = $Id; req = 'REQ-005.11'; pass = $Pass; desc = $Desc; details = $Details })
}

function Test-BytesEqual {
    param([byte[]]$A, [byte[]]$B)
    return ($null -ne $A) -and ($null -ne $B) -and ($A.Length -eq $B.Length) -and
           (Compare-Object $A $B -SyncWindow 0 | Measure-Object).Count -eq 0
}

$scenario = if ($env:PEP723_SCENARIO) { $env:PEP723_SCENARIO.ToLower() } else { 'fresh' }

$workDirName = switch ($scenario) {
    'idempotent'             { '~selftest_pep723_idempotent' }
    'skipflag'               { '~selftest_pep723_skipflag' }
    'malformed'               { '~selftest_pep723_malformed' }
    'trailing_ws_malformed'   { '~selftest_pep723_trailing_ws' }
    'existing_lockfile'       { '~selftest_pep723_lockfile' }
    'non_utf8'                { '~selftest_pep723_nonutf8' }
    'warnfix'                 { '~selftest_pep723_warnfix' }
    default                   { '~selftest_pep723_fresh' }
}
$bootstrapLog = "~pep723_$($scenario)_bootstrap.log"

# Non-Windows skip
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    $skipDetails = [ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' }
    switch ($scenario) {
        'idempotent'             { Write-Pep723Row -Id 'self.pep723.writeback.idempotent' -Pass $true -Desc "PEP 723 write-back $scenario (skipped on non-Windows)" -Details $skipDetails }
        'skipflag'               { Write-Pep723Row -Id 'self.pep723.writeback.skipflag' -Pass $true -Desc "PEP 723 write-back $scenario (skipped on non-Windows)" -Details $skipDetails }
        'malformed'               { Write-Pep723Row -Id 'self.pep723.writeback.malformed' -Pass $true -Desc "PEP 723 write-back $scenario (skipped on non-Windows)" -Details $skipDetails }
        'trailing_ws_malformed'   { Write-Pep723Row -Id 'self.pep723.writeback.trailing_ws_malformed' -Pass $true -Desc "PEP 723 write-back $scenario (skipped on non-Windows)" -Details $skipDetails }
        'existing_lockfile'       { Write-Pep723Row -Id 'self.pep723.writeback.existing_lockfile' -Pass $true -Desc "PEP 723 write-back $scenario (skipped on non-Windows)" -Details $skipDetails }
        'non_utf8'                { Write-Pep723Row -Id 'self.pep723.writeback.non_utf8' -Pass $true -Desc "PEP 723 write-back $scenario (skipped on non-Windows)" -Details $skipDetails }
        'warnfix'                 { Write-Pep723Row -Id 'self.pep723.writeback.warnfix' -Pass $true -Desc "PEP 723 write-back $scenario (skipped on non-Windows)" -Details $skipDetails }
        default                   { Write-Pep723Row -Id 'self.pep723.writeback.fresh' -Pass $true -Desc "PEP 723 write-back $scenario (skipped on non-Windows)" -Details $skipDetails }
    }
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    $missingDetails = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    switch ($scenario) {
        'idempotent'             { Write-Pep723Row -Id 'self.pep723.writeback.idempotent' -Pass $false -Desc "PEP 723 write-back $scenario`: run_setup.bat not found" -Details $missingDetails }
        'skipflag'               { Write-Pep723Row -Id 'self.pep723.writeback.skipflag' -Pass $false -Desc "PEP 723 write-back $scenario`: run_setup.bat not found" -Details $missingDetails }
        'malformed'               { Write-Pep723Row -Id 'self.pep723.writeback.malformed' -Pass $false -Desc "PEP 723 write-back $scenario`: run_setup.bat not found" -Details $missingDetails }
        'trailing_ws_malformed'   { Write-Pep723Row -Id 'self.pep723.writeback.trailing_ws_malformed' -Pass $false -Desc "PEP 723 write-back $scenario`: run_setup.bat not found" -Details $missingDetails }
        'existing_lockfile'       { Write-Pep723Row -Id 'self.pep723.writeback.existing_lockfile' -Pass $false -Desc "PEP 723 write-back $scenario`: run_setup.bat not found" -Details $missingDetails }
        'non_utf8'                { Write-Pep723Row -Id 'self.pep723.writeback.non_utf8' -Pass $false -Desc "PEP 723 write-back $scenario`: run_setup.bat not found" -Details $missingDetails }
        'warnfix'                 { Write-Pep723Row -Id 'self.pep723.writeback.warnfix' -Pass $false -Desc "PEP 723 write-back $scenario`: run_setup.bat not found" -Details $missingDetails }
        default                   { Write-Pep723Row -Id 'self.pep723.writeback.fresh' -Pass $false -Desc "PEP 723 write-back $scenario`: run_setup.bat not found" -Details $missingDetails }
    }
    exit 1
}

$workDir = Join-Path $here $workDirName
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

$appPath = Join-Path $workDir 'app.py'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Utf8NoBom {
    param([string]$Path, [string]$Text)
    [System.IO.File]::WriteAllText($Path, $Text, $utf8NoBom)
}

# derived requirement: per-scenario stub construction. Each scenario needs a different
# pre-existing entry-file state (no header / broken header / trailing-ws header /
# non-UTF-8 body / a different import) to exercise a different branch of
# tools/pep723_writeback.py or a different :pep723_writeback trigger.
switch ($scenario) {
    'malformed' {
        Write-Utf8NoBom -Path $appPath -Text "# /// script`nbroken toml (((`n# ///`nimport requests`nprint('hi')`n"
    }
    'trailing_ws_malformed' {
        # Trailing whitespace on the closing fence line, built explicitly (not via a
        # here-string) so it survives regardless of editor/tooling trailing-space trimming.
        $text = "# /// script`n# dependencies = [`"click`"]`n# ///" + "   " + "`nimport requests`nprint('hi')`n"
        Write-Utf8NoBom -Path $appPath -Text $text
    }
    'non_utf8' {
        # cp1252 smart-quote bytes (0x93/0x94) are not valid UTF-8; the PEP 263 coding
        # cookie lets Python itself still compile the file, but the write-back helper's
        # own strict UTF-8 pre-check must still skip it. HP_SKIP_PIPREQS=1 (set below)
        # keeps pipreqs -- which does NOT respect the coding cookie and crashes unhandled
        # on non-UTF-8 source, confirmed directly against a real pipreqs 0.4.13 -- away
        # from ever reading this file.
        $bytes = [System.Collections.Generic.List[byte]]::new()
        $bytes.AddRange([byte[]][System.Text.Encoding]::ASCII.GetBytes("# -*- coding: cp1252 -*-`nimport requests`n# smart quotes: "))
        $bytes.Add([byte]0x93)
        $bytes.AddRange([byte[]][System.Text.Encoding]::ASCII.GetBytes('test'))
        $bytes.Add([byte]0x94)
        $bytes.AddRange([byte[]][System.Text.Encoding]::ASCII.GetBytes("`nprint('hi')`n"))
        [System.IO.File]::WriteAllBytes($appPath, $bytes.ToArray())
        Write-Utf8NoBom -Path (Join-Path $workDir 'requirements.txt') -Text "requests`n"
    }
    'warnfix' {
        # Mirrors tests/selfapps_warnfix.ps1's real_warnfix scenario: xlrd is not covered
        # by any REQ-005.8 heuristic, and with pipreqs skipped nothing else discovers it,
        # so the warnfix repair loop is the ONLY path that installs it -- proving the
        # warnfix trigger (not the fresh trigger, which has no requirements.txt here)
        # is what fires the second :pep723_writeback call.
        Write-Utf8NoBom -Path $appPath -Text "import xlrd`n_ = xlrd.__version__`nprint('hi')`n"
    }
    default {
        Write-Utf8NoBom -Path $appPath -Text "import requests`nprint('hi')`n"
    }
}
$entryBytesPreRun = [System.IO.File]::ReadAllBytes($appPath)

$lockSidecarPath = "$appPath.lock"
if ($scenario -eq 'existing_lockfile') {
    Write-Utf8NoBom -Path $lockSidecarPath -Text ''
}

$envLeaf = Split-Path $workDir -Leaf
$envName = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_pep723' }
$distDir = Join-Path $workDir 'dist'
$exePath = Join-Path $distDir "$envName.exe"

$prevSkipFlag = if (Test-Path Env:HP_SKIP_PEP723_WRITEBACK) { $env:HP_SKIP_PEP723_WRITEBACK } else { $null }
if ($scenario -eq 'skipflag') {
    $env:HP_SKIP_PEP723_WRITEBACK = '1'
} else {
    Remove-Item Env:HP_SKIP_PEP723_WRITEBACK -ErrorAction SilentlyContinue
}

# derived requirement: non_utf8 and warnfix both need pipreqs kept away from the entry
# file (see the per-scenario comments above); skipflag/fresh/idempotent/malformed/
# trailing_ws_malformed/existing_lockfile all want pipreqs running normally so dependency
# discovery still happens for the fresh trigger.
$prevSkipPipreqs = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
if ($scenario -eq 'non_utf8' -or $scenario -eq 'warnfix') {
    $env:HP_SKIP_PIPREQS = '1'
} else {
    Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
}

function Invoke-Bootstrap {
    param([string]$LogName)
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $LogName 2>&1"
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

try {
    $run1Exit = Invoke-Bootstrap -LogName $bootstrapLog
    $run2Exit = $null
    $entryBytesAfterRun1 = if (Test-Path -LiteralPath $appPath) { [System.IO.File]::ReadAllBytes($appPath) } else { $null }
    if ($scenario -eq 'idempotent') {
        # Force a real second write-back invocation: remove the cached EXE so the top-of-file
        # EXE fast path (which would otherwise short-circuit straight to :success on an
        # unchanged source hash, per docs/agent-interconnect.md "EXE fast path vs env-state
        # fast path") cannot fire, and :lock_done -> :pep723_writeback runs again for real.
        if (Test-Path -LiteralPath $exePath) { Remove-Item -Force -LiteralPath $exePath }
        $bootstrapLog2 = '~pep723_idempotent_bootstrap_run2.log'
        $run2Exit = Invoke-Bootstrap -LogName $bootstrapLog2
    }
} finally {
    if ($null -eq $prevSkipFlag) {
        Remove-Item Env:HP_SKIP_PEP723_WRITEBACK -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PEP723_WRITEBACK = $prevSkipFlag
    }
    if ($null -eq $prevSkipPipreqs) {
        Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PIPREQS = $prevSkipPipreqs
    }
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText
if ($scenario -eq 'idempotent') {
    $logPath2  = Join-Path $workDir '~pep723_idempotent_bootstrap_run2.log'
    $logLines2 = if (Test-Path $logPath2) { Get-Content -LiteralPath $logPath2 -Encoding ASCII } else { @() }
    $setupText2 = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
    $combined2 = ($logLines2 -join "`n") + "`n" + $setupText2
}

$uvEnvPy  = Join-Path $workDir '.uv_env\Scripts\python.exe'
$isUvMode = Test-Path -LiteralPath $uvEnvPy

$successPhrase   = '[INFO] REQ-005.11: PEP 723 header write-back succeeded via uv add --script.'
$skipflagPhrase  = '[INFO] REQ-005.11: PEP 723 write-back skipped (HP_SKIP_PEP723_WRITEBACK set).'
$lockfilePhrase  = '[INFO] REQ-005.11: PEP 723 write-back skipped (a .py.lock sidecar already exists).'
$nonUtf8Phrase   = '[INFO] REQ-005.11: PEP 723 write-back skipped (entry file is not UTF-8).'
$successFired1   = $combined -match [regex]::Escape($successPhrase)
$skipflagFired1  = $combined -match [regex]::Escape($skipflagPhrase)
$lockfileFired1  = $combined -match [regex]::Escape($lockfilePhrase)
$nonUtf8Fired1   = $combined -match [regex]::Escape($nonUtf8Phrase)

if (-not $isUvMode) {
    $skipDetails2 = [ordered]@{ skip = $true; scenario = $scenario; reason = 'provider_not_uv' }
    switch ($scenario) {
        'idempotent'             { Write-Pep723Row -Id 'self.pep723.writeback.idempotent' -Pass $true -Desc "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)" -Details $skipDetails2 }
        'skipflag'               { Write-Pep723Row -Id 'self.pep723.writeback.skipflag' -Pass $true -Desc "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)" -Details $skipDetails2 }
        'malformed'               { Write-Pep723Row -Id 'self.pep723.writeback.malformed' -Pass $true -Desc "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)" -Details $skipDetails2 }
        'trailing_ws_malformed'   { Write-Pep723Row -Id 'self.pep723.writeback.trailing_ws_malformed' -Pass $true -Desc "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)" -Details $skipDetails2 }
        'existing_lockfile'       { Write-Pep723Row -Id 'self.pep723.writeback.existing_lockfile' -Pass $true -Desc "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)" -Details $skipDetails2 }
        'non_utf8'                { Write-Pep723Row -Id 'self.pep723.writeback.non_utf8' -Pass $true -Desc "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)" -Details $skipDetails2 }
        'warnfix'                 { Write-Pep723Row -Id 'self.pep723.writeback.warnfix' -Pass $true -Desc "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)" -Details $skipDetails2 }
        default                   { Write-Pep723Row -Id 'self.pep723.writeback.fresh' -Pass $true -Desc "PEP 723 write-back $scenario (v1 scope gate: HP_ENV_MODE did not resolve to uv)" -Details $skipDetails2 }
    }
    exit 0
}

$entryText = if (Test-Path -LiteralPath $appPath) { [System.IO.File]::ReadAllText($appPath) } else { '' }

if ($scenario -eq 'fresh') {
    $hasBlockStart = $entryText -match [regex]::Escape('# /// script')
    $hasBlockEnd   = $entryText -match [regex]::Escape('# ///')
    $hasRequiresPy = $entryText -match 'requires-python'
    $hasRequests   = $entryText -match 'requests'
    # derived requirement: certifi is NOT asserted here. Confirmed via a real CI run that
    # the REQ-005.8.2 requests->certifi heuristic augments ~reqs_conda.txt/~reqs_pip.txt
    # (conda/pip-targeted translated files), not requirements.txt itself -- and
    # requirements.txt is the packages source :pep723_writeback's fresh trigger actually
    # reads. certifi still gets installed (pip/uv resolve it as requests' own transitive
    # dependency), just never explicitly in requirements.txt, so it correctly never
    # appears in the written header either -- this is accurate, not a gap: a PEP 723
    # header should declare direct dependencies, not hand-pin every transitive one.
    $freshPass = $successFired1 -and $hasBlockStart -and $hasBlockEnd -and $hasRequiresPy -and $hasRequests
    Write-Pep723Row -Id 'self.pep723.writeback.fresh' -Pass $freshPass -Desc 'Fresh dependency install wrote a PEP 723 header via uv add --script' -Details ([ordered]@{
        scenario       = $scenario
        exitCode       = $run1Exit
        successFired   = $successFired1
        hasBlockStart  = $hasBlockStart
        hasBlockEnd    = $hasBlockEnd
        hasRequiresPy  = $hasRequiresPy
        hasRequests    = $hasRequests
    })
    if (-not $freshPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'skipflag') {
    $bytesEqual = Test-BytesEqual $entryBytesPreRun $entryBytesAfterRun1
    $skipPass = $skipflagFired1 -and $bytesEqual -and (-not $successFired1)
    Write-Pep723Row -Id 'self.pep723.writeback.skipflag' -Pass $skipPass -Desc 'HP_SKIP_PEP723_WRITEBACK=1 suppresses write-back; entry file untouched' -Details ([ordered]@{
        scenario      = $scenario
        exitCode      = $run1Exit
        skipflagFired = $skipflagFired1
        successFired  = $successFired1
        bytesEqual    = $bytesEqual
    })
    if (-not $skipPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'idempotent') {
    $successFired2 = $combined2 -match [regex]::Escape($successPhrase)
    $entryBytesAfterRun2 = if (Test-Path -LiteralPath $appPath) { [System.IO.File]::ReadAllBytes($appPath) } else { $null }
    $bytesEqual = Test-BytesEqual $entryBytesAfterRun1 $entryBytesAfterRun2
    $idempotentPass = $successFired1 -and $successFired2 -and $bytesEqual
    Write-Pep723Row -Id 'self.pep723.writeback.idempotent' -Pass $idempotentPass -Desc 'Two full bootstrap runs produce a byte-identical PEP 723 header (uv add --script idempotency)' -Details ([ordered]@{
        scenario      = $scenario
        run1Exit      = $run1Exit
        run2Exit      = $run2Exit
        successFired1 = $successFired1
        successFired2 = $successFired2
        bytesEqual    = $bytesEqual
    })
    if (-not $idempotentPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'malformed') {
    $hasRequiresPy = $entryText -match 'requires-python'
    $hasRequests   = $entryText -match 'requests'
    $stillBroken   = $entryText -match [regex]::Escape('broken toml (((')
    $malformedPass = $successFired1 -and $hasRequiresPy -and $hasRequests -and (-not $stillBroken)
    Write-Pep723Row -Id 'self.pep723.writeback.malformed' -Pass $malformedPass -Desc 'Strip-and-retry replaced a broken PEP 723 header with a freshly-written valid one' -Details ([ordered]@{
        scenario      = $scenario
        exitCode      = $run1Exit
        successFired  = $successFired1
        hasRequiresPy = $hasRequiresPy
        hasRequests   = $hasRequests
        stillBroken   = $stillBroken
    })
    if (-not $malformedPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'trailing_ws_malformed') {
    $hasRequiresPy = $entryText -match 'requires-python'
    $hasRequests   = $entryText -match 'requests'
    $stillHasClick = $entryText -match [regex]::Escape('click')
    $trailingWsPass = $successFired1 -and $hasRequiresPy -and $hasRequests -and (-not $stillHasClick)
    Write-Pep723Row -Id 'self.pep723.writeback.trailing_ws_malformed' -Pass $trailingWsPass -Desc 'A closing fence with trailing whitespace (astral-sh/uv#10918) is still recognized as malformed and fully replaced' -Details ([ordered]@{
        scenario       = $scenario
        exitCode       = $run1Exit
        successFired   = $successFired1
        hasRequiresPy  = $hasRequiresPy
        hasRequests    = $hasRequests
        stillHasClick  = $stillHasClick
    })
    if (-not $trailingWsPass) { exit 1 }
    exit 0
}

if ($scenario -eq 'existing_lockfile') {
    $bytesEqual = Test-BytesEqual $entryBytesPreRun $entryBytesAfterRun1
    $lockUntouched = Test-Path -LiteralPath $lockSidecarPath
    $lockfilePass = $lockfileFired1 -and $bytesEqual -and $lockUntouched -and (-not $successFired1)
    Write-Pep723Row -Id 'self.pep723.writeback.existing_lockfile' -Pass $lockfilePass -Desc 'A pre-existing .py.lock sidecar prevents the helper from ever invoking uv add --script' -Details ([ordered]@{
        scenario       = $scenario
        exitCode       = $run1Exit
        lockfileFired  = $lockfileFired1
        successFired   = $successFired1
        bytesEqual     = $bytesEqual
        lockUntouched  = $lockUntouched
    })
    if (-not $lockfilePass) { exit 1 }
    exit 0
}

if ($scenario -eq 'non_utf8') {
    $bytesEqual = Test-BytesEqual $entryBytesPreRun $entryBytesAfterRun1
    $nonUtf8Pass = $nonUtf8Fired1 -and $bytesEqual -and (-not $successFired1)
    Write-Pep723Row -Id 'self.pep723.writeback.non_utf8' -Pass $nonUtf8Pass -Desc 'A non-UTF-8 entry file is skipped by the encoding pre-check without ever invoking uv' -Details ([ordered]@{
        scenario      = $scenario
        exitCode      = $run1Exit
        nonUtf8Fired  = $nonUtf8Fired1
        successFired  = $successFired1
        bytesEqual    = $bytesEqual
    })
    if (-not $nonUtf8Pass) { exit 1 }
    exit 0
}

if ($scenario -eq 'warnfix') {
    $warnInstallFired = $combined -match [regex]::Escape('[REPAIR] missing modules detected; installing and rebuilding.')
    $warnRebuildFired = $combined -match [regex]::Escape('[REPAIR] rebuild complete after warnfix.')
    $hasXlrd = $entryText -match 'xlrd'
    $warnfixPass = $successFired1 -and $warnInstallFired -and $warnRebuildFired -and $hasXlrd
    Write-Pep723Row -Id 'self.pep723.writeback.warnfix' -Pass $warnfixPass -Desc 'The warnfix trigger writes back a module only warnfix (not pipreqs) discovered' -Details ([ordered]@{
        scenario          = $scenario
        exitCode          = $run1Exit
        successFired      = $successFired1
        warnInstallFired  = $warnInstallFired
        warnRebuildFired  = $warnRebuildFired
        hasXlrd           = $hasXlrd
    })
    if (-not $warnfixPass) { exit 1 }
    exit 0
}

Write-Pep723Row -Id 'self.pep723.writeback.fresh' -Pass $false -Desc "Unknown PEP723_SCENARIO value: $scenario" -Details ([ordered]@{ scenario = $scenario })
exit 1
