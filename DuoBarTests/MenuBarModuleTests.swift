import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class MenuBarModuleTests: XCTestCase {
    /// A 1800 pt display with 790 pt free on each side of the notch, as on a 14" MacBook Pro.
    static let geometry = NotchGeometry(screenSpan: 0...1800, visibleMinX: 1010)

    static func item(_ name: String, x: CGFloat, width: CGFloat = 30, pid: pid_t = 900, index: Int = 0, title: String? = nil) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            pid: pid, index: index, bundleIdentifier: "com.example.\(name)", appName: name,
            title: title, frame: CGRect(x: x, y: 0, width: width, height: 37)
        )
    }

    // MARK: Geometry

    func testItemsRightOfTheNotchAreVisible() {
        XCTAssertFalse(Self.geometry.isHidden(CGRect(x: 1010, y: 0, width: 30, height: 37)))
        XCTAssertFalse(Self.geometry.isHidden(CGRect(x: 1770, y: 0, width: 30, height: 37)))
    }

    func testItemsUnderOrLeftOfTheNotchAreHidden() {
        XCTAssertTrue(Self.geometry.isHidden(CGRect(x: 900, y: 0, width: 30, height: 37)), "under the notch")
        XCTAssertTrue(Self.geometry.isHidden(CGRect(x: 995, y: 0, width: 30, height: 37)), "partly under the notch")
        XCTAssertTrue(Self.geometry.isHidden(CGRect(x: 200, y: 0, width: 30, height: 37)), "left of the notch")
    }

    func testItemsOutsideEveryDisplayAreHidden() {
        XCTAssertTrue(Self.geometry.isHidden(CGRect(x: -500, y: 0, width: 30, height: 37)))
        XCTAssertTrue(Self.geometry.isHidden(CGRect(x: 5000, y: 0, width: 30, height: 37)))
    }

    func testItemsOnAnotherDisplayAreVisible() {
        var geometry = Self.geometry
        geometry.otherScreenSpans = [1800...4360]
        XCTAssertFalse(geometry.isHidden(CGRect(x: 3000, y: 0, width: 30, height: 37)))
        XCTAssertTrue(geometry.isHidden(CGRect(x: 600, y: 0, width: 30, height: 37)))
    }

    func testHiddenItemsSkipsSpacersAndSortsNearestToTheNotchFirst() {
        let items = [
            Self.item("Far", x: 100),
            Self.item("Visible", x: 1500),
            Self.item("Near", x: 950),
            Self.item("Spacer", x: -9000, width: 10_000),
            Self.item("Empty", x: 500, width: 0),
        ]
        XCTAssertEqual(Self.geometry.hiddenItems(items).map(\.appName), ["Near", "Far"])
    }

    // MARK: Module

    func testNoNotchSkipsTheReader() {
        let reader = FakeMenuBarItemsReader(trusted: true, items: [Self.item("A", x: 100)])
        let module = MenuBarModule(reader: reader, geometry: { nil }, candidates: { [] })
        module.popoverDidOpen()
        XCTAssertEqual(module.state, .noNotch)
        XCTAssertEqual(reader.scanCount, 0)
    }

    func testWithoutAccessNothingIsScannedOrPrompted() {
        let reader = FakeMenuBarItemsReader(trusted: false, items: [Self.item("A", x: 100)])
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] })
        module.popoverDidOpen()
        module.detailDidOpen()
        XCTAssertEqual(module.state, .needsAccess)
        XCTAssertEqual(reader.scanCount, 0)
        XCTAssertEqual(reader.accessRequests, 0, "the prompt only appears when the user asks")
        module.requestAccess()
        XCTAssertEqual(reader.accessRequests, 1)
    }

    func testScanPublishesHiddenItemsAndLeavesNoWork() {
        let reader = FakeMenuBarItemsReader(trusted: true, items: [Self.item("A", x: 100), Self.item("B", x: 1600)])
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] })
        XCTAssertEqual(reader.scanCount, 0, "nothing runs before the popover opens")
        module.popoverDidOpen()
        waitUntil { module.state == .ready }
        XCTAssertEqual(module.hiddenItems.map(\.appName), ["A"])
        module.popoverDidClose()
        XCTAssertEqual(module.activeWork, [])
    }

    func testScanFinishingAfterCloseIsDiscarded() {
        let reader = FakeMenuBarItemsReader(trusted: true, items: [Self.item("A", x: 100)])
        reader.delay = 0.2
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] })
        module.popoverDidOpen()
        module.popoverDidClose()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(module.state, .checking)
        XCTAssertTrue(module.hiddenItems.isEmpty)
    }

    func testItemWithoutMenuOpensTheApp() {
        let reader = FakeMenuBarItemsReader(trusted: true, items: [])
        var opened: [MenuBarItemSnapshot] = []
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] }, pressDelay: 0,
                                   openApplication: { opened.append($0) })
        let item = Self.item("A", x: -3621)
        module.open(item)
        module.open(item)
        // No menu exposed (BetterDisplay or an Electron app), so the app opens.
        waitUntil { opened.count == 2 }
        XCTAssertEqual(opened, [item, item])
        module.openApp(item)
        XCTAssertEqual(opened.count, 3)
    }

    func testExposedMenuIsShownAndThePickIsForwarded() {
        let entries = [
            MenuBarMenuEntry(index: 0, title: "Buttons", isEnabled: true, isChecked: false, isSeparator: false, children: []),
            MenuBarMenuEntry(index: 1, title: "", isEnabled: false, isChecked: false, isSeparator: true, children: []),
            MenuBarMenuEntry(index: 2, title: "Open", isEnabled: true, isChecked: false, isSeparator: false, children: []),
        ]
        let reader = FakeMenuBarItemsReader(trusted: true, items: [])
        reader.menu = entries
        var shown: [MenuBarMenuEntry]?
        let module = MenuBarModule(
            reader: reader, geometry: { Self.geometry }, candidates: { [] },
            presentMenu: { menu, onPick in
                shown = menu
                onPick([2])
            },
            pressDelay: 0,
            openApplication: { _ in XCTFail("an app with a menu shows the menu, not the app") }
        )
        let item = Self.item("A", x: -3900)
        module.open(item)
        waitUntil { !reader.picked.isEmpty }
        XCTAssertEqual(shown, entries)
        XCTAssertEqual(reader.picked.map(\.1), [[2]])
    }

    func testProxyMenuMirrorsEntriesAndPaths() throws {
        let entries = [
            MenuBarMenuEntry(index: 0, title: "Mode", isEnabled: true, isChecked: false, isSeparator: false, children: [
                MenuBarMenuEntry(index: 3, title: "Fast", isEnabled: true, isChecked: true, isSeparator: false, children: []),
            ]),
            MenuBarMenuEntry(index: 1, title: "", isEnabled: false, isChecked: false, isSeparator: true, children: []),
            MenuBarMenuEntry(index: 2, title: "Quit", isEnabled: false, isChecked: false, isSeparator: false, children: []),
        ]
        var picked: [Int]?
        let menu = MenuBarProxyMenu.makeMenu(entries) { picked = $0 }
        XCTAssertEqual(menu.items.map(\.title), ["Mode", "", "Quit"])
        XCTAssertTrue(menu.items[1].isSeparatorItem)
        XCTAssertFalse(menu.items[2].isEnabled)
        let submenu = try XCTUnwrap(menu.items[0].submenu)
        XCTAssertEqual(submenu.items.first?.state, .on)
        submenu.performActionForItem(at: 0)
        XCTAssertEqual(picked, [0, 3])
    }

    // MARK: Menu bar button

    func testButtonWidthAndVisibility() {
        XCTAssertEqual(MenuBarButton.extraWidth(isShown: false), 0)
        XCTAssertEqual(MenuBarButton.extraWidth(isShown: true), MenuBarButton.hitWidth)
        XCTAssertGreaterThan(MenuBarButton.hitWidth, 10)
        XCTAssertFalse(MenuBarButton.isShown(moduleEnabled: false, optionEnabled: true), "a switched-off module is fully off")
        XCTAssertFalse(MenuBarButton.isShown(moduleEnabled: true, optionEnabled: false))
        XCTAssertTrue(MenuBarButton.isShown(moduleEnabled: true, optionEnabled: true))
        XCTAssertFalse(ModuleOption.menuBarButton.defaultValue)
        XCTAssertEqual(ModuleOption.menuBarButton.module, .menuBar)
        XCTAssertTrue(ModuleOption.menuBarRow.defaultValue, "the card stays in the popover unless turned off")
        XCTAssertEqual(ModuleOption.menuBarRow.module, .menuBar)
    }

    func testButtonVisibilityFollowsDefaults() throws {
        let suite = "MenuBarModuleTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(MenuBarButton.isShown(in: defaults))
        defaults.set(true, forKey: ModuleOption.menuBarButton.key)
        XCTAssertFalse(MenuBarButton.isShown(in: defaults))
        defaults.set(true, forKey: PreferenceKeys.moduleEnabled(.menuBar))
        XCTAssertTrue(MenuBarButton.isShown(in: defaults))
    }

    func testOverviewReadsMenusForHiddenItemsOnly() {
        let reader = FakeMenuBarItemsReader(trusted: true, items: [Self.item("A", x: 100), Self.item("B", x: 1600, pid: 901)])
        reader.menu = [MenuBarMenuEntry(index: 0, title: "Quit", isEnabled: true, isChecked: false, isSeparator: false, children: [])]
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] })
        var overview: MenuBarOverview?
        module.loadOverview { overview = $0 }
        waitUntil { overview != nil }
        XCTAssertEqual(overview?.state, .ready)
        XCTAssertEqual(overview?.entries.map(\.item.appName), ["A"])
        XCTAssertEqual(overview?.entries.first?.menu, reader.menu)
        XCTAssertEqual(module.hiddenItems.map(\.appName), ["A"])
    }

    func testOverviewWithoutAccessDoesNotScan() {
        let reader = FakeMenuBarItemsReader(trusted: false, items: [Self.item("A", x: 100)])
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] })
        var overview: MenuBarOverview?
        module.loadOverview { overview = $0 }
        XCTAssertEqual(overview, MenuBarOverview(state: .needsAccess, entries: []))
        XCTAssertEqual(reader.scanCount, 0)
        XCTAssertEqual(reader.accessRequests, 0)
    }

    func testOverviewMenuRowsAndActions() throws {
        let withMenu = Self.item("Mouse", x: 900, pid: 901)
        let withoutMenu = Self.item("Tabby", x: 950, pid: 902, title: "Tray")
        let overview = MenuBarOverview(state: .ready, entries: [
            .init(item: withMenu, menu: [MenuBarMenuEntry(index: 4, title: "Buttons", isEnabled: true, isChecked: false, isSeparator: false, children: [])]),
            .init(item: withoutMenu, menu: nil),
        ])
        var picked: [(MenuBarItemSnapshot, [Int])] = []
        var pressed: [MenuBarItemSnapshot] = []
        var openedSettings = false
        let menu = MenuBarOverviewMenu.make(overview, actions: .init(
            pick: { picked.append(($0, $1)) },
            openApp: { pressed.append($0) },
            allowAccess: {},
            openSettings: { openedSettings = true }
        ))
        XCTAssertEqual(menu.items.map(\.title), ["Mouse", "Tabby", "", localized("Menu Bar Items Settings…")])
        let submenu = try XCTUnwrap(menu.items[0].submenu)
        submenu.performActionForItem(at: 0)
        XCTAssertEqual(picked.map(\.0), [withMenu])
        XCTAssertEqual(picked.map(\.1), [[4]])
        XCTAssertNil(menu.items[1].submenu)
        menu.performActionForItem(at: 1)
        XCTAssertEqual(pressed, [withoutMenu])
        menu.performActionForItem(at: 3)
        XCTAssertTrue(openedSettings)
    }

    func testOverviewMenuNotchToggle() {
        var toggled = 0
        var actions = MenuBarOverviewMenu.Actions(pick: { _, _ in }, openApp: { _ in }, allowAccess: {}, openSettings: {})
        let plain = MenuBarOverviewMenu.make(MenuBarOverview(state: .ready, entries: []), actions: actions)
        XCTAssertFalse(plain.items.map(\.title).contains(localized("Menu Bar Below Notch")))

        actions.notch = .init(isBelowNotch: true, toggle: { toggled += 1 })
        let below = MenuBarOverviewMenu.make(MenuBarOverview(state: .noNotch, entries: []), actions: actions)
        XCTAssertEqual(below.items.first?.title, localized("Menu bar is below the notch"))
        let index = try! XCTUnwrap(below.items.firstIndex { $0.title == localized("Menu Bar Below Notch") })
        XCTAssertEqual(below.items[index].state, .on)
        below.performActionForItem(at: index)
        XCTAssertEqual(toggled, 1)
    }

    func testGlyphMenuRows() {
        XCTAssertEqual(GlyphMenu.rows(moduleEnabled: true, notchAvailable: true, belowNotch: false),
                       [.showHiddenItems, .belowNotch(isChecked: false)])
        XCTAssertEqual(GlyphMenu.rows(moduleEnabled: false, notchAvailable: true, belowNotch: true), [.belowNotch(isChecked: true)])
        XCTAssertEqual(GlyphMenu.rows(moduleEnabled: true, notchAvailable: false, belowNotch: false), [.showHiddenItems])
        XCTAssertEqual(GlyphMenu.rows(moduleEnabled: false, notchAvailable: false, belowNotch: false), [], "the popover opens as before")
    }

    func testOverviewMenuEmptyAndNeedsAccess() {
        let actions = MenuBarOverviewMenu.Actions(pick: { _, _ in }, openApp: { _ in }, allowAccess: {}, openSettings: {})
        let empty = MenuBarOverviewMenu.make(MenuBarOverview(state: .ready, entries: []), actions: actions)
        XCTAssertEqual(empty.items.first?.title, localized("No hidden menu bar items"))
        XCTAssertEqual(empty.items.first?.isEnabled, false)
        let locked = MenuBarOverviewMenu.make(MenuBarOverview(state: .needsAccess, entries: []), actions: actions)
        XCTAssertEqual(locked.items.first?.title, localized("Allow Accessibility Access…"))
    }

    func testBackgroundOnlyAppsAreSkipped() {
        XCTAssertFalse(MenuBarModule.mayOwnMenuBarItems(.prohibited))
        XCTAssertTrue(MenuBarModule.mayOwnMenuBarItems(.accessory))
        XCTAssertTrue(MenuBarModule.mayOwnMenuBarItems(.regular))
    }

    func testFreshPrefetchIsUsedOnce() {
        let reader = FakeMenuBarItemsReader(trusted: true, items: [Self.item("Hidden", x: 993)])
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] })
        module.prefetchOverview()
        waitUntil { module.state == .ready }
        XCTAssertEqual(reader.scanCount, 1)

        var overview: MenuBarOverview?
        module.loadOverview { overview = $0 }
        XCTAssertEqual(overview?.entries.map(\.item.appName), ["Hidden"], "the prefetch answers the click at once")
        XCTAssertEqual(reader.scanCount, 1)

        overview = nil
        module.loadOverview { overview = $0 }
        waitUntil { overview != nil }
        XCTAssertEqual(reader.scanCount, 2, "a used prefetch is not reused")
    }

    func testStalePrefetchScansAgain() {
        let reader = FakeMenuBarItemsReader(trusted: true, items: [])
        var clock = Date(timeIntervalSince1970: 0)
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] }, now: { clock })
        module.prefetchOverview()
        waitUntil { module.state == .ready }
        clock += 10
        var overview: MenuBarOverview?
        module.loadOverview { overview = $0 }
        waitUntil { overview != nil }
        XCTAssertEqual(reader.scanCount, 2)
    }

    func testClickDuringPrefetchWaitsForIt() {
        let reader = FakeMenuBarItemsReader(trusted: true, items: [Self.item("Hidden", x: 993)])
        reader.delay = 0.2
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] })
        module.prefetchOverview()
        module.prefetchOverview()
        var overview: MenuBarOverview?
        module.loadOverview { overview = $0 }
        waitUntil { overview != nil }
        XCTAssertEqual(reader.scanCount, 1)
        XCTAssertEqual(overview?.entries.count, 1)
    }

    func testRunningAppsExcludeDuoBarItself() {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        XCTAssertFalse(MenuBarModule.runningApps().contains { $0.pid == ownPID })
    }

    func testSummaryText() {
        XCTAssertEqual(MenuBarText.summary(state: .ready, hiddenCount: 0), localized("All items are visible"))
        XCTAssertEqual(MenuBarText.summary(state: .ready, hiddenCount: 1), localized("1 item hidden by the notch"))
        XCTAssertEqual(MenuBarText.summary(state: .ready, hiddenCount: 3), localized("%d items hidden by the notch", 3))
        XCTAssertEqual(MenuBarText.summary(state: .needsAccess, hiddenCount: 0), localized("Needs Accessibility access"))
    }

    func testMenuBarItemsIsOptIn() {
        XCTAssertFalse(ModuleID.menuBar.isEnabledByDefault)
    }

    // MARK: Rendering

    func testRenderMenuBarDetail() throws {
        let reader = FakeMenuBarItemsReader(trusted: true, items: [
            Self.item("Dropbox", x: 960, pid: 901),
            Self.item("1Password", x: 900, pid: 902, title: "1Password menu"),
            Self.item("Rectangle", x: 860, pid: 903),
        ])
        let module = MenuBarModule(reader: reader, geometry: { Self.geometry }, candidates: { [] })
        module.popoverDidOpen()
        waitUntil { module.state == .ready }
        try render(module, named: "DuoBarPlus-Detail-menuBar.png")

        let locked = MenuBarModule(reader: FakeMenuBarItemsReader(trusted: false, items: []), geometry: { Self.geometry }, candidates: { [] })
        locked.popoverDidOpen()
        try render(locked, named: "DuoBarPlus-Detail-menuBar-access.png")
    }

    private func render(_ module: MenuBarModule, named name: String) throws {
        let view = VStack(spacing: 6) {
            MenuBarStatusRow(module: module, onActivate: {})
            MenuBarDetailView(module: module, onOpenAccessibilitySettings: {})
        }
        .padding(12)
        .frame(width: 304)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name), options: .atomic)
        XCTAssertGreaterThan(png.count, 1_000)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout) s", file: file, line: line)
    }
}

