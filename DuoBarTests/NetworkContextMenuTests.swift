import AppKit
import XCTest
@testable import DuoBar

@MainActor
final class NetworkContextMenuTests: XCTestCase {
    private let suiteName = "DuoBarPlus.NetworkContextMenuTests"
    private var defaults: UserDefaults!

    private let office = IPConfiguration(method: .manual, address: "10.0.0.20", subnetMask: "255.255.255.0", router: "10.0.0.1",
                                         dnsServers: [], searchDomains: [])

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func network(connected: Bool) -> NetworkStatus {
        NetworkStatus(isAvailable: true, isConnected: connected, transport: .ethernet, interfaceName: "en7",
                      isWiFiPoweredOn: true, ssid: nil, rssi: nil)
    }

    func testRowsAndProfileSubmenu() throws {
        let store = IPProfileStore(defaults: defaults)
        let profile = store.save(name: "Office", serviceName: "Ethernet", configuration: office)
        let runner = FakePrivilegedRunner(result: .success(()))
        let tools = NetworkTools(runner: runner, ipReader: FakeIPReader(office), profiles: store, notifier: FakeNotifier(), showError: { _ in })
        var closed = 0
        let menu = NetworkContextMenu.make(tools: tools, network: network(connected: true)) { closed += 1 }

        XCTAssertEqual(menu.items.map(\.title), [
            localized("Flush DNS Cache…"), localized("Edit Hosts File…"), "",
            localized("Renew DHCP Lease"), localized("Configure IP…"), localized("IP Profile"),
        ])
        let submenu = try XCTUnwrap(menu.items.last?.submenu)
        XCTAssertEqual(submenu.items.map(\.title), ["Office", "", localized("Automatic (DHCP)"), "", localized("Manage Profiles…")])
        XCTAssertEqual(submenu.items[0].state, .on)
        XCTAssertEqual(submenu.items[2].state, .off)

        submenu.performActionForItem(at: 0)
        XCTAssertEqual(closed, 1, "the popover closes before the password prompt")
        let deadline = Date().addingTimeInterval(2)
        while runner.commands.isEmpty, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertEqual(runner.commands, [IPConfigurationCommand.apply(profile.configuration, service: "Ethernet")])
    }

    func testOfflineMenuHasOnlyDNSAndHosts() {
        let tools = NetworkTools(runner: FakePrivilegedRunner(result: .success(())), ipReader: FakeIPReader(office),
                                 profiles: IPProfileStore(defaults: defaults), notifier: FakeNotifier(), showError: { _ in })
        let menu = NetworkContextMenu.make(tools: tools, network: network(connected: false)) {}
        XCTAssertEqual(menu.items.map(\.title), [localized("Flush DNS Cache…"), localized("Edit Hosts File…")])
    }

    func testSimpleContextMenuRunsItsAction() {
        var opened = 0
        let menu = SimpleContextMenu.make([
            .init(title: "Open Activity Monitor") { opened += 1 },
            .init(title: "Checked", isChecked: true) {},
        ])
        menu.performActionForItem(at: 0)
        XCTAssertEqual(opened, 1)
        XCTAssertEqual(menu.items[0].state, .off)
        XCTAssertEqual(menu.items[1].state, .on)
    }
}
