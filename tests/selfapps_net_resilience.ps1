# ASCII only
# selfapps_net_resilience.ps1 - Item 112: README REQ-013 (network resilience) shown with real downloads and real
# probes, not with a forced hook.
#
# What was missing (docs/plan-test-suite-gaps.md, REQ-013 gaps): the retry of a failed download (--retry 3), the
# PowerShell second method, the check of whether the internet is reachable before the secondary URL, the repeat of each
# reachability probe, the skip lines of offline mode for Miniconda and get-pip.py, the second download after a checksum
# or extraction failure of the embedded Python, and the replacement of the embedded Python folder tried again. Every
# one of them is behavior of a few lines inside run_setup.bat that a real network failure triggers and the existing rows
# only reach by a forced hook.
#
# How: the REAL code blocks are cut out of run_setup.bat (the technique of selfapps_conda_transient.ps1), wrapped in a
# tiny driver batch file and run by cmd.exe. Downloads go to a local HTTP server (System.Net.HttpListener, loopback) that
# answers from a plan per URL and per client (the User-Agent tells curl from Windows PowerShell), so curl and
# Invoke-WebRequest are the real programs and the server's request log is the evidence of what the code did and in which
# order. The reachability probe and the pause between swap attempts call ping.exe and curl.exe by bare name; cmd.exe
# searches the current folder first, so a small compiled stub in the scenario folder answers from a plan and counts its calls.
# No network, no Miniconda and no provider are involved.
#
# Rows (all real lane, gating through the aggregate check):
#   self.netres.getpip.retry / .powershell / .fallback / .offline       REQ-013.14, .15, .13 + .14, .11
#   self.netres.miniconda.retry / .powershell / .checkorder / .offline  REQ-013.14, .15, .1 + .13, .10
#   self.netres.embed.retry / .powershell / .checksum / .extractfail    REQ-013.14, .15, .17, .17
#   self.netres.check.repeat                                            REQ-013.3
#   self.netres.swap.retry                                              REQ-013.18
param()
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
$repo = Split-Path -Path $here -Parent
$nd   = Join-Path $here '~test-results.ndjson'
$ciNd = Join-Path $repo 'ci_test_results.ndjson'
if (-not (Test-Path -LiteralPath $nd))   { New-Item -ItemType File -Path $nd   -Force | Out-Null }
if (-not (Test-Path -LiteralPath $ciNd)) { New-Item -ItemType File -Path $ciNd -Force | Out-Null }

$script:LaneTag = [Environment]::GetEnvironmentVariable('HP_CI_LANE')
$script:AnyRowFailed = $false
function Write-NdjsonRow {
    param([hashtable]$Row)
    if ($Row.ContainsKey('pass') -and -not $Row['pass']) { $script:AnyRowFailed = $true }
    if ($script:LaneTag -and -not $Row.ContainsKey('lane')) { $Row['lane'] = $script:LaneTag }
    $json = $Row | ConvertTo-Json -Compress -Depth 8
    Add-Content -LiteralPath $nd   -Value $json -Encoding Ascii
    Add-Content -LiteralPath $ciNd -Value $json -Encoding Ascii
}

# derived requirement: tools/check_ndjson_registry.py finds a row id only as a quoted string right after the id key, and
# tests/test_req_trace.py reads the req tag the same way, so each call below spells both out in quotes.
function Write-AllRows {
    param([bool]$Pass, $Details)
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.getpip.retry'; req = 'REQ-013.14'; pass = $Pass; desc = 'get-pip.py: a download that fails with a transient error three times is tried a fourth time by curl and delivers'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.getpip.powershell'; req = 'REQ-013.15'; pass = $Pass; desc = 'get-pip.py: when curl fails, Windows PowerShell tries the same URL before the secondary URL is touched'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.getpip.fallback'; req = 'REQ-013.13, REQ-013.14'; pass = $Pass; desc = 'get-pip.py: curl tries the primary URL four times in all, PowerShell once, then the secondary URL delivers'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.getpip.offline'; req = 'REQ-013.11'; pass = $Pass; desc = 'get-pip.py: in offline mode no request is made and the log says so'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.miniconda.retry'; req = 'REQ-013.14'; pass = $Pass; desc = 'Miniconda: a download that fails with a transient error three times is tried a fourth time by curl and delivers'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.miniconda.powershell'; req = 'REQ-013.15'; pass = $Pass; desc = 'Miniconda: when curl fails, Windows PowerShell tries the same URL and delivers without a connectivity check'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.miniconda.checkorder'; req = 'REQ-013.1, REQ-013.13'; pass = $Pass; desc = 'Miniconda: after the primary URL fails by both methods the connectivity check runs, then the secondary URL is tried'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.miniconda.offline'; req = 'REQ-013.10'; pass = $Pass; desc = 'Miniconda: in offline mode no request is made and the log says so'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.embed.retry'; req = 'REQ-013.14'; pass = $Pass; desc = 'embedded Python: a download that fails with a transient error three times is tried a fourth time by curl and delivers'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.embed.powershell'; req = 'REQ-013.15'; pass = $Pass; desc = 'embedded Python: when curl fails, Windows PowerShell tries the same URL and delivers'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.embed.checksum'; req = 'REQ-013.17'; pass = $Pass; desc = 'embedded Python: a download that fails its checksum is downloaded once more and the second one is used'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.embed.extractfail'; req = 'REQ-013.17'; pass = $Pass; desc = 'embedded Python: a download that cannot be extracted is downloaded once more, not a third time, and the tier then fails'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.check.repeat'; req = 'REQ-013.3'; pass = $Pass; desc = 'the reachability check repeats an unanswered ICMP echo once and an unanswered HTTPS request once, and no more'; details = $Details })
    Write-NdjsonRow ([ordered]@{ id = 'self.netres.swap.retry'; req = 'REQ-013.18'; pass = $Pass; desc = 'the replacement of the embedded Python folder is tried again after a failure, three attempts at most, with a pause between them'; details = $Details })
}

