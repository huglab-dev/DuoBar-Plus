import Foundation
import SystemConfiguration

/// Maps BSD names (`en7`) to the names System Settings shows
/// ("USB 10/100/1000 LAN").
protocol NetworkAdapterNameReading: Sendable {
    func names() -> [String: String]
}

/// Reads adapter names through SystemConfiguration. Public API, no permission.
struct SCNetworkAdapterNameReader: NetworkAdapterNameReading {
    func names() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var names: [String: String] = [:]
        for interface in interfaces {
            guard let bsdName = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?,
                  !name.isEmpty, name != bsdName
            else { continue }
            names[bsdName] = name
        }
        return names
    }
}
