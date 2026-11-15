import XCTest
@testable import DuoBar

@MainActor
final class IPConfigurationTests: XCTestCase {
    private let manual = IPConfiguration(
        method: .manual, address: "192.168.1.20", subnetMask: "255.255.255.0", router: "192.168.1.1",
        dnsServers: ["1.1.1.1", "2606:4700:4700::1111"], searchDomains: ["home.arpa"]
    )

    func testValidation() {
        XCTAssertTrue(IPv4Validation.isAddress("10.0.0.255"))
        XCTAssertFalse(IPv4Validation.isAddress("10.0.0.256"))
        XCTAssertFalse(IPv4Validation.isAddress("10.0.0"))
        XCTAssertFalse(IPv4Validation.isAddress("10.0.0.1 "))
        XCTAssertFalse(IPv4Validation.isAddress("a.b.c.d"))
        XCTAssertTrue(IPv4Validation.isSubnetMask("255.255.255.0"))
        XCTAssertTrue(IPv4Validation.isSubnetMask("255.255.252.0"))
        XCTAssertFalse(IPv4Validation.isSubnetMask("255.0.255.0"))
        XCTAssertFalse(IPv4Validation.isSubnetMask("0.0.0.0"))
        XCTAssertTrue(IPv4Validation.sameSubnet("192.168.1.20", "192.168.1.1", mask: "255.255.255.0"))
        XCTAssertFalse(IPv4Validation.sameSubnet("192.168.2.20", "192.168.1.1", mask: "255.255.255.0"))
        XCTAssertTrue(IPv4Validation.isDNSServer("2606:4700:4700::1111"))
        XCTAssertFalse(IPv4Validation.isDNSServer("dns.google"))
        XCTAssertTrue(IPv4Validation.isSearchDomain("corp.example.com"))
        XCTAssertFalse(IPv4Validation.isSearchDomain("bad domain"))
    }

    func testCommands() {
        XCTAssertEqual(
            IPConfigurationCommand.apply(manual, service: "USB 10/100/1000 LAN"),
            "/usr/sbin/networksetup -setmanual 'USB 10/100/1000 LAN' '192.168.1.20' '255.255.255.0' '192.168.1.1'"
                + " && /usr/sbin/networksetup -setdnsservers 'USB 10/100/1000 LAN' '1.1.1.1' '2606:4700:4700::1111'"
                + " && /usr/sbin/networksetup -setsearchdomains 'USB 10/100/1000 LAN' 'home.arpa'"
        )
        var dhcp = manual
        dhcp.method = .dhcp
        dhcp.dnsServers = []
        dhcp.searchDomains = []
        XCTAssertEqual(
            IPConfigurationCommand.apply(dhcp, service: "Wi-Fi"),
            "/usr/sbin/networksetup -setdhcp 'Wi-Fi' && /usr/sbin/networksetup -setdnsservers 'Wi-Fi' Empty && /usr/sbin/networksetup -setsearchdomains 'Wi-Fi' Empty"
        )
        var inform = dhcp
        inform.method = .dhcpManualAddress
        XCTAssertTrue(IPConfigurationCommand.apply(inform, service: "Bob's \"LAN\"")
            .hasPrefix("/usr/sbin/networksetup -setmanualwithdhcprouter 'Bob'\\''s \"LAN\"' '192.168.1.20'"))
        XCTAssertEqual(IPConfigurationCommand.renew(bsdName: "en7"), "/usr/sbin/ipconfig set 'en7' DHCP")
    }

    func testEditorAppliesOnceAndClosesOnSuccess() {
        let runner = FakePrivilegedRunner(result: .success(()))
        let model = IPConfigurationEditorModel(bsdName: "en7", reader: FakeIPReader(manual), runner: runner)
        var applied = 0
        model.onApplied = { applied += 1 }
        model.load()
        XCTAssertEqual(model.serviceName, "Ethernet")
        XCTAssertFalse(model.canApply, "nothing changed yet")
        XCTAssertFalse(model.canRenewLease, "renewing would switch a manual service to DHCP")

        model.dnsText = "9.9.9.9\n149.112.112.112"
        XCTAssertTrue(model.canApply)
        var done = false
        model.apply { done = true }
        waitUntil { done }
        XCTAssertEqual(runner.commands.count, 1)
        XCTAssertTrue(runner.commands[0].contains("-setdnsservers 'Ethernet' '9.9.9.9' '149.112.112.112'"))
        XCTAssertEqual(applied, 1)
    }