if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
    Write-AllRows -Pass $true -Details ([ordered]@{ skip = $true; reason = 'non-windows-host' })
    exit 0
}

$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path -LiteralPath $batchPath)) {
    Write-AllRows -Pass $false -Details ([ordered]@{ error = 'run_setup.bat not found at ' + $batchPath })
    exit 1
}

# A variable the product reads must not come from the job: the scenarios start cmd.exe children that inherit this process.
$scrubPattern = '^(HP_|PVW_|NOINPUT$|NoDefaultCurrentDirectoryInExePath$)'
foreach ($v in @(Get-ChildItem Env: | Where-Object { $_.Name -match $scrubPattern })) {
    Remove-Item -LiteralPath ('Env:' + $v.Name) -ErrorAction SilentlyContinue
}

$work = Join-Path $here '~selftest_netres'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Force -Path $work | Out-Null

$batLines = [System.IO.File]::ReadAllLines($batchPath)

# Lines from the line that is exactly StartLine up to, not including, the line that is exactly EndLine.
function Get-BatBlock {
    param([string]$StartLine, [string]$EndLine)
    $start = -1
    for ($i = 0; $i -lt $batLines.Length; $i++) {
        if ($batLines[$i].Trim() -eq $StartLine) { $start = $i; break }
    }
    if ($start -lt 0) { return $null }
    $end = -1
    for ($j = $start + 1; $j -lt $batLines.Length; $j++) {
        if ($batLines[$j].Trim() -eq $EndLine) { $end = $j; break }
    }
    if ($end -lt 0) { return $null }
    return $batLines[$start..($end - 1)]
}

$getpipBlock = Get-BatBlock -StartLine ':download_get_pip' -EndLine ':handle_conda_failure'
$condaBlock  = Get-BatBlock -StartLine ':download_miniconda_exe' -EndLine ':download_get_pip'
$embedBlock  = Get-BatBlock -StartLine 'set "HP_EMBED_DL_ATTEMPT=0"' -EndLine 'call :log "[INFO] embed fallback: %HP_EMBED_LATEST_PATCH% extracted and verified."'
$swapBlock   = Get-BatBlock -StartLine 'set "HP_EMBED_SWAP_ATTEMPT=0"' -EndLine ':embed_pyver_check_tagcheck'
$checkBlock  = Get-BatBlock -StartLine ':check_net_after_dl_fail' -EndLine ':system_python_consent_gate'
if ((-not $getpipBlock) -or (-not $condaBlock) -or (-not $embedBlock) -or (-not $swapBlock) -or (-not $checkBlock)) {
    Write-AllRows -Pass $false -Details ([ordered]@{
        error = 'could not cut the code blocks out of run_setup.bat; the lines the harness needs moved'
        getpipFound = [bool]$getpipBlock
        minicondaFound = [bool]$condaBlock
        embedFound = [bool]$embedBlock
        swapFound = [bool]$swapBlock
        checkFound = [bool]$checkBlock
    })
    exit 1
}

function Write-CrLf {
    param([string]$Path, [string[]]$Lines)
    [System.IO.File]::WriteAllText($Path, (($Lines -join "`r`n") + "`r`n"), [System.Text.Encoding]::ASCII)
}

function Read-Text {
    param([string]$Path)
    if (Test-Path -LiteralPath $Path) { return [System.IO.File]::ReadAllText($Path) }
    return ''
}

# --- the stub program: ping.exe and curl.exe in a scenario folder -----------------------------------------------------
# It records its arguments (one line per call, before anything else, so a waiting test can see the call) in <name>.calls,
# then answers from <name>.plan: comma separated items, each an exit code with an optional :milliseconds to sleep first.
# The last item repeats. The name comes from the file name, so one compiled program serves as both.
$stubSource = @'
using System;
using System.IO;
using System.Threading;
public static class Stub
{
    public static int Main(string[] args)
    {
        string exe = System.Reflection.Assembly.GetExecutingAssembly().Location;
        string dir = Path.GetDirectoryName(exe);
        string name = Path.GetFileNameWithoutExtension(exe);
        string calls = Path.Combine(dir, name + ".calls");
        string plan = Path.Combine(dir, name + ".plan");
        int n = 0;
        if (File.Exists(calls)) { n = File.ReadAllLines(calls).Length; }
        File.AppendAllText(calls, string.Join(" ", args) + "\r\n");
        string[] items = new string[] { "0" };
        if (File.Exists(plan)) { items = File.ReadAllText(plan).Trim().Split(','); }
        string item = items[Math.Min(n, items.Length - 1)].Trim();
        string[] parts = item.Split(':');
        if (parts.Length > 1) { Thread.Sleep(int.Parse(parts[1])); }
        return int.Parse(parts[0]);
    }
}
'@

