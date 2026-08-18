import SwiftUI

@main
struct TokenUsageMonitorApp: App {
    @StateObject private var monitor = MonitorStore()

    var body: some Scene {
        MenuBarExtra {
            MonitorPanel(monitor: monitor)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                Text(monitor.menuTitle).monospacedDigit()
            }
            .help("Codex Token 用量")
        }
        .menuBarExtraStyle(.window)
    }
}
