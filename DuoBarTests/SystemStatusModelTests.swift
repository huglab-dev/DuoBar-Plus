import XCTest
@testable import DuoBar

final class SystemStatusModelTests: XCTestCase {
    func testWiFiSignalLevelBoundaries() {
        let cases: [(Int, WiFiSignalLevel)] = [
            (-40, .strong),
            (-60, .strong),
            (-63, .strong),
            (-67, .strong),
            (-68, .medium),
            (-72, .medium),
            (-75, .medium),
            (-76, .weak),
            (-85, .weak)
        ]

        for (rssi, expectedLevel) in cases {
            XCTAssertEqual(wifi(rssi: rssi).wifiSignalLevel, expectedLevel, "RSSI \(rssi)")
        }
    }

    func testWiFiUnknownAndDisconnectedStatesPreserveFallbackBehavior() {
        XCTAssertEqual(wifi(rssi: nil).wifiSignalLevel, .medium)
        XCTAssertEqual(wifi(rssi: nil, connected: false).wifiSignalLevel, .disconnected)

        var disabled = wifi(rssi: nil, connected: false)
        disabled.isWiFiPoweredOn = false
        XCTAssertEqual(disabled.wifiSignalLevel, .disabled)
        XCTAssertEqual(NetworkStatus.unavailable.wifiSignalLevel, .unavailable)
    }

    func testVolumeDotBoundaries() {
        let cases: [(Double, Int)] = [
            (0, 0), (0.01, 1), (0.25, 1), (0.26, 2), (0.50, 2),
            (0.51, 3), (0.75, 3), (0.76, 4), (1, 4)
        ]
        for (level, expectedDots) in cases {
            let volume = OutputVolumeStatus(level: level, isMuted: false, isSettable: true)
            XCTAssertEqual(volume.activeDotCount, expectedDots, "level \(level)")
        }
    }

    func testMutedVolumeAlwaysUsesZeroDots() {
        XCTAssertEqual(OutputVolumeStatus(level: 0.9, isMuted: true, isSettable: true).activeDotCount, 0)
    }

    func testUnavailableVolumeHasNoDotCount() {
        XCTAssertNil(OutputVolumeStatus.unavailable.activeDotCount)
    }

    func testValidatedModelUIDUsesAirPodsProFamily() {
        let device = makeDevice(name: "Renamed Headphones", modelUID: "  2027   4C ", manufacturer: nil)
        XCTAssertEqual(device.temporaryConnectionGlyph, .airPodsPro)
    }

    func testAirPodsProNameFallbackUsesAirPodsProFamily() {
        let device = makeDevice(name: "Alex’s AirPods Pro", manufacturer: "Apple Inc.")
        XCTAssertEqual(device.temporaryConnectionGlyph, .airPodsPro)
    }

    func testAirPodsMaxUsesAirPodsMaxFamily() {
        let device = makeDevice(name: "AirPods Max", manufacturer: "Apple Inc.")
        XCTAssertEqual(device.temporaryConnectionGlyph, .airPodsMax)
    }

    func testGenericAirPodsUsesRegularAirPodsFamily() {
        let device = makeDevice(name: "Travel AirPods", manufacturer: "Apple Inc.")
        XCTAssertEqual(device.temporaryConnectionGlyph, .airPods)
    }

    func testGenericBluetoothHeadphonesUseHeadphonesFamily() {
        let device = makeDevice(name: "WH-1000XM5", manufacturer: "Sony")
        XCTAssertEqual(device.temporaryConnectionGlyph, .headphones)
    }

    func testUnknownOutputUsesGenericAudioDeviceFamily() {
        let device = AudioDeviceStatus(uid: "unknown", name: "Audio Device", transport: .other, isAlive: true)
        XCTAssertEqual(device.temporaryConnectionGlyph, .audioDevice)
    }

    private func makeDevice(
        name: String,
        modelUID: String? = nil,
        manufacturer: String?
    ) -> AudioDeviceStatus {
        AudioDeviceStatus(
            uid: "test-device",
            name: name,
            transport: .bluetooth,
            isAlive: true,
            modelUID: modelUID,
            manufacturer: manufacturer,
            terminalType: .headphones
        )
    }

    private func wifi(rssi: Int?, connected: Bool = true) -> NetworkStatus {
        NetworkStatus(
            isAvailable: true,
            isConnected: connected,
            transport: .wifi,
            interfaceName: "en0",
            isWiFiPoweredOn: true,
            ssid: connected ? "Test" : nil,
            rssi: connected ? rssi : nil
        )
    }
}
