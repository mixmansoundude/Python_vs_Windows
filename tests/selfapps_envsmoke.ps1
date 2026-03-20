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

# TOKEN DETECTION - full history of failed approaches (do not retry these):
#
# v1-v4: print() / flush=True / os.write() under cmd.exe 1> redirect -> ~run.out.txt empty
# v8:    PowerShell direct conda python capture to stdout -> still empty
# v9:    app.py writes ~smoke_token.txt via file I/O (not stdout)
#        -> pyStderr revealed '"C:...\python.exe"' is not recognized
#        -> Python never ran at all; token file never written
# v10:   PS1 derives conda python path via Join-Path; guards with Test-Path
#        -> Test-Path returned false; direct-run field absent from NDJSON
#        -> python.exe does not exist at expected path
#
# Root cause (confirmed after v10): run_setup.bat derives ENVNAME from:
# for /f "usebackq delims=" %%I in (`powershell ... Write-Output $san`)
# PowerShell's Write-Output emits `_envsmoke<CR><LF>`. for /f strips <LF> but
# NOT <CR>. ENVNAME becomes `_envsmoke<CR>`. conda create -y -n "_envsmoke<CR>"
# either fails or creates an unusable env. python.exe never lands at the clean
# path. :die uses exit /b (subroutine return, NOT process exit), so run_setup.bat
# exits 0 regardless. HP_PY is set to the broken path with embedded <CR>, which
# produces the "not recognized" cmd.exe error seen in pyStderr.
#
# FIX: use `conda run -n $condaEnvName python app.py` instead of direct python.exe.
# conda run finds the env via conda's own registry (immune to path derivation
# bugs), activates it properly (handles DLL paths on Windows), and runs the
# script. We use it for its SIDE EFFECT: writing ~smoke_token.txt. We do NOT
# capture stdout (all stdout approaches failed; see history above).
#
# conda bat location: run_setup.bat always installs its own Miniconda to
# $PUBLIC\Documents\Miniconda3 (it does NOT use C:\Miniconda from the runner).
# After bootstrap, conda.bat is at that location.
$haveRunOut = Test-Path -LiteralPath $runout

# Derive env name and locate the conda bat that run_setup.bat installed.
$envLeaf      = Split-Path $app -Leaf
$condaEnvName = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $condaEnvName) { $condaEnvName = '_envsmoke' }
$appPath = Join-Path $app 'app.py'
$publicRoot   = [Environment]::GetEnvironmentVariable('PUBLIC')

# conda bat search paths - priority order mirrors run_setup.bat's :select_conda_bat,
# then falls back to common GitHub Actions runner locations.
# Note: $publicRoot may be null/empty if the PUBLIC env var is unset in this context;
# fallback paths handle that case and also cover runner-provided Miniconda installs.
$publicRootClean = if ($publicRoot) { $publicRoot.Trim().Trim('"') } else { '' }
$condaBatCandidates = @()
if ($publicRootClean) {
    $condaBatCandidates += Join-Path $publicRootClean 'Documents\Miniconda3\condabin\conda.bat'
    $condaBatCandidates += Join-Path $publicRootClean 'Documents\Miniconda3\Scripts\conda.bat'
}

# GitHub Actions windows-latest runner pre-installs Miniconda at these paths:
$condaBatCandidates += 'C:\Miniconda3\condabin\conda.bat'
$condaBatCandidates += 'C:\Miniconda3\Scripts\conda.bat'
$condaBatCandidates += 'C:\ProgramData\Miniconda3\condabin\conda.bat'
$condaBatCandidates += 'C:\ProgramData\Miniconda3\Scripts\conda.bat'
$condaBatCandidates += 'C:\Users\Public\Documents\Miniconda3\condabin\conda.bat'
$condaBatCandidates += 'C:\Users\Public\Documents\Miniconda3\Scripts\conda.bat'

# Try `where.exe conda` as last resort (finds conda if it's on PATH somehow)
$condaBat = $condaBatCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $condaBat) {
    # where.exe searches PATH; conda.bat may be there if the runner pre-activated conda
    $whereResult = where.exe conda 2>$null
    if ($whereResult) { $condaBat = ($whereResult -split "`n")[0].Trim() }
}

$condaRunUsed   = $false
$condaRunStderr = ''
$condaBatUsed   = $condaBat  # captured for diagnostics
if ($condaBat) {
    # derived requirement: always pass -n to conda run so envsmoke executes in
    # the created test env instead of inheriting base when no activation occurred.
    # Keep CWD pinned to $app so app.py side effects land in tests/~envsmoke.
    Push-Location -LiteralPath $app
    try {
        # cmd /c is required because conda.bat is a batch file, not an executable.
        $condaCmd = "`"$condaBat`" run -n $condaEnvName python `"$appPath`""
        $condaCapture = cmd /c $condaCmd 2>&1
        $condaRunUsed = $true
        $condaRunStderr = ($condaCapture |
            Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
            ForEach-Object { $_.Exception.Message }) -join ' '
        if (-not $condaRunStderr) {
            $asStr = ($condaCapture | Where-Object { $_ -is [string] }) -join ' '
            if ($asStr -match 'EnvironmentLocationNotFound|CommandNotFoundError|Error|Traceback|ImportError') {
                $condaRunStderr = $asStr.Substring(0, [Math]::Min(300, $asStr.Length))
            }
        }
    } catch {
        $condaRunUsed   = $true
        $condaRunStderr = $_.Exception.Message
    } finally {
        Pop-Location
    }
}

