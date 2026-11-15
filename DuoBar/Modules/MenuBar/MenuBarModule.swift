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
    /// Delay before reading an item's menu, so a closing popover is gone first.
    private let pressDelay: TimeInterval
    private let openApplication: @MainActor (MenuBarItemSnapshot) -> Void
    /// Bumped whenever scans should be discarded, for example after closing.
    private var generation = 0
    /// The menu bar button's scan: a prefetched result, and clicks waiting
    /// for a scan in progress.
    private var cachedOverview: (overview: MenuBarOverview, date: Date)?
    private var overviewWaiters: [@MainActor (MenuBarOverview) -> Void] = []
    private var isScanningOverview = false
    private let overviewMaxAge: TimeInterval
    private let now: () -> Date

    init(
        reader: any MenuBarItemsReading = AXMenuBarItemsReader(),
        geometry: @escaping @MainActor () -> NotchGeometry? = { NotchGeometry.current() },
        candidates: @escaping @MainActor () -> [MenuBarAppCandidate] = MenuBarModule.runningApps,
        presentMenu: @escaping @MainActor ([MenuBarMenuEntry], @escaping ([Int]) -> Void) -> Void = MenuBarProxyMenu.present,
        pressDelay: TimeInterval = 0.15,
        openApplication: @escaping @MainActor (MenuBarItemSnapshot) -> Void = MenuBarModule.reopenApplication,
        overviewMaxAge: TimeInterval = 3,
        now: @escaping () -> Date = Date.init
    ) {
        self.overviewMaxAge = overviewMaxAge
        self.now = now
        self.presentMenu = presentMenu
        self.reader = reader
        self.geometry = geometry
        self.candidates = candidates
        self.pressDelay = pressDelay
        self.openApplication = openApplication
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
        cachedOverview = nil
        hiddenItems = []
        state = .checking
    }

    /// Shows the system prompt for Accessibility access.
    func requestAccess() {
        reader.requestAccess()
    }

    /// Shows the item's menu at the pointer when the app exposes it.
    /// Otherwise opens the app.
    func open(_ item: MenuBarItemSnapshot) {
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
            // No readable menu: its own menu would open where the item is,
            // often off screen, so the app is opened instead.
            DispatchQueue.main.async {
                self?.openApplication(item)
            }
        }
    }

    /// Scans and reads each hidden item's menu, for the menu bar button.
    /// Uses a prefetch from the last few seconds, or waits for one in progress.
    func loadOverview(completion: @escaping @MainActor (MenuBarOverview) -> Void) {
        guard geometry() != nil else {
            state = .noNotch
            completion(MenuBarOverview(state: .noNotch, entries: []))
            return
        }
        guard reader.isTrusted() else {
            state = .needsAccess
            completion(MenuBarOverview(state: .needsAccess, entries: []))
            return
        }
        // A prefetch from moments ago is used once; the next click scans again.
        if let cached = cachedOverview, now().timeIntervalSince(cached.date) <= overviewMaxAge {
            cachedOverview = nil
            completion(cached.overview)
            return
        }
        cachedOverview = nil
        overviewWaiters.append(completion)
        startOverviewScan()
    }

    /// Starts the button's scan early, when the pointer reaches the button,
    /// so a click shortly after shows the list at once. Not a timer: it runs
    /// only on that pointer event.
    func prefetchOverview() {
        guard geometry() != nil, reader.isTrusted() else { return }
        if let cached = cachedOverview, now().timeIntervalSince(cached.date) <= overviewMaxAge { return }
        startOverviewScan()
    }

    private func startOverviewScan() {
        guard !isScanningOverview, let geometry = geometry() else { return }
        isScanningOverview = true
        let reader = reader
        let apps = candidates()
        queue.async { [weak self] in
            #if DEBUG
            let started = Date()
            #endif
            let hidden = geometry.hiddenItems(reader.items(of: apps))
            var menus = [[MenuBarMenuEntry]?](repeating: nil, count: hidden.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: hidden.count) { index in
                let menu = reader.menu(of: hidden[index])
                lock.withLock { menus[index] = menu }
            }
            #if DEBUG
            NSLog("[DuoBar+ MenuBar] scan apps=%d hidden=%d took %.0f ms", apps.count, hidden.count, Date().timeIntervalSince(started) * 1000)
            #endif
            let overview = MenuBarOverview(
                state: .ready,
                entries: zip(hidden, menus).map { MenuBarOverview.Entry(item: $0, menu: $1) }
            )
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanningOverview = false
                self.hiddenItems = hidden
                self.state = .ready
                let waiters = self.overviewWaiters
                self.overviewWaiters = []
                if waiters.isEmpty {
                    self.cachedOverview = (overview, self.now())
                } else {
                    waiters.forEach { $0(overview) }
                }
            }
        }
    }

    /// Chooses a row in the item's menu without opening it.
    func pick(_ item: MenuBarItemSnapshot, path: [Int]) {
        let reader = reader
        queue.async { _ = reader.pick(item, path: path) }
    }

    /// Opens the app, for items whose menu cannot be read.
    func openApp(_ item: MenuBarItemSnapshot) {
        openApplication(item)
    }

    /// Opens the app as a click in the Dock or Finder would. For a running
    /// app that sends "reopen", which shows its main or settings window.
    static func reopenApplication(_ item: MenuBarItemSnapshot) {
        let running = NSRunningApplication(processIdentifier: item.pid)
        let url = running?.bundleURL
            ?? item.bundleIdentifier.flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        guard let url else {
            running?.activate()
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { running?.activate() }
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

    /// Background-only processes cannot show menu bar items, and many of them
    /// never answer Accessibility, which slows the scan down.
    nonisolated static func mayOwnMenuBarItems(_ policy: NSApplication.ActivationPolicy) -> Bool {
        policy != .prohibited
    }

    /// Running apps that may own menu bar items, without DuoBar+ itself.
    static func runningApps() -> [MenuBarAppCandidate] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.processIdentifier != ownPID && mayOwnMenuBarItems($0.activationPolicy) }
            .map {
                MenuBarAppCandidate(
                    pid: $0.processIdentifier,
                    bundleIdentifier: $0.bundleIdentifier,
                    name: $0.localizedName ?? $0.bundleIdentifier ?? localized("Unknown App")
                )
            }
    }
}