final class FakeMenuBarItemsReader: MenuBarItemsReading, @unchecked Sendable {
    let trusted: Bool
    private var _items: [MenuBarItemSnapshot]
    var items: [MenuBarItemSnapshot] {
        get { lock.withLock { _items } }
        set { lock.withLock { _items = newValue } }
    }
    var delay: TimeInterval = 0
    private let lock = NSLock()
    private var _scanCount = 0
    private var _accessRequests = 0
    private var _picked: [(MenuBarItemSnapshot, [Int])] = []
    var menu: [MenuBarMenuEntry]?

    init(trusted: Bool, items: [MenuBarItemSnapshot]) {
        self.trusted = trusted
        self._items = items
    }

    var scanCount: Int { lock.withLock { _scanCount } }
    var accessRequests: Int { lock.withLock { _accessRequests } }
    var picked: [(MenuBarItemSnapshot, [Int])] { lock.withLock { _picked } }

    func menu(of item: MenuBarItemSnapshot) -> [MenuBarMenuEntry]? { menu }

    func pick(_ item: MenuBarItemSnapshot, path: [Int]) -> Bool {
        lock.withLock { _picked.append((item, path)) }
        return true
    }

    func isTrusted() -> Bool { trusted }
    func requestAccess() { lock.withLock { _accessRequests += 1 } }

    func items(of apps: [MenuBarAppCandidate]) -> [MenuBarItemSnapshot] {
        lock.withLock { _scanCount += 1 }
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        return lock.withLock { _items }
    }
}

