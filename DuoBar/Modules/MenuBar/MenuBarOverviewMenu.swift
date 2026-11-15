import AppKit

/// The menu under the menu bar button: one row per hidden item. A row whose
/// app exposes its menu opens it as a submenu; other rows open the app.
@MainActor
final class MenuBarOverviewMenu: NSObject {
    struct Actions {
        var pick: (MenuBarItemSnapshot, [Int]) -> Void
        /// Opens the app, for items whose menu cannot be read.
        var openApp: (MenuBarItemSnapshot) -> Void
        var allowAccess: () -> Void
        var openSettings: () -> Void
        /// The below-notch switch, when the built-in display supports it.
        var notch: NotchToggle?
    }

    struct NotchToggle {
        var isBelowNotch: Bool
        var toggle: () -> Void
    }

    private let actions: Actions
    private var appTargets: [ObjectIdentifier: MenuBarItemSnapshot] = [:]

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
            let text = actions.notch?.isBelowNotch == true
                ? localized("Menu bar is below the notch")
                : localized("No notch on this display")
            menu.addItem(disabledItem(text))
        case .checking, .ready:
            if overview.entries.isEmpty {
                menu.addItem(disabledItem(localized("No hidden menu bar items")))
            }
            for entry in overview.entries {
                menu.addItem(owner.row(for: entry))
            }
        }

        menu.addItem(.separator())
        if let notch = actions.notch {
            let item = owner.actionItem(localized("Menu Bar Below Notch"), #selector(toggleNotch))
            item.state = notch.isBelowNotch ? .on : .off
            menu.addItem(item)
        }
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
            row.action = #selector(openApp(_:))
            appTargets[ObjectIdentifier(row)] = item
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

    @objc private func openApp(_ sender: NSMenuItem) {
        guard let item = appTargets[ObjectIdentifier(sender)] else { return }
        actions.openApp(item)
    }

    @objc private func allowAccess() {
        actions.allowAccess()
    }

    @objc private func toggleNotch() {
        actions.notch?.toggle()
    }

    @objc private func openSettings() {
        actions.openSettings()
    }
}

