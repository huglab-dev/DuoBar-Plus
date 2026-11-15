import AppKit

/// The menu under the menu bar button: one row per hidden item. A row whose
/// app exposes its menu opens it as a submenu; other rows press the item.
@MainActor
final class MenuBarOverviewMenu: NSObject {
    struct Actions {
        var pick: (MenuBarItemSnapshot, [Int]) -> Void
        var press: (MenuBarItemSnapshot) -> Void
        var allowAccess: () -> Void
        var openSettings: () -> Void
    }

    private let actions: Actions
    private var pressTargets: [ObjectIdentifier: MenuBarItemSnapshot] = [:]

    private init(actions: Actions) {
        self.actions = actions
    }

    static func make(_ overview: MenuBarOverview, actions: Actions) -> NSMenu {
        let owner = MenuBarOverviewMenu(actions: actions)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.retainTarget(owner)

        switch overview.state {
        case .needsAccess:
            menu.addItem(owner.actionItem(localized("Allow Accessibility Access…"), #selector(allowAccess)))
        case .noNotch:
            menu.addItem(disabledItem(localized("No notch on this display")))
        case .checking, .ready:
            if overview.entries.isEmpty {
                menu.addItem(disabledItem(localized("No hidden menu bar items")))
            }
            for entry in overview.entries {
                menu.addItem(owner.row(for: entry))
            }
        }

        menu.addItem(.separator())
        menu.addItem(owner.actionItem(localized("Menu Bar Items Settings…"), #selector(openSettings)))
        return menu
    }

    private func row(for entry: MenuBarOverview.Entry) -> NSMenuItem {
        let item = entry.item
        // Only the app name keeps the menu narrow; the item's own title is a tooltip.
        let row = NSMenuItem(title: item.appName, action: nil, keyEquivalent: "")
        row.toolTip = item.title
        row.image = Self.icon(for: item)
        if let menu = entry.menu, !menu.isEmpty {
            row.submenu = MenuBarProxyMenu.makeMenu(menu) { [actions] path in
                actions.pick(item, path)
            }
        } else {
            row.target = self
            row.action = #selector(press(_:))
            pressTargets[ObjectIdentifier(row)] = item
        }
        return row
    }

    private func actionItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private static func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func icon(for item: MenuBarItemSnapshot) -> NSImage? {
        guard let icon = NSRunningApplication(processIdentifier: item.pid)?.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @objc private func press(_ sender: NSMenuItem) {
        guard let item = pressTargets[ObjectIdentifier(sender)] else { return }
        actions.press(item)
    }

    @objc private func allowAccess() {
        actions.allowAccess()
    }

    @objc private func openSettings() {
        actions.openSettings()
    }
}
