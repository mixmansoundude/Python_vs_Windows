<# 
PowerShell "compile-all" (syntax-only) for Python_vs_Windows
Version: 2025-11-09.v2
Purpose : Parse every .ps1/.psm1/.psd1 without executing; fail fast on syntax/manifest errors.
Why     : Equivalent to Python's compileall for PowerShell; no PSGallery or extra modules required.
Docs    : Parser API https://learn.microsoft.com/powershell/module/microsoft.powershell.sdk/about/about_PowerShell_SDK
          Test-ModuleManifest https://learn.microsoft.com/powershell/module/microsoft.powershell.core/test-modulemanifest
Notes   : - Catches real parse errors (unmatched ), }, here-strings, attribute syntax, stray backticks, etc.)
          - Also validates module manifests (metadata only; does not execute module code)
          - Emits GitHub-style ::error annotations when GITHUB_ACTIONS is set (harmless elsewhere)
#>

[CmdletBinding()]
param(
  [Parameter()] [string]$Root = ".",

  # We filter by extension for robust cross-platform recursion
  [Parameter()] [string[]]$Extensions = @(".ps1",".psm1",".psd1"),

  # Repo-aware directory skips (tuned for Python_vs_Windows)
  [Parameter()] [string[]]$ExcludeDirs = @(
    ".git","node_modules","bin","obj","dist","build",
    ".venv","venv",".tox","__pycache__",".pytest_cache",".mypy_cache","coverage",
    "diag/_artifacts","diag/_vendor","_vendor","diag/_temp","diag/_site","site","docs/_build"
  ),

  # Also validate *.psd1 manifests (recommended)
  [Parameter()] [bool]$ValidateManifests = $true,

  # Optional: emit JSON report to a path (prints to stdout if you pass "-Json -")
  [Parameter()] [string]$Json = $null,

  # Optional: list files being parsed
  [Parameter()] [switch]$List
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# --- Debug sanity checks (print only when -Verbose) ---
Write-Verbose ("PSVersion: {0}" -f $PSVersionTable.PSVersion)
Write-Verbose ("Root: {0}" -f (Resolve-Path $Root))

# Build directory-exclude regex (works on Windows/Linux)
$sep = [IO.Path]::DirectorySeparatorChar
$excludeRegex = ('({0})' -f ((
  $ExcludeDirs | ForEach-Object { $_.Replace('\','/').Replace('.','\.') }
) -join '|'))

# Gather files robustly, then filter by extension (avoid brittle -Include behavior)
$allFiles = Get-ChildItem -Path $Root -Recurse -File -ErrorAction Stop
$files = $allFiles | Where-Object {
  $p = $_.FullName.Replace('\','/')
  -not ($p -match "/$excludeRegex(/|$)") -and ($_.Extension -in $Extensions)
}

if ($List) { $files | ForEach-Object { "FILE: $($_.FullName)" } }

$errors = [System.Collections.Generic.List[object]]::new()
$inCI   = [bool]$env:GITHUB_ACTIONS

function Add-ErrorRecord {
  param([string]$File,[int]$Line,[int]$Column,[string]$Error,[string]$Text)
  $obj = [pscustomobject]@{
    File   = $File
    Line   = $Line
    Column = $Column
    Error  = $Error
    Text   = $Text
  }
  $script:errors.Add($obj)

  # Human-friendly output
  '{0}:{1}:{2}: {3}' -f $obj.File, $obj.Line, $obj.Column, $obj.Error

  # GitHub annotation (best-effort escaping)
  if ($inCI) {
    $fpath = $obj.File.Replace('\','/')
    $msg   = ($obj.Error -replace "[:\r\n%]"," ").Trim()
    Write-Output "::error file=$fpath,line=$($obj.Line),col=$($obj.Column)::$msg"
  }
}

# --- Parse all candidate files ---
foreach ($f in $files) {
  $tokens=$null; $parseErrs=$null
  [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$parseErrs)

  foreach ($e in ($parseErrs | Where-Object { $_ })) {
    Add-ErrorRecord -File   $e.Extent.File `
                    -Line   $e.Extent.StartLineNumber `
                    -Column $e.Extent.StartColumnNumber `
                    -Error  $e.Message `
                    -Text   ($e.Extent.Text.Trim())
  }
}

# --- Optional: validate module manifests (metadata only) ---
if ($ValidateManifests) {
  $manifests = $files | Where-Object Extension -eq ".psd1"
  foreach ($m in $manifests) {
    try {
      Test-ModuleManifest -Path $m.FullName | Out-Null
    }
    catch {
      Add-ErrorRecord -File $m.FullName -Line 1 -Column 1 -Error $_.Exception.Message -Text ""
    }
  }
}

# --- Emit optional JSON report ---
if ($Json) {
  $jsonData = [pscustomobject]@{
    ps_version = $PSVersionTable.PSVersion.ToString()
    root       = (Resolve-Path $Root).Path
    checked    = $files.Count
    errors     = $errors
  } | ConvertTo-Json -Depth 6

  if ($Json -eq "-") { $jsonData }
  else {
    $outPath = Resolve-Path -LiteralPath $Json -ErrorAction SilentlyContinue
    if (-not $outPath) {
      $dir = Split-Path -Parent $Json
      if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
      Set-Content -Path $Json -Value $jsonData -NoNewline
    } else {
      Set-Content -Path $outPath -Value $jsonData -NoNewline
    }
  }
}

# --- Summary & exit code (cap at 255 to be POSIX-friendly) ---
if ($errors.Count -gt 0) {
  Write-Error ("Syntax/manifest errors: {0}" -f $errors.Count)
  exit ([Math]::Min(255, $errors.Count))
}
else {
  Write-Host ("Syntax OK ({0} files checked)" -f $files.Count)
}
