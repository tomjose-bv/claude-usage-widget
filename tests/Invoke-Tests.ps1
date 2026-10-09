# Runs the Pester test suite. Requires Pester 5 or later:
#   Install-Module Pester -Scope CurrentUser -Force -SkipPublisherCheck
$ErrorActionPreference = 'Stop'
Import-Module Pester -MinimumVersion 5.0
$cfg = New-PesterConfiguration
$cfg.Run.Path = $PSScriptRoot
$cfg.Run.Exit = $true
$cfg.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $cfg
