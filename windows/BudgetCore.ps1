# Claude Budget — calculs du budget (portage PowerShell de budget.js et strings.js).
# Mêmes noms de fonctions que la version GNOME ; vérifié sur tests/vectors.json
# (windows/tests/Run-Tests.ps1). Windows PowerShell 5.1, sans module externe.
#
# Toutes les valeurs sont en % de la limite hebdomadaire (0–100) ; les instants
# sont des millisecondes depuis 1970 (comme Date.now() en JavaScript).

$script:WEEKEND_SHARE = 10
$script:MIN_MS = 60000.0
$script:DAY_MS = 86400000.0
$script:WEEK_MS = 7 * 86400000.0
$script:RESET_MATCH_MS = 90 * 60000.0
$script:RESET_ROUND_MS = 5 * 60000.0
$script:LEVELS = @(25, 50, 75, 100, 'over')
$script:STEPS = @(0.5, 1, 2, 2.5, 5, 10, 20, 25, 50, 100)
$script:MONTHS = @('jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec')
$script:DAY_NAMES = @{
    fr = @('dim.', 'lun.', 'mar.', 'mer.', 'jeu.', 'ven.', 'sam.')
    en = @('Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat')
}
$script:Invariant = [Globalization.CultureInfo]::InvariantCulture

# Expressions de `claude /usage` (ECMAScript : \d et \s en ASCII, comme en JavaScript).
$script:RX = [Text.RegularExpressions.RegexOptions]
$script:WEEK_TEXT = New-Object Text.RegularExpressions.Regex(
    '^Current week \(all models\):\s*(\d+(?:\.\d+)?)\s*%\s*used(.*)$',
    ($RX::IgnoreCase -bor $RX::Multiline -bor $RX::ECMAScript))
$script:SESSION_TEXT = New-Object Text.RegularExpressions.Regex(
    '^Current session:\s*(\d+(?:\.\d+)?)\s*%\s*used',
    ($RX::IgnoreCase -bor $RX::Multiline -bor $RX::ECMAScript))
$script:RESET_TEXT = New-Object Text.RegularExpressions.Regex(
    'resets\s+([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?',
    ($RX::IgnoreCase -bor $RX::ECMAScript))

# ── Outils ───────────────────────────────────────────────────────────────────

# Math.round de JavaScript (.NET arrondit 2,5 à 2 par défaut).
function JsRound([double]$x) { return [Math]::Floor($x + 0.5) }

function IsFiniteNumber($x) {
    if ($null -eq $x -or $x -is [string] -or $x -is [bool]) { return $false }
    try { $d = [double]$x } catch { return $false }
    return -not ([double]::IsNaN($d) -or [double]::IsInfinity($d))
}

function SumOf($xs) {
    $total = 0.0
    foreach ($x in $xs) { $total += [double]$x }
    return $total
}

# Instant → date et heure locales.
function ToLocal([double]$ms) {
    return [DateTimeOffset]::FromUnixTimeMilliseconds([long]$ms).LocalDateTime
}

# Date et heure locales → instant.
function ToMs([DateTime]$local) {
    $local = [DateTime]::SpecifyKind($local, [DateTimeKind]::Local)
    return [double]([DateTimeOffset]$local).ToUnixTimeMilliseconds()
}

function DayKeyOf([DateTime]$local) { return $local.ToString('yyyy-MM-dd', $Invariant) }

# ── Calculs (budget.js) ──────────────────────────────────────────────────────

function localKey($ms) { return DayKeyOf (ToLocal $ms) }

# `resets_at` de l'API → instant arrondi à la minute.
function normalizeReset([string]$iso) {
    $clean = ([regex]'\.\d+').Replace($iso, '', 1)
    $ms = [double][DateTimeOffset]::Parse($clean, $Invariant).ToUnixTimeMilliseconds()
    return (JsRound ($ms / $MIN_MS)) * $MIN_MS
}

