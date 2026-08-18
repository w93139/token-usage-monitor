import AppKit
import Foundation
import UserNotifications

final class MonitorStore: ObservableObject {
    @Published private(set) var snapshot: UsageSnapshot
    @Published private(set) var connectionState: MonitorConnectionState = .starting
    @Published private(set) var lastError: String?
    @Published private(set) var isRefreshing = false
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
        static let thresholds = "notifications.thresholds"
        static let resetWarningMinutes = "notifications.resetWarningMinutes"
        static let notifiedResetPrefix = "monitor.notifiedReset."
    }

    private let defaults = UserDefaults.standard
    private let worker = DispatchQueue(label: "token-monitor.collector", qos: .utility)
    private let workerKey = DispatchSpecificKey<Bool>()
    private var timer: DispatchSourceTimer?
    private var client: AppServerClient?
    private let dataDirectory: URL
    private let snapshotURL: URL
    private let notificationDelegate = NotificationDelegate()
    private var stopped = false
    private var terminationObserver: NSObjectProtocol?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        dataDirectory = support.appendingPathComponent("Token Usage Monitor", isDirectory: true)
        snapshotURL = dataDirectory.appendingPathComponent("menu-snapshot.json")
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dataDirectory.path)

        if let data = try? Data(contentsOf: snapshotURL),
           let saved = try? JSONDecoder().decode(UsageSnapshot.self, from: data) {
            snapshot = saved
        } else {
            snapshot = .empty
        }
        notificationsEnabled = defaults.object(forKey: Keys.notificationsEnabled) as? Bool ?? true
        thresholdText = defaults.string(forKey: Keys.thresholds) ?? "80, 95, 100"
        let storedWarning = defaults.integer(forKey: Keys.resetWarningMinutes)
        resetWarningMinutes = storedWarning == 0 ? 30 : storedWarning
        worker.setSpecific(key: workerKey, value: true)
        UNUserNotificationCenter.current().delegate = notificationDelegate
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in self?.stop() }
        DispatchQueue.main.async { [weak self] in self?.start() }
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
        guard let used = primaryWindow?.usedPercent else { return "--%" }
        return "\(Int(used.rounded()))%"
    }

    var thresholds: [Int] {
        let parsed = thresholdText
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == " " })
            .compactMap { Int($0) }
            .filter { (1...100).contains($0) }
        return Array(Set(parsed)).sorted()
    }

    func start() {
        guard timer == nil else { return }
        stopped = false
        if notificationsEnabled {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        let timer = DispatchSource.makeTimerSource(queue: worker)
        timer.schedule(deadline: .now(), repeating: 60)
        timer.setEventHandler { [weak self] in self?.collect() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        stopped = true
        timer?.cancel()
        timer = nil
        let closeClient = { [weak self] in
            self?.client?.close()
            self?.client = nil
        }
        if DispatchQueue.getSpecific(key: workerKey) == true { closeClient() }
        else { worker.sync(execute: closeClient) }
        DispatchQueue.main.async { [weak self] in self?.connectionState = .stopped }
    }

    func refresh() {
        DispatchQueue.main.async { self.isRefreshing = true }
        worker.async { [weak self] in self?.collect(forceReconnect: false) }
    }

    func updateNotificationPermissionIfNeeded() {
        guard notificationsEnabled else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func openDataFolder() {
        NSWorkspace.shared.open(dataDirectory)
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
            do { usage = try client.request(method: "account/usage/read") } catch { usageError = error }
            do { limits = try client.request(method: "account/rateLimits/read") } catch {
                if let usageError { throw MonitorError.server("\(usageError.localizedDescription)；\(error.localizedDescription)") }
                throw error
            }
            if usage.isEmpty && limits.isEmpty { throw MonitorError.invalidResponse }

            let updated = parseSnapshot(usage: usage, limits: limits)
            let previous = snapshot
            persist(updated)
            evaluateAlerts(previous: previous, current: updated)
            DispatchQueue.main.async {
                self.snapshot = updated
                self.lastError = nil
                self.isRefreshing = false
                self.connectionState = .connected(client.connectionMode ?? "已连接")
            }
        } catch {
            client?.close()
            client = nil
            DispatchQueue.main.async {
                self.lastError = error.localizedDescription
                self.isRefreshing = false
                self.connectionState = .retrying(error.localizedDescription)
            }
        }
    }

    private func parseSnapshot(usage: [String: Any], limits: [String: Any]) -> UsageSnapshot {
        let summaryObject = usage.dictionary("summary")
        let account = summaryObject.map {
            AccountSummary(
                lifetimeTokens: $0.integer("lifetimeTokens"),
                peakDailyTokens: $0.integer("peakDailyTokens"),
                currentStreakDays: $0.integer("currentStreakDays"),
                longestStreakDays: $0.integer("longestStreakDays")
            )
        }
        let days = usage.array("dailyUsageBuckets").compactMap { item -> DailyUsage? in
            guard let date = item.string("startDate"), let tokens = item.integer("tokens") else { return nil }
            return DailyUsage(date: date, tokens: tokens)
        }.sorted { $0.date < $1.date }

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
        let resetCredits = limits.dictionary("rateLimitResetCredits")?.integer("availableCount") ?? 0
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
            for threshold in thresholds where window.usedPercent >= Double(threshold) {
                if old == nil || (old?.usedPercent ?? 0) < Double(threshold) {
                    sendNotification(title: "Codex 用量提醒", body: "\(window.displayName)已使用 \(Int(window.usedPercent.rounded()))%")
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
