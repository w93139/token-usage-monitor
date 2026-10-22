# Token监测 (Token Usage Monitor)

[![CI](https://github.com/w93139/token-usage-monitor/actions/workflows/ci.yml/badge.svg)](https://github.com/w93139/token-usage-monitor/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/w93139/token-usage-monitor)](https://github.com/w93139/token-usage-monitor/releases/latest)
[![License: MIT](https://img.shields.io/badge/License-MIT-black.svg)](LICENSE)

本地优先的 Codex 插件与 macOS 菜单栏应用，用于查看任务 Token、API 用量、额度窗口和重置时间。提示词、回复正文、API Key 和账号邮箱不会被持久化。

## 安装与运行

从 [最新 Release](https://github.com/w93139/token-usage-monitor/releases/latest) 下载 macOS arm64 ZIP，解压后将 `Token监测.app` 移入“应用程序”并启动。要求 Apple Silicon、macOS 13+，以及已登录的本地 Codex／ChatGPT 环境。

公开构建采用 ad-hoc 签名，尚未完成 Developer ID 签名与 Apple 公证；首次打开如被 Gatekeeper 拦截，在“系统设置 → 隐私与安全性”中确认打开。

从源码构建需要 Swift 5.8+：

```sh
macos/TokenUsageMonitor/scripts/build_app.sh
open 'macos/TokenUsageMonitor/dist/Token监测.app'
```

插件能力定义见 [SKILL.md](skills/token-usage-monitor/SKILL.md)。

## 主要功能

- 菜单栏余量圆环，可选择 Codex、OpenAI API、DeepSeek API 或自定义渠道。
- 任务列表、累计 Token、模型与更新时间；可固定查看历史任务或跟随最近活动。
- 最近可用的任务上下文快照，独立显示读取时间、过期与不可用状态。
- API 输入、输出、缓存和推理 Token 记录，以及本地设置的 Token 预算。
- 14 天用量图、额度重置倒计时、本地提醒、可置顶余量浮标和登录启动。
- GitHub Release 更新检查，可在设置中关闭。
- 底部显示手动记录的下次月订阅续费日期与剩余天数，可在设置中保存或清除；不读取账单、不自动续期。

1.7.2 修复桌面 Codex 升级后路径变化与认证过期导致的停更，支持失败后重连。历史额度保留原更新时间，不会伪装成实时余量。

## API 接入

运行 macOS 应用后，可向仅绑定本机的 `POST http://127.0.0.1:47821/v1/usage` 上报响应中的 usage 元数据，也可调用插件的 `record_api_usage`。支持 OpenAI 与兼容接口的计数字段；最终 usage 缺失时不记录，重复请求不累加。

监测器不代理模型请求，不截取 HTTPS 流量，也不需要服务商密钥。调用方只发送用量计数与必要的标识，不能发送提示词、回复正文或凭据。载荷、流式示例与渠道设置见 [API 接入指南](docs/API_INTEGRATION.md)。

## 隐私与计数边界

- 任务累计量来自本地 Codex 数据库，可能重复计入历史输入；父任务是否含全部子代理用量尚未核实。
- 上下文是日志最近一次可用的 usage 元数据，不能保证反映随后发生的全部变化。应用只在内存中有界读取日志尾部（最多 4 MiB），不保存对话正文。
- 本地检查时间与用量上报时间分别显示；压缩后的不一致合成估计暂不作为准确用量，等待后续有效统计。
- 任务名只取明确标题；无标题显示“未命名任务＋短编号”。不会用首条提示词充当标题。
- 实时任务计数依赖所连接 App Server 暴露相应事件；缺失数据表示不可用，不能当作零。
- 账号统计依赖 Codex 账号认证；仅 API Key 或 Bedrock 认证不能取得相同账号摘要。
- 额外重置只能在服务实际提供后检测；工具不预测、购买或消耗重置次数，也不把订阅额度换算成虚构的固定 Token 总额。
- API 预算由用户本地填写，并非服务商实际余额。

## 数据与通知

插件启用时运行后台采集器；默认每 60 秒轮询。可用 `TOKEN_USAGE_MONITOR_POLL_SECONDS` 设置不低于 15 秒的间隔。

本地 SQLite 位置：

- macOS：`~/Library/Application Support/Token Usage Monitor/usage.sqlite3`
- Linux：`${XDG_DATA_HOME:-~/.local/share}/token-usage-monitor/usage.sqlite3`

默认在用量达到 80%、95%、100% 时提醒，重置前 30 分钟提醒；检测到新额外重置时通知一次。用 `configure_usage_alerts` 修改设置，或设 `TOKEN_USAGE_MONITOR_DISABLE_NOTIFICATIONS=1` 禁用进程通知。

## 开发与许可

依赖外部 Python 包之前的基础测试入口（Python 3.9+）：

```sh
python3 -m unittest discover -s scripts/tests -v
```

贡献与所需检查见 [CONTRIBUTING.md](CONTRIBUTING.md)，私密漏洞报告见 [SECURITY.md](SECURITY.md)，版本记录见 [CHANGELOG.md](CHANGELOG.md)。采用 [MIT License](LICENSE)。
