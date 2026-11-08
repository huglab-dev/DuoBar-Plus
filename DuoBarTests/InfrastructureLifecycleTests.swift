import XCTest
@testable import DuoBar

final class InfrastructureLifecycleTests: XCTestCase {
    @MainActor
    func testBatteryServicePublishesAnInitialReading() {
        let service = BatteryService()
        var readings: [BatteryStatus] = []
        service.onStatusChange = { readings.append($0) }

        service.start()

        XCTAssertEqual(readings.count, 1)
    }

    @MainActor
    func testAudioOutputServicePublishesAnInitialReading() {
        let service = AudioOutputService()
        var readings: [AudioStatus] = []
        service.onStatusChange = { readings.append($0) }

        service.start()

        XCTAssertEqual(readings.count, 1)
    }

    @MainActor
    func testNetworkServicePublishesAnInitialReading() {
        let service = NetworkService()
        var readings: [NetworkStatus] = []
        service.onStatusChange = { readings.append($0) }

        service.start()

        XCTAssertEqual(readings.count, 1)
    }

    @MainActor
    func testAudioServiceReleasesItsListeners() {
        weak var weakAudio: AudioOutputService?

        autoreleasepool {
            let audio = AudioOutputService()
            weakAudio = audio
            audio.start()
        }

        XCTAssertNil(weakAudio)
    }

    @MainActor
    func testNetworkServiceReleasesItsMonitorAndTimer() {
        weak var weakNetwork: NetworkService?
        autoreleasepool {
            let network = NetworkService()
            weakNetwork = network
            network.start()
        }
        XCTAssertNil(weakNetwork)
    }

    func testOnlyOneInstanceLockCanOwnAName() {
        let lockName = "com.mikeli.duobar.tests.\(UUID().uuidString).lock"
        let first = ApplicationInstanceLock(lockFileName: lockName)
        let second = ApplicationInstanceLock(lockFileName: lockName)

        XCTAssertTrue(first.acquire())
        XCTAssertFalse(second.acquire())

        first.release()
        XCTAssertTrue(second.acquire())
    }
}
