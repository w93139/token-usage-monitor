# Changelog

All notable changes to Token监测 are documented here.

## [1.7.3] - 2026-10-23

### Added

- Once-entered monthly renewal estimates with remaining days, original-day anchoring across short months and Gregorian civil-date persistence; migrate the previous local date and support clearing.
- A system frosted-glass window backdrop, lightweight tinted cards, and distinct button hover/press feedback that respect Reduce Transparency and Reduce Motion.

### Changed

- Label subscription dates as estimates and explain when to update them. Renewal tracking runs locally without website login, embedded browser processes or billing-page polling.

## [1.7.2] - 2026-10-23

### Added

- Bottom-bar monthly subscription renewal date and remaining calendar days, with local manual settings, clear/reset, and explicit overdue status; never inferred from quota resets.

### Fixed

- Discover the relocated desktop Codex CLI and reconnect after expired authentication or repeated quota failures instead of keeping an obsolete process indefinitely.
- Preserve quota timestamps on partial failures, reject missing/invalid percentages, and display stale quota as historical rather than live remaining capacity.
- Distinguish local context polling time from the original usage-report time; reject inconsistent synthetic compaction estimates until measured usage arrives.
- Preserve complete usage/reset events exactly at the bounded log-tail boundary; add recovery, task-switch, compaction and quota-freshness regressions.

## [1.7.1] - 2026-09-16

### Fixed

- Replace duplicate context selectors with one searchable task list; exclude the viewed task and deduplicate records by task ID while retaining distinct same-name tasks with short identifiers.
- Distinguish automatic follow of the latest updated non-archived task from fixed historical selection, with a return action and fallback when a selected task leaves the available records.
- Read context independently of task/API queries, coalesce rapid switches and reject obsolete responses using request revisions.
- Add Swift regressions for deterministic deduplication, selection/history separation, follow/pin behavior and rapid A–B–A switching.

## [1.7.0] - 2026-09-09

### Added

- Dedicated local task/API refresh with busy, successful-read time, failure and stale-data feedback, independent of network quota collection.
- Selectable last-reported task context snapshots using runtime usage and capacity; explicit unavailable/reset/stale states.
- Gentle hover feedback and exact task/API tooltips, respecting Reduce Motion.
- Custom relay channel configuration, local budgets, menu-bar selection, per-channel ingestion status and copyable usage templates.
- Context, current protocol and streaming-ingestion regression tests plus Swift model checks in CI.

### Fixed

- Parse the current nested Codex tokenUsage protocol and persist only whitelisted usage metadata.
- Preserve unavailable counters instead of treating missing live events as zero.
- Reject absent final API usage, invalid counters and source metadata; deduplicate streaming final records by channel/request ID.
- Select local Codex state database versions numerically and disclose task cumulative scope.
- Use the same custom Codex paths for task and context reads; never fall back to raw first-message titles for unnamed tasks. Rebuild legacy derived task caches using explicit names only.

## [1.6.3] - 2026-09-08

### Fixed

- Preserve the last known extra-reset count when a rate-limit response temporarily omits reset-credit metadata, preventing repeated “new reset available” notifications.
- Claim reset-credit count increases atomically across Python collectors sharing the local database, avoiding duplicate grant alerts.
- Continue recording an explicit zero count so consuming all credits is reflected correctly.

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