    func testEditorBlocksInvalidInputAndKeepsEditsOnCancel() {
        let model = IPConfigurationEditorModel(bsdName: "en7", reader: FakeIPReader(manual), runner: FakePrivilegedRunner(result: .failure(.cancelled)))
        model.onApplied = { XCTFail("stays open when cancelled") }
        model.load()
        model.router = "10.0.0.1"
        XCTAssertNotNil(model.errors[.router])
        XCTAssertFalse(model.canApply)

        model.router = "192.168.1.254"
        model.method = .dhcp
        XCTAssertTrue(model.errors.isEmpty, "addresses are not checked for DHCP")
        var done = false
        model.apply { done = true }
        waitUntil { done }
        XCTAssertTrue(model.isDirty)
        XCTAssertNil(model.errorMessage)
    }

    func testRenewLeaseOnlyForDHCP() {
        var dhcp = manual
        dhcp.method = .dhcp
        let runner = FakePrivilegedRunner(result: .success(()))
        let model = IPConfigurationEditorModel(bsdName: "en7", reader: FakeIPReader(dhcp), runner: runner)
        model.load()
        XCTAssertTrue(model.canRenewLease)
        var done = false
        model.renewLease { done = true }
        waitUntil { done }
        XCTAssertEqual(runner.commands, ["/usr/sbin/ipconfig set 'en7' DHCP"])
        XCTAssertEqual(model.statusMessage, localized("DHCP lease renewed"))
    }

    func testToolsRefuseToRenewAManualService() {
        let runner = FakePrivilegedRunner(result: .success(()))
        var errors: [String] = []
        let tools = NetworkTools(runner: runner, ipReader: FakeIPReader(manual), notifier: FakeNotifier(), showError: { errors.append($0) })
        tools.renewDHCPLease(bsdName: "en7")
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(runner.commands.isEmpty)
    }

    func testRealReaderFindsTheActiveService() throws {
        let addresses = NetworkAddressReader().addresses()
        guard let primary = addresses.primaryInterface, !NetworkAddresses.isTunnel(primary) else { throw XCTSkip("No primary interface") }
        let service = try XCTUnwrap(SCPreferencesIPConfigurationReader().configuration(forBSDName: primary))
        XCTAssertFalse(service.serviceName.isEmpty)
        if service.configuration.method == .dhcp, let ipv4 = addresses.ipv4 {
            XCTAssertEqual(service.configuration.address, ipv4, "DHCP shows the live address")
        }
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.01) }
        XCTAssertTrue(condition(), "condition not met within \(timeout) s", file: file, line: line)
    }
}

final class FakeIPReader: IPConfigurationReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _configuration: IPConfiguration
    let currentDNS: [String]
    let currentSearch: [String]

    init(_ configuration: IPConfiguration, currentDNS: [String] = [], currentSearch: [String] = []) {
        _configuration = configuration
        self.currentDNS = currentDNS
        self.currentSearch = currentSearch
    }

    var configuration: IPConfiguration {
        get { lock.withLock { _configuration } }
        set { lock.withLock { _configuration = newValue } }
    }

    func configuration(forBSDName bsdName: String) -> IPServiceConfiguration? {
        IPServiceConfiguration(serviceName: "Ethernet", bsdName: bsdName, configuration: configuration,
                               currentDNSServers: currentDNS, currentSearchDomains: currentSearch)
    }

    func configuration(forServiceName serviceName: String) -> IPServiceConfiguration? {
        serviceName == "Ethernet" ? configuration(forBSDName: "en7") : nil
    }
}
