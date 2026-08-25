import AppKit
import SwiftUI

@MainActor
final class AppPresentationController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isQuotaBadgePinned: Bool

    private enum Keys {
        static let quotaBadgePinned = "presentation.quotaBadgePinned"
        static let mainWindowFrame = "TokenMonitor.MainWindow"
        static let quotaBadgeFrame = "TokenMonitor.QuotaBadge"
    }

    private let defaults = UserDefaults.standard
    private var mainWindow: NSWindow?
    private var quotaBadge: NSPanel?
    private var didOpenOnLaunch = false

    override init() {
        isQuotaBadgePinned = UserDefaults.standard.bool(forKey: Keys.quotaBadgePinned)
        super.init()
    }

    func openOnLaunch(monitor: MonitorStore) {
        guard !didOpenOnLaunch else { return }
        didOpenOnLaunch = true
        DispatchQueue.main.async { [weak self, weak monitor] in
            guard let self, let monitor else { return }
            self.showMainWindow(monitor: monitor)
            if self.isQuotaBadgePinned { self.showQuotaBadge(monitor: monitor) }
        }
    }

    func toggleQuotaBadge(monitor: MonitorStore) {
        isQuotaBadgePinned.toggle()
        defaults.set(isQuotaBadgePinned, forKey: Keys.quotaBadgePinned)
        if isQuotaBadgePinned {
            showQuotaBadge(monitor: monitor)
        } else {
            hideQuotaBadge()
        }
    }

    private func showMainWindow(monitor: MonitorStore) {
        if let mainWindow {
            mainWindow.makeKeyAndOrderFront(nil)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Token监测"
        window.minSize = NSSize(width: 390, height: 540)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(
            rootView: MonitorPanel(monitor: monitor, presentationController: self)
        )
        window.setFrameAutosaveName(Keys.mainWindowFrame)
        if !window.setFrameUsingName(Keys.mainWindowFrame) { window.center() }

        mainWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func showQuotaBadge(monitor: MonitorStore) {
        if let quotaBadge {
            quotaBadge.orderFrontRegardless()
            return
        }

        let badge = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 128, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        badge.level = .statusBar
        badge.isFloatingPanel = true
        badge.hidesOnDeactivate = false
        badge.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        badge.isOpaque = false
        badge.backgroundColor = .clear
        badge.hasShadow = true
        badge.isMovableByWindowBackground = true
        badge.isReleasedWhenClosed = false
        badge.contentView = NSHostingView(rootView: QuotaBadgeView(monitor: monitor))
        badge.setFrameAutosaveName(Keys.quotaBadgeFrame)
        if !badge.setFrameUsingName(Keys.quotaBadgeFrame), let screen = NSScreen.main {
            let frame = screen.visibleFrame
            badge.setFrameOrigin(NSPoint(x: frame.maxX - 140, y: frame.maxY - 50))
        }

        quotaBadge = badge
        badge.orderFrontRegardless()
    }

    private func hideQuotaBadge() {
        guard let quotaBadge else { return }
        self.quotaBadge = nil
        quotaBadge.contentView = nil
        quotaBadge.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === mainWindow else { return }
        window.contentView = nil
        mainWindow = nil
    }
}

private struct QuotaBadgeView: View {
    @ObservedObject var monitor: MonitorStore

    var body: some View {
        HStack(spacing: 8) {
            RemainingRing(
                remainingPercent: monitor.menuBarRemainingPercent,
                size: 27,
                lineWidth: 2.4,
                fontSize: 7.5
            )
            VStack(alignment: .leading, spacing: 0) {
                Text(monitor.menuTitle)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(monitor.menuQuotaSource.label)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 128, height: 42)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color.primary.opacity(0.16), lineWidth: 0.5))
        .contentShape(Capsule())
        .help("拖动调整位置；在 Token监测中点击图钉可隐藏")
    }
}
