# ASCII only
# selfapps_pipreqs_output.ps1 - CLAUDE.md Item 63 follow-up: the pipreqs scan must never accept a
# stale requirements.auto.txt as this run's result, and one scan must never share a temp folder
# with another project's scan.
#
# Background (PR #478 review): when a folder holds a file pipreqs cannot read, the bootstrapper
# scans a UTF-8 copy of the project under the temp folder and copies the result back to
# requirements.auto.txt. Two gaps were found in that path:
#   1. If the copy-back fails (the old requirements.auto.txt is read-only or held open by another
#      program) the failure was only a log line and the OLD file was accepted as this run's scan.
#   2. The copy lives at a fixed name, %TEMP%\pipreqs_stage, which the next scan deletes first, so
#      two projects bootstrapping within seconds of each other can delete each other's copy.
#
# Two real bootstraps (skip hooks, so main.py never runs). The folder holds good.py (imports
# colorama), a cp1252 file with no coding cookie (forces the UTF-8 copy path) and main.py.
#
#   Bootstrap 1 - an OLD requirements.auto.txt that is READ-ONLY and lists "six", plus a sentinel
#                 file in the fixed temp folder name standing in for another project's scan.
#     readonly_replaced - the file now lists colorama and no longer lists six (the old file was
#                         cleared before the scan instead of being kept).
#     temp_isolated     - the sentinel is untouched, and the scan left no temp folder of its own.
#
#   Bootstrap 2 - an OLD requirements.auto.txt that this script holds open so it can be neither
#                 deleted nor overwritten (read allowed, like an indexer or sync client would).
#     locked_named      - the scan is reported as failed, a console [WARN] line names
#                         requirements.auto.txt, nothing says "no imports found", the old file's
#                         dependencies are not promoted into the resolved dependency list, and
#                         the bootstrap carries on (a failed scan never blocks the bootstrap).
#
#   Bootstrap 3 - PR #480 review: a clean project (no cp1252 file, so the scan runs in place) whose
#                 old requirements.auto.txt is held open as in bootstrap 2, while pipreqs itself
#                 crashes in every scan it attempts (REQUESTS_CA_BUNDLE points at a file that does not
#                 exist, so pipreqs fails the moment it asks PyPI about colorama). Nothing then
#                 replaces the old file, and the old dependencies must still not be installed.
#     locked_crash      - the resolved list and requirements.txt hold no dependency from the old
#                         file, the scan is reported failed, and a console [WARN] names
#                         requirements.auto.txt. The row also requires the crash to be the expected
#                         one (the direct scan's log shows the CA bundle error), or it proves nothing.
#
# Rows 1 and 2 also require that the UTF-8 copy path was really used, so a run that scanned in place
# cannot pass without testing anything. The proof is the summary note (a scan that worked) or the
# setup log line that announces the copy (a scan that failed has no such note in its summary).
#
# derived requirement: the child bootstraps run with RUNNER_TEMP pointed at a folder private to this
# script (tests\~pipreqs_output_temp), so the sentinel and every cleanup touch only that folder and
# never another scan's staging folder in the real temp root. Only that private folder is removed.
#
# Lane: real only (gating, uv-first), next to selfapps_pipreqs_encoding.ps1.
#
# Emits: self.pipreqs.output.readonly_replaced, self.pipreqs.output.temp_isolated,
#        self.pipreqs.output.locked_named, self.pipreqs.output.locked_crash
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

# The scan used the UTF-8 copy path. A scan that worked says so in its summary; a scan that failed
# (the copy-back could not be written) ends with a failure summary instead, so the setup log line
# that announces the copy counts too.
function Test-UsedCopy {
    param([string]$Summary, [string]$SetupLog)
    return ($Summary -match 'scanned a UTF-8 copy') -or ($SetupLog -match 'scanning a UTF-8 copy of the project')
}