$stubDir = Join-Path $work '~stubbuild'
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null
$stubExe = Join-Path $stubDir 'stub.exe'
$stubBuild = [ordered]@{ ok = $false; reason = 'not-built' }
$csc = $null
foreach ($candidate in @((Join-Path $env:windir 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'), (Join-Path $env:windir 'Microsoft.NET\Framework\v4.0.30319\csc.exe'))) {
    if ((-not $csc) -and (Test-Path -LiteralPath $candidate)) { $csc = $candidate }
}
if ($csc) {
    $srcPath = Join-Path $stubDir 'stub.cs'
    [System.IO.File]::WriteAllText($srcPath, $stubSource, [System.Text.Encoding]::ASCII)
    $cscOut = & $csc /nologo /target:exe ('/out:' + $stubExe) $srcPath 2>&1
    $stubBuild = [ordered]@{ ok = (Test-Path -LiteralPath $stubExe); reason = 'csc'; cscOutput = (($cscOut | Out-String).Trim()) }
} else {
    $stubBuild = [ordered]@{ ok = $false; reason = 'csc-not-found' }
}

# --- the local server ------------------------------------------------------------------------------------------------
Add-Type -AssemblyName System.IO.Compression

function Get-FreePort {
    $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
    $l.Start()
    $p = $l.LocalEndpoint.Port
    $l.Stop()
    return $p
}

function Get-Sha256Hex {
    param([byte[]]$Bytes)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = $sha.ComputeHash($Bytes) } finally { $sha.Dispose() }
    return (([BitConverter]::ToString($hash)) -replace '-', '').ToLower()
}

# A zip that the embed helper accepts: python.exe and a python*._pth with the commented import site line.
function New-StubZipBytes {
    param([string]$Marker)
    $ms = New-Object System.IO.MemoryStream
    $zip = New-Object System.IO.Compression.ZipArchive($ms, [System.IO.Compression.ZipArchiveMode]::Create, $true)
    foreach ($item in @(@('python.exe', ('stub python ' + $Marker)), @('python313._pth', ("python313.zip`r`n.`r`n#import site`r`n")))) {
        $entry = $zip.CreateEntry($item[0])
        $sw = New-Object System.IO.StreamWriter($entry.Open())
        $sw.Write($item[1])
        $sw.Dispose()
    }
    $zip.Dispose()
    $bytes = $ms.ToArray()
    $ms.Dispose()
    return $bytes
}

$state = [hashtable]::Synchronized(@{
    Plans  = @{}
    Counts = @{}
    Bodies = @{}
    Log    = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
})

# One plan per path and client kind ('<path>|curl' or '<path>|ps'): a list of '<status>[:<body name>]', one item per
# request of that kind, the last one repeating. A 200 sends the named body (default 'good'). A path with no plan answers 200.
$serverBlock = {
    param($listener, $state)
    while ($listener.IsListening) {
        $ctx = $null
        try { $ctx = $listener.GetContext() } catch { break }
        try {
            $req = $ctx.Request
            $res = $ctx.Response
            $path = $req.Url.AbsolutePath
            $ua = [string]$req.UserAgent
            $kind = 'other'
            if ($ua -like 'curl*') { $kind = 'curl' } elseif ($ua -like '*WindowsPowerShell*') { $kind = 'ps' }
            $key = $path + '|' + $kind
            $n = 0
            if ($state.Counts.ContainsKey($key)) { $n = [int]$state.Counts[$key] }
            $state.Counts[$key] = $n + 1
            $entry = '200:good'
            if ($state.Plans.ContainsKey($key)) {
                $plan = @($state.Plans[$key])
                if ($plan.Count -gt 0) { $entry = [string]$plan[[Math]::Min($n, $plan.Count - 1)] }
            }
            $parts = $entry.Split(':')
            $code = [int]$parts[0]
            $bodyName = 'good'
            if ($parts.Count -gt 1) { $bodyName = $parts[1] }
            $bytes = [System.Text.Encoding]::ASCII.GetBytes('status ' + $code)
            if (($code -eq 200) -and $state.Bodies.ContainsKey($bodyName)) { $bytes = [byte[]]$state.Bodies[$bodyName] }
            [void]$state.Log.Add($kind + '|' + $code + '|' + $path)
            $res.StatusCode = $code
            $res.ContentLength64 = $bytes.Length
            $res.OutputStream.Write($bytes, 0, $bytes.Length)
            $res.OutputStream.Close()
        } catch {
            try { $ctx.Response.Abort() } catch { }
        }
    }
}

$port = Get-FreePort
$base = 'http://127.0.0.1:' + $port
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($base + '/')
$serverError = ''
try { $listener.Start() } catch { $serverError = $_.Exception.Message }
$serverPs = $null
$serverHandle = $null
if (-not $serverError) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $serverPs = [powershell]::Create()
    $serverPs.Runspace = $rs
    $null = $serverPs.AddScript($serverBlock.ToString()).AddArgument($listener).AddArgument($state)
    $serverHandle = $serverPs.BeginInvoke()
}
if ($serverError -or (-not $stubBuild.ok)) {
    Write-AllRows -Pass $false -Details ([ordered]@{ error = 'the harness could not start'; serverError = $serverError; stubBuild = $stubBuild })
    exit 1
}

# --- running a driver ------------------------------------------------------------------------------------------------
$logLines = @(
    ':log',
    'setlocal',
    'set "MSG=%~1"',
    '>>"%LOG%" echo %MSG%',
    'endlocal',
    'exit /b 0'
)

function New-DriverHead {
    param([string]$Dir)
    return @(
        '@echo off',
        'setlocal',
        ('set "LOG=' + (Join-Path $Dir '~driver.log') + '"'),
        ('set "TEMP=' + (Join-Path $Dir 'tmp') + '"'),
        ('set "TMP=' + (Join-Path $Dir 'tmp') + '"')
    )
}

function New-ScenarioDir {
    param([string]$Name)
    $dir = Join-Path $work $Name
    New-Item -ItemType Directory -Force -Path (Join-Path $dir 'tmp') | Out-Null
    return $dir
}

# Starts the driver, waits for it (a hang is killed with its children and reported), and returns how it ended.
# WhileRunning is called about every 50 ms with the process and may stop waiting early by returning $true.
function Invoke-Driver {
    param([string]$Dir, [int]$TimeoutSec = 300, [scriptblock]$WhileRunning = $null)
    $driver = Join-Path $Dir '~driver.bat'
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $env:ComSpec -ArgumentList ('/d /c "' + $driver + '"') -WorkingDirectory $Dir -PassThru -NoNewWindow -RedirectStandardOutput (Join-Path $Dir '~driver_console.txt') -RedirectStandardError (Join-Path $Dir '~driver_console_err.txt')
    $null = $p.Handle
    $timedOut = $false
    $called = $false
    while (-not $p.HasExited) {
        if ($WhileRunning -and (-not $called)) {
            if (& $WhileRunning $p) { $called = $true }
        }
        if ($sw.Elapsed.TotalSeconds -gt $TimeoutSec) {
            $timedOut = $true
            & taskkill /F /T /PID $p.Id 2>&1 | Out-Null
            break
        }
        Start-Sleep -Milliseconds 50
    }
    $null = $p.WaitForExit(15000)
    return [ordered]@{
        exitCode = $(if ($p.HasExited) { $p.ExitCode } else { -1 })
        timedOut = $timedOut
        seconds = [Math]::Round($sw.Elapsed.TotalSeconds, 1)
    }
}

