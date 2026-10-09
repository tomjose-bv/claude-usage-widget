# Pester 5+ tests for ClaudeUsage.Core.psm1. Run:  .\tests\Invoke-Tests.ps1

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ClaudeUsage.Core.psm1') -Force
    $script:Now = [datetime]::new(2026, 1, 15, 12, 0, 0, [DateTimeKind]::Utc)

    function New-Usage($sessionUsed, $sessionReset, $weeklyUsed, $weeklyReset) {
        [pscustomobject]@{
            five_hour = [pscustomobject]@{ utilization = $sessionUsed; resets_at = $sessionReset }
            seven_day = [pscustomobject]@{ utilization = $weeklyUsed;  resets_at = $weeklyReset }
        }
    }
}

Describe 'Get-ResetUtc' {
    It 'parses an ISO-8601 offset timestamp to UTC' {
        $r = Get-ResetUtc '2026-01-15T14:30:00.321323+02:00'
        $r.Kind | Should -Be 'Utc'
        $r.ToString('HH:mm') | Should -Be '12:30'
    }
    It 'passes a [datetime] through as UTC' {
        (Get-ResetUtc $script:Now) | Should -Be $script:Now
    }
    It 'returns $null for empty input' {
        Get-ResetUtc $null | Should -BeNullOrEmpty
        Get-ResetUtc ''    | Should -BeNullOrEmpty
    }
}

Describe 'Format-Left' {
    It 'shows -- when the reset time is unknown' {
        Format-Left $null -Now $script:Now | Should -Be '--'
    }
    It 'shows now when the reset is in the past' {
        Format-Left $script:Now.AddMinutes(-1) -Now $script:Now | Should -Be 'now'
    }
    It 'rounds minutes up under an hour' {
        Format-Left $script:Now.AddSeconds(61) -Now $script:Now | Should -Be '2m'
        Format-Left $script:Now.AddMinutes(59) -Now $script:Now | Should -Be '59m'
    }
    It 'shows hours and zero-padded minutes under a day' {
        Format-Left $script:Now.AddHours(2).AddMinutes(5) -Now $script:Now | Should -Be '2h 05m'
    }
    It 'shows days and hours from one day up' {
        Format-Left $script:Now.AddDays(3).AddHours(4).AddMinutes(30) -Now $script:Now | Should -Be '3d 4h'
    }
    It 'accepts the API string format' {
        Format-Left '2026-01-15T13:00:00+00:00' -Now $script:Now | Should -Be '1h 00m'
    }
}

Describe 'Get-UsageRows' {
    It 'returns Session and Weekly rows with used and left percentages' {
        $rows = @(Get-UsageRows (New-Usage 14.0 '2026-01-15T15:00:00+00:00' 35 '2026-01-19T13:00:00+00:00'))
        $rows.Count | Should -Be 2
        $rows[0].Name | Should -Be 'Session'
        $rows[0].Used | Should -Be 14
        $rows[0].Left | Should -Be 86
        $rows[1].Name | Should -Be 'Weekly'
        $rows[1].Left | Should -Be 65
        $rows[1].Resets | Should -Be '2026-01-19T13:00:00+00:00'
    }
    It 'clamps out-of-range utilization to 0..100' {
        $rows = @(Get-UsageRows (New-Usage 130 $null -5 $null))
        $rows[0].Left | Should -Be 0
        $rows[1].Left | Should -Be 100
    }
    It 'keeps fractional utilization' {
        $rows = @(Get-UsageRows (New-Usage 12.5 $null 0.4 $null))
        $rows[0].Left | Should -Be 87.5
        $rows[1].Used | Should -Be 0.4
    }
    It 'skips a window that is null or missing' {
        $rows = @(Get-UsageRows ([pscustomobject]@{ five_hour = $null; seven_day = [pscustomobject]@{ utilization = 10; resets_at = $null } }))
        $rows.Count | Should -Be 1
        $rows[0].Name | Should -Be 'Weekly'
        $rows[0].Resets | Should -BeNullOrEmpty
    }
    It 'skips a window whose utilization is missing or not numeric' {
        $data = [pscustomobject]@{
            five_hour = [pscustomobject]@{ resets_at = '2026-01-15T15:00:00+00:00' }
            seven_day = [pscustomobject]@{ utilization = 'n/a' }
        }
        @(Get-UsageRows $data).Count | Should -Be 0
    }
    It 'ignores unrelated fields and handles $null / empty responses' {
        @(Get-UsageRows $null).Count | Should -Be 0
        @(Get-UsageRows ([pscustomobject]@{ extra_usage = @{ is_enabled = $false } })).Count | Should -Be 0
    }
    It 'accepts hashtables as well as objects' {
        $rows = @(Get-UsageRows @{ five_hour = @{ utilization = 50; resets_at = $null } })
        $rows[0].Left | Should -Be 50
    }
}

