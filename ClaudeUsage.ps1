# Claude Usage Widget - always-on-top taskbar overlay showing remaining Claude usage.
# Data source: the same endpoint Claude Code's /usage uses, authenticated with
# the Claude Code login stored in ~/.claude/.credentials.json (read-only).
# Pure logic (parsing, formatting, backoff, history) lives in ClaudeUsage.Core.psm1.

Import-Module (Join-Path $PSScriptRoot 'ClaudeUsage.Core.psm1') -Force -DisableNameChecking

$mutex = New-Object System.Threading.Mutex($false, 'Local\ClaudeUsageWidget')
if (-not $mutex.WaitOne(0)) { exit }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
. (Join-Path $PSScriptRoot 'ClaudeUsage.History.ps1')
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
  [DllImport("user32.dll")] public static extern bool ReleaseCapture();
  [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr h, int m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i);
  [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v);
}
"@
[W]::SetProcessDPIAware() | Out-Null
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$CredPath    = Join-Path $env:USERPROFILE '.claude\.credentials.json'
$PosPath     = Join-Path $PSScriptRoot 'position.txt'
$FetchEvery  = 300   # seconds between API calls (the endpoint rate-limits aggressive polling)
$RetryEvery  = 60    # seconds between retries after a non-rate-limit error
$BackoffMax  = 1800  # cap for the 429 backoff
$StaleAfter  = 3600  # keep showing last-known numbers (marked stale) for this long
$HistoryPath = Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget\history.jsonl'   # local only, capped at ~5000 samples

$script:data        = $null
$script:err         = 'Loading...'
$script:lastAttempt = [datetime]::MinValue
$script:lastOk      = $null
$script:backoff     = 0      # current 429 backoff in seconds (0 = not rate limited)
$script:credStamp   = $null  # credentials file timestamp at last attempt (a new /login changes it)

