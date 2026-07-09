# REQ-009 Tier 5: verifies checksum, extracts, and patches the disabled-site-imports ._pth file
# for an already-downloaded embeddable Python zip. Batch has already downloaded the zip (via the
# same curl-then-Invoke-WebRequest pattern as :download_miniconda_exe/:download_get_pip) and
# passes its path plus the expected SHA256 and destination directory as args. This script does
# NOT download anything itself and does NOT branch on requested version -- see the Python-side
# stage for per-request version selection.
# Args: $1 = zip path, $2 = expected sha256 (lowercase hex), $3 = destination directory.
# Output: on success, prints the extracted python.exe path on stdout, exit 0. On failure
# (checksum mismatch, extraction failure, missing ._pth, missing python.exe), prints nothing and
# exits 1 -- caller checks both stdout and exit code.
#
# derived requirement: hashing/extraction/text-IO deliberately use raw .NET APIs
# ([System.Security.Cryptography.SHA256], [System.IO.Compression.ZipFile], [System.IO.File])
# instead of the Get-FileHash / Expand-Archive / Get-Content / Set-Content cmdlets. Confirmed via
# real CI failure (Windows PowerShell 5.1, invoked as a for /f backtick subshell from run_setup.bat)
# that Get-FileHash throws "not recognized as the name of a cmdlet" in that exact invocation
# context -- its module (Microsoft.PowerShell.Utility) was not auto-loading, even though this
# script tested fine locally under pwsh (PowerShell 7 on Linux) beforehand, which does not share
# the same module-loading behavior. Test-Path/Get-Item (Microsoft.PowerShell.Management) worked
# fine in the same run, so this is scoped to Utility-module cmdlets specifically; .NET types have
# no module-loading dependency at all and sidestep the whole class of failure. See
# docs/agent-lessons-learned.md.
$ZipPath = $args[0]
$ExpectedSha256 = $args[1]
$DestDir = $args[2]

try {
    if (-not (Test-Path -LiteralPath $ZipPath)) {
        [Console]::Error.WriteLine("[embed_extract] zip not found: $ZipPath")
        exit 1
    }
    $ZipSize = (Get-Item -LiteralPath $ZipPath).Length
    $Sha256Provider = [System.Security.Cryptography.SHA256]::Create()
    $FileStream = [System.IO.File]::OpenRead($ZipPath)
    try {
        $HashBytes = $Sha256Provider.ComputeHash($FileStream)
    } finally {
        $FileStream.Dispose()
        $Sha256Provider.Dispose()
    }
    $ActualHash = ([BitConverter]::ToString($HashBytes) -replace '-', '').ToLower()
    if ($ActualHash -ne $ExpectedSha256.ToLower()) {
        [Console]::Error.WriteLine("[embed_extract] checksum mismatch: size=$ZipSize expected=$($ExpectedSha256.ToLower()) actual=$ActualHash")
        exit 1
    }

    if (Test-Path -LiteralPath $DestDir) { Remove-Item -Recurse -Force -LiteralPath $DestDir }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $DestDir)

    $PthFile = Get-ChildItem -LiteralPath $DestDir -Filter "python*._pth" -File | Select-Object -First 1
    if (-not $PthFile) {
        [Console]::Error.WriteLine("[embed_extract] no python*._pth file found under $DestDir")
        exit 1
    }
    # derived requirement: the embeddable zip's ._pth file ships with CRLF line endings, and
    # .NET regex $ in multiline mode matches immediately before \n -- it does not skip a
    # preceding \r, so an anchor of "^#import site$" against a CRLF line silently never matches
    # (the \r sits between "site" and the match position). \r? handles both line-ending styles.
    $PthContent = [System.IO.File]::ReadAllText($PthFile.FullName)
    $PthContent = $PthContent -replace '(?m)^#import site\r?$', 'import site'
    [System.IO.File]::WriteAllText($PthFile.FullName, $PthContent, [System.Text.Encoding]::ASCII)

    $PyExe = Join-Path $DestDir "python.exe"
    if (-not (Test-Path -LiteralPath $PyExe)) {
        [Console]::Error.WriteLine("[embed_extract] python.exe missing after extraction: $PyExe")
        exit 1
    }
    [Console]::Write($PyExe)
} catch {
    [Console]::Error.WriteLine("[embed_extract] exception: $($_.Exception.Message)")
    exit 1
}
