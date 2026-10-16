# Limit Bar 1.2.0

Local usage history, recovery alerts, and clearer connection and notification controls.

## What's new

- **Detailed local history**: Explore session and weekly balances for the last hour, 24 hours, 7 days, or 30 days. Provider cards and summary cards show recorded balances, observed drops, and reading counts.
- **Inspect exact readings**: Select a chart time or table row to see both balances. Switch between the recorded span and the full period, and export filtered readings as CSV.
- **Private history controls**: History stays on your Mac for up to 30 days. Pause recording or clear all readings. History contains no account details or session content, and starts when recording is enabled.
- **Usage available again alerts**: After an observed limit reaches 0%, receive one alert when a refresh confirms at least 5% is available and no observed limit remains depleted. This can be turned off separately in notification settings.
- **Clear notification status**: See whether macOS allows alerts, open Limit Bar's notification settings directly, and see confirmation after sending a test. Focus can still silence or delay notifications.
- **Better connection recovery**: Reconnect failed providers with clear next steps. A failed background refresh keeps the last successful values visible and marks them as stale.

## Improvements

- A cleaner history header with aligned Export and menu controls.
- Scrollable settings and correctly labelled accessibility controls.
- Interrupted connections can be retried after relaunch, and cancelled requests cannot reconnect a provider after it is disconnected.

Observed drops use percentage points between nearby readings. They do not estimate token consumption or fill recording gaps.

Requires macOS 15.6 or later.