function Get-RequestEntries {
    param([string]$Name)
    return @($state.Log.ToArray() | Where-Object { $_ -like ('*|*|/' + $Name + '/*') })
}

function Get-RequestCount {
    param([object[]]$Entries, [string]$Role, [string]$Kind)
    return @($Entries | Where-Object { $_ -like ($Kind + '|*|*/' + $Role) }).Count
}

function Get-RequestSequence {
    param([object[]]$Entries)
    $parts = @()
    foreach ($e in $Entries) {
        $f = $e.Split('|')
        $parts += ($f[0] + ' ' + $f[2].Split('/')[-1])
    }
    return ($parts -join ',')
}

function Set-Plan {
    param([string]$Name, [string]$Role, [string]$Kind, [string[]]$Items)
    $state.Plans['/' + $Name + '/' + $Role + '|' + $Kind] = $Items
}

# A scenario that downloads: Block is getpip, miniconda or embed. Offline sets HP_OFFLINE_MODE. Sha is the checksum the
# embed block expects. The driver writes RESULT lines to ~driver_result.txt; the rest of the evidence is the server log.
function Invoke-DownloadScenario {
    param([string]$Block, [string]$Name, [string]$Offline = '', [string]$Sha = '')
    $dir = New-ScenarioDir -Name $Name
    $result = Join-Path $dir '~driver_result.txt'
    $url1 = $base + '/' + $Name + '/p1'
    $url2 = $base + '/' + $Name + '/p2'
    $lines = New-DriverHead -Dir $dir
    if ($Offline -eq '1') { $lines += 'set "HP_OFFLINE_MODE=1"' }
    if ($Block -eq 'getpip') {
        $lines += @(
            ('set "HP_GETPIP_URL=' + $url1 + '"'),
            ('set "HP_GETPIP_FALLBACK_URL=' + $url2 + '"'),
            'call :download_get_pip',
            ('if defined HP_GETPIP_PY (echo GETPIP=present > "' + $result + '") else (echo GETPIP=none > "' + $result + '")'),
            'exit /b 0'
        ) + $getpipBlock + $logLines
    } elseif ($Block -eq 'miniconda') {
        $lines += @(
            ('set "HP_MINICONDA_URL=' + $url1 + '"'),
            ('set "HP_MINICONDA_FALLBACK_URL=' + $url2 + '"'),
            'call :download_miniconda_exe',
            ('if exist "%TEMP%\miniconda.exe" (echo MINICONDA=present > "' + $result + '") else (echo MINICONDA=none > "' + $result + '")'),
            'exit /b 0'
        ) + $condaBlock + @(
            ':check_net_after_dl_fail',
            ('curl -s -o nul "' + $base + '/' + $Name + '/checkpoint"'),
            'exit /b 0'
        ) + $logLines
    } else {
        $lines += @(
            ('set "HP_EMBED_URL=' + $url1 + '"'),
            ('set "HP_EMBED_ZIP=' + (Join-Path $dir 'tmp\python-embed-amd64.zip') + '"'),
            ('set "HP_EMBED_DIR=' + (Join-Path $dir '~embed_python') + '"'),
            'set "HP_EMBED_LATEST_PATCH=3.13.99"',
            ('set "HP_EMBED_LATEST_SHA256=' + $Sha + '"'),
            'call :embed_body',
            'set "DRV_RC=%ERRORLEVEL%"',
            ('echo RC=%DRV_RC% > "' + $result + '"'),
            ('echo PY=%HP_EMBED_PY% >> "' + $result + '"'),
            'exit /b 0',
            ':embed_body'
        ) + $embedBlock + @(
            'exit /b 0',
            ':emit_from_base64',
            ('copy /y "' + (Join-Path $repo 'tools\embed_extract.ps1') + '" "%~1" >nul'),
            'exit /b 0'
        ) + $logLines
    }
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines $lines
    $run = Invoke-Driver -Dir $dir
    $entries = Get-RequestEntries -Name $Name
    return [ordered]@{
        scenario = $Name
        run = $run
        result = ((Read-Text -Path $result) -replace "`r", '' -replace '\s+$', '' -replace '\s*\n\s*', ';')
        log = (Read-Text -Path (Join-Path $dir '~driver.log'))
        requests = (Get-RequestSequence -Entries $entries)
        p1Curl = (Get-RequestCount -Entries $entries -Role 'p1' -Kind 'curl')
        p1Ps = (Get-RequestCount -Entries $entries -Role 'p1' -Kind 'ps')
        p2Curl = (Get-RequestCount -Entries $entries -Role 'p2' -Kind 'curl')
        p2Ps = (Get-RequestCount -Entries $entries -Role 'p2' -Kind 'ps')
        total = $entries.Count
        dir = $dir
    }
}

function Test-FileHasText {
    param([string]$Path, [string]$Text)
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    return ((Read-Text -Path $Path).Trim() -eq $Text)
}

