# Task: Token监测 1.7.0 — reliable usage and clear feedback

## Goal

Distinguish task lifetime usage from current context; make freshness and manual refresh explicit; add restrained hover feedback and configurable relay channels with honest ingestion status. Install and publish 1.7.0 (build 13).

## Scope and acceptance

- Parse current nested and legacy Codex usage metadata without losing counters or storing message bodies.
- Show task cumulative counters with source/scope disclosure and precise hover values. Do not invent subagent aggregation.
- Task/API local reads run separately from network quota refresh; dedicated task refresh has busy, success timestamp and failure/cache states.
- Show context for a user-selectable task using the most recent available runtime context counters and window; missing data is unavailable, stale data is labeled. Never use cumulative tokens as context.
- Hover rows/buttons gently, preserve layout and respect Reduce Motion.
- Configure a custom API channel name and optional local Token budget, select it for menu quota; distinguish listener health, received records and unknown/missing usage. Provide copyable metadata-only ingestion example and diagnostic status.
- Preserve existing OpenAI/DeepSeek preferences and user records; no credentials, billable requests, account-balance claims or traffic interception.
- New regression tests for protocol shapes, context metadata and API ingestion. Full Python suite, relevant Swift verification, release build, signatures, plugin validators, independent read-only review, local smoke and UI checks.
- Sync versions, install app and plugin, verify ZIP/checksum and downloaded release assets; push main and publish only after both CI jobs succeed.

## Non-goals

Full automatic app installation updates, signing accounts/notarization, relay credential management, invoice reconciliation, destructive cleanup.

## Verification

- `git diff --check`
- `python3 -m unittest discover -s scripts/tests -v`
- `macos/TokenUsageMonitor/scripts/build_app.sh`
- `codesign --verify --deep --strict macos/TokenUsageMonitor/dist/Token监测.app`
- Skill/plugin validation, isolated installed MCP smoke, loopback health and archive verification.
- Native UI: task refresh, context availability, hover, settings and custom channel; explicitly record any untestable visual behavior.
- Independent review, exact released-commit GitHub Python and macOS CI.

## Authorization and risks

User approved this previously discussed implementation and local/GitHub synchronization; handoff authorizes commits, push and Release. Preserve data/preferences and retain prior app for rollback. Runtime metadata availability varies, so unknown/stale context must remain visible rather than presented as complete real-time context. Do not contact a relay or handle keys to test integration. Only usage metadata is persisted.
