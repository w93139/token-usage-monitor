# Token Usage Monitor

A local, privacy-focused Codex plugin for tracking token activity, rate-limit windows, scheduled resets, and earned reset credits.

The repository also includes a native macOS 13+ menu-bar app in
`macos/TokenUsageMonitor`. It provides a glanceable quota percentage, reset
countdown, daily chart, local alerts, and optional launch at login while using
the same local-only privacy model.

## macOS menu-bar app

Build the finished app with:

```bash
cd macos/TokenUsageMonitor
./scripts/build_app.sh
open 'dist/Token Usage Monitor.app'
```

The menu bar shows the current quota percentage. Click it to view all quota
windows, reset countdowns, a 14-day activity chart, alert settings, manual
refresh, and the launch-at-login option. The local build is ad-hoc signed;
Developer ID signing and Apple notarization are required before distributing a
download that opens without Gatekeeper review on other Macs.

## What it records

- Account token summaries and daily buckets returned by Codex services
- Current rate-limit percentages, window lengths, and scheduled reset times
- Earned reset-credit metadata
- Thread token-usage events when the connected App Server emits them

It does **not** request or store prompt text, response text, files, API keys, or account email addresses.

## Runtime behavior

The MCP server starts a background collector while the plugin is active. It first tries the shared Codex App Server daemon through `codex app-server proxy`, then falls back to a standalone read-only App Server connection. Data is stored in:

- macOS: `~/Library/Application Support/Token Usage Monitor/usage.sqlite3`
- Linux: `${XDG_DATA_HOME:-~/.local/share}/token-usage-monitor/usage.sqlite3`

The default polling interval is 60 seconds. Set `TOKEN_USAGE_MONITOR_POLL_SECONDS` to a value of at least 15 seconds to override it.

## Notifications

Local notifications are enabled by default at 80%, 95%, and 100% usage. A scheduled reset warning is sent 30 minutes before `resetsAt`. When a new earned reset is detected, the plugin announces it but never consumes it.

Use the `configure_usage_alerts` tool to change these settings. Set `TOKEN_USAGE_MONITOR_DISABLE_NOTIFICATIONS=1` to suppress notifications for the process.

## Limitations

- ChatGPT token activity summaries require Codex-backed authentication. API-key-only and Bedrock authentication do not expose that account summary endpoint.
- An unannounced extra reset can only be detected when the service grants it; the plugin cannot predict a future grant that the service has not exposed.
- Exact live thread counters depend on `thread/tokenUsage/updated` events being visible to the connected App Server. Account and quota polling still works when those events are unavailable.
- The plugin does not calculate subscription allowance as a fictional fixed token budget.

## Local tests

```bash
python3 -m unittest discover -s scripts/tests -v
```