# What goes into a row's details: the scenario without the folder path and with the log cut to the lines that matter.
function Get-Brief {
    param($S, $Extra = $null)
    $logLines2 = @(($S.log -split "`r?`n") | Where-Object { $_ -ne '' })
    $brief = [ordered]@{}
    foreach ($k in $S.Keys) {
        if (($k -ne 'dir') -and ($k -ne 'log')) { $brief[$k] = $S[$k] }
    }
    $brief['logLines'] = $logLines2
    if ($Extra) { foreach ($k in $Extra.Keys) { $brief[$k] = $Extra[$k] } }
    return $brief
}

$bodyGetpip = '# stub get-pip.py'
$bodyMiniconda = 'stub miniconda installer'
$state.Bodies['good'] = [System.Text.Encoding]::ASCII.GetBytes($bodyGetpip)

# ---- get-pip.py ----
$state.Bodies['good'] = [System.Text.Encoding]::ASCII.GetBytes($bodyGetpip)
Set-Plan -Name 'gp_retry' -Role 'p1' -Kind 'curl' -Items @('503', '503', '503', '200:good')
$gpRetry = Invoke-DownloadScenario -Block 'getpip' -Name 'gp_retry'
Set-Plan -Name 'gp_ps' -Role 'p1' -Kind 'curl' -Items @('404')
Set-Plan -Name 'gp_ps' -Role 'p1' -Kind 'ps' -Items @('200:good')
$gpPs = Invoke-DownloadScenario -Block 'getpip' -Name 'gp_ps'
Set-Plan -Name 'gp_fb' -Role 'p1' -Kind 'curl' -Items @('503')
Set-Plan -Name 'gp_fb' -Role 'p1' -Kind 'ps' -Items @('503')
Set-Plan -Name 'gp_fb' -Role 'p2' -Kind 'curl' -Items @('200:good')
$gpFb = Invoke-DownloadScenario -Block 'getpip' -Name 'gp_fb'
$gpOff = Invoke-DownloadScenario -Block 'getpip' -Name 'gp_off' -Offline '1'

$gpRetryFile = Test-FileHasText -Path (Join-Path $gpRetry.dir 'tmp\get-pip.py') -Text $bodyGetpip
$gpPsFile = Test-FileHasText -Path (Join-Path $gpPs.dir 'tmp\get-pip.py') -Text $bodyGetpip
$gpFbFile = Test-FileHasText -Path (Join-Path $gpFb.dir 'tmp\get-pip.py') -Text $bodyGetpip

Write-NdjsonRow ([ordered]@{
    id = 'self.netres.getpip.retry'
    req = 'REQ-013.14'
    pass = [bool](($gpRetry.p1Curl -eq 4) -and ($gpRetry.p1Ps -eq 0) -and (($gpRetry.p2Curl + $gpRetry.p2Ps) -eq 0) -and ($gpRetry.result -eq 'GETPIP=present') -and $gpRetryFile -and (-not $gpRetry.run.timedOut))
    desc = 'get-pip.py: a download that fails with a transient error three times is tried a fourth time by curl and delivers'
    details = (Get-Brief -S $gpRetry -Extra @{ fileHasBody = $gpRetryFile })
})
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.getpip.powershell'
    req = 'REQ-013.15'
    pass = [bool](($gpPs.p1Curl -eq 1) -and ($gpPs.p1Ps -eq 1) -and (($gpPs.p2Curl + $gpPs.p2Ps) -eq 0) -and ($gpPs.result -eq 'GETPIP=present') -and $gpPsFile -and (-not $gpPs.run.timedOut))
    desc = 'get-pip.py: when curl fails, Windows PowerShell tries the same URL before the secondary URL is touched'
    details = (Get-Brief -S $gpPs -Extra @{ fileHasBody = $gpPsFile })
})
$gpFbLines = ($gpFb.log -match 'Trying fallback get-pip.py URL') -and ($gpFb.log -match 'get-pip.py download succeeded from fallback URL')
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.getpip.fallback'
    req = 'REQ-013.13, REQ-013.14'
    pass = [bool](($gpFb.p1Curl -eq 4) -and ($gpFb.p1Ps -eq 1) -and ($gpFb.p2Curl -eq 1) -and ($gpFb.p2Ps -eq 0) -and ($gpFb.result -eq 'GETPIP=present') -and $gpFbFile -and $gpFbLines -and (-not $gpFb.run.timedOut))
    desc = 'get-pip.py: curl tries the primary URL four times in all, PowerShell once, then the secondary URL delivers'
    details = (Get-Brief -S $gpFb -Extra @{ fileHasBody = $gpFbFile; fallbackLines = [bool]$gpFbLines })
})
$gpOffLine = [bool]($gpOff.log -match 'Offline mode: skipping get-pip.py download')
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.getpip.offline'
    req = 'REQ-013.11'
    pass = [bool](($gpOff.total -eq 0) -and $gpOffLine -and ($gpOff.result -eq 'GETPIP=none') -and (-not $gpOff.run.timedOut))
    desc = 'get-pip.py: in offline mode no request is made and the log says so'
    details = (Get-Brief -S $gpOff -Extra @{ skipLine = $gpOffLine })
})

# ---- Miniconda ----
$state.Bodies['good'] = [System.Text.Encoding]::ASCII.GetBytes($bodyMiniconda)
Set-Plan -Name 'mc_retry' -Role 'p1' -Kind 'curl' -Items @('503', '503', '503', '200:good')
$mcRetry = Invoke-DownloadScenario -Block 'miniconda' -Name 'mc_retry'
Set-Plan -Name 'mc_ps' -Role 'p1' -Kind 'curl' -Items @('404')
Set-Plan -Name 'mc_ps' -Role 'p1' -Kind 'ps' -Items @('200:good')
$mcPs = Invoke-DownloadScenario -Block 'miniconda' -Name 'mc_ps'
Set-Plan -Name 'mc_order' -Role 'p1' -Kind 'curl' -Items @('404')
Set-Plan -Name 'mc_order' -Role 'p1' -Kind 'ps' -Items @('404')
Set-Plan -Name 'mc_order' -Role 'p2' -Kind 'curl' -Items @('200:good')
$mcOrder = Invoke-DownloadScenario -Block 'miniconda' -Name 'mc_order'
$mcOff = Invoke-DownloadScenario -Block 'miniconda' -Name 'mc_off' -Offline '1'