Describe 'Get-UsageLevel' {
    It 'is <Expected> at <Left>% left' -TestCases @(
        @{ Left = 100;  Expected = 'Green' }
        @{ Left = 50.1; Expected = 'Green' }
        @{ Left = 50;   Expected = 'Amber' }
        @{ Left = 20.1; Expected = 'Amber' }
        @{ Left = 20;   Expected = 'Red' }
        @{ Left = 0;    Expected = 'Red' }
    ) {
        Get-UsageLevel $Left | Should -Be $Expected
    }
    It 'maps levels to the widget palette' {
        (Get-LevelRgb 'Green') -join ',' | Should -Be '110,190,120'
        (Get-LevelRgb 'Amber') -join ',' | Should -Be '225,175,70'
        (Get-LevelRgb 'Red')   -join ',' | Should -Be '230,95,90'
    }
}

Describe 'Get-NextBackoff' {
    It 'starts at the poll interval' {
        Get-NextBackoff -Current 0 -FetchEvery 300 -Max 1800 | Should -Be 300
    }
    It 'doubles on each consecutive 429' {
        Get-NextBackoff -Current 300 -FetchEvery 300 -Max 1800 | Should -Be 600
        Get-NextBackoff -Current 600 -FetchEvery 300 -Max 1800 | Should -Be 1200
    }
    It 'is capped at Max' {
        Get-NextBackoff -Current 1200 -FetchEvery 300 -Max 1800 | Should -Be 1800
        Get-NextBackoff -Current 1800 -FetchEvery 300 -Max 1800 | Should -Be 1800
    }
    It 'honours a longer Retry-After, still capped' {
        Get-NextBackoff -Current 0 -RetryAfter 900  -FetchEvery 300 -Max 1800 | Should -Be 900
        Get-NextBackoff -Current 0 -RetryAfter 9999 -FetchEvery 300 -Max 1800 | Should -Be 1800
    }
}

Describe 'Get-FailureState' {
    It 'reports login expiry on 401 and clears backoff' {
        $s = Get-FailureState -StatusCode 401 -Backoff 600
        $s.Message | Should -Be 'Login expired - open Claude Code'
        $s.Backoff | Should -Be 0
    }
    It 'backs off on 429 and shows minutes until retry' {
        $s = Get-FailureState -StatusCode 429 -Backoff 300 -FetchEvery 300 -Max 1800
        $s.Backoff | Should -Be 600
        $s.Message | Should -Be 'Rate limited, retry in 10m'
    }
    It 'treats anything else as offline and keeps the backoff' {
        $s = Get-FailureState -StatusCode $null -Backoff 600
        $s.Message | Should -Be 'Offline, retrying'
        $s.Backoff | Should -Be 600
        (Get-FailureState -StatusCode 500).Message | Should -Be 'Offline, retrying'
    }
}

Describe 'Get-PollWait' {
    It 'uses the backoff when rate limited' { Get-PollWait -Backoff 1200 -HasError $true | Should -Be 1200 }
    It 'retries sooner after other errors' { Get-PollWait -HasError $true -RetryEvery 60 | Should -Be 60 }
    It 'polls at the normal interval otherwise' { Get-PollWait -FetchEvery 300 | Should -Be 300 }
}

Describe 'Get-DisplayState' {
    It 'is Live right after a successful poll' {
        Get-DisplayState -HasData $true -HasError $false -LastOk $script:Now.AddSeconds(-10) -Now $script:Now | Should -Be 'Live'
    }
    It 'is Stale when the last poll failed but data is recent' {
        Get-DisplayState -HasData $true -HasError $true -LastOk $script:Now.AddMinutes(-10) -Now $script:Now | Should -Be 'Stale'
    }
    It 'is Stale when no poll has succeeded for longer than one interval' {
        Get-DisplayState -HasData $true -HasError $false -LastOk $script:Now.AddMinutes(-6) -Now $script:Now | Should -Be 'Stale'
    }
    It 'is None when data is older than StaleAfter or missing' {
        Get-DisplayState -HasData $true -HasError $true -LastOk $script:Now.AddHours(-2) -Now $script:Now | Should -Be 'None'
        Get-DisplayState -HasData $false -HasError $true -LastOk $null -Now $script:Now | Should -Be 'None'
    }
}

