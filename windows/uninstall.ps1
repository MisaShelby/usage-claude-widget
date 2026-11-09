# Removes Claude Budget for the current Windows user.
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\uninstall.ps1 [-KeepHistory]
param([switch]$KeepHistory)
$ErrorActionPreference = 'Stop'

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*ClaudeBudget.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Programs'))) {
    $link = Join-Path $folder 'Claude Budget.lnk'
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force }
}

$data = Join-Path $env:LOCALAPPDATA 'ClaudeBudget'
if ($KeepHistory) {
    Remove-Item -LiteralPath (Join-Path $data 'app') -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host 'Claude Budget has been removed.'
