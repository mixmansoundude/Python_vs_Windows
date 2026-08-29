# ASCII only
# selfapps_layered_e2e.ps1 - CLAUDE.md Active Backlog item 22: a real, non-simulated
# end-to-end test proving THREE distinct REQ-009/REQ-007/REQ-016 mechanisms all fire for
# real in ONE run, replacing Part VII Scenario 33's [Extrapolated Branch] splice with
# genuine evidence:
#
#   1. uv-fails-to-conda provider cascade (REQ-009/REQ-005.10 slice 3): pygrib ships zero
#      Windows wheels on PyPI (confirmed via a direct PyPI JSON API query -- macOS/Linux
#      wheels exist for every recent CPython, Windows was deliberately excluded, and the
#      sdist needs the ecCodes/GRIB-API C library that a bare CI runner does not have), so
#      `uv pip install -r requirements.txt` genuinely fails to build it. conda-forge ships
#      real win-64 pygrib builds (verified via the anaconda.org API), so cascading to conda
#      genuinely resolves it.
#   2. warnfix repair (REQ-007), BOTH outcomes in the same round: pygrib and xlrd are both
#      genuinely absent after the failed bulk install (both statically imported, so both
#      land in PyInstaller's own warn file). warnfix's per-module loop tries each
#      separately -- xlrd has a real PyPI wheel and installs cleanly (genuine REPAIR
#      SUCCESS); pygrib genuinely fails again (genuine REPAIR FAILURE, the same real
#      cause as the bulk failure -- not a decoy). This is what drives the REQ-009 cascade
#      candidate detection: still-unresolved (pygrib) AND a real recorded install failure.
#   3. --hidden-import auto-recovery (REQ-016 Slice 2): colorama is imported only via
#      importlib.import_module('colorama'), invisible to PyInstaller's static analysis, so
#      it is never touched by warnfix. Once cascaded to conda, colorama installs
#      successfully as part of the ordinary bulk install (declared in requirements.txt),
#      but the frozen EXE still fails at runtime with ModuleNotFoundError (never bundled).
#      Because colorama IS installed in the (now conda) build interpreter, the strict
#      double-gate fires and a --hidden-import=colorama rebuild fixes it for real.
#   4. Conda native-DLL bundling repair loop (CLAUDE.md Active Backlog Item 24 /
#      docs/prd-conda-native-dll-bundling.md, :dll_bundle_recover in run_setup.bat): pygrib's
#      conda-forge build links its compiled _pygrib.cp3xx-win_amd64.pyd extension against
#      eccodes.dll, a separate native DLL shipped by its own conda-forge package
#      (python-eccodes / eccodes) under the env's Library\bin -- PyInstaller's static
#      analysis bundles the .pyd itself but never discovers or copies that DLL dependency,
#      so the build succeeds with only a "WARNING: Library not found: could not resolve
#      'eccodes.dll'..." note, and (before this mechanism existed) the frozen EXE crashed
#      at runtime with ImportError: DLL load failed. This is what previously kept
#      chainPass at False even once mechanisms 1-3 all genuinely passed. :dll_bundle_recover
#      reacts to that build-time warning (before the smoke run, no wasted crash-and-detect
#      cycle), locates eccodes.dll under the conda env's own Library\bin, bundles it via
#      --add-binary, and rebuilds -- this is the acceptance criterion that finally lets the
#      final EXE genuinely run pygrib and print its token. Requirement 1's own CI experiment
#      (PR #415, self.gribapi_hook_probe.hidden_import) first confirmed the cheaper
#      alternative -- forcing --hidden-import=gribapi to see if pyinstaller-hooks-contrib's
#      existing hook-gribapi.py would bundle the DLL for free -- does NOT work for a
#      pygrib-only build (pygrib and gribapi are independent bindings to the same C
#      library), ruling out that shortcut before this loop was built.
#
# GDAL/osgeo was the original candidate researched for mechanism 1, but was rejected after
# deeper research: GDAL's Python bindings live under the `osgeo` namespace
# (`from osgeo import gdal`), and PyInstaller's warn file always records the top-level
# import name ("osgeo"), not the actual PyPI distribution name ("gdal"/"GDAL"). PyPI hosts
# a real, always-succeeding dummy package literally named "osgeo" (a deliberate
# typosquat-protection placeholder for people who mistakenly `pip install osgeo`), so
# warnfix's own per-module repair attempt for GDAL would install that harmless dummy
# instead of failing -- silently defeating the REQ-009 cascade-candidate detection's
# Signal B (a REAL recorded install failure), which specifically checks
# ~warnfix_repair_failed.flag, set only by a genuine per-module install failure. pygrib's
# top-level import name IS its own correct PyPI/conda-forge package name (no namespace
# indirection, no decoy), so this same trap cannot occur.
#
# Needed test-only flag: HP_TEST_CASCADE_ANSWER=Y to accept the REQ-009 cascade consent
# prompt deterministically in CI (no way around an interactive prompt otherwise). No other
# HP_SKIP_*/HP_TEST_FORCE_*/HP_DISABLE_* flags are used -- pipreqs, the REQ-005.12
# autopep723 Tier 1 merge, and the REQ-005 heuristics all run normally; every failure and
# repair in this test is a genuine, unflagged consequence of the three packages' own real
# availability on PyPI vs. conda-forge.
#
# Lane: cache only (uv-first, and the only lane that already caches Miniconda across runs
# to amortize the one-time download this test's own cascade triggers). Non-gating for its
# first landing (the `cache` job is continue-on-error at the job level in batch-check.yml)
# -- promote once proven stable across several real runs, matching this repo's established
# graduation pattern (see CLAUDE.md's "CI lane gating maturity" periodic check).
#
# Emits: self.layered_e2e.chain
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path $nd))   { New-Item -ItemType File -Path $nd   -Force -ErrorAction Stop | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force -ErrorAction Stop | Out-Null }

