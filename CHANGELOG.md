# Changelog

All notable changes to Token监测 are documented here.

## [1.5.2] - 2026-08-25

### Added

- Automatic panel opening and an always-on-top pin switch.
- Black graphite application icon and the Token监测 display name.
- Date ticks, 14-day totals, accessibility labels, and hover guidance in the recent-usage chart.
- Automatic update checks through the GitHub Releases Atom feed.
- OpenAI and DeepSeek Token budgets with used, remaining, and percentage displays.
- Selectable Codex, OpenAI, or DeepSeek quota source for the menu-bar ring.
- HTTP integration tests for health checks, ingestion, history, deduplication, and CORS rejection.

### Fixed

- API monitor availability now reflects the actual `/health` response.
- Existing healthy loopback listeners are reused instead of spawning a conflicting process.
- API monitor termination updates the application status correctly.

## [1.4.0] - 2026-08-19

- Added exact Token values when hovering over recent-usage bars.

## [1.3.0] - 2026-08-19

- Added remaining-quota rings to the menu bar and quota cards.
