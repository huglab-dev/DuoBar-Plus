#if DEBUG
import AppKit
import Foundation

extension PopoverPanel {
    /// macOS hides status items that do not fit in a crowded menu bar (for
    /// example behind the camera housing), and a hidden item has no window to
    /// anchor to. With debug control enabled the panel then opens at the top
    /// right of the main screen, so scripted checks still work.
    func presentForDebugWithoutStatusItem(size: NSSize) {
        guard DebugPopoverControl.isEnabled, let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setContentSize(size)
        setFrameOrigin(NSPoint(x: visible.maxX - size.width - 8, y: visible.maxY - size.height - 6))
        makeKeyAndOrderFront(nil)
    }
}

/// Lets scripts open, close and navigate the popover in DEBUG builds, for
/// visual checks and the performance measurements in step 10. Active only when
/// the app is launched with `--debug-popover-control`.
///
/// ```
/// open -a "DuoBar+.app" --args --debug-popover-control
/// # then post com.huglab.duobarplus.debug.popover with userInfo
/// # ["command": "open" | "close" | "back" | "detail:<module id>"]
/// ```
@MainActor
final class DebugPopoverControl {
    static let notification = Notification.Name("com.huglab.duobarplus.debug.popover")

    static var isEnabled: Bool { isEnabledNonisolated }

    nonisolated static var isEnabledNonisolated: Bool {
        ProcessInfo.processInfo.arguments.contains("--debug-popover-control")
    }

    private var observer: NSObjectProtocol?

    init?(menuBarController: MenuBarController, statusStore: SystemStatusStore) {
        guard Self.isEnabled else { return nil }
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Self.notification,
            object: nil,
            queue: .main
        ) { [weak menuBarController, weak statusStore] notification in
            guard let command = notification.userInfo?["command"] as? String else { return }
            Task { @MainActor in
                guard let menuBarController, let statusStore else { return }
                Self.perform(command, menuBarController: menuBarController, router: statusStore.popoverRouter)
            }
        }
    }

    private static func perform(_ command: String, menuBarController: MenuBarController, router: PopoverRouter) {
        switch command {
        case "open":
            menuBarController.setPopoverVisibleForDebug(true)
        case "close":
            menuBarController.setPopoverVisibleForDebug(false)
        case "back":
            router.back()
        case "hover-in":
            menuBarController.simulateHoverForDebug(true)
        case "hover-out":
            menuBarController.simulateHoverForDebug(false)
        default:
            guard command.hasPrefix("detail:"),
                  let id = ModuleID(rawValue: String(command.dropFirst("detail:".count))) else { return }
            router.open(id)
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
#endif