$mcRetryFile = Test-FileHasText -Path (Join-Path $mcRetry.dir 'tmp\miniconda.exe') -Text $bodyMiniconda
$mcPsFile = Test-FileHasText -Path (Join-Path $mcPs.dir 'tmp\miniconda.exe') -Text $bodyMiniconda
$mcOrderFile = Test-FileHasText -Path (Join-Path $mcOrder.dir 'tmp\miniconda.exe') -Text $bodyMiniconda

Write-NdjsonRow ([ordered]@{
    id = 'self.netres.miniconda.retry'
    req = 'REQ-013.14'
    pass = [bool](($mcRetry.p1Curl -eq 4) -and ($mcRetry.p1Ps -eq 0) -and (($mcRetry.p2Curl + $mcRetry.p2Ps) -eq 0) -and ($mcRetry.result -eq 'MINICONDA=present') -and $mcRetryFile -and (-not $mcRetry.run.timedOut))
    desc = 'Miniconda: a download that fails with a transient error three times is tried a fourth time by curl and delivers'
    details = (Get-Brief -S $mcRetry -Extra @{ fileHasBody = $mcRetryFile })
})
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.miniconda.powershell'
    req = 'REQ-013.15'
    pass = [bool](($mcPs.p1Curl -eq 1) -and ($mcPs.p1Ps -eq 1) -and (($mcPs.p2Curl + $mcPs.p2Ps) -eq 0) -and ($mcPs.requests -eq 'curl p1,ps p1') -and ($mcPs.result -eq 'MINICONDA=present') -and $mcPsFile -and (-not $mcPs.run.timedOut))
    desc = 'Miniconda: when curl fails, Windows PowerShell tries the same URL and delivers without a connectivity check'
    details = (Get-Brief -S $mcPs -Extra @{ fileHasBody = $mcPsFile })
})
$mcOrderLines = ($mcOrder.log -match 'Trying fallback Miniconda URL') -and ($mcOrder.log -match 'Miniconda download succeeded from fallback URL')
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.miniconda.checkorder'
    req = 'REQ-013.1, REQ-013.13'
    pass = [bool](($mcOrder.requests -eq 'curl p1,ps p1,curl checkpoint,curl p2') -and ($mcOrder.result -eq 'MINICONDA=present') -and $mcOrderFile -and $mcOrderLines -and (-not $mcOrder.run.timedOut))
    desc = 'Miniconda: after the primary URL fails by both methods the connectivity check runs, then the secondary URL is tried'
    details = (Get-Brief -S $mcOrder -Extra @{ fileHasBody = $mcOrderFile; fallbackLines = [bool]$mcOrderLines; wantedSequence = 'curl p1,ps p1,curl checkpoint,curl p2' })
})
$mcOffLine = [bool]($mcOff.log -match 'Offline mode: skipping Miniconda download')
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.miniconda.offline'
    req = 'REQ-013.10'
    pass = [bool](($mcOff.total -eq 0) -and $mcOffLine -and ($mcOff.result -eq 'MINICONDA=none') -and (-not $mcOff.run.timedOut))
    desc = 'Miniconda: in offline mode no request is made and the log says so'
    details = (Get-Brief -S $mcOff -Extra @{ skipLine = $mcOffLine })
})

# ---- embedded Python ----
$zipGood = New-StubZipBytes -Marker 'good'
$zipBad = New-StubZipBytes -Marker 'other'
$garbage = [System.Text.Encoding]::ASCII.GetBytes('this is not a zip file')
$shaGood = Get-Sha256Hex -Bytes $zipGood
$shaGarbage = Get-Sha256Hex -Bytes $garbage
$state.Bodies['good'] = $zipGood
$state.Bodies['bad'] = $zipBad
$state.Bodies['garbage'] = $garbage

Set-Plan -Name 'em_retry' -Role 'p1' -Kind 'curl' -Items @('503', '503', '503', '200:good')
$emRetry = Invoke-DownloadScenario -Block 'embed' -Name 'em_retry' -Sha $shaGood
Set-Plan -Name 'em_ps' -Role 'p1' -Kind 'curl' -Items @('404')
Set-Plan -Name 'em_ps' -Role 'p1' -Kind 'ps' -Items @('200:good')
$emPs = Invoke-DownloadScenario -Block 'embed' -Name 'em_ps' -Sha $shaGood
Set-Plan -Name 'em_sum' -Role 'p1' -Kind 'curl' -Items @('200:bad', '200:good')
$emSum = Invoke-DownloadScenario -Block 'embed' -Name 'em_sum' -Sha $shaGood
Set-Plan -Name 'em_ext' -Role 'p1' -Kind 'curl' -Items @('200:garbage')
$emExt = Invoke-DownloadScenario -Block 'embed' -Name 'em_ext' -Sha $shaGarbage

function Test-EmbedPython {
    param($S)
    $m = [regex]::Match($S.result, 'PY=(.*)$')
    if (-not $m.Success) { return $false }
    $py = $m.Groups[1].Value.Trim()
    if (-not $py) { return $false }
    return (Test-Path -LiteralPath $py)
}
$emRetryPy = Test-EmbedPython -S $emRetry
$emPsPy = Test-EmbedPython -S $emPs
$emSumPy = Test-EmbedPython -S $emSum
$emExtPy = Test-EmbedPython -S $emExt

