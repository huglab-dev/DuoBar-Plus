import XCTest
@testable import DuoBar

final class StatusEventDetectorTests: XCTestCase {
    func testChargingTransitionCreatesInformationalEvent() {
        let old = makeStatus(battery: battery(percentage: 50, charging: false))
        let new = makeStatus(battery: battery(percentage: 51, charging: true))
        let events = StatusEventDetector.events(from: old, to: new)
        XCTAssertEqual(events.map(\.kind), [.charging])
        XCTAssertEqual(events.first?.priority, .informational)
    }

    func testInitialServicePopulationDoesNotCreateDisconnectOrAudioEvents() {
        let new = makeStatus(
            battery: battery(percentage: 80, charging: false),
            network: network(connected: false),
            audio: bluetoothAudio(name: "AirPods Pro")
        )
        XCTAssertTrue(StatusEventDetector.events(from: .unavailable, to: new).isEmpty)
    }

    func testDisconnectAndLowBatteryAreSortedByPriority() {
        let old = makeStatus(battery: battery(percentage: 20, charging: false), network: network(connected: true))
        let new = makeStatus(battery: battery(percentage: 8, charging: false), network: network(connected: false))
        XCTAssertEqual(StatusEventDetector.events(from: old, to: new).map(\.kind), [.lowBattery, .networkDisconnected])
    }

    func testBluetoothPowerChangeDoesNotCreateVisibleEvent() {
        let old = makeStatus(bluetooth: BluetoothStatus(isAvailable: true, isPoweredOn: true))
        let new = makeStatus(bluetooth: BluetoothStatus(isAvailable: true, isPoweredOn: false))
        XCTAssertTrue(StatusEventDetector.events(from: old, to: new).isEmpty)
    }

    func testBluetoothAudioConnectionCreatesShortInformationalEvent() throws {
        let old = makeStatus(audio: availableBuiltInAudio())
        let new = makeStatus(audio: bluetoothAudio(name: "AirPods Pro"))
        let event = try XCTUnwrap(StatusEventDetector.events(from: old, to: new).first)
        guard case let .audioDeviceConnected(device) = event.kind else {
            return XCTFail("Expected audio device connection event")
        }
        XCTAssertEqual(device.name, "AirPods Pro")
        XCTAssertEqual(device.temporaryGlyph, .airPods)
        XCTAssertEqual(event.priority, .informational)
        XCTAssertEqual(event.duration, 1.45, accuracy: 0.001)
    }

    func testNetworkSignalStrengthIsClamped() {
        XCTAssertEqual(network(rssi: -30).signalStrength, 1)
        XCTAssertEqual(network(rssi: -100).signalStrength, 0)
        XCTAssertNil(network(connected: false, rssi: nil).signalStrength)
    }

    private func makeStatus(
        battery: BatteryStatus = .unavailable,
        network: NetworkStatus = .unavailable,
        audio: AudioStatus = .unavailable,
        bluetooth: BluetoothStatus = .unavailable
    ) -> SystemStatus {
        SystemStatus(battery: battery, network: network, audio: audio, bluetooth: bluetooth)
    }

    private func battery(percentage: Int, charging: Bool) -> BatteryStatus {
        BatteryStatus(percentage: percentage, isCharging: charging, isPluggedIn: charging, isFullyCharged: false, isAvailable: true)
    }

    private func network(connected: Bool = true, rssi: Int? = -45) -> NetworkStatus {
        NetworkStatus(
            isAvailable: true,
            isConnected: connected,
            transport: .wifi,
            interfaceName: "en0",
            isWiFiPoweredOn: true,
            ssid: connected ? "Studio" : nil,
            rssi: connected ? rssi : nil
        )
    }

    private func availableBuiltInAudio() -> AudioStatus {
        let device = AudioDeviceStatus(uid: "built-in", name: "MacBook Speakers", transport: .builtIn, isAlive: true)
        return AudioStatus(
            isAvailable: true,
            defaultOutput: device,
            volume: OutputVolumeStatus(level: 0.5, isMuted: false, isSettable: true),
            connectedBluetoothOutputs: []
        )
    }

    private func bluetoothAudio(name: String) -> AudioStatus {
        let device = AudioDeviceStatus(uid: "bluetooth-output", name: name, transport: .bluetooth, isAlive: true)
        return AudioStatus(
            isAvailable: true,
            defaultOutput: device,
            volume: OutputVolumeStatus(level: 0.5, isMuted: false, isSettable: true),
            connectedBluetoothOutputs: [device]
        )
    }
}
