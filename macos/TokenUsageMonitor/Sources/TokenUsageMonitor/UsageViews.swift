import AppKit
import SwiftUI

struct HoverFeedback: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false
    func body(content: Content) -> some View {
        content
            .background(hovered ? Color.primary.opacity(0.065) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
    }
}

extension View {
    func usageHover() -> some View { modifier(HoverFeedback()) }
}

struct ContextUsageCard: View {
    @ObservedObject var monitor: MonitorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(monitor.contextSelection.pinnedID == nil ? "最近活动上下文" : "所选任务上下文")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if monitor.contextSelection.pinnedID != nil {
                    Button("返回最近活动") { monitor.selectContextTask(nil) }
                        .font(.caption).usageHover()
                }
            }
            if let task = monitor.selectedContextTask {
                Text(task.displayTitle).font(.caption.weight(.medium)).lineLimit(2)
                    .help("\(task.displayTitle)\n任务编号：\(task.id)")
                Text("\(task.id.suffix(8)) · \(monitor.contextSelection.pinnedID == nil ? "自动跟随最近更新" : "固定查看")\(task.archived ? " · 已归档" : "")")
                    .font(.caption2).foregroundStyle(.secondary)
                if let snapshot = monitor.contextSnapshot, snapshot.threadId == task.id {
                    if snapshot.error == nil, let tokens = snapshot.tokens {
                        HStack {
                            Text("\(tokens.formatted()) tokens").font(.subheadline.monospacedDigit().weight(.semibold))
                            Spacer()
                            if let percent = snapshot.percent { Text(String(format: "%.1f%%", percent)).font(.caption.monospacedDigit()) }
                        }
                        if let percent = snapshot.percent {
                            ProgressView(value: min(100, percent), total: 100)
                            Text("运行时容量 \((snapshot.window ?? 0).formatted()) tokens").font(.caption2).foregroundStyle(.secondary)
                        }
                        if let time = snapshot.capturedAt {
                            TimelineView(.periodic(from: .now, by: 1)) { tick in
                                HStack(spacing: 4) {
                                    Text(tick.date.timeIntervalSince(time) > 60 ? "历史快照 · 上报于" : "最近上报于")
                                    Text(time, style: .relative)
                                }.font(.caption2).foregroundStyle(tick.date.timeIntervalSince(time) > 60 ? Color.orange : Color.secondary)
                            }
                        }
                    } else {
                        Text(snapshot.unavailableReason).font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    Text(monitor.isRefreshingContext ? "正在读取上下文…" : "上下文暂不可用").font(.caption).foregroundStyle(.secondary)
                }
                Text("此任务累计 \(task.tokens.formatted()) tokens")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                Text("暂无未归档的活动任务，可从下方选择历史任务。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            TimelineView(.periodic(from: .now, by: 1)) { tick in
                if monitor.isRefreshingContext {
                    Text("正在读取本地上下文…").font(.caption2).foregroundStyle(.secondary)
                } else if let read = monitor.contextReadAt {
                    HStack(spacing: 3) {
                        Text(tick.date.timeIntervalSince(read) > 20 ? "读取可能中断 · 检查于" : "本地监测中 · 检查于")
                        Text(read, style: .relative)
                    }.font(.caption2).foregroundStyle(tick.date.timeIntervalSince(read) > 20 ? Color.orange : Color.secondary)
                }
            }
            Text("按本地任务更新时间跟随，不代表 Codex 前台任务。这里是最近上报的上下文快照，压缩或继续执行后可能变化。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct APIChannelSettings: View {
    @ObservedObject var monitor: MonitorStore
    @State private var channelID = ""
    @State private var channelName = ""
    @State private var budgetText = ""
    @State private var feedback: String?
    @State private var saved = false
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("中转站与自定义渠道").font(.subheadline.weight(.semibold))
            Text("渠道只用于归类上报记录。不会自动连接中转站，也不会读取 API Key。")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(monitor.apiChannels) { channel in
                HStack {
                Button {
                    channelID = channel.id
                    channelName = channel.name
                    budgetText = channel.budget.map(String.init) ?? ""
                    feedback = nil
                } label: {
                    HStack { Text(channel.name); Spacer(); Text(channel.id).foregroundStyle(.secondary); Image(systemName: "pencil") }
                        .font(.caption).padding(5)
                }.buttonStyle(.plain).usageHover().help("编辑渠道；同一标识保存会更新配置，保留全部用量记录")
                Button {
                    monitor.removeChannel(channel.id)
                    if channelID == channel.id { channelID = ""; channelName = ""; budgetText = "" }
                    feedback = "配置已移除，用量记录保留"; saved = true
                } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless).usageHover().help("移除渠道配置，保留用量记录；可随时用相同标识重新添加")
                }
            }
            TextField("渠道标识，例如 my-relay", text: $channelID).textFieldStyle(.roundedBorder)
            TextField("显示名称，例如 我的中转站", text: $channelName).textFieldStyle(.roundedBorder)
            TextField("本地 Token 预算，可留空", text: $budgetText).textFieldStyle(.roundedBorder)
            Button("保存渠道") {
                if let error = monitor.saveChannel(id: channelID, name: channelName, budgetText: budgetText) {
                    feedback = error; saved = false
                } else { feedback = "渠道已保存；上报时 provider 必须与渠道标识一致"; saved = true }
            }.usageHover()
            if let feedback { Text(feedback).font(.caption2).foregroundStyle(saved ? Color.green : Color.orange) }
            if !monitor.apiChannels.isEmpty {
                Picker("自定义菜单栏渠道", selection: $monitor.selectedAPIChannel) {
                    ForEach(monitor.apiChannels) { channel in Text(channel.name).tag(channel.id) }
                }
            }
            Text("预算是自己设定的用量目标，不代表中转站账户余额或实际账单。")
                .font(.caption2).foregroundStyle(.secondary)
            Button(copied ? "示例已复制" : "复制用量上报示例") {
                let provider = monitor.selectedAPIChannel.isEmpty ? "openai" : monitor.selectedAPIChannel
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(monitor.ingestionExample(provider: provider), forType: .string)
                copied = true
            }.usageHover()
            .onChange(of: monitor.selectedAPIChannel) { _ in copied = false }
            Text("示例数字仅作格式说明，接入时替换为真实响应 usage，再由客户端发送至本机端点。流式调用需取得最终 usage；缺失时不能当作零消耗。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SubscriptionSettings: View {
    @ObservedObject var monitor: MonitorStore
    @State private var date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("月订阅续费日期").font(.headline)
            DatePicker("下次续费日", selection: $date, displayedComponents: .date)
            HStack {
                Button("保存续费日期") { monitor.setSubscriptionRenewalDate(date) }.usageHover()
                if monitor.subscriptionRenewalDate != nil {
                    Button("清除记录") { monitor.setSubscriptionRenewalDate(nil) }.usageHover()
                }
            }
            if let saved = monitor.subscriptionRenewalDate {
                Text("已保存：\(saved.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("请按账户账单填写。此日期仅在本机记录，不是额度重置日；到期后需手动更新，不会自动扣款或推算续期。")
                .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { date = monitor.subscriptionRenewalDate ?? Date() }
    }
}
