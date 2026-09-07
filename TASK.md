# Task: Release Token监测 1.6.3

## Goal

Ship the existing reset-credit notification fix from `8ad147f` in macOS 1.6.3
(build 12), and refresh the installed local Codex plugin.

## Non-goals

- Full in-app update installation, new dependencies, Developer ID or notarization.
- Credential changes, destructive cleanup, or changes to stored user data.

## Done when

- AppInfo, MCP serverInfo, README and CHANGELOG describe 1.6.3 consistently.
- Reset-credit regression tests, complete Python suite, macOS build and signature checks pass.
- Plugin cachebuster, skill/plugin validation and local reinstall complete.
- Installed app reports 1.6.3 build 12 and its loopback health endpoint responds.
- Menu-bar ring, pinned badge, window resizing and application icon are checked on this Mac;
  any unavailable visual check is explicitly documented, not reported as passed.
- Independent read-only review has no unresolved Blocker or Important findings.
- ZIP and SHA256 are verified, main is pushed, GitHub Release is published,
  and both Python and macOS CI jobs pass for the released commit.

## Scope

- Release metadata, plugin manifest and release documentation.
- Existing fix in `scripts/token_monitor.py` and `MonitorStore.swift`, including its tests.
- Local application installation, plugin installation and GitHub release assets.

## Verify

- `git diff --check`
- `python3 -m unittest discover -s scripts/tests -v`
- `./macos/TokenUsageMonitor/scripts/build_app.sh`
- `codesign --verify --deep --strict macos/TokenUsageMonitor/dist/Token监测.app`
- `python3 ~/.codex/skills/.system/skill-creator/scripts/quick_validate.py skills/token-usage-monitor`
- `python3 ~/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py .`
- `curl -fsS http://127.0.0.1:47821/health`
- Installed bundle version, packaged script equality, ZIP signature and checksum checks.
- Native UI inspection, and GitHub CI status for the exact release commit.

## Risks and assumptions

- The handoff authorizes installation, packaging, commits, push and GitHub Release.
- Builds remain ad-hoc signed; signing accounts, certificates and notarization need user direction.
- Keep the previous installed app for rollback. Move obsolete installers to Trash if cleanup is needed.
- App/plugin collector restart may briefly interrupt monitoring; preserve SQLite and preferences.
