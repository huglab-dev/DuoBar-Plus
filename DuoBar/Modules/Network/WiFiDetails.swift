@preconcurrency import CoreWLAN
import Foundation
import IOKit

enum WiFiBand: Int, Equatable, Sendable {
    case ghz2 = 1
    case ghz5 = 2
    case ghz6 = 3

    var text: String {
        switch self {
        case .ghz2: "2.4 GHz"
        case .ghz5: "5 GHz"
        case .ghz6: "6 GHz"
        }
    }
}

/// Details of the current Wi-Fi association, read with CoreWLAN. Raw
/// values are kept so the text mapping is testable and tolerant of values
/// newer than the SDK (for example Wi-Fi 7).
struct WiFiDetails: Equatable, Sendable {
    var interfaceName: String?
    var ssid: String?
    /// Requires location authorization; nil otherwise.
    var bssid: String?
    var rssi: Int
    var noise: Int
    var transmitRate: Double
    var securityRaw: Int
    var phyModeRaw: Int
    var channelNumber: Int?
    var band: WiFiBand?
    var channelWidthRaw: Int?
    /// The Wi-Fi hardware's own MAC address.
    var hardwareAddress: String?
    /// The address in use now; differs when macOS uses a private address.
    var currentAddress: String?

    var isAssociated: Bool { rssi < 0 }

    /// The private Wi-Fi address, when macOS uses one for this network.
    var privateAddress: String? {
        guard let currentAddress, currentAddress != hardwareAddress, MACAddress.isLocallyAdministered(currentAddress) else {
            return nil
        }
        return currentAddress
    }

    /// Signal-to-noise ratio in dB, when both values are meaningful.
    var snr: Int? {
        guard rssi < 0, noise < 0, rssi > noise else { return nil }
        return rssi - noise
    }
}

enum WiFiText {
    static func security(_ raw: Int) -> String? {
        switch raw {
        case 0: localized("None")
        case 1: "WEP"
        case 2: "WPA Personal"
        case 3: "WPA/WPA2 Personal"
        case 4: "WPA2 Personal"
        case 5: localized("Personal")
        case 6: "Dynamic WEP"
        case 7: "WPA Enterprise"
        case 8: "WPA/WPA2 Enterprise"
        case 9: "WPA2 Enterprise"
        case 10: "Enterprise"
        case 11: "WPA3 Personal"
        case 12: "WPA3 Enterprise"
        case 13: "WPA2/WPA3 Personal"
        case 14: localized("Enhanced Open")
        case 15: localized("Enhanced Open (Transition)")
        default: nil
        }
    }

    /// "Wi-Fi 6E (802.11ax)". 6 GHz turns Wi-Fi 6 into 6E.
    static func phyMode(_ raw: Int, band: WiFiBand?) -> String? {
        switch raw {
        case 1: "802.11a"
        case 2: "802.11b"
        case 3: "802.11g"
        case 4: "Wi-Fi 4 (802.11n)"
        case 5: "Wi-Fi 5 (802.11ac)"
        case 6: band == .ghz6 ? "Wi-Fi 6E (802.11ax)" : "Wi-Fi 6 (802.11ax)"
        case 7: "Wi-Fi 7 (802.11be)"
        default: nil
        }
    }

    static func channelWidth(_ raw: Int?) -> String? {
        switch raw {
        case 1: "20 MHz"
        case 2: "40 MHz"
        case 3: "80 MHz"
        case 4: "160 MHz"
        case 5: "320 MHz"
        default: nil
        }
    }

    /// "108 · 5 GHz · 80 MHz"
    static func channel(_ details: WiFiDetails) -> String? {
        guard let number = details.channelNumber, number > 0 else { return nil }
        return ([String(number), details.band?.text, channelWidth(details.channelWidthRaw)] as [String?])
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    static func rate(_ mbps: Double) -> String? {
        guard mbps > 0 else { return nil }
        return localized("%d Mbit/s", Int(mbps.rounded()))
    }

    static func dBm(_ value: Int) -> String {
        localized("%d dBm", value)
    }
}

protocol WiFiDetailsReading: Sendable {
    func details() -> WiFiDetails?
}

struct WiFiDetailsReader: WiFiDetailsReading {
    func details() -> WiFiDetails? {
        guard let interface = CWWiFiClient.shared().interface(), interface.powerOn() else { return nil }
        let channel = interface.wlanChannel()
        return WiFiDetails(
            interfaceName: interface.interfaceName,
            ssid: SSIDValue.normalized(interface.ssid()),
            bssid: interface.bssid()?.lowercased(),
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            transmitRate: interface.transmitRate(),
            securityRaw: interface.security().rawValue,
            phyModeRaw: interface.activePHYMode().rawValue,
            channelNumber: channel?.channelNumber,
            band: channel.flatMap { WiFiBand(rawValue: $0.channelBand.rawValue) },
            channelWidthRaw: channel?.channelWidth.rawValue,
            // CoreWLAN reports the hardware address even while a private
            // address is in use; the link layer has the address in use.
            hardwareAddress: interface.interfaceName.flatMap(MACAddress.hardwareAddress(forBSDName:))
                ?? interface.hardwareAddress()?.lowercased(),
            currentAddress: interface.interfaceName.flatMap(MACAddress.linkAddress(forBSDName:))
        )
    }
}

enum MACAddress {
    /// Private (randomized) addresses set the locally administered bit,
    /// 0x02 in the first octet.
    static func isLocallyAdministered(_ address: String) -> Bool {
        guard let first = address.split(separator: ":").first, let octet = UInt8(first, radix: 16) else { return false }
        return octet & 0x02 != 0
    }

    static func format(_ bytes: Data) -> String? {
        guard bytes.count == 6 else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// The link-layer address in use, as `ifconfig` shows it.
    static func linkAddress(forBSDName name: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.pointee.ifa_name) == name else { continue }
            return address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { link -> String? in
                let dl = link.pointee
                guard dl.sdl_alen == 6 else { return nil }
                return withUnsafeBytes(of: link.pointee.sdl_data) { raw -> String? in
                    let start = Int(dl.sdl_nlen)
                    guard raw.count >= start + 6 else { return nil }
                    return format(Data(raw[start..<(start + 6)]))
                }
            }
        }
        return nil
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    /// The burned-in address (`IOMACAddress` of the interface's controller),
    /// read once per interface and cached; it never changes.
    static func hardwareAddress(forBSDName name: String) -> String? {
        if let cached = cacheLock.withLock({ cache[name] }) { return cached }
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { return nil }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "IOMACAddress" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
        guard let data = value as? Data, let address = format(data) else { return nil }
        cacheLock.withLock { cache[name] = address }
        return address
    }
}
