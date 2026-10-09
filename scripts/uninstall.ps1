<#
.SYNOPSIS
    Removes the Claude Usage Widget installed by install.ps1.

.DESCRIPTION
    Deletes the Start menu and Startup shortcuts and the installed widget files.
    Your local usage history (%LOCALAPPDATA%\ClaudeUsageWidget) is kept unless you pass -RemoveData.
    Only files the installer created are deleted; the install folder is removed only if it is then empty.
    Exit the widget first (right-click > Exit) so it doesn't keep running from memory.

.EXAMPLE
    .\scripts\uninstall.ps1 -RemoveData
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$InstallDir   = (Join-Path $env:LOCALAPPDATA 'Programs\ClaudeUsageWidget'),
    [string]$StartMenuDir = [Environment]::GetFolderPath('Programs'),
    [string]$StartupDir   = [Environment]::GetFolderPath('Startup'),
    [string]$DataDir      = (Join-Path $env:LOCALAPPDATA 'ClaudeUsageWidget'),
    [switch]$RemoveData,  # also delete the local usage history
    [switch]$StartupOnly  # only remove the "start with Windows" shortcut
)
$ErrorActionPreference = 'Stop'
$linkName = 'Claude Usage Widget.lnk'

function Remove-IfExists([string]$Path) {
    if ((Test-Path -LiteralPath $Path) -and $PSCmdlet.ShouldProcess($Path, 'Remove')) {
        Remove-Item -LiteralPath $Path -Force
        Write-Host "  removed $Path"
    }
}

Remove-IfExists (Join-Path $StartupDir $linkName)
if ($StartupOnly) { return }
Remove-IfExists (Join-Path $StartMenuDir $linkName)

foreach ($f in 'ClaudeUsage.ps1', 'ClaudeUsage.Core.psm1', 'ClaudeUsage.History.ps1', 'LICENSE', 'position.txt') {
    Remove-IfExists (Join-Path $InstallDir $f)
}
if ((Test-Path -LiteralPath $InstallDir) -and -not (Get-ChildItem -LiteralPath $InstallDir -Force)) {
    if ($PSCmdlet.ShouldProcess($InstallDir, 'Remove empty folder')) { Remove-Item -LiteralPath $InstallDir -Force; Write-Host "  removed $InstallDir" }
}

if ($RemoveData) {
    Remove-IfExists (Join-Path $DataDir 'history.jsonl')
    if ((Test-Path -LiteralPath $DataDir) -and -not (Get-ChildItem -LiteralPath $DataDir -Force)) {
        if ($PSCmdlet.ShouldProcess($DataDir, 'Remove empty folder')) { Remove-Item -LiteralPath $DataDir -Force; Write-Host "  removed $DataDir" }
    }
} elseif (Test-Path -LiteralPath $DataDir) {
    Write-Host "Kept usage history in $DataDir (use -RemoveData to delete it)."
}

$running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*$InstallDir*ClaudeUsage.ps1*" }
if ($running) { Write-Host 'The widget is still running - right-click it and choose Exit.' }
Write-Host 'Uninstalled.'
