import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class UnfoldOnHoverTests: XCTestCase {
    private let values = GlyphSlotValues(cpu: 0.12, memory: 0.85, disk: 0.77, networkBytesPerSecond: 12_000)
    private var status: SystemStatus { IndicatorSettingsView.sampleStatus }

    func testSegmentsFollowDotsCenterRing() {
        let standard = UnfoldSegmentBuilder.segments(configuration: .standard, status: status, values: values)
        XCTAssertEqual(standard.map(\.id), ["volume", "network", "battery"])
        XCTAssertEqual(standard.map(\.target), [nil, .network, .battery])

        let pictured = GlyphConfiguration(ring: .battery, center: .network, dots: .network, color: .automatic)
        let segments = UnfoldSegmentBuilder.segments(configuration: pictured, status: status, values: values)
        XCTAssertEqual(segments.map(\.id), ["rate", "network", "battery"])
        XCTAssertEqual(segments.first?.kind, .networkRate(12_000))
    }

    func testRateText() {
        XCTAssertEqual(UnfoldSegmentView.rateText(12_000), "\(NetworkSpeedFormatter.compact(12_000).dropLast()) KB/s")
        XCTAssertEqual(UnfoldSegmentView.rateText(0), "0 B/s")
    }

    func testDuplicatesAndMissingBatteryAreSkipped() {
        let configuration = GlyphConfiguration(ring: .battery, center: .battery, dots: .battery, color: .automatic)
        XCTAssertEqual(UnfoldSegmentBuilder.segments(configuration: configuration, status: status, values: values).map(\.id), ["battery"])

        var desktop = status
        desktop.battery = .unavailable
        XCTAssertEqual(UnfoldSegmentBuilder.segments(configuration: .standard, status: desktop, values: values).map(\.id), ["volume", "network"])

        let metrics = GlyphConfiguration(ring: .memory, center: .cpu, dots: .none, color: .automatic)
        XCTAssertEqual(UnfoldSegmentBuilder.segments(configuration: metrics, status: status, values: values).map(\.target), [.system, .system])
    }

    func testPopoverAnimationSetting() {
        let suite = "UnfoldOnHoverTests.motion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(PopoverMotion.isEnabled(in: defaults), "on by default")
        XCTAssertEqual(PopoverMotion.closeDelay(in: defaults), PopoverMotion.closeDuration + 0.03, accuracy: 0.0001)
        defaults.set(false, forKey: PopoverMotion.enabledKey)
        XCTAssertFalse(PopoverMotion.isEnabled(in: defaults))
        XCTAssertEqual(PopoverMotion.closeDelay(in: defaults), 0, "hides at once")
    }

    func testHoverDelayDefaultAndClamping() {
        let suite = "UnfoldOnHoverTests.delay.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HoverDelay.seconds(in: defaults), 0.15)
        defaults.set(0.6, forKey: HoverDelay.key)
        XCTAssertEqual(HoverDelay.seconds(in: defaults), 0.6)
        defaults.set(5.0, forKey: HoverDelay.key)
        XCTAssertEqual(HoverDelay.seconds(in: defaults), 1.0)
    }

    func testUnfoldWaitsForTheHoverDelay() {
        let suite = "UnfoldOnHoverTests.wait.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: UnfoldOnHover.key)
        defaults.set(0.5, forKey: HoverDelay.key)
        let state = StatusItemHoverState(defaults: defaults)
        state.pointerChanged(isInside: true)
        spin(0.3)
        XCTAssertFalse(state.isUnfolded, "not before the delay")
        spin(0.4)
        XCTAssertTrue(state.isUnfolded)
    }

    func testHoverActionKeepsBothKeysExclusive() {
        let suite = "UnfoldOnHoverTests.action.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(HoverAction.current(in: defaults), .none)

        HoverAction.openPopover.store(in: defaults)
        XCTAssertEqual(HoverAction.current(in: defaults), .openPopover)
        XCTAssertTrue(defaults.bool(forKey: PreferenceKeys.openOnHover))
        XCTAssertFalse(UnfoldOnHover.isEnabled(in: defaults))

        HoverAction.unfold.store(in: defaults)
        XCTAssertEqual(HoverAction.current(in: defaults), .unfold)
        XCTAssertFalse(defaults.bool(forKey: PreferenceKeys.openOnHover), "unfold replaces Open on Hover")

        HoverAction.none.store(in: defaults)
        XCTAssertEqual(HoverAction.current(in: defaults), .none)
    }

    func testHoverUnfoldsOnlyWhenEnabledAndFoldsAfterLeaving() {
        let suite = "UnfoldOnHoverTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = StatusItemHoverState(defaults: defaults)

        state.pointerChanged(isInside: true)
        spin(0.3)
        XCTAssertFalse(state.isUnfolded, "off by default")

        defaults.set(true, forKey: UnfoldOnHover.key)
        state.pointerChanged(isInside: true)
        spin(0.3)
        XCTAssertTrue(state.isUnfolded)

        state.setSegmentFrames([(0...40, .network), (52...90, .battery)])
        XCTAssertEqual(state.segment(atX: 20)?.target, .network)
        XCTAssertEqual(state.segment(atX: 60)?.target, .battery)
        XCTAssertNil(state.segment(atX: 46))

        state.pointerChanged(isInside: false)
        spin(0.2)
        XCTAssertTrue(state.isUnfolded, "folds only after a short delay")
        spin(0.5)
        XCTAssertFalse(state.isUnfolded)
        XCTAssertNil(state.segment(atX: 20), "no hits while folded")
    }

    func testRenderUnfoldedMark() throws {
        let segments = UnfoldSegmentBuilder.segments(
            configuration: GlyphConfiguration(ring: .battery, center: .network, dots: .network, color: .automatic),
            status: status,
            values: values
        )
        let view = UnfoldedStatusView(segments: segments) { _ in }
            .padding(10)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-Unfolded.png"), options: .atomic)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}
