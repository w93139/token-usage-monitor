import Foundation

struct AccountSummary: Codable, Equatable {
    var lifetimeTokens: Int?
    var peakDailyTokens: Int?
    var currentStreakDays: Int?
    var longestStreakDays: Int?
}

struct DailyUsage: Codable, Identifiable, Equatable {
    var date: String
    var tokens: Int
    var id: String { date }
}

struct RateWindow: Codable, Identifiable, Equatable {
    var limitID: String
    var limitName: String?
    var windowName: String
    var usedPercent: Double
    var durationMinutes: Int?
    var resetsAt: Date?

    var id: String { "\(limitID)-\(windowName)" }

    var displayName: String {
        if let limitName, !limitName.isEmpty { return limitName }
        if limitID == "codex" { return windowName == "primary" ? "Codex 周额度" : "Codex 次级额度" }
        return limitID.replacingOccurrences(of: "_", with: " ")
    }
}

struct UsageSnapshot: Codable, Equatable {
    var capturedAt: Date
    var account: AccountSummary?
    var dailyUsage: [DailyUsage]
    var rateWindows: [RateWindow]
    var availableResetCredits: Int

    static let empty = UsageSnapshot(
        capturedAt: .distantPast,
        account: nil,
        dailyUsage: [],
        rateWindows: [],
        availableResetCredits: 0
    )
}

enum MonitorConnectionState: Equatable {
    case starting
    case connected(String)
    case retrying(String)
    case stopped

    var label: String {
        switch self {
        case .starting: return "正在连接"
        case .connected: return "实时监控中"
        case .retrying: return "等待重连"
        case .stopped: return "已停止"
        }
    }

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }
}

enum MonitorError: LocalizedError {
    case codexNotFound
    case processEnded
    case invalidResponse
    case timeout(String)
    case server(String)

    var errorDescription: String? {
        switch self {
        case .codexNotFound:
            return "未找到 Codex CLI。请先安装或打开 Codex。"
        case .processEnded:
            return "Codex 用量服务已退出。"
        case .invalidResponse:
            return "Codex 返回了无法识别的数据。"
        case .timeout(let method):
            return "请求超时：\(method)"
        case .server(let message):
            return message
        }
    }
}

extension Dictionary where Key == String, Value == Any {
    func dictionary(_ key: String) -> [String: Any]? { self[key] as? [String: Any] }
    func array(_ key: String) -> [[String: Any]] { self[key] as? [[String: Any]] ?? [] }

    func integer(_ key: String) -> Int? {
        if let value = self[key] as? Int { return value }
        if let value = self[key] as? NSNumber { return value.intValue }
        return nil
    }

    func double(_ key: String) -> Double? {
        if let value = self[key] as? Double { return value }
        if let value = self[key] as? NSNumber { return value.doubleValue }
        return nil
    }

    func string(_ key: String) -> String? { self[key] as? String }
}
