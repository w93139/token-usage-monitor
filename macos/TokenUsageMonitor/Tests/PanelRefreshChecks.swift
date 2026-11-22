import Foundation

@main
struct PanelRefreshChecks {
    static func main() throws {
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let logs = folder.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let database = folder.appendingPathComponent("state_5.sqlite")
        func sql(_ db: URL, _ query: String) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            p.arguments = [db.path, query]
            try p.run()
            p.waitUntilExit()
            precondition(p.terminationStatus == 0)
        }
        let dir = logs.path.replacingOccurrences(of: "'", with: "''")
        try sql(database, """
            CREATE TABLE threads(id TEXT,name TEXT,tokens_used INTEGER,created_at INTEGER,updated_at INTEGER,model TEXT,archived INTEGER,thread_source TEXT,agent_role TEXT,rollout_path TEXT);
            CREATE TABLE thread_spawn_edges(child_thread_id TEXT);
            INSERT INTO threads VALUES('a','Alpha',900,1,5,'model',0,'user',NULL,'\(dir)/a.jsonl'),
                                     ('b','Beta',800,1,3,'model',0,'user',NULL,'\(dir)/b.jsonl');
            """)
        let storage = folder.appendingPathComponent("monitor")
        let suite = "token-monitor.tests." + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let port = Int(CommandLine.arguments[2])!
        let store = MonitorStore(storageDirectory: storage, apiPort: port, defaults: prefs)
        precondition(!store.apiReceiverEnabled, "New installs default to no receiver")
        store.menuQuotaSource = .codex
        let api = storage.appendingPathComponent("usage.sqlite3")
        try sql(api, """
            CREATE TABLE api_usage(id INTEGER, captured_at INTEGER,provider TEXT,model TEXT,task_name TEXT,
                input_tokens INTEGER,cached_input_tokens INTEGER,output_tokens INTEGER,reasoning_tokens INTEGER,total_tokens INTEGER,source TEXT);
            INSERT INTO api_usage VALUES(1,123,'openai','model',NULL,60,0,15,0,75,'response');
            """)

