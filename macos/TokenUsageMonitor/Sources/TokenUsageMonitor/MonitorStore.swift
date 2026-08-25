import AppKit
import Foundation
import UserNotifications

final class MonitorStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var taskRecords: [TaskUsageRecord]
    @Published private(set) var apiRecords: [APIUsageRecord] = []
    @Published private(set) var apiUsageTotals: [String: Int] = [:]
    @Published private(set) var apiMonitorAvailable = false
    @Published private(set) var connectionState: MonitorConnectionState = .starting
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var availableUpdate: AppUpdateInfo?
    @Published private(set) var updateStatus = "尚未检查更新"
    @Published private(set) var isCheckingForUpdates = false
    @Published var automaticallyChecksForUpdates: Bool {
        didSet { defaults.set(automaticallyChecksForUpdates, forKey: Keys.automaticUpdateChecks) }
    }
    @Published var openAIBudgetText: String {
        didSet { defaults.set(openAIBudgetText, forKey: Keys.openAIBudget) }
    }
    @Published var deepSeekBudgetText: String {
        didSet { defaults.set(deepSeekBudgetText, forKey: Keys.deepSeekBudget) }
    }
    @Published var menuQuotaSource: MenuQuotaSource {
        didSet { defaults.set(menuQuotaSource.rawValue, forKey: Keys.menuQuotaSource) }
    }
    @Published var notificationsEnabled: Bool {
        didSet { defaults.set(notificationsEnabled, forKey: Keys.notificationsEnabled) }
    }
    @Published var thresholdText: String {
        didSet { defaults.set(thresholdText, forKey: Keys.thresholds) }
    }
    @Published var resetWarningMinutes: Int {
        didSet { defaults.set(resetWarningMinutes, forKey: Keys.resetWarningMinutes) }
    }

    private enum Keys {
        static let notificationsEnabled = "notifications.enabled"
        static let thresholds = "notifications.remainingThresholds"
        static let resetWarningMinutes = "notifications.resetWarningMinutes"
        static let notifiedResetPrefix = "monitor.notifiedReset."
        static let automaticUpdateChecks = "updates.automaticCheck"
        static let openAIBudget = "apiBudget.openai"
        static let deepSeekBudget = "apiBudget.deepseek"
        static let menuQuotaSource = "menu.quotaSource"
    }

    private let defaults = UserDefaults.standard
    private let worker = DispatchQueue(label: "token-monitor.collector", qos: .utility)
    private let workerKey = DispatchSpecificKey<Bool>()
    private var timer: DispatchSourceTimer?
    private var taskTimer: DispatchSourceTimer?
    private var client: AppServerClient?
    private var apiServerProcess: Process?
    private var consecutiveQuotaFailures = 0
    private let dataDirectory: URL
    private let snapshotURL: URL
    private let taskRecordsURL: URL
    private let notificationDelegate = NotificationDelegate()
    private var stopped = false
    private var terminationObserver: NSObjectProtocol?
    private var updateCheckTask: URLSessionDataTask?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDirectory = support.appendingPathComponent("Token Usage Monitor", isDirectory: true)
        snapshotURL = dataDirectory.appendingPathComponent("menu-snapshot.json")
        taskRecordsURL = dataDirectory.appendingPathComponent("task-usage.json")
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)

        if let data = try? Data(contentsOf: snapshotURL),
           let saved = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = .empty
        }
        if let data = try? Data(contentsOf: taskRecordsURL),
           let saved = try? JSONDecoder().decode([TaskUsageRecord].self, from: data) {
            taskRecords = saved
        } else {
            taskRecords = []
        }
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        thresholdText = defaults.string(forKey: Keys.thresholds) ?? "20, 5, 0"
        let storedWarning = defaults.integer(forKey: Keys.resetWarningMinutes)
        resetWarningMinutes = storedWarning == 0 ? 30 : storedWarning
        automaticallyChecksForUpdates = defaults.object(forKey: Keys.automaticUpdateChecks) as? Bool ?? true
        openAIBudgetText = defaults.string(forKey: Keys.openAIBudget) ?? ""
        deepSeekBudgetText = defaults.string(forKey: Keys.deepSeekBudget) ?? ""
        menuQuotaSource = MenuQuotaSource(rawValue: defaults.string(forKey: Keys.menuQuotaSource) ?? "") ?? .codex
        worker.setSpecific(key: workerKey, value: true)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.stop() }
        DispatchQueue.main.async { [weak self] in
            self?.start()
            if self?.automaticallyChecksForUpdates == true { self?.checkForUpdates() }
        }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        stop()
    }

    var primaryWindow: RateWindow? {
        snapshot.rateWindows.first(where: { $0.limitID == "codex" && $0.windowName == "primary" })
            ?? snapshot.rateWindows.first
    }

    var menuTitle: String {
        guard let remaining = menuBarRemainingPercent else { return "--%" }
        return "\(Int(remaining.rounded()))%"
    }

    var menuBarRemainingPercent: Double? {
        switch menuQuotaSource {
        case .codex: return primaryWindow?.remainingPercent
        case .openAI: return apiQuota(for: "openai").remainingPercent
        case .deepSeek: return apiQuota(for: "deepseek").remainingPercent
        }
    }

    var apiQuotaSummaries: [APIQuotaSummary] {
        var providers = Set(apiUsageTotals.keys.map { $0.lowercased() })
        providers.formUnion(["openai", "deepseek"])
        let preferred = ["openai", "deepseek"]
        return providers.sorted {
            (preferred.firstIndex(of: $0) ?? Int.max, $0) < (preferred.firstIndex(of: $1) ?? Int.max, $1)
        }.map { apiQuota(for: $0) }
    }

    func apiQuota(for provider: String) -> APIQuotaSummary {
        let normalized = provider.lowercased()
        let budgetText: String?
        switch normalized {
        case "openai": budgetText = openAIBudgetText
        case "deepseek": budgetText = deepSeekBudgetText
        default: budgetText = nil
        }
        let budget = budgetText.flatMap(parseTokenBudget)
        return APIQuotaSummary(
            provider: normalized,
            usedTokens: apiUsageTotals[normalized] ?? 0,
            budgetTokens: budget
        )
    }

    private func parseTokenBudget(_ value: String) -> Int? {
        let digits = value.filter(\.isNumber)
        guard let number = Int(digits), number > 0 else { return nil }
        return number
    }

    var thresholds: [Int] {
        let parsed = thresholdText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .compactMap { Int($0) }
            .filter { (0...99).contains($0) }
        return Array(Set(parsed)).sorted(by: >)
    }

    func start() {
        guard timer == nil else { return }
        stopped = false
        if notificationsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: 30)
        timer.setEventHandler { [weak self] in self?.collect() }
        self.timer = timer
        timer.resume()

        let taskTimer = DispatchSource.makeTimerSource(queue: worker)
        taskTimer.schedule(deadline: .now(), repeating: 5)
        taskTimer.setEventHandler { [weak self] in self?.collectTasks() }
        self.taskTimer = taskTimer
        taskTimer.resume()
        worker.async { [weak self] in self?.startAPIUsageServer() }
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        taskTimer?.cancel()
        taskTimer = nil
        updateCheckTask?.cancel()
        updateCheckTask = nil
        let closeClient = { [weak self] in
            self?.client?.close()
            self?.client = nil
            if let process = self?.apiServerProcess, process.isRunning {
                process.terminate()
            }
            self?.apiServerProcess = nil
        }
        if DispatchQueue.getSpecific(key: workerKey) == true { closeClient() }
        else { worker.sync(execute: closeClient) }
        DispatchQueue.main.async { [weak self] in self?.connectionState = .stopped }
    }

    func refresh() {
        DispatchQueue.main.async { self.isRefreshing = true }
        worker.async { [weak self] in
            self?.collectTasks()
            self?.collect(forceReconnect: false)
        }
    }

    func updateNotificationPermissionIfNeeded() {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func openDataFolder() {
        NSWorkspace.shared.open(dataDirectory)
    }

    func checkForUpdates() {
        guard !isCheckingForUpdates,
              let url = URL(string: "https://github.com/w93139/token-usage-monitor/releases.atom") else { return }
        isCheckingForUpdates = true
        updateStatus = "正在检查更新…"

        var request = URLRequest(url: url)
        request.setValue("TokenMonitor-macOS", forHTTPHeaderField: "User-Agent")
        request.setValue("application/atom+xml", forHTTPHeaderField: "Accept")
        updateCheckTask = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isCheckingForUpdates = false
                self.updateCheckTask = nil
                if let error {
                    self.updateStatus = "检查失败：\(error.localizedDescription)"
                    return
                }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                      let feed = String(data: data, encoding: .utf8),
                      let pageURL = self.firstReleaseURL(in: feed) else {
                    self.updateStatus = "暂时无法读取 GitHub 版本信息"
                    return
                }

                let remoteVersion = pageURL.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
                if self.isVersion(remoteVersion, newerThan: currentVersion) {
                    self.availableUpdate = AppUpdateInfo(version: remoteVersion, pageURL: pageURL, downloadURL: nil)
                    self.updateStatus = "发现新版本 \(remoteVersion)"
                } else {
                    self.availableUpdate = nil
                    self.updateStatus = "当前已是最新版（\(currentVersion)）"
                }
            }
        }
        updateCheckTask?.resume()
    }

    private func firstReleaseURL(in feed: String) -> URL? {
        let marker = "href=\"https://github.com/w93139/token-usage-monitor/releases/tag/"
        guard let markerRange = feed.range(of: marker) else { return nil }
        let remainder = feed[markerRange.upperBound...]
        guard let end = remainder.firstIndex(of: "\"") else { return nil }
        return URL(string: "https://github.com/w93139/token-usage-monitor/releases/tag/" + String(remainder[..<end]))
    }

    func openAvailableUpdate() {
        guard let update = availableUpdate else { return }
        NSWorkspace.shared.open(update.downloadURL ?? update.pageURL)
    }

    private func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let right = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? left[index] : 0
            let rhs = index < right.count ? right[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    private func collect(forceReconnect: Bool = false) {
        guard !stopped else { return }
        do {
            if forceReconnect { client?.close(); client = nil }
            if client == nil {
                DispatchQueue.main.async { self.connectionState = .starting }
                let newClient = AppServerClient(logURL: dataDirectory.appendingPathComponent("menu-monitor.log"))
                newClient.onNotification = { [weak self] method, _ in
                    if method == "account/rateLimits/updated" {
                        self?.worker.async { self?.collect(forceReconnect: false) }
                    }
                }
                let mode = try newClient.connect()
                client = newClient
                DispatchQueue.main.async { self.connectionState = .connected(mode) }
            }
            guard let client else { throw MonitorError.processEnded }

            var usage: [String: Any] = [:]
            var limits: [String: Any] = [:]
            var usageError: Error?
            var limitsError: Error?
            do { limits = try client.request(method: "account/rateLimits/read", timeout: 20) } catch { limitsError = error }
            do { usage = try client.request(method: "account/usage/read", timeout: 20) } catch { usageError = error }

            guard !usage.isEmpty || !limits.isEmpty else {
                consecutiveQuotaFailures += 1
                let shouldReconnect = [usageError, limitsError]
                    .compactMap { $0 }
                    .contains { self.isProcessEnded($0) }
                if shouldReconnect {
                    client.close()
                    self.client = nil
                }
                let hasCachedQuota = !snapshot.rateWindows.isEmpty
                DispatchQueue.main.async {
                    self.lastError = hasCachedQuota
                        ? "账户额度暂时无法更新，正在显示上次数据；任务 Token 记录不受影响。"
                        : "暂时无法读取账户额度，应用会自动重试。"
                    self.isRefreshing = false
                    self.connectionState = hasCachedQuota ? .cached : .retrying("正在自动重试")
                }
                return
            }

            let updated = parseSnapshot(usage: usage, limits: limits, fallback: snapshot)
            let previous = snapshot
            persist(updated)
            evaluateAlerts(previous: previous, current: updated)
            consecutiveQuotaFailures = 0
            DispatchQueue.main.async {
                self.snapshot = updated
                self.lastError = limitsError == nil
                    ? nil
                    : "账户额度暂时无法更新，正在显示上次数据；任务 Token 记录不受影响。"
                self.isRefreshing = false
                self.connectionState = limitsError == nil
                    ? .connected(client.connectionMode ?? "已连接")
                    : .cached
            }
        } catch {
            client?.close()
            client = nil
            consecutiveQuotaFailures += 1
            let hasCachedQuota = !snapshot.rateWindows.isEmpty
            DispatchQueue.main.async {
                self.lastError = hasCachedQuota
                    ? "账户额度暂时无法更新，正在显示上次数据；任务 Token 记录不受影响。"
                    : self.friendlyConnectionError(error)
                self.isRefreshing = false
                self.connectionState = hasCachedQuota ? .cached : .retrying("正在自动重试")
            }
        }
    }

    private func isProcessEnded(_ error: Error) -> Bool {
        guard let monitorError = error as? MonitorError else { return false }
        if case .processEnded = monitorError { return true }
        return false
    }

    private func friendlyConnectionError(_ error: Error) -> String {
        if let monitorError = error as? MonitorError, case .codexNotFound = monitorError {
            return monitorError.localizedDescription
        }
        return "暂时无法连接 Codex 用量服务，应用会自动重试。"
    }

    private func collectTasks() {
        guard !stopped else { return }
        do {
            let records = try readTaskRecords()
            persistTaskRecords(records)
            let apiRecords = readAPIUsageRecords()
            let apiUsageTotals = readAPIUsageTotals()
            DispatchQueue.main.async {
                self.taskRecords = records
                self.apiRecords = apiRecords
                self.apiUsageTotals = apiUsageTotals
            }
        } catch {
            // Task history is an enhancement. Quota monitoring continues if the
            // local Codex state database is temporarily busy or unavailable.
        }
    }

    private func startAPIUsageServer() {
        guard apiServerProcess == nil else { return }
        if isAPIUsageServerHealthy() {
            DispatchQueue.main.async { self.apiMonitorAvailable = true }
            return
        }
        guard let resources = Bundle.main.resourceURL else { return }
        let serverScript = resources.appendingPathComponent("api_usage_server.py")
        guard FileManager.default.fileExists(atPath: serverScript.path) else { return }

        let pythonCandidates = [
            "/usr/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3"
        ]
        guard let python = pythonCandidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            DispatchQueue.main.async { self.apiMonitorAvailable = false }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [serverScript.path, "--port", "47821"]
        process.currentDirectoryURL = resources
        var environment = ProcessInfo.processInfo.environment
        environment["TOKEN_USAGE_MONITOR_HOME"] = dataDirectory.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        if let log = try? FileHandle(forWritingTo: dataDirectory.appendingPathComponent("api-monitor.log")) {
            _ = try? log.seekToEnd()
            process.standardError = log
        } else {
            process.standardError = FileHandle.nullDevice
        }
        do {
            try process.run()
            apiServerProcess = process
            process.terminationHandler = { [weak self, weak process] _ in
                guard let self, let process else { return }
                self.worker.async {
                    guard self.apiServerProcess === process else { return }
                    self.apiServerProcess = nil
                    let isAvailable = self.isAPIUsageServerHealthy()
                    DispatchQueue.main.async { self.apiMonitorAvailable = isAvailable }
                }
            }
            let deadline = Date().addingTimeInterval(2)
            while Date() < deadline, process.isRunning, !isAPIUsageServerHealthy() {
                Thread.sleep(forTimeInterval: 0.1)
            }
            let isAvailable = isAPIUsageServerHealthy()
            if !isAvailable, process.isRunning { process.terminate() }
            DispatchQueue.main.async { self.apiMonitorAvailable = isAvailable }
        } catch {
            DispatchQueue.main.async { self.apiMonitorAvailable = false }
        }
    }

    private func isAPIUsageServerHealthy() -> Bool {
        guard let url = URL(string: "http://127.0.0.1:47821/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.75
        let semaphore = DispatchSemaphore(value: 0)
        var isHealthy = false
        let task = URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data,
                  let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            isHealthy = payload["ok"] as? Bool == true
                && payload["service"] as? String == "token-usage-monitor"
        }
        task.resume()
        if semaphore.wait(timeout: .now() + 1) == .timedOut { task.cancel() }
        return isHealthy
    }

    private func readAPIUsageRecords() -> [APIUsageRecord] {
        let database = dataDirectory.appendingPathComponent("usage.sqlite3")
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        let query = """
        SELECT id, captured_at AS capturedAt, provider, model, task_name AS taskName,
               input_tokens AS inputTokens, cached_input_tokens AS cachedInputTokens,
               output_tokens AS outputTokens, reasoning_tokens AS reasoningTokens,
               total_tokens AS totalTokens
        FROM api_usage ORDER BY captured_at DESC, id DESC LIMIT 100;
        """
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database.path, query]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            guard !data.isEmpty,
                  let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
            return rows.compactMap { row in
                guard let id = row.integer("id"),
                      let capturedAt = row.integer("capturedAt"),
                      let provider = row.string("provider"),
                      let model = row.string("model") else { return nil }
                return APIUsageRecord(
                    id: id,
                    capturedAt: Date(timeIntervalSince1970: TimeInterval(capturedAt)),
                    provider: provider,
                    model: model,
                    taskName: row.string("taskName"),
                    inputTokens: row.integer("inputTokens") ?? 0,
                    cachedInputTokens: row.integer("cachedInputTokens") ?? 0,
                    outputTokens: row.integer("outputTokens") ?? 0,
                    reasoningTokens: row.integer("reasoningTokens") ?? 0,
                    totalTokens: row.integer("totalTokens") ?? 0
                )
            }
        } catch {
            return []
        }
    }

    private func readAPIUsageTotals() -> [String: Int] {
        let database = dataDirectory.appendingPathComponent("usage.sqlite3")
        guard FileManager.default.fileExists(atPath: database.path) else { return [:] }
        let query = "SELECT LOWER(provider) AS provider, SUM(total_tokens) AS total FROM api_usage GROUP BY LOWER(provider);"
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", database.path, query]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty,
                  let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [:] }
            return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                guard let provider = row.string("provider"), let total = row.integer("total") else { return nil }
                return (provider.lowercased(), total)
            })
        } catch {
            return [:]
        }
    }

    private func readTaskRecords() throws -> [TaskUsageRecord] {
        let codexDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        let preferred = codexDirectory.appendingPathComponent("state_5.sqlite")
        let databaseURL: URL
        if FileManager.default.fileExists(atPath: preferred.path) {
            databaseURL = preferred
        } else {
            let candidates = (try? FileManager.default.contentsOfDirectory(
                at: codexDirectory,
                includingPropertiesForKeys: nil
            ))?.filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" } ?? []
            guard let newest = candidates.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).first else {
                return []
            }
            databaseURL = newest
        }

        let query = """
        SELECT id,
               SUBSTR(COALESCE(NULLIF(TRIM(name), ''), NULLIF(TRIM(title), ''), '未命名任务'), 1, 280) AS title,
               tokens_used AS tokens,
               created_at AS createdAt,
               updated_at AS updatedAt,
               NULLIF(model, '') AS model,
               archived
        FROM threads
        WHERE tokens_used > 0
          AND thread_source = 'user'
          AND agent_role IS NULL
          AND id NOT IN (SELECT child_thread_id FROM thread_spawn_edges)
        ORDER BY updated_at DESC
        LIMIT 100;
        """
        let process = Process()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-json", databaseURL.path, query]
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8)
            throw MonitorError.server(message ?? "无法读取本地任务用量")
        }
        guard !data.isEmpty else { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MonitorError.invalidResponse
        }
        return rows.compactMap { row in
            guard let id = row.string("id"),
                  let title = row.string("title"),
                  let tokens = row.integer("tokens"),
                  let createdAt = row.integer("createdAt"),
                  let updatedAt = row.integer("updatedAt") else { return nil }
            return TaskUsageRecord(
                id: id,
                title: title,
                tokens: tokens,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
                updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt)),
                model: row.string("model"),
                archived: (row.integer("archived") ?? 0) != 0
            )
        }
    }

    private func persistTaskRecords(_ records: [TaskUsageRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: taskRecordsURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: taskRecordsURL.path)
    }

    private func parseSnapshot(
        usage: [String: Any],
        limits: [String: Any],
        fallback: UsageSnapshot
    ) -> UsageSnapshot {
        let summaryObject = usage.dictionary("summary")
        let account = summaryObject.map {
            AccountSummary(
                lifetimeTokens: $0.integer("lifetimeTokens"),
                peakDailyTokens: $0.integer("peakDailyTokens"),
                currentStreakDays: $0.integer("currentStreakDays"),
                longestStreakDays: $0.integer("longestStreakDays")
            )
        } ?? fallback.account
        let parsedDays = usage.array("dailyUsageBuckets").compactMap { item -> DailyUsage? in
            guard let date = item.string("startDate"), let tokens = item.integer("tokens") else { return nil }
            return DailyUsage(date: date, tokens: tokens)
        }.sorted { $0.date < $1.date }
        let days = usage.isEmpty ? fallback.dailyUsage : parsedDays

        var windows: [RateWindow] = []
        if let groups = limits.dictionary("rateLimitsByLimitId") {
            for (groupID, raw) in groups {
                guard let group = raw as? [String: Any] else { continue }
                appendWindows(from: group, fallbackID: groupID, into: &windows)
            }
        } else if let single = limits.dictionary("rateLimits") {
            appendWindows(from: single, fallbackID: single.string("limitId") ?? "codex", into: &windows)
        }
        windows.sort {
            if $0.limitID == "codex" && $1.limitID != "codex" { return true }
            if $0.limitID != "codex" && $1.limitID == "codex" { return false }
            return $0.id < $1.id
        }
        if limits.isEmpty { windows = fallback.rateWindows }
        let resetCredits = limits.isEmpty
            ? fallback.availableResetCredits
            : limits.dictionary("rateLimitResetCredits")?.integer("availableCount") ?? 0
        return UsageSnapshot(
            capturedAt: Date(),
            account: account,
            dailyUsage: days,
            rateWindows: windows,
            availableResetCredits: resetCredits
        )
    }

    private func appendWindows(from group: [String: Any], fallbackID: String, into output: inout [RateWindow]) {
        for name in ["primary", "secondary"] {
            guard let item = group.dictionary(name) else { continue }
            output.append(RateWindow(
                limitID: group.string("limitId") ?? fallbackID,
                limitName: group.string("limitName"),
                windowName: name,
                usedPercent: item.double("usedPercent") ?? 0,
                durationMinutes: item.integer("windowDurationMins"),
                resetsAt: item.integer("resetsAt").map { Date(timeIntervalSince1970: TimeInterval($0)) }
            ))
        }
    }

    private func persist(_ value: UsageSnapshot) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: snapshotURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
    }

    private func evaluateAlerts(previous: UsageSnapshot, current: UsageSnapshot) {
        guard notificationsEnabled else { return }
        let now = Date()
        for window in current.rateWindows {
            let old = previous.rateWindows.first(where: { $0.id == window.id })
            for threshold in thresholds where window.remainingPercent <= Double(threshold) {
                if old == nil || (old?.remainingPercent ?? 100) > Double(threshold) {
                    sendNotification(
                        title: "Codex 余量提醒",
                        body: "\(window.displayName)剩余 \(Int(window.remainingPercent.rounded()))%"
                    )
                }
            }
            if let old, let oldReset = old.resetsAt, let newReset = window.resetsAt,
               newReset > oldReset, window.usedPercent < old.usedPercent {
                sendNotification(title: "Codex 额度已刷新", body: "\(window.displayName)的新额度已经到账")
            }
            if let reset = window.resetsAt {
                let remaining = reset.timeIntervalSince(now)
                let warning = TimeInterval(resetWarningMinutes * 60)
                let notificationKey = Keys.notifiedResetPrefix + window.id + "." + String(Int(reset.timeIntervalSince1970))
                if remaining > 0, remaining <= warning, !defaults.bool(forKey: notificationKey) {
                    let minutes = max(1, Int(ceil(remaining / 60)))
                    sendNotification(title: "Codex 即将刷新", body: "\(window.displayName)将在约 \(minutes) 分钟后刷新")
                    defaults.set(true, forKey: notificationKey)
                }
            }
        }
        if current.availableResetCredits > previous.availableResetCredits {
            let count = current.availableResetCredits - previous.availableResetCredits
            sendNotification(title: "Codex 额外刷新可用", body: "检测到 \(count) 个新的重置机会，不会自动兑换")
        }
    }

    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }
}

private final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
