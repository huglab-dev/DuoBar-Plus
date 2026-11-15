import AppKit
import ApplicationServices

/// One menu bar item (status item) of another app, as Accessibility reports it.
/// `frame` uses Accessibility coordinates (origin at the top left of the
/// primary screen). Only the horizontal position is used, and that axis is the
/// same in AppKit coordinates.
struct MenuBarItemSnapshot: Equatable, Identifiable, Sendable {
    let pid: pid_t
    /// Position among the app's own menu bar items, used to find it again.
    let index: Int
    let bundleIdentifier: String?
    let appName: String
    /// The item's own title or description, when it has one besides the app name.
    let title: String?
    let frame: CGRect

    var id: String { "\(pid)-\(index)" }
}

/// How an item is opened: as with a left click or with a right click.
enum MenuBarItemClick: Equatable, Sendable {
    case primary
    case secondary
}

/// One row of another app's menu, read through Accessibility.
struct MenuBarMenuEntry: Equatable, Sendable {
    /// Position among the menu's Accessibility children, used to press it later.
    let index: Int
    let title: String
    let isEnabled: Bool
    let isChecked: Bool
    let isSeparator: Bool
    let children: [MenuBarMenuEntry]
}

/// An app that may own menu bar items. Captured on the main thread so the
/// reader can run on its own queue.
struct MenuBarAppCandidate: Equatable, Sendable {
    let pid: pid_t
    let bundleIdentifier: String?
    let name: String
}

protocol MenuBarItemsReading: Sendable {
    /// Whether DuoBar+ has Accessibility access. Never shows a prompt.
    func isTrusted() -> Bool
    /// Shows the system prompt that leads to Accessibility settings.
    func requestAccess()
    func items(of apps: [MenuBarAppCandidate]) -> [MenuBarItemSnapshot]
    /// Opens the item's menu, or its right-click menu for `.secondary`.
    /// Blocks while the app responds, so call it off the main thread.
    func press(_ item: MenuBarItemSnapshot, click: MenuBarItemClick) -> Bool
    /// The item's menu, when the app exposes it without opening it.
    func menu(of item: MenuBarItemSnapshot) -> [MenuBarMenuEntry]?
    /// Chooses the entry at `path` in the item's menu.
    func pick(_ item: MenuBarItemSnapshot, path: [Int]) -> Bool
}

/// Reads other apps' menu bar items through their Accessibility extras menu
/// bar (`AXExtrasMenuBar`). Public API; needs Accessibility access, not
/// screen recording.
struct AXMenuBarItemsReader: MenuBarItemsReading {
    /// Helper processes that never answer would otherwise stall the scan.
    private static let messagingTimeout: Float = 0.25

    func isTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    func items(of apps: [MenuBarAppCandidate]) -> [MenuBarItemSnapshot] {
        var results = [[MenuBarItemSnapshot]](repeating: [], count: apps.count)
        let lock = NSLock()
        // Unresponsive helpers each cost the full timeout, so ask in parallel.
        DispatchQueue.concurrentPerform(iterations: apps.count) { index in
            let found = Self.items(of: apps[index])
            lock.lock()
            results[index] = found
            lock.unlock()
        }
        return results.flatMap { $0 }
    }

    /// `AXPress` is the left click and `AXShowMenu` the right click. Each
    /// falls back to the other, so an item with one menu opens either way.
    func press(_ item: MenuBarItemSnapshot, click: MenuBarItemClick) -> Bool {
        guard let element = Self.element(for: item) else { return false }
        let actions = click == .primary
            ? [kAXPressAction, kAXShowMenuAction]
            : [kAXShowMenuAction, kAXPressAction]
        return actions.contains { AXUIElementPerformAction(element, $0 as CFString) == .success }
    }

    /// Apps built on `NSMenu` expose the whole menu without opening it.
    /// Apps that build their menu on click (for example Electron apps) do not.
    func menu(of item: MenuBarItemSnapshot) -> [MenuBarMenuEntry]? {
        guard let element = Self.element(for: item), let menu = Self.menuElement(of: element) else { return nil }
        let entries = Self.entries(of: menu, depth: 0)
        #if DEBUG
        NSLog("[DuoBar+ MenuBar] %@ menu entries=%d", item.appName, entries.count)
        #endif
        return entries.isEmpty ? nil : entries
    }

