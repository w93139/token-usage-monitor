import Foundation

@main
struct ModelChecks {
    static func main() throws {
        func require(_ value: Bool, _ message: String) { precondition(value, message) }
        for invalid in ["", "0", "-1", "1.5", "1,000", "1e6", "100abc", String(repeating: "9", count: 30)] {
            require(APIChannel.parseBudget(invalid) == nil, "Invalid budget must stay unknown: \(invalid)")
        }
        require(APIChannel.parseBudget(" 1000000 ") == 1_000_000, "Whitespace budget")
        require(APIChannel.validID("my-relay_2"), "Channel ID")
        require(!APIChannel.validID("https://relay.example"), "URL is not a channel ID")
        require(!APIChannel.validID("secret\nkey"), "Reject multiline IDs")
        let quota = APIQuotaSummary(provider: "relay", usedTokens: 250, budgetTokens: 1000, customName: "中转站")
        require(quota.remainingPercent == 75 && quota.remainingTokens == 750, "Custom budget math")
        require(quota.displayName == "中转站", "Custom display name")
        let unknown = APIQuotaSummary(provider: "relay", usedTokens: 250, budgetTokens: nil)
        require(unknown.remainingPercent == nil, "Missing budget is not zero percent")
        let exceeded = APIQuotaSummary(provider: "relay", usedTokens: 1200, budgetTokens: 1000)
        require(exceeded.remainingTokens == 0 && exceeded.remainingPercent == 0, "Budget overrun clamps remaining")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let data = Data(#"{"threadId":"t1","tokens":120,"window":1000,"capturedAt":1700000000,"source":"codex_rollout_last_usage","error":null}"#.utf8)
        let snapshot = try decoder.decode(ContextSnapshot.self, from: data)
        require(snapshot.percent == 12, "Context percentage uses snapshot tokens")
        require(snapshot.capturedAt?.timeIntervalSince1970 == 1700000000, "Preserve event time")
        let missing = try decoder.decode(ContextSnapshot.self, from: Data(#"{"threadId":"t1","tokens":null,"window":null,"capturedAt":null,"source":"codex_rollout_last_usage","error":"context_reset"}"#.utf8))
        require(missing.percent == nil && missing.unavailableReason.contains("压缩"), "Reset stays unknown")
        let invalid = ContextSnapshot(threadId: "t1", tokens: 120, window: 0, source: "test")
        require(invalid.percent == nil, "Zero window never divides")
        // Exercise the actual native query against a fixture containing private raw titles.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let database = folder.appendingPathComponent("fixture.sqlite")
        func sqlite(_ sql: String) throws -> Data {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = ["-json", database.path, sql]
            process.standardOutput = pipe
            try process.run()
            let result = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            require(process.terminationStatus == 0, "Fixture query")
            return result
        }
        _ = try sqlite("""
        CREATE TABLE threads(id TEXT, name TEXT, title TEXT, tokens_used INTEGER, created_at INTEGER, updated_at INTEGER, model TEXT, archived INTEGER, thread_source TEXT, agent_role TEXT);
        CREATE TABLE thread_spawn_edges(child_thread_id TEXT);
        INSERT INTO threads VALUES('abcdefgh-private',NULL,'PRIVATE PROMPT BODY',120,1,2,'model',0,'user',NULL);
        INSERT INTO threads VALUES('named-task','实际任务名','ANOTHER PRIVATE BODY',200,1,3,'model',0,'user',NULL);
        """)
        let records = try sqlite(TaskUsageRecord.historyQuery)
        let rendered = String(decoding: records, as: UTF8.self)
        require(!rendered.contains("PRIVATE"), "Never read raw title as task name")
        require(rendered.contains("实际任务名") && rendered.contains("未命名任务 abcdefgh"), "Preserve explicit names and stable fallback")
        require((try? decoder.decode(TaskRecordsCache.self, from: Data("[]".utf8))) == nil, "Do not load old unsourced task cache")
        func task(_ id: String, updated: TimeInterval, archived: Bool = false) -> TaskUsageRecord {
            TaskUsageRecord(id: id, title: "Same title", tokens: 100, createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: updated), model: nil, archived: archived)
        }
        let a = task("a", updated: 10)
        let b = task("b", updated: 20)
        let archive = task("archived", updated: 30, archived: true)
        let normalized = ContextTaskSelection.normalized([a, b, task("a", updated: 5), archive])
        require(normalized.count == 3 && normalized.last?.updatedAt == a.updatedAt, "Deduplicate IDs keeping latest, preserve distinct same-title tasks")
        require(ContextTaskSelection.normalized([task("z", updated: 10), a]).map(\.id) == ["a", "z"], "Stable tie ordering")
        var selection = ContextTaskSelection()
        require(selection.selected(in: normalized)?.id == "b", "Follow latest non-archived task")
        require(selection.history(in: normalized).map(\.id) == ["archived", "a"], "Selected task never repeats in history")
        let c = task("c", updated: 40)
        let newer = ContextTaskSelection.normalized(normalized + [c])
        require(selection.selected(in: newer)?.id == "c", "Automatic mode follows new activity")
        selection.select("a")
        require(selection.selected(in: newer)?.id == "a", "Manual selection stays fixed")
        let oldRequest = selection.beginRead()
        selection.select("b")
        selection.select("a")
        require(!selection.accepts(oldRequest, threadID: "a", records: newer), "A-B-A must reject obsolete A read")
        let latestRequest = selection.beginRead()
        require(selection.accepts(latestRequest, threadID: "a", records: newer), "Accept latest matching request")
        require(!selection.accepts(latestRequest, threadID: "b", records: newer), "Never publish another task's snapshot")
        selection.reconcile(with: [b, c])
        require(selection.pinnedID == nil, "Missing selection returns to follow mode")
        selection.select(nil)
        require(selection.selected(in: [archive]) == nil && selection.selected(in: []) == nil, "No active task stays empty, never auto-select archive")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let validLimits: [String: Any] = ["rateLimits": ["limitId": "codex", "primary": ["usedPercent": 25, "windowDurationMins": 10080, "resetsAt": 1_800_000_600]]]
        let fresh = UsageSnapshot.refreshed(usage: [:], limits: validLimits, fallback: .empty, now: now)
        require(fresh.rateWindows.first?.remainingPercent == 75 && fresh.capturedAt == now, "Measured quota refresh")
        let partial = UsageSnapshot.refreshed(usage: ["summary": ["lifetimeTokens": 123]], limits: [:], fallback: fresh, now: now.addingTimeInterval(200))
        require(partial.account?.lifetimeTokens == 123 && partial.rateWindows == fresh.rateWindows && partial.capturedAt == now, "Usage-only success cannot freshen old quota")
        require(!partial.hasFreshQuota(at: now.addingTimeInterval(200)), "Stale quota is unknown for live displays")
        for used: Any in [true, "0", -1, 101, 1e100, Double.infinity, NSNull()] {
            let malformed: [String: Any] = ["rateLimits": ["primary": ["usedPercent": used]]]
            require(QuotaRefreshPolicy.windows(from: malformed).isEmpty, "Malformed usage never becomes 100 percent remaining")
            let preserved = UsageSnapshot.refreshed(usage: [:], limits: malformed, fallback: fresh, now: now.addingTimeInterval(200))
            require(preserved.capturedAt == now && preserved.rateWindows == fresh.rateWindows, "Invalid quota preserves original time and windows")
        }
        require(QuotaRefreshPolicy.windows(from: ["rateLimits": ["primary": ["windowDurationMins": 10]]]).isEmpty, "Missing percent is unknown")
        require(QuotaRefreshPolicy.shouldReconnect(failures: 1, errors: [MonitorError.server("401 Unauthorized token_expired")]), "Expired credentials trigger rediscovery")
        require(!QuotaRefreshPolicy.shouldReconnect(failures: 2, errors: [MonitorError.timeout("limits")]), "Transient failures are bounded")
        require(QuotaRefreshPolicy.shouldReconnect(failures: 3, errors: [MonitorError.timeout("limits")]), "Repeated timeout reconnects")
        require(QuotaRefreshPolicy.shouldReconnect(failures: 1, errors: [MonitorError.processEnded]), "Exited process reconnects")
        let estimate = ContextSnapshot(threadId: "a", source: "test", error: "context_estimated")
        require(estimate.percent == nil && estimate.unavailableReason.contains("估计"), "Compacted estimate is not an exact snapshot")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 23, minute: 59))!
        let renewal = calendar.date(from: DateComponents(year: 2026, month: 10, day: 24))!
        require(SubscriptionRenewal.remainingDays(until: renewal, now: today, calendar: calendar) == 1, "Count calendar days, not 24-hour periods")
        require(SubscriptionRenewal.status(for: today, now: today, calendar: calendar) == "今天续费", "Same-day renewal")
        require(SubscriptionRenewal.status(for: today, now: renewal, calendar: calendar).contains("日期已过"), "Past date never rolls forward silently")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dst = calendar.date(from: DateComponents(year: 2026, month: 3, day: 8))!
        let nextDay = calendar.date(from: DateComponents(year: 2026, month: 3, day: 9))!
        require(SubscriptionRenewal.remainingDays(until: nextDay, now: dst, calendar: calendar) == 1, "Day count survives daylight saving")
        print("Swift model checks passed: quota freshness, reconnect policy, unknown values, context compaction, task switching and privacy")
    }
}
