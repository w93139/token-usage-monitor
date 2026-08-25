import SwiftUI

@main
struct TokenUsageMonitorApp: App {
    @StateObject private var monitor = MonitorStore()
    @StateObject private var pinController = PinnedPanelController()

    var body: some Scene {
        MenuBarExtra {
            MonitorPanel(monitor: monitor, pinController: pinController)
        } label: {
            RemainingRing(
                remainingPercent: monitor.menuBarRemainingPercent,
                size: 21,
                lineWidth: 1.8,
                fontSize: 6.5
            )
            .help("\(monitor.menuQuotaSource.label) 剩余额度")
            .onAppear { pinController.openOnLaunch(monitor: monitor) }
        }
        .menuBarExtraStyle(.window)
    }
}
