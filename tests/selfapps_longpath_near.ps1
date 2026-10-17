# ASCII only
# selfapps_longpath_near.ps1 - the long folder path warning at its real boundary (docs/plan-test-suite-gaps.md gap T9).
#
# run_setup.bat measures the length of its own folder path (with the closing backslash) and warns when it is 200
# characters or more, because paths near cmd.exe's 260-character limit fail in ways a beginner cannot read. The old
# row self.warn.longpath built a path over 260 characters, which a default runner cannot enter, so the row reported
# skip on every run and the warning was never seen in CI. This script stays under 260 and sits on both sides of the
# threshold, so the line itself is proven:
#   below  folder path with its closing backslash 199 characters: no warning, the run goes on
#   at     200 characters: the warning names 200 and the run goes on
#   over   215 characters: the warning names 215 and the run goes on
# "The run goes on" is shown by the program the bootstrapper started writing ~longpath_ran.txt and exit code 0.
#
# The run is the short system-Python path (HP_CI_SKIP_ENV=1, same as selfapps_isolation.ps1): the guard sits before
# provider selection, so a full provider run would only add minutes. The variable is set for the child only and
# restored afterwards. The scratch folders and their logs are long paths, so each run's two logs are copied to short
# names under tests\ for the artifact upload and the scratch folder is removed.
#
# derived requirement: ids stay literal at each Write-NdjsonRow call site (tools/check_ndjson_registry.py scans text,
# not PowerShell).
#
# Lane: real (gating from its first run, AGENTS.md "New tests gate immediately").
# Emits: self.longpath.near.below, self.longpath.near.at, self.longpath.near.over
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

$allIds = @('self.longpath.near.below', 'self.longpath.near.at', 'self.longpath.near.over')
if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; pass = $true; desc = 'Long folder path warning (skipped on non-Windows)'; details = [ordered]@{ skip = $true; reason = 'non-windows-host' } })
    }
    exit 0
}
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    foreach ($rowId in $allIds) {
        Write-NdjsonRow ([ordered]@{ id = $rowId; pass = $false; desc = 'Long folder path warning: run_setup.bat not found'; details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath } })
    }
    exit 1
}

$expectedExit = 5   # planted wrong on purpose in the red commit; the bootstrapper exits 0 on this path

