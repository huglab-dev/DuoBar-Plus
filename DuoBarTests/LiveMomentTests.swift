import XCTest
@testable import DuoBar

final class LiveMomentTests: XCTestCase {
    private func status(battery: BatteryStatus = .unavailable, volume: Double? = nil, muted: Bool = false) -> SystemStatus {
        var audio = AudioStatus.unavailable
        audio.volume = OutputVolumeStatus(level: volume, isMuted: muted, isSettable: true)
        return SystemStatus(battery: battery, network: .unavailable, audio: audio, bluetooth: .unavailable)
    }

    private func battery(_ percent: Int, charging: Bool = false, plugged: Bool = false, full: Bool = false) -> BatteryStatus {
        BatteryStatus(percentage: percent, isCharging: charging, isPluggedIn: plugged, isFullyCharged: full, isAvailable: true)
    }

    func testPluggingInAFullBatteryIsAMoment() {
        let events = StatusEventDetector.events(
            from: status(battery: battery(100, full: true)),
            to: status(battery: battery(100, plugged: true, full: true))
        )
        XCTAssertEqual(events.map(\.kind), [.charging])
    }

    func testLowBatteryAtTwentyAndTen() {
        let twenty = StatusEventDetector.events(from: status(battery: battery(21)), to: status(battery: battery(20)))
        XCTAssertEqual(twenty.map(\.kind), [.lowBattery])
        XCTAssertEqual(twenty.first?.priority, .attention)

        let ten = StatusEventDetector.events(from: status(battery: battery(11)), to: status(battery: battery(10)))
        XCTAssertEqual(ten.map(\.kind), [.lowBattery])
        XCTAssertEqual(ten.first?.priority, .critical)

        XCTAssertTrue(StatusEventDetector.events(from: status(battery: battery(19)), to: status(battery: battery(18))).isEmpty)
    }

    func testVolumeChangeAfterFirstReading() {
        XCTAssertTrue(StatusEventDetector.events(from: status(), to: status(volume: 0.5)).isEmpty, "first reading is not a change")
        XCTAssertEqual(StatusEventDetector.events(from: status(volume: 0.5), to: status(volume: 0.6)).map(\.kind), [.volumeChanged])
        XCTAssertEqual(StatusEventDetector.events(from: status(volume: 0.5), to: status(volume: 0.5, muted: true)).map(\.kind), [.volumeChanged])
    }

    func testTogglesAndVolumeRule() {
        let suite = "LiveMomentTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let charging = StatusEvent(kind: .charging, priority: .informational)
        let volume = StatusEvent(kind: .volumeChanged, priority: .informational)

        XCTAssertTrue(LiveMoment.allows(charging, dots: .volume, defaults: defaults))
        XCTAssertFalse(LiveMoment.allows(volume, dots: .volume, defaults: defaults), "dots already show the volume")
        XCTAssertTrue(LiveMoment.allows(volume, dots: .network, defaults: defaults))

        defaults.set(false, forKey: LiveMoment.pluggedIn.key)
        XCTAssertFalse(LiveMoment.allows(charging, dots: .volume, defaults: defaults))
    }

    func testCentersOnlyWithLiveMomentsEnabled() {
        let plugged = status(battery: battery(50, charging: true, plugged: true))
        let event = StatusPresentation.event(StatusEvent(kind: .charging, priority: .informational))
        XCTAssertEqual(DuoGlyphState(status: plugged, presentation: event, liveMomentCenters: true).centerState, .charging)
        XCTAssertNotEqual(DuoGlyphState(status: plugged, presentation: event).centerState, .charging, "upstream behavior by default")
        XCTAssertEqual(
            DuoGlyphState(status: plugged, presentation: event, centerStateOverride: .adaptiveEntry, liveMomentCenters: true).centerState,
            .adaptiveEntry,
            "the Adaptive Ring entry still wins over the charging moment"
        )

        let low = status(battery: battery(10))
        let lowEvent = StatusPresentation.event(StatusEvent(kind: .lowBattery, priority: .critical))
        XCTAssertEqual(DuoGlyphState(status: low, presentation: lowEvent, liveMomentCenters: true).centerState, .value(10))
        XCTAssertEqual(DuoGlyphState(status: low, dotCountOverride: 2).volumeActiveDotCount, 2)
    }
}
