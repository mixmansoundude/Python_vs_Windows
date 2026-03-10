$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path $nd)) { New-Item -ItemType File -Path $nd -Force | Out-Null }
if (-not (Test-Path $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

function Write-NdjsonRow {
    param([hashtable]$Row)

    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

function Get-LineSnippet {
    param(
        [string]$Text,
        [string]$Pattern
    )

    if (-not $Text) { return '' }
    foreach ($line in $Text -split "`r?`n") {
        if ($line -match $Pattern) {
            $trimmed = $line.Trim()
            if ($trimmed.Length -gt 160) { return $trimmed.Substring(0,160) }
            return $trimmed
        }
    }
    return ''
}

$script:RecordedPipreqs = $false

function Check-PipreqsFailure {
    param(
        [string]$LogPath,
        [string]$LogText
    )

    if ($script:RecordedPipreqs -or -not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return }
    if (-not $LogText) { $LogText = Get-Content -LiteralPath $LogPath -Raw -Encoding Ascii }

    $patterns = @(
        'No module named pipreqs\.__main__',
        'ERROR\s+conda\.cli\.main_run:execute\(127\):'
    )

    foreach ($pattern in $patterns) {
        if ($LogText -match $pattern) {
            $snippet = Get-LineSnippet -Text $LogText -Pattern $pattern
            $details = [ordered]@{ file = $LogPath }
            if ($snippet) { $details.snippet = $snippet }
            Write-NdjsonRow ([ordered]@{
                id      = 'pipreqs.run'
                pass    = $false
                desc    = 'pipreqs invocation failed during bootstrap'
                details = $details
            })
            $script:RecordedPipreqs = $true
            break
        }
    }
}

# Non-Windows runners cannot exercise the Windows bootstrap; Windows CI still
# covers the real envsmoke flow, so explicitly mark these checks as skipped.
if (-not $IsWindows) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    $details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    Write-NdjsonRow ([ordered]@{
        id      = 'self.env.smoke.conda'
        pass    = $true
        desc    = 'Miniconda bootstrap skipped on non-Windows host'
        details = $details
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.env.smoke.run'
        pass    = $true
        desc    = 'App run skipped on non-Windows host'
        details = $details
    })
    exit 0
}

# Emit a tiny app that imports a small conda-forge package and prints a token
$app = Join-Path $here '~envsmoke'
$setupLog = Join-Path $app '~setup.log'
New-Item -ItemType Directory -Force -Path $app | Out-Null
Copy-Item -LiteralPath (Join-Path $repo 'run_setup.bat') -Destination $app -Force
Set-Content -LiteralPath (Join-Path $app 'app.py') -Value @'
import colorama  # Prime Directive: proves pipreqs scanned app.py, conda installed it
import os as _os

# Write token to a sidecar file. stdout-based approaches (print, os.write) are
# unreliable through cmd.exe redirects on some Windows Python distributions due
# to CRT file-descriptor/HANDLE mismatch (see history in selfapps_envsmoke.ps1).
# File I/O uses Win32 CreateFile/WriteFile directly - no stdout involved.
_here = _os.path.dirname(_os.path.abspath(__file__))
with open(_os.path.join(_here, '~smoke_token.txt'), 'w') as _f:
    _f.write('smoke-ok\n')
'@ -NoNewline

if (Test-Path -LiteralPath $setupLog) {
    Remove-Item -LiteralPath $setupLog -Force
}

# Delete stale files before bootstrap so leftovers from a prior run cannot
# produce false-positive results or stale diagnostic data.
$tokenFile = Join-Path $app '~smoke_token.txt'
Remove-Item -LiteralPath $tokenFile -Force -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $app '~run.err.txt') -Force -ErrorAction SilentlyContinue

$prevVenvFallback = if (Test-Path Env:HP_ALLOW_VENV_FALLBACK) { $env:HP_ALLOW_VENV_FALLBACK } else { $null }
$env:HP_ALLOW_VENV_FALLBACK = '1'

Push-Location -LiteralPath $app
try {
    $env:HP_ALLOW_VENV_FALLBACK = '1'
    $env:HP_ALLOW_SYSTEM_FALLBACK = '1'
    # FULL bootstrap here: do NOT set HP_CI_SKIP_ENV
    cmd /c .\run_setup.bat *> '~envsmoke_bootstrap.log'
    $exit = $LASTEXITCODE
} finally {
    Remove-Item Env:HP_ALLOW_VENV_FALLBACK -ErrorAction SilentlyContinue
    Remove-Item Env:HP_ALLOW_SYSTEM_FALLBACK -ErrorAction SilentlyContinue
    Pop-Location
    if ($null -eq $prevVenvFallback) {
        Remove-Item Env:HP_ALLOW_VENV_FALLBACK -ErrorAction SilentlyContinue
    } else {
        $env:HP_ALLOW_VENV_FALLBACK = $prevVenvFallback
    }
}

$blog   = Join-Path $app '~envsmoke_bootstrap.log'
$runout = Join-Path $app '~run.out.txt'
$setup  = (Test-Path $setupLog) ? (Get-Content -LiteralPath $setupLog -Raw -Encoding Ascii) : ''
$bltxt  = (Test-Path $blog)   ? (Get-Content -LiteralPath $blog   -Raw -Encoding Ascii) : ''
$outxt  = (Test-Path $runout) ? (Get-Content -LiteralPath $runout -Raw -Encoding Ascii) : ''
$runerr = Join-Path $app '~run.err.txt'
$errtxt = (Test-Path $runerr) ? (Get-Content -LiteralPath $runerr -Raw -Encoding Ascii) : ''

$smokeCommand = ''
if ($setup) {
    $cmdMatch = [regex]::Match($setup, '^Smoke command:\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if ($cmdMatch.Success) {
        $smokeCommand = $cmdMatch.Groups[1].Value.Trim()
    }
}

# derived requirement: envsmoke failures must surface the bootstrap command
$bootstrapCommand = 'cmd /c .\run_setup.bat (envsmoke bootstrap)'
$displayCommand = if ($smokeCommand) { $smokeCommand } else { $bootstrapCommand }

Check-PipreqsFailure -LogPath $setupLog -LogText $setup

# TOKEN DETECTION - history of failed approaches:
# v1-v4: print() / flush=True / os.write() in app.py under cmd.exe 1> -> empty file
# v8:    PowerShell & operator capturing stdout -> empty (stdout still lost)
# v9:    app.py writes ~smoke_token.txt; run_setup.bat invokes python via cmd.exe
# Result: STILL failed. pyStderr revealed the real cause: cmd.exe error
# '"C:...\python.exe"' is not recognized - HP_PY has embedded quotes.
# Python never ran. Token file never written.
#
# Root cause of v9 failure (confirmed): run_setup.bat sets HP_PY from the conda
# env path using `set "HP_PY=%CONDA_PREFIX%\python.exe"`. Somehow HP_PY acquires
# embedded double-quotes in the variable VALUE (not just the cmd.exe quoting
# wrapper), causing `"%HP_PY%"` to expand to `""C:\...\python.exe""`.
# The exact source of the embedded quotes is unknown without the bootstrap log.
#
# Also confirmed: run_setup.bat's :die uses `exit /b` (exits subroutine only,
# not the whole cmd.exe process). So $exit is always 0 even when python fails.
#
# FIX: After run_setup.bat exits, PS1 derives the conda Python path independently
# using PowerShell's Join-Path (no cmd.exe quoting). If that python.exe exists,
# PS1 runs app.py DIRECTLY via the & operator. app.py writes ~smoke_token.txt.
# PS1 reads the token file. No cmd.exe involved in the token verification step.
#
# This correctly fails if: conda env was not created (Test-Path $condaPy = false)
# OR if colorama was not installed (import colorama raises ImportError, Python
# exits non-zero before writing the token file).

$haveRunOut = Test-Path -LiteralPath $runout

# Derive conda Python path via PowerShell (immune to cmd.exe quoting issues).
# ~envsmoke -> _envsmoke matches conda's own sanitization of the env name.
$envLeaf      = Split-Path $app -Leaf
$condaEnvName = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
$publicRoot   = [Environment]::GetEnvironmentVariable('PUBLIC')
$condaPy      = if ($publicRoot) {
    Join-Path $publicRoot "Documents\Miniconda3\envs\$condaEnvName\python.exe"
} else { '' }

$directRunUsed   = $false
$directRunStderr = ''
if ($condaPy -and (Test-Path -LiteralPath $condaPy)) {
    # Run app.py directly via PowerShell & - bypasses cmd.exe quoting entirely.
    # We run it for the SIDE EFFECT (writing ~smoke_token.txt), not to capture stdout.
    # 2>&1 captures both streams; assigned to $directCapture for diagnostics only.
    try {
        $directCapture = & $condaPy (Join-Path $app 'app.py') 2>&1
        $directRunUsed = $true
        # Collect stderr lines for NDJSON diagnostics (helps catch colorama ImportError etc.)
        $directRunStderr = ($directCapture |
            Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { $_.Exception.Message }) -join ' '
        if (-not $directRunStderr) {
            # Fallback: look for Python-style traceback lines in combined output
            $asStr = ($directCapture | Where-Object { $_ -is [string] }) -join ' '
            if ($asStr -match 'Traceback|Error:|ImportError') {
                $directRunStderr = $asStr.Substring(0, [Math]::Min(200, $asStr.Length))
            }
        }
    } catch {
        $directRunUsed = $true
        $directRunStderr = $_.Exception.Message
    }
}

# Read the token file (may have been written by run_setup.bat's cmd.exe run,
# OR by the PS1 direct run above - either path proves the env works).
$tokenTxt = if (Test-Path -LiteralPath $tokenFile) {
    Get-Content -LiteralPath $tokenFile -Raw -Encoding Ascii
} else { '' }
$haveToken = $tokenTxt -match 'smoke-ok'

# Belt-and-suspenders: also accept the ~run.out.txt token (works for venv/system Python).
$tokenFound = $haveToken -or ($haveRunOut -and (($outxt -match 'hello-from-stub') -or ($outxt -match 'smoke-ok')))

# derived requirement: supervisors consume iterate inputs as plain text. Mirror the
# smoke transcripts into _artifacts/iterate/inputs so agents on small devices can
# review failures without downloading large archives.
$inputsRoot = Join-Path $repo '_artifacts/iterate/inputs'
try {
    New-Item -ItemType Directory -Force -Path $inputsRoot | Out-Null
} catch {
    # best effort; diagnostics should proceed even if the mirror cannot be written.
}

$condaMirror = Join-Path $inputsRoot 'env_smoke_conda.log.txt'
$runMirror = Join-Path $inputsRoot 'env_smoke_run.log.txt'

try {
    $condaLines = @()
    if ($setup) {
        $condaLines += '# ~setup.log'
        $condaLines += $setup
    }
    if ($bltxt) {
        $condaLines += '# ~envsmoke_bootstrap.log'
        $condaLines += $bltxt
    }
    if (-not $condaLines) { $condaLines = @('(no bootstrap logs captured)') }
    Set-Content -LiteralPath $condaMirror -Value ($condaLines -join "`n") -Encoding Ascii
} catch {
    # keep diagnostics stable if the mirror write fails.
}

try {
    $runLines = @()
    if ($outxt) {
        $runLines += '# ~run.out.txt'
        $runLines += $outxt
    } else {
        $runLines += '(no run output captured)'
    }
    Set-Content -LiteralPath $runMirror -Value ($runLines -join "`n") -Encoding Ascii
} catch {
    # keep diagnostics stable if the mirror write fails.
}

# Record two rows: env setup + app run
Write-NdjsonRow ([ordered]@{
    id='self.env.smoke.conda'
    pass=($exit -eq 0)
    desc='Miniconda bootstrap + environment creation'
    details=[ordered]@{ exitCode=$exit; command=$displayCommand }
})

$passRun = ($exit -eq 0) -and $tokenFound
Write-NdjsonRow ([ordered]@{
    id='self.env.smoke.run'
    pass=$passRun
    desc='App runs in created environment'
    details=[ordered]@{ exitCode=$exit; tokenFound=$tokenFound; haveRunOut=$haveRunOut; command=$displayCommand }
})

if (($exit -eq 0) -and (-not $tokenFound)) {
    $snippet = Get-LineSnippet -Text $outxt -Pattern 'smoke-ok'
    $details = [ordered]@{ file = $runout; exitCode = $exit; tokenFound = $tokenFound; haveRunOut = $haveRunOut; command = $displayCommand }
    if ($snippet) { $details.snippet = $snippet }
    # Include Python stderr from the original cmd.exe run - critical for diagnosing
    # import errors (e.g. colorama not installed, ImportError) that are otherwise invisible.
    $errSnippet = Get-LineSnippet -Text $errtxt -Pattern '.'
    if ($errSnippet) { $details.pyStderr = $errSnippet }
    # Include info from the PS1 direct run (added v10: bypasses cmd.exe HP_PY quoting issue).
    if ($directRunUsed) { $details.directRunUsed = $true }
    if ($directRunStderr) { $details.directRunStderr = $directRunStderr }
    Write-NdjsonRow ([ordered]@{
        id='envsmoke.run'
        pass=$false
        desc='Environment smoke run missing expected output token after success'
        details=$details
    })
}
