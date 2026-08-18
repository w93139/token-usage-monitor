---
name: token-usage-monitor
description: Inspect local Codex token activity, daily usage history, rate-limit windows, reset times, and earned reset credits. Use when the user asks about token consumption, remaining Codex allowance, five-hour or weekly limits, reset timing, extra refreshes, or usage alerts.
---

# Token Usage Monitor

Use the `token-usage-monitor` MCP tools as the source of truth for local usage data.

## Workflow

1. Call `get_token_usage_summary` for a compact overview.
2. Call `get_rate_limits` when the user asks about remaining allowance, reset timing, or extra resets.
3. Call `get_usage_history` only when the user asks for a trend or a specific date range.
4. Call `refresh_usage` when data is stale or the user explicitly asks for the latest state.
5. Call `configure_usage_alerts` only when the user asks to change notification settings.

## Interpretation

- Treat `usedPercent` and `resetsAt` as authoritative for a reported quota window.
- Do not convert subscription allowance percentages into invented token totals.
- Distinguish scheduled resets from earned reset credits.
- An earned reset can be detected when granted, but its future grant cannot be predicted unless the service supplies it.
- If account token summaries are unavailable, explain the authentication limitation and still report any available rate-limit data.

## Safety and privacy

- The plugin stores counts and identifiers, never prompt or response text.
- Never consume an earned reset automatically.
- Never call an email, messaging, billing, or purchasing action from usage data.
- Do not claim that a notification was delivered unless the tool reports success.
