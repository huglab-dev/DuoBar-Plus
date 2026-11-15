import AppKit
import SwiftUI

extension View {
    /// DuoBar+: shows an AppKit menu on right-click, built when the click
    /// happens. Unlike `.contextMenu`, the open menu is not rebuilt when the
    /// view redraws, so rows that update every second keep a steady menu.
    func rightClickMenu(_ make: @escaping () -> NSMenu?) -> some View {
        background(RightClickMenuView(make: make))
    }
}

private struct RightClickMenuView: NSViewRepresentable {
    let make: () -> NSMenu?

    func makeNSView(context: Context) -> RightClickCatcher {
        let view = RightClickCatcher()
        view.make = make
        return view
    }

    func updateNSView(_ view: RightClickCatcher, context: Context) {
        view.make = make
    }
}

/// Watches right-clicks in its window with a local event monitor, so it sits
/// behind the row's buttons without taking their left clicks.
final class RightClickCatcher: NSView {
    var make: (() -> NSMenu?)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self, let window = self.window, event.window === window else { return event }
            let point = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(point), let menu = self.make?() else { return event }
            menu.popUp(positioning: nil, at: point, in: self)
            return nil
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// A plain menu of titled actions, for `.rightClickMenu`.
@MainActor
final class SimpleContextMenu: NSObject {
    struct Row {
        var title: String
        var isChecked = false
        var action: () -> Void
    }

    private var actions: [() -> Void] = []

    static func make(_ rows: [Row]) -> NSMenu {
        let owner = SimpleContextMenu()
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.retainTarget(owner)
        for (index, row) in rows.enumerated() {
            let item = NSMenuItem(title: row.title, action: #selector(choose(_:)), keyEquivalent: "")
            item.target = owner
            item.tag = index
            item.state = row.isChecked ? .on : .off
            owner.actions.append(row.action)
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard actions.indices.contains(sender.tag) else { return }
        actions[sender.tag]()
    }
}
