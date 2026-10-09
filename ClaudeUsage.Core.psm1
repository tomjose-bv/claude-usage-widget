# ClaudeUsage.Core - pure, UI-free logic for the Claude Usage Widget.
# Everything here is deterministic given its inputs (pass -Now to pin the clock),
# so it can be unit tested with Pester. No WinForms, no network.

Set-StrictMode -Version 2.0

$script:Inv = [Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------- time helpers

function Get-ResetUtc {
    <# Converts an API timestamp (ISO-8601 string or [datetime]) to a UTC [datetime]. Returns $null for empty input. #>
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetimeoffset]) { return $Value.UtcDateTime }
    return [datetimeoffset]::Parse([string]$Value, $script:Inv).UtcDateTime
}

function Format-Left {
    <# Countdown text until a reset time: '3d 4h', '2h 05m', '17m', 'now', or '--' if unknown. #>
    param($ResetsAt, [datetime]$Now = [datetime]::UtcNow)
    if (-not $ResetsAt) { return '--' }
    $t = (Get-ResetUtc $ResetsAt) - $Now.ToUniversalTime()
    if ($t.TotalSeconds -le 0) { return 'now' }
    if ($t.TotalDays  -ge 1) { return '{0}d {1}h'    -f [int][math]::Floor($t.TotalDays),  $t.Hours }
    if ($t.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
    return '{0}m' -f [int][math]::Ceiling($t.TotalMinutes)
}

# ---------------------------------------------------------------- response parsing

$script:Windows = @(
    @{ Name = 'Session'; Key = 'five_hour'; Hours = 5 },
    @{ Name = 'Weekly';  Key = 'seven_day'; Hours = 168 }
)

function Get-WindowHours {
    <# Length of a usage window in hours ('Session' = 5, 'Weekly' = 168). #>
    param([string]$Name)
    foreach ($w in $script:Windows) { if ($w.Name -eq $Name) { return $w.Hours } }
    return $null
}

function Get-Prop {
    # StrictMode-safe property read from a PSCustomObject / hashtable.
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-UsageRows {
    <#
      Turns the /api/oauth/usage response into display rows:
        Name ('Session'|'Weekly'), Used (0-100), Left (0-100), Resets (raw resets_at).
      Windows that are missing, null, or have no numeric utilization are skipped.
    #>
    param($Data)
    $rows = @()
    if ($null -eq $Data) { return ,$rows }
    foreach ($w in $script:Windows) {
        $win = Get-Prop $Data $w.Key
        if ($null -eq $win) { continue }
        $u = Get-Prop $win 'utilization'
        if ($null -eq $u -or "$u" -eq '') { continue }
        $used = 0.0
        if (-not [double]::TryParse("$u", [Globalization.NumberStyles]::Float, $script:Inv, [ref]$used)) { continue }
        $used = [math]::Max(0.0, [math]::Min(100.0, $used))
        $rows += [pscustomobject]@{
            Name   = $w.Name
            Used   = $used
            Left   = 100 - $used
            Resets = Get-Prop $win 'resets_at'
        }
    }
    return ,$rows
}

# ---------------------------------------------------------------- colour levels

function Get-UsageLevel {
    <# Level for a 'percent left' value: Green (>50), Amber (>20), Red (otherwise). #>
    param([double]$Left)
    if ($Left -gt 50) { return 'Green' }
    if ($Left -gt 20) { return 'Amber' }
    return 'Red'
}

function Get-LevelRgb {
    <# RGB triple for a level name, matching the widget's palette. #>
    param([string]$Level)
    switch ($Level) {
        'Green' { return @(110, 190, 120) }
        'Amber' { return @(225, 175, 70) }
        default { return @(230, 95, 90) }
    }
}

# ---------------------------------------------------------------- polling / backoff

function Get-NextBackoff {
    <#
      Next 429 backoff in seconds: doubles the current backoff, never less than the
      normal poll interval or the server's Retry-After, capped at -Max.
    #>
    param([double]$Current = 0, [double]$RetryAfter = 0, [double]$FetchEvery = 300, [double]$Max = 1800)
    return [math]::Min($Max, [math]::Max([math]::Max($RetryAfter, $FetchEvery), $Current * 2))
}

function Get-FailureState {
    <#
      Maps a failed poll to the message shown in the widget and the new backoff.
      -StatusCode is the HTTP status (or $null for network errors).
    #>
    param($StatusCode, [double]$RetryAfter = 0, [double]$Backoff = 0, [double]$FetchEvery = 300, [double]$Max = 1800)
    if ($StatusCode -eq 401) {
        return [pscustomobject]@{ Message = 'Login expired - open Claude Code'; Backoff = 0 }
    }
    if ($StatusCode -eq 429) {
        $b = Get-NextBackoff -Current $Backoff -RetryAfter $RetryAfter -FetchEvery $FetchEvery -Max $Max
        return [pscustomobject]@{ Message = ('Rate limited, retry in {0}m' -f [int][math]::Ceiling($b / 60)); Backoff = $b }
    }
    return [pscustomobject]@{ Message = 'Offline, retrying'; Backoff = $Backoff }
}

function Get-PollWait {
    <# Seconds to wait before the next poll given the current state. #>
    param([double]$Backoff = 0, [bool]$HasError = $false, [double]$RetryEvery = 60, [double]$FetchEvery = 300)
    if ($Backoff -gt 0) { return $Backoff }
    if ($HasError) { return $RetryEvery }
    return $FetchEvery
}

function Get-DisplayState {
    <#
      'Live'  - latest poll succeeded recently;
      'Stale' - showing last-known numbers (poll failing, but data younger than -StaleAfter);
      'None'  - nothing worth showing.
    #>
    param([bool]$HasData, [bool]$HasError, $LastOk, [datetime]$Now = (Get-Date),
          [double]$FetchEvery = 300, [double]$StaleAfter = 3600)
    $age = if ($LastOk) { ($Now - [datetime]$LastOk).TotalSeconds } else { [double]::MaxValue }
    if ($HasData -and -not $HasError -and $age -lt ($FetchEvery + 30)) { return 'Live' }
    if ($HasData -and $age -lt $StaleAfter) { return 'Stale' }
    return 'None'
}

# ---------------------------------------------------------------- local history (JSONL)

function ConvertTo-HistoryRecord {
    <# Builds a history record from a usage response. Returns $null if the response has no usable windows. #>
    param($Data, [datetime]$Timestamp = [datetime]::UtcNow)
    $rows = Get-UsageRows $Data
    if ($rows.Count -eq 0) { return $null }
    $rec = [ordered]@{ ts = $Timestamp.ToUniversalTime().ToString('o', $script:Inv) }
    foreach ($pair in @(@('Session', 'session'), @('Weekly', 'weekly'))) {
        $r = $rows | Where-Object { $_.Name -eq $pair[0] } | Select-Object -First 1
        $rec[$pair[1]] = if ($r) { $r.Used } else { $null }
        $reset = if ($r) { Get-ResetUtc $r.Resets } else { $null }
        $rec[$pair[1] + '_resets'] = if ($reset) { $reset.ToString('o', $script:Inv) } else { $null }
    }
    return [pscustomobject]$rec
}

function Add-HistoryRecord {
    <#
      Appends one record as a JSON line. When the file grows past -MaxRecords lines it is
      rewritten keeping only the newest -MaxRecords (default ~17 days at a 5-minute poll).
    #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Record, [int]$MaxRecords = 5000)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $line = $Record | ConvertTo-Json -Compress
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::AppendAllText($Path, $line + "`n", $enc)
    $lines = [IO.File]::ReadAllLines($Path, $enc)
    if ($lines.Count -gt $MaxRecords) {
        $keep = $lines[($lines.Count - $MaxRecords)..($lines.Count - 1)]
        [IO.File]::WriteAllText($Path, (($keep -join "`n") + "`n"), $enc)
    }
}

function Read-History {
    <#
      Reads history records newer than -Since (UTC), oldest first. Corrupt or partial lines are skipped.
      Each record: Time (UTC datetime), Session, Weekly (0-100 or $null), SessionResets, WeeklyResets (UTC datetime or $null).
    #>
    param([Parameter(Mandatory)][string]$Path, $Since = $null)
    $out = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path $Path)) { return ,@() }
    $sinceUtc = if ($Since) { ([datetime]$Since).ToUniversalTime() } else { [datetime]::MinValue }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        if (-not $line.Trim()) { continue }
        try {
            $o = $line | ConvertFrom-Json -ErrorAction Stop
            $t = Get-ResetUtc (Get-Prop $o 'ts')
            if (-not $t -or $t -lt $sinceUtc) { continue }
            $s = Get-Prop $o 'session'; $w = Get-Prop $o 'weekly'
            $out.Add([pscustomobject]@{
                Time          = $t
                Session       = if ($null -ne $s) { [double]$s } else { $null }
                Weekly        = if ($null -ne $w) { [double]$w } else { $null }
                SessionResets = Get-ResetUtc (Get-Prop $o 'session_resets')
                WeeklyResets  = Get-ResetUtc (Get-Prop $o 'weekly_resets')
            })
        } catch { continue }
    }
    return ,@($out | Sort-Object Time)
}

