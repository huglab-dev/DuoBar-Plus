import XCTest
@testable import DuoBar

final class WiFiPowerControlTests: XCTestCase {
    func testWiFiPowerOnRequestUsesActualOnState() {
        let controller = TestWiFiPowerController(powerState: false)
        let result = WiFiPowerControlCoordinator(controller: controller).setPower(true)

        XCTAssertEqual(result, .success(actualPowerState: true))
        XCTAssertEqual(controller.requests, [true])
    }

    func testWiFiPowerOffRequestUsesActualOffState() {
        let controller = TestWiFiPowerController(powerState: true)
        let result = WiFiPowerControlCoordinator(controller: controller).setPower(false)

        XCTAssertEqual(result, .success(actualPowerState: false))
        XCTAssertEqual(controller.requests, [false])
    }

    func testWiFiPowerFailureKeepsActualState() {
        let controller = TestWiFiPowerController(powerState: true, setError: TestError.failed)
        let result = WiFiPowerControlCoordinator(controller: controller).setPower(false)

        XCTAssertEqual(result, .failure(actualPowerState: true, message: TestError.failed.localizedDescription))
        XCTAssertEqual(controller.requests, [false])
    }

    func testWiFiPowerRequestDoesNotClaimSuccessWhenReadBackDiffers() {
        let controller = TestWiFiPowerController(powerState: true, appliesWrites: false)
        let result = WiFiPowerControlCoordinator(controller: controller).setPower(false)

        XCTAssertEqual(
            result,
            .failure(actualPowerState: true, message: WiFiPowerControlError.stateDidNotUpdate.localizedDescription)
        )
    }

    func testWiFiPowerUnavailableDoesNotAttemptWrite() {
        let controller = TestWiFiPowerController(powerState: nil)
        let result = WiFiPowerControlCoordinator(controller: controller).setPower(true)

        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(controller.requests.isEmpty)
    }

    func testSSIDAvailableAndUnavailableRemainTruthful() {
        let available = NetworkStatus(
            isAvailable: true, isConnected: true, transport: .wifi,
            interfaceName: "en0", isWiFiPoweredOn: true, ssid: "Studio", rssi: -50
        )
        let unavailable = NetworkStatus(
            isAvailable: true, isConnected: true, transport: .wifi,
            interfaceName: "en0", isWiFiPoweredOn: true, ssid: nil, rssi: -50
        )

        XCTAssertEqual(available.ssid, "Studio")
        XCTAssertNil(unavailable.ssid)
    }

    func testEthernetAndDisconnectedNetworkStatesRemainUnaffected() {
        let ethernet = NetworkStatus(
            isAvailable: true, isConnected: true, transport: .ethernet,
            interfaceName: "en1", isWiFiPoweredOn: true, ssid: nil, rssi: nil
        )
        let disconnected = NetworkStatus(
            isAvailable: true, isConnected: false, transport: .wifi,
            interfaceName: "en0", isWiFiPoweredOn: false, ssid: nil, rssi: nil
        )

        XCTAssertEqual(ethernet.transport, .ethernet)
        XCTAssertEqual(disconnected.wifiSignalLevel, .disabled)
    }
}

private final class TestWiFiPowerController: WiFiPowerControlling {
    var powerState: Bool?
    var requests: [Bool] = []
    let setError: Error?
    let appliesWrites: Bool

    init(powerState: Bool?, setError: Error? = nil, appliesWrites: Bool = true) {
        self.powerState = powerState
        self.setError = setError
        self.appliesWrites = appliesWrites
    }

    func currentPowerState() -> Bool? { powerState }

    func setPower(_ enabled: Bool) throws {
        requests.append(enabled)
        if let setError { throw setError }
        if appliesWrites { powerState = enabled }
    }
}

private enum TestError: LocalizedError {
    case failed

    var errorDescription: String? { "Test failure" }
}
