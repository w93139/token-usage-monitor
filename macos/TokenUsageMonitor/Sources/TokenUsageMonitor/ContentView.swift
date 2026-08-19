import AppKit
import Charts
import ServiceManagement
import SwiftUI

struct MonitorPanel: View {
    @ObservedObject var monitor: MonitorStore
    @State private var showsSettings = false
    @State private var showsSupplementalLimits = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                if showsSettings { settings } else { dashboard }
            }
            Divider()
            footer
        }
        .frame(width: 370, height: 540)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 10) {
            if let logo = appLogo {
                Image(nsImage: logo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 40, height: 40)
            } else {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Token Usage Monitor").font(.headline)
                HStack(spacing: 5) {
                    Circle()
                        .fill(monitor.connectionState.isConnected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(monitor.connectionState.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button { showsSettings.toggle() } label: {
                Image(systemName: showsSettings ? "xmark" : "gearshape")
            }
            .buttonStyle(.plain)
            .help(showsSettings ? "返回" : "设置")
        }
        .padding(14)
    }

    private var dashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }

            if monitor.snapshot.rateWindows.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("正在读取 Codex 用量…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 45)
            } else {
                ForEach(visibleRateWindows) { window in rateCard(window) }
                if hiddenSupplementalCount > 0 && !showsSupplementalLimits {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { showsSupplementalLimits = true }
                    } label: {
                        Label("显示 \(hiddenSupplementalCount) 个未使用的模型专属额度", systemImage: "plus.circle")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                } else if showsSupplementalLimits && supplementalWindows.count > 0 {
                    Button("隐藏未使用的模型专属额度") {
                        withAnimation(.easeInOut(duration: 0.2)) { showsSupplementalLimits = false }
                    }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }

            if let account = monitor.snapshot.account { summaryCard(account) }
            if !monitor.taskRecords.isEmpty { taskUsageCard }
            apiUsageCard
            if !monitor.snapshot.dailyUsage.isEmpty { historyChart }

            if monitor.snapshot.availableResetCredits > 0 {
                Label("可用额外刷新：\(monitor.snapshot.availableResetCredits)", systemImage: "sparkles")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.mint)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.mint.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            }
        }
        .padding(14)
    }

    private func rateCard(_ window: RateWindow) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.displayName).font(.subheadline.weight(.semibold))
                if window.limitID != "codex" {
                    Text("模型专属").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Color.blue.opacity(0.12), in: Capsule())
                } else if window.windowName == "secondary" {
                    Text("次级").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text("剩余 \(Int(window.remainingPercent.rounded()))%")
                    .font(.title2.monospacedDigit().weight(.bold))
                    .foregroundStyle(remainingColor(window.remainingPercent))
            }
            ProgressView(value: window.remainingPercent, total: 100)
                .tint(remainingColor(window.remainingPercent))
            HStack {
                Text(remainingDescription(window.remainingPercent))
                Spacer()
                if let reset = window.resetsAt {
                    Text("刷新 ") + Text(reset, style: .relative)
                } else {
                    Text("刷新时间未知")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if window.limitID != "codex" {
                Text("独立可用额度，不代表当前正在使用此模型")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func summaryCard(_ account: AccountSummary) -> some View {
        HStack(spacing: 0) {
            metric(title: "累计 Token", value: compact(account.lifetimeTokens))
            Divider().frame(height: 38)
            metric(title: "单日峰值", value: compact(account.peakDailyTokens))
            Divider().frame(height: 38)
            metric(title: "连续使用", value: account.currentStreakDays.map { "\($0) 天" } ?? "—")
        }
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func metric(title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.monospacedDigit().weight(.semibold))
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var historyChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("最近用量").font(.subheadline.weight(.semibold))
            Chart(Array(monitor.snapshot.dailyUsage.suffix(14))) { item in
                BarMark(x: .value("日期", item.date), y: .value("Token", item.tokens))
                    .foregroundStyle(Color.accentColor.gradient)
                    .cornerRadius(2)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.15))
                    AxisValueLabel {
                        if let number = value.as(Int.self) { Text(compact(number)) }
                    }
                }
            }
            .frame(height: 105)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var taskUsageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("任务 Token 记录").font(.subheadline.weight(.semibold))
                Spacer()
                Label("5 秒刷新", systemImage: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            ForEach(Array(monitor.taskRecords.prefix(10))) { task in
                HStack(spacing: 10) {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.displayTitle)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        HStack(spacing: 5) {
                            Text(task.updatedAt, style: .relative)
                            if let model = task.model, !model.isEmpty {
                                Text("·")
                                Text(model)
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(compact(task.tokens))
                        .font(.caption.monospacedDigit().weight(.semibold))
                    Text("tokens")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if task.id != monitor.taskRecords.prefix(10).last?.id { Divider() }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var apiUsageCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("外部 API 用量").font(.subheadline.weight(.semibold))
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(monitor.apiMonitorAvailable ? Color.green : Color.orange).frame(width: 6, height: 6)
                    Text(monitor.apiMonitorAvailable ? "本机监听中" : "未启动")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            if monitor.apiRecords.isEmpty {
                Text("支持 OpenAI、DeepSeek 及 OpenAI 兼容模型；记录 API 响应中的 usage，不保存提示词、回复或密钥。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(Array(monitor.apiRecords.prefix(8))) { record in
                    HStack(spacing: 9) {
                        Text(record.provider.uppercased())
                            .font(.system(size: 8, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 3)
                            .background(Color.purple.opacity(0.13), in: Capsule())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.displayTaskName).font(.caption.weight(.medium)).lineLimit(1)
                            Text("\(record.model) · \(record.capturedAt, style: .relative)")
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(compact(record.totalTokens))
                            .font(.caption.monospacedDigit().weight(.semibold))
                        Text("tokens").font(.caption2).foregroundStyle(.secondary)
                    }
                    if record.id != monitor.apiRecords.prefix(8).last?.id { Divider() }
                }
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Group {
                Text("提醒设置").font(.headline)
                Toggle("系统通知", isOn: $monitor.notificationsEnabled)
                    .onChange(of: monitor.notificationsEnabled) { _ in monitor.updateNotificationPermissionIfNeeded() }
                VStack(alignment: .leading, spacing: 5) {
                    Text("低余量提醒").font(.subheadline)
                    TextField("20, 5, 0", text: $monitor.thresholdText).textFieldStyle(.roundedBorder)
                    Text("剩余比例降到这些数值时提醒，以逗号分隔").font(.caption).foregroundStyle(.secondary)
                }
                Stepper("刷新前提醒：\(monitor.resetWarningMinutes) 分钟", value: $monitor.resetWarningMinutes, in: 5...240, step: 5)
            }

            Group {
                Divider()
                Text("应用").font(.headline)
                LaunchAtLoginToggle()
                Button("打开本地数据目录") { monitor.openDataFolder() }
            }

            Group {
                Divider()
                Text("API 监控").font(.headline)
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("本机记录端点").font(.subheadline)
                        Text("http://127.0.0.1:47821/v1/usage")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("复制") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("http://127.0.0.1:47821/v1/usage", forType: .string)
                    }
                }
                Text("将 OpenAI、DeepSeek 或兼容 API 响应中的 usage 对象发送到此端点，即可按模型和任务记录。API Key 不应发送给监控器。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Group {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    Label("只保存用量数字，不读取或保存对话正文", systemImage: "lock.shield")
                    Label("额外刷新只提醒，不会自动兑换", systemImage: "hand.raised")
                    Label("任务每 5 秒、账户额度每 30 秒刷新", systemImage: "clock.arrow.circlepath")
                    Label("本机保存任务名称与 Token 数，不保存对话正文", systemImage: "text.badge.checkmark")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if monitor.snapshot.capturedAt > .distantPast {
                Text("更新于 ") + Text(monitor.snapshot.capturedAt, style: .relative)
            } else {
                Text("尚未更新")
            }
            Spacer()
            Button { monitor.refresh() } label: {
                if monitor.isRefreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(.plain)
            .disabled(monitor.isRefreshing)
            .help("立即刷新")
            Menu {
                Button("退出 Token Usage Monitor") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func remainingColor(_ value: Double) -> Color {
        if value <= 5 { return .red }
        if value <= 20 { return .orange }
        return .accentColor
    }

    private func remainingDescription(_ value: Double) -> String {
        if value <= 5 { return "余量即将耗尽" }
        if value <= 20 { return "余量偏低" }
        return "余量充足"
    }

    private var appLogo: NSImage? {
        guard let url = Bundle.main.url(forResource: "AppLogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    private func compact(_ number: Int?) -> String {
        guard let number else { return "—" }
        return number.formatted(.number.notation(.compactName))
    }

    private var supplementalWindows: [RateWindow] {
        monitor.snapshot.rateWindows.filter { $0.limitID != "codex" }
    }

    private var hiddenSupplementalCount: Int {
        supplementalWindows.filter { $0.usedPercent == 0 }.count
    }

    private var visibleRateWindows: [RateWindow] {
        monitor.snapshot.rateWindows.filter {
            $0.limitID == "codex" || $0.usedPercent > 0 || showsSupplementalLimits
        }
    }
}

private struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("登录时自动启动", isOn: Binding(get: { enabled }, set: { update($0) }))
            if let errorText { Text(errorText).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func update(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            enabled = value
            errorText = nil
        } catch {
            enabled = SMAppService.mainApp.status == .enabled
            errorText = "请将应用移到“应用程序”文件夹后再开启"
        }
    }
}