# Jours calendaires d'aujourd'hui jusqu'au reset ; weight = part du jour dans la semaine de quota.
function daysUntilReset($now, $resetAt) {
    $now = [double]$now; $resetAt = [double]$resetAt
    $windowStart = $resetAt - $WEEK_MS
    $days = New-Object Collections.ArrayList
    $cur = (ToLocal $now).Date
    $dayStart = ToMs $cur
    while ($dayStart -lt $resetAt) {
        $next = $cur.AddDays(1)
        $dayEnd = ToMs $next
        $overlap = [Math]::Min($dayEnd, $resetAt) - [Math]::Max($dayStart, $windowStart)
        if ($overlap -gt 0) {
            $weekend = ($cur.DayOfWeek -eq [DayOfWeek]::Saturday) -or ($cur.DayOfWeek -eq [DayOfWeek]::Sunday)
            [void]$days.Add(@{ key = (DayKeyOf $cur); weekend = $weekend; weight = $overlap / ($dayEnd - $dayStart) })
        }
        $cur = $next
        $dayStart = $dayEnd
    }
    return , $days.ToArray()
}

# Répartit `remaining` % : 5 % par jour de week-end, le reste aux jours de semaine.
function allocate($remaining, $days) {
    $days = @($days)
    $rem = [Math]::Max([double]0, [double]$remaining)
    $targets = @(foreach ($d in $days) { if ($d.weekend) { ($WEEKEND_SHARE / 2) * [double]$d.weight } else { 0.0 } })
    $targetSum = SumOf $targets
    $reserve = [Math]::Min($rem, $targetSum)
    $pool = $rem - $reserve
    $weekdayWeight = SumOf @(foreach ($d in $days) { if (-not $d.weekend) { $d.weight } })
    $weekendWeight = SumOf @(foreach ($d in $days) { if ($d.weekend) { $d.weight } })

    $out = New-Object Collections.ArrayList
    for ($i = 0; $i -lt $days.Count; $i++) {
        $d = $days[$i]
        if (-not $d.weekend) {
            if ($weekdayWeight -gt 0) { $b = ($pool * [double]$d.weight) / $weekdayWeight } else { $b = 0.0 }
        } else {
            if ($targetSum -gt 0) { $b = ($targets[$i] * $reserve) / $targetSum } else { $b = 0.0 }
            if ($weekdayWeight -eq 0 -and $weekendWeight -gt 0) { $b += ($pool * [double]$d.weight) / $weekendWeight }
        }
        [void]$out.Add([double]$b)
    }
    return , $out.ToArray()
}

# État du jour : budget figé au début de journée, jours suivants recalculés.
function computeStatus($o) {
    $utilization = [double]$o.utilization
    $dayStartUtil = [double]$o.dayStartUtil
    $days = daysUntilReset $o.now $o.resetAt
    if ($days.Count -gt 0) { $todayBudget = [double](allocate (100 - $dayStartUtil) $days)[0] } else { $todayBudget = 0.0 }
    $usedToday = [Math]::Max([double]0, $utilization - $dayStartUtil)
    if ($todayBudget -gt 0) { $progress = ($usedToday / $todayBudget) * 100 }
    elseif ($usedToday -gt 0) { $progress = [double]::PositiveInfinity }
    else { $progress = 100.0 }

    $leftoverToday = [Math]::Max([double]0, $todayBudget - $usedToday)
    if ($days.Count -gt 1) { $future = @($days[1..($days.Count - 1)]) } else { $future = @() }
    $budgets = allocate (100 - $utilization - $leftoverToday) $future
    $upcoming = New-Object Collections.ArrayList
    for ($i = 0; $i -lt $future.Count; $i++) {
        $u = $future[$i].Clone()
        $u.budget = $budgets[$i]
        [void]$upcoming.Add($u)
    }
    if ($days.Count -gt 0) { $today = $days[0] } else { $today = $null }
    return @{
        todayBudget = $todayBudget; usedToday = $usedToday; progress = $progress
        upcoming = $upcoming.ToArray(); today = $today
    }
}

function HasLevel($list, $level) {
    foreach ($x in @($list)) { if ("$x" -eq "$level") { return $true } }
    return $false
}

