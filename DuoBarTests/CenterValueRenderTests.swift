import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class CenterValueRenderTests: XCTestCase {
    func testRenderLargeCenterValue() throws {
        let view = DuoGlyphView(
            status: IndicatorSettingsView.sampleStatus,
            metrics: DuoGlyphMetrics.standard.sized(160),
            animationsEnabled: false,
            centerStateOverride: .value(90)
        )
        .frame(width: 180, height: 180)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-CenterValue.png"), options: .atomic)
    }
}