Write-NdjsonRow ([ordered]@{
    id = 'self.netres.embed.retry'
    req = 'REQ-013.14'
    pass = [bool](($emRetry.p1Curl -eq 4) -and ($emRetry.p1Ps -eq 0) -and ($emRetry.result -match '^RC=0;') -and $emRetryPy -and (-not $emRetry.run.timedOut))
    desc = 'embedded Python: a download that fails with a transient error three times is tried a fourth time by curl and delivers'
    details = (Get-Brief -S $emRetry -Extra @{ pythonExtracted = $emRetryPy })
})
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.embed.powershell'
    req = 'REQ-013.15'
    pass = [bool](($emPs.p1Curl -eq 1) -and ($emPs.p1Ps -eq 1) -and ($emPs.result -match '^RC=0;') -and $emPsPy -and (-not $emPs.run.timedOut))
    desc = 'embedded Python: when curl fails, Windows PowerShell tries the same URL and delivers'
    details = (Get-Brief -S $emPs -Extra @{ pythonExtracted = $emPsPy })
})
$emSumLine = [bool]($emSum.log -match 'checksum verification or extraction failed; retrying download once')
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.embed.checksum'
    req = 'REQ-013.17'
    pass = [bool](($emSum.p1Curl -eq 2) -and ($emSum.p1Ps -eq 0) -and ($emSum.result -match '^RC=0;') -and $emSumPy -and $emSumLine -and (-not $emSum.run.timedOut))
    desc = 'embedded Python: a download that fails its checksum is downloaded once more and the second one is used'
    details = (Get-Brief -S $emSum -Extra @{ pythonExtracted = $emSumPy; retryLine = $emSumLine })
})
$emExtRetry = [bool]($emExt.log -match 'checksum verification or extraction failed; retrying download once')
$emExtFinal = [bool](@(($emExt.log -split "`r?`n") | Where-Object { $_ -match 'checksum verification or extraction failed\.$' }).Count -ge 1)
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.embed.extractfail'
    req = 'REQ-013.17'
    pass = [bool](($emExt.p1Curl -eq 2) -and ($emExt.p1Ps -eq 0) -and ($emExt.result -match '^RC=1;') -and (-not $emExtPy) -and $emExtRetry -and $emExtFinal -and (-not $emExt.run.timedOut))
    desc = 'embedded Python: a download that cannot be extracted is downloaded once more, not a third time, and the tier then fails'
    details = (Get-Brief -S $emExt -Extra @{ pythonExtracted = $emExtPy; retryLine = $emExtRetry; finalLine = $emExtFinal })
})

# ---- the reachability check ----
function Invoke-CheckScenario {
    param([string]$Name, [string]$PingPlan, [string]$CurlPlan)
    $dir = New-ScenarioDir -Name $Name
    $result = Join-Path $dir '~driver_result.txt'
    foreach ($tool in @('ping', 'curl')) { Copy-Item -LiteralPath $stubExe -Destination (Join-Path $dir ($tool + '.exe')) -Force }
    [System.IO.File]::WriteAllText((Join-Path $dir 'ping.plan'), $PingPlan, [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $dir 'curl.plan'), $CurlPlan, [System.Text.Encoding]::ASCII)
    $lines = (New-DriverHead -Dir $dir) + @(
        'set "HP_TEST_CNDF_ANSWER=n"',
        'call :check_net_after_dl_fail',
        'set "DRV_RC=%ERRORLEVEL%"',
        ('echo RC=%DRV_RC% > "' + $result + '"'),
        ('if "%HP_OFFLINE_MODE%"=="1" echo OFFLINE=1 >> "' + $result + '"'),
        'exit /b 0'
    ) + $checkBlock + $logLines
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines $lines
    $run = Invoke-Driver -Dir $dir -TimeoutSec 120
    $pingCalls = @((Read-Text -Path (Join-Path $dir 'ping.calls')) -split "`r?`n" | Where-Object { $_ -ne '' })
    $curlCalls = @((Read-Text -Path (Join-Path $dir 'curl.calls')) -split "`r?`n" | Where-Object { $_ -ne '' })
    return [ordered]@{
        scenario = $Name
        run = $run
        result = ((Read-Text -Path $result) -replace "`r", '' -replace '\s+$', '' -replace '\s*\n\s*', ';')
        log = (Read-Text -Path (Join-Path $dir '~driver.log'))
        pingCalls = $pingCalls.Count
        curlCalls = $curlCalls.Count
        pingArgs = (@($pingCalls | Select-Object -First 1) -join '')
        curlArgs = (@($curlCalls | Select-Object -First 1) -join '')
        dir = $dir
    }
}

$ckPing = Invoke-CheckScenario -Name 'ck_ping' -PingPlan '1,0' -CurlPlan '1'
$ckCurl = Invoke-CheckScenario -Name 'ck_curl' -PingPlan '1' -CurlPlan '1,0'
$ckNone = Invoke-CheckScenario -Name 'ck_none' -PingPlan '1' -CurlPlan '1'
$ckPingOk = (($ckPing.pingCalls -eq 2) -and ($ckPing.curlCalls -eq 0) -and ($ckPing.result -match '^RC=0') -and ($ckPing.log -match 'internet reachable\. Cascading to fallback') -and ($ckPing.log -notmatch 'via HTTPS'))
$ckCurlOk = (($ckCurl.pingCalls -eq 2) -and ($ckCurl.curlCalls -eq 2) -and ($ckCurl.result -match '^RC=0') -and ($ckCurl.log -match 'reachable via HTTPS') -and ($ckCurl.curlArgs -match 'conda\.anaconda\.org'))
$ckNoneOk = (($ckNone.pingCalls -eq 2) -and ($ckNone.curlCalls -eq 2) -and ($ckNone.result -match '^RC=1') -and ($ckNone.result -match 'OFFLINE=1') -and ($ckNone.log -match 'no internet detected'))
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.check.repeat'
    req = 'REQ-013.3'
    pass = [bool]($ckPingOk -and $ckCurlOk -and $ckNoneOk -and (-not $ckPing.run.timedOut) -and (-not $ckCurl.run.timedOut) -and (-not $ckNone.run.timedOut))
    desc = 'the reachability check repeats an unanswered ICMP echo once and an unanswered HTTPS request once, and no more'
    details = [ordered]@{
        pingRepeated = [bool]$ckPingOk
        curlRepeated = [bool]$ckCurlOk
        noAnswerBounded = [bool]$ckNoneOk
        pingScenario = (Get-Brief -S $ckPing)
        curlScenario = (Get-Brief -S $ckCurl)
        noneScenario = (Get-Brief -S $ckNone)
    }
})