function Test-ReqLine {
    param([string]$Text, [string]$Name)
    return [regex]::IsMatch($Text, '(?im)^\s*' + [regex]::Escape($Name) + '\s*([<>=!~].*)?$')
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    $platform = [System.Environment]::OSVersion.Platform.ToString()
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.output.readonly_replaced'; req = 'REQ-005'; pass = $true; desc = 'read-only old requirements.auto.txt is replaced (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.output.temp_isolated'; req = 'REQ-005'; pass = $true; desc = 'scan temp folder is not shared (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.output.locked_named'; req = 'REQ-005'; pass = $true; desc = 'locked old requirements.auto.txt is named, scan reported failed (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.output.locked_crash'; req = 'REQ-005'; pass = $true; desc = 'locked old requirements.auto.txt is not installed when every scan crashes (skipped on non-Windows)'; details = [ordered]@{ skip = $true; platform = $platform; reason = 'non-windows-host' } })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.output.readonly_replaced'; req = 'REQ-005'; pass = $false; desc = 'pipreqs output: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.output.temp_isolated'; req = 'REQ-005'; pass = $false; desc = 'pipreqs output: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.output.locked_named'; req = 'REQ-005'; pass = $false; desc = 'pipreqs output: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    Write-NdjsonRow ([ordered]@{ id = 'self.pipreqs.output.locked_crash'; req = 'REQ-005'; pass = $false; desc = 'pipreqs output: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    exit 1
}

$utf8 = New-Object System.Text.UTF8Encoding($false)
# Latin-1 and cp1252 agree on U+00E9 (byte 0xE9); a cp1252 file with no coding cookie is not valid
# UTF-8 or valid Python source, so the pre-check leaves it out and scans a UTF-8 copy instead.
$cp1252 = [System.Text.Encoding]::GetEncoding('ISO-8859-1')

function New-ScenarioDir {
    param([string]$Name, [switch]$Clean)
    $dir = Join-Path $here ('~selftest_pipreqs_output_' + $Name)
    if (Test-Path -LiteralPath $dir) {
        # A leftover read-only file from an earlier local run would block the delete.
        Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object { try { $_.IsReadOnly = $false } catch { } }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Copy-Item -Path $batchPath -Destination $dir -Force
    [System.IO.File]::WriteAllBytes((Join-Path $dir 'good.py'), $utf8.GetBytes("import colorama`n`nGREEN = colorama.Fore.GREEN`n"))
    if ($Clean) {
        # Every file is clean UTF-8, so the pre-check lets pipreqs scan the folder in place.
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'main.py'), $utf8.GetBytes("import good`n`nprint('pipreqs-output-ok')`n"))
    } else {
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'cp1252_nocookie.py'), $cp1252.GetBytes("NAME = 'caf" + [string][char]0x00E9 + "'`n"))
        [System.IO.File]::WriteAllBytes((Join-Path $dir 'main.py'), $utf8.GetBytes("import good`nimport cp1252_nocookie`n`nprint('pipreqs-output-ok')`n"))
    }
    return $dir
}

