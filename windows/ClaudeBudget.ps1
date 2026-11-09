<#
  Claude Budget — widget de la zone de notification Windows (près du Wi-Fi et de la batterie).
  Deux icônes : % du budget du jour et % de la limite hebdomadaire Claude ; un clic ouvre le
  détail, comme le menu de la version GNOME. Windows PowerShell 5.1, rien à installer.

  Paramètres :
    -Demo       données d'exemple (rien n'est lu ni enregistré) — aperçu et captures d'écran
    -OpenPanel  ouvre le panneau au démarrage    -OpenWeek  ouvre le graphique au démarrage
    -Lang fr|en force la langue (sinon : celle de Windows)
#>
param(
    [switch]$Demo,
    [switch]$OpenPanel,
    [switch]$OpenWeek,
    [ValidateSet('', 'fr', 'en')][string]$Lang = ''
)
$ErrorActionPreference = 'Stop'
$RequestedLang = $Lang
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
. (Join-Path $PSScriptRoot 'BudgetCore.ps1')

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ClaudeBudgetNative {
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr hIcon);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
}
'@
[void][ClaudeBudgetNative]::SetProcessDPIAware()
[Windows.Forms.Application]::EnableVisualStyles()

# ── Réglages ─────────────────────────────────────────────────────────────────
$REFRESH_MS = 300000
$RETRY_MS = 30000
$PROBE_MIN_MS = 240000
$USAGE_URL = 'https://api.anthropic.com/api/oauth/usage'

if ($env:CLAUDE_CONFIG_DIR) { $ConfigDir = $env:CLAUDE_CONFIG_DIR } else { $ConfigDir = Join-Path $env:USERPROFILE '.claude' }
$CredPath = Join-Path $ConfigDir '.credentials.json'
$DataDir = Join-Path $env:LOCALAPPDATA 'ClaudeBudget'
$StatePath = Join-Path $DataDir 'state.json'
$LogPath = Join-Path $DataDir 'widget.log'
if (-not (Test-Path -LiteralPath $DataDir)) { [void](New-Item -ItemType Directory -Path $DataDir) }

if ($RequestedLang) { $script:Lang = $RequestedLang } else { $script:Lang = pickLang @([Globalization.CultureInfo]::CurrentUICulture.Name) }

function Write-Log([string]$message) {
    try {
        if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 200KB) {
            Remove-Item -LiteralPath $LogPath
        }
        Add-Content -LiteralPath $LogPath -Value ('{0}  {1}' -f (Get-Date -Format 's'), $message) -Encoding UTF8
    } catch { }
}

# Une seule instance à la fois (sauf en démonstration).
if (-not $Demo) {
    $created = $false
    $script:Mutex = New-Object Threading.Mutex($true, 'Local\ClaudeBudgetWidget', [ref]$created)
    if (-not $created) { exit 0 }
}

function NowMs { return [double][DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() }
function hhmm($ms) { return (ToLocal $ms).ToString('HH:mm', $Invariant) }

# ── Thème (clair / sombre comme la barre des tâches) ─────────────────────────
function Rgb([int]$hex) { return [Drawing.Color]::FromArgb(($hex -shr 16) -band 255, ($hex -shr 8) -band 255, $hex -band 255) }
function Mix([Drawing.Color]$a, [Drawing.Color]$b, [double]$t) {
    return [Drawing.Color]::FromArgb(
        [int]($a.R * $t + $b.R * (1 - $t)), [int]($a.G * $t + $b.G * (1 - $t)), [int]($a.B * $t + $b.B * (1 - $t)))
}

function Get-Theme {
    $light = $false
    try {
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        $light = ((Get-ItemProperty -Path $key -Name 'SystemUsesLightTheme' -ErrorAction Stop).SystemUsesLightTheme -eq 1)
    } catch { }
    if ($light) {
        $t = @{ light = $true; bg = (Rgb 0xf9f9f9); fg = (Rgb 0x1b1b1b); border = (Rgb 0xdedede)
            green = (Rgb 0x26a269); orange = (Rgb 0xc64600); red = (Rgb 0xc01c28); time = (Rgb 0x8a8a8a) }
    } else {
        $t = @{ light = $false; bg = (Rgb 0x2b2b2b); fg = (Rgb 0xffffff); border = (Rgb 0x404040)
            green = (Rgb 0x33d17a); orange = (Rgb 0xff7800); red = (Rgb 0xed333b); time = (Rgb 0x9a9a9a) }
    }
    $t.dim = Mix $t.fg $t.bg 0.62
    $t.track = Mix $t.fg $t.bg 0.18
    $t.hover = Mix $t.fg $t.bg 0.08
    $t.line = Mix $t.fg $t.bg 0.14
    return $t
}

# Couleurs vives des icônes (fond sombre, quel que soit le thème).
$IconColors = @{ green = (Rgb 0x33d17a); orange = (Rgb 0xff7800); red = (Rgb 0xed333b); time = (Rgb 0x9a9a9a) }

function Get-Scale {
    $g = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero)
    try { return $g.DpiX / 96.0 } finally { $g.Dispose() }
}

