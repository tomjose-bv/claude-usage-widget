# History window for the Claude Usage Widget: a 7-day line chart of session and weekly
# utilization from the local history file, plus a few derived (estimated) stats.
# Dot-sourced by ClaudeUsage.ps1; needs ClaudeUsage.Core.psm1 to be imported first.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Windows.Forms.DataVisualization

function Get-HistoryStatsText {
    <# Plain-text summary shown under the chart. $Rows are current usage rows (Get-UsageRows). #>
    param([object[]]$Rows = @(), [object[]]$Records = @(), [datetime]$Now = [datetime]::UtcNow)
    $lines = @()
    foreach ($r in $Rows) {
        $hours = Get-WindowHours $r.Name
        $e = Get-BurnEstimate -Used $r.Used -Resets $r.Resets -WindowHours $hours -Now $Now
        $label = if ($r.Name -eq 'Session') { 'Session (5h)' } else { 'Weekly (7d)' }
        $line = '{0}: {1:0}% used' -f $label, $r.Used
        if ($null -eq $e.RatePerHour) {
            $line += ' - too early in the window for a burn rate'
        } else {
            $rate = if ($r.Name -eq 'Session') { '{0:0.0}%/hour' -f $e.RatePerHour } else { '{0:0.0}%/day' -f ($e.RatePerHour * 24) }
            $line += ' - average burn {0} this window' -f $rate
            $resetLocal = $e.ResetsAt.ToLocalTime().ToString('ddd HH:mm')
            if ($e.WillHitLimit) {
                $line += ' - est. 100% at {0} (in {1}), before the reset at {2}' -f `
                    $e.ProjectedAt.ToLocalTime().ToString('ddd HH:mm'), (Format-Duration $e.HoursTo100), $resetLocal
            } elseif ($e.ProjectedAt) {
                $line += ' - at this pace you would not hit 100% before the reset at {0}' -f $resetLocal
            }
        }
        $lines += $line
    }
    $s = Get-HistorySummary $Records
    if ($s.Samples -gt 0) {
        $lines += 'Recorded: {0} samples since {1} - peak session {2:0}%, peak weekly {3:0}% - {4} of {5} session windows reached 90%+' -f `
            $s.Samples, $s.First.ToLocalTime().ToString('ddd HH:mm'), $s.PeakSession, $s.PeakWeekly, $s.NearLimitWindows, $s.SessionWindows
    } else {
        $lines += 'No history yet - a sample is recorded each time the widget polls (every 5 minutes).'
    }
    $lines += 'Estimates assume usage continues at the window''s average pace so far. The endpoint reports percentages only (no tokens or cost).'
    return ($lines -join "`r`n")
}

function New-HistoryForm {
    <#
      Builds (but does not show) the history window.
      -Data is the latest usage response (optional; falls back to the newest history record).
    #>
    param([Parameter(Mandatory)][string]$HistoryPath, [double]$Scale = 1, $Data = $null, [datetime]$Now = [datetime]::UtcNow)

    $nowUtc  = $Now.ToUniversalTime()
    $records = @(Read-History -Path $HistoryPath -Since $nowUtc.AddDays(-7))
    $rows    = @(Get-UsageRows $Data)
    if ($rows.Count -eq 0 -and $records.Count -gt 0) {
        $last = $records[-1]
        $rows = @(Get-UsageRows ([pscustomobject]@{
            five_hour = if ($null -ne $last.Session) { @{ utilization = $last.Session; resets_at = $last.SessionResets } } else { $null }
            seven_day = if ($null -ne $last.Weekly)  { @{ utilization = $last.Weekly;  resets_at = $last.WeeklyResets } }  else { $null }
        }))
    }

    $bg      = [Drawing.Color]::FromArgb(32, 32, 32)
    $grid    = [Drawing.Color]::FromArgb(58, 58, 58)
    $ink     = [Drawing.Color]::FromArgb(240, 240, 240)
    $inkSoft = [Drawing.Color]::FromArgb(195, 194, 183)
    $cSess   = [Drawing.Color]::FromArgb(0x39, 0x87, 0xe5)   # blue
    $cWeek   = [Drawing.Color]::FromArgb(0xd9, 0x59, 0x26)   # orange
    $px = { param($v) [int]($v * $Scale) }

    $form = New-Object System.Windows.Forms.Form
    $form.Text          = 'Claude usage - last 7 days'
    $form.StartPosition = 'CenterScreen'
    $form.Size          = New-Object Drawing.Size((& $px 760), (& $px 520))
    $form.MinimumSize   = New-Object Drawing.Size((& $px 480), (& $px 360))
    $form.BackColor     = $bg
    $form.ForeColor     = $ink
    $form.Font          = New-Object Drawing.Font('Segoe UI', 9)   # points, so it follows system DPI
    $form.ShowIcon      = $false

    # ---- stats panel (bottom)
    $stats = New-Object System.Windows.Forms.Label
    $stats.Dock      = 'Bottom'
    $stats.Height    = & $px 104
    $stats.Padding   = New-Object System.Windows.Forms.Padding((& $px 12), (& $px 6), (& $px 12), (& $px 6))
    $stats.ForeColor = $inkSoft
    $stats.BackColor = $bg
    $stats.Text      = Get-HistoryStatsText -Rows $rows -Records $records -Now $nowUtc

    # ---- chart
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Dock      = 'Fill'
    $chart.BackColor = $bg
    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea 'main'
    $area.BackColor = $bg
    foreach ($ax in @($area.AxisX, $area.AxisY)) {
        $ax.LineColor = $grid
        $ax.MajorGrid.LineColor = $grid
        $ax.MajorTickMark.LineColor = $grid
        $ax.LabelStyle.ForeColor = $inkSoft
    }
    $area.AxisX.MajorGrid.Enabled = $false
    $area.AxisY.Minimum = 0; $area.AxisY.Maximum = 100; $area.AxisY.Interval = 25
    $area.AxisY.LabelStyle.Format = '0"%"'
    $area.AxisX.Minimum = $nowUtc.AddDays(-7).ToLocalTime().ToOADate()
    $area.AxisX.Maximum = $nowUtc.ToLocalTime().ToOADate()
    $area.AxisX.IntervalType = 'Days'; $area.AxisX.Interval = 1
    $area.AxisX.LabelStyle.Format = 'ddd d'
    $chart.ChartAreas.Add($area)

    $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend 'legend'
    $legend.Docking = 'Top'; $legend.Alignment = 'Center'
    $legend.BackColor = $bg; $legend.ForeColor = $ink
    $chart.Legends.Add($legend)

    foreach ($def in @(@('Session (5h)', 'Session', $cSess), @('Weekly (7d)', 'Weekly', $cWeek))) {
        $ser = New-Object System.Windows.Forms.DataVisualization.Charting.Series $def[0]
        $ser.ChartType   = 'Line'
        $ser.XValueType  = 'DateTime'
        $ser.Color       = $def[2]
        $ser.BorderWidth = [math]::Max(2, [int](2 * $Scale))
        $ser.ToolTip     = '#SERIESNAME: #VALY{0}% used at #VALX{ddd HH:mm}'
        $ser.EmptyPointStyle.Color = [Drawing.Color]::Transparent
        $prev = $null
        foreach ($rec in $records) {
            $v = $rec.($def[1])
            if ($null -eq $v) { continue }
            # Break the line across gaps (widget not running) instead of drawing a misleading slope.
            if ($prev -and ($rec.Time - $prev).TotalMinutes -gt 20) {
                $i = $ser.Points.AddXY($prev.AddMinutes(1).ToLocalTime().ToOADate(), 0.0); $ser.Points[$i].IsEmpty = $true
            }
            [void]$ser.Points.AddXY($rec.Time.ToLocalTime().ToOADate(), [double]$v)
            $prev = $rec.Time
        }
        $chart.Series.Add($ser)
    }
    if ($records.Count -eq 0) {
        $t = New-Object System.Windows.Forms.DataVisualization.Charting.Title 'No history recorded yet'
        $t.ForeColor = $inkSoft; $t.Docking = 'Top'
        $chart.Titles.Add($t)
    }

    $form.Controls.Add($chart)
    $form.Controls.Add($stats)
    return $form
}
