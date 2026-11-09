# Installs Claude Budget for the current Windows user (no administrator rights needed):
#   - copies the widget to %LOCALAPPDATA%\ClaudeBudget\app
#   - starts it with Windows (Startup folder) and adds it to the Start menu
#   - launches it now
# Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\install.ps1
param([switch]$NoStart)
$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'ClaudeBudget\app'
$powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script = Join-Path $dest 'ClaudeBudget.ps1'
$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`""

# Stop a running copy so its files can be replaced.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like '*ClaudeBudget.ps1*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($file in @('ClaudeBudget.ps1', 'BudgetCore.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $dest -Force
}
Get-ChildItem -LiteralPath $dest -Filter '*.ps1' | Unblock-File

$shell = New-Object -ComObject WScript.Shell
foreach ($folder in @([Environment]::GetFolderPath('Startup'), [Environment]::GetFolderPath('Programs'))) {
    $link = $shell.CreateShortcut((Join-Path $folder 'Claude Budget.lnk'))
    $link.TargetPath = $powershell
    $link.Arguments = $arguments
    $link.WorkingDirectory = $dest
    $link.WindowStyle = 7 # minimized: no console flash
    $link.Description = 'Claude weekly budget in the notification area'
    $link.Save()
}

if (-not $NoStart) { Start-Process -FilePath $powershell -ArgumentList $arguments -WindowStyle Hidden }

Write-Host 'Claude Budget is installed and starts with Windows.'
Write-Host 'Windows 11: Settings > Personalization > Taskbar > Other system tray icons > turn on both'
Write-Host '"Windows PowerShell" icons to keep them next to the clock.'
