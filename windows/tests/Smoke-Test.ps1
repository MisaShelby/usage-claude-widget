# Starts the widget in demo mode with its panel and week chart open, checks that it keeps
# running for a few seconds and logged no error, then stops it.
$ErrorActionPreference = 'Stop'
# Toute erreur imprévue devient une annotation GitHub (fichier, ligne, message).
trap {
    $where = "$([IO.Path]::GetFileName($_.InvocationInfo.ScriptName)):$($_.InvocationInfo.ScriptLineNumber)"
    $text = "$where $($_.Exception.Message) | $($_.InvocationInfo.Line.Trim())" -replace "`r?`n", ' / '
    Write-Host "::error::$text"
    exit 1
}
$app = (Resolve-Path (Join-Path $PSScriptRoot '..\ClaudeBudget.ps1')).Path
$log = Join-Path $env:LOCALAPPDATA 'ClaudeBudget\widget.log'
if (Test-Path $log) { Remove-Item $log }

# Dessin hors écran : icônes, panneau, graphique (toute erreur de dessin fait échouer).
foreach ($lang in @('en', 'fr')) {
    $dir = Join-Path $env:RUNNER_TEMP "render-$lang"
    if (-not $env:RUNNER_TEMP) { $dir = Join-Path $env:TEMP "render-$lang" }
    $p = Start-Process -FilePath 'powershell.exe' -Wait -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$app`"", '-Demo', '-Lang', $lang, '-Render', "`"$dir`"")
    if (Test-Path $log) {
        Get-Content $log | ForEach-Object { Write-Host "::error::[render $lang] $_" }
        throw "drawing failed ($lang)"
    }
    if ($p.ExitCode -ne 0) { throw "render exited with code $($p.ExitCode) ($lang)" }
    foreach ($file in @('panel.png', 'week.png', 'icon-day-16.png', 'icon-week-32.png')) {
        if (-not (Test-Path (Join-Path $dir $file))) { throw "render: $file missing ($lang)" }
    }
    Write-Host "render ($lang): icons, panel and week chart drawn"
}

foreach ($lang in @('en', 'fr')) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$app`"", '-Demo', '-OpenPanel', '-OpenWeek', '-Lang', $lang)
    $p = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -PassThru
    Start-Sleep -Seconds 10
    $alive = -not $p.HasExited
    if ($alive) { Stop-Process -Id $p.Id -Force }
    if (Test-Path $log) {
        Get-Content $log | ForEach-Object { Write-Host "::error::[$lang] $_" }
        throw "the widget logged errors ($lang)"
    }
    if (-not $alive) { throw "the widget stopped by itself ($lang, exit code $($p.ExitCode))" }
    Write-Host "demo mode ($lang): running, no error"
}