Describe 'History file' {
    BeforeEach {
        $script:Path = Join-Path $TestDrive ("h{0}\history.jsonl" -f [guid]::NewGuid().ToString('N'))
    }

    It 'builds a record from a usage response' {
        $rec = ConvertTo-HistoryRecord (New-Usage 14 '2026-01-15T15:00:00.123+00:00' 35 '2026-01-19T13:00:00+00:00') -Timestamp $script:Now
        $rec.ts | Should -Be '2026-01-15T12:00:00.0000000Z'
        $rec.session | Should -Be 14
        $rec.weekly | Should -Be 35
        $rec.session_resets | Should -Match '^2026-01-15T15:00:00\.123'
    }
    It 'returns no record when the response has no usable windows' {
        ConvertTo-HistoryRecord ([pscustomobject]@{ five_hour = $null }) | Should -BeNullOrEmpty
    }
    It 'keeps a null for a missing window' {
        $rec = ConvertTo-HistoryRecord ([pscustomobject]@{ seven_day = @{ utilization = 40; resets_at = $null } }) -Timestamp $script:Now
        $rec.session | Should -BeNullOrEmpty
        $rec.weekly | Should -Be 40
        $rec.weekly_resets | Should -BeNullOrEmpty
    }
    It 'round-trips records through the JSONL file, creating the folder' {
        foreach ($i in 0..2) {
            $rec = ConvertTo-HistoryRecord (New-Usage (10 + $i) '2026-01-15T15:00:00+00:00' 30 '2026-01-19T13:00:00+00:00') -Timestamp $script:Now.AddMinutes(5 * $i)
            Add-HistoryRecord -Path $script:Path -Record $rec
        }
        $h = @(Read-History -Path $script:Path)
        $h.Count | Should -Be 3
        $h[2].Session | Should -Be 12
        $h[2].Weekly | Should -Be 30
        $h[2].Time | Should -Be $script:Now.AddMinutes(10)
        $h[0].SessionResets | Should -Be ([datetime]::new(2026, 1, 15, 15, 0, 0, [DateTimeKind]::Utc))
    }
    It 'caps the file at MaxRecords, keeping the newest' {
        foreach ($i in 1..12) {
            Add-HistoryRecord -Path $script:Path -MaxRecords 5 -Record ([pscustomobject]@{ ts = $script:Now.AddMinutes($i).ToString('o'); session = $i; weekly = 1 })
        }
        $h = @(Read-History -Path $script:Path)
        $h.Count | Should -Be 5
        $h[0].Session | Should -Be 8
        $h[-1].Session | Should -Be 12
    }
    It 'filters by Since and skips corrupt lines' {
        $lines = @(
            '{"ts":"2026-01-01T00:00:00Z","session":5,"weekly":1}',
            'not json {',
            '',
            '{"ts":"2026-01-15T11:00:00Z","session":20,"weekly":null}',
            '{"session":99}'
        )
        New-Item -ItemType Directory -Path (Split-Path $script:Path) -Force | Out-Null
        Set-Content -Path $script:Path -Value $lines -Encoding UTF8
        $h = @(Read-History -Path $script:Path -Since $script:Now.AddDays(-7))
        $h.Count | Should -Be 1
        $h[0].Session | Should -Be 20
        $h[0].Weekly | Should -BeNullOrEmpty
    }
    It 'returns an empty list when the file does not exist' {
        @(Read-History -Path (Join-Path $TestDrive 'missing.jsonl')).Count | Should -Be 0
    }
}

