import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class GlyphProportionRenderTests: XCTestCase {
    func testRenderReferenceComparison() throws {
        var status = IndicatorSettingsView.sampleStatus
        status.audio.volume = OutputVolumeStatus(level: 0.2, isMuted: false, isSettable: true)
        let view = DuoGlyphView(
            status: status,
            metrics: DuoGlyphMetrics.standard.sized(300),
            animationsEnabled: false,
            batteryColorCodingEnabled: true,
            batteryLevelColorsEnabled: true
        )
        .frame(width: 320, height: 320)
        .background(Color(red: 0.01, green: 0.02, blue: 0.04))
        .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-GlyphLarge.png"), options: .atomic)
    }
}

@MainActor
final class RingThicknessTests: XCTestCase {
    func testThicknessScalesOnlyTheRingStroke() {
        let standard = DuoGlyphMetrics.standard
        let thick = standard.withRingThickness(1.5)
        XCTAssertEqual(thick.arcLineWidth, standard.arcLineWidth * 1.5, accuracy: 0.0001)
        XCTAssertEqual(thick.ringDiameter, standard.ringDiameter)
        XCTAssertEqual(thick.dotDiameter, standard.dotDiameter)
        XCTAssertEqual(standard.withRingThickness(9).ringThicknessScale, 1.5, accuracy: 0.0001)
        XCTAssertEqual(standard.withRingThickness(0.1).ringThicknessScale, 0.6, accuracy: 0.0001)
        XCTAssertEqual(RingThickness.resolve(nil), 1)
        XCTAssertEqual(standard.scaled(by: 1.2).withRingThickness(1.2).arcLineWidth,
                       standard.scaled(by: 1.2).arcLineWidth * 1.2, accuracy: 0.0001)
    }

    func testRenderThicknesses() throws {
        let status = IndicatorSettingsView.sampleStatus
        let view = HStack(spacing: 16) {
            ForEach([0.6, 1.0, 1.5], id: \.self) { scale in
                DuoGlyphView(status: status, metrics: DuoGlyphMetrics.standard.sized(90).withRingThickness(scale),
                             animationsEnabled: false, batteryColorCodingEnabled: true, batteryLevelColorsEnabled: true)
            }
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
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-Thickness.png"), options: .atomic)
    }
}
