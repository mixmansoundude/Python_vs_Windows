# Windows-only entry-selection probe for consumer apps.
# Synthesizes tiny app roots and writes self.entry.* NDJSON rows
# (entry1/entryA to entryE, guard, fallback, fallback.guard, ignored). Runs unconditionally;
# HP_CI_SKIP_ENV=1 must be set so each scenario uses system Python instead of installing conda.
# Every row carries the README shall it proves as a literal tag (REQ-002.2, .10 to .13); the tag
# is passed to Write-EntryRow as a hashtable so the scan of tests/test_req_trace.py reads it.
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


$script:AnyRowFailed = $false
function Write-NdjsonRow {
    param([hashtable]$Row)

    if ($Row.ContainsKey('pass') -and -not $Row['pass']) { $script:AnyRowFailed = $true }
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
        req     = 'REQ-002'
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

    if ($LogText -match '''python" "~find_entry\.py'' is not recognized as an internal or external command') {
        Emit-FailureRow -Id 'helper.invoke' -Description 'Entry helper failed to execute under Python' -FilePath $LogPath -Pattern '''python" "~find_entry\.py'' is not recognized as an internal or external command' -LogText $LogText
        $script:RecordedHelperInvoke = $true
    } elseif (($LogText -match 'SyntaxError:') -and ($LogText -match '~find_entry\.py')) {
        Emit-FailureRow -Id 'helper.invoke' -Description 'Entry helper failed to execute under Python' -FilePath $LogPath -Pattern 'SyntaxError:' -LogText $LogText
        $script:RecordedHelperInvoke = $true
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
                $result.crumb = $match.Groups[1].Value.TrimEnd()
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
        [string]$Description,
        [hashtable]$Tag,
        [string]$RequireText = '',
        [string]$ForbidText = ''
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

    # RequireText and ForbidText are literal texts of the setup log and the console log: the
    # chosen file alone cannot tell the sole-guard rule from the alphabetical fallback, which
    # can name the same file, so the row also reads which of the two the batch file reported.
    $logs = [string]$Scenario.setupLog + "`n" + [string]$Scenario.bootstrapLog
    $sawRequired = $true
    if ($RequireText) { $sawRequired = $logs.Contains($RequireText) }
    $sawForbidden = $false
    if ($ForbidText) { $sawForbidden = $logs.Contains($ForbidText) }
    $details.sawRequired = $sawRequired
    $details.sawForbidden = $sawForbidden

    $pass = ($Scenario.exitCode -eq 0) -and ($chosen -eq $Expected) -and $sawRequired -and (-not $sawForbidden)

    Write-NdjsonRow ([ordered]@{
        id      = $Id
        req     = $Tag.req
        pass    = $pass
        desc    = $Description
        details = $details
    })
}

# Scenario 1: single entry file should breadcrumb correctly
$scenario1 = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry_sel1') -LogName '~entry_sel1_bootstrap.log' -Files ([ordered]@{
    'entry1.py' = @'
if __name__ == "__main__":
    print("from-entry1")
'@
})
$expected1 = 'entry1.py'
Write-EntryRow -Id 'self.entry.entry1' -Expected $expected1 -Scenario $scenario1 -Description 'Single entry file detected' -Tag @{ req = 'REQ-002.2' }
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
$expectedA = 'main.py'
Write-EntryRow -Id 'self.entry.entryA' -Expected $expectedA -Scenario $scenarioA -Description 'main.py beats app.py' -Tag @{ req = 'REQ-002.10' }
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
$expectedB = 'app.py'
Write-EntryRow -Id 'self.entry.entryB' -Expected $expectedB -Scenario $scenarioB -Description 'app.py preferred over generic modules' -Tag @{ req = 'REQ-002.10' }
Check-PipreqsFailure -LogPath $scenarioB.setupPath -LogText $scenarioB.setupLog
Check-HelperInvokeFailure -LogPath $scenarioB.bootstrapPath -LogText $scenarioB.bootstrapLog

# Scenario C: cli.py should win over a generic module name
$scenarioC = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry_cli') -LogName '~entry_cli_bootstrap.log' -Files ([ordered]@{
    'cli.py' = @'
