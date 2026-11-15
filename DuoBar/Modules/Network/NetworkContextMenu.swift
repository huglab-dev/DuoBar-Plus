import AppKit

/// The network card's right-click menu, built in AppKit when the click
/// happens. Each choice closes the popover first, since it opens a dialog,
/// a window or a password prompt.
@MainActor
final class NetworkContextMenu: NSObject {
    private let tools: NetworkTools
    private let onClose: () -> Void
    private var handlers: [ObjectIdentifier: () -> Void] = [:]

    private init(tools: NetworkTools, onClose: @escaping () -> Void) {
        self.tools = tools
        self.onClose = onClose
    }

    static func make(tools: NetworkTools, network: NetworkStatus, onClose: @escaping () -> Void) -> NSMenu {
        let owner = NetworkContextMenu(tools: tools, onClose: onClose)
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.retainTarget(owner)

        menu.addItem(owner.item(localized("Flush DNS Cache…")) { tools.flushDNS() })
        menu.addItem(owner.item(localized("Edit Hosts File…")) { tools.editHostsFile() })

        if let interfaceName = network.interfaceName, network.isConnected {
            menu.addItem(.separator())
            menu.addItem(owner.item(localized("Renew DHCP Lease")) { tools.renewDHCPLease(bsdName: interfaceName) })
            menu.addItem(owner.item(localized("Configure IP…")) { tools.configureIP(bsdName: interfaceName) })
            if let state = tools.profileMenuState(bsdName: interfaceName) {
                let profiles = NSMenu()
                profiles.autoenablesItems = false
                for profile in state.profiles {
                    let row = owner.item(profile.name) { tools.applyProfile(profile) }
                    row.state = state.activeID == profile.id ? .on : .off
                    profiles.addItem(row)
                }
                if !state.profiles.isEmpty { profiles.addItem(.separator()) }
                let automatic = owner.item(localized("Automatic (DHCP)")) { tools.applyAutomatic(service: state.serviceName) }
                automatic.state = state.isAutomatic ? .on : .off
                profiles.addItem(automatic)
                profiles.addItem(.separator())
                profiles.addItem(owner.item(localized("Manage Profiles…")) { tools.configureIP(bsdName: interfaceName) })
                let parent = NSMenuItem(title: localized("IP Profile"), action: nil, keyEquivalent: "")
                parent.submenu = profiles
                menu.addItem(parent)
            }
        }
        return menu
    }

    private func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(choose(_:)), keyEquivalent: "")
        item.target = self
        handlers[ObjectIdentifier(item)] = action
        return item
    }

    @objc private func choose(_ sender: NSMenuItem) {
        guard let action = handlers[ObjectIdentifier(sender)] else { return }
        onClose()
        action()
    }
}
