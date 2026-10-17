# ASCII only
# selfapps_runtests_contract.ps1 - what run_tests.bat promises about the self-test section (CLAUDE.md Item 84).
#
# run_tests.bat runs the static harness and then the two self-test scripts. It used to run them only when
# the harness exited 0, so one red harness row removed every selftest.ps1 and selftests.ps1 row from the run.
# An absent row cannot be red, so a real regression in a self-test scenario stayed invisible until the harness
# was green again (and a red-first self-test row could not be shown red while any harness row was red).
#
# This test runs a COPY of the real run_tests.bat against stub harness.ps1 / selftest.ps1 / selftests.ps1
# scripts whose exit codes and summary files the scenario chooses, then reads the stubs' marker files and the
# batch's exit code:
#   all_green              every stub passes: exit 0, both self-test stubs ran.
#   harness_red            the harness stub exits 1: the batch still exits 1, AND both self-test stubs ran.
#   selftest_red           selftest.ps1 stub exits 1: the batch exits 1 and selftests.ps1 still ran.
#   selftest_unreported    selftest.ps1 stub exits 0 but writes no tests\~selftest-summary.txt (an older copy of
#                          that file is lying there): the section did not complete, so the batch exits 1 and says so.
#   selftests_unreported   the same for selftests.ps1 and tests\~selftests-summary.txt.
#
# The stubs make the scenarios deterministic and fast (a few seconds in total), so the test runs in every lane
# and gates from its first run (AGENTS.md, "New tests gate immediately").
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text).
#
# Emits: self.runtests.all_green, self.runtests.harness_red, self.runtests.selftest_red,
#        self.runtests.selftest_unreported, self.runtests.selftests_unreported
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

$runTestsSrc = Join-Path $repo 'run_tests.bat'
$root = Join-Path $here '~runtests_contract'
if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $root | Out-Null

# One stub script: it records that it ran, optionally writes its summary file, and exits with the chosen code.
function New-StubScript {
    param([string]$Path, [string]$Marker, [string]$SummaryName, [bool]$WriteSummary, [int]$ExitCode)
    $lines = @('param()', "Set-Content -LiteralPath (Join-Path `$PSScriptRoot '$Marker') -Value 'ran' -Encoding Ascii")
    if ($SummaryName -and $WriteSummary) {
        $lines += "Set-Content -LiteralPath (Join-Path `$PSScriptRoot '$SummaryName') -Value 'stub summary' -Encoding Ascii"
    }
    $lines += "exit $ExitCode"
    Set-Content -LiteralPath $Path -Value $lines -Encoding Ascii
}

function Invoke-RunTestsScenario {
    param(
        [string]$Name,
        [int]$HarnessExit,
        [int]$SelftestExit, [bool]$SelftestSummary,
        [int]$SelftestsExit, [bool]$SelftestsSummary,
        [bool]$StaleSummaries
    )
    $dir = Join-Path $root $Name
    $tdir = Join-Path $dir 'tests'
    New-Item -ItemType Directory -Force -Path $tdir | Out-Null
    Copy-Item -LiteralPath $runTestsSrc -Destination (Join-Path $dir 'run_tests.bat') -Force
    New-StubScript -Path (Join-Path $tdir 'harness.ps1')   -Marker '~stub_harness_ran.txt'   -SummaryName '~test-summary.txt'      -WriteSummary $true              -ExitCode $HarnessExit
    New-StubScript -Path (Join-Path $tdir 'selftest.ps1')  -Marker '~stub_selftest_ran.txt'  -SummaryName '~selftest-summary.txt'  -WriteSummary $SelftestSummary  -ExitCode $SelftestExit
    New-StubScript -Path (Join-Path $tdir 'selftests.ps1') -Marker '~stub_selftests_ran.txt' -SummaryName '~selftests-summary.txt' -WriteSummary $SelftestsSummary -ExitCode $SelftestsExit
    if ($StaleSummaries) {
        # An older run left these behind; a section that never reported must not be vouched for by them.
        Set-Content -LiteralPath (Join-Path $tdir '~selftest-summary.txt')  -Value 'stale summary from an earlier run' -Encoding Ascii
        Set-Content -LiteralPath (Join-Path $tdir '~selftests-summary.txt') -Value 'stale summary from an earlier run' -Encoding Ascii
    }
    $outFile = Join-Path $dir '~rt_out.txt'
    # derived requirement: redirect inside the cmd string, never with PowerShell *> (cmd would get a literal *).
    Push-Location -LiteralPath $dir
    try {
        & cmd /c "call run_tests.bat > ~rt_out.txt 2>&1"
        $exit = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    $outText = if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Raw } else { '' }
    if ($null -eq $outText) { $outText = '' }
    $tail = @(if (Test-Path -LiteralPath $outFile) { Get-Content -LiteralPath $outFile -Tail 12 } else { @() })
    return [ordered]@{
        exitCode      = $exit
        harnessRan    = (Test-Path -LiteralPath (Join-Path $tdir '~stub_harness_ran.txt'))
        selftestRan   = (Test-Path -LiteralPath (Join-Path $tdir '~stub_selftest_ran.txt'))
        selftestsRan  = (Test-Path -LiteralPath (Join-Path $tdir '~stub_selftests_ran.txt'))
        reportsMissingSelftest  = ($outText -match 'did not complete') -and ($outText -match [regex]::Escape('~selftest-summary.txt'))
        reportsMissingSelftests = ($outText -match 'did not complete') -and ($outText -match [regex]::Escape('~selftests-summary.txt'))
        outputTail    = $tail
    }
}

