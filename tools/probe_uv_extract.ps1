# ASCII only. CLAUDE.md Item 127 (temporary probe, removed with the fix): on the runner image of
# 2026-11-16 the bootstrapper downloads uv's zip in full and then finds no uv.exe. The product's
# extraction line is powershell -Command "try { Expand-Archive ... } catch { exit 1 }" and the catch
# throws the reason away, so the setup log cannot say why. This script answers it directly on the
# runner: image facts, the Archive module that Windows PowerShell 5.1 loads, Defender state, and each
# way of unpacking the same zip (the product's exact command line, the same with the reason printed,
# the .NET ZipFile call, tar) for the newest uv release, the one before it and the 0.7.3 fallback.
# It only reports; it never fails the step. Run: powershell -File tools/probe_uv_extract.ps1

$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('uvprobe_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null

function Show([string]$Text) { Write-Host ("PROBE " + $Text) }

function Get-FolderFacts([string]$Dir) {
    if (-not (Test-Path -LiteralPath $Dir)) { return 'folder missing' }
    $files = @(Get-ChildItem -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })
    if ($files.Count -eq 0) { return 'folder empty' }
    return (($files | ForEach-Object { $_.FullName.Substring($Dir.Length).TrimStart('\') + '=' + $_.Length }) -join '; ')
}

Show ('image=' + $env:ImageVersion + ' os=' + [System.Environment]::OSVersion.Version + ' ps=' + $PSVersionTable.PSVersion + ' edition=' + $PSVersionTable.PSEdition)
Show ('clr=' + [System.Environment]::Version + ' dotnet=' + [System.Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)
Show ('curl=' + ((& curl.exe --version 2>&1 | Select-Object -First 1) -join ' '))

# The Archive module Windows PowerShell loads: every version on PSModulePath, which one Expand-Archive comes from.
try {
    $mods = @(Get-Module -ListAvailable -Name Microsoft.PowerShell.Archive)
    foreach ($m in $mods) { Show ('archive module ' + $m.Version + ' at ' + $m.ModuleBase) }
    $cmd = Get-Command Expand-Archive -ErrorAction Stop
    Show ('Expand-Archive resolves to module ' + $cmd.Source + ' ' + $cmd.Version)
} catch { Show ('Expand-Archive lookup failed: ' + $_.Exception.Message) }
Show ('PSModulePath=' + $env:PSModulePath)

# Defender: is it on, and has it removed anything.
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Show ('Defender realtime=' + $mp.RealTimeProtectionEnabled + ' antivirus=' + $mp.AntivirusEnabled + ' behavior=' + $mp.BehaviorMonitorEnabled + ' signatures=' + $mp.AntivirusSignatureVersion)
} catch { Show ('Defender status unavailable: ' + $_.Exception.Message) }
try {
    $pref = Get-MpPreference -ErrorAction Stop
    Show ('Defender exclusions paths=' + ($pref.ExclusionPath -join ',') + ' processes=' + ($pref.ExclusionProcess -join ','))
} catch { Show ('Defender preference unavailable: ' + $_.Exception.Message) }

# Which uv releases to try: the newest two from the API, plus the bootstrapper's own fallback URL.
$urls = [ordered]@{}
$urls['latest'] = 'https://github.com/astral-sh/uv/releases/latest/download/uv-x86_64-pc-windows-msvc.zip'
try {
    $hdr = @{ 'User-Agent' = 'probe' }
    if ($env:GITHUB_TOKEN) { $hdr['Authorization'] = 'Bearer ' + $env:GITHUB_TOKEN }
    $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/astral-sh/uv/releases?per_page=4' -Headers $hdr
    $i = 0
    foreach ($r in $rel) {
        $i++
        Show ('release ' + $r.tag_name + ' published ' + $r.published_at)
        if ($i -le 3) { $urls['tag_' + $r.tag_name] = 'https://github.com/astral-sh/uv/releases/download/' + $r.tag_name + '/uv-x86_64-pc-windows-msvc.zip' }
    }
} catch { Show ('release list unavailable: ' + $_.Exception.Message) }
$urls['fallback_0.7.3'] = 'https://github.com/astral-sh/uv/releases/download/0.7.3/uv-x86_64-pc-windows-msvc.zip'

foreach ($name in $urls.Keys) {
    $dir = Join-Path $work $name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $zip = Join-Path $dir '~uv_setup.zip'
    & curl.exe --fail -L --retry 3 --retry-delay 5 --max-time 120 -s -S $urls[$name] -o $zip 2>&1 | ForEach-Object { Show ($name + ' curl: ' + $_) }
    if (-not (Test-Path -LiteralPath $zip)) { Show ($name + ' download failed'); continue }
    $sha = [System.BitConverter]::ToString((New-Object System.Security.Cryptography.SHA256Managed).ComputeHash([System.IO.File]::ReadAllBytes($zip))).Replace('-', '').ToLower()
    Show ($name + ' zip bytes=' + (Get-Item -LiteralPath $zip).Length + ' sha256=' + $sha)

    # 1. The product's exact command line, run through cmd.exe the way run_setup.bat runs it.
    $d1 = Join-Path $dir 'x1'
    $bat = Join-Path $dir 'x1.cmd'
    $line = 'powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Expand-Archive -LiteralPath ''' + $zip + ''' -DestinationPath ''' + $d1 + ''' -Force } catch { exit 1 }"'
    [System.IO.File]::WriteAllText($bat, "@echo off`r`n" + $line + "`r`necho rc=%ERRORLEVEL%`r`n")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = (& cmd.exe /c $bat 2>&1) -join ' | '
    Show ($name + ' product line: ' + $out + ' in ' + $sw.ElapsedMilliseconds + ' ms; ' + (Get-FolderFacts $d1))
    Start-Sleep -Seconds 3
    Show ($name + ' product line, 3 s later: ' + (Get-FolderFacts $d1))

    # 2. The same call with the reason printed.
    $d2 = Join-Path $dir 'x2'
    $cmd2 = 'try { Expand-Archive -LiteralPath ''' + $zip + ''' -DestinationPath ''' + $d2 + ''' -Force -ErrorAction Stop } catch { Write-Output (''ERR '' + $_.Exception.GetType().FullName + '': '' + $_.Exception.Message); exit 1 }'
    $out2 = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd2 2>&1) -join ' | '
    Show ($name + ' Expand-Archive with reason: rc=' + $LASTEXITCODE + ' ' + $out2 + '; ' + (Get-FolderFacts $d2))

    # 3. The .NET call, no module involved.
    $d3 = Join-Path $dir 'x3'
    $cmd3 = 'try { Add-Type -AssemblyName System.IO.Compression.FileSystem; [System.IO.Compression.ZipFile]::ExtractToDirectory(''' + $zip + ''', ''' + $d3 + '''); Write-Output ''dotnet ok'' } catch { Write-Output (''ERR '' + $_.Exception.GetType().FullName + '': '' + $_.Exception.Message); exit 1 }'
    $out3 = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd3 2>&1) -join ' | '
    Show ($name + ' ZipFile.ExtractToDirectory: rc=' + $LASTEXITCODE + ' ' + $out3 + '; ' + (Get-FolderFacts $d3))

    # 4. tar (bsdtar ships in System32 since Windows 10 1803).
    $d4 = Join-Path $dir 'x4'
    New-Item -ItemType Directory -Path $d4 | Out-Null
    $out4 = (& tar.exe -xf $zip -C $d4 2>&1) -join ' | '
    Show ($name + ' tar: rc=' + $LASTEXITCODE + ' ' + $out4 + '; ' + (Get-FolderFacts $d4))

    # Does the unpacked uv.exe run?
    foreach ($d in @($d1, $d2, $d3, $d4)) {
        $exe = Join-Path $d 'uv.exe'
        if (Test-Path -LiteralPath $exe) { Show ($name + ' ' + (Split-Path $d -Leaf) + ' uv --version: ' + ((& $exe --version 2>&1) -join ' ')) }
    }
}

try {
    $ev = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Windows Defender/Operational'; Id = 1116, 1117, 1118, 1119, 1015, 5007 } -MaxEvents 10 -ErrorAction Stop
    foreach ($e in $ev) { Show ('Defender event ' + $e.Id + ' ' + $e.TimeCreated + ': ' + (($e.Message -split "`n")[0..2] -join ' ')) }
} catch { Show ('Defender events: ' + $_.Exception.Message) }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
exit 0
