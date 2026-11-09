# Screenshots of the Windows widget in demo mode (sample data), for the README.
# Run on a Windows desktop session (the CI uses a GitHub Actions Windows runner):
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\tests\Take-Screenshots.ps1 -Out docs\screenshots
param(
    [string]$Out = 'docs\screenshots',
    [ValidateSet('fr', 'en')][string]$Lang = 'en'
)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ShotNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
}
'@
[void][ShotNative]::SetProcessDPIAware()

$app = (Resolve-Path (Join-Path $PSScriptRoot '..\ClaudeBudget.ps1')).Path
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$log = Join-Path $env:LOCALAPPDATA 'ClaudeBudget\widget.log'

$screen = [Windows.Forms.Screen]::PrimaryScreen
Write-Host "Screen $($screen.Bounds) · working area $($screen.WorkingArea)"

function Save-Region([Drawing.Rectangle]$rect, [string]$name, [int]$zoom = 1) {
    $bmp = New-Object Drawing.Bitmap $rect.Width, $rect.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($rect.Location, [Drawing.Point]::Empty, $rect.Size)
    $g.Dispose()
    if ($zoom -gt 1) {
        $big = New-Object Drawing.Bitmap ($rect.Width * $zoom), ($rect.Height * $zoom)
        $g = [Drawing.Graphics]::FromImage($big)
        $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
        $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::Half
        $g.DrawImage($bmp, 0, 0, $big.Width, $big.Height)
        $g.Dispose(); $bmp.Dispose(); $bmp = $big
    }
    $path = Join-Path $Out $name
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "saved $path"
}

function Window-Rect([string]$title) {
    $hwnd = [ShotNative]::FindWindow($null, $title)
    if ($hwnd -eq [IntPtr]::Zero) { throw "window '$title' not found" }
    $r = New-Object ShotNative+RECT
    [void][ShotNative]::GetWindowRect($hwnd, [ref]$r)
    return New-Object Drawing.Rectangle($r.Left, $r.Top, ($r.Right - $r.Left), ($r.Bottom - $r.Top))
}

function Start-Widget([string[]]$extra) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$app`"", '-Demo', '-Lang', $Lang) + $extra
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru
    Start-Sleep -Seconds 8
    if ($p.HasExited) {
        if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host "::error::$_" } }
        throw "the widget stopped (exit code $($p.ExitCode))"
    }
    return $p
}

$bounds = $screen.Bounds
$work = $screen.WorkingArea
$taskbarH = $bounds.Bottom - $work.Bottom

# 1. Notification area + detail panel.
$p = Start-Widget @('-OpenPanel')
try {
    $strip = New-Object Drawing.Rectangle(($bounds.Right - 420), $work.Bottom, 420, [Math]::Max(1, $taskbarH))
    Save-Region $strip 'windows-taskbar.png' 2
    $panel = Window-Rect $(if ($Lang -eq 'fr') { 'Budget Claude' } else { 'Claude Budget' })
    $x = [Math]::Max(0, $panel.Left - 24)
    $y = [Math]::Max(0, $panel.Top - 24)
    Save-Region (New-Object Drawing.Rectangle($x, $y, ($bounds.Right - $x), ($bounds.Bottom - $y))) 'windows-panel.png'
} finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

# 2. Week chart.
$p = Start-Widget @('-OpenWeek')
try {
    $rect = Window-Rect $(if ($Lang -eq 'fr') { 'Usage Claude de la semaine' } else { 'Claude usage this week' })
    Save-Region $rect 'windows-week.png'
} finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }

if (Test-Path $log) { Write-Host '--- widget.log ---'; Get-Content $log | Write-Host }
