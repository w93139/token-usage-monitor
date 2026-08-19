import SwiftUI

@main
struct TokenUsageMonitorApp: App {
    @StateObject private var monitor = MonitorStore()

    var body: some Scene {
        MenuBarExtra {
            MonitorPanel(monitor: monitor)
        } label: {
            RemainingRing(
                remainingPercent: monitor.primaryWindow?.remainingPercent,
                size: 21,
                lineWidth: 1.8,
                fontSize: 6.5
            )
            .help("Codex 剩余额度")
        }
        .menuBarExtraStyle(.window)
    }
}