function Get-BurnEstimate {
    <#
      Estimates burn rate and time-to-100% for one window from the latest reading.
      The window started at (resets - window length) with 0% used, so
        rate = used% / hours elapsed in the window.
      If the projected 100% time falls after the reset, WillHitLimit is $false.
      All figures are estimates that assume usage continues at the window's average pace.
    #>
    param([double]$Used, $Resets, [double]$WindowHours, [datetime]$Now = [datetime]::UtcNow)
    $res = [pscustomobject]@{ Used = $Used; RatePerHour = $null; HoursTo100 = $null; ProjectedAt = $null; WillHitLimit = $false; ResetsAt = $null }
    $reset = Get-ResetUtc $Resets
    if (-not $reset) { return $res }
    $res.ResetsAt = $reset
    $now = $Now.ToUniversalTime()
    $elapsed = ($now - $reset.AddHours(-$WindowHours)).TotalHours
    if ($elapsed -le 0 -or $now -ge $reset) { return $res }
    # A very short elapsed time gives a wildly noisy rate; wait for at least 5% of the window (15 min for a session).
    if ($elapsed -lt ($WindowHours * 0.05)) { return $res }
    $rate = $Used / $elapsed
    $res.RatePerHour = $rate
    if ($Used -ge 100) {
        $res.HoursTo100 = 0; $res.ProjectedAt = $now; $res.WillHitLimit = $true
    } elseif ($rate -gt 0) {
        $h = (100 - $Used) / $rate
        $res.HoursTo100 = $h
        $res.ProjectedAt = $now.AddHours($h)
        $res.WillHitLimit = $res.ProjectedAt -lt $reset
    }
    return $res
}

