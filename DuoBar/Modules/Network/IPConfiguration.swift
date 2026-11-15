import Darwin
import Foundation
import SystemConfiguration

/// IPv4 and DNS settings of one network service, as System Settings shows them.
struct IPConfiguration: Equatable, Codable, Sendable {
    enum Method: String, CaseIterable, Identifiable, Codable, Sendable {
        case dhcp
        case dhcpManualAddress
        case manual

        var id: String { rawValue }

        var title: String {
            switch self {
            case .dhcp: localized("Using DHCP")
            case .dhcpManualAddress: localized("Using DHCP with manual address")
            case .manual: localized("Manually")
            }
        }
    }

    var method: Method
    var address: String
    var subnetMask: String
    var router: String
    var dnsServers: [String]
    var searchDomains: [String]

    /// Whether applying `other` would change nothing. Addresses count only
    /// where the method uses them; DHCP fills them in itself.
    func matches(_ other: IPConfiguration) -> Bool {
        guard method == other.method, dnsServers == other.dnsServers, searchDomains == other.searchDomains else { return false }
        switch method {
        case .dhcp: return true
        case .dhcpManualAddress: return address == other.address
        case .manual: return address == other.address && subnetMask == other.subnetMask && router == other.router
        }
    }

    /// DHCP for everything, with no own DNS servers or search domains.
    static let automatic = IPConfiguration(method: .dhcp, address: "", subnetMask: "", router: "", dnsServers: [], searchDomains: [])
}

/// A service's configuration plus what it uses right now.
struct IPServiceConfiguration: Equatable, Sendable {
    var serviceName: String
    var bsdName: String
    var configuration: IPConfiguration
    /// The resolvers and search domains in use, from DHCP or the own lists.
    var currentDNSServers: [String] = []
    var currentSearchDomains: [String] = []
}

protocol IPConfigurationReading: Sendable {
    func configuration(forBSDName bsdName: String) -> IPServiceConfiguration?
    func configuration(forServiceName serviceName: String) -> IPServiceConfiguration?
}

/// Reads the current network set with SystemConfiguration. Reading needs no
/// permission. Empty address fields are filled with the live values, so a
/// DHCP service shows what it got from the router.
struct SCPreferencesIPConfigurationReader: IPConfigurationReading {
    func configuration(forBSDName bsdName: String) -> IPServiceConfiguration? {
        configuration { Self.bsdName(of: $0) == bsdName }
    }

    func configuration(forServiceName serviceName: String) -> IPServiceConfiguration? {
        configuration { SCNetworkServiceGetName($0) as String? == serviceName }
    }

    private static func bsdName(of service: SCNetworkService) -> String? {
        SCNetworkServiceGetInterface(service).flatMap { SCNetworkInterfaceGetBSDName($0) as String? }
    }

    private func configuration(where matches: (SCNetworkService) -> Bool) -> IPServiceConfiguration? {
        guard let preferences = SCPreferencesCreate(nil, "DuoBarPlus" as CFString, nil),
              let set = SCNetworkSetCopyCurrent(preferences),
              let services = SCNetworkSetCopyServices(set) as? [SCNetworkService]
        else { return nil }
        guard let service = services.first(where: { SCNetworkServiceGetEnabled($0) && matches($0) }),
              let name = SCNetworkServiceGetName(service) as String?,
              let bsdName = Self.bsdName(of: service)
        else { return nil }

        let ipv4 = Self.configuration(of: service, type: kSCNetworkProtocolTypeIPv4)
        let dns = Self.configuration(of: service, type: kSCNetworkProtocolTypeDNS)
        let serviceID = SCNetworkServiceGetServiceID(service) as String?
        let live = serviceID.flatMap { Self.state("State:/Network/Service/\($0)/IPv4") } ?? [:]
        let liveDNS = Self.liveDNS(serviceID: serviceID, bsdName: bsdName)

        let configMethod = ipv4[kSCPropNetIPv4ConfigMethod as String] as? String
        let method: IPConfiguration.Method
        if configMethod == (kSCValNetIPv4ConfigMethodManual as String) {
            method = .manual
        } else if configMethod == (kSCValNetIPv4ConfigMethodINFORM as String) {
            method = .dhcpManualAddress
        } else {
            method = .dhcp
        }

        func first(_ key: CFString, in dictionary: [String: Any]) -> String? {
            (dictionary[key as String] as? [String])?.first ?? dictionary[key as String] as? String
        }
        func value(_ key: CFString) -> String {
            first(key, in: ipv4) ?? first(key, in: live) ?? ""
        }

        return IPServiceConfiguration(
            serviceName: name,
            bsdName: bsdName,
            configuration: IPConfiguration(
                method: method,
                address: value(kSCPropNetIPv4Addresses),
                subnetMask: value(kSCPropNetIPv4SubnetMasks),
                router: value(kSCPropNetIPv4Router),
                dnsServers: dns[kSCPropNetDNSServerAddresses as String] as? [String] ?? [],
                searchDomains: dns[kSCPropNetDNSSearchDomains as String] as? [String] ?? []
            ),
            currentDNSServers: liveDNS[kSCPropNetDNSServerAddresses as String] as? [String] ?? [],
            currentSearchDomains: liveDNS[kSCPropNetDNSSearchDomains as String] as? [String] ?? []
        )
    }

