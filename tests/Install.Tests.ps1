# Pester 5+ tests for scripts/install.ps1 and scripts/uninstall.ps1, run against temp folders only.

BeforeAll {
    $script:Repo = Split-Path -Parent $PSScriptRoot
    $script:Root = Join-Path $TestDrive 'cuw'
    $script:P = @{
        InstallDir   = Join-Path $script:Root 'app'
        StartMenuDir = Join-Path $script:Root 'menu'
        StartupDir   = Join-Path $script:Root 'startup'
    }
    $script:Link = 'Claude Usage Widget.lnk'
}

Describe 'install.ps1' {
    BeforeAll {
        $p = $script:P
        & (Join-Path $script:Repo 'scripts\install.ps1') @p -Startup -NoLaunch 6>$null
        $shell = New-Object -ComObject WScript.Shell
        $script:Lnk = $shell.CreateShortcut((Join-Path $p.StartMenuDir $script:Link))
    }

    It 'copies the widget files' {
        foreach ($f in 'ClaudeUsage.ps1', 'ClaudeUsage.Core.psm1', 'ClaudeUsage.History.ps1', 'LICENSE') {
            Join-Path $script:P.InstallDir $f | Should -Exist
        }
    }
    It 'creates Start menu and Startup shortcuts' {
        Join-Path $script:P.StartMenuDir $script:Link | Should -Exist
        Join-Path $script:P.StartupDir $script:Link | Should -Exist
    }
    It 'targets Windows PowerShell with a hidden window and the installed script' {
        $script:Lnk.TargetPath | Should -Match 'WindowsPowerShell\\v1\.0\\powershell\.exe$'
        $script:Lnk.Arguments | Should -Match '-WindowStyle Hidden'
        $script:Lnk.Arguments | Should -Match '-NoProfile'
        $script:Lnk.Arguments | Should -BeLike ('*"' + (Join-Path $script:P.InstallDir 'ClaudeUsage.ps1') + '"*')
        $script:Lnk.WindowStyle | Should -Be 7
    }
    It 'skips the Startup shortcut without -Startup' {
        $p = @{ InstallDir = Join-Path $script:Root 'app2'; StartMenuDir = Join-Path $script:Root 'menu2'; StartupDir = Join-Path $script:Root 'startup2' }
        & (Join-Path $script:Repo 'scripts\install.ps1') @p -NoLaunch 6>$null
        Join-Path $p.StartMenuDir $script:Link | Should -Exist
        Join-Path $p.StartupDir $script:Link | Should -Not -Exist
    }
    It 'upgrades in place and keeps the saved position' {
        Set-Content (Join-Path $script:P.InstallDir 'position.txt') '10,20'
        $p = $script:P
        & (Join-Path $script:Repo 'scripts\install.ps1') @p -NoLaunch 6>$null
        Get-Content (Join-Path $script:P.InstallDir 'position.txt') | Should -Be '10,20'
    }
}

Describe 'uninstall.ps1' {
    BeforeAll {
        # TestDrive is reset between Describe blocks, so install fresh.
        $p = $script:P
        & (Join-Path $script:Repo 'scripts\install.ps1') @p -Startup -NoLaunch 6>$null
    }
    It 'removes only the Startup shortcut with -StartupOnly' {
        $p = $script:P
        & (Join-Path $script:Repo 'scripts\uninstall.ps1') @p -DataDir (Join-Path $script:Root 'data') -StartupOnly 6>$null
        Join-Path $p.StartupDir $script:Link | Should -Not -Exist
        Join-Path $p.StartMenuDir $script:Link | Should -Exist
    }
    It 'removes shortcuts and files, keeping history unless -RemoveData' {
        $p = $script:P
        $data = Join-Path $script:Root 'data'
        New-Item -ItemType Directory $data -Force | Out-Null
        Set-Content (Join-Path $data 'history.jsonl') '{}'
        & (Join-Path $script:Repo 'scripts\uninstall.ps1') @p -DataDir $data 6>$null
        Join-Path $p.StartMenuDir $script:Link | Should -Not -Exist
        $p.InstallDir | Should -Not -Exist
        Join-Path $data 'history.jsonl' | Should -Exist
        & (Join-Path $script:Repo 'scripts\uninstall.ps1') @p -DataDir $data -RemoveData 6>$null
        $data | Should -Not -Exist
    }
    It 'never deletes unrelated files in the install folder' {
        $dir = Join-Path $script:Root 'shared'
        New-Item -ItemType Directory $dir -Force | Out-Null
        Set-Content (Join-Path $dir 'ClaudeUsage.ps1') '#'
        Set-Content (Join-Path $dir 'keep-me.txt') 'x'
        & (Join-Path $script:Repo 'scripts\uninstall.ps1') -InstallDir $dir -StartMenuDir $dir -StartupDir $dir -DataDir (Join-Path $script:Root 'nodata') 6>$null
        Join-Path $dir 'keep-me.txt' | Should -Exist
        Join-Path $dir 'ClaudeUsage.ps1' | Should -Not -Exist
    }
}
