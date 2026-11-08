import Foundation
import IOBluetooth

@MainActor
final class BluetoothService {
    var onStatusChange: ((BluetoothStatus) -> Void)?

    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }

        let center = NotificationCenter.default
        let names = [
            Notification.Name.IOBluetoothHostControllerPoweredOn,
            Notification.Name.IOBluetoothHostControllerPoweredOff
        ]

        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }

        refresh()
    }

    func refresh() {
        guard let controller = IOBluetoothHostController.default() else {
            onStatusChange?(.unavailable)
            return
        }

        onStatusChange?(
            BluetoothStatus(
                isAvailable: true,
                isPoweredOn: controller.powerState == kBluetoothHCIPowerStateON
            )
        )
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}
