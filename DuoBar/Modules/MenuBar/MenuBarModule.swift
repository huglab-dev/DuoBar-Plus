import AppKit
import Foundation

/// Menu Bar module. Lists other apps' menu bar items that macOS hid behind
/// the camera notch, and opens their menus on click.
///
/// Scans only when the popover or the detail view opens: no timers and no
/// observers. Accessibility access is checked without a prompt; the prompt
/// appears only when the user asks for it in the detail view.
/// What the menu bar button's menu shows.
struct MenuBarOverview: Equatable {
    struct Entry: Equatable {
        let item: MenuBarItemSnapshot
        /// The item's menu, or nil when the app does not expose it.
        let menu: [MenuBarMenuEntry]?
    }

    let state: MenuBarModule.State
    let entries: [Entry]
}

@MainActor
final class MenuBarModule: ObservableObject, StatusModule {
    enum State: Equatable {
        /// The first scan has not finished.
        case checking
        case needsAccess
        case noNotch
        case ready
    }

    let id: ModuleID = .menuBar

    @Published private(set) var state: State = .checking
    @Published private(set) var hiddenItems: [MenuBarItemSnapshot] = []

    private let reader: any MenuBarItemsReading
    private let geometry: @MainActor () -> NotchGeometry?
    private let candidates: @MainActor () -> [MenuBarAppCandidate]
    private let presentMenu: @MainActor ([MenuBarMenuEntry], @escaping ([Int]) -> Void) -> Void
    private let queue = DispatchQueue(label: "DuoBarPlus.MenuBarModule", qos: .userInitiated)
    /// Delay before pressing an item, so the popover is gone when its menu opens.
    private let pressDelay: TimeInterval
    /// Bumped whenever scans should be discarded, for example after closing.
    private var generation = 0

    init(
        reader: any MenuBarItemsReading = AXMenuBarItemsReader(),
        geometry: @escaping @MainActor () -> NotchGeometry? = { NotchGeometry.current() },
        candidates: @escaping @MainActor () -> [MenuBarAppCandidate] = MenuBarModule.runningApps,
        presentMenu: @escaping @MainActor ([MenuBarMenuEntry], @escaping ([Int]) -> Void) -> Void = MenuBarProxyMenu.present,
        pressDelay: TimeInterval = 0.15
    ) {
        self.presentMenu = presentMenu
        self.reader = reader
        self.geometry = geometry
        self.candidates = candidates
        self.pressDelay = pressDelay
    }

    func popoverDidOpen() {
        refresh()
    }

    func popoverDidClose() {
        generation += 1
    }

    func detailDidOpen() {
        refresh()
    }

    func deactivate() {
        generation += 1
        hiddenItems = []
        state = .checking
    }

    /// Shows the system prompt for Accessibility access.
    func requestAccess() {
        reader.requestAccess()
    }

    /// Shows the item's menu at the pointer when the app exposes it. Otherwise
    /// presses the item (its menu then opens where the item is), and brings
    /// the app forward when even that fails.
    func open(_ item: MenuBarItemSnapshot, click: MenuBarItemClick = .primary) {
        let reader = reader
        queue.asyncAfter(deadline: .now() + pressDelay) { [weak self] in
            if let entries = reader.menu(of: item) {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.presentMenu(entries) { [weak self] path in
                        self?.pick(item, path: path)
                    }
                }
                return
            }
            guard !reader.press(item, click: click) else { return }
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: item.pid)?.activate()
            }
        }
    }

    /// Scans now and reads each hidden item's menu, for the menu bar button.
    /// Runs only when the user clicks that button.
    func loadOverview(completion: @escaping @MainActor (MenuBarOverview) -> Void) {
        generation += 1
        guard let geometry = geometry() else {
            state = .noNotch
            completion(MenuBarOverview(state: .noNotch, entries: []))
            return
        }
        guard reader.isTrusted() else {
            state = .needsAccess
            completion(MenuBarOverview(state: .needsAccess, entries: []))
            return
        }
        let generation = generation
        let reader = reader
        let apps = candidates()
        queue.async { [weak self] in
            let hidden = geometry.hiddenItems(reader.items(of: apps))
            var menus = [[MenuBarMenuEntry]?](repeating: nil, count: hidden.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: hidden.count) { index in
                let menu = reader.menu(of: hidden[index])
                lock.withLock { menus[index] = menu }
            }
            let overview = MenuBarOverview(
                state: .ready,
                entries: zip(hidden, menus).map { MenuBarOverview.Entry(item: $0, menu: $1) }
            )
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.hiddenItems = hidden
                self.state = .ready
                completion(overview)
            }
        }
    }

    /// Chooses a row in the item's menu without opening it.
    func pick(_ item: MenuBarItemSnapshot, path: [Int]) {
        let reader = reader
        queue.async { _ = reader.pick(item, path: path) }
    }

    /// Presses the item itself, for apps whose menu cannot be read.
    func press(_ item: MenuBarItemSnapshot) {
        let reader = reader
        queue.async {
            guard !reader.press(item, click: .secondary) else { return }
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: item.pid)?.activate()
            }
        }
    }

    func refresh() {
        generation += 1
        guard let geometry = geometry() else {
            hiddenItems = []
            state = .noNotch
            return
        }
        guard reader.isTrusted() else {
            hiddenItems = []
            state = .needsAccess
            return
        }
        let generation = generation
        let reader = reader
        let apps = candidates()
        queue.async { [weak self] in
            let hidden = geometry.hiddenItems(reader.items(of: apps))
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.hiddenItems = hidden
                self.state = .ready
            }
        }
    }

    /// Running apps that may own menu bar items, without DuoBar+ itself.
    static func runningApps() -> [MenuBarAppCandidate] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID }
            .map {
                MenuBarAppCandidate(
                    pid: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.localizedName ?? $0.bundleIdentifier ?? localized("Unknown App")
                )
            }
    }
}
