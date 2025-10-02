[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$checks = @(
    @{ Display = 'py -3'; Exe = 'py'; Args = @('-3') },
    @{ Display = 'python'; Exe = 'python'; Args = @() },
    @{ Display = 'python3'; Exe = 'python3'; Args = @() }
)

foreach ($check in $checks) {
    $exe = $check.Exe
    try {
        $null = Get-Command -Name $exe -ErrorAction Stop
    } catch {
        continue
    }

    $args = @()
    if ($check.Args) { $args += $check.Args }
    $args += '-c'
    $args += 'import sys; print(sys.version)'

    try {
        $null = & $exe @args 2>$null | Out-Null
    } catch {
        continue
    }

    if ($LASTEXITCODE -eq 0) {
        Write-Output $check.Display
        exit 0
    }
}

Write-Error 'choose_python.ps1: no supported interpreter found.'
exit 1
