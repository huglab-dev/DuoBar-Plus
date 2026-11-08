import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class BatteryModuleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "BatteryModuleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func battery(_ percentage: Int, pluggedIn: Bool = false, lowPower: Bool = false, full: Bool = false) -> BatteryStatus {
        var status = BatteryStatus(
            percentage: percentage,
            isCharging: pluggedIn && !full,
            isPluggedIn: pluggedIn,
            isFullyCharged: full,
            isAvailable: true
        )
        status.isLowPowerModeEnabled = lowPower
        return status
    }

    private func role(_ battery: BatteryStatus, _ mode: BatteryRingColorMode) -> BatteryRingColorRole {
        BatteryRingPresentation.resolve(
            battery: battery,
            colorCodingEnabled: mode.colorCodingEnabled,
            levelColorsEnabled: mode.levelColorsEnabled
        ).colorRole
    }

    // MARK: Colors

    func testByLevelBoundaries() {
        XCTAssertEqual(role(battery(100), .byLevel), .levelHigh)
        XCTAssertEqual(role(battery(50), .byLevel), .levelHigh)
        XCTAssertEqual(role(battery(49), .byLevel), .levelMedium)
        XCTAssertEqual(role(battery(20), .byLevel), .levelMedium)
        XCTAssertEqual(role(battery(19), .byLevel), .levelLow)
        XCTAssertEqual(role(battery(10), .byLevel), .levelLow)
        XCTAssertEqual(role(battery(9), .byLevel), .lowBattery)
        XCTAssertEqual(role(battery(0), .byLevel), .lowBattery)
    }

    func testChargingAndLowPowerOverrideLevel() {
        XCTAssertEqual(role(battery(5, pluggedIn: true), .byLevel), .charging)
        XCTAssertEqual(role(battery(80, lowPower: true), .byLevel), .lowPowerMode)
        XCTAssertEqual(role(battery(5, lowPower: true), .byLevel), .lowPowerMode)
        XCTAssertEqual(role(battery(100, pluggedIn: true, full: true), .byLevel), .levelHigh)
    }

    func testLowOnlyIsUpstreamColorCoding() {
        XCTAssertEqual(role(battery(80), .lowOnly), .monochrome)
        XCTAssertEqual(role(battery(20), .lowOnly), .monochrome)
        XCTAssertEqual(role(battery(19), .lowOnly), .lowBattery)
        XCTAssertEqual(role(battery(50, pluggedIn: true), .lowOnly), .charging)
        XCTAssertEqual(role(battery(50, lowPower: true), .lowOnly), .lowPowerMode)
        XCTAssertEqual(role(battery(100, pluggedIn: true, full: true), .lowOnly), .monochrome)
        // Identical to the upstream call without the new parameter.
        for percentage in [5, 15, 19, 20, 60] {
            XCTAssertEqual(
                role(battery(percentage), .lowOnly),
                BatteryRingPresentation.resolve(battery: battery(percentage), colorCodingEnabled: true).colorRole
            )
        }
    }

    func testMonochromeNeverColors() {
        for status in [battery(5), battery(50, pluggedIn: true), battery(80, lowPower: true), battery(100, pluggedIn: true, full: true)] {
            XCTAssertEqual(role(status, .monochrome), .monochrome)
        }
    }

    func testModeRoundTripsThroughGlyphFlags() {
        for mode in BatteryRingColorMode.allCases {
            XCTAssertEqual(BatteryRingColorMode(colorCodingEnabled: mode.colorCodingEnabled, levelColorsEnabled: mode.levelColorsEnabled), mode)
        }
    }

    func testMigration() {
        BatteryRingColorMode.migrate(defaults: defaults, persistedLegacyValue: nil)
        XCTAssertEqual(BatteryRingColorMode.current(in: defaults), .byLevel)
        XCTAssertEqual(defaults.object(forKey: PreferenceKeys.batteryColorCoding) as? Bool, true)

        BatteryRingColorMode.migrate(defaults: defaults, persistedLegacyValue: false)
        XCTAssertEqual(BatteryRingColorMode.current(in: defaults), .byLevel, "an existing choice is never overwritten")

        defaults.removeObject(forKey: BatteryRingColorMode.key)
        BatteryRingColorMode.migrate(defaults: defaults, persistedLegacyValue: true)
        XCTAssertEqual(BatteryRingColorMode.current(in: defaults), .lowOnly)

        defaults.removeObject(forKey: BatteryRingColorMode.key)
        BatteryRingColorMode.migrate(defaults: defaults, persistedLegacyValue: false)
        XCTAssertEqual(BatteryRingColorMode.current(in: defaults), .monochrome)
        XCTAssertEqual(defaults.object(forKey: PreferenceKeys.batteryColorCoding) as? Bool, false)
    }

    // MARK: Health

    func testMaximumCapacityRoundsUpLikeSystemInformation() {
        XCTAssertEqual(BatteryHealth(designCapacity: 6249, fullChargeCapacity: 5702, cycleCount: 237).maximumCapacityPercent, 92)
        XCTAssertEqual(BatteryHealth(designCapacity: 5000, fullChargeCapacity: 5200, cycleCount: 1).maximumCapacityPercent, 100)
        XCTAssertNil(BatteryHealth(designCapacity: 0, fullChargeCapacity: 5000, cycleCount: nil).maximumCapacityPercent)
    }

    func testModuleReadsOnOpenAndObservesOnlyWhileOpen() {
        let reader = FakeBatteryDetailReader()
        let module = BatteryModule(hasInternalBattery: true, reader: reader)
        module.activate()
        XCTAssertEqual(reader.healthReads, 0)
        XCTAssertFalse(module.isObservingPowerSources)

        module.popoverDidOpen()
        XCTAssertTrue(module.isObservingPowerSources)
        waitUntil { module.health != nil && module.adapter != nil }
        XCTAssertEqual(module.health?.maximumCapacityPercent, 92)
        XCTAssertEqual(module.adapter?.watts, 96)

        module.popoverDidClose()
        XCTAssertFalse(module.isObservingPowerSources)

        module.popoverDidOpen()
        module.deactivate()
        XCTAssertFalse(module.isObservingPowerSources)
    }

    func testRealReaderOnThisMac() throws {
        guard DeviceContextService().current().hasInternalBattery else {
            throw XCTSkip("No internal battery")
        }
        let health = try XCTUnwrap(BatteryDetailReader().health())
        XCTAssertGreaterThan(health.designCapacity, 0)
        XCTAssertNotNil(health.maximumCapacityPercent)
        XCTAssertNotNil(health.cycleCount)
    }

    func testRenderLevelColorGallery() throws {
        let levels: [(Int, Bool, Bool)] = [(80, false, false), (35, false, false), (15, false, false), (5, false, false), (60, true, false), (60, false, true)]
        let view = HStack(spacing: 10) {
            ForEach(Array(levels.enumerated()), id: \.offset) { _, item in
                DuoGlyphView(
                    status: SystemStatus(
                        battery: self.battery(item.0, pluggedIn: item.1, lowPower: item.2),
                        network: .unavailable,
                        audio: .unavailable,
                        bluetooth: .unavailable
                    ),
                    animationsEnabled: false,
                    batteryColorCodingEnabled: true,
                    batteryLevelColorsEnabled: true
                )
                .frame(width: 40, height: 40)
            }
        }
        .padding(10)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-BatteryColors.png"), options: .atomic)
    }

    // MARK: Percentage placement

    func testPercentageBesideOnlyWhenChosenAndAvailable() {
        let status = battery(82)
        XCTAssertEqual(MenuBarBatteryPercentage.visiblePercentage(battery: status, isEnabled: true, placement: .beside), 82)
        XCTAssertNil(MenuBarBatteryPercentage.visiblePercentage(battery: status, isEnabled: true, placement: .inside))
        XCTAssertNil(MenuBarBatteryPercentage.visiblePercentage(battery: status, isEnabled: false, placement: .beside))
        XCTAssertNil(MenuBarBatteryPercentage.visiblePercentage(battery: .unavailable, isEnabled: true, placement: .beside))
        // A full MacBook on power switches to the Adaptive Ring; the text stays.
        XCTAssertEqual(MenuBarBatteryPercentage.visiblePercentage(battery: battery(100, pluggedIn: true, full: true), isEnabled: true, placement: .beside), 100)
        XCTAssertEqual(MenuBarBatteryPercentage.extraWidth(for: nil), 0)
    }

    func testPercentageWidthOnlyChangesWithDigitCount() {
        XCTAssertEqual(MenuBarBatteryPercentage.textWidth(for: 82), MenuBarBatteryPercentage.textWidth(for: 47))
        XCTAssertEqual(MenuBarBatteryPercentage.textWidth(for: 11), MenuBarBatteryPercentage.textWidth(for: 88))
        XCTAssertGreaterThan(MenuBarBatteryPercentage.textWidth(for: 100), MenuBarBatteryPercentage.textWidth(for: 99))
        XCTAssertEqual(BatteryPercentagePlacement.current(in: defaults), .inside, "upstream placement is the default")
    }

    func testRenderPercentagePlacements() throws {
        let status = SystemStatus(battery: battery(82), network: .unavailable, audio: .unavailable, bluetooth: .unavailable)
        let view = HStack(spacing: 24) {
            DuoGlyphView(status: status, animationsEnabled: false, showBatteryPercentage: true)
                .frame(width: 27, height: 22)
            HStack(spacing: MenuBarBatteryPercentage.spacing) {
                DuoGlyphView(status: status, animationsEnabled: false)
                    .frame(width: 27, height: 22)
                MenuBarBatteryPercentageText(percentage: 82)
            }
        }
        .padding(8)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)

        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-PercentagePlacement.png"), options: .atomic)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout) s", file: file, line: line)
    }
}

final class FakeBatteryDetailReader: BatteryDetailReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _healthReads = 0
    var healthReads: Int { lock.withLock { _healthReads } }

    func health() -> BatteryHealth? {
        lock.withLock { _healthReads += 1 }
        return BatteryHealth(designCapacity: 6249, fullChargeCapacity: 5702, cycleCount: 237)
    }

    func adapter() -> PowerAdapterInfo? {
        PowerAdapterInfo(watts: 96, name: "96W USB-C Power Adapter")
    }
}