# Paliers 25/50/75/100 % puis dépassement ; ne renvoie que le plus haut nouvellement franchi.
function checkThresholds($progress, $notified) {
    $p = [double]$progress
    $reached = @(foreach ($l in $LEVELS) {
        if ($l -is [string]) { if ($p -gt 100) { $l } } elseif ($p -ge $l) { $l }
    })
    $fresh = @(foreach ($l in $reached) { if (-not (HasLevel $notified $l)) { $l } })
    $all = @(foreach ($l in $LEVELS) { if ((HasLevel $notified $l) -or (HasLevel $reached $l)) { $l } })
    if ($fresh.Count -gt 0) { $level = $fresh[$fresh.Count - 1] } else { $level = $null }
    return @{ level = $level; notified = $all }
}

function sameReset($a, $b) {
    return (IsFiniteNumber $a) -and (IsFiniteNumber $b) -and ([Math]::Abs([double]$a - [double]$b) -le $RESET_MATCH_MS)
}

# Nouveau jour ou nouvelle semaine → on repart de l'usage actuel (historique gardé dans la semaine).
function rollDayState($state, $o) {
    $dayKey = localKey $o.now
    $sameWeek = ($null -ne $state) -and (sameReset $state.resetAt $o.resetAt)
    if ($sameWeek -and $state.dayKey -eq $dayKey) {
        if ([double]$state.resetAt -eq [double]$o.resetAt) { return $state }
        $copy = $state.Clone()
        $copy.resetAt = $o.resetAt
        return $copy
    }
    if ($sameWeek -and $null -ne $state.history) { $history = $state.history } else { $history = @{} }
    return @{ dayKey = $dayKey; resetAt = $o.resetAt; dayStartUtil = $o.utilization; notified = @(); history = $history }
}

function recordDay($state, $o) {
    $history = @{}
    if ($null -ne $state.history) { foreach ($k in @($state.history.Keys)) { $history[$k] = $state.history[$k] } }
    $history[$state.dayKey] = @{ budget = $o.todayBudget; start = $state.dayStartUtil; used = $o.usedToday }
    $copy = $state.Clone()
    $copy.history = $history
    return $copy
}

# Données du graphique de la semaine (kind = past | today | future | gap) et blocs non suivis.
function weekChart($o) {
    $state = $o.state; $status = $o.status; $resetAt = [double]$o.resetAt
    if ($null -ne $state.history) { $history = $state.history } else { $history = @{} }
    $planned = @{}
    foreach ($d in @($status.upcoming)) { $planned[$d.key] = $d.budget }
    $days = New-Object Collections.ArrayList
    $gaps = New-Object Collections.ArrayList
    $prevEnd = 0.0
    $open = $null
    $all = daysUntilReset ($resetAt - $WEEK_MS) $resetAt
    for ($i = 0; $i -lt $all.Count; $i++) {
        $d = $all[$i]
        $base = @{ key = $d.key; weight = $d.weight; weekend = $d.weekend }
        if ($d.key -eq $state.dayKey) {
            if ($null -ne $open) {
                $open.total = [Math]::Max([double]0, [double]$state.dayStartUtil - $prevEnd)
                [void]$gaps.Add($open); $open = $null
            }
            $base.kind = 'today'; $base.budget = $status.todayBudget; $base.used = $status.usedToday
        } elseif ([string]::CompareOrdinal($d.key, $state.dayKey) -gt 0) {
            $base.kind = 'future'; $base.used = $null
            if ($planned.ContainsKey($d.key)) { $base.budget = $planned[$d.key] } else { $base.budget = 0 }
        } elseif ($history.ContainsKey($d.key)) {
            $r = $history[$d.key]
            if ($null -ne $open) {
                $open.total = [Math]::Max([double]0, [double]$r.start - $prevEnd)
                [void]$gaps.Add($open); $open = $null
            }
            $prevEnd = [double]$r.start + [double]$r.used
            $base.kind = 'past'; $base.budget = $r.budget; $base.used = $r.used
        } else {
            if ($null -ne $open) { $open.to = $i } else { $open = @{ from = $i; to = $i } }
            $base.kind = 'gap'; $base.budget = $null; $base.used = $null
        }
        [void]$days.Add($base)
    }
    return @{ days = $days.ToArray(); gaps = $gaps.ToArray() }
}

