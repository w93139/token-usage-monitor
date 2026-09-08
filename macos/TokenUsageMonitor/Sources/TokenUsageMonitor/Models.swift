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
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .codex: return "Codex 周额度"
        case .openAI: return "OpenAI API"
        case .deepSeek: return "DeepSeek API"
        case .custom: return "自定义 API 渠道"
        }
    }
}

struct APIQuotaSummary: Identifiable, Equatable {
    var provider: String
    var usedTokens: Int
    var budgetTokens: Int?
    var customName: String? = nil
    var id: String { provider }

    var remainingTokens: Int? {
        budgetTokens.map { max(0, $0 - usedTokens) }
    }

    var remainingPercent: Double? {
        guard let budgetTokens, budgetTokens > 0 else { return nil }
        return max(0, min(100, Double(budgetTokens - usedTokens) / Double(budgetTokens) * 100))
    }

    var displayName: String {
        if let customName, !customName.isEmpty { return customName }
        switch provider.lowercased() {
        case "openai": return "OpenAI API"
        case "deepseek": return "DeepSeek API"
        default: return provider
        }
    }
}

struct APIChannel: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var budget: Int?

    static func parseBudget(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: "^[0-9]+$", options: .regularExpression) != nil,
              let number = Int(trimmed), number > 0 else { return nil }
        return number
    }

    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 64 && value.range(of: "^[a-z0-9][a-z0-9_-]*$", options: .regularExpression) != nil
    }
}

struct APIActivity: Equatable {
    var count: Int
    var lastReceivedAt: Date
}

struct ContextSnapshot: Decodable, Equatable {
    var threadId: String
    var tokens: Int?
    var window: Int?
    var capturedAt: Date?
    var source: String
    var error: String?

    var percent: Double? {
        guard error == nil, let tokens, tokens >= 0, let window, window > 0 else { return nil }
        return Double(tokens) / Double(window) * 100
    }

    var unavailableReason: String {
        switch error {
        case "context_reset": return "上下文已压缩或清空，等待下一次用量上报"
        default: return "暂未取得可用的上下文统计；不会用任务累计值代替"
        }
    }
}

struct TaskUsageRecord: Codable, Identifiable, Equatable {
    static let historyQuery = """
        SELECT id,
               SUBSTR(COALESCE(NULLIF(TRIM(name), ''), '未命名任务 ' || SUBSTR(id, 1, 8)), 1, 280) AS title,
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

struct TaskRecordsCache: Codable {
    var version: Int = 2
    var records: [TaskUsageRecord]
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
    var source: String = "response"

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