# Runs the bootstrapper from a scratch folder whose path, including the closing backslash the bootstrapper adds, is
# exactly $RootLength characters. Returns what the row needs; never throws.
function Invoke-LongPathRun {
    param([string]$Tag, [int]$RootLength)
    $out = [ordered]@{
        built = $false; rootLength = -1; exitCode = -1; ranMarker = $false
        warnInConsole = $false; warnInLog = $false; warnedLengthConsole = $null; warnedLengthLog = $null; error = $null
    }
    $base = Join-Path $here ('~selftest_longpath_' + $Tag)
    try {
        if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        # base + '\' + pad, then the closing backslash: base.Length + 1 + pad.Length + 1 = RootLength
        $padLen = $RootLength - $base.Length - 2
        if ($padLen -lt 8) { $out.error = "base path too long for $RootLength ($($base.Length))"; return $out }
        $dir = Join-Path $base ('pad_' + ('p' * ($padLen - 4)))
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $out.rootLength = ([System.IO.Path]::GetFullPath($dir)).Length + 1
        $out.built = ($out.rootLength -eq $RootLength)
        Copy-Item -LiteralPath $batchPath -Destination $dir -Force
        Set-Content -LiteralPath (Join-Path $dir 'longpath_app.py') -Value "open('~longpath_ran.txt', 'w').write('ran')" -Encoding ASCII
        $had = [Environment]::GetEnvironmentVariable('HP_CI_SKIP_ENV')
        [Environment]::SetEnvironmentVariable('HP_CI_SKIP_ENV', '1')
        Push-Location -LiteralPath $dir
        try {
            & cmd.exe /c '.\run_setup.bat longpath_app.py > ~lp_boot.log 2>&1 < nul'
            $out.exitCode = $LASTEXITCODE
        } finally {
            Pop-Location
            [Environment]::SetEnvironmentVariable('HP_CI_SKIP_ENV', $had)
        }
        $out.ranMarker = Test-Path -LiteralPath (Join-Path $dir '~longpath_ran.txt')
        $console = ''
        $bootLog = Join-Path $dir '~lp_boot.log'
        if (Test-Path -LiteralPath $bootLog) { $console = Get-Content -LiteralPath $bootLog -Raw -Encoding ASCII }
        $setupLog = ''
        $setupPath = Join-Path $dir '~setup.log'
        if (Test-Path -LiteralPath $setupPath) { $setupLog = Get-Content -LiteralPath $setupPath -Raw -Encoding ASCII }
        $mc = [regex]::Match($console, 'Script path is (\d+) chars')
        $ml = [regex]::Match($setupLog, '\[WARN\] Script path is (\d+) chars')
        $out.warnInConsole = $mc.Success
        $out.warnInLog = $ml.Success
        if ($mc.Success) { $out.warnedLengthConsole = [int]$mc.Groups[1].Value }
        if ($ml.Success) { $out.warnedLengthLog = [int]$ml.Groups[1].Value }
        # short copies for the artifact upload, then drop the long scratch path
        if ($console) { Set-Content -LiteralPath (Join-Path $here ('~longpath_near_' + $Tag + '.boot.log')) -Value $console -Encoding ASCII }
        if ($setupLog) { Set-Content -LiteralPath (Join-Path $here ('~longpath_near_' + $Tag + '.setup.log')) -Value $setupLog -Encoding ASCII }
    } catch {
        $out.error = $_.Exception.Message
    } finally {
        if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force -ErrorAction SilentlyContinue }
    }
    return $out
}

$passBelow = $false
$passAt = $false
$passOver = $false

# ---------------------------------------------------------------- below the threshold: 199 characters
$r = Invoke-LongPathRun -Tag 'below' -RootLength 199
$passBelow = $r.built -and ($r.exitCode -eq $expectedExit) -and $r.ranMarker -and (-not $r.warnInConsole) -and (-not $r.warnInLog)
Write-NdjsonRow ([ordered]@{
    id = 'self.longpath.near.below'; req = 'REQ-003.5'; pass = [bool]$passBelow
    desc = 'README REQ-003.5: a folder path of 199 characters (with its closing backslash) starts the run without the long path warning'
    details = $r
})

# ---------------------------------------------------------------- at the threshold: 200 characters
$r = Invoke-LongPathRun -Tag 'at' -RootLength 200
$passAt = $r.built -and ($r.exitCode -eq $expectedExit) -and $r.ranMarker -and $r.warnInConsole -and $r.warnInLog -and ($r.warnedLengthConsole -eq 200) -and ($r.warnedLengthLog -eq 200)
Write-NdjsonRow ([ordered]@{
    id = 'self.longpath.near.at'; req = 'REQ-003.5'; pass = [bool]$passAt
    desc = 'README REQ-003.5: a folder path of 200 characters prints and logs the long path warning naming 200, then the run goes on'
    details = $r
})

# ---------------------------------------------------------------- over the threshold: 215 characters
$r = Invoke-LongPathRun -Tag 'over' -RootLength 215
$passOver = $r.built -and ($r.exitCode -eq $expectedExit) -and $r.ranMarker -and $r.warnInConsole -and $r.warnInLog -and ($r.warnedLengthConsole -eq 215) -and ($r.warnedLengthLog -eq 215)
Write-NdjsonRow ([ordered]@{
    id = 'self.longpath.near.over'; req = 'REQ-003.5'; pass = [bool]$passOver
    desc = 'README REQ-003.5: a folder path of 215 characters prints and logs the long path warning naming 215, then the run goes on'
    details = $r
})

if (-not ($passBelow -and $passAt -and $passOver)) { exit 1 }
exit 0
