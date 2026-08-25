import SwiftUI

@main
struct TokenUsageMonitorApp: App {
    @StateObject private var monitor = MonitorStore()
    @StateObject private var presentationController = AppPresentationController()

    var body: some Scene {
        MenuBarExtra {
            MonitorPanel(monitor: monitor, presentationController: presentationController)
        } label: {
            Text(monitor.menuTitle)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
            .help("\(monitor.menuQuotaSource.label) 剩余额度")
            .onAppear { presentationController.openOnLaunch(monitor: monitor) }
        }
        .menuBarExtraStyle(.window)
    }
}
