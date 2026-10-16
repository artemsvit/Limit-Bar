# Limit Bar

Limit Bar is a macOS menu bar utility that keeps AI usage limits visible while you work. It reads local Codex and Claude Code sessions, shows current and weekly remaining balance, highlights reset timing, and can notify you before you start a task that will run past your available headroom.

## Highlights

- Menu bar status for current and weekly usage windows
- Local-first provider integration with installed CLI sessions
- Configurable low-balance notifications and test notifications
- Recovery alerts after depleted usage becomes available again
- Local usage history with 24-hour, 7-day, and 30-day charts
- macOS notification permission status and direct access to System Settings
- Reconnect actions with guidance after provider refresh failures
- Start at login support
- Automatic in-app updates through Sparkle
- Developer ID signed and notarized release distribution

## Supported Providers

- Codex
- Claude Code

Gemini scaffolding exists in the codebase, but the shipped app currently focuses on the providers above.

## Download

Latest release: [Limit Bar 1.2.0 DMG](https://github.com/artemsvit/Limit-Bar/releases/download/v1.2.0/Limit-Bar-1.2.0.dmg)

Release notes: [Limit Bar release history](https://limitbar.artsvit.com/releases/)

All release assets: [GitHub Releases](https://github.com/artemsvit/Limit-Bar/releases)

Requirements:

- macOS 15.6 or later

## How It Works

Limit Bar uses the local tools you already have installed. It does not rely on browser cookies or hosted scraping. Provider status is collected from local CLI-accessible usage data, then rendered in a compact menu bar experience with a deeper settings and status view.

## Updates

The app uses Sparkle for signed in-app updates.

- Appcast feed: [appcast.xml](https://github.com/artemsvit/Limit-Bar/releases/download/updates/appcast.xml)
- Update configuration notes: [docs/sparkle-updates.md](docs/sparkle-updates.md)

## Usage history and recovery alerts

Open **Usage history** from the menu bar chart button or **View history** in Settings.
Provider cards show the latest recorded balances. Filter by 1 hour, 24 hours, 7 days, or
30 days, and switch between session and weekly limits. Summary cards show the latest
and lowest remaining balances, observed decreases, and reading counts.

The chart focuses on the recorded span by default; **Full period** shows the entire
selected period. Select a chart time or a row in **Recorded readings** to inspect exact
values. **Export CSV** saves the filtered readings. Observed decreases
exclude intervals longer than 30 minutes and do not estimate token consumption.

Successful refreshes record up to one observation per provider per five-minute interval.
History starts when this version runs; it does not backfill earlier usage. Records expire
after 30 days and stay in `~/Library/Application Support/Limit Bar/usage-history-v1.json`.
Recording can be paused and all history can be cleared in the history window.

Recovery alerts are enabled by default when usage notifications are on. After an observed
limit reaches 0%, a later successful refresh must confirm at least 5% remaining in that
window. An observed depleted weekly window also has to recover. Each depletion sends
one recovery alert. Missing data and elapsed reset timers do not trigger alerts.

Notification permission appears in Settings even when the app's notification toggle is
off. macOS Focus and notification settings still control alert presentation.

## Development

Project layout:

- `Limit Bar/` - macOS app sources
- `Config/` - app configuration plist values
- `Vendor/Sparkle/` - vendored Sparkle framework and tools
- `scripts/` - release, signing, DMG, and publishing scripts
- `Landing/` - static landing page

Useful release scripts:

```sh
scripts/build-signed-dmg.sh 1.2.0 17
scripts/publish-release.sh 1.2.0 17
```

`build-signed-dmg.sh` produces the signed distribution artifacts. `publish-release.sh` publishes the GitHub release assets and Sparkle appcast.

Build and run locally with `./script/build_and_run.sh --verify`.
Run the recovery and history checks with:

```sh
xcrun swiftc 'Limit Bar/UsageInsightsModels.swift' 'Limit Bar/HistoryAnalysis.swift' Tests/UsageInsightsTests.swift -o build/usage-insights-tests
build/usage-insights-tests
```

## License

This repository includes Sparkle, which is distributed under its own license in [Vendor/Sparkle/LICENSE](Vendor/Sparkle/LICENSE).
