import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class NetworkAddressesTests: XCTestCase {
    private let sample: [InterfaceAddress] = [
        InterfaceAddress(interface: "lo0", address: "127.0.0.1", isIPv6: false),
        InterfaceAddress(interface: "en0", address: "fe80::1", isIPv6: true),
        InterfaceAddress(interface: "en0", address: "192.168.1.154", isIPv6: false),
        InterfaceAddress(interface: "en0", address: "2001:db8::5", isIPv6: true),
        InterfaceAddress(interface: "utun0", address: "fe80::abcd", isIPv6: true),
        InterfaceAddress(interface: "utun3", address: "fd00::1", isIPv6: true),
    ]

    func testGlobalIPv6Classification() {
        XCTAssertTrue(NetworkAddresses.isGlobalIPv6("2001:db8::5"))
        XCTAssertTrue(NetworkAddresses.isGlobalIPv6("2a02:aa1::1"))
        XCTAssertFalse(NetworkAddresses.isGlobalIPv6("fe80::1"))
        XCTAssertFalse(NetworkAddresses.isGlobalIPv6("fd00::1"))
        XCTAssertFalse(NetworkAddresses.isGlobalIPv6("::1"))
    }

    func testIdleSystemTunnelsAreNotAVPN() {
        let result = NetworkAddresses.make(addresses: sample, primaryInterface: "en0", router: "192.168.1.1", dnsServers: ["1.1.1.1"])
        XCTAssertEqual(result.ipv4, "192.168.1.154")
        XCTAssertEqual(result.ipv6, "2001:db8::5")
        XCTAssertEqual(result.router, "192.168.1.1")
        XCTAssertNil(result.vpnInterface)
    }

    func testTunnelWithIPv4OrPrimaryRouteIsAVPN() {
        let withVPN = sample + [InterfaceAddress(interface: "utun7", address: "10.8.0.2", isIPv6: false)]
        XCTAssertEqual(NetworkAddresses.vpnInterface(addresses: withVPN, primaryInterface: "en0"), "utun7")
        XCTAssertEqual(NetworkAddresses.vpnInterface(addresses: sample, primaryInterface: "ipsec0"), "ipsec0")
    }

    func testModuleReadsAddressesOnlyWithOpenDetail() {
        let addresses = FakeAddressReader()
        let module = NetworkModule(reader: FakeWiFiDetailsReader(), addressReader: addresses, interval: 0.05)
        module.popoverDidOpen()
        spin(0.15)
        XCTAssertEqual(addresses.reads, 0)

        module.detailDidOpen()
        waitUntil { module.addresses != nil }
        module.detailDidClose()
        spin(0.05)
        let reads = addresses.reads
        spin(0.15)
        XCTAssertEqual(addresses.reads, reads)
        module.popoverDidClose()
    }

    func testRealReaderFindsPrimaryInterface() throws {
        let result = NetworkAddressReader().addresses()
        guard let primary = result.primaryInterface else { throw XCTSkip("Offline") }
        XCTAssertFalse(primary.isEmpty)
        XCTAssertTrue(result.ipv4 != nil || result.ipv6 != nil)
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

final class FakeAddressReader: NetworkAddressReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    var reads: Int { lock.withLock { _reads } }

    func addresses() -> NetworkAddresses {
        lock.withLock { _reads += 1 }
        return NetworkAddresses(primaryInterface: "en0", ipv4: "192.168.1.20", ipv6: nil, router: "192.168.1.1", dnsServers: ["9.9.9.9"], vpnInterface: nil)
    }
}

@MainActor
final class SpeedHistoryTests: XCTestCase {
    func testKeepsSixtySamplesAndIgnoresNil() {
        let history = SpeedHistory()
        history.append(nil)
        XCTAssertTrue(history.samples.isEmpty)
        for i in 0..<75 {
            history.append(NetworkSpeed(downloadBytesPerSecond: Double(i), uploadBytesPerSecond: 1))
        }
        XCTAssertEqual(history.samples.count, 60)
        XCTAssertEqual(history.samples.first?.download, 15)
        XCTAssertEqual(history.peak, 74)
        history.clear()
        XCTAssertTrue(history.samples.isEmpty)
    }

    func testModuleRecordsOnlyWhilePopoverIsOpen() {
        let module = NetworkModule(reader: FakeWiFiDetailsReader(), addressReader: FakeAddressReader(), interval: 60)
        module.record(.zero)
        XCTAssertTrue(module.speedHistory.samples.isEmpty)
        module.popoverDidOpen()
        module.record(.zero)
        XCTAssertEqual(module.speedHistory.samples.count, 1)
        module.popoverDidClose()
        XCTAssertTrue(module.speedHistory.samples.isEmpty, "history lives only while the popover is open")
    }

    func testRenderGraph() throws {
        let history = SpeedHistory()
        for i in 0..<60 {
            let wave = (sin(Double(i) / 6) + 1.2) * 2_000_000
            history.append(NetworkSpeed(downloadBytesPerSecond: wave, uploadBytesPerSecond: wave / 6))
        }
        let view = SpeedGraphTile(history: history)
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
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-SpeedGraph.png"), options: .atomic)
    }
}
