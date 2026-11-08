import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class NearbyListRenderTests: XCTestCase {
    func testRenderSectionedList() async throws {
        func candidate(_ ssid: String, _ rssi: Int, band: WiFiBand, known: Bool = false, current: Bool = false, open: Bool = false) -> NearbyWiFiScanCandidate {
            NearbyWiFiScanCandidate(id: ssid, ssid: ssid, bssid: nil, rssi: rssi, channelNumber: 36,
                                    security: open ? .open : .personal, isCurrent: current, isKnown: known, band: band)
        }
        let provider = RenderNearbyProvider(result: NearbyWiFiScanResult(isWiFiPoweredOn: true, networks: [
            candidate("Bjurström_5ghz", -48, band: .ghz5, known: true, current: true),
            candidate("Bjurström_24ghz", -55, band: .ghz2, known: true),
            candidate("Office Guest", -70, band: .ghz5, known: true, open: true),
            candidate("ENwifi-A7C771", -62, band: .ghz2),
            candidate("Telia-2G", -80, band: .ghz2),
        ]))
        let store = SystemStatusStore(
            startServices: false,
            deviceContext: DeviceContext(hasInternalBattery: true),
            nearbyWiFiProvider: provider,
            moduleDefaults: UserDefaults(suiteName: "NearbyListRenderTests.\(UUID().uuidString)")!
        )
        await store.refreshNearbyWiFi()
        XCTAssertEqual(store.nearbyWiFiController.networks.first?.ssid, "Bjurström_5ghz")

        let view = NearbyWiFiPopoverView(statusStore: store, onOpenSettings: {})
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        for _ in 0..<3 {
            hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
            hostingView.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-NearbyList.png"), options: .atomic)
    }
}

private actor RenderNearbyProvider: NearbyWiFiProviding {
    let result: NearbyWiFiScanResult
    init(result: NearbyWiFiScanResult) { self.result = result }
    func scan() async throws -> NearbyWiFiScanResult { result }
    func associate(networkID: String, password: String?) async throws {}
}
