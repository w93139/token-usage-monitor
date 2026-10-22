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

## 1.7.1 context switching correction (2026-09-16)

User requests clearer context switching and removal of duplicate history presentation, with local/GitHub synchronization. Replace the duplicated picker/row selectors with one searchable task history; exclude the selected task from that list, retain same-name distinct IDs, and normalize duplicate IDs deterministically. Default follows the most recently updated non-archived task (not foreground detection); manual selection stays fixed until return or removal from the available list. Give context reads their own queue and revision guard so rapid switches cannot publish obsolete snapshots. Preserve user data and API behavior. Verify selection/normalization/race acceptance with Swift regression checks, all Python tests, build/signature, independent review, available native UI, plugin validation, exact-commit CI and release archive checks. Ship patch 1.7.1 build 14 under existing authorization.

## 1.7.2 monitoring recovery (2026-10-23)

Fix the observed stale quota connection after a desktop upgrade and validate context freshness across task switches and compaction. Discover the new bundled CLI path; reconnect expired/failed collectors; preserve quota timestamps on partial failure and never render unknown usage as zero. Distinguish local context polling time from original usage time. Reject synthetic inconsistent compaction counts as unknown pending the next measured call and fix exact tail-boundary reads. Preserve data, credentials, login state, budgets and reset credits. Verify Python/Swift regression suites, real read-only quota calls, local UI/current task snapshots, build/signature/plugin checks, independent review and exact-commit CI before local/GitHub 1.7.2 build 15 release. No billable inference or account-changing calls.

User additionally chose bottom-bar next monthly renewal date plus remaining days. Provide explicit manual local settings (unset initially), calendar-day counting, saved confirmation and clearing. Past dates stay overdue until edited; do not infer billing dates from quota resets or claim automatic billing access. Verify persistence/UI and today/tomorrow/past/DST boundary calculations.
