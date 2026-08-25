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