# ---- the folder replacement of the embed tier ----
# The old folder holds a file that stays open (FileShare.Read: readable, not deletable), so rd cannot remove the folder.
# ReleaseOnPing releases it when the stub ping, the pause between two attempts, has been called once; the stub then sleeps
# 1500 ms, so the next attempt always sees the release. Otherwise the lock stays for the whole run.
function Invoke-SwapScenario {
    param([string]$Name, [bool]$ReleaseOnPing, [string]$PingPlan)
    $dir = New-ScenarioDir -Name $Name
    $result = Join-Path $dir '~driver_result.txt'
    $embedDir = Join-Path $dir '~embed_python'
    $swapDir = Join-Path $dir '~embed_python_swap'
    New-Item -ItemType Directory -Force -Path $embedDir | Out-Null
    New-Item -ItemType Directory -Force -Path $swapDir | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $embedDir 'python.exe'), 'old python', [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $embedDir 'locked.txt'), 'held open', [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText((Join-Path $swapDir 'python.exe'), 'new python', [System.Text.Encoding]::ASCII)
    Copy-Item -LiteralPath $stubExe -Destination (Join-Path $dir 'ping.exe') -Force
    [System.IO.File]::WriteAllText((Join-Path $dir 'ping.plan'), $PingPlan, [System.Text.Encoding]::ASCII)
    $lines = (New-DriverHead -Dir $dir) + @(
        ('set "HP_EMBED_DIR=' + $embedDir + '"'),
        ('set "HP_EMBED_SWAP_DIR=' + $swapDir + '"'),
        'set "HP_EMBED_SWAP_MINOR=3.12"',
        'call :swap_body',
        'exit /b 0',
        ':swap_body'
    ) + $swapBlock + @(
        ':embed_pyver_check_tagcheck',
        ('if exist "%HP_EMBED_DIR%\python.exe" (echo PYTHON=present > "' + $result + '") else (echo PYTHON=missing > "' + $result + '")'),
        'exit /b 0'
    ) + $logLines
    Write-CrLf -Path (Join-Path $dir '~driver.bat') -Lines $lines
    $lock = [System.IO.File]::Open((Join-Path $embedDir 'locked.txt'), [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $pingCalls = Join-Path $dir 'ping.calls'
    $released = $false
    $watch = {
        param($p)
        if ($ReleaseOnPing -and (Test-Path -LiteralPath $pingCalls)) {
            $lock.Dispose()
            return $true
        }
        return $false
    }.GetNewClosure()
    try {
        $run = Invoke-Driver -Dir $dir -TimeoutSec 120 -WhileRunning $watch
    } finally {
        $lock.Dispose()
    }
    $calls = @((Read-Text -Path $pingCalls) -split "`r?`n" | Where-Object { $_ -ne '' })
    $pyPath = Join-Path $embedDir 'python.exe'
    return [ordered]@{
        scenario = $Name
        run = $run
        result = ((Read-Text -Path $result) -replace "`r", '' -replace '\s+$', '')
        log = (Read-Text -Path (Join-Path $dir '~driver.log'))
        pauses = $calls.Count
        pauseArgs = (@($calls | Select-Object -First 1) -join '')
        pythonText = $(if (Test-Path -LiteralPath $pyPath) { (Read-Text -Path $pyPath).Trim() } else { '' })
        dir = $dir
    }
}

$swOk = Invoke-SwapScenario -Name 'sw_ok' -ReleaseOnPing $true -PingPlan '0:1500'
$swStuck = Invoke-SwapScenario -Name 'sw_stuck' -ReleaseOnPing $false -PingPlan '0:200'
$swOkGood = (($swOk.pauses -eq 1) -and ($swOk.pauseArgs -match '127\.0\.0\.1') -and ($swOk.result -eq 'PYTHON=present') -and ($swOk.pythonText -eq 'new python') -and ($swOk.log -match 'swapped to requested Python 3\.12') -and ($swOk.log -notmatch 'swap move failed'))
$swStuckGood = (($swStuck.pauses -eq 2) -and ($swStuck.log -match 'swap move failed; interpreter may be missing') -and ($swStuck.log -notmatch 'swapped to requested Python'))
Write-NdjsonRow ([ordered]@{
    id = 'self.netres.swap.retry'
    req = 'REQ-013.18'
    pass = [bool]($swOkGood -and $swStuckGood -and (-not $swOk.run.timedOut) -and (-not $swStuck.run.timedOut))
    desc = 'the replacement of the embedded Python folder is tried again after a failure, three attempts at most, with a pause between them'
    details = [ordered]@{
        succeedsOnSecondAttempt = [bool]$swOkGood
        givesUpAfterThreeAttempts = [bool]$swStuckGood
        okScenario = (Get-Brief -S $swOk)
        stuckScenario = (Get-Brief -S $swStuck)
    }
})

# --- teardown ----------------------------------------------------------------------------------------------------------
try { $listener.Stop() } catch { }
try { if ($serverPs) { $serverPs.Stop() } } catch { }
try { $listener.Close() } catch { }
# The compiled stubs are copies of one program; the artifact keeps the logs, the request lists and the plans, not the programs.
Get-ChildItem -LiteralPath $work -Recurse -Filter '*.exe' -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue

if ($script:AnyRowFailed) { exit 1 }
exit 0