# derived requirement: fail closed on NDJSON output -- under the script's own
# $ErrorActionPreference = 'Continue', a failed Add-Content would otherwise be silently
# swallowed, leaving CI with NO self.layered_e2e.chain record at all (indistinguishable from
# the step never running) instead of a loud, diagnosable failure.
function Write-NdjsonRow {
    param([hashtable]$Row)
    $lane = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
    if ($lane -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $lane }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii -ErrorAction Stop
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii -ErrorAction Stop
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.layered_e2e.chain'
        req     = 'REQ-009'
        pass    = $true
        skip    = $true
        desc    = 'real layered dependency chain (cascade + warnfix + hidden-import) skipped on non-Windows'
        details = [ordered]@{ reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.layered_e2e.chain'
        req     = 'REQ-009'
        pass    = $false
        desc    = 'run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_layered_e2e'
# derived requirement: fail closed on stale-workspace cleanup -- $ErrorActionPreference is
# 'Continue' for the rest of this script (so later steps still write an NDJSON row/exit code
# on failure), which would otherwise let a failed Remove-Item (e.g. a locked dist\<env>.exe
# left over from a prior interrupted run) silently pass through, letting this run reuse stale
# dist/status/token/log files and pass for the wrong reason instead of exercising a genuinely
# fresh bootstrap. -ErrorAction Stop + an explicit existence re-check makes that failure loud.
# Wrapped in try/catch (rather than just letting the throw propagate) so a workspace-prep
# failure still emits the self.layered_e2e.chain NDJSON row -- a raw terminating error here
# would otherwise leave CI with no record of this test at all instead of an explicit failure.
try {
    if (Test-Path -LiteralPath $workDir) {
        Remove-Item -LiteralPath $workDir -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $workDir) {
            throw "selfapps_layered_e2e.ps1: failed to remove stale workspace: $workDir"
        }
    }
    New-Item -ItemType Directory -Force -Path $workDir -ErrorAction Stop | Out-Null
    Copy-Item -Path $batchPath -Destination $workDir -Force -ErrorAction Stop
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.layered_e2e.chain'
        req     = 'REQ-009'
        pass    = $false
        desc    = 'layered test workspace preparation failed'
        details = [ordered]@{ error = $_.Exception.Message }
    })
    exit 1
}

