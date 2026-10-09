# Claude Usage Widget

A tiny always-on-top Windows overlay that shows how much of your **Claude** plan usage is left, without opening a browser or typing `/usage`.

```
Session ━━━━━━━━━━━━  61% left   2h 14m
Weekly  ━━━━━━━━━━━━  83% left   4d 6h
```

## Features

- **Session (5-hour) and Weekly** usage, each with a colour-coded bar (green / amber / red) and a countdown to reset
- **Sits on the taskbar** — on the empty left end on Windows 11, draggable anywhere, and remembers its position
- **Hover** for exact reset times; **right-click** for Refresh, Open usage page, Reset position and Exit
- **Resilient polling:**
  - checks every 5 minutes
  - backs off exponentially (up to 30 minutes) when rate-limited
  - keeps showing the last-known numbers, marked with an amber dot, for up to an hour
  - recovers instantly after you sign in again
- **Zero dependencies** — a single PowerShell script using WinForms, which comes built into Windows

## Requirements

- Windows 10/11 with Windows PowerShell 5.1 (preinstalled)
- [Claude Code](https://claude.com/claude-code), signed in with a Claude subscription

## Run

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ClaudeUsage.ps1
```

**Start with Windows:** create a shortcut with the command above and put it in `shell:startup`.

## How it works

- **Data source:** the widget reads the OAuth access token that Claude Code stores in `~/.claude/.credentials.json`. It only reads that file and never modifies it.
- **What it calls:** the same usage endpoint that Claude Code's `/usage` command uses.
- **Single instance:** a mutex ensures only one copy runs at a time.

> **Note:** this relies on an undocumented endpoint, so it may break if it changes. If the widget shows *Login expired*, open Claude Code, or run `/login`, to refresh the token.

## Privacy

The token is sent only to `api.anthropic.com`. Nothing is logged or stored except the widget's screen position.

## License

MIT