function RoundedPath([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $r = [Math]::Max(0.5, [Math]::Min($r, [Math]::Min($w, $h) / 2))
    $d = 2 * $r
    $p.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90)
    $p.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
    $p.AddArc([single]($x + $w - $d), [single]($y + $h - $d), [single]$d, [single]$d, 0, 90)
    $p.AddArc([single]$x, [single]($y + $h - $d), [single]$d, [single]$d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Fill-Rounded($g, [Drawing.Color]$color, $x, $y, $w, $h, $r) {
    if ($w -le 0 -or $h -le 0) { return }
    $path = RoundedPath $x $y $w $h $r
    $brush = New-Object Drawing.SolidBrush $color
    $g.FillPath($brush, $path)
    $brush.Dispose(); $path.Dispose()
}

# ── Icônes de la zone de notification ────────────────────────────────────────
# Tuile sombre, nombre coloré (vert / orange / rouge) et petite barre de progression.
function New-TrayBitmap([string]$text, [double]$fraction, [string]$level) {
    $size = [Windows.Forms.SystemInformation]::SmallIconSize.Width
    $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([Drawing.Color]::Transparent)
    Fill-Rounded $g ([Drawing.Color]::FromArgb(240, 30, 30, 30)) 0 0 $size $size ([Math]::Max(2.0, $size / 5))

    $color = $IconColors[$level]
    $pad = [Math]::Max(2.0, [Math]::Round($size / 8))
    $barH = [Math]::Max(2.0, [Math]::Round($size / 9))
    $barY = $size - $pad - $barH + 1
    $trackW = $size - 2 * $pad
    Fill-Rounded $g ([Drawing.Color]::FromArgb(80, 255, 255, 255)) $pad $barY $trackW $barH ($barH / 2)
    if ($fraction -gt 0) {
        $fillW = [Math]::Max($barH, $trackW * [Math]::Min(1.0, $fraction))
        Fill-Rounded $g $color $pad $barY $fillW $barH ($barH / 2)
    }

    if ($text.Length -le 1) { $em = 0.74 } else { $em = 0.66 }
    $font = New-Object Drawing.Font('Segoe UI', [single]($size * $em), [Drawing.FontStyle]::Bold, [Drawing.GraphicsUnit]::Pixel)
    $format = New-Object Drawing.StringFormat
    $format.Alignment = [Drawing.StringAlignment]::Center
    $format.LineAlignment = [Drawing.StringAlignment]::Center
    $brush = New-Object Drawing.SolidBrush $color
    $box = New-Object Drawing.RectangleF(0, -1, $size, $barY)
    $g.DrawString($text, $font, $brush, $box, $format)
    $brush.Dispose(); $format.Dispose(); $font.Dispose(); $g.Dispose()
    return $bmp
}

function Set-TrayIcon($notify, [string]$text, [double]$fraction, [string]$level, [string]$tooltip) {
    $bmp = New-TrayBitmap $text $fraction $level
    $handle = $bmp.GetHicon()
    $bmp.Dispose()
    $old = $notify.Tag
    $notify.Icon = [Drawing.Icon]::FromHandle($handle)
    $notify.Tag = $handle
    if ($old) { [void][ClaudeBudgetNative]::DestroyIcon([IntPtr]$old) }
    if ($tooltip.Length -gt 63) { $tooltip = $tooltip.Substring(0, 62) + '…' }
    $notify.Text = $tooltip
}

function Short([double]$value) {
    if ([double]::IsInfinity($value) -or [double]::IsNaN($value)) { return '!' }
    $n = JsRound $value
    if ($n -ge 100) { return '!' }
    return [string][int]$n
}

function Update-Tray {
    if ($script:Last) {
        $status = $script:Last.status; $usage = $script:Last.usage
        $p = $status.progress; $u = [double]$usage.utilization
        Set-TrayIcon $script:DayIcon (Short $p) (barFraction $p) (barLevel $p) `
            (Tr 'tooltipDay' (progressText $p $Lang) (fmtPct $status.usedToday $Lang) (pctText $status.todayBudget $Lang))
        Set-TrayIcon $script:WeekIcon (Short $u) ($u / 100) (barLevel $u) `
            (Tr 'tooltipWeek' (pctText $u $Lang) (dayLabel (localKey $usage.resetAt) $Lang) (hhmm $usage.resetAt))
    } else {
        if ($script:LastError) { $tip = "Claude · ⚠ $($script:LastError)" } else { $tip = Tr 'waiting' }
        Set-TrayIcon $script:DayIcon '?' 0 'time' $tip
        Set-TrayIcon $script:WeekIcon '?' 0 'time' $tip
    }
}

# ── Panneau de détail (clic sur une icône) ───────────────────────────────────
# Lignes : bar (libellé, valeur, barre), header, sep, info, action.
function Build-PanelRows {
    $rows = New-Object Collections.ArrayList
    $add = { param($h) [void]$rows.Add($h) }
    if ($script:Last) {
        $status = $script:Last.status; $usage = $script:Last.usage; $now = $script:Last.now
        $p = $status.progress; $u = [double]$usage.utilization
        if ($status.today) { $todayKey = Tr 'todayOf' (dayLabel $status.today.key $Lang) } else { $todayKey = Tr 'today' }
        & $add @{ type = 'bar'; key = $todayKey; fraction = (barFraction $p); level = (barLevel $p)
            value = (Tr 'todayValue' (fmtPct $status.usedToday $Lang) (pctText $status.todayBudget $Lang) (progressText $p $Lang)) }
        & $add @{ type = 'bar'; key = (Tr 'week'); fraction = ($u / 100); level = (barLevel $u)
            value = (Tr 'weekValue' (pctText $u $Lang) (pctText (100 - $u) $Lang)) }
        $elapsed = weekElapsed $now $usage.resetAt
        & $add @{ type = 'bar'; key = (Tr 'reset'); fraction = $elapsed; level = 'time'
            value = (Tr 'resetValue' (dayLabel (localKey $usage.resetAt) $Lang) (hhmm $usage.resetAt) (pctText (JsRound ($elapsed * 100)) $Lang)) }
        if ($null -eq $usage.session) {
            & $add @{ type = 'bar'; key = (Tr 'session'); value = '—'; fraction = 0; level = 'green' }
        } else {
            $sv = [double]$usage.session
            & $add @{ type = 'bar'; key = (Tr 'session'); value = (pctText $sv $Lang); fraction = ($sv / 100); level = (barLevel $sv) }
        }
        & $add @{ type = 'header'; text = (Tr 'upcomingHeader') }
        $upcoming = @($status.upcoming)
        if ($upcoming.Count -eq 0) { & $add @{ type = 'info'; key = (Tr 'lastDay'); value = '' } }
        $lengths = planFractions $status.todayBudget $upcoming
        for ($i = 0; $i -lt $upcoming.Count; $i++) {
            $d = $upcoming[$i]
            $title = dayLabel $d.key $Lang
            if ($d.weekend) { $title += Tr 'weekendSuffix' }
            elseif ([double]$d.weight -lt 1) { $title += Tr 'untilSuffix' (hhmm $usage.resetAt) }
            & $add @{ type = 'bar'; key = $title; value = (pctText $d.budget $Lang); fraction = $lengths[$i]
                level = (barLevel ($lengths[$i] * 100)) }
        }
        & $add @{ type = 'sep' }
    }
    if ($script:LastError) {
        & $add @{ type = 'info'; key = "⚠ $($script:LastError)"; value = (hhmm $script:LastErrorAt) }
    } elseif ($script:Last) {
        if ($script:Last.usage.source -eq 'cli') { $k = Tr 'updatedViaCli' } else { $k = Tr 'updated' }
        & $add @{ type = 'info'; key = $k; value = (hhmm $script:Last.now) }
    } else {
        & $add @{ type = 'info'; key = (Tr 'waiting'); value = '' }
    }
    & $add @{ type = 'action'; text = (Tr 'viewWeek'); action = 'week' }
    & $add @{ type = 'action'; text = (Tr 'refreshNow'); action = 'refresh' }
    & $add @{ type = 'action'; text = (Tr 'quit'); action = 'quit' }
    return , $rows.ToArray()
}

$RowHeights = @{ bar = 52; header = 34; sep = 13; info = 34; action = 34 }

function Layout-Panel($form) {
    $s = Get-Scale
    $script:PanelRows = Build-PanelRows
    $y = 8 * $s
    foreach ($row in $script:PanelRows) {
        $row.y = $y
        $row.h = $RowHeights[$row.type] * $s
        $y += $row.h
    }
    $form.ClientSize = New-Object Drawing.Size([int](392 * $s), [int]($y + 8 * $s))
    $area = [Windows.Forms.Screen]::FromPoint([Windows.Forms.Cursor]::Position).WorkingArea
    $margin = [int](12 * $s)
    $form.Location = New-Object Drawing.Point(($area.Right - $form.Width - $margin), ($area.Bottom - $form.Height - $margin))
}

$TextLeft = [Windows.Forms.TextFormatFlags]'Left, VerticalCenter, SingleLine, EndEllipsis, NoPrefix'
$TextRight = [Windows.Forms.TextFormatFlags]'Right, VerticalCenter, SingleLine, NoPrefix'

function Paint-Panel($g, $form) {
    $s = Get-Scale
    $t = $script:Theme
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.Clear($t.bg)
    $pen = New-Object Drawing.Pen $t.border
    $g.DrawRectangle($pen, 0, 0, $form.ClientSize.Width - 1, $form.ClientSize.Height - 1)
    $pen.Dispose()
    $padX = 16 * $s
    $width = $form.ClientSize.Width
    foreach ($row in $script:PanelRows) {
        $y = $row.y
        switch ($row.type) {
            'bar' {
                $line = New-Object Drawing.Rectangle([int]$padX, [int]($y + 6 * $s), [int]($width - 2 * $padX), [int](22 * $s))
                $valueSize = [Windows.Forms.TextRenderer]::MeasureText($row.value, $script:FontBold)
                $keyBox = New-Object Drawing.Rectangle($line.X, $line.Y, ($line.Width - $valueSize.Width - [int](8 * $s)), $line.Height)
                [Windows.Forms.TextRenderer]::DrawText($g, $row.key, $script:FontNormal, $keyBox, $t.fg, $TextLeft)
                [Windows.Forms.TextRenderer]::DrawText($g, $row.value, $script:FontBold, $line, $t.fg, $TextRight)
                $barY = $y + 33 * $s; $barH = 6 * $s; $barW = $width - 2 * $padX
                Fill-Rounded $g $t.track $padX $barY $barW $barH ($barH / 2)
                if ($row.fraction -gt 0) {
                    $fillW = [Math]::Max($barH, $barW * [Math]::Min(1.0, [double]$row.fraction))
                    Fill-Rounded $g $t[$row.level] $padX $barY $fillW $barH ($barH / 2)
                }
            }
            'header' {
                $box = New-Object Drawing.Rectangle([int]$padX, [int]($y + 8 * $s), [int]($width - 2 * $padX), [int](22 * $s))
                [Windows.Forms.TextRenderer]::DrawText($g, $row.text, $script:FontSmall, $box, $t.dim, $TextLeft)
                $tw = [Windows.Forms.TextRenderer]::MeasureText($row.text, $script:FontSmall).Width
                $ly = [int]($box.Y + $box.Height / 2)
                $pen = New-Object Drawing.Pen $t.line
                if ($padX + $tw + 8 * $s -lt $width - $padX) { $g.DrawLine($pen, [int]($padX + $tw + 8 * $s), $ly, [int]($width - $padX), $ly) }
                $pen.Dispose()
            }
            'sep' {
                $pen = New-Object Drawing.Pen $t.line
                $ly = [int]($y + $row.h / 2)
                $g.DrawLine($pen, [int]$padX, $ly, [int]($width - $padX), $ly)
                $pen.Dispose()
            }
            'info' {
                $box = New-Object Drawing.Rectangle([int]$padX, [int]$y, [int]($width - 2 * $padX), [int]$row.h)
                $valueW = [Windows.Forms.TextRenderer]::MeasureText($row.value, $script:FontBold).Width
                $keyBox = New-Object Drawing.Rectangle($box.X, $box.Y, ($box.Width - $valueW - [int](8 * $s)), $box.Height)
                [Windows.Forms.TextRenderer]::DrawText($g, $row.key, $script:FontNormal, $keyBox, $t.fg, $TextLeft)
                [Windows.Forms.TextRenderer]::DrawText($g, $row.value, $script:FontBold, $box, $t.fg, $TextRight)
            }
            'action' {
                if ($script:Hover -eq $row) {
                    Fill-Rounded $g $t.hover (6 * $s) ($y + 2 * $s) ($width - 12 * $s) ($row.h - 4 * $s) (5 * $s)
                }
                $box = New-Object Drawing.Rectangle([int]$padX, [int]$y, [int]($width - 2 * $padX), [int]$row.h)
                [Windows.Forms.TextRenderer]::DrawText($g, $row.text, $script:FontNormal, $box, $t.fg, $TextLeft)
            }
        }
    }
}

function Row-At([int]$y) {
    foreach ($row in $script:PanelRows) {
        if ($row.type -eq 'action' -and $y -ge $row.y -and $y -lt $row.y + $row.h) { return $row }
    }
    return $null
}

function Enable-DoubleBuffer($control) {
    $prop = $control.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance, NonPublic')
    $prop.SetValue($control, $true, $null)
}

function Set-RoundCorners($form) {
    try { $v = 2; [void][ClaudeBudgetNative]::DwmSetWindowAttribute($form.Handle, 33, [ref]$v, 4) } catch { }
}

function Set-DarkTitleBar($form) {
    if ($script:Theme.light) { return }
    try { $v = 1; [void][ClaudeBudgetNative]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4) } catch { }
}

$script:Panel = $null
$script:PanelClosedAt = 0
$script:Hover = $null

function Close-Panel {
    if ($script:Panel -and -not $script:Panel.IsDisposed) {
        $script:PanelClosedAt = [Environment]::TickCount
        $script:Panel.Close()
    }
    $script:Panel = $null
}

function Toggle-Panel {
    if ($script:Panel -and -not $script:Panel.IsDisposed) { Close-Panel; return }
    # Le clic qui vient de fermer le panneau (perte du focus) ne doit pas le rouvrir.
    if ([Environment]::TickCount - $script:PanelClosedAt -lt 400) { return }
    Show-Panel
}

function Show-Panel {
    $script:Theme = Get-Theme
    $form = New-Object Windows.Forms.Form
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::None
    $form.ShowInTaskbar = $false
    $form.TopMost = $true
    $form.StartPosition = [Windows.Forms.FormStartPosition]::Manual
    $form.KeyPreview = $true
    $form.Text = Tr 'title'
    Enable-DoubleBuffer $form
    Layout-Panel $form
    $form.Add_Paint({ param($src, $e) try { Paint-Panel $e.Graphics $src } catch { Write-Log "panneau : $_" } })
    $form.Add_MouseMove({ param($src, $e)
        $row = Row-At $e.Y
        if ($row -ne $script:Hover) { $script:Hover = $row; $src.Invalidate() }
        if ($row) { $src.Cursor = [Windows.Forms.Cursors]::Hand } else { $src.Cursor = [Windows.Forms.Cursors]::Default }
    })
    $form.Add_MouseLeave({ param($src, $e) $script:Hover = $null; $src.Invalidate() })
    $form.Add_MouseClick({ param($src, $e)
        $row = Row-At $e.Y
        if (-not $row) { return }
        switch ($row.action) {
            'week' { Close-Panel; Show-Week }
            'refresh' { Start-Refresh }
            'quit' { Quit-App }
        }
    })
    $form.Add_KeyDown({ param($src, $e) if ($e.KeyCode -eq [Windows.Forms.Keys]::Escape) { Close-Panel } })
    if (-not $script:KeepPanel) { $form.Add_Deactivate({ Close-Panel }) }
    $script:Panel = $form
    $form.Show()
    [void][ClaudeBudgetNative]::ShowWindow($form.Handle, 9) # SW_RESTORE (voir Show-Week)
    Set-RoundCorners $form
    $form.Activate()
}

function Refresh-Panel {
    if ($script:Panel -and -not $script:Panel.IsDisposed) {
        Layout-Panel $script:Panel
        $script:Panel.Invalidate()
    }
}

# ── Graphique de la semaine (portage de chart.js) ────────────────────────────
$USED = Rgb 0x3584e4
$OVER = Rgb 0xe66100

function Top-Rounded([double]$x, [double]$y, [double]$w, [double]$h, [double]$r) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $r = [Math]::Max(0.5, [Math]::Min($r, [Math]::Min($w / 2, $h)))
    $d = 2 * $r
    $p.AddLine([single]$x, [single]($y + $h), [single]$x, [single]($y + $r))
    $p.AddArc([single]$x, [single]$y, [single]$d, [single]$d, 180, 90)
    $p.AddArc([single]($x + $w - $d), [single]$y, [single]$d, [single]$d, 270, 90)
    $p.AddLine([single]($x + $w), [single]($y + $r), [single]($x + $w), [single]($y + $h))
    $p.CloseFigure()
    return $p
}

