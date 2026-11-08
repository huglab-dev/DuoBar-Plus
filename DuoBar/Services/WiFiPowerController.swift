@preconcurrency import CoreWLAN
import Foundation

protocol WiFiPowerControlling: AnyObject {
    func currentPowerState() -> Bool?
    func setPower(_ enabled: Bool) throws
}

final class CoreWLANWiFiPowerController: WiFiPowerControlling {
    private let interfaceProvider: () -> CWInterface?

    init(interfaceProvider: @escaping () -> CWInterface?) {
        self.interfaceProvider = interfaceProvider
    }

    func currentPowerState() -> Bool? {
        interfaceProvider()?.powerOn()
    }

    func setPower(_ enabled: Bool) throws {
        guard let interface = interfaceProvider() else {
            throw WiFiPowerControlError.interfaceUnavailable
        }
        try interface.setPower(enabled)
    }
}

enum WiFiPowerControlError: LocalizedError, Equatable {
    case interfaceUnavailable
    case stateDidNotUpdate

    var errorDescription: String? {
        switch self {
        case .interfaceUnavailable: "Wi-Fi interface unavailable"
        case .stateDidNotUpdate: "Wi-Fi power state did not update"
        }
    }
}

enum WiFiPowerControlResult: Equatable {
    case success(actualPowerState: Bool)
    case unavailable
    case failure(actualPowerState: Bool?, message: String)
}

struct WiFiPowerControlCoordinator {
    let controller: WiFiPowerControlling

    func setPower(_ enabled: Bool) -> WiFiPowerControlResult {
        guard controller.currentPowerState() != nil else { return .unavailable }

        do {
            try controller.setPower(enabled)
            guard let actualPowerState = controller.currentPowerState() else {
                return .unavailable
            }
            guard actualPowerState == enabled else {
                return .failure(
                    actualPowerState: actualPowerState,
                    message: WiFiPowerControlError.stateDidNotUpdate.localizedDescription
                )
            }
            return .success(actualPowerState: actualPowerState)
        } catch {
            return .failure(
                actualPowerState: controller.currentPowerState(),
                message: error.localizedDescription
            )
        }
    }
}
