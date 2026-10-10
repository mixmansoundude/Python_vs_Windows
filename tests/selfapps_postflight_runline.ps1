# ASCII only
# selfapps_postflight_runline.ps1 - CLAUDE.md Active Backlog Item 69 (investigation, NOT a fix):
# does the "run it yourself" line the post-flight briefing prints actually run when it is used
# the way a person would use it? The August field note says the printed
#   "<python.exe>" "main.py"
# failed when tried by hand and worked with the quotes dropped; a later hand check in Command
# Prompt worked. Nothing in CI ever executed the PRINTED text, only the bootstrapper's own
# equivalent command, so this check captures the line from a REAL bootstrap run's console output
# and runs it as printed.
#
# Non-gating by construction: wired only into the uv and justme-test lanes (neither is a gated
# lane; justme-test and uv resolve to different providers, so together they cover the
# "same mechanism in both lanes" question), under a step with continue-on-error: true.
#
# Rows:
#   self.postflight.runline.verbatim  pass = the line, written to a .cmd file exactly as printed
#                                     and run by cmd.exe, runs the app. A .cmd file is parsed the
#                                     way a pasted Command Prompt line is; `cmd /c "<line>"`
#                                     would not be, because cmd /c strips the outer quotes.
#   self.postflight.runline.variants  always pass=true, informational only: each variant's
#                                     outcome (quotes dropped, curly quotes, a space in the
#                                     interpreter path with and without quotes, the line in
#                                     Windows PowerShell with and without a leading &) goes in
#                                     details so the maintainer's August observation can be
#                                     compared against what each shell really does.
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

# derived requirement: OSVersion.Platform, never $IsWindows (undefined under Windows PowerShell 5.1).
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{
        id      = 'self.postflight.runline.verbatim'
        req     = 'REQ-016'
        pass    = $true
        desc    = 'Post-flight run line runs as printed (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.postflight.runline.variants'
        req     = 'REQ-016'
        pass    = $true
        desc    = 'Post-flight run line variants, informational (skipped on non-Windows)'
        details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' }
    })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.postflight.runline.verbatim'
        req     = 'REQ-016'
        pass    = $false
        desc    = 'Post-flight run line runs as printed: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}

$workDir = Join-Path $here '~selftest_postflight_runline'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force
$marker = 'PVW_RUNLINE_OK'
Set-Content -Path (Join-Path $workDir 'app.py') -Value ('print("' + $marker + '")') -Encoding ASCII

$prev = if (Test-Path Env:HP_SKIP_PIPREQS) { $env:HP_SKIP_PIPREQS } else { $null }
$env:HP_SKIP_PIPREQS = '1'
$bootLog = '~postflight_runline_bootstrap.log'
Push-Location $workDir
try {
    cmd /c "call run_setup.bat > $bootLog 2>&1"
    $bootExit = $LASTEXITCODE
} finally {
    Pop-Location
    if ($null -eq $prev) {
        Remove-Item Env:HP_SKIP_PIPREQS -ErrorAction SilentlyContinue
    } else {
        $env:HP_SKIP_PIPREQS = $prev
    }
}

# Find the printed line. The EXE briefing prints it after "directly via the interpreter at any
# time:"; the no-EXE briefing prints it right under "RUNNING YOUR APP (without an .exe)". Take
# the first following line that starts with a double quote.
$bootPath = Join-Path $workDir $bootLog
$bootLines = @()
if (Test-Path -LiteralPath $bootPath) {
    $bootLines = @(Get-Content -LiteralPath $bootPath -Encoding ASCII)
}
$printed = $null
$source = $null
for ($i = 0; $i -lt $bootLines.Count; $i++) {
    $text = $bootLines[$i]
    $isEx  = $text -match [regex]::Escape('directly via the interpreter at any time:')
    $isNo  = $text -match [regex]::Escape('RUNNING YOUR APP (without an .exe)')
    if (-not ($isEx -or $isNo)) { continue }
    for ($j = $i + 1; $j -lt [Math]::Min($i + 4, $bootLines.Count); $j++) {
        if ($bootLines[$j].TrimStart().StartsWith('"')) {
            $printed = $bootLines[$j].Trim()
            $source = if ($isEx) { 'exe-briefing' } else { 'noexe-briefing' }
            break
        }
    }
    if ($printed) { break }
}