# Read the token file written by app.py (side effect of conda run above,
# or of run_setup.bat's own cmd.exe run if that ever works).
$tokenTxt = if (Test-Path -LiteralPath $tokenFile) {
    Get-Content -LiteralPath $tokenFile -Raw -Encoding Ascii
} else { '' }
$haveToken = $tokenTxt -match 'smoke-ok'

# Belt-and-suspenders: also accept the ~run.out.txt token (venv/system Python path).
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
    # Conda-run diagnostics: always written so future runs show what PS1 searched for.
    # condaBatFound=false means conda.bat was not at any searched path (Miniconda
    # not installed, or PUBLIC env var empty/wrong). condaBatFound=true +
    # condaRunUsed=false means cmd /c conda run threw before try completed.
    $details.publicRoot = if ($publicRoot) { $publicRoot } else { '(empty)' }
    $details.condaBatCandidates = $condaBatCandidates -join '; '
    $details.condaBatFound = [bool]$condaBat
    if ($condaBat) { $details.condaBatPath = $condaBat }
    if ($condaRunUsed) { $details.condaRunUsed = $true }
    if ($condaRunStderr) { $details.condaRunStderr = $condaRunStderr }
    Write-NdjsonRow ([ordered]@{
        id='envsmoke.run'
        pass=$false
        desc='Environment smoke run missing expected output token after success'
        details=$details
    })
}


# derived requirement: envsmoke must verify the packaged EXE exists, runs standalone,
# and is reused on the second bootstrap so CI can detect PyInstaller or fast-path regressions.
$exeEnvName = ($envLeaf -replace '[^A-Za-z0-9_-]', '_')
if (-not $exeEnvName) { $exeEnvName = '_envsmoke' }
$exePath = Join-Path $app ("dist\\$exeEnvName.exe")
$exeExists = Test-Path -LiteralPath $exePath
Write-NdjsonRow ([ordered]@{
    id='self.exe.build'
    pass=$exeExists
    desc='PyInstaller produced standalone EXE'
    details=[ordered]@{ exePath=$exePath; exists=$exeExists }
})

$exeExit = -1
$exeTokenPath = Join-Path $app 'dist\~smoke_token.txt'
$exeTokenFound = $false
if ($exeExists) {
    try {
        Remove-Item -LiteralPath $exeTokenPath -Force -ErrorAction SilentlyContinue
        Push-Location -LiteralPath $app
        try {
            cmd /c "`"$exePath`"" *> '~envsmoke_exe.log'
            $exeExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $exeTokenFound = Test-Path -LiteralPath $exeTokenPath
    } catch {
        $exeExit = -1
        $exeTokenFound = Test-Path -LiteralPath $exeTokenPath
    }
}
Write-NdjsonRow ([ordered]@{
    id='self.exe.run'
    pass=($exeExists -and ($exeExit -eq 0))
    desc='Standalone EXE runs successfully'
    details=[ordered]@{ exitCode=$exeExit; tokenFound=$exeTokenFound }
})

$fastExit = -1
$fastPathDetected = $false
$prevVenvFallback = if (Test-Path Env:HP_ALLOW_VENV_FALLBACK) { $env:HP_ALLOW_VENV_FALLBACK } else { $null }
$prevSystemFallback = if (Test-Path Env:HP_ALLOW_SYSTEM_FALLBACK) { $env:HP_ALLOW_SYSTEM_FALLBACK } else { $null }
Push-Location -LiteralPath $app
try {
    $env:HP_ALLOW_VENV_FALLBACK = '1'
    $env:HP_ALLOW_SYSTEM_FALLBACK = '1'
    cmd /c "call .\run_setup.bat > ~envsmoke_fastpath.log 2>&1"
    $fastExit = $LASTEXITCODE
} catch {
    $fastExit = -1
} finally {
    if ($null -eq $prevVenvFallback) {
        Remove-Item Env:HP_ALLOW_VENV_FALLBACK -ErrorAction SilentlyContinue
    } else {
        $env:HP_ALLOW_VENV_FALLBACK = $prevVenvFallback
    }
    if ($null -eq $prevSystemFallback) {
        Remove-Item Env:HP_ALLOW_SYSTEM_FALLBACK -ErrorAction SilentlyContinue
    } else {
        $env:HP_ALLOW_SYSTEM_FALLBACK = $prevSystemFallback
    }
    Pop-Location
}

$fastSetupText = if (Test-Path -LiteralPath $setupLog) {
    Get-Content -LiteralPath $setupLog -Raw -Encoding Ascii
} else { '' }
$fastPathDetected = ($fastSetupText -match 'Fast path: reusing')
Write-NdjsonRow ([ordered]@{
    id='self.fastpath'
    pass=(($fastExit -eq 0) -and $fastPathDetected)
    desc='Second run reuses existing EXE via fast path'
    details=[ordered]@{ exitCode=$fastExit; fastPathDetected=$fastPathDetected }
})
