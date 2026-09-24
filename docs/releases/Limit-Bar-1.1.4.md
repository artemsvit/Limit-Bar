# Limit Bar 1.1.4

Real-time menu bar limit refreshing, faster probes, and permission isolation.

## What's new

- **Real-time menu bar refreshing**: Background quota refreshing now runs continuously for the menu bar display even when low-balance notifications are disabled.
- **Configurable refresh interval**: Choose your preferred refresh frequency in Settings (1 minute, 2 minutes, 5 minutes, or 15 minutes).
- **Faster Claude Code connector**: Reads subscription limits headlessly in ~3 seconds without launching an interactive pseudo-terminal.
- **Permission isolation**: All background CLI probes now execute in an isolated Application Support sandbox, completely preventing macOS from asking for Desktop or Documents access.
- **Manual refresh & native spinner**: Added a one-click refresh button in the menu popover that displays a native macOS progress spinner while checking.
- **Live freshness tooltips**: Hovering over provider indicators in the menu bar shows exactly when limits were last refreshed.

Requires macOS 15.6 or later.
