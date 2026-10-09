<#
.SYNOPSIS
    Installs the Claude Usage Widget for the current user (no admin rights needed).

.DESCRIPTION
    Copies the widget files to -InstallDir and creates a Start menu shortcut that runs
    it with a hidden PowerShell window. With -Startup it also starts with Windows.
    Re-running the script upgrades in place and keeps your saved widget position.

.EXAMPLE
    .\scripts\install.ps1 -Startup

.EXAMPLE
    # Dry run into a scratch folder (nothing touches your real Start menu)
    .\scripts\install.ps1 -InstallDir $env:TEMP\cuw\app -StartMenuDir $env:TEMP\cuw\menu -StartupDir $env:TEMP\cuw\startup -Startup -NoLaunch
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallDir   = (Join-Path $env:LOCALAPPDATA 'Programs\ClaudeUsageWidget'),
    [string]$StartMenuDir = [Environment]::GetFolderPath('Programs'),
    [string]$StartupDir   = [Environment]::GetFolderPath('Startup'),
    [switch]$Startup,     # also start the widget when you sign in to Windows
    [switch]$NoLaunch     # don't start the widget after installing
)
$ErrorActionPreference = 'Stop'

$source   = Split-Path -Parent $PSScriptRoot
$files    = 'ClaudeUsage.ps1', 'ClaudeUsage.Core.psm1', 'ClaudeUsage.History.ps1', 'LICENSE'
$linkName = 'Claude Usage Widget.lnk'
$psExe    = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

foreach ($f in $files) {
    if (-not (Test-Path (Join-Path $source $f))) { throw "Missing $f in $source - run this script from a full copy of the repository." }
}

# 1. Copy the app
if ($PSCmdlet.ShouldProcess($InstallDir, 'Copy widget files')) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    foreach ($f in $files) {
        Copy-Item -Path (Join-Path $source $f) -Destination $InstallDir -Force
        Unblock-File -Path (Join-Path $InstallDir $f) -ErrorAction SilentlyContinue   # clear "downloaded from internet" mark
    }
}

# 2. Shortcuts: powershell.exe, hidden window, no profile
$script  = Join-Path $InstallDir 'ClaudeUsage.ps1'
$psArgs  = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $script

function New-WidgetShortcut([string]$Dir) {
    $path = Join-Path $Dir $linkName
    if (-not $PSCmdlet.ShouldProcess($path, 'Create shortcut')) { return }
    New-Item -ItemType Directory -Path $Dir -Force | Out-Null
    $shell = New-Object -ComObject WScript.Shell
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath       = $psExe
    $lnk.Arguments        = $psArgs
    $lnk.WorkingDirectory = $InstallDir
    $lnk.WindowStyle      = 7   # minimized, so no console flashes up before -WindowStyle Hidden applies
    $lnk.Description      = 'Shows remaining Claude plan usage on the taskbar'
    $lnk.IconLocation     = "$psExe,0"
    $lnk.Save()
    [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    Write-Host "  shortcut: $path"
}

Write-Host "Installed to $InstallDir"
New-WidgetShortcut $StartMenuDir
if ($Startup) {
    New-WidgetShortcut $StartupDir
} elseif (Test-Path (Join-Path $StartupDir $linkName)) {
    Write-Host "  (existing Startup shortcut left in place - run uninstall.ps1 -StartupOnly to remove it)"
}

# 3. Launch (the widget exits immediately if a copy is already running)
if (-not $NoLaunch -and $PSCmdlet.ShouldProcess($script, 'Start widget')) {
    Start-Process -FilePath $psExe -ArgumentList $psArgs -WindowStyle Hidden -WorkingDirectory $InstallDir
    Write-Host 'Started. Look for the overlay on the left end of your taskbar.'
}
