# Changelog

All notable changes to this project are documented in this file.
The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - 2026-10-13

First public release.

### Added

- Always-on-top Windows overlay showing Claude session (5-hour) and weekly usage,
  with colour-coded bars and countdowns to reset.
- Hover tooltip with exact reset times; right-click menu with Refresh, History,
  Open usage page, Reset position and Exit.
- Polling with exponential backoff on rate limits (honouring `Retry-After`) and
  last-known values kept on screen for up to an hour when a poll fails.
- Local usage history (JSONL) and a History window with a 7-day chart, burn rate
  and an estimated time to reach 100%.
- Per-user `scripts/install.ps1` and `scripts/uninstall.ps1` (Start menu and
  optional Startup shortcuts, no admin rights needed).
- Pure logic split into `ClaudeUsage.Core.psm1` with a Pester 5 test suite.
- Version constant (`Get-WidgetVersion`), shown in the tooltip.
- GitHub Actions CI running the Pester suite on Windows PowerShell 5.1.

### Fixed

- Core functions emit results to the pipeline so `@()` callers get flat arrays.

[0.1.0]: https://github.com/tomjose-bv/claude-usage-widget/releases/tag/v0.1.0
