# ASCII only
param()
$ErrorActionPreference = "Stop"
$OutDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjDir = Split-Path -Parent $OutDir
$BatchPath = Join-Path $ProjDir "run_setup.bat"
$ResultsPath = Join-Path $OutDir "~test-results.ndjson"
$SummaryPath = Join-Path $OutDir "~test-summary.txt"
$ExtractDir = Join-Path $OutDir "extracted"
if (Test-Path $ResultsPath) { Remove-Item -Force $ResultsPath }
if (!(Test-Path $BatchPath)) { Write-Host "run_setup.bat not found next to run_tests.bat." -ForegroundColor Red; exit 2 }
New-Item -ItemType Directory -Force -Path $ExtractDir | Out-Null
function Write-Result { param($Id,$Desc,[bool]$Pass,$Details)
  $rec = [ordered]@{ id=$Id; pass=$Pass; desc=$Desc; details=$Details }
  $json = $rec | ConvertTo-Json -Compress
  Add-Content -Path $ResultsPath -Value $json -Encoding Ascii
}
$Lines = Get-Content -LiteralPath $BatchPath -Encoding ASCII
$AllText = [string]::Join("`n", $Lines)
$sha = (Get-FileHash -Algorithm SHA256 -LiteralPath $BatchPath).Hash
Write-Result "file.hash" "SHA256 of run_setup.bat" $true @{ sha256 = $sha }
$psBlocks = [regex]::Matches($AllText, 'call\s+:write_ps_file\s+"[^"]*emit_[^"]*\.ps1"\s+"@''(?s).*?''@"') | ForEach-Object { $_.Value }
function Extract-InnerHereString([string]$Block) {
  $outFile = ([regex]::Match($Block, "\$OutFile\s*=\s*'([^']+\.py)'")).Groups[1].Value
  $content = ([regex]::Match($Block, "\$Content\s*=\s*@'(?s)(.*?)'@")).Groups[1].Value
  return @{ OutFile=$outFile; Content=$content }
}
$emitted = @()
foreach ($b in $psBlocks) {
  $rec = Extract-InnerHereString $b
  if ($rec.Content -and $rec.OutFile) {
    $dest = Join-Path $ExtractDir $rec.OutFile
    $text = $rec.Content -replace "`r?`n","`r`n"
    [IO.File]::WriteAllText($dest, $text, [Text.Encoding]::ASCII)
    $emitted += $rec.OutFile
    Write-Result "emit.extract" "Extracted $($rec.OutFile) from run_setup.bat here-strings" $true @{ file=$rec.OutFile }
  }
}
$hasDisable = ($Lines | Select-String -SimpleMatch "setlocal DisableDelayedExpansion").Count -gt 0
Write-Result "batch.delayed.off" "DisableDelayedExpansion present" $hasDisable @{}
$hasEnable = ($Lines | Select-String -SimpleMatch "EnableDelayedExpansion").Count -gt 0
Write-Result "batch.delayed.enable_absent" "EnableDelayedExpansion not present" (-not $hasEnable) @{}
$bangHits = @()
$inHere = $false
for ($i=0; $i -lt $Lines.Count; $i++) {
  $ln = $Lines[$i]
  if (-not $inHere -and $ln -match "@'") { $inHere = $true; continue }
  if ($inHere) {
    if ($ln -match "'@") { $inHere = $false }
    continue
  }
  if ($ln -match '^\s*(rem|echo)\b') { continue }
  if ($ln -like "*!*") { $bangHits += ("line {0}: {1}" -f ($i+1), $ln.Trim()) }
}
Write-Result "batch.bang.scan" "No '!' in live batch code lines" ($bangHits.Count -eq 0) @{ hits=$bangHits }
$badConda = @()
for ($i=0; $i -lt $Lines.Count; $i++) {
  $ln = $Lines[$i]
  if ($ln -match "^\s*call\s+\"%CONDA_BAT%\"\s+(create|install)\b") {
    $window = ($ln + " " + ($(if ($i+1 -lt $Lines.Count) { $Lines[$i+1] } else { "" })) + " " + ($(if ($i+2 -lt $Lines.Count) { $Lines[$i+2] } else { "" })))
    if ($window -notmatch "--override-channels" -or $window -notmatch "-c\s+conda-forge") {
      $badConda += ("line {0}: {1}" -f ($i+1), $ln.Trim())
    }
  }
}
Write-Result "conda.channels" "All conda create/install use --override-channels -c conda-forge" ($badConda.Count -eq 0) @{ misses=$badConda }
$hasPipreqs = ($AllText -match "pipreqs\s+\.\s+--force.*--mode\s+compat.*--savepath\s+requirements\.auto\.txt")
Write-Result "pipreqs.flags" "pipreqs flags OK" $hasPipreqs @{} 
$hasPyInst = ($AllText -match "pyinstaller\s+-y\s+--onefile\s+--name\s+""%ENVNAME%""")
Write-Result "pyi.onefile" "PyInstaller one-file named %ENVNAME%" $hasPyInst @{} 
$hasRotate = ($AllText -match "Length -gt 10485760")
Write-Result "log.rotate" "Log rotation ~10MB present" $hasRotate @{} 
$tildeCount = ([regex]::Matches($AllText, "~setup\.log|~reqs_conda\.txt|~pipreqs\.diff\.txt|~entry\.txt|~run\.err\.txt")).Count
Write-Result "tilde.naming" "Tilde prefix used for crashable artifacts" ($tildeCount -ge 3) @{ count=$tildeCount }
$visa = ($AllText -match "pyvisa" -or $AllText -match "import[ ]*visa")
Write-Result "visa.detect" "NI-VISA import detection present" $visa @{} 
$need = @("~detect_python.py","~prep_requirements.py","~print_pyver.py","~find_entry.py")
$missing = $need | Where-Object { $_ -notin $emitted }
Write-Result "emit.helpers" "All helper scripts extractable from run_setup.bat" ($missing.Count -eq 0) @{ missing=$missing }
$dpPath = Join-Path $ExtractDir "~detect_python.py"
$dpHasCompat = $false
if (Test-Path $dpPath) { $dpHasCompat = ((Get-Content $dpPath -Encoding ASCII) | Select-String -SimpleMatch 'op == "~="').Count -gt 0 }
Write-Result "dp.compat" "detect_python handles ~= in requires-python" $dpHasCompat @{} 
$prPath = Join-Path $ExtractDir "~prep_requirements.py"
$fmtOK = $false
if (Test-Path $prPath) {
  $txt = Get-Content $prPath -Encoding ASCII
  $fmtOK = ($txt | Select-String -SimpleMatch 'return [f"{name} " + ",".join(ops)] if ops else [name]').Count -gt 0
}
Write-Result "prep.multi.constraint" "prep_requirements formats multi-constraints as name >=X,<Y" $fmtOK @{} 
$paren = 0; $imbalance = @()
for ($k=0; $k -lt $Lines.Count; $k++) {
  $ln = $Lines[$k]
  $open = ([regex]::Matches($ln, "\(")).Count
  $close = ([regex]::Matches($ln, "\)")).Count
  $paren += ($open - $close)
  if ($paren -lt 0) { $imbalance += ("line {0}: {1} (paren={2})" -f ($k+1), $ln.Trim(), $paren) }
}
Write-Result "batch.paren.balance" "No negative parenthesis balance while scanning" ($imbalance.Count -eq 0) @{ issues=$imbalance }
$envLine = ($AllText -match 'for %%I in \("%CD%"\) do set "ENVNAME=%%~nI"')
Write-Result "env.foldername" "Env name equals folder name" $envLine @{} 
$instPathOk = ($AllText -match "%PUBLIC%\\Documents\\Miniconda3")
Write-Result "conda.path" "Miniconda path is %PUBLIC%\Documents\Miniconda3" $instPathOk @{} 
$results = Get-Content -LiteralPath $ResultsPath -Encoding ASCII | ForEach-Object { $_ | ConvertFrom-Json }
$fail = @($results | Where-Object { -not $_.pass })
$pass = @($results | Where-Object { $_.pass })
$sb = New-Object System.Text.StringBuilder
$null = $sb.AppendLine("=== Static Test Summary ===")
$null = $sb.AppendLine("run_setup.bat sha256: " + $sha.ToLower())
$null = $sb.AppendLine("PASS: " + $pass.Count + "    FAIL: " + $fail.Count)
if ($fail.Count -gt 0) { $null = $sb.AppendLine("---- Failures ----"); foreach ($f in $fail) { $null = $sb.AppendLine(("* " + $f.id + " :: " + $f.desc)) } }
$null = $sb.AppendLine("Artifacts:")
$null = $sb.AppendLine("  tests\~test-results.ndjson")
$null = $sb.AppendLine("  tests\extracted\ (helper sources)")
[IO.File]::WriteAllText($SummaryPath, $sb.ToString(), [Text.Encoding]::ASCII)
if ($fail.Count -gt 0) { exit 1 } else { exit 0 }
