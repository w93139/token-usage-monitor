import Charts
import ServiceManagement
import SwiftUI

struct MonitorPanel: View {
    @ObservedObject var monitor: MonitorStore
    @State private var showsSettings = false

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
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.gradient)
                    .frame(width: 38, height: 38)
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
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
                ForEach(monitor.snapshot.rateWindows) { window in rateCard(window) }
            }

            if let account = monitor.snapshot.account { summaryCard(account) }
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
                if window.windowName == "secondary" {
                    Text("次级").font(.caption2).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.secondary.opacity(0.12), in: Capsule())
                }
                Spacer()
                Text("\(Int(window.usedPercent.rounded()))%")
                    .font(.title2.monospacedDigit().weight(.bold))
                    .foregroundStyle(progressColor(window.usedPercent))
            }
            ProgressView(value: min(window.usedPercent, 100), total: 100)
                .tint(progressColor(window.usedPercent))
            HStack {
                Text("剩余 \(Int(max(0, 100 - window.usedPercent).rounded()))%")
                Spacer()
                if let reset = window.resetsAt {
                    Text("刷新 ") + Text(reset, style: .relative)
                } else {
                    Text("刷新时间未知")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private var settings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("提醒设置").font(.headline)
            Toggle("系统通知", isOn: $monitor.notificationsEnabled)
                .onChange(of: monitor.notificationsEnabled) { _ in monitor.updateNotificationPermissionIfNeeded() }
            VStack(alignment: .leading, spacing: 5) {
                Text("用量阈值").font(.subheadline)
                TextField("80, 95, 100", text: $monitor.thresholdText).textFieldStyle(.roundedBorder)
                Text("使用逗号分隔，范围为 1–100").font(.caption).foregroundStyle(.secondary)
            }
            Stepper("刷新前提醒：\(monitor.resetWarningMinutes) 分钟", value: $monitor.resetWarningMinutes, in: 5...240, step: 5)

            Divider()
            Text("应用").font(.headline)
            LaunchAtLoginToggle()
            Button("打开本地数据目录") { monitor.openDataFolder() }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Label("只保存用量数字，不读取或保存对话正文", systemImage: "lock.shield")
                Label("额外刷新只提醒，不会自动兑换", systemImage: "hand.raised")
                Label("每 60 秒刷新一次", systemImage: "clock.arrow.circlepath")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
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

    private func progressColor(_ value: Double) -> Color {
        if value >= 95 { return .red }
        if value >= 80 { return .orange }
        return .accentColor
    }

    private func compact(_ number: Int?) -> String {
        guard let number else { return "—" }
        return number.formatted(.number.notation(.compactName))
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
