import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class WiFiDetailsTests: XCTestCase {
    nonisolated static let sample = WiFiDetails(
        interfaceName: "en0", ssid: "Home", bssid: "aa:bb:cc:dd:ee:ff",
        rssi: -58, noise: -92, transmitRate: 864, securityRaw: 13, phyModeRaw: 6,
        channelNumber: 108, band: .ghz5, channelWidthRaw: 3,
        hardwareAddress: "00:11:22:33:44:55", currentAddress: "02:00:00:00:00:02"
    )

    func testTextMappings() {
        XCTAssertEqual(Self.sample.snr, 34)
        XCTAssertEqual(WiFiText.security(4), "WPA2 Personal")
        XCTAssertEqual(WiFiText.security(13), "WPA2/WPA3 Personal")
        XCTAssertNil(WiFiText.security(Int.max))
        XCTAssertEqual(WiFiText.phyMode(6, band: .ghz5), "Wi-Fi 6 (802.11ax)")
        XCTAssertEqual(WiFiText.phyMode(6, band: .ghz6), "Wi-Fi 6E (802.11ax)")
        XCTAssertEqual(WiFiText.phyMode(7, band: .ghz6), "Wi-Fi 7 (802.11be)")
        XCTAssertNil(WiFiText.phyMode(0, band: nil))
        XCTAssertEqual(WiFiText.channel(Self.sample), "108 · 5 GHz · 80 MHz")
        XCTAssertNil(WiFiText.rate(0))
    }

    func testPrivateAddressDetection() {
        XCTAssertEqual(Self.sample.privateAddress, "02:00:00:00:00:02")
        var same = Self.sample
        same.currentAddress = same.hardwareAddress
        XCTAssertNil(same.privateAddress, "no private row when the hardware address is in use")
        XCTAssertTrue(MACAddress.isLocallyAdministered("02:00:00:00:00:02"))
        XCTAssertFalse(MACAddress.isLocallyAdministered("00:11:22:33:44:55"))
        XCTAssertEqual(MACAddress.format(Data([0x00, 0x11, 0x22, 0x33, 0x44, 0x55])), "00:11:22:33:44:55")
        XCTAssertNil(MACAddress.format(Data([1, 2, 3])))
    }

    func testRealHardwareAddress() throws {
        guard let name = WiFiDetailsReader().details()?.interfaceName else { throw XCTSkip("No Wi-Fi") }
        let address = try XCTUnwrap(MACAddress.hardwareAddress(forBSDName: name))
        XCTAssertFalse(MACAddress.isLocallyAdministered(address), "the burned-in address is globally unique")
        XCTAssertNotNil(MACAddress.linkAddress(forBSDName: name))
    }

    func testSNRNeedsMeaningfulValues() {
        var details = Self.sample
        details.noise = 0
        XCTAssertNil(details.snr)
        details.rssi = 0
        XCTAssertFalse(details.isAssociated)
    }

    func testModuleSamplesOnlyWhilePopoverIsOpen() {
        let reader = FakeWiFiDetailsReader()
        let module = NetworkModule(reader: reader, interval: 0.05)
        module.activate()
        spin(0.1)
        XCTAssertEqual(reader.reads, 0, "nothing is read while the popover is closed")

        module.popoverDidOpen()
        XCTAssertTrue(module.isSamplingDetails)
        waitUntil { module.wifi == Self.sample && reader.reads >= 3 }

        module.popoverDidClose()
        XCTAssertFalse(module.isSamplingDetails)
        spin(0.05)
        let reads = reader.reads
        spin(0.15)
        XCTAssertEqual(reader.reads, reads)

        module.popoverDidOpen()
        module.deactivate()
        XCTAssertFalse(module.isSamplingDetails)
    }

    func testSignalQualityColors() {
        typealias Q = NetworkStatusText.SignalQuality
        XCTAssertEqual(Q(rssi: -40), .good)
        XCTAssertEqual(Q(rssi: -67), .good)
        XCTAssertEqual(Q(rssi: -68), .fair)
        XCTAssertEqual(Q(rssi: -75), .fair)
        XCTAssertEqual(Q(rssi: -76), .poor)
        XCTAssertEqual(Q(rssi: -82), .poor)
        XCTAssertEqual(Q(rssi: -83), .bad)
    }

    func testRenderNetworkRowWithSignal() throws {
        let store = SystemStatusStore(
            startServices: false,
            deviceContext: DeviceContext(hasInternalBattery: true),
            moduleDefaults: UserDefaults(suiteName: "WiFiDetailsTests.\(UUID().uuidString)")!
        )
        store.applyDebugNetworkState(.strong)
        let rows = [-48, -72, -79, -88].map { rssi -> NetworkModule in
            let module = NetworkModule(reader: FixedRSSIReader(rssi: rssi), interval: 60)
            module.popoverDidOpen()
            waitUntil { module.wifi?.rssi == rssi }
            return module
        }
        let view = VStack(spacing: 6) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, module in
                NetworkStatusRow(statusStore: store, module: module, trailing: nil, onActivate: {})
            }
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
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-NetworkRow-signal.png"), options: .atomic)
        rows.forEach { $0.popoverDidClose() }
    }

    func testRealReaderOnThisMac() throws {
        guard let details = WiFiDetailsReader().details(), details.isAssociated else {
            throw XCTSkip("Wi-Fi is off or not associated")
        }
        XCTAssertNotNil(WiFiText.security(details.securityRaw))
        XCTAssertNotNil(WiFiText.phyMode(details.phyModeRaw, band: details.band))
        XCTAssertNotNil(WiFiText.channel(details))
    }

    func testRenderWiFiDetail() throws {
        let store = SystemStatusStore(
            startServices: false,
            deviceContext: DeviceContext(hasInternalBattery: true),
            moduleDefaults: UserDefaults(suiteName: "WiFiDetailsTests.\(UUID().uuidString)")!
        )
        store.applyDebugNetworkState(.strong)
        let module = NetworkModule(reader: FakeWiFiDetailsReader(), interval: 60)
        module.popoverDidOpen()
        waitUntil { module.wifi != nil }

        let view = VStack(spacing: 6) {
            NetworkDetailView(
                statusStore: store,
                module: module,
                nearbyNetworks: AnyView(NearbyWiFiButton(statusStore: store, onOpenSettings: {})),
                onOpenSettings: {}
            )
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
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-Detail-wifi.png"), options: .atomic)
        module.popoverDidClose()
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

final class FakeWiFiDetailsReader: WiFiDetailsReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    var reads: Int { lock.withLock { _reads } }

    func details() -> WiFiDetails? {
        lock.withLock { _reads += 1 }
        return WiFiDetailsTests.sample
    }
}

final class NearbyKnownNetworksTests: XCTestCase {
    private func candidate(_ ssid: String, rssi: Int, known: Bool = false, current: Bool = false, band: WiFiBand? = nil) -> NearbyWiFiScanCandidate {
        NearbyWiFiScanCandidate(
            id: "\(ssid)|personal|\(rssi)", ssid: ssid, bssid: nil, rssi: rssi, channelNumber: nil,
            security: .personal, isCurrent: current, isKnown: known, band: band
        )
    }

    func testCurrentThenKnownThenSignal() {
        let networks = NearbyWiFiListBuilder.makeNetworks(from: [
            candidate("Strong stranger", rssi: -40),
            candidate("Known weak", rssi: -80, known: true),
            candidate("Home", rssi: -70, known: true, current: true),
            candidate("Known strong", rssi: -50, known: true),
        ])
        XCTAssertEqual(networks.map(\.ssid), ["Home", "Known strong", "Known weak", "Strong stranger"])
    }

    func testMergedNetworkKeepsBandOfStrongestAccessPoint() {
        let networks = NearbyWiFiListBuilder.makeNetworks(from: [
            candidate("Office", rssi: -75, band: .ghz2),
            candidate("Office", rssi: -55, band: .ghz5),
        ])
        XCTAssertEqual(networks.count, 1)
        XCTAssertEqual(networks.first?.band, .ghz5)
    }
}

final class FixedRSSIReader: WiFiDetailsReading, @unchecked Sendable {
    let rssi: Int
    init(rssi: Int) { self.rssi = rssi }
    func details() -> WiFiDetails? {
        var details = WiFiDetailsTests.sample
        details.rssi = rssi
        return details
    }
}
