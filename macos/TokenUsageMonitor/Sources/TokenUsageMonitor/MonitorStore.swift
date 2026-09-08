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
    @Published private(set) var isRefreshingTasks = false
    @Published private(set) var tasksReadAt: Date?
    @Published private(set) var taskReadError: String?
    @Published private(set) var apiReadError: String?
    @Published private(set) var apiReadAt: Date?
    @Published private(set) var apiActivity: [String: APIActivity] = [:]
    @Published private(set) var contextSnapshot: ContextSnapshot?
    @Published var selectedContextTaskID = "" {
        didSet {
            guard oldValue != selectedContextTaskID else { return }
            contextSnapshot = nil
            refreshTasks()
        }
    }
    @Published private(set) var apiChannels: [APIChannel] = []
    @Published var selectedAPIChannel: String {
        didSet { defaults.set(selectedAPIChannel, forKey: "api.selectedChannel") }
    }
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
    private let taskWorker = DispatchQueue(label: "token-monitor.local-records", qos: .utility)
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
           let saved = try? JSONDecoder().decode(TaskRecordsCache.self, from: data), saved.version == 2 {
            taskRecords = saved.records
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
        selectedAPIChannel = defaults.string(forKey: "api.selectedChannel") ?? ""
        if let data = defaults.data(forKey: "api.channels"),
           let saved = try? JSONDecoder().decode([APIChannel].self, from: data) { apiChannels = saved }
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
        case .openAI: return apiActivity["openai"] == nil ? nil : apiQuota(for: "openai").remainingPercent
        case .deepSeek: return apiActivity["deepseek"] == nil ? nil : apiQuota(for: "deepseek").remainingPercent
        case .custom:
            guard !selectedAPIChannel.isEmpty, apiActivity[selectedAPIChannel] != nil else { return nil }
            return apiQuota(for: selectedAPIChannel).remainingPercent
        }
    }

    var menuQuotaLabel: String {
        if menuQuotaSource == .codex { return menuQuotaSource.label }
        let title = menuQuotaSource == .custom ? (apiChannels.first { $0.id == selectedAPIChannel }?.name ?? "自定义 API 渠道") : menuQuotaSource.label
        return "\(title) 本地预算"
    }

    func saveChannel(id: String, name: String, budgetText: String) -> String? {
        let key = id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard APIChannel.validID(key), !["openai", "deepseek"].contains(key) else {
            return "渠道标识请用 1–64 位小写字母、数字、连字符或下划线；不要使用 openai/deepseek"
        }
        guard !title.isEmpty, title.count <= 64 else { return "请填写 1–64 字的渠道名称" }
        let budgetValue = budgetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let budget = APIChannel.parseBudget(budgetValue)
        guard budgetValue.isEmpty || (budget != nil && budget! > 0) else { return "总预算请填写正整数，或留空" }
        let item = APIChannel(id: key, name: title, budget: budget)
        var channels = apiChannels
        if let index = channels.firstIndex(where: { $0.id == key }) { channels[index] = item }
        else { channels.append(item) }
        guard let data = try? JSONEncoder().encode(channels) else { return "渠道配置未能保存" }
        defaults.set(data, forKey: "api.channels")
        apiChannels = channels
        if selectedAPIChannel.isEmpty { selectedAPIChannel = key }
        return nil
    }

    func ingestionExample(provider: String) -> String {
        // Deliberately a template, not fabricated usage that is sent to the listener.
        """
        {"provider":"\(provider)","model":"填写响应中的模型名","request_id":"填写唯一响应ID","source":"response","usage":{"input_tokens":120,"output_tokens":30,"total_tokens":150}}
        """
    }

    func removeChannel(_ id: String) {
        let channels = apiChannels.filter { $0.id != id }
        guard let data = try? JSONEncoder().encode(channels) else { return }
        defaults.set(data, forKey: "api.channels")
        apiChannels = channels
        if selectedAPIChannel == id { selectedAPIChannel = channels.first?.id ?? "" }
    }

    var apiQuotaSummaries: [APIQuotaSummary] {
        var providers = Set(apiUsageTotals.keys.map { $0.lowercased() })
        providers.formUnion(["openai", "deepseek"])
        providers.formUnion(apiChannels.map(\.id))
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
        default: budgetText = apiChannels.first { $0.id == normalized }?.budget.map(String.init)
        }
        let budget = budgetText.flatMap(parseTokenBudget)
        return APIQuotaSummary(
            provider: normalized,
            usedTokens: apiUsageTotals[normalized] ?? 0,
            budgetTokens: budget,
            customName: apiChannels.first { $0.id == normalized }?.name
        )
    }

    private func parseTokenBudget(_ value: String) -> Int? {
        APIChannel.parseBudget(value)
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

        let taskTimer = DispatchSource.makeTimerSource(queue: .main)
        taskTimer.schedule(deadline: .now(), repeating: 5)
        taskTimer.setEventHandler { [weak self] in self?.refreshTasks() }
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
        refreshTasks()
        guard !isRefreshing else { return }
        isRefreshing = true
        worker.async { [weak self] in
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

    func refreshTasks() {
        guard !stopped, !isRefreshingTasks else { return }
        isRefreshingTasks = true
        let requestedID = selectedContextTaskID
        taskWorker.async { [weak self] in
            guard let self else { return }
            let tasks = Result { try self.readTaskRecords() }
            let apis = Result { try self.readAPIUsageRecords() }
            let totals = Result { try self.readAPIUsageTotals() }
            let activity = Result { try self.readAPIActivity() }
            let healthy = self.isAPIUsageServerHealthy()
            let records = try? tasks.get()
            let contextID = requestedID.isEmpty ? (records?.first?.id ?? "") : requestedID
            let context = contextID.isEmpty ? nil : self.readContext(threadID: contextID)
            DispatchQueue.main.async {
                guard !self.stopped else { self.isRefreshingTasks = false; return }
                switch tasks {
                case .success(let rows):
                    self.taskRecords = rows
                    self.persistTaskRecords(rows)
                    self.tasksReadAt = Date()
                    self.taskReadError = nil
                case .failure:
                    self.taskReadError = "读取失败，保留上次任务数据"
                }
                do {
                    let rows = try apis.get()
                    let sums = try totals.get()
                    let received = try activity.get()
                    self.apiRecords = rows
                    self.apiUsageTotals = sums
                    self.apiActivity = received
                    self.apiReadError = nil
                    self.apiReadAt = Date()
                } catch { self.apiReadError = "读取失败，保留上次 API 数据" }
                self.apiMonitorAvailable = healthy
                self.isRefreshingTasks = false
                if self.selectedContextTaskID.isEmpty, !contextID.isEmpty {
                    // Setting the initial selection triggers one fresh local read.
                    self.selectedContextTaskID = contextID
                }
                if self.selectedContextTaskID == contextID { self.contextSnapshot = context }
                else if !self.selectedContextTaskID.isEmpty { self.refreshTasks() }
            }
        }
    }

    private func readContext(threadID: String) -> ContextSnapshot? {
        let unavailable = ContextSnapshot(threadId: threadID, source: "unavailable", error: "read_failed")
        guard let script = Bundle.main.url(forResource: "context_snapshot", withExtension: "py") else { return unavailable }
        do {
            let data = try runLocalProcess(executable: "/usr/bin/python3", arguments: [script.path, "--thread-id", threadID])
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .secondsSince1970
            let value = try decoder.decode(ContextSnapshot.self, from: data)
            return value.threadId == threadID ? value : unavailable
        } catch { return unavailable }
    }

    private func runLocalProcess(executable: String, arguments: [String]) throws -> Data {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = environment
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Local reads are independent from network collection; cap unexpected hangs.
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 8, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { throw MonitorError.invalidResponse }
        return data
    }

    private func readAPIActivity() throws -> [String: APIActivity] {
        let database = dataDirectory.appendingPathComponent("usage.sqlite3")
        guard FileManager.default.fileExists(atPath: database.path) else { return [:] }
        let data = try runLocalProcess(executable: "/usr/bin/sqlite3", arguments: ["-readonly", "-json", database.path,
            "SELECT LOWER(provider) AS provider, COUNT(*) AS count, MAX(captured_at) AS last FROM api_usage GROUP BY LOWER(provider);"])
        guard !data.isEmpty else { return [:] }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MonitorError.invalidResponse }
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let provider = row.string("provider"), let count = row.integer("count"), let last = row.integer("last") else { return nil }
            return (provider, APIActivity(count: count, lastReceivedAt: Date(timeIntervalSince1970: TimeInterval(last))))
        })
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
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
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

    private func readAPIUsageRecords() throws -> [APIUsageRecord] {
        let database = dataDirectory.appendingPathComponent("usage.sqlite3")
        guard FileManager.default.fileExists(atPath: database.path) else { return [] }
        let query = """
        SELECT id, captured_at AS capturedAt, provider, model, task_name AS taskName,
               input_tokens AS inputTokens, cached_input_tokens AS cachedInputTokens,
               output_tokens AS outputTokens, reasoning_tokens AS reasoningTokens,
               total_tokens AS totalTokens, source
        FROM api_usage ORDER BY captured_at DESC, id DESC LIMIT 100;
        """
        let data = try runLocalProcess(executable: "/usr/bin/sqlite3", arguments: ["-readonly", "-json", database.path, query])
        guard !data.isEmpty else { return [] }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MonitorError.invalidResponse }
        return rows.compactMap { row in
            guard let id = row.integer("id"), let capturedAt = row.integer("capturedAt"),
                  let provider = row.string("provider"), let model = row.string("model"),
                  let total = row.integer("totalTokens") else { return nil }
            return APIUsageRecord(id: id, capturedAt: Date(timeIntervalSince1970: TimeInterval(capturedAt)),
                provider: provider, model: model, taskName: row.string("taskName"),
                inputTokens: row.integer("inputTokens") ?? 0, cachedInputTokens: row.integer("cachedInputTokens") ?? 0,
                outputTokens: row.integer("outputTokens") ?? 0, reasoningTokens: row.integer("reasoningTokens") ?? 0,
                totalTokens: total, source: row.string("source") ?? "response")
        }
    }

    private func readAPIUsageTotals() throws -> [String: Int] {
        let database = dataDirectory.appendingPathComponent("usage.sqlite3")
        guard FileManager.default.fileExists(atPath: database.path) else { return [:] }
        let query = "SELECT LOWER(provider) AS provider, SUM(total_tokens) AS total FROM api_usage GROUP BY LOWER(provider);"
        let data = try runLocalProcess(executable: "/usr/bin/sqlite3", arguments: ["-readonly", "-json", database.path, query])
        guard !data.isEmpty else { return [:] }
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw MonitorError.invalidResponse }
        return Dictionary(uniqueKeysWithValues: rows.compactMap { row in
            guard let provider = row.string("provider"), let total = row.integer("total") else { return nil }
            return (provider.lowercased(), total)
        })
    }

    private func readTaskRecords() throws -> [TaskUsageRecord] {
        let environment = ProcessInfo.processInfo.environment
        let homePath = environment["CODEX_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let codexDirectory = URL(fileURLWithPath: (homePath as NSString).expandingTildeInPath)
        let databaseURL: URL
        if let override = environment["CODEX_STATE_DB"], !override.isEmpty {
            databaseURL = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
        let candidates = try FileManager.default.contentsOfDirectory(at: codexDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" && Int($0.deletingPathExtension().lastPathComponent.dropFirst(6)) != nil }
        func version(_ url: URL) -> Int { Int(url.deletingPathExtension().lastPathComponent.dropFirst(6)) ?? -1 }
        guard let newest = candidates.max(by: { version($0) < version($1) }) else {
            throw MonitorError.server("未找到 Codex 本地任务数据库")
        }
        databaseURL = newest
        }

        let query = TaskUsageRecord.historyQuery
        let data = try runLocalProcess(executable: "/usr/bin/sqlite3", arguments: ["-readonly", "-json", databaseURL.path, query])
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
        guard let data = try? JSONEncoder().encode(TaskRecordsCache(records: records)) else { return }
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
        let resetCredits: Int
        if limits.isEmpty {
            resetCredits = fallback.availableResetCredits
        } else if let availableCount = limits.dictionary("rateLimitResetCredits")?.integer("availableCount") {
            resetCredits = availableCount
        } else {
            // Reset-credit metadata can be absent from an otherwise successful
            // response. Keep the last known value instead of briefly dropping
            // to zero and notifying again when the field reappears.
            resetCredits = fallback.availableResetCredits
        }
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
