# Fails if any PowerShell script of the project has a syntax error.
$failed = $false
Get-ChildItem -Path (Join-Path $PSScriptRoot '..') -Filter '*.ps1' -Recurse | ForEach-Object {
    $tokens = $null; $errors = $null
    [void][Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) {
        Write-Host "::error file=$($_.Name),line=$($e.Extent.StartLineNumber)::$($e.Message)"
        $failed = $true
    }
    # Windows PowerShell 5.1 reads a script without BOM as ANSI: accents would break.
    $bytes = [IO.File]::ReadAllBytes($_.FullName)
    if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
        Write-Host "::error file=$($_.Name)::UTF-8 BOM missing"
        $failed = $true
    }
}
if ($failed) { exit 1 }
Write-Host 'All scripts parse.'
