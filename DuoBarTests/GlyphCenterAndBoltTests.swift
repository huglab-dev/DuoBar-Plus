import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class GlyphCenterAndBoltTests: XCTestCase {
    /// The bolt never reaches the dots, whatever the level.
    func testChargingBoltStaysClearOfTheDots() {
        let metrics = DuoGlyphMetrics.standard
        let diameter = metrics.ringDiameter
        let dot = CGPoint(
            x: DuoVolumeIndicatorGeometry.centerXOffsets[3] * diameter,
            y: DuoVolumeIndicatorGeometry.centerYOffsets[3] * diameter + metrics.ringYOffset
        )
        let dotRadius = diameter * DuoVolumeIndicatorGeometry.indicatorDiameterRatio * DuoVolumeIndicatorGeometry.activeScale / 2
        let boltHalf = diameter * BatteryChargingAnimationProfile.boltFontSizeRatio * DuoRingGeometry.chargingBoltHalfWidthRatio
        for step in 0...20 {
            let point = DuoRingGeometry.chargingBoltPoint(metrics: metrics, progress: Double(step) / 20)
            let distance = hypot(point.x - dot.x, point.y - dot.y)
            XCTAssertGreaterThan(distance, dotRadius + boltHalf, "progress \(Double(step) / 20)")
        }
    }

    /// Low and middle levels keep the bolt just past the arc's end.
    func testChargingBoltFollowsTheArcBelowTheClamp() {
        let metrics = DuoGlyphMetrics.standard
        let low = DuoRingGeometry.chargingBoltPoint(metrics: metrics, progress: 0.2)
        let high = DuoRingGeometry.chargingBoltPoint(metrics: metrics, progress: 0.6)
        XCTAssertNotEqual(low, high)
    }

    func testCenterSizeIsClamped() {
        let standard = DuoGlyphMetrics.standard
        XCTAssertEqual(standard.centerScale, 1)
        XCTAssertEqual(standard.withCenterScale(1.2).centerScale, 1.2, accuracy: 0.0001)
        XCTAssertEqual(standard.withCenterScale(9).centerScale, 1.3, accuracy: 0.0001)
        XCTAssertEqual(standard.withCenterScale(0).centerScale, 0.7, accuracy: 0.0001)
        XCTAssertEqual(CenterIconSize.resolve(nil), 1)
        // Only the center changes.
        XCTAssertEqual(standard.withCenterScale(1.3).arcLineWidth, standard.arcLineWidth)
        XCTAssertEqual(standard.withCenterScale(1.3).ringDiameter, standard.ringDiameter)
    }

    func testWiFiMarkIsCentredNearTheRingCentre() {
        typealias G = DuoWiFiReferenceGeometry
        let top = G.apexYRatio - G.outerArcRadiusRatio - G.strokeWidthRatio / 2
        let bottom = G.apexYRatio + G.coreCenterOffsetRatio + G.coreRadiusRatio
        XCTAssertEqual((top + bottom) / 2, G.markCenterYRatio, accuracy: 0.0001)
        // Even gaps between the core and the bands.
        XCTAssertEqual(G.middleArcRadiusRatio - G.strokeWidthRatio / 2 - G.coreRadiusRatio, G.gapRatio, accuracy: 0.0001)
        XCTAssertEqual(G.outerArcRadiusRatio - G.middleArcRadiusRatio - G.strokeWidthRatio, G.gapRatio, accuracy: 0.0001)
    }

    func testRenderCenterAndBolt() throws {
        func status(_ percent: Int, charging: Bool) -> SystemStatus {
            var status = IndicatorSettingsView.sampleStatus
            status.battery = BatteryStatus(percentage: percent, isCharging: charging, isPluggedIn: charging, isFullyCharged: false, isAvailable: true)
            status.audio.volume = OutputVolumeStatus(level: 0.5, isMuted: false, isSettable: true)
            return status
        }
        func glyph(_ status: SystemStatus, center: DuoCenterState? = nil, scale: Double = 1) -> some View {
            let metrics = DuoGlyphMetrics.standard.sized(110).withCenterScale(scale)
            return DuoGlyphView(
                status: status,
                metrics: metrics,
                animationsEnabled: false,
                ringPresentation: .battery(status.battery, colorCodingEnabled: true, levelColorsEnabled: true),
                centerStateOverride: center,
                batteryColorCodingEnabled: true,
                batteryLevelColorsEnabled: true
            )
            .frame(width: 120, height: 120)
            .overlay {
                // Crosshair through the ring centre to check centring.
                let y = 60 + metrics.ringYOffset * 120 / DuoGlyphMetrics.canvasSize
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: 120, y: y))
                    path.move(to: CGPoint(x: 60, y: 0)); path.addLine(to: CGPoint(x: 60, y: 120))
                }
                .stroke(Color.red.opacity(0.5), lineWidth: 0.5)
            }
        }
        let view = VStack(spacing: 12) {
            HStack(spacing: 12) {
                glyph(status(40, charging: true))
                glyph(status(85, charging: true))
                glyph(status(95, charging: true))
                glyph(status(99, charging: true))
            }
            HStack(spacing: 12) {
                glyph(status(90, charging: false), center: .value(90))
                glyph(status(100, charging: false), center: .value(100))
                glyph(status(90, charging: false), scale: 0.7)
                glyph(status(90, charging: false), scale: 1.3)
            }
        }
        .padding(12)
        .background(Color(red: 0.75, green: 0.55, blue: 0.42))
        .environment(\.colorScheme, .light)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-CenterAndBolt.png"), options: .atomic)
    }
}