# Échelle ronde de l'axe vertical : au plus 4 graduations au-dessus de 0.
function chartScale($maxValue) {
    $m = [double]$maxValue
    if (-not ($m -gt 0)) { return @{ max = 5; step = 5 } }
    $step = 100
    foreach ($s in $STEPS) { if ([Math]::Ceiling($m / $s) -le 4) { $step = $s; break } }
    return @{ max = [Math]::Ceiling($m / $step) * $step; step = $step }
}

function progressText($progress, $lang = 'fr') {
    if (IsFiniteNumber $progress) { return pctText (JsRound ([double]$progress)) $lang }
    if ($lang -eq 'fr') { return 'dépassé' } else { return 'over' }
}

function barFraction($progress) {
    if (-not (IsFiniteNumber $progress)) { return 1 }
    return [Math]::Min([double]1, [Math]::Max([double]0, [double]$progress / 100))
}

# Couleur : vert sous 50 %, orange de 50 à 75 %, rouge dès 75 %.
function barLevel($percent) {
    if (-not (IsFiniteNumber $percent) -or [double]$percent -ge 75) { return 'red' }
    if ([double]$percent -ge 50) { return 'orange' } else { return 'green' }
}

function weekElapsed($now, $resetAt) {
    return [Math]::Min([double]1, [Math]::Max([double]0, 1 - ([double]$resetAt - [double]$now) / $WEEK_MS))
}

function planFractions($todayBudget, $upcoming) {
    $max = [double]$todayBudget
    foreach ($d in @($upcoming)) { if ([double]$d.budget -gt $max) { $max = [double]$d.budget } }
    $out = @(foreach ($d in @($upcoming)) { if ($max -gt 0) { [double]$d.budget / $max } else { 0 } })
    return , $out
}

function fmtPct($x, $lang = 'fr') {
    $r = (JsRound ([double]$x * 10)) / 10
    if ($r -eq 0) { $r = 0.0 }
    $s = ([double]$r).ToString('R', $Invariant)
    if ($lang -eq 'fr') { return $s.Replace('.', ',') } else { return $s }
}

function pctText($x, $lang = 'fr') {
    if ($lang -eq 'fr') { return "$(fmtPct $x $lang) %" } else { return "$(fmtPct $x $lang)%" }
}

function dayLabel([string]$key, $lang = 'fr') {
    $parts = $key.Split('-')
    $date = New-Object DateTime -ArgumentList @([int]$parts[0], [int]$parts[1], [int]$parts[2])
    $names = $DAY_NAMES[$lang]
    if ($null -eq $names) { $names = $DAY_NAMES['en'] }
    return '{0} {1}' -f $names[[int]$date.DayOfWeek], [int]$parts[2]
}

# « resets Nov 10, 3pm » (heure locale) → instant arrondi à 5 min, ou $null.
function parseResetText([string]$text, $now) {
    $m = $RESET_TEXT.Match($text)
    if (-not $m.Success) { return $null }
    $month = [Array]::IndexOf($MONTHS, $m.Groups[1].Value.ToLowerInvariant())
    $day = [int]$m.Groups[2].Value
    $hour = [int]$m.Groups[3].Value
    if ($m.Groups[4].Success) { $minute = [int]$m.Groups[4].Value } else { $minute = 0 }
    if ($m.Groups[5].Success) {
        $hour = $hour % 12
        if ($m.Groups[5].Value.ToLowerInvariant() -eq 'pm') { $hour += 12 }
    }
    if ($month -lt 0 -or $hour -gt 23 -or $minute -gt 59) { return $null }
    $year = (ToLocal $now).Year
    foreach ($y in @($year, ($year + 1))) {
        # Comme new Date(y, m, d, h, min) : un jour hors du mois déborde sur le suivant.
        $first = New-Object DateTime -ArgumentList @([int]$y, ($month + 1), 1)
        $local = $first.AddDays($day - 1).AddHours($hour).AddMinutes($minute)
        $t = ToMs $local
        if ($t -gt [double]$now - $RESET_MATCH_MS -and $t -le [double]$now + $WEEK_MS + $DAY_MS) {
            return (JsRound ($t / $RESET_ROUND_MS)) * $RESET_ROUND_MS
        }
    }
    return $null
}

