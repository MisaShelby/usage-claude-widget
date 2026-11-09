# Screenshots of the Windows widget in demo mode (sample data), for the README.
# Run on a Windows desktop session (the CI uses a GitHub Actions Windows runner):
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\tests\Take-Screenshots.ps1 -Out docs\screenshots
# Full-screen captures and the list of the widget's windows go to -DebugDir, to understand a failure.
param(
    [string]$Out = 'docs\screenshots',
    [string]$DebugDir = 'ci-debug',
    [ValidateSet('fr', 'en')][string]$Lang = 'en'
)
$ErrorActionPreference = 'Stop'
# Toute erreur imprévue devient une annotation GitHub (fichier, ligne, message).
trap {
    $where = "$([IO.Path]::GetFileName($_.InvocationInfo.ScriptName)):$($_.InvocationInfo.ScriptLineNumber)"
    $text = "$where $($_.Exception.Message) | $($_.InvocationInfo.Line.Trim())" -replace "`r?`n", ' / '
    Write-Host "::error::$text"
    exit 1
}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class ShotNative {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    public class Win { public IntPtr Handle; public bool Visible; public string Title; public int Left, Top, Right, Bottom; }
    delegate bool EnumProc(IntPtr hwnd, IntPtr lParam);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr lParam);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    public static Win[] WindowsOf(int pid) {
        var list = new List<Win>();
        EnumWindows((h, l) => {
            uint p; GetWindowThreadProcessId(h, out p);
            if (p == (uint)pid) {
                var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
                RECT r; GetWindowRect(h, out r);
                list.Add(new Win { Handle = h, Visible = IsWindowVisible(h), Title = sb.ToString(),
                    Left = r.Left, Top = r.Top, Right = r.Right, Bottom = r.Bottom });
            }
            return true;
        }, IntPtr.Zero);
        return list.ToArray();
    }
}
'@
[void][ShotNative]::SetProcessDPIAware()

$app = (Resolve-Path (Join-Path $PSScriptRoot '..\ClaudeBudget.ps1')).Path
New-Item -ItemType Directory -Force -Path $Out, $DebugDir | Out-Null
$Out = (Resolve-Path $Out).Path
$DebugDir = (Resolve-Path $DebugDir).Path
$log = Join-Path $env:LOCALAPPDATA 'ClaudeBudget\widget.log'
$notes = Join-Path $DebugDir 'debug.txt'

$screen = [Windows.Forms.Screen]::PrimaryScreen
$bounds = $screen.Bounds
$work = $screen.WorkingArea
"screen $bounds · working area $($work)" | Tee-Object -FilePath $notes | Write-Host

function Save-Region([Drawing.Rectangle]$rect, [string]$path, [int]$zoom = 1) {
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
    $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    Write-Host "saved $path"
}

# Visible window of the widget: the one with this title, else the largest one.
function Widget-Window([int]$processId, [string]$title, [string]$stage) {
    $wins = @([ShotNative]::WindowsOf($processId))
    Add-Content -LiteralPath $notes -Value "[$stage] windows of process ${processId}:"
    foreach ($w in $wins) {
        Add-Content -LiteralPath $notes -Value ("  visible={0} title='{1}' rect={2},{3},{4},{5}" -f $w.Visible, $w.Title, $w.Left, $w.Top, $w.Right, $w.Bottom)
    }
    $visible = @($wins | Where-Object { $_.Visible -and ($_.Right - $_.Left) -gt 50 -and ($_.Bottom - $_.Top) -gt 50 })
    $match = @($visible | Where-Object { $_.Title -eq $title })
    if ($match.Count -eq 0) { $match = @($visible | Sort-Object { ($_.Right - $_.Left) * ($_.Bottom - $_.Top) } -Descending) }
    if ($match.Count -eq 0) { throw "no visible window for '$title' (see $notes)" }
    $w = $match[0]
    return New-Object Drawing.Rectangle($w.Left, $w.Top, ($w.Right - $w.Left), ($w.Bottom - $w.Top))
}

function Start-Widget([string[]]$extra, [string]$stage) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$app`"", '-Demo', '-Lang', $Lang) + $extra
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 10
    Save-Region $bounds (Join-Path $DebugDir "$stage-screen.png")
    if ($p.HasExited) { throw "the widget stopped (exit code $($p.ExitCode))" }
    return $p
}

function Stop-Widget($p) {
    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

# Bureau dégagé : les autres fenêtres (console du runner…) ne gênent pas les captures.
(New-Object -ComObject Shell.Application).MinimizeAll()
Start-Sleep -Seconds 2

$failed = $false
try {
    # 1. Notification area + detail panel.
    $p = Start-Widget @('-OpenPanel') 'panel'
    $taskbarH = [Math]::Max([int]1, $bounds.Bottom - $work.Bottom)
    $strip = New-Object Drawing.Rectangle(($bounds.Right - 420), $work.Bottom, 420, $taskbarH)
    Save-Region $strip (Join-Path $Out 'windows-taskbar.png') 2
    $title = if ($Lang -eq 'fr') { 'Budget Claude' } else { 'Claude Budget' }
    $panel = Widget-Window $p.Id $title 'panel'
    $x = [Math]::Max([int]0, $panel.Left - 24)
    $y = [Math]::Max([int]0, $panel.Top - 24)
    Save-Region (New-Object Drawing.Rectangle($x, $y, ($bounds.Right - $x), ($bounds.Bottom - $y))) (Join-Path $Out 'windows-panel.png')
    Stop-Widget $p

    # 2. Week chart.
    $p = Start-Widget @('-OpenWeek') 'week'
    $title = if ($Lang -eq 'fr') { 'Usage Claude de la semaine' } else { 'Claude usage this week' }
    Save-Region (Widget-Window $p.Id $title 'week') (Join-Path $Out 'windows-week.png')
    Stop-Widget $p
} catch {
    $failed = $true
    $where = "$([IO.Path]::GetFileName($_.InvocationInfo.ScriptName)):$($_.InvocationInfo.ScriptLineNumber)"
    Write-Host ("::error::$where $($_.Exception.Message)" -replace "`r?`n", ' / ')
} finally {
    if (Test-Path $log) {
        Add-Content -LiteralPath $notes -Value '--- widget.log ---'
        Get-Content $log | Add-Content -LiteralPath $notes
    }
    Get-Content $notes | Write-Host
}
if ($failed) { exit 1 }
