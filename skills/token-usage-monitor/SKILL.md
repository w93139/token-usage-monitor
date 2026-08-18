---
name: token-usage-monitor
description: Inspect local Codex task token activity, conversation-level history, rate-limit windows, reset times, and OpenAI-compatible API usage such as OpenAI or DeepSeek. Use when the user asks about token consumption, per-task totals, model usage, remaining Codex allowance, weekly limits, reset timing, extra refreshes, or usage alerts.
---

# Token Usage Monitor

Use the `token-usage-monitor` MCP tools as the source of truth for local usage data.

## Workflow

1. Call `get_token_usage_summary` for a compact overview.
2. Call `get_rate_limits` when the user asks about remaining allowance, reset timing, or extra resets.
3. Call `get_usage_history` only when the user asks for a trend or a specific date range.
4. Call `refresh_usage` when data is stale or the user explicitly asks for the latest state.
5. Call `configure_usage_alerts` only when the user asks to change notification settings.
6. Call `get_task_usage_history` for per-task Codex totals and local conversation names.
7. Call `get_api_usage_history` for OpenAI, DeepSeek, or other recorded API calls.
8. Call `record_api_usage` only with counters returned by an API response; never pass prompts, responses, or credentials.

## Interpretation

- Treat `usedPercent` and `resetsAt` as authoritative for a reported quota window.
- Do not convert subscription allowance percentages into invented token totals.
- Distinguish scheduled resets from earned reset credits.
- An earned reset can be detected when granted, but its future grant cannot be predicted unless the service supplies it.
- If account token summaries are unavailable, explain the authentication limitation and still report any available rate-limit data.
- A model-specific 0% quota window is available capacity, not proof that the user selected or used that model.
- DeepSeek-style `prompt_tokens`/`completion_tokens` and OpenAI-style `input_tokens`/`output_tokens` are both supported.

## Safety and privacy

- The plugin stores counts, identifiers, model names, and user-facing task titles locally, never prompt or response bodies.
- Never store or transmit an API key through `record_api_usage`.
- Never consume an earned reset automatically.
- Never call an email, messaging, billing, or purchasing action from usage data.
- Do not claim that a notification was delivered unless the tool reports success.
