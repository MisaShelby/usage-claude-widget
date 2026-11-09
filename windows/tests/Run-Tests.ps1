# Vérifie BudgetCore.ps1 sur les cas de référence calculés par la version GNOME
# (tests/vectors.json), puis quelques règles propres à Windows.
#   tzutil /s "Romance Standard Time"   (les cas sont en heure de Paris)
#   powershell -NoProfile -ExecutionPolicy Bypass -File windows\tests\Run-Tests.ps1
$ErrorActionPreference = 'Stop'
# Toute erreur imprévue devient une annotation GitHub (fichier, ligne, message).
trap {
    $where = "$([IO.Path]::GetFileName($_.InvocationInfo.ScriptName)):$($_.InvocationInfo.ScriptLineNumber)"
    $text = "$where $($_.Exception.Message) | $($_.InvocationInfo.Line.Trim())" -replace "`r?`n", ' / '
    Write-Host "::error::$text"
    exit 1
}
. (Join-Path $PSScriptRoot '..\BudgetCore.ps1')

if ([TimeZoneInfo]::Local.Id -ne 'Romance Standard Time') {
    throw "Les cas sont en heure de Paris : lancez d'abord  tzutil /s ""Romance Standard Time""  (fuseau actuel : $([TimeZoneInfo]::Local.Id))"
}

# "Infinity" (JSON n'en a pas) → [double]::PositiveInfinity, partout.
function Revive($v) {
    if ($v -is [string]) {
        if ($v -eq 'Infinity') { return [double]::PositiveInfinity }
        if ($v -eq '-Infinity') { return [double]::NegativeInfinity }
        return $v
    }
    if ($v -is [hashtable]) {
        $h = @{}
        foreach ($k in @($v.Keys)) { $h[$k] = Revive $v[$k] }
        return $h
    }
    if ($v -is [array]) {
        $list = New-Object Collections.ArrayList
        foreach ($x in $v) { [void]$list.Add((Revive $x)) }
        return , $list.ToArray()
    }
    return $v
}

function IsNumber($v) {
    return ($v -is [int]) -or ($v -is [long]) -or ($v -is [double]) -or ($v -is [decimal]) -or ($v -is [single])
}

# Écart entre le résultat obtenu et l'attendu ; $null si identiques.
function Compare-Values($actual, $expected, [string]$path) {
    if ($null -eq $expected) {
        if ($null -eq $actual) { return $null }
        return "${path}: attendu null, obtenu $actual"
    }
    if ($expected -is [hashtable]) {
        if (-not ($actual -is [hashtable])) { return "${path}: attendu un objet, obtenu $actual" }
        $keys = @($expected.Keys) + @($actual.Keys) | Sort-Object -Unique
        foreach ($k in $keys) {
            if (-not $expected.ContainsKey($k)) { return "${path}.${k}: clé en trop" }
            if (-not $actual.ContainsKey($k)) { return "${path}.${k}: clé manquante" }
            $d = Compare-Values $actual[$k] $expected[$k] "$path.$k"
            if ($d) { return $d }
        }
        return $null
    }
    if ($expected -is [array]) {
        if (-not ($actual -is [array])) { return "${path}: attendu un tableau, obtenu $actual" }
        if ($actual.Count -ne $expected.Count) { return "${path}: $($actual.Count) éléments au lieu de $($expected.Count)" }
        for ($i = 0; $i -lt $expected.Count; $i++) {
            $d = Compare-Values $actual[$i] $expected[$i] "$path[$i]"
            if ($d) { return $d }
        }
        return $null
    }
    if ($expected -is [string]) {
        if (($actual -is [string]) -and $actual -ceq $expected) { return $null }
        return "${path}: attendu '$expected', obtenu '$actual'"
    }
    if ($expected -is [bool]) {
        if (($actual -is [bool]) -and $actual -eq $expected) { return $null }
        return "${path}: attendu $expected, obtenu $actual"
    }
    if (IsNumber $expected) {
        if (-not (IsNumber $actual)) { return "${path}: attendu $expected, obtenu '$actual'" }
        $a = [double]$actual; $e = [double]$expected
        if ([double]::IsInfinity($e) -or [double]::IsInfinity($a)) {
            if ($a -eq $e) { return $null }
        } elseif ([Math]::Abs($a - $e) -le 1e-9 * [Math]::Max(1, [Math]::Abs($e))) {
            return $null
        }
        return "${path}: attendu $e, obtenu $a"
    }
    return "${path}: type inattendu $($expected.GetType().Name)"
}

$failures = New-Object Collections.ArrayList
$passed = 0
function Check([string]$name, $actual, $expected) {
    $d = Compare-Values $actual $expected $name
    if ($d) { [void]$script:failures.Add($d) } else { $script:passed++ }
}

Write-Host "PowerShell $($PSVersionTable.PSVersion) · fuseau $([TimeZoneInfo]::Local.Id)"
$vectorsPath = Join-Path $PSScriptRoot '..\..\tests\vectors.json'
$vectors = [IO.File]::ReadAllText($vectorsPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$index = 0
foreach ($case in $vectors.cases) {
    $callArgs = New-Object Collections.ArrayList
    foreach ($a in $case.args) { [void]$callArgs.Add((Revive (ConvertTo-Hash $a))) }
    $argArray = $callArgs.ToArray()
    $expected = Revive (ConvertTo-Hash $case.expected)
    $name = "#$index $($case.fn)"
    try {
        $actual = & $case.fn @argArray
        Check $name $actual $expected
    } catch {
        [void]$failures.Add("${name}: erreur $($_.Exception.Message) (ligne $($_.InvocationInfo.ScriptLineNumber))")
    }
    $index++
}

# Textes : mêmes clés dans les deux langues, formats {0} remplis.
$fr = @($STRINGS['fr'].Keys | Sort-Object)
$en = @($STRINGS['en'].Keys | Sort-Object)
Check 'textes: mêmes clés fr/en' ($fr -join ',') ($en -join ',')
$script:Lang = 'fr'
Check 'Tr fr' (Tr 'weekValue' (pctText 49 'fr') (pctText 51 'fr')) '49 % utilisés · reste 51 %'
$script:Lang = 'en'
Check 'Tr en' (Tr 'resetValue' (dayLabel '2026-11-10' 'en') '15:00' (pctText 84 'en')) 'Tue 10 at 15:00  ·  84% elapsed'
Check 'pickLang fr-FR (Windows)' (pickLang @('fr-FR')) 'fr'
Check 'pickLang en-US (Windows)' (pickLang @('en-US')) 'en'

# État relu depuis le JSON (nombres à virgule, tableau d'un seul palier).
$json = '{"dayKey":"2026-11-09","resetAt":1794319200000,"dayStartUtil":49.5,"notified":[25],"history":{"2026-11-06":{"budget":17.9,"start":43,"used":5}}}'
$state = ConvertTo-Hash ($json | ConvertFrom-Json)
Check 'état: notified reste un tableau' ($state.notified -is [array]) $true
Check 'état: décimal → double' ($state.dayStartUtil -is [double]) $true
$again = ConvertTo-Hash ((recordDay $state @{ todayBudget = 31.4; usedToday = 2 }) | ConvertTo-Json -Depth 10 -Compress | ConvertFrom-Json)
Check 'état: aller-retour JSON' ($again.history['2026-11-09'].used) 2
Check 'état: notified après aller-retour' ($again.notified -is [array]) $true

Write-Host "$passed vérifications réussies, $($failures.Count) en échec ($index cas de référence)."
foreach ($f in $failures) { Write-Host "::error::$f" }
if ($failures.Count -gt 0) { exit 1 }
