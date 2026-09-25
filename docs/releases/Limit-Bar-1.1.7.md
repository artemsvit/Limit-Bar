# Limit Bar 1.1.7

Fixes Antigravity opening Terminal windows by itself.

## What's fixed

- **No more surprise Terminal windows**: A failed Antigravity check no longer opens Terminal automatically, which in 1.1.6 could repeat and open several windows. If Antigravity needs a login after you refresh, Limit Bar asks first with an "Open CLI Login" button.
- **More reliable Antigravity check**: Quota data is read before any login check, so a normal response is no longer mistaken for a signed-out account.
- **Quieter retries**: A provider whose last refresh failed is no longer retried on every burst of activity. The regular schedule and the refresh button still retry it.

Requires macOS 15.6 or later.
