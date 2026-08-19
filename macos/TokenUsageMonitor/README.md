# Token Usage Monitor for macOS

Native macOS 13+ menu-bar companion for the Token Usage Monitor Codex plugin.

## Features

- Live Codex remaining-quota percentage and reset countdown
- White circular remaining-quota indicator in the menu bar and quota cards
- Exact consumed percentage beneath each remaining-quota bar
- Cached quota fallback with a friendly automatic-retry status during network interruptions
- Product Logo in the panel and macOS application icon
- Daily token chart and account summary
- Mouse-hover details with exact date and Token count on the recent-usage chart
- Local notifications at configurable thresholds
- Detection of scheduled resets and newly granted reset credits
- Manual refresh, local-only storage, and optional launch at login
- Five-second per-task token totals with local conversation titles
- Local usage ingestion for OpenAI, DeepSeek, and compatible API responses
- No prompt text, response text, email address, or API key collection

## Build

```sh
./scripts/build_app.sh
```

The finished app is written to `dist/Token Usage Monitor.app`. Move it to the
Applications folder and launch it; the remaining-quota percentage will appear in the
menu bar. The app requires a local Codex CLI installation, an authenticated
Codex session, and macOS 13 or newer.

The app is ad-hoc signed for local use. Public distribution requires an Apple
Developer ID signature and notarization.