$exe = $null
$entry = $null
if ($printed -and ($printed -match '^"([^"]+)"\s+"([^"]+)"$')) {
    $exe = $Matches[1]
    $entry = $Matches[2]
}

if (-not $exe) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.postflight.runline.verbatim'
        req     = 'REQ-016'
        pass    = $false
        desc    = 'Post-flight run line runs as printed: the printed line was not found in the bootstrap console output'
        details = [ordered]@{ bootExit = $bootExit; bootLogLines = $bootLines.Count; printed = $printed }
    })
    Write-NdjsonRow ([ordered]@{
        id      = 'self.postflight.runline.variants'
        req     = 'REQ-016'
        pass    = $true
        desc    = 'Post-flight run line variants, informational: no printed line to vary'
        details = [ordered]@{ skip = $true; reason = 'printed-line-not-found' }
    })
    exit 1
}

# cmd.exe reads a batch file in the console code page, so text is written as raw bytes: ASCII as
# is, and the two curly double quotes as their Windows-1252 bytes (0x93 and 0x94). To cmd.exe
# either one is just an ordinary character, whatever the code page.
function ConvertTo-LineBytes {
    param([string]$Text)
    $list = New-Object System.Collections.Generic.List[byte]
    foreach ($ch in $Text.ToCharArray()) {
        $code = [int]$ch
        if ($code -eq 0x201C) { $list.Add([byte]0x93) }
        elseif ($code -eq 0x201D) { $list.Add([byte]0x94) }
        elseif ($code -lt 128) { $list.Add([byte]$code) }
        else { $list.Add([byte]0x3F) }
    }
    return , $list.ToArray()
}

function Get-Snippet {
    param([string]$Text)
    $flat = ($Text -replace '[^\x20-\x7E]+', ' ').Trim()
    if ($flat.Length -gt 220) { $flat = $flat.Substring(0, 220) }
    return $flat
}

function Invoke-CmdLine {
    param([string]$Line, [string]$FileName)
    $path = Join-Path $workDir $FileName
    $body = "@echo off`r`n" + $Line + "`r`necho PVW_RC=%errorlevel%`r`n"
    [System.IO.File]::WriteAllBytes($path, (ConvertTo-LineBytes $body))
    Push-Location $workDir
    try {
        $out = (& cmd.exe /d /c $FileName 2>&1 | Out-String)
    } finally {
        Pop-Location
    }
    $ran = ($out -match [regex]::Escape($marker)) -and ($out -match 'PVW_RC=0')
    return [ordered]@{ ran = $ran; out = (Get-Snippet $out) }
}

function Invoke-PsLine {
    param([string]$Line, [string]$FileName)
    $path = Join-Path $workDir $FileName
    [System.IO.File]::WriteAllBytes($path, (ConvertTo-LineBytes ($Line + "`r`n")))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Push-Location $workDir
    try {
        $out = (& $ps -NoProfile -ExecutionPolicy Bypass -File $path 2>&1 | Out-String)
    } finally {
        Pop-Location
    }
    $ran = $out -match [regex]::Escape($marker)
    return [ordered]@{ ran = $ran; out = (Get-Snippet $out) }
}

$kind = if ($exe -match '\\\.uv_env\\') { 'uv-venv' } elseif ($exe -match '(?i)conda') { 'conda' } else { 'other' }

# The claim: the line, exactly as printed, runs.
$verbatim = Invoke-CmdLine -Line $printed -FileName '~runline_verbatim.cmd'

