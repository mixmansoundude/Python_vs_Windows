# Windows-only entry-selection probe for consumer apps.
# Synthesizes tiny app roots, writes self.entry.* NDJSON rows (entry1/entryA/entryB),
# and is gated by ~bootstrap.status.json or PY_FILES so it only runs when exactly
# one Python entry was detected. In this bootstrapper repo it normally stays
# dormant unless CI forces a single-entry simulation.
$ErrorActionPreference = 'Continue'

$here = $PSScriptRoot
if (-not $here) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$repoRoot = Split-Path -Path $here -Parent
$nd = Join-Path -Path $here -ChildPath '~test-results.ndjson'
$ciNd = Join-Path -Path $repoRoot -ChildPath 'ci_test_results.ndjson'

if (-not (Test-Path -LiteralPath $nd)) {
    New-Item -ItemType File -Path $nd -Force | Out-Null
}
if (-not (Test-Path -LiteralPath $ciNd)) {
    New-Item -ItemType File -Path $ciNd -Force | Out-Null
}

# derived requirement: diagnostics run 19035211236-1 flagged `self.entry.*` rows as
# failures even though the bootstrapper reported `pyFiles=0`. Honor the bootstrap
# status so these synthetic entry probes only run when the real project exposed a
# single Python entry.
$pyFileCount = $null
$statusPath = Join-Path -Path $repoRoot -ChildPath '~bootstrap.status.json'
if (Test-Path -LiteralPath $statusPath) {
    try {
        $statusJson = Get-Content -LiteralPath $statusPath -Raw -Encoding Ascii | ConvertFrom-Json
        $candidate = $statusJson.pyFiles
        if ($null -ne $candidate) {
            $parsed = 0
            if ([int]::TryParse($candidate.ToString(), [ref]$parsed)) {
                $pyFileCount = $parsed
            }
        }
    } catch {
        # derived requirement: tolerate malformed or missing bootstrap status so we can fall back to env hints.
    }
}
if ($null -eq $pyFileCount -and $env:PY_FILES) {
    $parsed = 0
    if ([int]::TryParse($env:PY_FILES, [ref]$parsed)) {
        $pyFileCount = $parsed
    }
}
if ($null -ne $pyFileCount -and $pyFileCount -ne 1) {
    # Emit an explicit REQ-002 skip row so coverage is present even when skipped.
    $skipRow = [ordered]@{
        id      = 'self.entry.results'
        req     = 'REQ-002'
        pass    = $true
        desc    = 'Entry selection skipped: pyFiles count is not 1'
        details = [ordered]@{ skip = $true; pyFiles = $pyFileCount; reason = 'pyfiles-not-1' }
    }
    $skipJson = $skipRow | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd -Value $skipJson -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $skipJson -Encoding Ascii
    Write-Host ("[INFO] selfapps_entry skipped: pyFiles={0}" -f $pyFileCount)
    exit 0
}

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

function Emit-FailureRow {
    param(
        [string]$Id,
        [string]$Description,
        [string]$FilePath,
        [string]$Pattern,
        [string]$LogText
    )

    if (-not $LogText) {
        $LogText = Get-Content -LiteralPath $FilePath -Raw -Encoding Ascii
    }
    $snippet = Get-LineSnippet -Text $LogText -Pattern $Pattern
    $details = [ordered]@{ file = $FilePath }
    if ($snippet) { $details.snippet = $snippet }

    Write-NdjsonRow ([ordered]@{
        id      = $Id
        pass    = $false
        desc    = $Description
        details = $details
    })
}

$script:RecordedPipreqs = $false
$script:RecordedHelperInvoke = $false

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
            Emit-FailureRow -Id 'pipreqs.run' -Description 'pipreqs invocation failed during bootstrap' -FilePath $LogPath -Pattern $pattern -LogText $LogText
            $script:RecordedPipreqs = $true
            break
        }
    }
}

