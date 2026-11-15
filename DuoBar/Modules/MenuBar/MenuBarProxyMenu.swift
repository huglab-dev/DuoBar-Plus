import AppKit

/// Lets a menu keep the objects that receive its actions alive.
private var associatedTargetKey = 0

extension NSMenu {
    func retainTarget(_ target: AnyObject) {
        var targets = objc_getAssociatedObject(self, &associatedTargetKey) as? [AnyObject] ?? []
        targets.append(target)
        objc_setAssociatedObject(self, &associatedTargetKey, targets, .OBJC_ASSOCIATION_RETAIN)
    }
}

/// Shows another app's menu, read through Accessibility, as DuoBar+'s own
/// menu at the mouse pointer. Choosing a row reports its path; the module
/// then presses the matching row in the real app.
///
/// Needed because a hidden item's own menu opens where the item is, which is
/// under the notch or off screen.
@MainActor
final class MenuBarProxyMenu: NSObject {
    private let onPick: ([Int]) -> Void

    init(onPick: @escaping ([Int]) -> Void) {
        self.onPick = onPick
    }

    static func present(_ entries: [MenuBarMenuEntry], onPick: @escaping ([Int]) -> Void) {
        let proxy = MenuBarProxyMenu(onPick: onPick)
        let menu = proxy.makeMenu(entries, path: [])
        // Blocks until the menu closes, which also keeps `proxy` alive.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    /// The menu `present` shows. It keeps its target alive, so it can be
    /// stored or nested in another menu.
    static func makeMenu(_ entries: [MenuBarMenuEntry], onPick: @escaping ([Int]) -> Void) -> NSMenu {
        let proxy = MenuBarProxyMenu(onPick: onPick)
        let menu = proxy.makeMenu(entries, path: [])
        menu.retainTarget(proxy)
        return menu
    }

    private func makeMenu(_ entries: [MenuBarMenuEntry], path: [Int]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            if entry.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let item = NSMenuItem(title: entry.title, action: nil, keyEquivalent: "")
            item.isEnabled = entry.isEnabled
            item.state = entry.isChecked ? .on : .off
            let entryPath = path + [entry.index]
            if entry.children.isEmpty {
                item.target = self
                item.action = #selector(choose(_:))
                item.representedObject = entryPath
            } else {
                item.submenu = makeMenu(entry.children, path: entryPath)
            }
            menu.addItem(item)
        }
        return menu
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? [Int] else { return }
        onPick(path)
    }
}