# derived requirement: pin pygrib specifically -- it is the cascade trigger (mechanism 1),
# whose whole premise depends on it shipping zero Windows wheels on PyPI as of this pin. An
# unpinned requirement could silently pick up a future PyPI release that DOES ship a Windows
# wheel, which would make `uv pip install` succeed and never trigger the cascade at all. colorama
# and xlrd are not pinned -- neither one's own trigger (hidden-import recovery / warnfix success)
# depends on a specific version the way the cascade depends on pygrib's wheel availability.
Set-Content -Path (Join-Path $workDir 'requirements.txt') -Value "pygrib==2.1.8`ncolorama`nxlrd" -Encoding ASCII

$appCode = @'
import pygrib
import xlrd
import importlib
import os as _os
import sys as _sys

_pygrib_ok = bool(pygrib)
_xlrd_ver = xlrd.__version__
_colorama_mod = importlib.import_module('colorama')

_here = _os.path.dirname(_os.path.abspath(_sys.argv[0]))
with open(_os.path.join(_here, '~layered_e2e_token.txt'), 'w') as _f:
    _f.write('pygrib=%s xlrd=%s colorama=%s\n' % (_pygrib_ok, _xlrd_ver, _colorama_mod.__name__))
print('pygrib/xlrd/colorama layered e2e ok')
'@
Set-Content -Path (Join-Path $workDir 'app.py') -Value $appCode -Encoding ASCII

# HP_TEST_CASCADE_ANSWER=Y: grant cascade consent deterministically (no prompt, no CI auto-decline).
# No other override -- pipreqs, Tier 1 autopep723 merge, and REQ-005 heuristics all run normally.
$prevCascade = if (Test-Path Env:HP_TEST_CASCADE_ANSWER) { $env:HP_TEST_CASCADE_ANSWER } else { $null }
$env:HP_TEST_CASCADE_ANSWER = 'Y'

# derived requirement (CLAUDE.md Item 37): point run_setup.bat's own inline HP_NDJSON
# emission at the SAME shared file this test's own Write-NdjsonRow already writes to ($nd), so
# self.dll_bundle.recover's "repaired" row -- proven by mech4Pass's log-text checks below to
# genuinely fire during this exact run, but never previously captured as a queryable NDJSON row
# anywhere -- lands in the shared stream for the first time. See docs/agent-ndjson.md's
# "self.dll_bundle.recover... Not currently observed in any real CI artifact" note: the only
# test reaching the 'repaired' state is THIS one, and it never set HP_NDJSON before now. Unlike
# selfapps_postexec_checkpoint.ps1 / selfapps_failfast_probe.ps1 / selfapps_exefastpath.ps1
# (which deliberately UNSET HP_NDJSON around their own sub-bootstraps to keep an isolated
# scenario's rows OUT of the shared stream), this test's Item 37 goal is the opposite: this
# sub-bootstrap's inline rows (self.dll_bundle.recover, plus the other already-registered ids
# it incidentally also emits -- pipreqs.install, env.mode, helper.find_entry.syntax, conda.url,
# self.warnfix.platform_filter, self.exe.smokerun -- all already-expected occurrences for a
# real full bootstrap run) belong IN the shared stream.
$prevNdjson = if (Test-Path Env:HP_NDJSON) { $env:HP_NDJSON } else { $null }
$env:HP_NDJSON = $nd
$ndLinesBefore = if (Test-Path -LiteralPath $nd) { @(Get-Content -LiteralPath $nd -Encoding ASCII) } else { @() }
$ndCountBefore = $ndLinesBefore.Count

$bootstrapLog = '~layered_e2e_bootstrap.log'
# derived requirement: guard the location push -- under $ErrorActionPreference = 'Continue', a
# failed Push-Location would otherwise be non-terminating, letting the try block run
# run_setup.bat from the CALLER's own directory instead of $workDir, and letting the finally
# block's Pop-Location pop an unrelated stack entry that was never pushed by this script.
$pushedLocation = $false
try {
    Push-Location -LiteralPath $workDir -ErrorAction Stop
    $pushedLocation = $true
    cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
    $runExit = $LASTEXITCODE
} finally {
    if ($null -eq $prevCascade) { Remove-Item Env:HP_TEST_CASCADE_ANSWER -ErrorAction SilentlyContinue } else { $env:HP_TEST_CASCADE_ANSWER = $prevCascade }
    if ($null -eq $prevNdjson) { Remove-Item Env:HP_NDJSON -ErrorAction SilentlyContinue } else { $env:HP_NDJSON = $prevNdjson }
    if ($pushedLocation) { Pop-Location }
}