if __name__ == "__main__":
    print("from-cli")
'@
    'bar.py' = @'
if __name__ == "__main__":
    print("from-generic")
'@
})
$expectedC = 'cli.py'
Write-EntryRow -Id 'self.entry.entryC' -Expected $expectedC -Scenario $scenarioC -Description 'cli.py preferred over generic modules (REQ-002)' -Tag @{ req = 'REQ-002.10' }
Check-PipreqsFailure -LogPath $scenarioC.setupPath -LogText $scenarioC.setupLog
Check-HelperInvokeFailure -LogPath $scenarioC.bootstrapPath -LogText $scenarioC.bootstrapLog

# Scenario D: run.py should win over cli.py (run.py precedes cli.py in PREFERRED order)
$scenarioD = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry_run') -LogName '~entry_run_bootstrap.log' -Files ([ordered]@{
    'run.py' = @'
if __name__ == "__main__":
    print("from-run")
'@
    'cli.py' = @'
if __name__ == "__main__":
    print("from-cli")
'@
})
$expectedD = 'run.py'
Write-EntryRow -Id 'self.entry.entryD' -Expected $expectedD -Scenario $scenarioD -Description 'run.py preferred over cli.py (REQ-002)' -Tag @{ req = 'REQ-002.10' }
Check-PipreqsFailure -LogPath $scenarioD.setupPath -LogText $scenarioD.setupLog
Check-HelperInvokeFailure -LogPath $scenarioD.bootstrapPath -LogText $scenarioD.bootstrapLog

# Scenario E (REQ-002.10): app.py comes before run.py. Scenarios A and D show main.py before
# app.py and run.py before cli.py; this is the pair that joins them into one order.
$scenarioE = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry_app_run') -LogName '~entry_app_run_bootstrap.log' -Files ([ordered]@{
    'run.py' = @'
if __name__ == "__main__":
    print("from-run")
'@
    'app.py' = @'
if __name__ == "__main__":
    print("from-app")
'@
})
$expectedE = 'app.py'
Write-EntryRow -Id 'self.entry.entryE' -Expected $expectedE -Scenario $scenarioE -Description 'app.py preferred over run.py (REQ-002.10)' -Tag @{ req = 'REQ-002.10' }
Check-PipreqsFailure -LogPath $scenarioE.setupPath -LogText $scenarioE.setupLog
Check-HelperInvokeFailure -LogPath $scenarioE.bootstrapPath -LogText $scenarioE.bootstrapLog

# Scenario F (REQ-002.11): none of the four names is present, one file has a substantive guard.
# The file that sorts first has a guard whose body is only pass, which does not count; if it did,
# two files would have a guard, no sole guard would exist and the alphabetical rule would take
# alpha_helper.py. So zeta.py, with no fallback line in the log, is the proof.
$scenarioF = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry_guard') -LogName '~entry_guard_bootstrap.log' -Files ([ordered]@{
    'alpha_helper.py' = @'
if __name__ == "__main__":
    pass
'@
    'mid.py' = @'
print("from-mid")
'@
    'zeta.py' = @'
if __name__ == "__main__":
    print("from-zeta")
'@
})
$expectedF = 'zeta.py'
Write-EntryRow -Id 'self.entry.guard' -Expected $expectedF -Scenario $scenarioF -Description 'The one file with a substantive main guard is the entry; a guard of only pass does not count (REQ-002.11)' -Tag @{ req = 'REQ-002.11' } -ForbidText 'No clear entry found'
Check-PipreqsFailure -LogPath $scenarioF.setupPath -LogText $scenarioF.setupLog
Check-HelperInvokeFailure -LogPath $scenarioF.bootstrapPath -LogText $scenarioF.bootstrapLog

# Scenario G1 (REQ-002.12): no name, no guard anywhere. The alphabetically first of all files runs
# and the fallback line names it.
$scenarioG1 = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry_fallback') -LogName '~entry_fallback_bootstrap.log' -Files ([ordered]@{
    'beta.py' = @'
print("from-beta")
'@
    'alpha.py' = @'
