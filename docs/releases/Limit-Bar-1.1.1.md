# Limit Bar 1.1.1

A correctness fix for Claude Code's reset times.

## What's new

- Fixed reset times shown for Claude Code when its primary usage check falls back to a plain status read. Claude Code's CLI changed how it reports reset times, and the old parser silently fell back to a guessed 5-hour and 7-day window instead of showing the real one.

Requires macOS 15.6 or later.