$logPath   = Join-Path $workDir $bootstrapLog
$setupLog  = Join-Path $workDir '~setup.log'
$logLines  = if (Test-Path $logPath)  { Get-Content -LiteralPath $logPath  -Encoding ASCII } else { @() }
$setupText = if (Test-Path $setupLog) { Get-Content -LiteralPath $setupLog -Raw -Encoding ASCII } else { '' }
$combined  = ($logLines -join "`n") + "`n" + $setupText

# Mechanism 1: uv-fails-to-conda cascade.
$uvInstallFailed = $combined -match [regex]::Escape('[WARN] uv pip install -r requirements.txt failed; some packages may be missing.')
$cascadeDetected = $combined -match [regex]::Escape('[INFO] REQ-009: cascade candidate detected.')
$cascadeApproved = $combined -match [regex]::Escape('[INFO] REQ-009: cascade approved; will re-attempt under the next provider tier.')
$uvToConda       = ([regex]::Matches($setupText, [regex]::Escape('REQ-009: cascading provider uv to conda'))).Count
$condaSelected   = $combined -match [regex]::Escape('REQ-009: Selected Python provider: Conda')
# derived requirement: real CI evidence (2026-08-07) showed this cascade genuinely failing here --
# runtime.txt write-back pins the EXACT uv-resolved patch version (e.g. python-3.14.7), and without
# the HP_PYSPEC_WRITEBACK fix, :try_conda_create forwarded that exact pin to conda create, which
# conda-forge does not carry (PackagesNotFoundInChannelsError), hard-failing the whole cascade
# before pygrib was ever built. This app's own stub has no runtime.txt/pyproject.toml of its own,
# so PYSPEC can ONLY be non-empty here via write-back -- $pinDropped not firing (while $condaSelected
# is still true) would mean conda happened to already have that exact patch by coincidence, not that
# the fix's own code path was exercised; not asserted as a hard requirement for that reason, but
# logged for visibility (see docs/agent-interconnect.md's "runtime.txt write-back... cascade
# re-entry" section for the full mechanism trace).
$pinDropped      = $setupText -match [regex]::Escape('[INFO] conda create: dropping the write-back-derived exact Python pin')

# Mechanism 2: warnfix repair, both outcomes in the SAME round -- derived requirement: a plain
# "does this string appear anywhere in the combined log" check (the original approach) cannot
# distinguish "both happened in one round" from "each happened in a different round," so it
# would not actually catch a future regression that split them across rounds. Scope the pygrib/
# xlrd checks to the single warnfix round's own text slice instead: from the round's start
# marker to the next "rebuild complete" marker (or end of log if the round never completed).
# $warnfixRoundCount -eq 1 additionally proves there was exactly one such round in this run, so
# the slice below cannot itself be straddling two rounds.
# derived requirement: match against $setupText ALONE, not $combined -- every :log-emitted line
# (including both markers below) is written to BOTH stdout (captured into $logLines) AND
# ~setup.log (%LOG%, see run_setup.bat's :log subroutine), so counting matches in $combined
# double-counts every occurrence. $uvToConda above already established this same
# single-source-for-counts convention; this reuses it rather than inventing a second one.
$warnInstallFired    = $setupText -match [regex]::Escape('[REPAIR] missing modules detected; installing and rebuilding.')
$warnfixRoundMatches = [regex]::Matches($setupText, [regex]::Escape('[REPAIR] missing modules detected; installing and rebuilding.'))
$warnfixRoundCount   = $warnfixRoundMatches.Count
$warnfixRoundText     = ''
$warnfixRoundComplete = $false
if ($warnfixRoundCount -ge 1) {
    $roundStart = $warnfixRoundMatches[0].Index
    $tail = $setupText.Substring($roundStart)
    $endMarker = [regex]::Match($tail, [regex]::Escape('[REPAIR] rebuild complete after warnfix.'))
    # derived requirement: an incomplete round (no completion marker -- e.g. the rebuild itself
    # errored, or the log was truncated) must NOT count as same-round evidence just because the
    # rest of the log happens to still contain both substrings; require the marker explicitly
    # rather than falling back to "everything to EOF."
    if ($endMarker.Success) {
        $warnfixRoundText = $tail.Substring(0, $endMarker.Index + $endMarker.Length)
        $warnfixRoundComplete = $true
    }
}
$pygribAttempted  = $warnfixRoundText -match [regex]::Escape('[INFO] Attempting to install: pygrib')
$pygribFailed     = $warnfixRoundText -match [regex]::Escape('[WARN] Repair failed: pygrib')
$xlrdAttempted    = $warnfixRoundText -match [regex]::Escape('[INFO] Attempting to install: xlrd')
$xlrdInstalled    = $warnfixRoundText -match [regex]::Escape('[INFO] Installed: xlrd')

