# API Integration Guide

Token监测 records usage metadata returned by OpenAI, DeepSeek, and OpenAI-compatible APIs. It does
not proxy requests and must never receive an API key, prompt, or model response body.

## Endpoint

```text
POST http://127.0.0.1:47821/v1/usage
Content-Type: application/json
```

The macOS application must be running. Check availability with:

```bash
curl http://127.0.0.1:47821/health
```

## OpenAI-style response

After your application receives an API response, forward only its usage counters:

```json
{
  "provider": "openai",
  "model": "gpt-5",
  "task_name": "Generate weekly report",
  "request_id": "response-id-or-your-idempotency-key",
  "usage": {
    "input_tokens": 1200,
    "output_tokens": 240,
    "total_tokens": 1440
  }
}
```

## DeepSeek/OpenAI-compatible response

```json
{
  "provider": "deepseek",
  "model": "deepseek-chat",
  "task_name": "Summarize documents",
  "request_id": "request-123",
  "usage": {
    "prompt_tokens": 900,
    "prompt_cache_hit_tokens": 300,
    "completion_tokens": 180,
    "total_tokens": 1080
  }
}
```

`request_id` enables idempotent ingestion: sending the same provider and request ID again does not
double-count the usage.

## Supported counters

| Meaning | OpenAI field | Compatible field |
|---|---|---|
| Input | `input_tokens` | `prompt_tokens` |
| Cached input | `cached_input_tokens` | `prompt_cache_hit_tokens` |
| Output | `output_tokens` | `completion_tokens` |
| Reasoning | `reasoning_tokens` | `reasoning_tokens` |
| Total | `total_tokens` | `total_tokens` |

## Quota display

Provider responses usually do not expose a common account-wide Token allowance. Enter the OpenAI
or DeepSeek total Token budget in Token监测 settings. The application calculates:

```text
remaining = configured budget - locally recorded usage
```

Budgets stay in local macOS preferences. Provider credentials are never requested.

## Privacy checklist

- Send only provider, model, optional task name, request ID, and numeric usage counters.
- Never send authorization headers, API keys, prompts, model responses, or uploaded files.
- Keep the endpoint bound to loopback; do not expose port 47821 through a proxy or tunnel.


## Relay / custom channels (1.7.0)

1. In Settings → 中转站与自定义渠道, choose a stable channel ID such as `my-relay`, a display name and an optional positive integer local Token budget.
2. Have your API client post its real response `usage` to the loopback endpoint, using that channel ID as `provider`. Changing a provider base URL alone does not connect the monitor. There is no credential entry or automatic traffic interception.
3. Use `source: "response"` for a complete non-streaming response, `"stream_final"` for the final streaming usage, or `"manual"` when manually transcribing actual response counters. These are the supported source values; estimates are not accepted as reported usage.
4. For streaming, request final usage when the provider supports it (OpenAI Chat Completions: `stream_options.include_usage: true`). Post the final counters once with a stable `request_id`. An interrupted stream may not provide final usage; missing usage must remain unknown rather than becoming zero.

```json
{
  "provider": "my-relay",
  "model": "model-name-from-response",
  "request_id": "unique-response-id",
  "source": "stream_final",
  "usage": {"prompt_tokens": 120, "completion_tokens": 30, "total_tokens": 150}
}
```

The numbers above illustrate the schema only. Replace them with the actual response usage before sending. `stream_final` requires a request ID. Retrying the same ID within a provider returns `recorded: false` without adding usage again. Use a distinct provider/channel ID for distinct relay accounts when request IDs may overlap.

Counters must be non-negative integers. Provide either an explicit total or both input and output counters. Cached-input and reasoning counters are subsets and are not added again. Optional breakdown fields that are absent are stored as zero by the legacy schema; the app shows only reported total usage, not a purported complete breakdown. Invalid or missing final usage is rejected without writing a zero-use record. `captured_at`, if supplied, must be a positive Unix timestamp in seconds, no more than five minutes in the future.

The interface distinguishes listener availability, records received, and recent record time. Recent record time uses the event timestamp (`captured_at`), so importing old records does not imply a new API call. Channel budgets are local tracking targets, not the relay's balance, bill or official quota. Removing a channel configuration does not erase recorded usage; recreate the same ID to restore its display name and budget.
