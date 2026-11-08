import Darwin
import Foundation
import SystemConfiguration

struct InterfaceAddress: Equatable, Sendable {
    var interface: String
    var address: String
    var isIPv6: Bool
}

/// Addresses and resolvers of the primary connection, read from
/// `getifaddrs` and the SystemConfiguration dynamic store. Local only:
/// nothing is sent anywhere.
struct NetworkAddresses: Equatable, Sendable {
    var primaryInterface: String?
    var ipv4: String?
    var ipv6: String?
    var router: String?
    var dnsServers: [String]
    /// An active VPN tunnel interface, if any.
    var vpnInterface: String?

    static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap"]

    static func isTunnel(_ interface: String) -> Bool {
        tunnelPrefixes.contains { interface.hasPrefix($0) }
    }

    /// Global unicast IPv6 (2000::/3). Link-local and unique-local addresses
    /// are left out; macOS keeps many idle tunnels with those.
    static func isGlobalIPv6(_ address: String) -> Bool {
        guard let first = address.split(separator: ":").first, let value = UInt16(first, radix: 16) else { return false }
        return value & 0xE000 == 0x2000
    }

    /// A tunnel counts as a VPN when it carries an IPv4 or global IPv6
    /// address, or when it is the primary interface.
    static func vpnInterface(addresses: [InterfaceAddress], primaryInterface: String?) -> String? {
        if let primaryInterface, isTunnel(primaryInterface) { return primaryInterface }
        return addresses
            .filter { isTunnel($0.interface) && (!$0.isIPv6 || isGlobalIPv6($0.address)) }
            .map(\.interface)
            .sorted()
            .first
    }

    static func make(addresses: [InterfaceAddress], primaryInterface: String?, router: String?, dnsServers: [String]) -> NetworkAddresses {
        let primary = addresses.filter { $0.interface == primaryInterface }
        return NetworkAddresses(
            primaryInterface: primaryInterface,
            ipv4: primary.first { !$0.isIPv6 }?.address,
            ipv6: primary.first { $0.isIPv6 && isGlobalIPv6($0.address) }?.address,
            router: router,
            dnsServers: dnsServers,
            vpnInterface: vpnInterface(addresses: addresses, primaryInterface: primaryInterface)
        )
    }
}

protocol NetworkAddressReading: Sendable {
    func addresses() -> NetworkAddresses
}

struct NetworkAddressReader: NetworkAddressReading {
    func addresses() -> NetworkAddresses {
        let store = SCDynamicStoreCreate(nil, "DuoBarPlus" as CFString, nil, nil)
        let ipv4 = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/IPv4" as CFString) } as? [String: Any]
        let dns = store.flatMap { SCDynamicStoreCopyValue($0, "State:/Network/Global/DNS" as CFString) } as? [String: Any]
        return NetworkAddresses.make(
            addresses: Self.interfaceAddresses(),
            primaryInterface: ipv4?["PrimaryInterface"] as? String,
            router: ipv4?["Router"] as? String,
            dnsServers: dns?["ServerAddresses"] as? [String] ?? []
        )
    }

    static func interfaceAddresses() -> [InterfaceAddress] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var result: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            var text = String(cString: host)
            if let percent = text.firstIndex(of: "%") { text = String(text[..<percent]) }
            result.append(InterfaceAddress(
                interface: String(cString: entry.pointee.ifa_name),
                address: text,
                isIPv6: family == AF_INET6
            ))
        }
        return result
    }
}
