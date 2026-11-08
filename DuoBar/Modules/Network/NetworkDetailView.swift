import SwiftUI

struct NetworkDetailView: View {
    @ObservedObject var statusStore: SystemStatusStore
    let module: NetworkModule?
    /// The Nearby Networks entry, shown right under the connected network.
    var nearbyNetworks: AnyView?
    let onOpenSettings: () -> Void

    var body: some View {
        let network = statusStore.status.network

        DetailValueRow(label: localized("Status"), value: NetworkStatusText.state(for: network))

        if network.transport == .wifi, network.isConnected {
            // DuoBar+: the network picker row shows the current network
            // itself, so it replaces the separate Wi-Fi row.
            if let nearbyNetworks {
                nearbyNetworks
            } else {
                DetailValueRow(
                    label: localized("Wi-Fi"),
                    value: NetworkStatusText.detail(for: network, hasPowerControlError: false)
                )
            }
        } else {
            DetailValueRow(
                label: localized("Connection"),
                value: NetworkStatusText.detail(
                    for: network,
                    hasPowerControlError: statusStore.wifiPowerControlError != nil
                )
            )
            // Without a Wi-Fi connection the list is still useful for joining one.
            if network.transport != .ethernet, let nearbyNetworks {
                nearbyNetworks
            }
        }

        if let interfaceName = network.interfaceName, network.isConnected {
            DetailValueRow(label: localized("Interface"), value: interfaceName, isCopyable: true)
        }

        if network.isConnected {
            if let module {
                SpeedGraphTile(history: module.speedHistory)
            } else if let speed = NetworkStatusText.speed(for: network, speed: statusStore.networkSpeed) {
                DetailValueRow(label: localized("Speed"), value: speed)
            }
        }

        if let module, network.isConnected {
            AddressRows(module: module)
        }

        if network.transport == .wifi, network.isConnected {
            if let module {
                WiFiDetailRows(module: module, ssidAuthorization: statusStore.wifiSSIDAuthorization)
            } else if let signal = NetworkStatusText.signal(for: network) {
                DetailValueRow(label: localized("Signal"), value: signal)
            }
        }

        if let module, module.logsRoaming {
            RoamingLogSection(log: module.roamingLog)
        }

        DetailActionRow(title: settingsTitle, action: onOpenSettings)
    }

    private var settingsTitle: String {
        SystemSettingsOpener.pane(for: statusStore.status.network) == .network
            ? localized("Open Network Settings")
            : localized("Open Wi-Fi Settings")
    }
}

private struct RoamingLogSection: View {
    @ObservedObject var log: RoamingLog

    var body: some View {
        DetailSectionHeader(title: localized("Roaming Log"))
        if log.registrationFailed {
            DetailValueRow(label: localized("Status"), value: localized("Unavailable"))
        } else if log.entries.isEmpty {
            DetailValueRow(label: localized("No access point changes yet"), value: "")
        } else {
            ForEach(log.entries.prefix(10)) { entry in
                DetailValueRow(label: Self.time(entry.date), value: Self.summary(entry), isCopyable: true)
            }
            if log.entries.count > 10 {
                Text(localized("%d earlier changes", log.entries.count - 10))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    static func time(_ date: Date) -> String { timeFormatter.string(from: date) }

    /// "…ee:ff → …12:34 · −61 dBm", or channels when BSSIDs are hidden.
    static func summary(_ entry: RoamingEntry) -> String {
        func name(_ ap: AccessPointSnapshot) -> String {
            if let bssid = ap.bssid { return "…" + bssid.suffix(5) }
            return ap.channel.map { localized("ch %d", $0) } ?? "?"
        }
        return "\(name(entry.from)) → \(name(entry.to)) · \(WiFiText.dBm(entry.to.rssi))"
    }
}

/// IP, router, DNS and VPN, read by `NetworkModule` while visible.
private struct AddressRows: View {
    @ObservedObject var module: NetworkModule

    var body: some View {
        if let addresses = module.addresses {
            if let ipv4 = addresses.ipv4 {
                DetailValueRow(label: localized("IP Address"), value: ipv4, isCopyable: true)
            }
            if let ipv6 = addresses.ipv6 {
                DetailValueRow(label: localized("IPv6 Address"), value: ipv6, isCopyable: true)
            }
            if let router = addresses.router {
                DetailValueRow(label: localized("Router"), value: router, isCopyable: true)
            }
            if !addresses.dnsServers.isEmpty {
                DetailValueRow(
                    label: localized("DNS"),
                    value: addresses.dnsServers.prefix(2).joined(separator: ", "),
                    isCopyable: true
                )
            }
            DetailValueRow(
                label: localized("VPN"),
                value: addresses.vpnInterface.map { localized("Connected (%@)", $0) } ?? localized("Off")
            )
        }
    }
}

/// Extended CoreWLAN fields, sampled by `NetworkModule` while visible.
private struct WiFiDetailRows: View {
    @ObservedObject var module: NetworkModule
    let ssidAuthorization: SSIDAuthorizationState

    var body: some View {
        DetailSectionHeader(title: localized("Wi-Fi Details"))

        if let wifi = module.wifi, wifi.isAssociated {
            DetailValueRow(
                label: localized("Signal"),
                value: WiFiText.dBm(wifi.rssi),
                tint: NetworkStatusText.SignalQuality(rssi: wifi.rssi).color
            )
            if wifi.noise < 0 {
                DetailValueRow(label: localized("Noise"), value: WiFiText.dBm(wifi.noise))
            }
            if let snr = wifi.snr {
                DetailValueRow(label: localized("Signal-to-Noise"), value: localized("%d dB", snr))
            }
            if let rate = WiFiText.rate(wifi.transmitRate) {
                DetailValueRow(label: localized("Link Rate"), value: rate)
            }
            if let security = WiFiText.security(wifi.securityRaw) {
                DetailValueRow(label: localized("Security"), value: security)
            }
            if let phy = WiFiText.phyMode(wifi.phyModeRaw, band: wifi.band) {
                DetailValueRow(label: localized("Standard"), value: phy)
            }
            if let channel = WiFiText.channel(wifi) {
                DetailValueRow(label: localized("Channel"), value: channel)
            }
            if let bssid = wifi.bssid {
                DetailValueRow(label: "BSSID", value: bssid, isCopyable: true)
            } else {
                DetailValueRow(label: "BSSID", value: bssidPlaceholder)
            }
            if let hardware = wifi.hardwareAddress {
                DetailValueRow(label: localized("MAC Address"), value: hardware, isCopyable: true)
            }
            if let privateAddress = wifi.privateAddress {
                DetailValueRow(label: localized("Private Address"), value: privateAddress, isCopyable: true)
            }
        } else {
            DetailValueRow(label: localized("Status"), value: module.hasLoadedWiFi ? localized("Unavailable") : localized("Calculating…"))
        }
    }

    private var bssidPlaceholder: String {
        switch ssidAuthorization {
        case .authorized: localized("Unavailable")
        default: localized("Needs Location Access")
        }
    }
}