# Informational variants.
$variants = [ordered]@{}
$variants.cmd_no_quotes = Invoke-CmdLine -Line ($exe + ' ' + $entry) -FileName '~runline_noquotes.cmd'
$curly = [string][char]0x201C
$curlyEnd = [string][char]0x201D
$variants.cmd_curly_quotes = Invoke-CmdLine -Line ($curly + $exe + $curlyEnd + ' ' + $curly + $entry + $curlyEnd) -FileName '~runline_curly.cmd'
$variants.ps51_verbatim = Invoke-PsLine -Line $printed -FileName '~runline_verbatim.ps1'
$variants.ps51_with_call_operator = Invoke-PsLine -Line ('& ' + $printed) -FileName '~runline_amp.ps1'

# A space in the interpreter path: a junction named with a space, pointing at the environment
# root (the directory holding pyvenv.cfg or conda-meta), then the same relative interpreter path
# beneath it. Pointing at the root rather than Scripts\ keeps a venv's pyvenv.cfg lookup valid.
$envRoot = $null
$walk = Split-Path -Parent $exe
while ($walk -and (Test-Path -LiteralPath $walk)) {
    if ((Test-Path -LiteralPath (Join-Path $walk 'pyvenv.cfg')) -or (Test-Path -LiteralPath (Join-Path $walk 'conda-meta'))) {
        $envRoot = $walk
        break
    }
    $up = Split-Path -Parent $walk
    if ((-not $up) -or ($up -eq $walk)) { break }
    $walk = $up
}
$spaceNote = 'not-run'
if ($envRoot -and $exe.StartsWith($envRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    $rel = $exe.Substring($envRoot.Length).TrimStart('\')
    $link = Join-Path $workDir '~pvw space link'
    try {
        New-Item -ItemType Junction -Path $link -Target $envRoot -ErrorAction Stop | Out-Null
        $spaceExe = Join-Path $link $rel
        $variants.cmd_space_in_path_quoted = Invoke-CmdLine -Line ('"' + $spaceExe + '" "' + $entry + '"') -FileName '~runline_space_quoted.cmd'
        $variants.cmd_space_in_path_unquoted = Invoke-CmdLine -Line ($spaceExe + ' ' + $entry) -FileName '~runline_space_unquoted.cmd'
        $spaceNote = 'ran'
    } catch {
        $spaceNote = 'junction-failed: ' + (Get-Snippet $_.Exception.Message)
    } finally {
        # Directory.Delete on a junction removes only the link, never the target's contents.
        if (Test-Path -LiteralPath $link) { [System.IO.Directory]::Delete($link) }
    }
} else {
    $spaceNote = 'env-root-not-found'
}

$details = [ordered]@{ printed = (Get-Snippet $printed); source = $source; interpreterKind = $kind; bootExit = $bootExit }
Write-NdjsonRow ([ordered]@{
    id      = 'self.postflight.runline.verbatim'
    req     = 'REQ-016'
    pass    = [bool]$verbatim.ran
    desc    = 'The run line the post-flight briefing prints runs the app when used exactly as printed (cmd.exe, straight quotes)'
    details = [ordered]@{
        printed         = $details.printed
        source          = $details.source
        interpreterKind = $details.interpreterKind
        bootExit        = $details.bootExit
        ran             = [bool]$verbatim.ran
        output          = $verbatim.out
    }
})

Write-NdjsonRow ([ordered]@{
    id      = 'self.postflight.runline.variants'
    req     = 'REQ-016'
    pass    = $true
    desc    = 'Post-flight run line variants (quotes dropped, curly quotes, space in path, Windows PowerShell), informational only'
    details = [ordered]@{
        interpreterKind = $kind
        spacePathRun    = $spaceNote
        variants        = $variants
    }
})

if (-not $verbatim.ran) { exit 1 }
exit 0
