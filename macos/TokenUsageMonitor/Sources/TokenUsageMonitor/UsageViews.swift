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
            Text("当前上下文").font(.subheadline.weight(.semibold))
            if monitor.taskRecords.isEmpty {
                Text("暂无可选择的任务").font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("查看任务", selection: $monitor.selectedContextTaskID) {
                    ForEach(monitor.taskRecords) { task in Text(task.displayTitle).tag(task.id) }
                }
                .labelsHidden()
                .help("选择要查看上下文的任务；任务列表中的行也可点击")
                if let snapshot = monitor.contextSnapshot, snapshot.threadId == monitor.selectedContextTaskID {
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
                    Text(monitor.isRefreshingTasks ? "正在读取上下文…" : "上下文暂不可用").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("最近一次可观测的上下文占用，不等于任务累计用量；压缩或继续执行后可能变化。")
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
