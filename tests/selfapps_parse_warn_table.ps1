# ASCII only
# selfapps_parse_warn_table.ps1
# Verifies that ~parse_warn.py (HP_PARSE_WARN) translates every TRANSLATIONS table entry
# from import name to the expected conda package name.
# Uses PyInstaller 5.x format synthetic warn files.
# Emits one combined NDJSON row: self.parse_warn.table
# Lane: all (lightweight, no conda env required).
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

# TRANSLATIONS table: import name -> expected conda package name.
# derived requirement: must stay in sync with TRANSLATIONS in tools/parse_warn.py
# and HP_PARSE_WARN in run_setup.bat.
$mappings = [ordered]@{
    'cv2'      = 'opencv'
    'PIL'      = 'pillow'
    'Image'    = 'pillow'
    'sklearn'  = 'scikit-learn'
    'bs4'      = 'beautifulsoup4'
    'serial'   = 'pyserial'
    'yaml'     = 'pyyaml'
    'git'      = 'gitpython'
    'wx'       = 'wxpython'
    'dateutil' = 'python-dateutil'
    'dotenv'   = 'python-dotenv'
    'Crypto'   = 'pycryptodome'
    'OpenSSL'  = 'pyopenssl'
    'jwt'      = 'pyjwt'
    'usb'      = 'pyusb'
    'attr'     = 'attrs'
    'win32api' = 'pywin32'
    'win32con' = 'pywin32'
    'fitz'     = 'pymupdf'
    'docx'     = 'python-docx'
}

# Locate Python
$pyExe = $null
foreach ($cand in @('python', 'python3')) {
    if (Get-Command $cand -ErrorAction SilentlyContinue) {
        $pyExe = $cand
        break
    }
}
if (-not $pyExe) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.parse_warn.table'
        pass    = $false
        desc    = 'parse_warn TRANSLATIONS table: python not in PATH'
        details = [ordered]@{ error = 'python not found' }
    })
    exit 1
}

# Extract and decode HP_PARSE_WARN from run_setup.bat
$batchPath = Join-Path $repo 'run_setup.bat'
if (-not (Test-Path $batchPath)) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.parse_warn.table'
        pass    = $false
        desc    = 'parse_warn TRANSLATIONS table: run_setup.bat not found'
        details = [ordered]@{ error = 'run_setup.bat not found at ' + $batchPath }
    })
    exit 1
}
$batchText = Get-Content -LiteralPath $batchPath -Raw -Encoding ASCII
$varMatch  = [regex]::Match($batchText, 'set "HP_PARSE_WARN=([A-Za-z0-9+/=]+)"')
if (-not $varMatch.Success) {
    Write-NdjsonRow ([ordered]@{
        id      = 'self.parse_warn.table'
        pass    = $false
        desc    = 'parse_warn TRANSLATIONS table: HP_PARSE_WARN not found in run_setup.bat'
        details = [ordered]@{ error = 'HP_PARSE_WARN set line not found' }
    })
    exit 1
}
$b64     = $varMatch.Groups[1].Value
$bytes   = [System.Convert]::FromBase64String($b64)
$pwSrc   = [System.Text.Encoding]::UTF8.GetString($bytes)

# Work directory
$workDir = Join-Path $here '~selftest_parse_warn_table'
if (Test-Path $workDir) { Remove-Item -Recurse -Force $workDir }
New-Item -ItemType Directory -Force -Path $workDir | Out-Null

# Write decoded parse_warn.py to work dir
$pwPath = Join-Path $workDir '~parse_warn_tbl.py'
[System.IO.File]::WriteAllText($pwPath, $pwSrc, [System.Text.Encoding]::UTF8)

# Test each mapping individually using 5.x format synthetic warn files
$failures  = [System.Collections.Generic.List[object]]::new()
$envname   = 'tblenv'
$buildBase = Join-Path $workDir "build\$envname"
New-Item -ItemType Directory -Force -Path $buildBase | Out-Null
$warnFile  = Join-Path $buildBase "warn-$envname.txt"

foreach ($kv in $mappings.GetEnumerator()) {
    $importName  = $kv.Key
    $expectedPkg = $kv.Value

    # Write synthetic 5.x warn line
    "W: no module named '$importName'" | Set-Content -LiteralPath $warnFile -Encoding ASCII

    Push-Location $workDir
    try {
        $rawOut  = & $pyExe '~parse_warn_tbl.py' $envname 2>$null
        $exitCode = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $lines = @()
    if ($rawOut) {
        $lines = ($rawOut -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }

    if ($expectedPkg -notin $lines) {
        $failures.Add([ordered]@{
            import   = $importName
            expected = $expectedPkg
            got      = ($lines -join ',')
            exit     = $exitCode
        })
    }
}

$pass = ($failures.Count -eq 0)

Write-NdjsonRow ([ordered]@{
    id      = 'self.parse_warn.table'
    pass    = $pass
    desc    = 'parse_warn TRANSLATIONS table: all import->conda mappings resolve correctly'
    details = [ordered]@{
        tested   = $mappings.Count
        failures = $failures.ToArray()
    }
})

if (-not $pass) { exit 1 }

# Second loop: PyInstaller 6.x format
# Format: missing module named <import> - imported by <importer> (top-level)
$failures6 = [System.Collections.Generic.List[object]]::new()

foreach ($kv in $mappings.GetEnumerator()) {
    $importName  = $kv.Key
    $expectedPkg = $kv.Value

    # Write synthetic 6.x warn line
    "missing module named $importName - imported by app (top-level)" | Set-Content -LiteralPath $warnFile -Encoding ASCII

    Push-Location $workDir
    try {
        $rawOut6  = & $pyExe '~parse_warn_tbl.py' $envname 2>$null
        $exitCode6 = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    $lines6 = @()
    if ($rawOut6) {
        $lines6 = ($rawOut6 -split "`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    }

    if ($expectedPkg -notin $lines6) {
        $failures6.Add([ordered]@{
            import   = $importName
            expected = $expectedPkg
            got      = ($lines6 -join ',')
            exit     = $exitCode6
        })
    }
}

$pass6 = ($failures6.Count -eq 0)

Write-NdjsonRow ([ordered]@{
    id      = 'self.parse_warn.table.v6'
    pass    = $pass6
    desc    = 'parse_warn TRANSLATIONS table: all import->conda mappings resolve correctly (PyInstaller 6.x format)'
    details = [ordered]@{
        tested   = $mappings.Count
        failures = $failures6.ToArray()
    }
})

if (-not $pass6) { exit 1 }
exit 0