Describe 'Get-BurnEstimate' {
    It 'derives the average rate from the window start (reset - window length)' {
        # 5h session resetting in 3h => 2h elapsed; 40% used => 20%/h; 60% left => 3h => exactly at reset
        $e = Get-BurnEstimate -Used 40 -Resets $script:Now.AddHours(3) -WindowHours 5 -Now $script:Now
        $e.RatePerHour | Should -Be 20
        $e.HoursTo100 | Should -Be 3
        $e.WillHitLimit | Should -BeFalse
    }
    It 'flags a limit hit when the projection lands before the reset' {
        # 4h elapsed, 90% used => 22.5%/h; 10% left => ~27m, reset in 1h
        $e = Get-BurnEstimate -Used 90 -Resets $script:Now.AddHours(1) -WindowHours 5 -Now $script:Now
        $e.WillHitLimit | Should -BeTrue
        [math]::Round($e.HoursTo100 * 60) | Should -Be 27
        $e.ProjectedAt | Should -BeLessThan $e.ResetsAt
    }
    It 'treats 100% used as already at the limit' {
        $e = Get-BurnEstimate -Used 100 -Resets $script:Now.AddHours(1) -WindowHours 5 -Now $script:Now
        $e.HoursTo100 | Should -Be 0
        $e.WillHitLimit | Should -BeTrue
    }
    It 'gives no projection at 0% used' {
        $e = Get-BurnEstimate -Used 0 -Resets $script:Now.AddHours(2) -WindowHours 5 -Now $script:Now
        $e.RatePerHour | Should -Be 0
        $e.ProjectedAt | Should -BeNullOrEmpty
        $e.WillHitLimit | Should -BeFalse
    }
    It 'withholds a rate early in the window, when it would be noise' {
        $e = Get-BurnEstimate -Used 10 -Resets $script:Now.AddHours(4.9) -WindowHours 5 -Now $script:Now
        $e.RatePerHour | Should -BeNullOrEmpty
    }
    It 'returns empty estimates with no or past reset time' {
        (Get-BurnEstimate -Used 50 -Resets $null -WindowHours 5 -Now $script:Now).RatePerHour | Should -BeNullOrEmpty
        (Get-BurnEstimate -Used 50 -Resets $script:Now.AddMinutes(-1) -WindowHours 5 -Now $script:Now).RatePerHour | Should -BeNullOrEmpty
    }
    It 'works on a weekly window' {
        # 168h window resetting in 84h => 84h elapsed; 42% used => 0.5%/h
        $e = Get-BurnEstimate -Used 42 -Resets $script:Now.AddHours(84) -WindowHours (Get-WindowHours 'Weekly') -Now $script:Now
        $e.RatePerHour | Should -Be 0.5
        $e.HoursTo100 | Should -Be 116
        $e.WillHitLimit | Should -BeFalse
    }
}

Describe 'Get-HistorySummary' {
    It 'handles an empty history' {
        $s = Get-HistorySummary @()
        $s.Samples | Should -Be 0
        $s.PeakSession | Should -BeNullOrEmpty
    }
    It 'counts samples, peaks and distinct session windows (ignoring sub-second reset jitter)' {
        $r1 = [datetime]::new(2026, 1, 14, 10, 0, 0, [DateTimeKind]::Utc)
        $r2 = [datetime]::new(2026, 1, 15, 15, 0, 0, [DateTimeKind]::Utc)
        $recs = @(
            [pscustomobject]@{ Time = $r1.AddHours(-3); Session = 30; Weekly = 10; SessionResets = $r1; WeeklyResets = $null }
            [pscustomobject]@{ Time = $r1.AddHours(-1); Session = 95; Weekly = 18; SessionResets = $r1.AddMilliseconds(321); WeeklyResets = $null }
            [pscustomobject]@{ Time = $r2.AddHours(-2); Session = 40; Weekly = 25; SessionResets = $r2; WeeklyResets = $null }
            [pscustomobject]@{ Time = $r2.AddHours(-1); Session = $null; Weekly = 26; SessionResets = $null; WeeklyResets = $null }
        )
        $s = Get-HistorySummary $recs
        $s.Samples | Should -Be 4
        $s.PeakSession | Should -Be 95
        $s.PeakWeekly | Should -Be 26
        $s.SessionWindows | Should -Be 2
        $s.NearLimitWindows | Should -Be 1
        $s.First | Should -Be $r1.AddHours(-3)
    }
}

Describe 'Format-Duration' {
    It 'formats <Hours>h as <Expected>' -TestCases @(
        @{ Hours = 0.75; Expected = '45m' }
        @{ Hours = 3.5;  Expected = '3h 30m' }
        @{ Hours = 53;   Expected = '2d 5h' }
        @{ Hours = -1;   Expected = '0m' }
    ) {
        Format-Duration $Hours | Should -Be $Expected
    }
}
