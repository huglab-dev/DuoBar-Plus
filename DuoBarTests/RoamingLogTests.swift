import XCTest
@testable import DuoBar

@MainActor
final class RoamingLogTests: XCTestCase {
    private func ap(_ bssid: String?, channel: Int? = 36, rssi: Int = -60) -> AccessPointSnapshot {
        AccessPointSnapshot(ssid: "Office", bssid: bssid, channel: channel, band: .ghz5, rssi: rssi)
    }

    func testDetector() {
        XCTAssertTrue(RoamingDetector.isRoam(from: ap("aa"), to: ap("bb")))
        XCTAssertFalse(RoamingDetector.isRoam(from: ap("aa"), to: ap("aa", rssi: -70)))
        XCTAssertFalse(RoamingDetector.isRoam(from: nil, to: ap("aa")))
        XCTAssertFalse(RoamingDetector.isRoam(from: ap("aa"), to: ap("bb", rssi: 0)), "disassociation is not a roam")
        // Without location access the BSSID is hidden; a channel change counts.
        XCTAssertTrue(RoamingDetector.isRoam(from: ap(nil, channel: 36), to: ap(nil, channel: 149)))
        XCTAssertFalse(RoamingDetector.isRoam(from: ap(nil, channel: 36), to: ap(nil, channel: 36)))
    }

    func testLogKeepsNewestFirstWithinCapacity() {
        let log = RoamingLog(capacity: 3)
        log.observe(ap("00"))
        for i in 1...5 {
            log.observe(ap(String(format: "%02d", i)))
        }
        XCTAssertEqual(log.entries.count, 3)
        XCTAssertEqual(log.entries.first?.to.bssid, "05")
        XCTAssertEqual(log.entries.first?.from.bssid, "04")
        XCTAssertEqual(log.entries.last?.to.bssid, "03")
    }

    func testDisassociationDoesNotResetBaseline() {
        let log = RoamingLog()
        log.observe(ap("aa"))
        log.observe(ap(nil, channel: nil, rssi: 0))
        log.observe(ap("bb"))
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries.first?.from.bssid, "aa")
    }

    func testModuleListensOnlyWithOptionOn() {
        let suite = "RoamingLogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let module = NetworkModule(reader: FakeWiFiDetailsReader(), addressReader: FakeAddressReader(), defaults: defaults, interval: 60)

        module.activate()
        XCTAssertFalse(module.roamingLog.isListening, "the roaming log is off by default")

        defaults.set(true, forKey: ModuleOption.roamingLog.key)
        waitUntil { module.roamingLog.isListening }

        defaults.set(false, forKey: ModuleOption.roamingLog.key)
        waitUntil { !module.roamingLog.isListening }

        defaults.set(true, forKey: ModuleOption.roamingLog.key)
        waitUntil { module.roamingLog.isListening }
        module.deactivate()
        XCTAssertFalse(module.roamingLog.isListening)
    }

    func testPopoverSamplesFeedTheLog() {
        let suite = "RoamingLogTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: ModuleOption.roamingLog.key)
        let reader = SwitchableWiFiReader()
        let module = NetworkModule(reader: reader, addressReader: FakeAddressReader(), defaults: defaults, interval: 0.05)
        module.activate()
        module.popoverDidOpen()
        waitUntil { module.wifi?.bssid == "aa:aa:aa:aa:aa:aa" }

        reader.bssid = "bb:bb:bb:bb:bb:bb"
        waitUntil { module.roamingLog.entries.contains { $0.to.bssid == "bb:bb:bb:bb:bb:bb" } }
        module.deactivate()
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout) s", file: file, line: line)
    }
}

final class SwitchableWiFiReader: WiFiDetailsReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _bssid = "aa:aa:aa:aa:aa:aa"
    var bssid: String {
        get { lock.withLock { _bssid } }
        set { lock.withLock { _bssid = newValue } }
    }

    func details() -> WiFiDetails? {
        var details = WiFiDetailsTests.sample
        details.bssid = bssid
        return details
    }
}
