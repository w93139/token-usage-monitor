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

struct AppUpdateInfo: Equatable {
    var version: String
    var pageURL: URL
    var downloadURL: URL?
}

enum MenuQuotaSource: String, CaseIterable, Identifiable {
    case codex
    case openAI
    case deepSeek

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex: return "Codex 周额度"
        case .openAI: return "OpenAI API"
        case .deepSeek: return "DeepSeek API"
        }
    }
}

struct APIQuotaSummary: Identifiable, Equatable {
    var provider: String
    var usedTokens: Int
    var budgetTokens: Int?
    var id: String { provider }

    var remainingTokens: Int? {
        budgetTokens.map { max(0, $0 - usedTokens) }
    }

    var remainingPercent: Double? {
        guard let budgetTokens, budgetTokens > 0 else { return nil }
        return max(0, min(100, Double(budgetTokens - usedTokens) / Double(budgetTokens) * 100))
    }

    var displayName: String {
        switch provider.lowercased() {
        case "openai": return "OpenAI API"
        case "deepseek": return "DeepSeek API"
        default: return provider
        }
    }
}

struct TaskUsageRecord: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var tokens: Int
    var createdAt: Date
    var updatedAt: Date
    var model: String?
    var archived: Bool

    var displayTitle: String {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "未命名任务" : cleaned
    }
}

struct APIUsageRecord: Codable, Identifiable, Equatable {
    var id: Int
    var capturedAt: Date
    var provider: String
    var model: String
    var taskName: String?
    var inputTokens: Int
    var cachedInputTokens: Int
    var outputTokens: Int
    var reasoningTokens: Int
    var totalTokens: Int

    var displayTaskName: String {
        guard let taskName, !taskName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "API 调用"
        }
        return taskName
    }
}

struct RateWindow: Codable, Identifiable, Equatable {
    var limitID: String
    var limitName: String?
    var windowName: String
    var usedPercent: Double
    var durationMinutes: Int?
    var resetsAt: Date?

    var id: String { "\(limitID)-\(windowName)" }

    var remainingPercent: Double {
        min(100, max(0, 100 - usedPercent))
    }

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
    case cached
    case retrying(String)
    case stopped

    var label: String {
        switch self {
        case .starting: return "正在连接"
        case .connected: return "实时监控中"
        case .cached: return "显示缓存额度"
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