    /// The service's own DNS state, or the global one when the service is
    /// the primary connection.
    private static func liveDNS(serviceID: String?, bsdName: String) -> [String: Any] {
        if let serviceID, let dns = state("State:/Network/Service/\(serviceID)/DNS"),
           dns[kSCPropNetDNSServerAddresses as String] != nil {
            return dns
        }
        let primary = state("State:/Network/Global/IPv4")?[kSCDynamicStorePropNetPrimaryInterface as String] as? String
        guard primary == bsdName else { return [:] }
        return state("State:/Network/Global/DNS") ?? [:]
    }

    private static func configuration(of service: SCNetworkService, type: CFString) -> [String: Any] {
        guard let networkProtocol = SCNetworkServiceCopyProtocol(service, type),
              let configuration = SCNetworkProtocolGetConfiguration(networkProtocol) as? [String: Any]
        else { return [:] }
        return configuration
    }

    private static func state(_ key: String) -> [String: Any]? {
        guard let store = SCDynamicStoreCreate(nil, "DuoBarPlus" as CFString, nil, nil) else { return nil }
        return SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any]
    }
}

/// The root commands that apply a configuration. Uses Apple's `networksetup`
/// and `ipconfig`.
enum IPConfigurationCommand {
    static let networksetup = "/usr/sbin/networksetup"
    static let ipconfig = "/usr/sbin/ipconfig"

    static func apply(_ configuration: IPConfiguration, service: String) -> String {
        let quotedService = ShellQuoting.shell(service)
        let method: String
        switch configuration.method {
        case .dhcp:
            method = "\(networksetup) -setdhcp \(quotedService)"
        case .dhcpManualAddress:
            method = "\(networksetup) -setmanualwithdhcprouter \(quotedService) \(ShellQuoting.shell(configuration.address))"
        case .manual:
            let values = [configuration.address, configuration.subnetMask, configuration.router].map(ShellQuoting.shell)
            method = "\(networksetup) -setmanual \(quotedService) \(values.joined(separator: " "))"
        }
        let dns = list(configuration.dnsServers)
        let search = list(configuration.searchDomains)
        return [
            method,
            "\(networksetup) -setdnsservers \(quotedService) \(dns)",
            "\(networksetup) -setsearchdomains \(quotedService) \(search)"
        ].joined(separator: " && ")
    }

    static func renew(bsdName: String) -> String {
        "\(ipconfig) set \(ShellQuoting.shell(bsdName)) DHCP"
    }

    /// `Empty` clears the list, so the service uses what DHCP provides.
    private static func list(_ values: [String]) -> String {
        values.isEmpty ? "Empty" : values.map(ShellQuoting.shell).joined(separator: " ")
    }
}

enum IPv4Validation {
    static func value(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var result: UInt32 = 0
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isASCII), part.allSatisfy(\.isNumber),
                  let octet = UInt32(part), octet <= 255
            else { return nil }
            result = result << 8 | octet
        }
        return result
    }

    static func isAddress(_ text: String) -> Bool { value(text) != nil }

    /// A mask of contiguous ones, such as 255.255.255.0.
    static func isSubnetMask(_ text: String) -> Bool {
        guard let mask = value(text), mask != 0 else { return false }
        let inverted = ~mask
        return inverted & (inverted &+ 1) == 0
    }

    static func sameSubnet(_ address: String, _ router: String, mask: String) -> Bool {
        guard let address = value(address), let router = value(router), let mask = value(mask) else { return false }
        return address & mask == router & mask
    }

    static func isDNSServer(_ text: String) -> Bool {
        if isAddress(text) { return true }
        var storage = in6_addr()
        return inet_pton(AF_INET6, text, &storage) == 1
    }

    static func isSearchDomain(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }
}