if (-not (Test-Path -LiteralPath $runTestsSrc)) {
    foreach ($id in @('self.runtests.all_green', 'self.runtests.harness_red', 'self.runtests.selftest_red', 'self.runtests.selftest_unreported', 'self.runtests.selftests_unreported')) {
        Write-NdjsonRow ([ordered]@{ id = $id; pass = $false; desc = 'run_tests.bat contract: run_tests.bat not found'; details = [ordered]@{ path = $runTestsSrc } })
    }
    return
}

# --- all_green -------------------------------------------------------------------------------------------
$g = Invoke-RunTestsScenario -Name 'all_green' -HarnessExit 0 -SelftestExit 0 -SelftestSummary $true -SelftestsExit 0 -SelftestsSummary $true -StaleSummaries $false
$gPass = ($g.exitCode -eq 0) -and $g.harnessRan -and $g.selftestRan -and $g.selftestsRan
Write-NdjsonRow ([ordered]@{
    id = 'self.runtests.all_green'; pass = [bool]$gPass
    desc = 'run_tests.bat contract: harness, selftest.ps1 and selftests.ps1 all pass -> exit 0 and both self-test scripts ran'
    details = [ordered]@{ exitCode = $g.exitCode; expectedExit = 0; harnessRan = $g.harnessRan; selftestRan = $g.selftestRan; selftestsRan = $g.selftestsRan }
})

# --- harness_red -----------------------------------------------------------------------------------------
$h = Invoke-RunTestsScenario -Name 'harness_red' -HarnessExit 1 -SelftestExit 0 -SelftestSummary $true -SelftestsExit 0 -SelftestsSummary $true -StaleSummaries $false
$hPass = ($h.exitCode -eq 1) -and $h.harnessRan -and $h.selftestRan -and $h.selftestsRan
Write-NdjsonRow ([ordered]@{
    id = 'self.runtests.harness_red'; pass = [bool]$hPass
    desc = 'run_tests.bat contract: a red harness still runs selftest.ps1 and selftests.ps1 (their rows must not vanish) and the exit stays 1'
    details = [ordered]@{ exitCode = $h.exitCode; expectedExit = 1; harnessRan = $h.harnessRan; selftestRan = $h.selftestRan; selftestsRan = $h.selftestsRan; outputTail = $h.outputTail }
})

# --- selftest_red ----------------------------------------------------------------------------------------
$s = Invoke-RunTestsScenario -Name 'selftest_red' -HarnessExit 0 -SelftestExit 1 -SelftestSummary $true -SelftestsExit 0 -SelftestsSummary $true -StaleSummaries $false
$sPass = ($s.exitCode -eq 1) -and $s.selftestRan -and $s.selftestsRan
Write-NdjsonRow ([ordered]@{
    id = 'self.runtests.selftest_red'; pass = [bool]$sPass
    desc = 'run_tests.bat contract: a red selftest.ps1 keeps the exit at 1 and selftests.ps1 still runs'
    details = [ordered]@{ exitCode = $s.exitCode; expectedExit = 1; selftestRan = $s.selftestRan; selftestsRan = $s.selftestsRan }
})

# --- selftest_unreported ---------------------------------------------------------------------------------
$u = Invoke-RunTestsScenario -Name 'selftest_unreported' -HarnessExit 0 -SelftestExit 0 -SelftestSummary $false -SelftestsExit 0 -SelftestsSummary $true -StaleSummaries $true
$uPass = ($u.exitCode -eq 1) -and $u.selftestRan -and $u.selftestsRan -and $u.reportsMissingSelftest
Write-NdjsonRow ([ordered]@{
    id = 'self.runtests.selftest_unreported'; pass = [bool]$uPass
    desc = 'run_tests.bat contract: a selftest.ps1 that exits 0 without writing its summary did not complete -> exit 1 and the console says so, even with an older summary lying there'
    details = [ordered]@{ exitCode = $u.exitCode; expectedExit = 1; selftestRan = $u.selftestRan; selftestsRan = $u.selftestsRan; reportsMissing = $u.reportsMissingSelftest; outputTail = $u.outputTail }
})

# --- selftests_unreported --------------------------------------------------------------------------------
$v = Invoke-RunTestsScenario -Name 'selftests_unreported' -HarnessExit 0 -SelftestExit 0 -SelftestSummary $true -SelftestsExit 0 -SelftestsSummary $false -StaleSummaries $true
$vPass = ($v.exitCode -eq 1) -and $v.selftestRan -and $v.selftestsRan -and $v.reportsMissingSelftests
Write-NdjsonRow ([ordered]@{
    id = 'self.runtests.selftests_unreported'; pass = [bool]$vPass
    desc = 'run_tests.bat contract: a selftests.ps1 that exits 0 without writing its summary did not complete -> exit 1 and the console says so, even with an older summary lying there'
    details = [ordered]@{ exitCode = $v.exitCode; expectedExit = 1; selftestRan = $v.selftestRan; selftestsRan = $v.selftestsRan; reportsMissing = $v.reportsMissingSelftests; outputTail = $v.outputTail }
})

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
