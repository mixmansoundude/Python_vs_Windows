# ASCII only
# selfapps_pvw_quickstart.ps1 - Dry-run test for the README "PVW QuickStart" copy-paste
# commands, run as close to verbatim (and as close to what a real user would paste) as
# possible -- NOT a run_setup.bat test. This does not touch the bootstrapper at all; it
# exercises the standalone uv/autopep723 commands documented in README's "PVW QuickStart
# (Super-User Fast Path)" section directly, including their own `irm .../install.ps1 | iex`
# uv-acquisition line, so this test is self-contained and does not depend on any other CI
# step's PATH state.
#
# Purpose: an isolated proof that the underlying autopep723/uv mechanics actually work as
# documented in this exact CI environment, BEFORE building any bootstrapper integration on
# top of them (docs/plan-autopep723-two-tier.md's Tier 1 reuses the "check" command below;
# Tier 2's HP_PVW_KNOWN_IDEMPOTENT reuses the "run" command's persist-on-success logic
# verbatim). If this test ever breaks, that is a signal the underlying tool behavior
# (autopep723's output format, uv add --script's semantics) has changed upstream, which
# either tier would inherit.
#
# Scenarios (controlled by QUICKSTART_SCENARIO env var; default: check):
#
#   check - README's "Check what it would install, without running or changing anything"
#           command: `uvx autopep723 check <file>`. Read-only; asserts exit 0, the
#           discovered dependency name appears in the output, and the file itself is left
#           byte-for-byte unchanged. Emits: self.pvw_quickstart.check
#
#   run   - README's "Just run it (and remember what it needed)" command, copied verbatim
#           (the "spaced out" form) from the README, filename substituted only. Asserts the
#           script's own stdout came through (proving a real execution happened, not a
#           mock), the wrapper's success message printed, the file's own PEP 723 header now
#           contains the dependency, and no .bak file was left behind (the clean-header
#           path never creates one). Emits: self.pvw_quickstart.run
#
# Lane: uv only (matches where autopep723/uv add --script are already exercised elsewhere
# in this suite -- selfapps_pep723_writeback.ps1). Non-gating.
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

function Write-QuickstartRow {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)]$Pass,
        [Parameter(Mandatory)][string]$Desc,
        [Parameter(Mandatory)][hashtable]$Details
    )
    Write-NdjsonRow ([ordered]@{ id = $Id; pass = $Pass; desc = $Desc; details = $Details })
}

$scenario = if ($env:QUICKSTART_SCENARIO) { $env:QUICKSTART_SCENARIO.ToLower() } else { 'check' }

