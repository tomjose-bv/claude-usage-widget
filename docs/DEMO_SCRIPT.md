# 60-second demo script

A screen recording that shows what the widget does and how to get it. Record at 1080p, taskbar visible, Claude Code open in a terminal. Use your real numbers — don't stage or edit percentages.

| Time | On screen | Voice-over / caption |
|---|---|---|
| 0:00–0:07 | Desktop with Claude Code running; zoom on the left end of the taskbar where the widget sits. | "If you live in Claude Code, the usage limits are what interrupt you. This keeps them on your taskbar." |
| 0:07–0:17 | Hold on the widget. Point at the Session row, then the Weekly row. | "Session is the 5-hour window, Weekly is the 7-day one. Bar colour goes green, amber, red. On the right: time until reset." |
| 0:17–0:24 | Hover the widget; tooltip appears with exact reset times. | "Hover for exact reset times." |
| 0:24–0:30 | Drag the widget somewhere else on the screen, then back. | "Drag it anywhere — it remembers where you put it." |
| 0:30–0:42 | Right-click → **History**. The 7-day chart opens; point at the session sawtooth, the weekly line, then the stats text. | "Every poll is saved locally, so you get a week of history, your average burn rate this window, and an estimate of when you'd hit 100% at this pace. Estimates, not promises." |
| 0:42–0:52 | Terminal in the repo folder: run `powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -Startup`. Show the Start menu entry. | "Install is one command. No admin rights, no dependencies — just the PowerShell already in Windows." |
| 0:52–1:00 | Back to the taskbar; caption with the repo link. | "Your token only goes to api.anthropic.com, credentials are read-only, and it's MIT-licensed. Link below." |

## Before recording

- Let the widget run for a few days first so the History chart has real data.
- Close anything private in the background; the terminal should show only the install command.
- Don't show `~/.claude/.credentials.json` or any token on screen.
- If you're rate-limited during recording (amber dot), wait it out rather than spamming *Refresh now*.
