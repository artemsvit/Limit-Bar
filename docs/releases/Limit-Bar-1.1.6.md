# Limit Bar 1.1.6

Smarter usage alerts, a menu bar that keeps up while you work, and correct Claude limits.

## What's new

- **One alert per threshold**: Usage notifications no longer repeat on every refresh. Each limit alerts once per threshold and only re-arms after the limit actually resets. A newer alert replaces the older one in Notification Center.
- **Clearer alert wording**: Alerts now match the threshold level: "below 50%", "running low", or "almost used up". Only the warn and critical alerts play a sound.
- **Live menu bar while you work**: Limit Bar notices when Codex, Claude Code, or Antigravity is in use and refreshes that provider within seconds, while idle polling stays on your chosen interval.
- **Correct Claude limits**: Claude session and weekly limits are read from their own lines, so weekly shows its real reset time and extra percentages in the usage breakdown are ignored. An unstarted session now shows "Idle · starts on next use".
- **Faster Claude refresh**: A normal Claude refresh starts one CLI process instead of two.
- **Calmer manual refresh**: Only the progress bars show a loading shimmer. Percentages and reset times stay in place, then the new values animate in.

Requires macOS 15.6 or later.