function Draw-WeekChart($g, [double]$left, [double]$top, [double]$width, [double]$height, $chart, [string]$resetTime) {
    $s = Get-Scale
    $t = $script:Theme
    $ink = { param([double]$a) return (Mix $t.fg $t.bg $a) }
    $fonts = @{}
    $font = {
        param([double]$size, [bool]$bold)
        $k = "$size-$bold"
        if (-not $fonts.ContainsKey($k)) {
            if ($bold) { $style = [Drawing.FontStyle]::Bold } else { $style = [Drawing.FontStyle]::Regular }
            $fonts[$k] = New-Object Drawing.Font('Segoe UI', [single](10.5 * $size), $style)
        }
        return $fonts[$k]
    }
    $flags = [Windows.Forms.TextFormatFlags]'NoPadding, SingleLine, NoPrefix'
    $measure = { param([string]$str, [double]$size, [bool]$bold)
        return [Windows.Forms.TextRenderer]::MeasureText($g, $str, (& $font $size $bold), (New-Object Drawing.Size(9999, 9999)), $flags) }
    $text = {
        param([string]$str, [double]$x, [double]$y, [double]$size, [bool]$bold, [double]$alpha, [string]$align, [string]$valign)
        $m = & $measure $str $size $bold
        $tx = $x; $ty = $y
        if ($align -eq 'center') { $tx = $x - $m.Width / 2 } elseif ($align -eq 'right') { $tx = $x - $m.Width }
        if ($valign -eq 'bottom') { $ty = $y - $m.Height } elseif ($valign -eq 'middle') { $ty = $y - $m.Height / 2 }
        [Windows.Forms.TextRenderer]::DrawText($g, $str, (& $font $size $bold), (New-Object Drawing.Point([int]$tx, [int]$ty)), (& $ink $alpha), $flags)
        return $m.Width
    }

    $days = @($chart.days)
    $gaps = @($chart.gaps)
    $colW = 24 * $s; $radius = 4 * $s; $gapPx = 2 * $s
    $plotLeft = $left + 50 * $s
    $plotRight = $left + $width - 8 * $s
    $plotTop = $top + 38 * $s
    $baseline = $top + $height - 82 * $s
    $slot = ($plotRight - $plotLeft) / $days.Count
    $values = @(foreach ($d in $days) { if ($null -ne $d.budget) { [double]$d.budget } else { 0 }; if ($null -ne $d.used) { [double]$d.used } else { 0 } })
    $maxValue = 0.0
    foreach ($v in $values) { if ($v -gt $maxValue) { $maxValue = $v } }
    $scale = chartScale $maxValue
    $yOf = { param([double]$v) return $baseline - ($v / $scale.max) * ($baseline - $plotTop) }
    $cx = { param([int]$i) return $plotLeft + $slot * ($i + 0.5) }

    # Fond discret derrière la colonne du jour.
    for ($i = 0; $i -lt $days.Count; $i++) {
        if ($days[$i].kind -eq 'today') {
            Fill-Rounded $g (& $ink 0.05) ($plotLeft + $slot * $i + 2) ($plotTop - 30 * $s) ($slot - 4) ($baseline - $plotTop + 70 * $s) (8 * $s)
        }
    }

    # Grille et graduations.
    for ($v = 0.0; $v -le $scale.max + 1e-9; $v += $scale.step) {
        $y = [Math]::Round((& $yOf $v)) + 0.5
        if ($v -eq 0) { $a = 0.25 } else { $a = 0.08 }
        $pen = New-Object Drawing.Pen (& $ink $a)
        $g.DrawLine($pen, [single]$plotLeft, [single]$y, [single]$plotRight, [single]$y)
        $pen.Dispose()
        if ($v -eq 0) { $label = '0' } else { $label = pctText $v $Lang }
        [void](& $text $label ($plotLeft - 8 * $s) $y 0.8 $false 0.55 'right' 'middle')
    }

    # Colonnes.
    for ($i = 0; $i -lt $days.Count; $i++) {
        $d = $days[$i]
        $x = (& $cx $i) - $colW / 2
        if ($d.kind -eq 'future') {
            $topY = & $yOf ([double]$d.budget)
            if ($baseline - $topY -ge 1) {
                $pen = New-Object Drawing.Pen((& $ink 0.4), [single](1.5 * $s))
                $pen.DashPattern = [single[]]@(2, 2)
                $path = Top-Rounded ($x + 0.75) ($topY + 0.75) ($colW - 1.5) ($baseline - $topY - 0.75) $radius
                $g.DrawPath($pen, $path)
                $path.Dispose(); $pen.Dispose()
            }
            [void](& $text (fmtPct $d.budget $Lang) (& $cx $i) ($topY - 4 * $s) 0.85 $false 0.55 'center' 'bottom')
            continue
        }
        if ($d.kind -ne 'past' -and $d.kind -ne 'today') { continue }
        $budget = [double]$d.budget; $used = [double]$d.used
        $budgetTop = & $yOf $budget
        $usedTop = & $yOf $used
        if ($baseline - $budgetTop -ge 1) {
            $path = Top-Rounded $x $budgetTop $colW ($baseline - $budgetTop) $radius
            $brush = New-Object Drawing.SolidBrush (& $ink 0.14); $g.FillPath($brush, $path); $brush.Dispose(); $path.Dispose()
        }
        if ($used -le $budget) {
            if ($baseline - $usedTop -ge 0.5) {
                $path = Top-Rounded $x $usedTop $colW ($baseline - $usedTop) $radius
                $brush = New-Object Drawing.SolidBrush $USED; $g.FillPath($brush, $path); $brush.Dispose(); $path.Dispose()
            }
        } else {
            if ($baseline - $budgetTop -ge 0.5) {
                $brush = New-Object Drawing.SolidBrush $USED
                $g.FillRectangle($brush, [single]$x, [single]$budgetTop, [single]$colW, [single]($baseline - $budgetTop))
                $brush.Dispose()
            }
            if ($budget -gt 0) { $overBottom = $budgetTop - $gapPx } else { $overBottom = $budgetTop }
            if ($overBottom - $usedTop -ge 0.5) {
                $path = Top-Rounded $x $usedTop $colW ($overBottom - $usedTop) $radius
                $brush = New-Object Drawing.SolidBrush $OVER; $g.FillPath($brush, $path); $brush.Dispose(); $path.Dispose()
            }
        }
        $capTop = [Math]::Min($budgetTop, $usedTop)
        $isToday = $d.kind -eq 'today'
        $usedText = fmtPct $used $Lang
        $rest = " / $(fmtPct $budget $Lang)"
        $wUsed = (& $measure $usedText 0.85 $true).Width
        $wRest = (& $measure $rest 0.85 $false).Width
        $lx = (& $cx $i) - ($wUsed + $wRest) / 2
        if ($isToday) { $a = 1 } else { $a = 0.9 }
        [void](& $text $usedText $lx ($capTop - 4 * $s) 0.85 $true $a 'left' 'bottom')
        [void](& $text $rest ($lx + $wUsed) ($capTop - 4 * $s) 0.85 $false 0.6 'left' 'bottom')
    }

    # Blocs des jours sans relevé.
    foreach ($gp in $gaps) {
        $x0 = $plotLeft + $slot * $gp.from + 6 * $s
        $x1 = $plotLeft + $slot * ($gp.to + 1) - 6 * $s
        $gTop = $plotTop + ($baseline - $plotTop) * 0.2
        Fill-Rounded $g (& $ink 0.04) $x0 $gTop ($x1 - $x0) ($baseline - $gTop) (6 * $s)
        $pen = New-Object Drawing.Pen (& $ink 0.22)
        $pen.DashPattern = [single[]]@(4, 4)
        $path = RoundedPath $x0 $gTop ($x1 - $x0) ($baseline - $gTop) (6 * $s)
        $g.DrawPath($pen, $path); $path.Dispose(); $pen.Dispose()
        $mid = ($x0 + $x1) / 2
        $midY = ($gTop + $baseline) / 2
        $span = $gp.to - $gp.from + 1
        if ($span -gt 1) { $total = Tr 'chartTotal' (pctText $gp.total $Lang); $note = Tr 'chartUntrackedDays' }
        else { $total = pctText $gp.total $Lang; $note = Tr 'chartUntracked' }
        $room = $x1 - $x0 - 8 * $s
        if ((& $measure $total 1 $true).Width -le $room) { $size = 1 } else { $size = 0.8 }
        [void](& $text $total $mid ($midY - 2 * $s) $size $true 0.85 'center' 'bottom')
        if ((& $measure $note 0.8 $false).Width -le $room) { [void](& $text $note $mid ($midY + 2 * $s) 0.8 $false 0.55 'center' 'top') }
    }

    # Jours sous l'axe.
    $last = $days.Count - 1
    for ($i = 0; $i -lt $days.Count; $i++) {
        $d = $days[$i]
        $isToday = $d.kind -eq 'today'
        if ($isToday) { $a = 1 } else { $a = 0.75 }
        [void](& $text (dayLabel $d.key $Lang) (& $cx $i) ($baseline + 8 * $s) 0.9 $isToday $a 'center' 'top')
        $sub = $null
        if ($isToday) { $sub = Tr 'chartToday' }
        elseif ($i -eq 0 -and [double]$d.weight -lt 1) { $sub = Tr 'chartFrom' $resetTime }
        elseif ($i -eq $last -and [double]$d.weight -lt 1) { $sub = Tr 'chartUntil' $resetTime }
        if ($sub) { [void](& $text $sub (& $cx $i) ($baseline + 8 * $s + 17 * $s) 0.75 $false 0.5 'center' 'top') }
    }

    # Légende.
    $ly = $top + $height - 14 * $s
    $lx = $plotLeft
    $items = @(
        @{ label = (Tr 'legendUsed'); kind = 'used' },
        @{ label = (Tr 'legendBudget'); kind = 'budget' },
        @{ label = (Tr 'legendOver'); kind = 'over' },
        @{ label = (Tr 'legendPlanned'); kind = 'planned' })
    foreach ($item in $items) {
        $sw = 10 * $s; $sy = $ly - 5 * $s
        switch ($item.kind) {
            'used' { Fill-Rounded $g $USED $lx $sy $sw $sw (2 * $s) }
            'budget' { Fill-Rounded $g (& $ink 0.14) $lx $sy $sw $sw (2 * $s) }
            'over' { Fill-Rounded $g $OVER $lx $sy $sw $sw (2 * $s) }
            'planned' {
                $pen = New-Object Drawing.Pen((& $ink 0.45), [single](1.2 * $s))
                $pen.DashPattern = [single[]]@(2, 2)
                $path = RoundedPath ($lx + 0.6) ($sy + 0.6) ($sw - 1.2) ($sw - 1.2) (2 * $s)
                $g.DrawPath($pen, $path); $path.Dispose(); $pen.Dispose()
            }
        }
        $lx += 16 * $s
        $lx += (& $text $item.label $lx $ly 0.85 $false 0.75 'left' 'middle') + 20 * $s
    }
    foreach ($f in $fonts.Values) { $f.Dispose() }
}

