import AppKit
import Foundation
import SwiftUI

/// Wi-Fi and network module. CoreWLAN details are read every `interval`
/// seconds on a background queue while the popover is open: the main row
/// shows the live, color-coded signal and the detail view the rest.
/// Nothing is read while the popover is closed.
@MainActor
final class NetworkModule: ObservableObject, StatusModule {
    let id: ModuleID = .network

    @Published private(set) var wifi: WiFiDetails?
    @Published private(set) var hasLoadedWiFi = false
    /// IP, router, DNS and VPN; read only while the detail view is open.
    @Published private(set) var addresses: NetworkAddresses?
    /// One-second speed readings for the graph, cleared when the popover closes.
    let speedHistory = SpeedHistory()
    /// Access point changes; listens in the background only while the
    /// "Roaming log" option is on.
    let roamingLog = RoamingLog()
    private var optionObserver: NSObjectProtocol?
    private let defaults: UserDefaults

    private let reader: any WiFiDetailsReading
    private let addressReader: any NetworkAddressReading
    private let interval: TimeInterval
    private var isDetailOpen = false
    private let queue = DispatchQueue(label: "DuoBarPlus.NetworkModule", qos: .userInitiated)
    private var timer: Timer?
    private var generation = 0

    init(
        reader: any WiFiDetailsReading = WiFiDetailsReader(),
        addressReader: any NetworkAddressReading = NetworkAddressReader(),
        defaults: UserDefaults = .standard,
        interval: TimeInterval = 2
    ) {
        self.defaults = defaults
        self.reader = reader
        self.addressReader = addressReader
        self.interval = interval
    }

    var isSamplingDetails: Bool { timer != nil }
    var activeWork: [String] { isSamplingDetails ? ["detail timer"] : [] }

    func popoverDidOpen() {
        guard timer == nil else { return }
        generation += 1
        readDetails()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readDetails() }
        }
        timer.tolerance = interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func popoverDidClose() {
        stopDetails()
        speedHistory.clear()
    }

    /// Fed by `SystemStatusStore` from `NetworkSpeedService`, which only
    /// runs while the popover is open.
    func record(_ speed: NetworkSpeed?) {
        guard timer != nil else { return }
        speedHistory.append(speed)
    }

    func detailDidOpen() {
        isDetailOpen = true
        // Fresh values right away instead of waiting for the next tick.
        if timer != nil { readDetails() }
    }

    func detailDidClose() {
        isDetailOpen = false
    }

    func activate() {
        syncRoamingLog()
        optionObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncRoamingLog() }
        }
    }

    func deactivate() {
        stopDetails()
        speedHistory.clear()
        if let optionObserver {
            NotificationCenter.default.removeObserver(optionObserver)
            self.optionObserver = nil
        }
        roamingLog.stop()
        roamingLog.clear()
    }

    var logsRoaming: Bool { ModuleOption.roamingLog.isEnabled(in: defaults) }

    private func syncRoamingLog() {
        if logsRoaming {
            roamingLog.start()
        } else if roamingLog.isListening {
            roamingLog.stop()
            roamingLog.clear()
        }
    }

    private func readDetails() {
        let generation = generation
        let reader = reader
        let addressReader = isDetailOpen ? addressReader : nil
        queue.async { [weak self] in
            let details = reader.details()
            let addresses = addressReader?.addresses()
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.timer != nil else { return }
                self.wifi = details
                self.hasLoadedWiFi = true
                if self.roamingLog.isListening {
                    self.roamingLog.observe(details.map(AccessPointSnapshot.init(details:)))
                }
                if let addresses, addresses != self.addresses { self.addresses = addresses }
            }
        }
    }

    private func stopDetails() {
        timer?.invalidate()
        timer = nil
        isDetailOpen = false
        generation += 1
    }

    deinit {
        timer?.invalidate()
        if let optionObserver {
            NotificationCenter.default.removeObserver(optionObserver)
        }
    }
}

/// Text and symbols for the network row and its detail view, shared so the
/// two never disagree.
enum NetworkStatusText {
    static func symbol(for network: NetworkStatus) -> String {
        guard network.isConnected else { return "network.slash" }
        switch network.transport {
        case .wifi: return "wifi"
        case .ethernet: return "cable.connector.horizontal"
        case .other: return "ellipsis.circle"
        case .none: return "network.slash"
        }
    }

    static func detail(for network: NetworkStatus, hasPowerControlError: Bool) -> String {
        if hasPowerControlError {
            return localized("Unable to change Wi-Fi power")
        }
        guard network.isAvailable else { return localized("No network interface") }
        guard network.isConnected else {
            return network.isWiFiPoweredOn == false ? localized("Wi-Fi disabled") : localized("Not connected")
        }
        switch network.transport {
        case .wifi: return network.ssid ?? localized("Network name unavailable")
        case .ethernet: return network.interfaceName ?? localized("Wired connection")
        case .other: return network.interfaceName ?? localized("Active connection")
        case .none: return localized("Not connected")
        }
    }

    static func state(for network: NetworkStatus) -> String {
        guard network.isAvailable else { return localized("Unavailable") }
        if network.isWiFiPoweredOn == false, !network.isConnected { return localized("Off") }
        guard network.isConnected else { return localized("Offline") }
        switch network.transport {
        case .wifi: return localized("Wi-Fi")
        case .ethernet: return localized("Ethernet")
        case .other: return localized("Connected")
        case .none: return localized("Offline")
        }
    }

    static func speed(for network: NetworkStatus, speed: NetworkSpeed?) -> String? {
        guard network.isConnected, let speed else { return nil }
        let down = NetworkSpeedFormatter.compact(speed.downloadBytesPerSecond)
        let up = NetworkSpeedFormatter.compact(speed.uploadBytesPerSecond)
        return "↓\(down) ↑\(up)"
    }

    static func signal(for network: NetworkStatus) -> String? {
        guard network.transport == .wifi, network.isConnected, let rssi = network.rssi, rssi < 0 else { return nil }
        return localized("%d dBm", rssi)
    }

    /// Signal quality buckets for the color-coded RSSI. The -67/-75 limits
    /// match upstream's strong/medium Wi-Fi glyph levels.
    enum SignalQuality: Equatable {
        case good, fair, poor, bad

        init(rssi: Int) {
            if rssi >= -67 { self = .good }
            else if rssi >= -75 { self = .fair }
            else if rssi >= -82 { self = .poor }
            else { self = .bad }
        }

        var color: Color {
            switch self {
            case .good: Color(nsColor: .systemGreen)
            case .fair: Color(nsColor: .systemYellow)
            case .poor: Color(nsColor: .systemOrange)
            case .bad: Color(nsColor: .systemRed)
            }
        }
    }
}