# Mechanism 3: hidden-import auto-recovery for colorama, after the cascade.
$hiddenAdding     = $combined -match [regex]::Escape('[REPAIR][HIDDEN_IMPORT] Adding --hidden-import=colorama')
$hiddenRecovered  = $combined -match [regex]::Escape('[REPAIR][HIDDEN_IMPORT] EXE verified after hidden-import recovery')

# Mechanism 4: conda native-DLL bundling repair loop (CLAUDE.md Active Backlog Item 24).
# $dllWarningSeen proves PyInstaller's own build-time detection signal fired at all (the
# same signal that, before :dll_bundle_recover existed, was the whole reason chainPass
# stayed False); $dllBundling proves the loop actually located eccodes.dll under the conda
# env's Library\bin and attempted a rebuild with it; $dllBundleComplete proves that rebuild
# succeeded (the loop's own trailer log line only fires after a genuinely successful
# rebuild -- see :dll_bundle_recover_done in run_setup.bat).
$dllWarningSeen    = $setupText -match [regex]::Escape("Library not found: could not resolve 'eccodes.dll'")
$dllBundling       = $combined -match [regex]::Escape('[REPAIR][DLL_BUNDLE] Bundling native DLL dependency: eccodes.dll')
$dllBundleComplete = $combined -match [regex]::Escape('[REPAIR][DLL_BUNDLE] Native-DLL bundling complete')

# derived requirement (CLAUDE.md Item 37): informational only, deliberately NOT folded into
# chainPass/mech4Pass -- mech4Pass above already proves the real repair happened via log text
# (the same underlying event this NDJSON row records), so a wiring hiccup in the row emission
# itself must not turn a currently-green, closely-watched test red on its own first real CI
# run. This is the row's first-ever real-CI observation; once proven stable across several runs
# it can graduate to a hard assertion via Item 35's own promotion process.
$ndLinesAfterRun  = if (Test-Path -LiteralPath $nd) { @(Get-Content -LiteralPath $nd -Encoding ASCII) } else { @() }
$ndNewLines       = if ($ndLinesAfterRun.Count -gt $ndCountBefore) { $ndLinesAfterRun[$ndCountBefore..($ndLinesAfterRun.Count - 1)] } else { @() }
# derived requirement (CodeRabbit review, PR #452): parse each new NDJSON line as its own
# object and require the state check to apply to the SAME row that carries the
# self.dll_bundle.recover id -- a plain substring match across the whole $ndNewCombined text
# (the original approach) could not tell "this row's own details.state is repaired" apart from
# "some OTHER unrelated row emitted during this same run also happens to contain the substring
# "state":"repaired"" (e.g. a coincidentally identically-shaped field on a different id).
$dllBundleRowSeen     = $false
$dllBundleRowRepaired = $false
foreach ($ndLine in $ndNewLines) {
    if (-not $ndLine.Trim()) { continue }
    try {
        $ndRow = $ndLine | ConvertFrom-Json
    } catch {
        continue
    }
    if ($ndRow.id -eq 'self.dll_bundle.recover') {
        $dllBundleRowSeen = $true
        if ($ndRow.details.state -eq 'repaired') { $dllBundleRowRepaired = $true }
    }
}

$infraError = $combined -match 'Failed to parse|uv error|pip error'

