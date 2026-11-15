import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class IPProfileTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "DuoBarPlus.IPProfileTests"

    private let cloudflare = IPConfiguration(method: .dhcp, address: "192.168.1.154", subnetMask: "255.255.255.0", router: "192.168.1.1",
                                             dnsServers: ["1.1.1.1"], searchDomains: [])
    private let office = IPConfiguration(method: .manual, address: "10.0.0.20", subnetMask: "255.255.255.0", router: "10.0.0.1",
                                         dnsServers: ["10.0.0.2"], searchDomains: ["corp.example"])

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testProfilesAreSavedAndReadBack() {
        let store = IPProfileStore(defaults: defaults)
        let saved = store.save(name: " Cloudflare ", serviceName: "Ethernet", configuration: cloudflare)
        store.save(name: "Office", serviceName: "Wi-Fi", configuration: office)
        XCTAssertEqual(saved.name, "Cloudflare")

        let reloaded = IPProfileStore(defaults: defaults)
        XCTAssertEqual(reloaded.profiles.map(\.name), ["Cloudflare", "Office"])
        XCTAssertEqual(reloaded.profiles(for: "Ethernet").map(\.name), ["Cloudflare"])
        XCTAssertEqual(reloaded.profile(named: "office")?.configuration, office)

        reloaded.save(name: "Cloudflare", serviceName: "Ethernet", configuration: office)
        XCTAssertEqual(reloaded.profiles.count, 2, "the same name replaces the profile")
        reloaded.delete(saved)
        XCTAssertEqual(IPProfileStore(defaults: defaults).profiles.map(\.name), ["Office"])
    }

    func testActiveProfileIgnoresDHCPAddresses() {
        let store = IPProfileStore(defaults: defaults)
        let profile = store.save(name: "Cloudflare", serviceName: "Ethernet", configuration: cloudflare)
        var current = cloudflare
        current.address = "192.168.1.200"
        let service = IPServiceConfiguration(serviceName: "Ethernet", bsdName: "en7", configuration: current)
        XCTAssertEqual(store.activeProfile(for: service), profile, "DHCP picks its own address")
        current.dnsServers = []
        XCTAssertNil(store.activeProfile(for: IPServiceConfiguration(serviceName: "Ethernet", bsdName: "en7", configuration: current)))
        XCTAssertTrue(current.matches(.automatic))
    }

    func testApplyingAProfileRunsOneCommandAndNotifies() {
        let runner = FakePrivilegedRunner(result: .success(()))
        let notifier = FakeNotifier()
        let store = IPProfileStore(defaults: defaults)
        let profile = store.save(name: "Office", serviceName: "Ethernet", configuration: office)
        let tools = NetworkTools(runner: runner, ipReader: FakeIPReader(cloudflare), profiles: store, notifier: notifier, showError: { XCTFail($0) })
        tools.applyProfile(profile)
        waitUntil { !notifier.titles.isEmpty }
        XCTAssertEqual(runner.commands, [IPConfigurationCommand.apply(office, service: "Ethernet")])
        XCTAssertEqual(notifier.titles, [localized("IP profile %@ applied", "Office")])
    }

    func testProfileByNameAndDHCPFromURL() {
        let runner = FakePrivilegedRunner(result: .success(()))
        var errors: [String] = []
        let store = IPProfileStore(defaults: defaults)
        store.save(name: "Office", serviceName: "Ethernet", configuration: office)
        let tools = NetworkTools(runner: runner, ipReader: FakeIPReader(office), profiles: store, notifier: FakeNotifier(), showError: { errors.append($0) })
        tools.applyProfile(named: "dhcp", primaryBSDName: "en7")
        tools.applyProfile(named: "OFFICE", primaryBSDName: "en7")
        tools.applyProfile(named: "Missing", primaryBSDName: "en7")
        waitUntil { runner.commands.count == 2 }
        XCTAssertEqual(runner.commands[0], IPConfigurationCommand.apply(.automatic, service: "Ethernet"))
        XCTAssertEqual(runner.commands[1], IPConfigurationCommand.apply(office, service: "Ethernet"))
        XCTAssertEqual(errors.count, 1)
    }

    func testProfileMenuState() {
        let store = IPProfileStore(defaults: defaults)
        let profile = store.save(name: "Office", serviceName: "Ethernet", configuration: office)
        let reader = FakeIPReader(office)
        let tools = NetworkTools(runner: FakePrivilegedRunner(result: .success(())), ipReader: reader, profiles: store, notifier: FakeNotifier(), showError: { _ in })
        let state = tools.profileMenuState(bsdName: "en7")
        XCTAssertEqual(state?.serviceName, "Ethernet")
        XCTAssertEqual(state?.profiles, [profile])
        XCTAssertEqual(state?.activeID, profile.id)
        XCTAssertEqual(state?.isAutomatic, false)

        reader.configuration = .automatic
        XCTAssertEqual(tools.profileMenuState(bsdName: "en7")?.isAutomatic, true, "read fresh on every right-click")
    }

    func testEditorProfilesAndInUseDNS() {
        let store = IPProfileStore(defaults: defaults)
        let profile = store.save(name: "Office", serviceName: "Ethernet", configuration: office)
        let runner = FakePrivilegedRunner(result: .success(()))
        let model = IPConfigurationEditorModel(
            bsdName: "en7",
            reader: FakeIPReader(cloudflare, currentDNS: ["1.1.1.1"], currentSearch: ["home.arpa"]),
            runner: runner,
            profiles: store
        )
        model.load()
        XCTAssertEqual(model.currentDNSServers, ["1.1.1.1"])
        XCTAssertEqual(model.currentSearchDomains, ["home.arpa"])
        XCTAssertNil(model.selectedProfileID)
        XCTAssertEqual(IPConfigurationEditorView.inUseText(["192.168.1.1"]), localized("From DHCP: %@", "192.168.1.1"))
        XCTAssertEqual(IPConfigurationEditorView.inUseText([]), localized("From DHCP: %@", localized("None")))

        model.selectProfile(profile.id)
        XCTAssertEqual(model.method, .manual)
        XCTAssertEqual(model.address, "10.0.0.20")
        XCTAssertTrue(model.canApply)
        XCTAssertTrue(runner.commands.isEmpty, "picking a profile applies nothing")

        model.selectProfile(nil)
        XCTAssertFalse(model.isDirty)
        model.dnsText = "9.9.9.9"
        model.saveProfile(named: "Quad9")
        XCTAssertEqual(store.profiles(for: "Ethernet").map(\.name), ["Office", "Quad9"])
        XCTAssertEqual(model.selectedProfileID, store.profile(named: "Quad9")?.id)
        model.deleteSelectedProfile()
        XCTAssertEqual(store.profiles(for: "Ethernet").map(\.name), ["Office"])
    }

    func testRenameAndNameCheck() {
        let store = IPProfileStore(defaults: defaults)
        let profile = store.save(name: "Office", serviceName: "Ethernet", configuration: office)
        let model = IPConfigurationEditorModel(bsdName: "en7", reader: FakeIPReader(office), runner: FakePrivilegedRunner(result: .success(())), profiles: store)
        model.load()
        XCTAssertEqual(model.activeProfileID, profile.id)
        XCTAssertEqual(model.selectedProfileID, profile.id)
        XCTAssertTrue(model.profileNameExists(" Office "))
        XCTAssertFalse(model.profileNameExists("Home"))

        model.renameProfile(profile.id, to: "HQ")
        XCTAssertEqual(store.profiles.map(\.name), ["HQ"])
        XCTAssertEqual(model.selectedProfileID, profile.id)

        model.deleteProfile(profile.id)
        XCTAssertNil(model.selectedProfileID)
        XCTAssertNil(model.activeProfileID)
        XCTAssertTrue(store.profiles.isEmpty)
    }

    func testRenderEditorWithProfiles() throws {
        let store = IPProfileStore(defaults: defaults)
        store.save(name: "Home", serviceName: "Ethernet", configuration: cloudflare)
        let selected = store.save(name: "Office", serviceName: "Ethernet", configuration: office)
        let model = IPConfigurationEditorModel(bsdName: "en7", reader: FakeIPReader(cloudflare, currentDNS: ["94.140.14.14"]), runner: FakePrivilegedRunner(result: .success(())), profiles: store)
        model.load()
        model.selectProfile(selected.id)
        let hosting = NSHostingView(rootView: IPConfigurationEditorView(model: model))
        hosting.frame = NSRect(x: 0, y: 0, width: 460, height: 700)
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-IPConfiguration.png"), options: .atomic)
        XCTAssertGreaterThan(png.count, 1_000)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(condition(), "condition not met within \(timeout) s", file: file, line: line)
    }
}
