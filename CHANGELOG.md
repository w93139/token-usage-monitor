# Changelog

All notable changes to Token监测 are documented here.

## [1.6.2] - 2026-08-25

### Fixed

- Renamed the bundled icon resource so macOS refreshes the transparent app icon after an in-place update.
- Removed the legacy icon resource from rebuilt application bundles.

## [1.6.1] - 2026-08-25

### Fixed

- Restored the live remaining-quota ring beside the readable percentage in the macOS menu bar.

## [1.6.0] - 2026-08-25

### Changed

- Rebuilt the app presentation around a standard 420×640 resizable macOS window with a 390×540 minimum size.
- Changed the pin action to show a compact, always-front quota badge instead of raising the entire app window.
- Simplified the menu-bar label for better legibility under limited menu-bar space.
- Normalized the graphite app icon to a 1024×1024 RGBA asset with transparent safe margins.

### Fixed

- The main app window no longer remains above unrelated applications after pinning quota visibility.
- Removed the opaque square canvas that made the application icon appear oversized in macOS launch surfaces.

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
