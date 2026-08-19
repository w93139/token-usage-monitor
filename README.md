# Token Usage Monitor

A local, privacy-focused Codex plugin for tracking token activity, rate-limit windows, scheduled resets, and earned reset credits.

The repository also includes a native macOS 13+ menu-bar app in
`macos/TokenUsageMonitor`. It provides a glanceable remaining-quota percentage, reset
countdown, daily chart, local alerts, and optional launch at login while using
the same local-only privacy model.

Version 1.2 adds the product Logo throughout the macOS app, displays quotas as
remaining percentages, prefers the Codex runtime bundled with ChatGPT, and
keeps the last successful quota snapshot during transient network failures.
It also includes five-second per-task tracking with local conversation names
and provider-neutral API usage ingestion for OpenAI-compatible models.

## macOS menu-bar app

Build the finished app with:

```bash
cd macos/TokenUsageMonitor
./scripts/build_app.sh
open 'dist/Token Usage Monitor.app'
```

The menu bar shows the current remaining-quota percentage. Click it to view all quota
windows, reset countdowns, a 14-day activity chart, alert settings, manual
refresh, and the launch-at-login option. The local build is ad-hoc signed;
Developer ID signing and Apple notarization are required before distributing a
download that opens without Gatekeeper review on other Macs.

## What it records

- Account token summaries and daily buckets returned by Codex services
- Current rate-limit percentages, window lengths, and scheduled reset times
- Earned reset-credit metadata
- Thread token-usage events when the connected App Server emits them
- Per-task Codex totals with the user-facing conversation title
- API response usage counters grouped by provider, model, and optional task name

It does **not** request or store prompt bodies, response bodies, files, API keys, or account email addresses.

## External API usage

While the macOS app is running, a loopback-only endpoint accepts usage metadata:

```text
POST http://127.0.0.1:47821/v1/usage
Content-Type: application/json
```

Example payload:

```json
{
  "provider": "deepseek",
  "model": "deepseek-chat",
  "task_name": "Summarize reports",
  "request_id": "request-123",
  "usage": {
    "prompt_tokens": 120,
    "completion_tokens": 30,
    "total_tokens": 150
  }
}
```

The endpoint accepts both OpenAI `input_tokens`/`output_tokens` fields and
OpenAI-compatible `prompt_tokens`/`completion_tokens` fields. It never proxies
requests and must never receive an API key, prompt, or response body. OpenAI's
organization-wide Usage API requires an admin key; DeepSeek exposes per-response
usage and an account balance endpoint, so response-level ingestion is the
portable default.

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
- External API usage is recorded when the calling application posts the response `usage` object or invokes the `record_api_usage` MCP tool; the monitor does not intercept HTTPS traffic.
- The plugin does not calculate subscription allowance as a fictional fixed token budget.

## Local tests

```bash
python3 -m unittest discover -s scripts/tests -v
```
