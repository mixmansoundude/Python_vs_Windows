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
$ZipPath = $args[0]
$ExpectedSha256 = $args[1]
$DestDir = $args[2]

try {
    if (-not (Test-Path -LiteralPath $ZipPath)) { exit 1 }
    $ActualHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash.ToLower()
    if ($ActualHash -ne $ExpectedSha256.ToLower()) { exit 1 }

    if (Test-Path -LiteralPath $DestDir) { Remove-Item -Recurse -Force -LiteralPath $DestDir }
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $DestDir -Force

    $PthFile = Get-ChildItem -LiteralPath $DestDir -Filter "python*._pth" -File | Select-Object -First 1
    if (-not $PthFile) { exit 1 }
    (Get-Content -LiteralPath $PthFile.FullName) -replace '^#import site$', 'import site' |
        Set-Content -LiteralPath $PthFile.FullName -Encoding ASCII

    $PyExe = Join-Path $DestDir "python.exe"
    if (-not (Test-Path -LiteralPath $PyExe)) { exit 1 }
    [Console]::Write($PyExe)
} catch {
    exit 1
}
