# Limit Bar

Limit Bar is a macOS menu bar utility that keeps AI usage limits visible while you work. It reads local Codex and Claude Code sessions, shows current and weekly remaining balance, highlights reset timing, and can notify you before you start a task that will run past your available headroom.

## Highlights

- Menu bar status for current and weekly usage windows
- Local-first provider integration with installed CLI sessions
- Configurable low-balance notifications and test notifications
- Start at login support
- Automatic in-app updates through Sparkle
- Developer ID signed and notarized release distribution

## Supported Providers

- Codex
- Claude Code

Gemini scaffolding exists in the codebase, but the shipped app currently focuses on the providers above.

## Download

Latest release: [Limit Bar 1.0.6 DMG](https://github.com/artemsvit/Limit-Bar/releases/download/v1.0.6/Limit-Bar-1.0.6.dmg)

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

## Development

Project layout:

- `Limit Bar/` - macOS app sources
- `Config/` - app configuration plist values
- `Vendor/Sparkle/` - vendored Sparkle framework and tools
- `scripts/` - release, signing, DMG, and publishing scripts
- `Landing/` - static landing page

Useful release scripts:

```sh
scripts/build-signed-dmg.sh 1.0.6 7
scripts/publish-release.sh 1.0.6 7
```

`build-signed-dmg.sh` produces the signed distribution artifacts. `publish-release.sh` publishes the GitHub release assets and Sparkle appcast.

## License

This repository includes Sparkle, which is distributed under its own license in [Vendor/Sparkle/LICENSE](Vendor/Sparkle/LICENSE).
