import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class GlyphComposerTests: XCTestCase {
    private var status: SystemStatus { IndicatorSettingsView.sampleStatus }
    private let values = GlyphSlotValues(cpu: 0.9, memory: 0.5, disk: 0.77, networkBytesPerSecond: 12_000)

    private func compose(_ configuration: GlyphConfiguration, event: StatusEvent? = nil, status: SystemStatus? = nil) -> GlyphComposition {
        GlyphComposer.compose(configuration: configuration, status: status ?? self.status, values: values, event: event, batteryColorMode: .byLevel)
    }

    func testStandardConfigurationChangesNothing() {
        XCTAssertEqual(compose(.standard), .unchanged)
        XCTAssertTrue(GlyphConfiguration.standard.neededMetrics.isEmpty, "standard slots sample nothing")
    }

    func testCPURingCenterAndDots() {
        let composition = compose(GlyphConfiguration(ring: .cpu, center: .cpu, dots: .cpu, color: .automatic))
        XCTAssertEqual(composition.ring?.mode, .adaptive)
        XCTAssertEqual(composition.ring?.progress ?? 0, 0.9, accuracy: 0.001)
        XCTAssertEqual(composition.ringColor, Color(nsColor: .systemOrange))
        XCTAssertEqual(composition.center, .value(90))
        XCTAssertEqual(composition.dots, 4)
        XCTAssertFalse(composition.usesAutomaticRing)
        XCTAssertEqual(GlyphConfiguration(ring: .cpu, center: .cpu, dots: .cpu, color: .automatic).neededMetrics, [.cpu])
    }

    func testNetworkDotsAreLogarithmic() {
        XCTAssertEqual(GlyphComposer.networkDots(nil), 0)
        XCTAssertEqual(GlyphComposer.networkDots(500), 0)
        XCTAssertEqual(GlyphComposer.networkDots(12_000), 1)
        XCTAssertEqual(GlyphComposer.networkDots(250_000), 2)
        XCTAssertEqual(GlyphComposer.networkDots(5_000_000), 3)
        XCTAssertEqual(GlyphComposer.networkDots(50_000_000), 4)
        XCTAssertEqual(compose(GlyphConfiguration(ring: .automatic, center: .network, dots: .network, color: .automatic)).dots, 1)
    }

    func testOtherDotsAndCenters() {
        XCTAssertEqual(GlyphComposer.fractionDots(0.9), 4)
        XCTAssertEqual(GlyphComposer.fractionDots(0.26), 2)
        XCTAssertEqual(GlyphComposer.fractionDots(0), 0)
        let battery = compose(GlyphConfiguration(ring: .battery, center: .battery, dots: .battery, color: .automatic))
        XCTAssertEqual(battery.center, .value(90))
        XCTAssertEqual(battery.dots, 4)
        XCTAssertEqual(battery.ring?.mode, .battery)
        XCTAssertEqual(compose(GlyphConfiguration(ring: .none, center: .none, dots: .none, color: .automatic)).center, .empty)
        XCTAssertEqual(compose(GlyphConfiguration(ring: .none, center: .none, dots: .none, color: .automatic)).ring?.opacity, 0)
    }

    func testColorStyles() {
        let mono = compose(GlyphConfiguration(ring: .automatic, center: .network, dots: .volume, color: .monochrome))
        XCTAssertEqual(mono.batteryColorCoding, false)
        XCTAssertEqual(mono.ringColor, .primary)
        let accent = compose(GlyphConfiguration(ring: .memory, center: .network, dots: .volume, color: .accent))
        XCTAssertEqual(accent.ringColor, .accentColor)
        XCTAssertNil(GlyphComposer.loadColor(0.5, style: .automatic))
        XCTAssertEqual(GlyphComposer.loadColor(0.97, style: .automatic), Color(nsColor: .systemRed))
    }

    func testCustomColor() throws {
        let pink = GlyphConfiguration(ring: .automatic, center: .network, dots: .volume, color: .custom, customColorHex: "#FF2D55")
        let composition = compose(pink)
        XCTAssertEqual(composition.batteryColorCoding, false)
        XCTAssertEqual(composition.ringColor, HexColor.color("#FF2D55"))
        XCTAssertEqual(compose(GlyphConfiguration(ring: .cpu, center: .network, dots: .volume, color: .custom, customColorHex: "#FF2D55")).ringColor, HexColor.color("#FF2D55"))
        XCTAssertEqual(compose(GlyphConfiguration(ring: .battery, center: .network, dots: .volume, color: .custom, customColorHex: "#FF2D55")).ringColor, HexColor.color("#FF2D55"))
        XCTAssertFalse(pink.isStandard)

        let color = try XCTUnwrap(HexColor.nsColor("#FF2D55"))
        XCTAssertEqual(HexColor.hex(color), "#FF2D55")
        XCTAssertEqual(HexColor.hex(try XCTUnwrap(HexColor.nsColor("34c759"))), "#34C759")
        XCTAssertNil(HexColor.nsColor("#12"))
        XCTAssertEqual(GlyphConfiguration(ring: .automatic, center: .network, dots: .volume, color: .custom, customColorHex: "bad").fixedRingColor, .accentColor)
    }

    func testLiveMomentsWinOverSlots() {
        var low = status
        low.battery.percentage = 10
        let lowEvent = StatusEvent(kind: .lowBattery, priority: .critical)
        let lowComposition = compose(GlyphConfiguration(ring: .cpu, center: .cpu, dots: .network, color: .automatic), event: lowEvent, status: low)
        XCTAssertEqual(lowComposition.ring?.mode, .battery, "the ring turns into the red battery ring")
        XCTAssertEqual(lowComposition.ring?.batteryPresentation.colorRole, .lowBattery)
        XCTAssertNil(lowComposition.center, "the moment decides the center")

        let volumeEvent = StatusEvent(kind: .volumeChanged, priority: .informational)
        XCTAssertEqual(compose(GlyphConfiguration(ring: .automatic, center: .network, dots: .network, color: .automatic), event: volumeEvent).dots, 2, "50 % volume")
    }

    func testSamplerIsIdleWithStandardSlotsAndSamplesOnlyWhatIsNeeded() {
        let suite = "GlyphComposerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let stats = FakeSystemStatsReader()
        let sampler = GlyphSlotSampler(statsReader: stats, counterReader: { _ in nil }, defaults: defaults, interval: 0.05)
        sampler.start()
        XCTAssertFalse(sampler.isSampling)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(stats.tickReads, 0)

        defaults.set(DotsSlot.cpu.rawValue, forKey: DotsSlot.key)
        let deadline = Date().addingTimeInterval(2)
        while sampler.cpu == nil, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertTrue(sampler.isSampling)
        XCTAssertNotNil(sampler.cpu)
        XCTAssertNil(sampler.memory)

        defaults.set(DotsSlot.volume.rawValue, forKey: DotsSlot.key)
        let stop = Date().addingTimeInterval(2)
        while sampler.isSampling, Date() < stop { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        XCTAssertFalse(sampler.isSampling)
        XCTAssertNil(sampler.cpu)
    }

    func testRenderConfigurationsAndMoments() throws {
        let configurations: [(GlyphConfiguration, StatusEvent?)] = [
            (.standard, nil),
            (GlyphConfiguration(ring: .battery, center: .network, dots: .network, color: .automatic), nil),
            (GlyphConfiguration(ring: .cpu, center: .cpu, dots: .cpu, color: .automatic), nil),
            (GlyphConfiguration(ring: .disk, center: .battery, dots: .wifiSignal, color: .accent), nil),
            (GlyphConfiguration(ring: .automatic, center: .network, dots: .volume, color: .custom, customColorHex: "#FF2D55"), nil),
            (GlyphConfiguration(ring: .memory, center: .network, dots: .network, color: .custom, customColorHex: "#AF52DE"), nil),
            (.standard, StatusEvent(kind: .charging, priority: .informational)),
            (.standard, StatusEvent(kind: .audioDeviceConnected(.previewAirPods), priority: .informational)),
            (.standard, StatusEvent(kind: .lowBattery, priority: .critical)),
        ]
        var low = status
        low.battery.percentage = 10
        let normal = status
        let values = self.values
        let view = HStack(spacing: 14) {
            ForEach(Array(configurations.enumerated()), id: \.offset) { _, item in
                let glyphStatus = item.1?.kind == .lowBattery ? low : normal
                let composition = GlyphComposer.compose(configuration: item.0, status: glyphStatus, values: values, event: item.1, batteryColorMode: .byLevel)
                DuoGlyphView(
                    status: glyphStatus,
                    presentation: item.1.map(StatusPresentation.event) ?? .normal,
                    metrics: DuoGlyphMetrics.standard.sized(56),
                    animationsEnabled: false,
                    ringPresentation: composition.ring,
                    centerStateOverride: composition.center,
                    ringColorOverride: composition.ringColor,
                    batteryColorCodingEnabled: composition.batteryColorCoding ?? true,
                    batteryLevelColorsEnabled: composition.batteryLevelColors ?? true,
                    liveMomentCenters: true,
                    dotCountOverride: composition.dots
                )
                .frame(width: 64, height: 64)
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
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-GlyphSlots.png"), options: .atomic)
    }

    func testRenderIndicatorTab() throws {
        let hostingView = NSHostingView(rootView: IndicatorSettingsView())
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 640)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-IndicatorTab.png"), options: .atomic)
    }
}