# Texte de `claude -p /usage` → @{ utilization; session; resetAt } ou $null.
function parseUsageText([string]$text, $now) {
    $week = $WEEK_TEXT.Match($text)
    if (-not $week.Success) { return $null }
    $utilization = [double]::Parse($week.Groups[1].Value, $Invariant)
    if (-not ($utilization -ge 0 -and $utilization -le 100)) { return $null }
    $session = $SESSION_TEXT.Match($text)
    if ($session.Success) { $sessionValue = [double]::Parse($session.Groups[1].Value, $Invariant) } else { $sessionValue = $null }
    return @{ utilization = $utilization; session = $sessionValue; resetAt = (parseResetText $week.Groups[2].Value $now) }
}

# Remise à zéro à retenir pour une lecture de /usage (voir budget.js).
function pickReset($known, $candidate, $now) {
    if ((IsFiniteNumber $known) -and [double]$known -gt [double]$now) { $live = [double]$known } else { $live = $null }
    if ($null -eq $candidate) { return $live }
    if ($null -ne $live -and (sameReset $live $candidate)) { return $live }
    return $candidate
}

# ── Langue et textes (strings.js) ────────────────────────────────────────────

function pickLang($names) {
    foreach ($name in @($names)) {
        if ("$name" -match '^fr([_.@-]|$)') { return 'fr' }
        if ("$name" -match '^en([_.@-]|$)') { return 'en' }
    }
    return 'en'
}

