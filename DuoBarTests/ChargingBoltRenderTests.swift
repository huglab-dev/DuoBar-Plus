import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class ChargingBoltRenderTests: XCTestCase {
    private func status(charging: Bool, full: Bool = false) -> SystemStatus {
        var status = IndicatorSettingsView.sampleStatus
        status.battery = BatteryStatus(percentage: full ? 100 : 85, isCharging: charging && !full, isPluggedIn: charging, isFullyCharged: full, isAvailable: true)
        return status
    }

    func testBoltOnAdaptiveRingOnlyWhileCharging() {
        let charging = DuoGlyphView(status: status(charging: true), ringPresentation: .adaptive(progress: 0.4))
        XCTAssertTrue(charging.showsAdaptiveChargingBolt)
        XCTAssertFalse(DuoGlyphView(status: status(charging: false), ringPresentation: .adaptive(progress: 0.4)).showsAdaptiveChargingBolt)
        XCTAssertFalse(DuoGlyphView(status: status(charging: true, full: true), ringPresentation: .adaptive(progress: 0.4)).showsAdaptiveChargingBolt, "no bolt when full")
        XCTAssertFalse(DuoGlyphView(status: status(charging: true), ringPresentation: .adaptive(progress: 0.4), showBatteryPercentage: true).showsAdaptiveChargingBolt, "the number uses the gap")
    }

    func testRenderBoltInEveryRingMode() throws {
        let charging = status(charging: true)
        let view = HStack(spacing: 16) {
            DuoGlyphView(status: charging, metrics: DuoGlyphMetrics.standard.sized(140), animationsEnabled: false, batteryColorCodingEnabled: true)
            DuoGlyphView(status: charging, metrics: DuoGlyphMetrics.standard.sized(140), animationsEnabled: false, ringPresentation: .adaptive(progress: 0.25))
            DuoGlyphView(status: charging, metrics: DuoGlyphMetrics.standard.sized(140), animationsEnabled: false,
                         ringPresentation: GlyphComposer.gauge(0.9), ringColorOverride: Color(nsColor: .systemOrange))
        }
        .padding(12)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-ChargingBolt.png"), options: .atomic)
    }
}