print("from-alpha")
'@
})
$expectedG1 = 'alpha.py'
Write-EntryRow -Id 'self.entry.fallback' -Expected $expectedG1 -Scenario $scenarioG1 -Description 'With no clear entry the alphabetically first file runs and the fallback is logged (REQ-002.12)' -Tag @{ req = 'REQ-002.12, REQ-002.18, REQ-002.25' } -RequireText "[BOOT] REQ-002: No clear entry found; selecting 'alpha.py' (alphabetical fallback)." -ForbidText 'Multiple Python files detected'
Check-PipreqsFailure -LogPath $scenarioG1.setupPath -LogText $scenarioG1.setupLog
Check-HelperInvokeFailure -LogPath $scenarioG1.bootstrapPath -LogText $scenarioG1.bootstrapLog

# Scenario G2 (REQ-002.12): two files have a substantive guard. The alphabetical rule is applied to
# those two only: alpha.py sorts first of all three files but has no guard, so beta.py is the entry.
$scenarioG2 = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry_fallback_guard') -LogName '~entry_fallback_guard_bootstrap.log' -Files ([ordered]@{
    'alpha.py' = @'
print("from-alpha")
'@
    'gamma.py' = @'
if __name__ == "__main__":
    print("from-gamma")
'@
    'beta.py' = @'
if __name__ == "__main__":
    print("from-beta")
'@
})
$expectedG2 = 'beta.py'
Write-EntryRow -Id 'self.entry.fallback.guard' -Expected $expectedG2 -Scenario $scenarioG2 -Description 'With two guarded files the alphabetically first of those runs, not the first of all files (REQ-002.12)' -Tag @{ req = 'REQ-002.12' } -RequireText "[BOOT] REQ-002: No clear entry found; selecting 'beta.py' (alphabetical fallback)."
Check-PipreqsFailure -LogPath $scenarioG2.setupPath -LogText $scenarioG2.setupLog
Check-HelperInvokeFailure -LogPath $scenarioG2.bootstrapPath -LogText $scenarioG2.bootstrapLog

# Scenario H (REQ-002.13): a file that starts with ~ or ._ is never a candidate. Both have a
# guard and sort before the others, so a candidate among them would be taken as the sole or the
# alphabetically first guarded file. Without them nothing has a guard and yyy.py is first of all.
$scenarioH = Invoke-EntryScenario -Root (Join-Path -Path $here -ChildPath '~entry_ignored') -LogName '~entry_ignored_bootstrap.log' -Files ([ordered]@{
    '~aaa.py' = @'
if __name__ == "__main__":
    print("from-tilde")
'@
    '._bbb.py' = @'
if __name__ == "__main__":
    print("from-appledouble")
'@
    'yyy.py' = @'
print("from-yyy")
'@
    'zzz.py' = @'
print("from-zzz")
'@
})
$expectedH = 'yyy.py'
Write-EntryRow -Id 'self.entry.ignored' -Expected $expectedH -Scenario $scenarioH -Description 'Files that start with a tilde or ._ are not candidates for the entry (REQ-002.13)' -Tag @{ req = 'REQ-002.13' } -RequireText "selecting 'yyy.py' (alphabetical fallback)."
Check-PipreqsFailure -LogPath $scenarioH.setupPath -LogText $scenarioH.setupLog
Check-HelperInvokeFailure -LogPath $scenarioH.bootstrapPath -LogText $scenarioH.bootstrapLog

# REQ-011/REQ-010 behavioral tests moved to tests/selfapps_isolation.ps1 (runs unconditionally).
# This file only covers REQ-002 entry-selection.

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
    @{ Id = 'self.entry.entryB'; Expected = $expectedB },
    @{ Id = 'self.entry.entryC'; Expected = $expectedC },
    @{ Id = 'self.entry.entryD'; Expected = $expectedD },
    @{ Id = 'self.entry.entryE'; Expected = $expectedE },
    @{ Id = 'self.entry.guard'; Expected = $expectedF },
    @{ Id = 'self.entry.fallback'; Expected = $expectedG1 },
    @{ Id = 'self.entry.fallback.guard'; Expected = $expectedG2 },
    @{ Id = 'self.entry.ignored'; Expected = $expectedH }
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

if ($script:AnyRowFailed) { exit 1 }
exit 0
