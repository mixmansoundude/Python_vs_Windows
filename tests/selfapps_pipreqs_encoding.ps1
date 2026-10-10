# ASCII only
# selfapps_pipreqs_encoding.ps1 - CLAUDE.md Item 63: one file pipreqs cannot read must not hide
# the dependencies of every other file in the folder.
#
# Field report (2026-10-09): pipreqs 0.4.13 reads every .py with the locale encoding (cp1252 on a
# Western Windows machine running Python 3.14 or older) and re-raises on the first decode or parse
# error, so ONE valid UTF-8 file holding U+201D (byte 0x9D, undefined in cp1252) aborted the whole
# scan and the bootstrapper reported "zero requirements: no imports found". See
# docs/plan-field-report-2026-10.md, Item 63.
#
# Python 3.15 turns UTF-8 mode on by default (PEP 686), which hides this symptom, and the uv-first
# lanes now provision 3.15. This scenario therefore sets PYTHONUTF8=0 for the sub-bootstrap so the
# legacy locale-encoding read is what pipreqs gets on every lane, exactly as a user on Python 3.14
# or older sees it. The row details record what the env's interpreter actually reports.
#
# One bootstrap, three rows, each judged on its own concern:
#   curly_quote     - the maintainer's real file (valid UTF-8, no coding cookie, U+201C and U+201D
#                     in raw-string regexes, plus one real import) still lands in
#                     requirements.auto.txt.
#   mixed_files     - an emoji file and a cp1252-declared file contribute their imports; a cp1252
#                     file with no cookie and an unparseable file are each named in a [WARN] line
#                     of ~setup.log AND on the console, and contribute nothing (their module names
#                     are never treated as requirements even though main.py imports them).
#   never_no_imports - this folder has imports, so neither ~pipreqs.summary.txt nor ~setup.log may
#                     say "no imports found".
#
# derived requirement: the skip hooks keep the sub-bootstrap from executing main.py (it imports
# files that cannot be imported); the build itself still runs and PyInstaller tolerates them.
#
# Lane: real only (gating, uv-first). A red row here fails the lane.
#
# Emits: self.pipreqs.encoding.curly_quote, self.pipreqs.encoding.mixed_files,
#        self.pipreqs.encoding.never_no_imports
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

# Keep NDJSON ASCII-only and short: anything outside printable ASCII becomes '?'.
function Get-Snippet {
    param([string]$Text, [int]$Max = 240)
    if ($null -eq $Text) { return '' }
    $clean = [regex]::Replace($Text, '[^\x20-\x7E]', '?')
    if ($clean.Length -gt $Max) { $clean = $clean.Substring(0, $Max) }
    return $clean
}