# Textes avec {0}, {1}… (opérateur -f). Seuls ceux affichés par la version Windows.
$script:STRINGS = @{
    fr = @{
        title = 'Budget Claude'
        today = 'Aujourd’hui'; todayOf = 'Aujourd’hui ({0})'
        week = 'Semaine'; reset = 'Remise à zéro'; session = 'Session (5 h)'
        upcomingHeader = "Prochains jours (réserve week-end $WEEKEND_SHARE %)"
        lastDay = 'Dernier jour avant la remise à zéro'
        weekendSuffix = ' (week-end)'; untilSuffix = ' (jusqu’à {0})'
        updated = 'Mis à jour'; updatedViaCli = 'Mis à jour (via claude /usage)'
        viewWeek = 'Voir la semaine…'; refreshNow = 'Actualiser maintenant'; quit = 'Quitter'
        todayValue = '{0} / {1}  ·  {2}'; weekValue = '{0} utilisés · reste {1}'
        resetValue = '{0} à {1}  ·  {2} écoulé'
        tooltipDay = 'Claude · aujourd’hui {0} ({1} / {2})'
        tooltipWeek = 'Claude · semaine {0} · remise à zéro {1} à {2}'
        chartTitle = 'Usage Claude de la semaine'; chartTitleRange = 'Usage Claude — semaine du {0} au {1}'
        chartSummary = '{0} utilisés · reste {1} · remise à zéro {2} à {3}'
        chartFooter = 'En % de la limite hebdomadaire · mis à jour à {0}'; close = 'Fermer'
        chartUntracked = 'non suivi'; chartUntrackedDays = 'jours non suivis'; chartTotal = '{0} au total'
        chartToday = 'aujourd’hui'; chartFrom = 'dès {0}'; chartUntil = 'jusqu’à {0}'
        legendUsed = 'utilisé'; legendBudget = 'budget du jour'; legendOver = 'dépassement'; legendPlanned = 'prévu'
        planItem = '{0} : {1}'; planNone = 'plus aucun jour avant la remise à zéro ({0})'
        notifyOverTitle = 'Claude : budget du jour dépassé'
        notifyOverBody = "{0} utilisés pour {1} prévus aujourd’hui (+{2}).`nBudgets recalculés : {3}"
        notifyFullTitle = 'Claude : budget du jour atteint'
        notifyFullBody = "Vous avez utilisé les {0} prévus pour aujourd’hui.`nProchains jours : {1}"
        notifyLevelTitle = 'Claude : {0} % du budget du jour'
        notifyLevelBody = '{0} utilisés sur {1} prévus aujourd’hui (semaine : {2}).'
        errNoLogin = 'Connexion Claude introuvable (%USERPROFILE%\.claude\.credentials.json)'
        errExpired = 'Connexion expirée : lancez Claude Code pour la renouveler'
        errTooMany = 'Trop de requêtes, nouvel essai dans 5 min'
        errHttp = 'Service indisponible (HTTP {0})'; errNetwork = 'Pas de connexion au service Claude'
        errUnexpected = 'Réponse inattendue du service Claude'
        waiting = 'Claude · lecture de l’usage…'
    }
    en = @{
        title = 'Claude Budget'
        today = 'Today'; todayOf = 'Today ({0})'
        week = 'Week'; reset = 'Resets'; session = 'Session (5 h)'
        upcomingHeader = "Next days (weekend reserve $WEEKEND_SHARE%)"
        lastDay = 'Last day before the reset'
        weekendSuffix = ' (weekend)'; untilSuffix = ' (until {0})'
        updated = 'Updated'; updatedViaCli = 'Updated (via claude /usage)'
        viewWeek = 'View the week…'; refreshNow = 'Refresh now'; quit = 'Quit'
        todayValue = '{0} / {1}  ·  {2}'; weekValue = '{0} used · {1} left'
        resetValue = '{0} at {1}  ·  {2} elapsed'
        tooltipDay = 'Claude · today {0} ({1} / {2})'
        tooltipWeek = 'Claude · week {0} · resets {1} at {2}'
        chartTitle = 'Claude usage this week'; chartTitleRange = 'Claude usage — week of {0} to {1}'
        chartSummary = '{0} used · {1} left · resets {2} at {3}'
        chartFooter = 'In % of the weekly limit · updated at {0}'; close = 'Close'
        chartUntracked = 'not tracked'; chartUntrackedDays = 'days not tracked'; chartTotal = '{0} in total'
        chartToday = 'today'; chartFrom = 'from {0}'; chartUntil = 'until {0}'
        legendUsed = 'used'; legendBudget = 'daily budget'; legendOver = 'over budget'; legendPlanned = 'planned'
        planItem = '{0}: {1}'; planNone = 'no day left before the reset ({0})'
        notifyOverTitle = 'Claude: daily budget exceeded'
        notifyOverBody = "{0} used for {1} planned today (+{2}).`nBudgets recalculated: {3}"
        notifyFullTitle = 'Claude: daily budget reached'
        notifyFullBody = "You have used the {0} planned for today.`nNext days: {1}"
        notifyLevelTitle = "Claude: {0}% of today's budget"
        notifyLevelBody = '{0} used of {1} planned today (week: {2}).'
        errNoLogin = 'Claude login not found (%USERPROFILE%\.claude\.credentials.json)'
        errExpired = 'Login expired: open Claude Code to renew it'
        errTooMany = 'Too many requests, retrying in 5 min'
        errHttp = 'Service unavailable (HTTP {0})'; errNetwork = 'Cannot reach the Claude service'
        errUnexpected = 'Unexpected answer from the Claude service'
        waiting = 'Claude · reading usage…'
    }
}

# Texte traduit : Tr 'weekValue' '49 %' '51 %'.
function Tr([string]$key) {
    $code = "$script:Lang"
    if (-not $STRINGS.ContainsKey($code)) { $code = 'en' }
    $text = $STRINGS[$code][$key]
    if ($args.Count -gt 0) { return $text -f $args }
    return $text
}


# ── JSON ─────────────────────────────────────────────────────────────────────

# ConvertFrom-Json (objets) → tables de hachage, tableaux gardés tels quels.
function ConvertTo-Hash($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [decimal]) { return [double]$value } # nombres à virgule de ConvertFrom-Json (5.1)
    if ($value -is [Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $value.PSObject.Properties) { $h[$p.Name] = ConvertTo-Hash $p.Value }
        return $h
    }
    if ($value -is [Collections.IList]) {
        $list = New-Object Collections.ArrayList
        foreach ($item in $value) { [void]$list.Add((ConvertTo-Hash $item)) }
        return , $list.ToArray()
    }
    return $value
}
