# Pester 5+ tests for the history window helpers (built, never shown).

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ClaudeUsage.Core.psm1') -Force
    . (Join-Path $PSScriptRoot '..\ClaudeUsage.History.ps1')
    $script:Now = [datetime]::new(2026, 1, 15, 12, 0, 0, [DateTimeKind]::Utc)
}

Describe 'Get-HistoryStatsText' {
    It 'labels a projected limit hit as an estimate' {
        $rows = @([pscustomobject]@{ Name = 'Session'; Used = 90; Left = 10; Resets = $script:Now.AddHours(1) })
        $text = Get-HistoryStatsText -Rows $rows -Records @() -Now $script:Now
        $text | Should -Match 'Session \(5h\): 90% used'
        $text | Should -Match 'average burn 22\.5%/hour'
        $text | Should -Match 'est\. 100% at .* before the reset'
        $text | Should -Match 'Estimates assume'
    }
    It 'says when the pace will not reach the limit, and shows weekly burn per day' {
        $rows = @([pscustomobject]@{ Name = 'Weekly'; Used = 42; Left = 58; Resets = $script:Now.AddHours(84) })
        $text = Get-HistoryStatsText -Rows $rows -Now $script:Now
        $text | Should -Match 'average burn 12\.0%/day'
        $text | Should -Match 'would not hit 100% before the reset'
    }
    It 'never mentions token counts or cost figures as data' {
        $rows = @([pscustomobject]@{ Name = 'Session'; Used = 30; Left = 70; Resets = $script:Now.AddHours(2) })
        $text = Get-HistoryStatsText -Rows $rows -Now $script:Now
        $text | Should -Not -Match '\d+\s*tokens'
        $text | Should -Not -Match '\$\d'
    }
    It 'explains an empty history' {
        Get-HistoryStatsText -Now $script:Now | Should -Match 'No history yet'
    }
}

Describe 'New-HistoryForm' {
    It 'builds a chart window from a history file without showing it' {
        $path = Join-Path $TestDrive 'history.jsonl'
        foreach ($i in 1..3) {
            Add-HistoryRecord -Path $path -Record ([pscustomobject]@{
                ts = [datetime]::UtcNow.AddMinutes(-5 * $i).ToString('o'); session = 10 * $i; weekly = 20
                session_resets = [datetime]::UtcNow.AddHours(2).ToString('o'); weekly_resets = [datetime]::UtcNow.AddDays(2).ToString('o')
            })
        }
        $form = New-HistoryForm -HistoryPath $path
        try {
            $chart = $form.Controls | Where-Object { $_ -is [System.Windows.Forms.DataVisualization.Charting.Chart] }
            $chart.Series.Count | Should -Be 2
            $chart.Series[0].Points.Count | Should -Be 3
            $form.Visible | Should -BeFalse
        } finally { $form.Dispose() }
    }
    It 'copes with a missing history file' {
        $form = New-HistoryForm -HistoryPath (Join-Path $TestDrive 'none.jsonl')
        try { $form.Text | Should -Match 'last 7 days' } finally { $form.Dispose() }
    }
}