function Update-Usage {
    $script:lastAttempt = Get-Date
    $script:credStamp   = (Get-Item $CredPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
    try {
        $tok = (Get-Content $CredPath -Raw | ConvertFrom-Json).claudeAiOauth.accessToken
        $script:data = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -TimeoutSec 10 `
            -Headers @{ Authorization = "Bearer $tok"; 'anthropic-beta' = 'oauth-2025-04-20' }
        $script:err = $null
        $script:lastOk = Get-Date
        $script:backoff = 0
        # Record a local history sample; never let a disk problem break the widget.
        try {
            $rec = ConvertTo-HistoryRecord $script:data
            if ($rec) { Add-HistoryRecord -Path $HistoryPath -Record $rec }
        } catch {}
    } catch {
        $code = $null; $retryAfter = 0
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            try { $retryAfter = [int]$_.Exception.Response.Headers['Retry-After'] } catch {}
        }
        $f = Get-FailureState -StatusCode $code -RetryAfter $retryAfter -Backoff $script:backoff -FetchEvery $FetchEvery -Max $BackoffMax
        $script:err = $f.Message
        $script:backoff = $f.Backoff
    }
}

function Get-Rows { @(Get-UsageRows $script:data) }

# ---------- window ----------
$form = New-Object System.Windows.Forms.Form
$form.FormBorderStyle = 'None'
$form.ShowInTaskbar   = $false
$form.TopMost         = $true
$form.StartPosition   = 'Manual'
$form.BackColor       = [Drawing.Color]::FromArgb(32, 32, 32)
$form.Opacity         = 0.99   # layered window - needed to draw over the Win11 taskbar
$form.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'NonPublic,Instance').SetValue($form, $true, $null)

$gTmp = $form.CreateGraphics(); $scale = $gTmp.DpiX / 96; $gTmp.Dispose()
$baseW = 250; $baseH = 40
$form.Size = New-Object Drawing.Size([int]($baseW * $scale), [int]($baseH * $scale))

function Get-DefaultLocation {
    $scr = [System.Windows.Forms.Screen]::PrimaryScreen
    $tbH = $scr.Bounds.Bottom - $scr.WorkingArea.Bottom
    if ($tbH -ge $form.Height) {
        # on the empty left end of the taskbar (Win11 centers its icons)
        $y = $scr.Bounds.Bottom - $tbH + [int](($tbH - $form.Height) / 2)
        $x = $scr.Bounds.Left + [int](12 * $scale)
    } else {
        $y = $scr.WorkingArea.Bottom - $form.Height - [int](8 * $scale)
        $x = $scr.WorkingArea.Right - $form.Width - [int](10 * $scale)
    }
    New-Object Drawing.Point($x, $y)
}

$loc = $null
if (Test-Path $PosPath) {
    $xy = (Get-Content $PosPath -Raw).Trim() -split ','
    if ($xy.Count -eq 2) {
        $pt = New-Object Drawing.Point([int]$xy[0], [int]$xy[1])
        $onScreen = [System.Windows.Forms.Screen]::AllScreens | Where-Object { $_.Bounds.Contains($pt) }
        if ($onScreen) { $loc = $pt }
    }
}
if (-not $loc) { $loc = Get-DefaultLocation }
$form.Location = $loc

$fontLabel = New-Object Drawing.Font('Segoe UI', 12, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$fontValue = New-Object Drawing.Font('Segoe UI Semibold', 12, [Drawing.FontStyle]::Regular, [Drawing.GraphicsUnit]::Pixel)
$brGray    = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(170, 170, 170))
$brWhite   = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(240, 240, 240))
$brTrack   = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(62, 62, 62))
$brRed     = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(230, 95, 90))
$brGreen   = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(110, 190, 120))
$brAmber   = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(225, 175, 70))

function Get-LevelColor($left) {
    $rgb = Get-LevelRgb (Get-UsageLevel $left)
    return [Drawing.Color]::FromArgb($rgb[0], $rgb[1], $rgb[2])
}

$form.Add_Paint({
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode     = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $g.ScaleTransform($scale, $scale)

    # Live = latest fetch succeeded recently. Otherwise keep showing last-known numbers (amber dot) for a while.
    $state = Get-DisplayState -HasData ([bool]$script:data) -HasError ([bool]$script:err) -LastOk $script:lastOk `
                              -FetchEvery $FetchEvery -StaleAfter $StaleAfter
    $live  = $state -eq 'Live'
    $rows  = if ($state -ne 'None') { @(Get-Rows) } else { @() }
    if ($rows.Count -eq 0) {
        $msg = if ($script:err) { $script:err } else { 'Updating...' }
        if ($script:lastOk) { $msg += ' - last ' + $script:lastOk.ToString('HH:mm') }
        $g.FillEllipse($brRed, 8, 9, 6, 6)
        $g.DrawString('Not live', $fontValue, $brWhite, 18, 3)
        $g.DrawString($msg, $fontLabel, $brGray, 8, 21)
        return
    }
    $y = 3
    foreach ($r in $rows) {
        $g.DrawString($r.Name, $fontLabel, $brGray, 6, $y)
        $g.FillRectangle($brTrack, 58, $y + 6, 60, 5)
        $fill = New-Object Drawing.SolidBrush((Get-LevelColor $r.Left))
        $g.FillRectangle($fill, 58, $y + 6, [single](60 * $r.Left / 100), 5)
        $fill.Dispose()
        $g.DrawString(('{0:0}% left' -f $r.Left), $fontValue, $brWhite, 124, $y)
        $g.DrawString((Format-Left $r.Resets), $fontLabel, $brGray, 190, $y)
        $y += 18
    }
    $dot = if ($live) { $brGreen } else { $brAmber }
    $g.FillEllipse($dot, 242, 4, 5, 5)   # green = live, amber = last-known (hover for why)
})

# ---------- tooltip with full detail ----------
$tip = New-Object System.Windows.Forms.ToolTip
$form.Add_MouseEnter({
    $lines = @()
    if ($script:data) {
        foreach ($r in Get-Rows) {
            $reset = Get-ResetUtc $r.Resets
            $at = if ($reset) { $reset.ToLocalTime().ToString('ddd HH:mm') } else { 'unknown' }
            $lines += '{0}: {1:0}% left - resets in {2} ({3})' -f $r.Name, $r.Left, (Format-Left $r.Resets), $at
        }
    }
    if ($script:lastOk) { $lines += 'Updated ' + $script:lastOk.ToString('HH:mm:ss') }
    if ($script:err)    { $lines += $script:err }
    $lines += 'Drag to move - right-click for options'
    $tip.SetToolTip($form, ($lines -join "`n"))
})

# ---------- drag to move (position is remembered) ----------
$form.Add_MouseDown({
    param($s, $e)
    if ($e.Button -eq 'Left') {
        [W]::ReleaseCapture() | Out-Null
        [W]::SendMessage($form.Handle, 0xA1, [IntPtr]2, [IntPtr]::Zero) | Out-Null   # returns when drag ends
        try { "$($form.Left),$($form.Top)" | Set-Content $PosPath -Encoding ascii } catch {}
    }
})

# ---------- right-click menu ----------
$script:histForm = $null
function Show-History {
    if ($script:histForm -and -not $script:histForm.IsDisposed) { $script:histForm.Activate(); return }
    try {
        $script:histForm = New-HistoryForm -HistoryPath $HistoryPath -Scale $scale -Data $script:data
        $script:histForm.Show()
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Could not open history: $($_.Exception.Message)", 'Claude Usage') | Out-Null
    }
}

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Items.Add('Refresh now').Add_Click({ Update-Usage; $form.Invalidate() }) | Out-Null
$menu.Items.Add('History').Add_Click({ Show-History }) | Out-Null
$menu.Items.Add('Open usage page').Add_Click({ Start-Process 'https://claude.ai/settings/usage' }) | Out-Null
$menu.Items.Add('Reset position').Add_Click({
    $form.Location = Get-DefaultLocation
    Remove-Item $PosPath -ErrorAction SilentlyContinue
}) | Out-Null
$menu.Items.Add('-') | Out-Null
$menu.Items.Add('Exit').Add_Click({ $form.Close() }) | Out-Null
$form.ContextMenuStrip = $menu

# ---------- keep above the taskbar, tick countdowns, poll API ----------
$form.Add_Load({
    $h = $form.Handle
    [W]::SetWindowLong($h, -20, ([W]::GetWindowLong($h, -20) -bor 0x80)) | Out-Null  # WS_EX_TOOLWINDOW: hide from Alt+Tab
    Update-Usage
})

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if (-not $menu.Visible) {
        # HWND_TOPMOST, SWP_NOMOVE|SWP_NOSIZE|SWP_NOACTIVATE - re-assert so the taskbar can't cover us
        [W]::SetWindowPos($form.Handle, [IntPtr](-1), 0, 0, 0, 0, 0x13) | Out-Null
    }
    # Retry immediately after a fresh login / token refresh rewrites the credentials file
    $stamp = (Get-Item $CredPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
    if ($script:err -and $stamp -and $stamp -ne $script:credStamp) { Update-Usage }
    $wait = Get-PollWait -Backoff $script:backoff -HasError ([bool]$script:err) -RetryEvery $RetryEvery -FetchEvery $FetchEvery
    if (((Get-Date) - $script:lastAttempt).TotalSeconds -ge $wait) { Update-Usage }
    $form.Invalidate()
})
$timer.Start()

[System.Windows.Forms.Application]::Run($form)
$mutex.ReleaseMutex()