$script:WeekForm = $null

function Show-Week {
    if ($script:WeekForm -and -not $script:WeekForm.IsDisposed) { $script:WeekForm.Activate(); return }
    $script:Theme = Get-Theme
    $s = Get-Scale
    $form = New-Object Windows.Forms.Form
    $form.Text = Tr 'chartTitle'
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedSingle
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.ClientSize = New-Object Drawing.Size([int](720 * $s), [int](500 * $s))
    $form.BackColor = $script:Theme.bg
    $form.KeyPreview = $true
    Enable-DoubleBuffer $form
    $button = New-Object Windows.Forms.Button
    $button.Text = Tr 'close'
    $button.Size = New-Object Drawing.Size([int](96 * $s), [int](30 * $s))
    $button.Location = New-Object Drawing.Point(($form.ClientSize.Width - $button.Width - [int](16 * $s)), ($form.ClientSize.Height - $button.Height - [int](12 * $s)))
    $button.FlatStyle = [Windows.Forms.FlatStyle]::System
    $button.Add_Click({ $script:WeekForm.Close() })
    $form.Controls.Add($button)
    $form.AcceptButton = $button
    $form.CancelButton = $button
    $form.Add_Paint({ param($src, $e)
        try {
            $g = $e.Graphics
            $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
            $sc = Get-Scale
            $t = $script:Theme
            $w = $src.ClientSize.Width
            if (-not $script:Last) {
                [Windows.Forms.TextRenderer]::DrawText($g, (Tr 'waiting'), $script:FontNormal, (New-Object Drawing.Point([int](20 * $sc), [int](20 * $sc))), $t.fg)
                return
            }
            $status = $script:Last.status; $usage = $script:Last.usage; $now = $script:Last.now
            $chart = weekChart @{ state = $script:State; status = $status; resetAt = $usage.resetAt }
            $days = @($chart.days)
            $title = Tr 'chartTitle'
            if ($days.Count -gt 0) { $title = Tr 'chartTitleRange' (dayLabel $days[0].key $Lang) (dayLabel $days[$days.Count - 1].key $Lang) }
            $flags = [Windows.Forms.TextFormatFlags]'HorizontalCenter, SingleLine, NoPrefix, EndEllipsis'
            [Windows.Forms.TextRenderer]::DrawText($g, $title, $script:FontTitle, (New-Object Drawing.Rectangle(0, [int](16 * $sc), $w, [int](30 * $sc))), $t.fg, $flags)
            $summary = Tr 'chartSummary' (pctText $usage.utilization $Lang) (pctText (100 - [double]$usage.utilization) $Lang) (dayLabel (localKey $usage.resetAt) $Lang) (hhmm $usage.resetAt)
            [Windows.Forms.TextRenderer]::DrawText($g, $summary, $script:FontNormal, (New-Object Drawing.Rectangle(0, [int](48 * $sc), $w, [int](22 * $sc))), $t.dim, $flags)
            Draw-WeekChart $g (20 * $sc) (78 * $sc) ($w - 40 * $sc) (330 * $sc) $chart (hhmm $usage.resetAt)
            [Windows.Forms.TextRenderer]::DrawText($g, (Tr 'chartFooter' (hhmm $now)), $script:FontSmall, (New-Object Drawing.Rectangle(0, [int](414 * $sc), $w, [int](20 * $sc))), $t.dim, $flags)
        } catch { Write-Log "graphique : $_ $($_.InvocationInfo.PositionMessage)" }
    })
    $form.Add_FormClosed({ $script:WeekForm = $null })
    $script:WeekForm = $form
    $form.Show()
    # Lancé caché ou réduit (raccourci de démarrage), Windows applique cet état à la
    # première fenêtre normale affichée : on la remet explicitement à l'écran.
    [void][ClaudeBudgetNative]::ShowWindow($form.Handle, 9) # SW_RESTORE
    Set-DarkTitleBar $form
    $form.Activate()
}