# Final EXE: built under conda (the tier the cascade lands on), run for real.
$envLeaf  = Split-Path $workDir -Leaf
$envName  = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $envName) { $envName = '_layered_e2e' }
$distDir  = Join-Path $workDir 'dist'
$exePath  = Join-Path $distDir "$envName.exe"
$exeExists = Test-Path -LiteralPath $exePath
$exeExit   = -1
$tokenPath = Join-Path $distDir '~layered_e2e_token.txt'
$tokenFound = $false

if ($exeExists) {
    try {
        Push-Location -LiteralPath $distDir
        try {
            # derived requirement: bound the final EXE launch -- an unbounded `cmd /c` wait
            # (the original approach) could hang the whole CI job until the workflow-level
            # timeout if the built EXE ever hangs. run_setup.bat's OWN smokerun already has
            # a 30s activity-aware kill, but that covers ONLY its own internal verification
            # launch -- it does not cover this SECOND, independent launch performed by the
            # test itself, after run_setup.bat has already exited.
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $exePath
            $psi.UseShellExecute = $false
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError = $true
            $proc = [System.Diagnostics.Process]::Start($psi)
            $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
            $stderrTask = $proc.StandardError.ReadToEndAsync()
            $exeTimeoutMs = 60000
            if ($proc.WaitForExit($exeTimeoutMs)) {
                $exeExit = $proc.ExitCode
            } else {
                # derived requirement: Process.Kill() (the parameterless overload) terminates
                # ONLY $proc itself -- a onefile bootloader (or any program) that spawns a child
                # inheriting the redirected stdout/stderr handles can leave that child running
                # after $proc is killed, so the pipe never reaches EOF and an unbounded
                # ReadToEndAsync().Result would hang forever, defeating the whole point of this
                # bounded launch. Same taskkill /T (process-tree kill) pattern already
                # established in tools/exe_hint_rerun.ps1 for the identical hazard, but with a
                # BOUNDED wait after each termination attempt (not an unbounded final
                # WaitForExit()) -- if taskkill AND Kill() both somehow fail to terminate $proc
                # itself, the test must still reach the bounded output drain below instead of
                # hanging the whole CI job indefinitely.
                $terminationWaitMs = 5000
                try {
                    & taskkill.exe /F /T /PID $proc.Id 2>$null 1>$null
                } catch {
                    Write-Warning "taskkill failed for PID $($proc.Id): $($_.Exception.Message)"
                }
                if (-not $proc.WaitForExit($terminationWaitMs) -and -not $proc.HasExited) {
                    try {
                        $proc.Kill()
                    } catch {
                        Write-Warning "Process kill failed for PID $($proc.Id): $($_.Exception.Message)"
                    }
                    if (-not $proc.WaitForExit($terminationWaitMs)) {
                        Write-Warning "Process $($proc.Id) remained active after termination attempts."
                    }
                }
                $exeExit = -1
            }
            # Bounded final read, NOT a blind .GetAwaiter().GetResult() block: even after
            # killing the process tree, a descendant taskkill /T did not catch (or some other
            # exotic handle-inheritance edge case) must not be able to hang this test
            # indefinitely. Task.Wait(ms) returns false on timeout without throwing.
            $drainMs = 5000
            $stdout = ''
            $stderr = ''
            if ($stdoutTask.Wait($drainMs)) { try { $stdout = $stdoutTask.Result } catch {} }
            if ($stderrTask.Wait($drainMs)) { try { $stderr = $stderrTask.Result } catch {} }
            ($stdout + $stderr) | Set-Content -LiteralPath '~layered_e2e_exe.log' -Encoding Ascii
        } finally {
            Pop-Location
        }
        $tokenFound = Test-Path -LiteralPath $tokenPath
    } catch {
        $exeExit = -1
    }
}

$statusPath = Join-Path $workDir '~bootstrap.status.json'
$statusExit = $null
$statusState = $null
if (Test-Path $statusPath) {
    try {
        $status = Get-Content -LiteralPath $statusPath -Raw -Encoding ASCII | ConvertFrom-Json
        $statusExit = $status.exitCode
        $statusState = $status.state
    } catch {
        Write-Warning "Failed to parse ${statusPath}: $($_.Exception.Message)"
    }
}