function Read-TextOrEmpty {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) {
        # ISO-8859-1 round-trips any byte, so a log holding odd bytes never throws or truncates.
        return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::GetEncoding('ISO-8859-1'))
    }
    return ''
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.encoding.curly_quote'; req = 'REQ-005'; pass = $true; desc = 'pipreqs scan survives U+201D (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.encoding.mixed_files'; req = 'REQ-005'; pass = $true; desc = 'pipreqs scan names files it leaves out (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.encoding.never_no_imports'; req = 'REQ-005'; pass = $true; desc = 'crashed scan never reported as no imports (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.encoding.curly_quote'; req = 'REQ-005'; pass = $false; desc = 'pipreqs encoding: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.encoding.mixed_files'; req = 'REQ-005'; pass = $false; desc = 'pipreqs encoding: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.encoding.never_no_imports'; req = 'REQ-005'; pass = $false; desc = 'pipreqs encoding: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

$workDir = Join-Path $here '~selftest_pipreqs_encoding'
if (Test-Path -LiteralPath $workDir) { Remove-Item -LiteralPath $workDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null
Copy-Item -Path $batchPath -Destination $workDir -Force

$utf8 = New-Object System.Text.UTF8Encoding($false)
# Latin-1 and cp1252 agree on U+00E9 (byte 0xE9) and Latin-1 needs no code-page provider.
$cp1252 = [System.Text.Encoding]::GetEncoding('ISO-8859-1')
$lq = [string][char]0x201C   # left double quotation mark, E2 80 9C in UTF-8 (decodes in cp1252)
$rq = [string][char]0x201D   # right double quotation mark, E2 80 9D in UTF-8 (0x9D is undefined in cp1252)
$emoji = [char]::ConvertFromUtf32(0x1F50D)   # F0 9F 94 8D in UTF-8 (0x8D is undefined in cp1252)

# The maintainer's real file shape: valid UTF-8, NO coding cookie, smart-quote cleanup regexes.
$adjacent = "import re`nimport colorama`n`n`ndef clean(data):`n" +
    "    data = re.sub(r'" + $lq + "', '`"', data)`n" +
    "    data = re.sub(r'" + $rq + "', '`"', data)`n" +
    "    return colorama.Fore.RESET + data`n"
[System.IO.File]::WriteAllBytes((Join-Path $workDir 'adjacent.py'), $utf8.GetBytes($adjacent))

# Ordinary AI-written script: an emoji in a print().
$emojiTool = "import tabulate`n`n`ndef show(rows):`n    print('" + $emoji + " ' + tabulate.tabulate(rows))`n"
[System.IO.File]::WriteAllBytes((Join-Path $workDir 'emoji_tool.py'), $utf8.GetBytes($emojiTool))

# A cp1252 file that DECLARES its encoding (PEP 263): valid Python, not valid UTF-8.
$declared = "# -*- coding: cp1252 -*-`nimport termcolor`n`nNAME = 'caf" + [string][char]0x00E9 + "'`n"
[System.IO.File]::WriteAllBytes((Join-Path $workDir 'cp1252_declared.py'), $cp1252.GetBytes($declared))

# A cp1252 file with NO cookie: Python itself rejects it as source, so it must be left out and named.
$noCookie = "NAME = 'caf" + [string][char]0x00E9 + "'`n"
[System.IO.File]::WriteAllBytes((Join-Path $workDir 'cp1252_nocookie.py'), $cp1252.GetBytes($noCookie))

# A file that does not parse.
[System.IO.File]::WriteAllBytes((Join-Path $workDir 'unparseable.py'), $utf8.GetBytes("import jinja2`n`n`ndef broken(:`n    pass`n"))

# The entry imports every file, including the two that cannot be read: pipreqs treats an import
# that matches a .py filename in the scanned tree as local, so neither module name may become a
# requirement.
$main = "import adjacent`nimport emoji_tool`nimport cp1252_declared`nimport cp1252_nocookie`nimport unparseable`n`nprint('pipreqs-encoding-ok')`n"
[System.IO.File]::WriteAllBytes((Join-Path $workDir 'main.py'), $utf8.GetBytes($main))

$bootstrapLog = '~pipreqs_encoding_bootstrap.log'
$prevUtf8 = if (Test-Path Env:PYTHONUTF8) { $env:PYTHONUTF8 } else { $null }
$prevSkipEntry = if (Test-Path Env:HP_SKIP_ENTRY_SMOKE) { $env:HP_SKIP_ENTRY_SMOKE } else { $null }
$prevSkipExe = if (Test-Path Env:HP_SKIP_EXE_SMOKERUN) { $env:HP_SKIP_EXE_SMOKERUN } else { $null }
$env:PYTHONUTF8 = '0'
$env:HP_SKIP_ENTRY_SMOKE = '1'
$env:HP_SKIP_EXE_SMOKERUN = '1'
try {
    Push-Location $workDir
    try {
        cmd /c "call run_setup.bat > $bootstrapLog 2>&1"
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $setupLog    = Read-TextOrEmpty (Join-Path $workDir '~setup.log')
    $summaryText = Read-TextOrEmpty (Join-Path $workDir '~pipreqs.summary.txt')
    $directLog   = Read-TextOrEmpty (Join-Path $workDir '~pipreqs_direct.log')
    $consoleText = Read-TextOrEmpty (Join-Path $workDir $bootstrapLog)
    $autoPath    = Join-Path $workDir 'requirements.auto.txt'
    $autoExists  = Test-Path -LiteralPath $autoPath
    $autoText    = Read-TextOrEmpty $autoPath

    # What the env's own interpreter reports, so a lane that does NOT read with cp1252 is visible
    # in the row instead of silently making the scenario meaningless.
    $pyEncoding = ''
    $interp = [regex]::Match($summaryText, '(?m)^Interpreter:\s*(.+?)\s*$')
    if ($interp.Success -and (Test-Path -LiteralPath $interp.Groups[1].Value)) {
        $pyEncoding = (& $interp.Groups[1].Value -c "import sys,locale; print(sys.flags.utf8_mode, locale.getpreferredencoding(False))" 2>&1 | Out-String).Trim()
    }
    # derived requirement: a run that did not read with cp1252 and UTF-8 mode off never exercised the
    # bug, so it must fail loudly instead of passing without testing anything.
    $encodingOk = [regex]::IsMatch($pyEncoding, '(?im)^\s*0\s+cp1252\s*$')

    $directLastLine = ''
    $directLines = @($directLog -split "`r?`n" | Where-Object { $_.Trim() -ne '' })
    if ($directLines.Count -gt 0) { $directLastLine = $directLines[$directLines.Count - 1] }
    $rcLine = ''
    $rcMatch = [regex]::Match($setupLog, '(?m)^.*\[DEBUG\] pipreqs \(direct\) rc=\S+ size=\S+')
    if ($rcMatch.Success) { $rcLine = $rcMatch.Value }

    function Test-ReqLine {
        param([string]$Text, [string]$Name)
        return [regex]::IsMatch($Text, '(?im)^\s*' + [regex]::Escape($Name) + '\s*([<>=!~].*)?$')
    }
    $hasColorama = Test-ReqLine $autoText 'colorama'
    $hasTabulate = Test-ReqLine $autoText 'tabulate'
    $hasTermcolor = Test-ReqLine $autoText 'termcolor'
    $hasLocalName = (Test-ReqLine $autoText 'unparseable') -or (Test-ReqLine $autoText 'cp1252_nocookie') -or (Test-ReqLine $autoText 'adjacent') -or (Test-ReqLine $autoText 'emoji_tool') -or (Test-ReqLine $autoText 'cp1252_declared')

    $warnLines = @($setupLog -split "`r?`n" | Where-Object { $_ -match '\[WARN\]' })
    $warnNamesNoCookie = @($warnLines | Where-Object { $_ -match 'cp1252_nocookie\.py' }).Count -gt 0
    $warnNamesUnparseable = @($warnLines | Where-Object { $_ -match 'unparseable\.py' }).Count -gt 0
    $warnNamesGoodFile = @($warnLines | Where-Object { $_ -match 'adjacent\.py|emoji_tool\.py|cp1252_declared\.py' }).Count -gt 0

    # What a double-click user sees: the same [WARN] lines must reach the console, not only the log.
    $consoleWarns = @($consoleText -split "`r?`n" | Where-Object { $_ -match '\[WARN\]' })
    $consoleNamesNoCookie = @($consoleWarns | Where-Object { $_ -match 'cp1252_nocookie\.py' }).Count -gt 0
    $consoleNamesUnparseable = @($consoleWarns | Where-Object { $_ -match 'unparseable\.py' }).Count -gt 0

    $summaryNoImports = $summaryText -match 'no imports found'
    $setupNoImports = $setupLog -match 'no imports found'

    $curlyPass = $encodingOk -and $autoExists -and $hasColorama
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pipreqs.encoding.curly_quote'
        req     = 'REQ-005'
        pass    = $curlyPass
        desc    = 'pipreqs scan keeps the imports of a valid UTF-8 file holding U+201D (cp1252 locale read)'
        details = [ordered]@{
            exitCode       = $exitCode
            autoExists     = $autoExists
            hasColorama    = $hasColorama
            pyEncoding     = Get-Snippet $pyEncoding 80
            encodingOk     = $encodingOk
            directRcLine   = Get-Snippet $rcLine 160
            directLastLine = Get-Snippet $directLastLine 200
            log            = $bootstrapLog
        }
    })

    $mixedPass = $encodingOk -and $autoExists -and $hasColorama -and $hasTabulate -and $hasTermcolor -and (-not $hasLocalName) -and $warnNamesNoCookie -and $warnNamesUnparseable -and (-not $warnNamesGoodFile) -and $consoleNamesNoCookie -and $consoleNamesUnparseable
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pipreqs.encoding.mixed_files'
        req     = 'REQ-005'
        pass    = $mixedPass
        desc    = 'pipreqs scan keeps emoji and declared-cp1252 imports and names the files it leaves out'
        details = [ordered]@{
            autoExists            = $autoExists
            hasColorama           = $hasColorama
            hasTabulate           = $hasTabulate
            hasTermcolor          = $hasTermcolor
            localNameInReqs       = $hasLocalName
            warnNamesNoCookie     = $warnNamesNoCookie
            warnNamesUnparseable  = $warnNamesUnparseable
            warnNamesReadableFile = $warnNamesGoodFile
            warnCount             = $warnLines.Count
            consoleNamesNoCookie  = $consoleNamesNoCookie
            consoleNamesUnparseable = $consoleNamesUnparseable
            log                   = $bootstrapLog
        }
    })

    $neverPass = $encodingOk -and (-not $summaryNoImports) -and (-not $setupNoImports)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pipreqs.encoding.never_no_imports'
        req     = 'REQ-005'
        pass    = $neverPass
        desc    = 'A folder that has imports is never summarized as "no imports found"'
        details = [ordered]@{
            summaryNoImports = $summaryNoImports
            setupLogNoImports = $setupNoImports
            summaryPhase     = Get-Snippet (([regex]::Match($summaryText, '(?m)^Phase:.*$')).Value) 160
            log              = $bootstrapLog
        }
    })
} finally {
    if ($null -eq $prevUtf8) { Remove-Item Env:PYTHONUTF8 -ErrorAction SilentlyContinue } else { $env:PYTHONUTF8 = $prevUtf8 }
    if ($null -eq $prevSkipEntry) { Remove-Item Env:HP_SKIP_ENTRY_SMOKE -ErrorAction SilentlyContinue } else { $env:HP_SKIP_ENTRY_SMOKE = $prevSkipEntry }
    if ($null -eq $prevSkipExe) { Remove-Item Env:HP_SKIP_EXE_SMOKERUN -ErrorAction SilentlyContinue } else { $env:HP_SKIP_EXE_SMOKERUN = $prevSkipExe }
}

if (-not ($curlyPass -and $mixedPass -and $neverPass)) { exit 1 }
exit 0