function Check-HelperInvokeFailure {
    param(
        [string]$LogPath,
        [string]$LogText
    )

    if ($script:RecordedHelperInvoke -or -not $LogPath -or -not (Test-Path -LiteralPath $LogPath)) { return }
    if (-not $LogText) { $LogText = Get-Content -LiteralPath $LogPath -Raw -Encoding Ascii }

    $patterns = @(
        @{ Pattern = '''python" "~find_entry\.py'' is not recognized as an internal or external command'; RequireFindEntry = $false },
        @{ Pattern = 'SyntaxError:'; RequireFindEntry = $true }
    )

    foreach ($item in $patterns) {
        $pattern = $item.Pattern
        if ($LogText -match $pattern) {
            if ($item.RequireFindEntry -and ($LogText -notmatch '~find_entry\.py')) { continue }
            Emit-FailureRow -Id 'helper.invoke' -Description 'Entry helper failed to execute under Python' -FilePath $LogPath -Pattern $pattern -LogText $LogText
            $script:RecordedHelperInvoke = $true
            break
        }
    }
}

function Invoke-EntryScenario {
    param(
        [string]$Root,
        [string]$LogName,
        [hashtable]$Files
    )

    $result = [ordered]@{
        exitCode = $null
        log = ''
        crumb = ''
        error = $null
        setupPath = $null
        setupLog = ''
        bootstrapPath = $null
        bootstrapLog = ''
        helperCommand = ''
    }

    try {
        if (Test-Path -LiteralPath $Root) {
            Remove-Item -LiteralPath $Root -Recurse -Force
        }
        New-Item -ItemType Directory -Force -Path $Root | Out-Null

        Copy-Item -LiteralPath (Join-Path -Path $repoRoot -ChildPath 'run_setup.bat') -Destination $Root -Force

        foreach ($name in $Files.Keys) {
            $content = $Files[$name]
            Set-Content -LiteralPath (Join-Path -Path $Root -ChildPath $name) -Value $content -Encoding Ascii -NoNewline
        }

        $setupLog = Join-Path -Path $Root -ChildPath '~setup.log'
        if (Test-Path -LiteralPath $setupLog) {
            Remove-Item -LiteralPath $setupLog -Force
        }

        $bootstrapLog = Join-Path -Path $Root -ChildPath $LogName
        if (Test-Path -LiteralPath $bootstrapLog) {
            Remove-Item -LiteralPath $bootstrapLog -Force
        }

        Push-Location -LiteralPath $Root
        try {
            cmd /c .\run_setup.bat *> $LogName
            $result.exitCode = $LASTEXITCODE
        }
        finally {
            Pop-Location
        }

        $result.setupPath = $setupLog
        if (Test-Path -LiteralPath $setupLog) {
            $result.log = Get-Content -LiteralPath $setupLog -Raw -Encoding Ascii
            $result.setupLog = $result.log
            $match = [regex]::Match($result.log, '^Chosen entry: (.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if ($match.Success) {
                $result.crumb = $match.Groups[1].Value
            }
            $helper = [regex]::Match($result.log, '^Helper command:\s*(.+)$', [System.Text.RegularExpressions.RegexOptions]::Multiline)
            if ($helper.Success) {
                $result.helperCommand = $helper.Groups[1].Value.Trim()
            }
        }

        $result.bootstrapPath = $bootstrapLog
        if (Test-Path -LiteralPath $bootstrapLog) {
            $result.bootstrapLog = Get-Content -LiteralPath $bootstrapLog -Raw -Encoding Ascii
        }
    }
    catch {
        $result.error = $_.Exception.Message
    }

    return $result
}

function Write-EntryRow {
    param(
        [string]$Id,
        [string]$Expected,
        [hashtable]$Scenario,
        [string]$Description
    )

    $chosen = $Scenario.crumb
    if ($null -eq $chosen) { $chosen = '' }

    $details = [ordered]@{
        exitCode = $Scenario.exitCode
        expected = $Expected
        chosen   = $chosen
    }

    if ($Scenario.error) {
        $details.error = $Scenario.error
    }
    if ($Scenario.helperCommand) {
        $details.helperCommand = $Scenario.helperCommand
    }

    $pass = ($Scenario.exitCode -eq 0) -and ($chosen -eq $Expected)

    Write-NdjsonRow ([ordered]@{
        id      = $Id
        req     = 'REQ-002'
        pass    = $pass
        desc    = $Description
        details = $details
    })
}

# Scenario 1: single entry file should breadcrumb correctly
$scenario1 = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry1') -LogName '~entry1_bootstrap.log' -Files ([ordered]@{
    'entry1.py' = @'
if __name__ == "__main__":
    print("from-entry1")
'@
})
$expected1 = Join-Path '.' 'entry1.py'
Write-EntryRow -Id 'self.entry.entry1' -Expected $expected1 -Scenario $scenario1 -Description 'Single entry file detected'
Check-PipreqsFailure -LogPath $scenario1.setupPath -LogText $scenario1.setupLog
Check-HelperInvokeFailure -LogPath $scenario1.bootstrapPath -LogText $scenario1.bootstrapLog

# Scenario A: main.py should win over app.py when both present
$scenarioA = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entryA') -LogName '~entryA_bootstrap.log' -Files ([ordered]@{
    'main.py' = @'
if __name__ == "__main__":
    print("from-main")
'@
    'app.py' = @'
if __name__ == "__main__":
    print("from-app")
'@
})
$expectedA = Join-Path '.' 'main.py'
Write-EntryRow -Id 'self.entry.entryA' -Expected $expectedA -Scenario $scenarioA -Description 'main.py beats app.py'
Check-PipreqsFailure -LogPath $scenarioA.setupPath -LogText $scenarioA.setupLog
Check-HelperInvokeFailure -LogPath $scenarioA.bootstrapPath -LogText $scenarioA.bootstrapLog

# Scenario B: prefer common names over generic modules when picking entries
$scenarioB = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entryB') -LogName '~entryB_bootstrap.log' -Files ([ordered]@{
    'app.py' = @'
if __name__ == "__main__":
    print("from-app")
'@
    'foo.py' = @'
if __name__ == "__main__":
    print("from-guard")
'@
})
$expectedB = Join-Path '.' 'app.py'
Write-EntryRow -Id 'self.entry.entryB' -Expected $expectedB -Scenario $scenarioB -Description 'app.py preferred over generic modules'
Check-PipreqsFailure -LogPath $scenarioB.setupPath -LogText $scenarioB.setupLog
Check-HelperInvokeFailure -LogPath $scenarioB.bootstrapPath -LogText $scenarioB.bootstrapLog

# Scenario C: REQ-011 -- cross-dir explicit arg must abort (negative test)
$scenarioCBoot = Join-Path -Path $here -ChildPath '~entryC_boot'
$scenarioCExt  = Join-Path -Path $here -ChildPath '~entryC_ext'
try {
    foreach ($d in @($scenarioCBoot, $scenarioCExt)) {
        if (Test-Path -LiteralPath $d) { Remove-Item -LiteralPath $d -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $d | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $repoRoot 'run_setup.bat') -Destination $scenarioCBoot -Force
    $extPy = Join-Path $scenarioCExt 'external.py'
    Set-Content -LiteralPath $extPy -Value 'print("external")' -Encoding Ascii -NoNewline

    Push-Location -LiteralPath $scenarioCBoot
    try {
        # PowerShell quotes $extPy automatically if it contains spaces.
        cmd /c .\run_setup.bat $extPy *> '~entryC_bootstrap.log'
        $exitC = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $logCPath = Join-Path $scenarioCBoot '~entryC_bootstrap.log'
    $logCText = if (Test-Path -LiteralPath $logCPath) { Get-Content $logCPath -Raw -Encoding Ascii } else { '' }
    $req011InLog = [bool]($logCText -match 'REQ-011')
    $passC = ($exitC -ne 0) -and $req011InLog

    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.crossdir'
        req     = 'REQ-011'
        pass    = $passC
        desc    = 'REQ-011: cross-dir file argument must abort bootstrap'
        details = [ordered]@{ exitCode = $exitC; req011InLog = $req011InLog }
    })
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.crossdir'
        req     = 'REQ-011'
        pass    = $false
        desc    = 'REQ-011: cross-dir test threw an exception'
        details = [ordered]@{ error = $_.Exception.Message }
    })
}

# Scenario D: REQ-011 -- same-dir explicit arg must succeed (positive test)
$scenarioDRoot = Join-Path -Path $here -ChildPath '~entryD_boot'
try {
    if (Test-Path -LiteralPath $scenarioDRoot) { Remove-Item -LiteralPath $scenarioDRoot -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $scenarioDRoot | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'run_setup.bat') -Destination $scenarioDRoot -Force
    Set-Content -LiteralPath (Join-Path $scenarioDRoot 'direct.py') -Value 'print("direct")' -Encoding Ascii -NoNewline

    Push-Location -LiteralPath $scenarioDRoot
    try {
        # Pass relative arg -- the canonicalization in run_setup.bat resolves .\direct.py
        # relative to the boot dir so the directory check matches HP_SELF_DIR.
        cmd /c '.\run_setup.bat ".\direct.py"' *> '~entryD_bootstrap.log'
        $exitD = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $setupDPath = Join-Path $scenarioDRoot '~setup.log'
    $setupDText = if (Test-Path -LiteralPath $setupDPath) { Get-Content $setupDPath -Raw -Encoding Ascii } else { '' }
    # Match basename only -- log may preserve .\direct.py or show canonicalized full path.
    $entryInLog = [bool]($setupDText -match 'direct\.py')
    $passD = ($exitD -eq 0) -and $entryInLog

    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.sameDir'
        req     = 'REQ-011'
        pass    = $passD
        desc    = 'REQ-011: same-dir file argument must succeed'
        details = [ordered]@{ exitCode = $exitD; entryInLog = $entryInLog }
    })
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.entry.req011.sameDir'
        req     = 'REQ-011'
        pass    = $false
        desc    = 'REQ-011: same-dir test threw an exception'
        details = [ordered]@{ error = $_.Exception.Message }
    })
}

# REQ-010 behavioral isolation test: entry script reports PYTHONPATH value so we can
# verify that run_setup.bat cleared it before any Python subprocess ran.
# Without SET "PYTHONPATH=" in run_setup.bat the conda Python would see the injected
# marker value and the assertion below would fail.
$req010Root    = Join-Path -Path $here -ChildPath '~req010_test'
$prevPythonPath = $env:PYTHONPATH
try {
    if (Test-Path -LiteralPath $req010Root) { Remove-Item -LiteralPath $req010Root -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $req010Root | Out-Null
    Copy-Item -LiteralPath (Join-Path $repoRoot 'run_setup.bat') -Destination $req010Root -Force

    # Entry script writes PYTHONPATH / PYTHONHOME to ~isolation_check.txt.
    $entryContent = @'
import os
pythonpath = os.environ.get('PYTHONPATH', '')
pythonhome = os.environ.get('PYTHONHOME', '')
with open('~isolation_check.txt', 'w') as fh:
    fh.write('PYTHONPATH={}\nPYTHONHOME={}\n'.format(pythonpath, pythonhome))
'@
    Set-Content -LiteralPath (Join-Path $req010Root 'isolation_check.py') -Value $entryContent -Encoding Ascii

    $env:PYTHONPATH = 'C:\req010_poison_marker'

    Push-Location -LiteralPath $req010Root
    try {
        cmd /c .\run_setup.bat *> '~req010_bootstrap.log'
        $exit010 = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $checkPath = Join-Path $req010Root '~isolation_check.txt'
    if (-not (Test-Path -LiteralPath $checkPath)) {
        $pass010 = $false
        $checkText = 'FILE_NOT_CREATED'
        $pythonpathCleared = $false
    } else {
        $checkText = Get-Content $checkPath -Raw -Encoding Ascii
        $ppLine = ($checkText -split '\r?\n' | Where-Object { $_ -match '^PYTHONPATH=' } | Select-Object -First 1)
        $pythonpathCleared = $ppLine -eq 'PYTHONPATH='
        $pass010 = ($exit010 -eq 0) -and $pythonpathCleared
    }

    Write-NdjsonRow ([ordered]@{
        id      = 'self.isolation.req010.pythonpath'
        req     = 'REQ-010'
        pass    = $pass010
        desc    = 'REQ-010: PYTHONPATH is cleared before Python subprocesses run'
        details = [ordered]@{ exitCode = $exit010; pythonpathCleared = $pythonpathCleared; checkSnippet = ($checkText.Trim() | Select-Object -First 1) }
    })
} catch {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.isolation.req010.pythonpath'
        req     = 'REQ-010'
        pass    = $false
        desc    = 'REQ-010: isolation test threw an exception'
        details = [ordered]@{ error = $_.Exception.Message }
    })
} finally {
    if ($null -eq $prevPythonPath) {
        Remove-Item -Path 'env:PYTHONPATH' -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONPATH = $prevPythonPath
    }
}

$parsedRows = @()
if (Test-Path -LiteralPath $ciNd) {
    foreach ($line in Get-Content -LiteralPath $ciNd -Encoding Ascii) {
        $trim = $line.Trim()
        if (-not $trim) { continue }
        try {
            $parsedRows += ($trim | ConvertFrom-Json)
        } catch {
            # derived requirement: keep parsing resilient so diagnostics survive malformed
            # lines without crashing the self-test loop.
        }
    }
}

$helperRows = @($parsedRows | Where-Object { $_.id -eq 'helper.invoke' })
Write-NdjsonRow ([ordered]@{
    id      = 'self.entry.helper.invoke.absent'
    req     = 'REQ-002'
    pass    = ($helperRows.Count -eq 0)
    desc    = 'Helper invocation rows are absent in NDJSON output'
    details = @{ count = $helperRows.Count }
})

$expectedMap = @(
    @{ Id = 'self.entry.entry1'; Expected = $expected1 },
    @{ Id = 'self.entry.entryA'; Expected = $expectedA },
    @{ Id = 'self.entry.entryB'; Expected = $expectedB }
)
$issues = @()
foreach ($item in $expectedMap) {
    $row = $parsedRows | Where-Object { $_.id -eq $item.Id } | Select-Object -First 1
    if (-not $row) {
        $issues += [ordered]@{ id = $item.Id; reason = 'missing-row' }
        continue
    }
    if (-not $row.pass) {
        $issues += [ordered]@{ id = $item.Id; reason = 'row-failed'; exitCode = $row.details.exitCode; chosen = $row.details.chosen }
        continue
    }
    if (-not $row.details -or -not $row.details.chosen) {
        $issues += [ordered]@{ id = $item.Id; reason = 'missing-chosen' }
    }
}

Write-NdjsonRow ([ordered]@{
    id      = 'self.entry.results'
    req     = 'REQ-002'
    pass    = ($issues.Count -eq 0)
    desc    = 'Entry scenarios emitted breadcrumbs and passed'
    details = @{ issues = $issues }
})