$mech1Pass = $uvInstallFailed -and $cascadeDetected -and $cascadeApproved -and ($uvToConda -eq 1) -and $condaSelected
$mech2Pass = $warnInstallFired -and ($warnfixRoundCount -eq 1) -and $warnfixRoundComplete -and $pygribAttempted -and $pygribFailed -and $xlrdAttempted -and $xlrdInstalled
$mech3Pass = $hiddenAdding -and $hiddenRecovered
$mech4Pass = $dllWarningSeen -and $dllBundling -and $dllBundleComplete
$exePass   = $exeExists -and ($exeExit -eq 0) -and $tokenFound -and (-not $infraError)
$chainPass = $mech1Pass -and $mech2Pass -and $mech3Pass -and $mech4Pass -and $exePass -and ($statusExit -eq 0) -and ($statusState -eq 'ok') -and ($runExit -eq 0)

# Self-diagnosis: run_setup.bat output is redirected to the bootstrap log file, so without
# this the CI job log shows nothing about what the chain actually did.
Write-Host "=== self.layered_e2e.chain evidence ==="
Write-Host ("mech1Pass={0} mech2Pass={1} mech3Pass={2} mech4Pass={3} exePass={4} statusExit={5} statusState={6} runExit={7} chainPass={8}" -f `
    $mech1Pass, $mech2Pass, $mech3Pass, $mech4Pass, $exePass, $statusExit, $statusState, $runExit, $chainPass)
Write-Host "=== REQ-009 / warnfix / hidden-import / dll-bundle lines (setup log) ==="
($setupText -split "`n") | Where-Object { $_ -match 'REQ-009|REPAIR|HIDDEN_IMPORT|DLL_BUNDLE|Selected Python provider|Attempting to install|Installed:|Repair failed|Library not found' } | Select-Object -First 100 | ForEach-Object { Write-Host $_ }
Write-Host "=== bootstrap stdout log tail (50) ==="
$logLines | Select-Object -Last 50 | ForEach-Object { Write-Host $_ }
Write-Host "=== end self.layered_e2e.chain evidence ==="

Write-NdjsonRow ([ordered]@{
    id      = 'self.layered_e2e.chain'
    req     = 'REQ-009'
    pass    = [bool]$chainPass
    desc    = 'real, unflagged chain: uv fails on pygrib -> cascades to conda; warnfix fixes xlrd but genuinely fails on pygrib (driving the cascade); hidden-import-recovery fixes colorama after the cascade; dll-bundle-recovery bundles eccodes.dll so the final EXE genuinely runs pygrib'
    details = [ordered]@{
        mech1Pass        = $mech1Pass
        uvInstallFailed  = $uvInstallFailed
        cascadeDetected  = $cascadeDetected
        cascadeApproved  = $cascadeApproved
        uvToConda        = $uvToConda
        condaSelected    = $condaSelected
        pinDropped       = $pinDropped
        mech2Pass        = $mech2Pass
        warnInstallFired = $warnInstallFired
        warnfixRoundCount    = $warnfixRoundCount
        warnfixRoundComplete = $warnfixRoundComplete
        pygribAttempted  = $pygribAttempted
        pygribFailed     = $pygribFailed
        xlrdAttempted    = $xlrdAttempted
        xlrdInstalled    = $xlrdInstalled
        mech3Pass        = $mech3Pass
        hiddenAdding     = $hiddenAdding
        hiddenRecovered  = $hiddenRecovered
        mech4Pass          = $mech4Pass
        dllWarningSeen     = $dllWarningSeen
        dllBundling        = $dllBundling
        dllBundleComplete  = $dllBundleComplete
        dllBundleRowSeen     = $dllBundleRowSeen
        dllBundleRowRepaired = $dllBundleRowRepaired
        exePass          = $exePass
        exeExists        = $exeExists
        exeExit          = $exeExit
        tokenFound       = $tokenFound
        infraError       = $infraError
        statusExit       = $statusExit
        statusState      = $statusState
        runExit          = $runExit
        exePath          = $exePath
    }
})

if (-not $chainPass) { exit 1 }
exit 0