function Get-HistorySummary {
    <#
      Aggregates history records: sample count, time span, peak session/weekly %, and how many
      distinct session windows reached >= -NearLimit percent.
    #>
    param([object[]]$Records = @(), [double]$NearLimit = 90)
    $recs = @($Records | Where-Object { $_ })
    $sum = [pscustomobject]@{ Samples = $recs.Count; First = $null; Last = $null; PeakSession = $null; PeakWeekly = $null; SessionWindows = 0; NearLimitWindows = 0 }
    if ($recs.Count -eq 0) { return $sum }
    $sorted = @($recs | Sort-Object Time)
    $sum.First = $sorted[0].Time
    $sum.Last  = $sorted[-1].Time
    $s = @($sorted | Where-Object { $null -ne $_.Session } | ForEach-Object { $_.Session })
    $w = @($sorted | Where-Object { $null -ne $_.Weekly }  | ForEach-Object { $_.Weekly })
    if ($s.Count) { $sum.PeakSession = ($s | Measure-Object -Maximum).Maximum }
    if ($w.Count) { $sum.PeakWeekly  = ($w | Measure-Object -Maximum).Maximum }
    # Group by session window (resets_at rounded to the minute - the API adds sub-second jitter).
    $groups = @{}
    foreach ($r in $sorted) {
        if (-not $r.SessionResets -or $null -eq $r.Session) { continue }
        $k = $r.SessionResets.ToString('yyyyMMddHHmm', $script:Inv)
        if (-not $groups.ContainsKey($k) -or $r.Session -gt $groups[$k]) { $groups[$k] = $r.Session }
    }
    $sum.SessionWindows = $groups.Count
    $sum.NearLimitWindows = @($groups.Values | Where-Object { $_ -ge $NearLimit }).Count
    return $sum
}

function Format-Duration {
    <# Compact duration text for estimates: '45m', '3h 10m', '2d 5h'. #>
    param([double]$Hours)
    $t = [timespan]::FromHours([math]::Max(0.0, $Hours))
    if ($t.TotalDays  -ge 1) { return '{0}d {1}h'    -f [int][math]::Floor($t.TotalDays),  $t.Hours }
    if ($t.TotalHours -ge 1) { return '{0}h {1:00}m' -f [int][math]::Floor($t.TotalHours), $t.Minutes }
    return '{0}m' -f [int][math]::Round($t.TotalMinutes)
}

Export-ModuleMember -Function Get-ResetUtc, Format-Left, Get-WindowHours, Get-UsageRows, Get-UsageLevel, Get-LevelRgb,
    Get-NextBackoff, Get-FailureState, Get-PollWait, Get-DisplayState,
    ConvertTo-HistoryRecord, Add-HistoryRecord, Read-History, Get-BurnEstimate, Get-HistorySummary, Format-Duration