        func write(_ id: String, _ lines: [String]) throws {
            try (lines.joined(separator: "\n") + "\n").write(to: logs.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8)
        }
        func usage(_ tokens: Int, input: Int? = nil) -> String {
            #"{"timestamp":"2026-10-23T00:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"model_context_window":1000,"last_token_usage":{"input_tokens":\#(input ?? tokens),"output_tokens":0,"total_tokens":\#(tokens)}}}}"#
        }
        func waitFor(_ message: String, _ ready: () -> Bool) {
            let deadline = Date().addingTimeInterval(4.9)
            while !ready() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.015)) }
            precondition(ready(), message)
        }
        try write("a", [usage(240)])
        try write("b", [usage(120)])
        store.setPanel(.mainWindow, visible: true)
        waitFor("Opening reads immediately") { store.contextSnapshot?.tokens == 240 }
        store.setPanel(.menuPopover, visible: true)
        precondition(store.apiRecords.isEmpty && store.apiReadAt == nil, "No API detail query for a collapsed panel")
        store.setAPIDetails(.mainWindow, expanded: true)
        waitFor("Expanded rows load immediately") { store.apiRecords.count == 1 }
        store.setAPIDetails(.menuPopover, expanded: true)
        store.setAPIDetails(.mainWindow, expanded: false)
        precondition(store.apiRecords.count == 1, "Second expanded panel retains demand")
        store.setAPIDetails(.menuPopover, expanded: false)
        precondition(store.apiRecords.isEmpty && store.apiReadAt == nil, "Last collapsed panel releases detail rows")
        store.setPanel(.mainWindow, visible: false)
        store.selectContextTask("b")
        store.selectContextTask("a")
        store.selectContextTask("b")
        waitFor("Remaining panel follows the final selection") {
            store.contextSnapshot?.threadId == "b" && store.contextSnapshot?.tokens == 120
        }
        store.setPanel(.menuPopover, visible: false)
        let lastRead = store.tasksReadAt
        let cache = storage.appendingPathComponent("task-usage.json")
        func cacheTime() throws -> Date? {
            try cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        let lastWrite = try cacheTime()
        let reset = #"{"type":"compacted","payload":{}}"#
        try write("b", [usage(120), reset])
        try sql(database, "UPDATE threads SET tokens_used=901 WHERE id='a'")
        store.refreshTasks()
        store.refreshContext()
        let idle = max(6, Double(ProcessInfo.processInfo.environment["TOKEN_MONITOR_TEST_IDLE_SECONDS"] ?? "") ?? 6)
        RunLoop.main.run(until: Date().addingTimeInterval(idle))
        let hiddenWrite = try cacheTime()
        precondition(store.tasksReadAt == lastRead && store.contextReadAt == nil && hiddenWrite == lastWrite, "Hidden panels must leave task data untouched")
        store.setPanel(.menuPopover, visible: true)
        precondition(store.contextSnapshot == nil, "No old context on reopen")
        waitFor("Reopen observes compression during pause") { store.contextSnapshot?.error == "context_reset" }
        precondition(store.taskRecords.first?.tokens == 901 && store.contextSnapshot?.tokens == nil)
        let changedWrite = try cacheTime()
        try write("b", [reset, usage(33, input: 0)])
        store.refreshTasks()
        waitFor("Estimate is unknown") { store.contextSnapshot?.error == "context_estimated" }
        try write("b", [reset, usage(33, input: 0), usage(42)])
        store.refreshTasks()
        waitFor("Measured post-compaction report is used") { store.contextSnapshot?.tokens == 42 }
        let finalWrite = try cacheTime()
        precondition(finalWrite == changedWrite, "Unchanged task rows must not rewrite cache")
        store.setPanel(.menuPopover, visible: false)
        let closedRead = store.tasksReadAt
        try sql(api, "INSERT INTO api_usage VALUES(2,124,'openai','model',NULL,10,0,0,0,10,'response')")
        store.openAIBudgetText = "100"
        store.menuQuotaSource = .openAI
        waitFor("Selected API updates while hidden") { store.apiActivity["openai"]?.totalTokens == 85 && store.menuTitle == "15%" }
        precondition(store.tasksReadAt == closedRead && store.contextReadAt == nil)
        // Use the isolated stdio fixture installed by test_models.sh.
        precondition(ProcessInfo.processInfo.environment["CODEX_BINARY"] != nil)
        let quotaFlag = folder.appendingPathComponent("valid-quota")
        store.refresh()
        waitFor("Usage-only response without cache waits for quota") { !store.isRefreshing && store.connectionState == .retrying }
        try Data().write(to: quotaFlag)
        store.refresh()
        waitFor("Valid quota restores live state") { !store.isRefreshing && store.quotaIsCurrent }
        let quotaTimestamp = store.snapshot.capturedAt
        try FileManager.default.removeItem(at: quotaFlag)
        store.refresh()
        waitFor("Quota failure after success shows cached timestamp") { !store.isRefreshing && store.connectionState == .cached }
        precondition(store.snapshot.capturedAt == quotaTimestamp && !store.quotaIsCurrent)
        try Data().write(to: quotaFlag)
        store.refresh()
        waitFor("Recovery after cached state") { !store.isRefreshing && store.quotaIsCurrent }
        store.stop()

        // A separate disposable installation exercises actual HTTP intake with no panels open.
        let intake = folder.appendingPathComponent("receiver")
        let receiver = MonitorStore(storageDirectory: intake, apiPort: port, defaults: prefs)
        receiver.setAPIReceiverEnabled(true)
        waitFor("Enabled receiver listens") { receiver.apiMonitorAvailable }
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = ["--noproxy", "*", "--max-time", "3", "-fsS", "-H", "Content-Type: application/json", "-d",
            #"{"provider":"openai","model":"test","request_id":"local-only","usage":{"total_tokens":11}}"#,
            "http://127.0.0.1:\(port)/v1/usage"]
        curl.standardOutput = FileHandle.nullDevice
        try curl.run()
        curl.waitUntilExit()
        precondition(curl.terminationStatus == 0 && receiver.apiRecords.isEmpty, "Folded receivable without detail reads")
        receiver.setPanel(.mainWindow, visible: true)
        receiver.setAPIDetails(.mainWindow, expanded: true)
        waitFor("First expansion sees folded receipt") { receiver.apiRecords.first?.totalTokens == 11 }
        receiver.setAPIReceiverEnabled(false)
        receiver.stop()
        precondition(!MonitorStore(storageDirectory: intake, apiPort: port, defaults: prefs).apiReceiverEnabled, "Disabled choice survives restart")
        prefs.removeObject(forKey: "api.receiver.enabled")
        prefs.removeObject(forKey: "menu.quotaSource")
        precondition(MonitorStore(storageDirectory: intake, apiPort: port, defaults: prefs).apiReceiverEnabled, "Keep database-only prior API intake")
        prefs.removeObject(forKey: "api.receiver.enabled")
        let emptyDB = folder.appendingPathComponent("mcp-only")
        try FileManager.default.createDirectory(at: emptyDB, withIntermediateDirectories: true)
        try sql(emptyDB.appendingPathComponent("usage.sqlite3"), "CREATE TABLE api_usage(id INTEGER)")
        precondition(!MonitorStore(storageDirectory: emptyDB, apiPort: port, defaults: prefs).apiReceiverEnabled, "An empty database does not opt into HTTP intake")
        prefs.removeObject(forKey: "api.receiver.enabled")
        try Data().write(to: intake.appendingPathComponent("menu-snapshot.json"))
        precondition(MonitorStore(storageDirectory: intake, apiPort: port, defaults: prefs).apiReceiverEnabled, "Upgrade preserves legacy listener")

        print("Panel checks passed: \(Int(idle))s hidden, immediate reopen, two panels, rapid switching, compaction and hidden API budget")
    }
}