# ── Données : API, puis secours `claude /usage` ──────────────────────────────
function Find-Claude {
    $candidates = @((Join-Path $env:USERPROFILE '.local\bin\claude.exe'))
    if ($env:APPDATA) { $candidates += (Join-Path $env:APPDATA 'npm\claude.cmd') }
    foreach ($c in $candidates) { if (Test-Path -LiteralPath $c) { return $c } }
    foreach ($name in @('claude.exe', 'claude.cmd')) {
        $cmd = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

# Tourne dans un runspace à part pour ne pas figer l'icône ; renvoie les réponses brutes.
$WorkerScript = {
    param($credPath, $url, $claudePath, $allowProbe)
    $r = @{ api = $null; apiError = $null; probe = $null; probeError = $null }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $token = $null; $expired = $false
        if (Test-Path -LiteralPath $credPath) {
            $creds = ([IO.File]::ReadAllText($credPath) | ConvertFrom-Json).claudeAiOauth
            if ($creds) {
                $token = $creds.accessToken
                if ($creds.expiresAt -and [double]$creds.expiresAt -lt [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()) { $expired = $true }
            }
        }
        if (-not $token) { $r.apiError = 'nologin' }
        elseif ($expired) { $r.apiError = 'expired' }
        else {
            $req = [Net.HttpWebRequest]::Create($url)
            $req.Method = 'GET'; $req.Timeout = 20000; $req.Accept = 'application/json'
            $req.UserAgent = 'claude-budget-windows/1'
            $req.Headers.Add('Authorization', "Bearer $token")
            $req.Headers.Add('anthropic-beta', 'oauth-2025-04-20')
            $resp = $null
            try { $resp = $req.GetResponse() } catch [Net.WebException] { $resp = $_.Exception.Response }
            if ($resp) {
                $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
                $r.api = @{ status = [int]$resp.StatusCode; body = $reader.ReadToEnd() }
                $reader.Close(); $resp.Close()
            } else { $r.apiError = 'network' }
        }
    } catch { $r.apiError = 'network'; $r.apiDetail = "$_" }

    $apiOk = ($null -ne $r.api) -and ($r.api.status -eq 200)
    if (-not $apiOk -and $allowProbe) {
        if (-not $claudePath) { $r.probeError = 'claude introuvable' }
        else {
            try {
                $psi = New-Object Diagnostics.ProcessStartInfo
                $cliArgs = '-p --no-session-persistence --strict-mcp-config /usage'
                if ($claudePath -match '\.(cmd|bat)$') {
                    $psi.FileName = $env:ComSpec
                    $psi.Arguments = "/d /s /c `"`"$claudePath`" $cliArgs`""
                } else {
                    $psi.FileName = $claudePath
                    $psi.Arguments = $cliArgs
                }
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.RedirectStandardInput = $true
                $psi.RedirectStandardOutput = $true
                $psi.RedirectStandardError = $true
                $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
                $psi.WorkingDirectory = $env:USERPROFILE
                $psi.EnvironmentVariables['WEEKLY_BUDGET_PROBE'] = '1'
                $p = [Diagnostics.Process]::Start($psi)
                $p.StandardInput.Close()
                $out = $p.StandardOutput.ReadToEndAsync()
                $err = $p.StandardError.ReadToEndAsync()
                if (-not $p.WaitForExit(60000)) {
                    try { $p.Kill() } catch { }
                    $r.probeError = 'trop long, arrêté'
                } else {
                    $r.probe = @{ exit = $p.ExitCode; out = $out.Result }
                }
            } catch { $r.probeError = "$_" }
        }
    }
    return $r
}

$script:State = $null
$script:StateLoaded = $false
$script:SavedJson = $null
$script:Last = $null
$script:LastError = $null
$script:LastErrorAt = 0
$script:ProbedAt = -1e12
$script:Worker = $null

function Load-State {
    try {
        if (Test-Path -LiteralPath $StatePath) {
            $json = [IO.File]::ReadAllText($StatePath, [Text.Encoding]::UTF8)
            $script:SavedJson = $json
            $state = ConvertTo-Hash ($json | ConvertFrom-Json)
            if ($state -is [hashtable] -and $state.dayKey) {
                if ($null -eq $state.notified) { $state.notified = @() }
                return $state
            }
        }
    } catch { Write-Log "état illisible : $_" }
    return $null
}

function Save-State {
    try {
        $json = $script:State | ConvertTo-Json -Depth 10 -Compress
        if ($json -eq $script:SavedJson) { return }
        [IO.File]::WriteAllText($StatePath, $json, (New-Object Text.UTF8Encoding $false))
        $script:SavedJson = $json
    } catch { Write-Log "état non enregistré : $_" }
}

function Start-Refresh {
    if ($Demo) { Apply-Usage (Get-DemoUsage) (NowMs); return }
    if ($script:Worker) { return }
    if (-not $script:StateLoaded) { $script:State = Load-State; $script:StateLoaded = $true }
    $allowProbe = ((NowMs) - $script:ProbedAt) -ge $PROBE_MIN_MS
    $ps = [PowerShell]::Create()
    [void]$ps.AddScript($WorkerScript.ToString()).AddArgument($CredPath).AddArgument($USAGE_URL).AddArgument((Find-Claude)).AddArgument($allowProbe)
    $script:Worker = @{ ps = $ps; handle = $ps.BeginInvoke() }
}

function Api-Error($r) {
    switch ($r.apiError) {
        'nologin' { return Tr 'errNoLogin' }
        'expired' { return Tr 'errExpired' }
        'network' { return Tr 'errNetwork' }
    }
    if ($r.api) {
        if ($r.api.status -eq 401) { return Tr 'errExpired' }
        if ($r.api.status -eq 429) { return Tr 'errTooMany' }
        return Tr 'errHttp' $r.api.status
    }
    return Tr 'errUnexpected'
}

function Handle-Result($r) {
    $now = NowMs
    if ($r.probe -or $r.probeError) { $script:ProbedAt = $now }
    $usage = $null
    $message = $null
    if ($r.api -and $r.api.status -eq 200) {
        try {
            $data = $r.api.body | ConvertFrom-Json
            $week = $data.seven_day
            if ($week -and $null -ne $week.utilization -and $week.resets_at) {
                $resets = $week.resets_at
                if ($resets -is [DateTime]) { $resets = $resets.ToUniversalTime().ToString('o') }
                $session = $null
                if ($data.five_hour -and $null -ne $data.five_hour.utilization) { $session = [double]$data.five_hour.utilization }
                $usage = @{ utilization = [double]$week.utilization; resetAt = (normalizeReset ([string]$resets)); session = $session; source = 'api' }
            } else { $message = Tr 'errUnexpected' }
        } catch { $message = Tr 'errUnexpected'; Write-Log "réponse API : $_" }
    } else {
        $message = Api-Error $r
    }
    if (-not $usage -and $r.probe) {
        $parsed = $null
        if ($r.probe.exit -eq 0) { $parsed = parseUsageText $r.probe.out $now }
        if ($parsed) {
            if ($script:State) { $known = $script:State.resetAt } else { $known = $null }
            $resetAt = pickReset $known $parsed.resetAt $now
            if ($null -ne $resetAt) {
                $usage = @{ utilization = $parsed.utilization; resetAt = $resetAt; session = $parsed.session; source = 'cli' }
            } else { Write-Log 'claude /usage : date de remise à zéro illisible' }
        } else {
            Write-Log "claude /usage : code $($r.probe.exit), $($r.probe.out)"
        }
    }
    if ($r.probeError) { Write-Log "claude /usage : $($r.probeError)" }
    if ($usage) {
        Apply-Usage $usage $now
    } else {
        Write-Log "erreur : $message $($r.apiDetail)"
        $script:LastError = $message
        $script:LastErrorAt = $now
        Update-Tray
        Refresh-Panel
        if ($r.apiError -eq 'network') { $script:RetryTimer.Start() }
    }
}

function Notify($level, $status, $usage) {
    $used = pctText $status.usedToday $Lang
    $budget = pctText $status.todayBudget $Lang
    $upcoming = @($status.upcoming)
    if ($upcoming.Count -gt 0) {
        $plan = (@(foreach ($d in $upcoming) { Tr 'planItem' (dayLabel $d.key $Lang) (pctText $d.budget $Lang) })) -join ' · '
    } else { $plan = Tr 'planNone' (hhmm $usage.resetAt) }
    $icon = [Windows.Forms.ToolTipIcon]::Info
    if ($level -eq 'over') {
        $title = Tr 'notifyOverTitle'
        $body = Tr 'notifyOverBody' $used $budget (pctText ($status.usedToday - $status.todayBudget) $Lang) $plan
        $icon = [Windows.Forms.ToolTipIcon]::Warning
    } elseif ("$level" -eq '100') {
        $title = Tr 'notifyFullTitle'
        $body = Tr 'notifyFullBody' $budget $plan
        $icon = [Windows.Forms.ToolTipIcon]::Warning
    } else {
        $title = Tr 'notifyLevelTitle' $level
        $body = Tr 'notifyLevelBody' $used $budget (pctText $usage.utilization $Lang)
    }
    $script:DayIcon.ShowBalloonTip(10000, $title, $body, $icon)
}

function Apply-Usage($usage, $now) {
    $script:State = rollDayState $script:State @{ utilization = $usage.utilization; resetAt = $usage.resetAt; now = $now }
    $status = computeStatus @{ utilization = $usage.utilization; dayStartUtil = $script:State.dayStartUtil; resetAt = $usage.resetAt; now = $now }
    $check = checkThresholds $status.progress $script:State.notified
    if ($null -ne $check.level) {
        $copy = $script:State.Clone()
        $copy.notified = $check.notified
        $script:State = $copy
        if (-not $Demo) { Notify $check.level $status $usage }
    }
    $script:State = recordDay $script:State $status
    if (-not $Demo) { Save-State }
    $script:Last = @{ status = $status; usage = $usage; now = $now }
    $script:LastError = $null
    Update-Tray
    Refresh-Panel
    if ($script:WeekForm -and -not $script:WeekForm.IsDisposed) { $script:WeekForm.Invalidate() }
}

# ── Démonstration : une semaine d'exemple autour d'aujourd'hui ───────────────
# Mêmes règles que le vrai calcul (budget de chaque jour passé alloué au début du jour) ;
# même scénario que les captures GNOME (tools/screenshots/shot@claude-budget/extension.js).
function Get-DemoUsage {
    if ($script:DemoUsage) { return $script:DemoUsage }
    $now = NowMs
    $today = (ToLocal $now).Date
    $todayKey = DayKeyOf $today
    $resetAt = ToMs ($today.AddDays(4).AddHours(15))
    $windowStart = $resetAt - $WEEK_MS
    $factors = @(0.8, 1.18, 0.82, 0.9, 1.05, 0.7)
    $round1 = { param([double]$x) return (JsRound ($x * 10)) / 10 }
    $history = @{}
    $start = 0.0
    $i = 0
    foreach ($d in (daysUntilReset $windowStart $resetAt)) {
        if ([string]::CompareOrdinal($d.key, $todayKey) -ge 0) { break }
        $parts = $d.key.Split('-')
        $midnight = ToMs (New-Object DateTime -ArgumentList @([int]$parts[0], [int]$parts[1], [int]$parts[2]))
        $budget = [double](allocate (100 - $start) (daysUntilReset ([Math]::Max($midnight, $windowStart)) $resetAt))[0]
        $used = & $round1 ($budget * $factors[$i % $factors.Count])
        $history[$d.key] = @{ budget = (& $round1 $budget); start = (& $round1 $start); used = $used }
        $start += $used
        $i++
    }
    $dayStart = & $round1 $start
    $script:State = @{ dayKey = $todayKey; resetAt = $resetAt; dayStartUtil = $dayStart; notified = @(25, 50); history = $history }
    $first = computeStatus @{ utilization = $dayStart; dayStartUtil = $dayStart; resetAt = $resetAt; now = $now }
    $utilization = & $round1 ($dayStart + 0.62 * $first.todayBudget)
    $script:DemoUsage = @{ utilization = $utilization; resetAt = $resetAt; session = 23; source = 'api' }
    return $script:DemoUsage
}

function Quit-App {
    foreach ($timer in @($script:RefreshTimer, $script:PollTimer, $script:RetryTimer)) { if ($timer) { $timer.Stop() } }
    foreach ($icon in @($script:DayIcon, $script:WeekIcon)) {
        if ($icon) {
            $icon.Visible = $false
            if ($icon.Tag) { [void][ClaudeBudgetNative]::DestroyIcon([IntPtr]$icon.Tag) }
            $icon.Dispose()
        }
    }
    $script:Context.ExitThread()
}

# ── Démarrage ────────────────────────────────────────────────────────────────
try {
    $script:Theme = Get-Theme
    $script:FontNormal = New-Object Drawing.Font('Segoe UI', 10)
    $script:FontBold = New-Object Drawing.Font('Segoe UI', 10, [Drawing.FontStyle]::Bold)
    $script:FontSmall = New-Object Drawing.Font('Segoe UI', 9)
    $script:FontTitle = New-Object Drawing.Font('Segoe UI Semibold', 13)
    $script:KeepPanel = [bool]$OpenPanel

    $menu = New-Object Windows.Forms.ContextMenuStrip
    [void]$menu.Items.Add((Tr 'title'), $null, { Toggle-Panel })
    [void]$menu.Items.Add((Tr 'viewWeek'), $null, { Show-Week })
    [void]$menu.Items.Add((Tr 'refreshNow'), $null, { Start-Refresh })
    [void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
    [void]$menu.Items.Add((Tr 'quit'), $null, { Quit-App })

    # Windows place à gauche la première icône affichée : le jour, puis la semaine.
    $script:DayIcon = New-Object Windows.Forms.NotifyIcon
    $script:WeekIcon = New-Object Windows.Forms.NotifyIcon
    foreach ($icon in @($script:WeekIcon, $script:DayIcon)) {
        $icon.ContextMenuStrip = $menu
        $icon.Add_MouseClick({ param($src, $e) if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Toggle-Panel } })
    }
    Update-Tray
    $script:DayIcon.Visible = $true
    $script:WeekIcon.Visible = $true

    $script:RefreshTimer = New-Object Windows.Forms.Timer
    $script:RefreshTimer.Interval = $REFRESH_MS
    $script:RefreshTimer.Add_Tick({ Start-Refresh })
    $script:RetryTimer = New-Object Windows.Forms.Timer
    $script:RetryTimer.Interval = $RETRY_MS
    $script:RetryTimer.Add_Tick({ $script:RetryTimer.Stop(); Start-Refresh })
    $script:PollTimer = New-Object Windows.Forms.Timer
    $script:PollTimer.Interval = 250
    $script:PollTimer.Add_Tick({
        try {
            if ($script:Worker -and $script:Worker.handle.IsCompleted) {
                $w = $script:Worker
                $script:Worker = $null
                $out = $w.ps.EndInvoke($w.handle)
                $w.ps.Dispose()
                if ($out.Count -gt 0) { Handle-Result $out[0] }
            }
        } catch { Write-Log "relevé : $_" }
    })

    $script:StartTimer = New-Object Windows.Forms.Timer
    $script:StartTimer.Interval = 300
    $script:StartTimer.Add_Tick({
        $script:StartTimer.Stop()
        try {
            Start-Refresh
            if ($OpenPanel) { Show-Panel }
            if ($OpenWeek) { Show-Week }
        } catch { Write-Log "démarrage : $_ $($_.InvocationInfo.PositionMessage)" }
    })
    $script:RefreshTimer.Start()
    $script:PollTimer.Start()
    $script:StartTimer.Start()

    $script:Context = New-Object Windows.Forms.ApplicationContext
    [Windows.Forms.Application]::Run($script:Context)
} catch {
    Write-Log "arrêt : $_ $($_.InvocationInfo.PositionMessage)"
    throw
}
