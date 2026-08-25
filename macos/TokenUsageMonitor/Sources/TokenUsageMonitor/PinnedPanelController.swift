import AppKit
import SwiftUI

@MainActor
final class PinnedPanelController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var isPinned = false

    private var panel: NSPanel?
    private var didOpenOnLaunch = false

    func openOnLaunch(monitor: MonitorStore) {
        guard !didOpenOnLaunch else { return }
        didOpenOnLaunch = true
        DispatchQueue.main.async { [weak self, weak monitor] in
            guard let self, let monitor else { return }
            self.showPanel(monitor: monitor, pinned: false)
        }
    }

    func toggle(monitor: MonitorStore) {
        if let panel {
            isPinned.toggle()
            configureLevel(for: panel)
            panel.makeKeyAndOrderFront(nil)
            return
        }

        showPanel(monitor: monitor, pinned: true)
    }

    private func showPanel(monitor: MonitorStore, pinned: Bool) {
        if let panel {
            panel.makeKeyAndOrderFront(nil)
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 370, height: 540),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Token监测"
        panel.titleVisibility = .hidden
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: MonitorPanel(monitor: monitor, pinController: self)
        )

        self.panel = panel
        isPinned = pinned
        configureLevel(for: panel)
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func configureLevel(for panel: NSPanel) {
        panel.level = isPinned ? .floating : .normal
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === panel else { return }
        window.contentView = nil
        panel = nil
        isPinned = false
    }
}