    /// Presses the menu item at `path` (indices among each menu's children)
    /// without opening the menu.
    func pick(_ item: MenuBarItemSnapshot, path: [Int]) -> Bool {
        guard var current = Self.element(for: item) else { return false }
        for index in path {
            guard let menu = Self.menuElement(of: current) else { return false }
            let children = Self.children(of: menu)
            guard children.indices.contains(index) else { return false }
            current = children[index]
        }
        let result = AXUIElementPerformAction(current, kAXPressAction as CFString)
        #if DEBUG
        NSLog("[DuoBar+ MenuBar] %@ pick %@ result=%d", item.appName, path.description, result.rawValue)
        #endif
        // A menu action that opens a window can outlast the timeout although it ran.
        return result == .success || result == .cannotComplete
    }

    /// Submenus deeper than this are left out.
    private static let maximumMenuDepth = 3

    private static func entries(of menu: AXUIElement, depth: Int) -> [MenuBarMenuEntry] {
        children(of: menu).enumerated().compactMap { index, element in
            guard string(element, kAXRoleAttribute) == kAXMenuItemRole else { return nil }
            let title = string(element, kAXTitleAttribute) ?? ""
            let isEnabled = bool(element, kAXEnabledAttribute) ?? true
            let submenu = depth + 1 < maximumMenuDepth ? menuElement(of: element).map { entries(of: $0, depth: depth + 1) } ?? [] : []
            if title.isEmpty && submenu.isEmpty {
                // Untitled, disabled rows are separators; untitled enabled rows
                // (image-only items) cannot be shown meaningfully.
                return isEnabled ? nil : MenuBarMenuEntry(index: index, title: "", isEnabled: false, isChecked: false, isSeparator: true, children: [])
            }
            let mark = string(element, kAXMenuItemMarkCharAttribute) ?? ""
            return MenuBarMenuEntry(
                index: index, title: title, isEnabled: isEnabled, isChecked: !mark.isEmpty,
                isSeparator: false, children: submenu
            )
        }
    }

    private static func element(for item: MenuBarItemSnapshot) -> AXUIElement? {
        let elements = itemElements(pid: item.pid)
        return elements.indices.contains(item.index) ? elements[item.index] : nil
    }

    private static func menuElement(of element: AXUIElement) -> AXUIElement? {
        children(of: element).first { string($0, kAXRoleAttribute) == kAXMenuRole }
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success else { return [] }
        return children as? [AXUIElement] ?? []
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? Bool
    }

    private static func items(of app: MenuBarAppCandidate) -> [MenuBarItemSnapshot] {
        itemElements(pid: app.pid).enumerated().compactMap { index, element in
            guard let frame = frame(of: element) else { return nil }
            let label = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute]
                .lazy
                .compactMap { string(element, $0) }
                .first { !$0.isEmpty && $0 != app.name }
            return MenuBarItemSnapshot(
                pid: app.pid,
                index: index,
                bundleIdentifier: app.bundleIdentifier,
                appName: app.name,
                title: label,
                frame: frame
            )
        }
    }

    private static func itemElements(pid: pid_t) -> [AXUIElement] {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, messagingTimeout)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(application, kAXExtrasMenuBarAttribute as CFString, &bar) == .success,
              let bar, CFGetTypeID(bar) == AXUIElementGetTypeID()
        else { return [] }
        return children(of: bar as! AXUIElement)
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue, let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue as! AXValue, .cgPoint, &position),
              AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Reports no access and no items. Used when services are not started (tests).
struct InertMenuBarItemsReader: MenuBarItemsReading {
    func isTrusted() -> Bool { false }
    func requestAccess() {}
    func items(of apps: [MenuBarAppCandidate]) -> [MenuBarItemSnapshot] { [] }
    func press(_ item: MenuBarItemSnapshot, click: MenuBarItemClick) -> Bool { false }
    func menu(of item: MenuBarItemSnapshot) -> [MenuBarMenuEntry]? { nil }
    func pick(_ item: MenuBarItemSnapshot, path: [Int]) -> Bool { false }
}