# Non-Windows skip (matches this suite's convention -- production target is Windows-only,
# even though the underlying uv/autopep723 CLI mechanics are cross-platform in principle).
# derived requirement: literal -Id per branch, not a variable -- tools/check_ndjson_registry.py's
# PowerShell scanner only matches a literal `-Id '...'` string at the call site (see
# selfapps_pep723_writeback.ps1's own Write-Pep723Row comment for the same convention).
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    if ($scenario -eq 'run') {
        Write-QuickstartRow -Id 'self.pvw_quickstart.run' -Pass $true -Desc "PVW QuickStart $scenario (skipped on non-Windows)" -Details ([ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' })
    } else {
        Write-QuickstartRow -Id 'self.pvw_quickstart.check' -Pass $true -Desc "PVW QuickStart $scenario (skipped on non-Windows)" -Details ([ordered]@{ skip = $true; scenario = $scenario; platform = $platform; reason = 'non-windows-host' })
    }
    exit 0
}

$workDir = Join-Path $here "~selftest_pvw_quickstart_$scenario"
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Push-Location $workDir
try {
    # README's own first line: acquire uv exactly as a real user pasting the command would.
    # Self-contained on purpose -- does not depend on any earlier CI step's uv acquisition
    # (run_setup.bat's own uv download is process-local PATH, not visible to this step).
    irm https://astral.sh/uv/install.ps1 | iex
    $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"

    $f = "solve_my_probs.py"
    # A single real, importable third-party dependency (requests) -- simple, stable,
    # already used elsewhere in this repo's own test fixtures.
    Set-Content -LiteralPath $f -Value "import requests`nprint('hello-quickstart-demo')`n" -Encoding Ascii -NoNewline

    if ($scenario -eq 'check') {
        # README: "Check what it would install, without running or changing anything"
        $before = [System.IO.File]::ReadAllBytes((Get-Item $f).FullName)
        $chk = (uvx autopep723 check $f) -join "`n"
        $rc = $LASTEXITCODE
        $after = [System.IO.File]::ReadAllBytes((Get-Item $f).FullName)
        $unchanged = ($before.Length -eq $after.Length) -and ((Compare-Object $before $after -SyncWindow 0 | Measure-Object).Count -eq 0)
        $foundDep = $chk -match 'requests'
        $pass = ($rc -eq 0) -and $foundDep -and $unchanged
        Write-QuickstartRow -Id 'self.pvw_quickstart.check' -Pass $pass -Desc 'PVW QuickStart check-only command discovers deps without modifying the file' -Details ([ordered]@{ exitCode = $rc; foundDep = [bool]$foundDep; fileUnchanged = $unchanged; output = $chk })
    } else {
        # README: "Just run it (and remember what it needed)" -- spaced-out form, copied
        # verbatim from README.md's "PVW QuickStart" section, filename substituted only.
        $enc = [System.Text.Encoding]::GetEncoding("ISO-8859-1")
        $original = [System.IO.File]::ReadAllText((Get-Item $f).FullName, $enc)

        function Persist($f) {
            $chk = (uvx autopep723 check $f) -join "`n"
            if ($LASTEXITCODE -ne 0) { return $false }
            $names = [regex]::Matches($chk, '^#\s*"([^"]+)",?\s*$', 'Multiline') | ForEach-Object { $_.Groups[1].Value }
            if ($names.Count -eq 0) { return $true }
            uv add --script $f $names
            return ($LASTEXITCODE -eq 0)
        }

        $runOutput = uvx autopep723 $f
        $rc = $LASTEXITCODE
        $message = $null

        if ($rc -eq 0) {
            if (Persist $f) {
                $message = "Ran successfully and remembered what it needed."
            } else {
                $message = "Ran successfully, but could not update the dependency header - nothing was changed there."
            }
        } elseif ($rc -eq 2) {
            $message = "Header is malformed - retrying with a clean version..."
            [System.IO.File]::WriteAllText("$((Get-Item $f).FullName).bak", $original, $enc)
            $c = $original -replace "(?ms)^# /// script\r?\n.*?^# ///[ \t]*\r?\n?", ""
            [System.IO.File]::WriteAllText((Get-Item $f).FullName, $c, $enc)
            uvx autopep723 $f
            if ($LASTEXITCODE -eq 0) {
                if (Persist $f) { $message = "Ran successfully after repair and remembered a fresh header." }
                else { $message = "Ran successfully after repair, but could not update the header." }
            } else {
                $message = "Retry also failed - restoring your original file untouched."
                [System.IO.File]::WriteAllText((Get-Item $f).FullName, $original, $enc)
            }
            Remove-Item -ErrorAction SilentlyContinue "$f.bak"
        } else {
            $message = "Run failed with an existing header in place - trying to fill in any missing dependencies..."
            Persist $f | Out-Null
            uvx autopep723 $f
            if ($LASTEXITCODE -eq 0) { $message = "Ran successfully after filling in missing dependencies." }
            else { $message = "Run still failed - this looks like a script-level issue, not a dependency gap, so nothing further was attempted." }
        }

        $finalContent = Get-Content -LiteralPath $f -Raw
        $scriptRan = $runOutput -match 'hello-quickstart-demo'
        $depPersisted = $finalContent -match 'requests'
        $noBakLeftBehind = -not (Test-Path "$f.bak")
        $pass = $scriptRan -and $depPersisted -and $noBakLeftBehind -and ($message -eq "Ran successfully and remembered what it needed.")
        Write-QuickstartRow -Id 'self.pvw_quickstart.run' -Pass $pass -Desc 'PVW QuickStart just-run-it command executes the script and persists what it needed' -Details ([ordered]@{ exitCode = $rc; scriptRan = [bool]$scriptRan; depPersisted = [bool]$depPersisted; noBakLeftBehind = $noBakLeftBehind; message = $message })
    }
} finally {
    Pop-Location
}

if (-not $pass) { exit 1 }
exit 0
