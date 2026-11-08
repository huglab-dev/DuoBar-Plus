@preconcurrency import CoreLocation
@preconcurrency import CoreWLAN
import Foundation

@MainActor
@available(*, deprecated, message: "Use NetworkService for active Wi-Fi and Ethernet state")
final class WiFiService: NSObject, @preconcurrency CLLocationManagerDelegate {
    var onStatusChange: ((NetworkStatus) -> Void)?

    private let client = CWWiFiClient.shared()
    private let locationManager = CLLocationManager()
    private var refreshTimer: Timer?

    func start() {
        guard refreshTimer == nil else { return }
        locationManager.delegate = self
        refresh()

        // CoreWLAN's event registration requires an entitlement that isn't available
        // for normal Developer ID apps. A low-frequency timer keeps status current
        // without relying on unsupported entitlements or creating meaningful idle load.
        let timer = Timer(timeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func requestSSIDAccess() {
        guard locationManager.authorizationStatus == .notDetermined else { return }
        locationManager.requestWhenInUseAuthorization()
    }

    func refresh() {
        guard let interface = client.interface() else {
            onStatusChange?(.unavailable)
            return
        }

        let isPoweredOn = interface.powerOn()
        let rawRSSI = interface.rssiValue()
        let rssi = rawRSSI == 0 ? nil : rawRSSI
        let ssid = interface.ssid()?.trimmingCharacters(in: .whitespacesAndNewlines)

        // SSID can be withheld without location authorization, so RSSI is also used as
        // a public, permission-independent indication that the interface is associated.
        let isConnected = isPoweredOn && ((ssid?.isEmpty == false) || rssi != nil)

        onStatusChange?(
            NetworkStatus(
                isAvailable: true,
                isConnected: isConnected,
                transport: .wifi,
                interfaceName: interface.interfaceName,
                isWiFiPoweredOn: isPoweredOn,
                ssid: ssid?.isEmpty == false ? ssid : nil,
                rssi: rssi
            )
        )
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        refresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }
}
