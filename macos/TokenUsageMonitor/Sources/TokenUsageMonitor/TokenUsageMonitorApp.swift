import AppKit
import Combine
import SwiftUI

@main
enum TokenUsageMonitorApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = StatusItemController()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class StatusItemController: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let monitor = MonitorStore()
    private let presentation = AppPresentationController()
    private var statusItem: NSStatusItem?
    private var observation: AnyCancellable?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        guard let button = item.button else { return }
        button.imagePosition = .imageLeading
        button.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        button.target = self
        button.action = #selector(statusItemClicked(_:))
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        // Read the final values after a batch of @Published changes. Redraw only
        // if the displayed quota or its source actually changed.
        observation = monitor.objectWillChange
            .debounce(for: .zero, scheduler: RunLoop.main)
            .prepend(())
            .map { [monitor] in StatusReading(monitor: monitor) }
            .removeDuplicates()
            .sink { [weak button] reading in
                button?.title = reading.title
                button?.image = reading.ring
                button?.toolTip = reading.label
                button?.setAccessibilityLabel("\(reading.label) \(reading.title)")
            }
        presentation.openOnLaunch(monitor: monitor)
    }

    private func installMainMenu() {
        let menu = NSMenu()
        func submenu(_ title: String) -> NSMenu {
            let child = NSMenu(title: title)
            menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = child
            return child
        }
        let appMenu = submenu("Token监测")
        appMenu.addItem(withTitle: "退出 Token监测", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = submenu("编辑")
        for (title, action, key) in [("撤销", "undo:", "z"), ("重做", "redo:", "Z"),
                                    ("剪切", "cut:", "x"), ("拷贝", "copy:", "c"),
                                    ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        let window = submenu("窗口")
        window.addItem(withTitle: "关闭", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = window
        NSApp.mainMenu = menu
    }

    @objc private func statusItemClicked(_ button: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || (event?.type == .leftMouseUp && event?.modifierFlags.contains(.control) == true) {
            popover?.performClose(nil)
            let menu = NSMenu()
            let quit = menu.addItem(withTitle: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            quit.target = NSApp
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.minY - 2), in: button)
            return
        }

        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let panel = NSPopover()
        panel.behavior = .transient
        panel.delegate = self
        panel.contentViewController = NSHostingController(rootView:
            MonitorPanel(monitor: monitor, presentationController: presentation)
        )
        panel.contentSize = NSSize(width: 420, height: 640)
        popover = panel
        panel.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    func popoverDidClose(_ notification: Notification) {
        if let closed = notification.object as? NSPopover, closed === popover {
            popover = nil
        }
    }
}

private struct StatusReading: Equatable {
    let percent: Double?
    let title: String
    let label: String

    init(monitor: MonitorStore) {
        percent = monitor.menuBarRemainingPercent
        title = monitor.menuTitle
        label = "\(monitor.menuQuotaLabel) 剩余额度"
    }

    var ring: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let bounds = NSRect(x: 1, y: 1, width: 16, height: 16)
            NSColor.black.withAlphaComponent(0.24).setFill()
            NSBezierPath(ovalIn: bounds).fill()
            if let percent, percent > 0 {
                let arc = NSBezierPath()
                arc.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 8,
                              startAngle: 90, endAngle: 90 - 3.6 * min(100, percent), clockwise: true)
                arc.lineWidth = 2
                arc.lineCapStyle = .round
                NSColor.black.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