function Invoke-Bootstrap {
    param([string]$Dir, [string]$LogName)
    Push-Location $Dir
    try {
        cmd /c "call run_setup.bat > $LogName 2>&1"
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

# The bootstrapper stages its copy under RUNNER_TEMP (then TEMP). Point it at a folder private to
# this script so nothing here can touch a scan that is running elsewhere on the machine.
$tempRoot = Join-Path $here '~pipreqs_output_temp'
$fixedStage = Join-Path $tempRoot 'pipreqs_stage'
$prevRunnerTemp = if (Test-Path Env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { $null }
if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
$env:RUNNER_TEMP = $tempRoot

$prevSkipEntry = if (Test-Path Env:HP_SKIP_ENTRY_SMOKE) { $env:HP_SKIP_ENTRY_SMOKE } else { $null }
$prevSkipExe = if (Test-Path Env:HP_SKIP_EXE_SMOKERUN) { $env:HP_SKIP_EXE_SMOKERUN } else { $null }
$env:HP_SKIP_ENTRY_SMOKE = '1'
$env:HP_SKIP_EXE_SMOKERUN = '1'
$readonlyPass = $false
$tempPass = $false
$lockedPass = $false
$crashPass = $false
$lock = $null
$lock3 = $null
$prevCaBundle = if (Test-Path Env:REQUESTS_CA_BUNDLE) { $env:REQUESTS_CA_BUNDLE } else { $null }
try {
    # ---------------- Bootstrap 1: read-only old output, and a sentinel in the shared temp name ----
    $dir1 = New-ScenarioDir 'readonly'
    $auto1 = Join-Path $dir1 'requirements.auto.txt'
    [System.IO.File]::WriteAllBytes($auto1, $utf8.GetBytes("six==1.16.0`r`n"))
    Set-ItemProperty -LiteralPath $auto1 -Name IsReadOnly -Value $true
    $wasReadOnly = (Get-Item -LiteralPath $auto1).IsReadOnly

    # Stands in for another project's scan that is running right now under the fixed name.
    New-Item -ItemType Directory -Force -Path $fixedStage | Out-Null
    $sentinel = Join-Path $fixedStage '~other_project_scan.txt'
    [System.IO.File]::WriteAllText($sentinel, "another project is scanning here`n")
    $stagesBefore = @(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'pipreqs_stage_*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

    $log1 = '~pipreqs_output_readonly.log'
    $exit1 = Invoke-Bootstrap $dir1 $log1

    $sentinelSurvived = Test-Path -LiteralPath $sentinel
    $stagesAfter = @(Get-ChildItem -LiteralPath $tempRoot -Directory -Filter 'pipreqs_stage_*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
    $leftover = @($stagesAfter | Where-Object { $stagesBefore -notcontains $_ })

    $summary1 = Read-TextOrEmpty (Join-Path $dir1 '~pipreqs.summary.txt')
    $setup1 = Read-TextOrEmpty (Join-Path $dir1 '~setup.log')
    $autoText1 = Read-TextOrEmpty $auto1
    $staged1 = Test-UsedCopy $summary1 $setup1
    $hasColorama1 = Test-ReqLine $autoText1 'colorama'
    $hasSix1 = Test-ReqLine $autoText1 'six'

    $readonlyPass = $wasReadOnly -and $staged1 -and $hasColorama1 -and (-not $hasSix1)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pipreqs.output.readonly_replaced'
        req     = 'REQ-005'
        pass    = $readonlyPass
        desc    = 'A read-only old requirements.auto.txt is replaced by this run''s scan, never kept as its result'
        details = [ordered]@{
            exitCode       = $exit1
            wasReadOnly    = $wasReadOnly
            usedUtf8Copy   = $staged1
            hasColorama    = $hasColorama1
            oldSixStillIn  = $hasSix1
            autoSnippet    = Get-Snippet $autoText1 120
            summaryPhase   = Get-Snippet (([regex]::Match($summary1, '(?m)^Phase:.*$')).Value) 160
            log            = $log1
        }
    })

    $tempPass = $staged1 -and $sentinelSurvived -and ($leftover.Count -eq 0)
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pipreqs.output.temp_isolated'
        req     = 'REQ-005'
        pass    = $tempPass
        desc    = 'A scan uses a temp folder of its own: another scan''s folder survives and nothing is left behind'
        details = [ordered]@{
            usedUtf8Copy      = $staged1
            sentinelSurvived  = $sentinelSurvived
            leftoverFolders   = ($leftover -join ',')
            log               = $log1
        }
    })

    # ---------------- Bootstrap 2: old output held open by another program --------------------------
    $dir2 = New-ScenarioDir 'locked'
    $auto2 = Join-Path $dir2 'requirements.auto.txt'
    [System.IO.File]::WriteAllBytes($auto2, $utf8.GetBytes("six==1.16.0`r`n"))
    # Read access, others may read but not write or delete: how an indexer or sync client holds a file.
    $lock = [System.IO.File]::Open($auto2, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $lockHeld = $true

    $log2 = '~pipreqs_output_locked.log'
    $exit2 = Invoke-Bootstrap $dir2 $log2

    $lock.Dispose()
    $lock = $null

    $summary2 = Read-TextOrEmpty (Join-Path $dir2 '~pipreqs.summary.txt')
    $setup2 = Read-TextOrEmpty (Join-Path $dir2 '~setup.log')
    $console2 = Read-TextOrEmpty (Join-Path $dir2 $log2)
    $autoText2 = Read-TextOrEmpty $auto2
    $resolvedText2 = Read-TextOrEmpty (Join-Path $dir2 '~dependency_resolved.txt')
    $staged2 = Test-UsedCopy $summary2 $setup2
    $stillOld = Test-ReqLine $autoText2 'six'
    # The old file's dependencies must not be copied into requirements.txt and installed as if the
    # scan had produced them: the resolved snapshot is a copy of requirements.txt.
    $resolvedHasSix = Test-ReqLine $resolvedText2 'six'
    $phaseFailed = [regex]::IsMatch($summary2, '(?m)^Phase:\s+failed')
    $consoleWarns2 = @($console2 -split "`r?`n" | Where-Object { $_ -match '\[WARN\]' })
    $consoleNamesFile = @($consoleWarns2 | Where-Object { $_ -match 'requirements\.auto\.txt' }).Count -gt 0
    $noImportsClaim = ($summary2 -match 'no imports found') -or ($setup2 -match 'no imports found')
    $carriedOn = $setup2 -match 'continuing without auto-detected requirements'

    $lockedPass = $lockHeld -and $staged2 -and $stillOld -and (-not $resolvedHasSix) -and $phaseFailed -and $consoleNamesFile -and (-not $noImportsClaim) -and $carriedOn
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pipreqs.output.locked_named'
        req     = 'REQ-005'
        pass    = $lockedPass
        desc    = 'When the old requirements.auto.txt cannot be replaced the scan is reported failed and the file is named'
        details = [ordered]@{
            exitCode          = $exit2
            lockHeld          = $lockHeld
            usedUtf8Copy      = $staged2
            oldFileUntouched  = $stillOld
            resolvedHasOldDep = $resolvedHasSix
            summaryPhaseFailed = $phaseFailed
            consoleNamesFile  = $consoleNamesFile
            noImportsClaim    = $noImportsClaim
            carriedOn         = $carriedOn
            summaryPhase      = Get-Snippet (([regex]::Match($summary2, '(?m)^Phase:.*$')).Value) 160
            consoleWarnCount  = $consoleWarns2.Count
            log               = $log2
        }
    })

    # ---------------- Bootstrap 3: old output held open, and every pipreqs scan crashes -------------
    # pipreqs asks PyPI about any import it cannot find in the environment (colorama here). With
    # REQUESTS_CA_BUNDLE pointing at a file that does not exist, requests refuses to make the call
    # and pipreqs dies with a traceback, in the scan of the project and in the fallback scan alike.
    # uv ignores that variable, so only pipreqs is affected. Nothing then replaces the old file.
    $dir3 = New-ScenarioDir 'lockedcrash' -Clean
    $auto3 = Join-Path $dir3 'requirements.auto.txt'
    [System.IO.File]::WriteAllBytes($auto3, $utf8.GetBytes("six==1.16.0`r`n"))
    $lock3 = [System.IO.File]::Open($auto3, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $lockHeld3 = $true
    $env:REQUESTS_CA_BUNDLE = Join-Path $tempRoot 'no-such-ca-bundle.pem'

    $log3 = '~pipreqs_output_lockedcrash.log'
    $exit3 = Invoke-Bootstrap $dir3 $log3

    if ($null -eq $prevCaBundle) { Remove-Item Env:REQUESTS_CA_BUNDLE -ErrorAction SilentlyContinue } else { $env:REQUESTS_CA_BUNDLE = $prevCaBundle }
    $lock3.Dispose()
    $lock3 = $null

    $summary3 = Read-TextOrEmpty (Join-Path $dir3 '~pipreqs.summary.txt')
    $setup3 = Read-TextOrEmpty (Join-Path $dir3 '~setup.log')
    $console3 = Read-TextOrEmpty (Join-Path $dir3 $log3)
    $autoText3 = Read-TextOrEmpty $auto3
    $resolvedText3 = Read-TextOrEmpty (Join-Path $dir3 '~dependency_resolved.txt')
    $reqText3 = Read-TextOrEmpty (Join-Path $dir3 'requirements.txt')
    # The direct scan's own log holds the traceback. It is not copied to the setup log on this path,
    # because the old file is still populated, so the bootstrap falls through to the staging scan.
    $directLog3 = Read-TextOrEmpty (Join-Path $dir3 '~pipreqs_direct.log')
    $crashSeen3 = ($directLog3 -match 'Could not find a suitable TLS CA certificate bundle') -or ($setup3 -match 'Could not find a suitable TLS CA certificate bundle')
    $crashLine3 = @($directLog3 -split "`r?`n" | Where-Object { $_ -match 'Error' }) | Select-Object -Last 1
    $inPlace3 = -not (Test-UsedCopy $summary3 $setup3)
    $stillOld3 = Test-ReqLine $autoText3 'six'
    $resolvedHasSix3 = Test-ReqLine $resolvedText3 'six'
    $reqHasSix3 = Test-ReqLine $reqText3 'six'
    $phaseFailed3 = [regex]::IsMatch($summary3, '(?m)^Phase:\s+failed')
    $consoleWarns3 = @($console3 -split "`r?`n" | Where-Object { $_ -match '\[WARN\]' })
    $consoleNamesFile3 = @($consoleWarns3 | Where-Object { $_ -match 'requirements\.auto\.txt' }).Count -gt 0

    $crashPass = $lockHeld3 -and $crashSeen3 -and $inPlace3 -and $stillOld3 -and (-not $resolvedHasSix3) -and (-not $reqHasSix3) -and $phaseFailed3 -and $consoleNamesFile3
    Write-NdjsonRow ([ordered]@{
        id      = 'self.pipreqs.output.locked_crash'
        req     = 'REQ-005'
        pass    = $crashPass
        desc    = 'A locked old requirements.auto.txt is never installed when every scan crashes'
        details = [ordered]@{
            exitCode           = $exit3
            lockHeld           = $lockHeld3
            crashSeen          = $crashSeen3
            crashLine          = Get-Snippet ([string]$crashLine3) 200
            scannedInPlace     = $inPlace3
            oldFileUntouched   = $stillOld3
            resolvedHasOldDep  = $resolvedHasSix3
            requirementsHasOldDep = $reqHasSix3
            summaryPhaseFailed = $phaseFailed3
            consoleNamesFile   = $consoleNamesFile3
            summaryPhase       = Get-Snippet (([regex]::Match($summary3, '(?m)^Phase:.*$')).Value) 160
            consoleWarnCount   = $consoleWarns3.Count
            log                = $log3
        }
    })
} finally {
    if ($null -ne $lock3) { $lock3.Dispose() }
    if ($null -eq $prevCaBundle) { Remove-Item Env:REQUESTS_CA_BUNDLE -ErrorAction SilentlyContinue } else { $env:REQUESTS_CA_BUNDLE = $prevCaBundle }
    if ($null -ne $lock) { $lock.Dispose() }
    if ($null -eq $prevRunnerTemp) { Remove-Item Env:RUNNER_TEMP -ErrorAction SilentlyContinue } else { $env:RUNNER_TEMP = $prevRunnerTemp }
    # Only the folder private to this script is removed.
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if ($null -eq $prevSkipEntry) { Remove-Item Env:HP_SKIP_ENTRY_SMOKE -ErrorAction SilentlyContinue } else { $env:HP_SKIP_ENTRY_SMOKE = $prevSkipEntry }
    if ($null -eq $prevSkipExe) { Remove-Item Env:HP_SKIP_EXE_SMOKERUN -ErrorAction SilentlyContinue } else { $env:HP_SKIP_EXE_SMOKERUN = $prevSkipExe }
}

if (-not ($readonlyPass -and $tempPass -and $lockedPass -and $crashPass)) { exit 1 }
exit 0
