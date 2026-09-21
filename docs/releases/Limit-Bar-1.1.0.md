# Limit Bar 1.1.0

A lighter, quieter app: a narrower menu bar, thresholds you can drag, and far less background work.

## What's new

- The menu bar shows a coloured dot and percentage per provider instead of `Cl:100% Cx:100%`, about a third narrower, and percentages sit in fixed slots so the bar no longer shifts when a value changes width.
- Hover any provider in the menu bar to see its session and weekly balance.
- Alert thresholds can be dragged on the scale, and the coloured bands now show each alert's territory. Thresholds stay ordered, so the labels always match what fires first.
- Limit Bar refreshes the moment you open the menu, instead of showing values up to three minutes old.
- Background checks now run only when usage notifications are on, every 15 minutes rather than every 3, timed around reset windows and paused while your Mac sleeps.
- When a background refresh fails, the affected provider now says so and shows how old its numbers are, rather than presenting stale data as current.
- Limit Bar checks for updates on launch, with a new switch in Settings to turn that off.
- Settings uses the same violet accent as the website.
- Fixed reset times reading "Resets in in 4h".
- Update notes now appear directly in the update dialog rather than loading a web page.

Requires macOS 15.6 or later.
