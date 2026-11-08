import XCTest
@testable import DuoBar

@MainActor
final class ModuleRegistryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ModuleRegistryTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testResolveOrderKeepsStoredOrderDropsUnknownAndAppendsMissing() {
        let order = ModuleRegistry.resolveOrder(stored: ["disk", "bogus", "network", "disk"])
        XCTAssertEqual(order, [.disk, .network, .battery, .bluetooth, .system, .aiUsage])
        XCTAssertEqual(ModuleRegistry.resolveOrder(stored: nil), ModuleID.allCases)
    }

    func testEnabledSupportedModulesAreActivatedAndVisibleInOrder() {
        let network = RecordingModule(.network)
        let battery = RecordingModule(.battery)
        defaults.set(["battery", "network"], forKey: PreferenceKeys.moduleOrder)

        let registry = ModuleRegistry(modules: [network, battery], defaults: defaults)

        XCTAssertEqual(registry.visibleModules, [.battery, .network])
        XCTAssertEqual(network.events, [.activate])
        XCTAssertEqual(battery.events, [.activate])
    }

    func testUnsupportedModuleIsNeverActivated() {
        let battery = RecordingModule(.battery, isSupported: false)
        let registry = ModuleRegistry(modules: [battery], defaults: defaults)

        registry.popoverDidOpen()
        registry.detailDidOpen(.battery)

        XCTAssertEqual(registry.visibleModules, [])
        XCTAssertEqual(battery.events, [])
    }

    func testDisabledModuleGetsNoLifecycleCalls() {
        defaults.set(false, forKey: PreferenceKeys.moduleEnabled(.network))
        let network = RecordingModule(.network)
        let registry = ModuleRegistry(modules: [network], defaults: defaults)

        registry.popoverDidOpen()
        registry.detailDidOpen(.network)
        registry.popoverDidClose()

        XCTAssertEqual(registry.visibleModules, [])
        XCTAssertEqual(network.events, [])
    }

    func testDisablingWhileDetailIsOpenUnwindsInOrder() {
        let network = RecordingModule(.network)
        let registry = ModuleRegistry(modules: [network], defaults: defaults)
        var deactivated: [ModuleID] = []
        registry.onModuleDeactivated = { deactivated.append($0) }

        registry.popoverDidOpen()
        registry.detailDidOpen(.network)
        registry.setEnabled(false, for: .network)

        XCTAssertEqual(network.events, [.activate, .popoverOpen, .detailOpen, .detailClose, .popoverClose, .deactivate])
        XCTAssertEqual(registry.visibleModules, [])
        XCTAssertNil(registry.openDetail)
        XCTAssertEqual(deactivated, [.network])
    }

    func testEnablingWhilePopoverIsOpenStartsRowWork() {
        defaults.set(false, forKey: PreferenceKeys.moduleEnabled(.network))
        let network = RecordingModule(.network)
        let registry = ModuleRegistry(modules: [network], defaults: defaults)

        registry.popoverDidOpen()
        registry.setEnabled(true, for: .network)

        XCTAssertEqual(network.events, [.activate, .popoverOpen])
        XCTAssertEqual(registry.visibleModules, [.network])
    }

    func testPopoverCallsAreBalancedAndIdempotent() {
        let network = RecordingModule(.network)
        let registry = ModuleRegistry(modules: [network], defaults: defaults)

        registry.popoverDidClose()
        registry.popoverDidOpen()
        registry.popoverDidOpen()
        registry.detailDidOpen(.network)
        registry.detailDidOpen(.network)
        registry.popoverDidClose()
        registry.popoverDidClose()

        XCTAssertEqual(network.events, [.activate, .popoverOpen, .detailOpen, .detailClose, .popoverClose])
    }

    func testDetailRequiresOpenPopover() {
        let network = RecordingModule(.network)
        let registry = ModuleRegistry(modules: [network], defaults: defaults)

        registry.detailDidOpen(.network)

        XCTAssertEqual(network.events, [.activate])
        XCTAssertNil(registry.openDetail)
    }

    func testOpeningAnotherDetailClosesThePreviousOne() {
        let network = RecordingModule(.network)
        let battery = RecordingModule(.battery)
        let registry = ModuleRegistry(modules: [network, battery], defaults: defaults)

        registry.popoverDidOpen()
        registry.detailDidOpen(.network)
        registry.detailDidOpen(.battery)

        XCTAssertEqual(network.events.suffix(2), [.detailOpen, .detailClose])
        XCTAssertEqual(battery.events.last, .detailOpen)
        XCTAssertEqual(registry.openDetail, .battery)
    }

    func testSetOrderPersistsCompleteOrder() {
        let registry = ModuleRegistry(modules: [RecordingModule(.network), RecordingModule(.battery)], defaults: defaults)

        registry.setOrder([.battery])

        XCTAssertEqual(defaults.stringArray(forKey: PreferenceKeys.moduleOrder), ["battery", "network", "bluetooth", "system", "disk", "aiUsage"])
        XCTAssertEqual(registry.visibleModules, [.battery, .network])
    }
}

@MainActor
final class RecordingModule: StatusModule {
    enum Event: Equatable {
        case activate, deactivate, popoverOpen, popoverClose, detailOpen, detailClose
    }

    let id: ModuleID
    let isSupported: Bool
    private(set) var events: [Event] = []

    init(_ id: ModuleID, isSupported: Bool = true) {
        self.id = id
        self.isSupported = isSupported
    }

    func activate() { events.append(.activate) }
    func deactivate() { events.append(.deactivate) }
    func popoverDidOpen() { events.append(.popoverOpen) }
    func popoverDidClose() { events.append(.popoverClose) }
    func detailDidOpen() { events.append(.detailOpen) }
    func detailDidClose() { events.append(.detailClose) }
}
