import SwiftUI

/// Main-view network row. On Wi-Fi the right-hand value is the live signal
/// strength, color-coded by quality; otherwise the transfer speed.
struct NetworkStatusRow: View {
    @ObservedObject var statusStore: SystemStatusStore
    @ObservedObject var module: NetworkModule
    let trailing: AnyView?
    let onActivate: () -> Void

    var body: some View {
        let network = statusStore.status.network
        StatusRow(
            symbol: NetworkStatusText.symbol(for: network),
            title: localized("Network"),
            detail: NetworkStatusText.detail(for: network, hasPowerControlError: statusStore.wifiPowerControlError != nil),
            speedText: rssi.map(WiFiText.dBm) ?? NetworkStatusText.speed(for: network, speed: statusStore.networkSpeed),
            speedTint: rssi.map { NetworkStatusText.SignalQuality(rssi: $0).color },
            stateText: NetworkStatusText.state(for: network),
            tint: .primary,
            accessory: .disclosure,
            trailing: trailing,
            onActivate: onActivate,
            activationHint: localized("Show details")
        )
        .accessibilityValue(rssi.map { localized("Signal %@", WiFiText.dBm($0)) } ?? "")
    }

    /// Live RSSI from the module, falling back to `NetworkService`'s value.
    private var rssi: Int? {
        let network = statusStore.status.network
        guard network.transport == .wifi, network.isConnected else { return nil }
        if let wifi = module.wifi, wifi.isAssociated { return wifi.rssi }
        if let rssi = network.rssi, rssi < 0 { return rssi }
        return nil
    }
}
