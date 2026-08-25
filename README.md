# Token监测 (Token Usage Monitor)

[![CI](https://github.com/w93139/token-usage-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/w93139/token-usage-monitor/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/w93139/token-usage-monitor)](https://github.com/w93139/token-usage-monitor/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-black.svg)](LICENSE)

本地优先、注重隐私的 Codex 插件与 macOS 菜单栏应用，用于监测任务 Token、API
用量、额度窗口、刷新时间和额外刷新次数。提示词、回复正文和 API Key 均不会被保存。

## 下载与安装

1. 从 [最新 Release](https://github.com/w93139/token-usage-monitor/releases/latest)
   下载 `Token-Monitor-macOS-arm64-v1.6.1.zip`。
2. 解压后将 `Token监测.app` 移入“应用程序”文件夹并启动。
3. 首次启动若被 Gatekeeper 拦截，请在“系统设置 → 隐私与安全性”中确认打开。

运行要求：Apple Silicon Mac、macOS 13 或更高版本，以及已登录的本地 Codex/ChatGPT
环境。当前公开构建采用 ad-hoc 签名；Developer ID 签名和 Apple 公证尚未完成。

## 核心能力

- 菜单栏实时余量圆环，可选择 Codex、OpenAI API 或 DeepSeek API
- 每个任务的 Token 总量、对话名称、模型和更新时间
- OpenAI/DeepSeek 兼容 API 的输入、输出、缓存和推理 Token 记录
- 可配置 API Token 总额度，并显示已用量、余量和剩余百分比
- 14 天最近用量图、悬停详情、额度刷新倒计时和本地通知
- 启动自动展开、顶部余量浮标、登录启动和 GitHub Release 自动检查
- 本地 SQLite 存储，监听端点仅绑定 `127.0.0.1`

The repository also includes a native macOS 13+ menu-bar app in
`macos/TokenUsageMonitor`. It provides a glanceable remaining-quota percentage, reset
countdown, daily chart, local alerts, and optional launch at login while using
the same local-only privacy model.

Version 1.6 adopts a standard resizable macOS window, a 1024×1024 app icon with
true transparent margins, and a dedicated always-front quota badge. The pin
control now keeps only the selected remaining-quota number visible near the top
of the screen; the main window retains normal window layering. macOS controls
the ordering of menu-bar status items, so the badge provides a stable public-API
alternative when the status item would otherwise be hidden. Version 1.5 added
the Chinese product name Token监测, update checks, and launch-time opening. The recent-usage chart
also adds readable date ticks, a 14-day total, and a hover guide. Version 1.4 added
mouse-hover inspection to the recent-usage chart, showing the exact date and
Token count while highlighting the selected bar. Version 1.3
added a live circular remaining-quota indicator to the menu bar and
quota cards. The white arc is the remaining allowance, the consumed portion is
left blank, and each card also shows the exact consumed percentage. The app
prefers the Codex runtime bundled with ChatGPT and keeps the last successful
quota snapshot during transient network failures.

## macOS menu-bar app

Build the finished app with:

```bash
cd macos/TokenUsageMonitor
./scripts/build_app.sh
open 'dist/Token监测.app'
```

The menu bar shows the current remaining-quota percentage. Click it to view all quota
windows, reset countdowns, a 14-day activity chart, alert settings, manual
refresh, and the launch-at-login option. Use the pin button in the panel header
to keep a compact quota badge above other windows while leaving the main window
at its normal level. Automatic update checks are enabled by
default and can be disabled in Settings; update links open the public GitHub
release page. The local build is ad-hoc signed;
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

The macOS settings screen accepts an optional Token budget for OpenAI and
DeepSeek. The API card then shows lifetime recorded usage, remaining Tokens, and
remaining percentage. The menu-bar ring can independently display Codex,
OpenAI, or DeepSeek remaining quota. Budgets stay in local macOS preferences;
the monitor never requests provider credentials.

完整接入示例、字段说明和安全边界见
[API Integration Guide](docs/API_INTEGRATION.md)。

## Runtime behavior

The MCP server starts a background collector while the plugin is active. The
macOS app prefers the Codex runtime bundled with ChatGPT, uses the shared App
Server only when its control socket exists, and otherwise opens a standalone
read-only connection. Data is stored in:

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

macOS 应用构建：

```bash
macos/TokenUsageMonitor/scripts/build_app.sh
```

## Contributing and security

- 贡献代码前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。
- 安全问题请按 [SECURITY.md](SECURITY.md) 私下报告，不要公开附带敏感数据的 Issue。
- 版本变化见 [CHANGELOG.md](CHANGELOG.md)。

## License

Released under the [MIT License](LICENSE).
