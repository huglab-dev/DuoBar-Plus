import Combine
import Foundation

extension PreferenceKeys {
    /// Ordered module identifiers (`[String]`) for the popover main view.
    static let moduleOrder = "duoBarPlus.moduleOrder"

    static func moduleEnabled(_ id: ModuleID) -> String {
        "duoBarPlus.module.\(id.rawValue).enabled"
    }
}

/// Owns the popover modules, reads which are enabled and in what order, and
/// drives their lifecycle so a disabled module does no work at all.
@MainActor
final class ModuleRegistry: ObservableObject {
    /// Enabled, supported modules in the user's order.
    @Published private(set) var visibleModules: [ModuleID] = []

    /// Called after a module has been deactivated, for example so the router
    /// can leave its detail view.
    var onModuleDeactivated: ((ModuleID) -> Void)?

    private let modules: [ModuleID: any StatusModule]
    private let defaults: UserDefaults
    private var activeModules: Set<ModuleID> = []
    private(set) var isPopoverOpen = false
    private(set) var openDetail: ModuleID?
    private var defaultsObserver: NSObjectProtocol?

    /// - Parameter observesDefaults: re-read settings whenever `UserDefaults`
    ///   changes, so toggles in Settings take effect immediately.
    init(modules: [any StatusModule], defaults: UserDefaults = .standard, observesDefaults: Bool = true) {
        var byID: [ModuleID: any StatusModule] = [:]
        for module in modules where byID[module.id] == nil {
            byID[module.id] = module
        }
        self.modules = byID
        self.defaults = defaults
        reload()
        if observesDefaults {
            defaultsObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification,
                object: defaults,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.reload()
                }
            }
        }
    }

    deinit {
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }

    func module(_ id: ModuleID) -> (any StatusModule)? {
        modules[id]
    }

    func isRegistered(_ id: ModuleID) -> Bool {
        modules[id] != nil
    }

    func isSupported(_ id: ModuleID) -> Bool {
        modules[id]?.isSupported ?? false
    }

    func isEnabled(_ id: ModuleID) -> Bool {
        defaults.object(forKey: PreferenceKeys.moduleEnabled(id)) as? Bool ?? id.isEnabledByDefault
    }

    /// Every module id in the user's order, including disabled and unregistered ones.
    var order: [ModuleID] {
        Self.resolveOrder(stored: defaults.stringArray(forKey: PreferenceKeys.moduleOrder))
    }

    func setEnabled(_ enabled: Bool, for id: ModuleID) {
        defaults.set(enabled, forKey: PreferenceKeys.moduleEnabled(id))
        reload()
    }

    func setOrder(_ order: [ModuleID]) {
        defaults.set(Self.resolveOrder(stored: order.map(\.rawValue)).map(\.rawValue), forKey: PreferenceKeys.moduleOrder)
        reload()
    }

    /// Re-reads settings and activates or deactivates modules to match.
    func reload() {
        let currentOrder = order
        let desired = Set(currentOrder.filter { id in
            guard let module = modules[id] else { return false }
            return module.isSupported && isEnabled(id)
        })

        for id in currentOrder where activeModules.contains(id) && !desired.contains(id) {
            stop(id)
        }
        for id in currentOrder where !activeModules.contains(id) && desired.contains(id) {
            start(id)
        }

        let visible = currentOrder.filter { activeModules.contains($0) }
        if visible != visibleModules {
            visibleModules = visible
        }
    }

    func popoverDidOpen() {
        guard !isPopoverOpen else { return }
        isPopoverOpen = true
        for id in visibleModules {
            modules[id]?.popoverDidOpen()
        }
    }

    func popoverDidClose() {
        guard isPopoverOpen else { return }
        if let openDetail {
            detailDidClose(openDetail)
        }
        isPopoverOpen = false
        for id in visibleModules {
            modules[id]?.popoverDidClose()
        }
    }

    func detailDidOpen(_ id: ModuleID) {
        guard isPopoverOpen, activeModules.contains(id), openDetail != id else { return }
        if let openDetail {
            detailDidClose(openDetail)
        }
        openDetail = id
        modules[id]?.detailDidOpen()
    }

    func detailDidClose(_ id: ModuleID) {
        guard openDetail == id else { return }
        openDetail = nil
        modules[id]?.detailDidClose()
    }

    /// Known ids in stored order without duplicates, followed by any ids the
    /// stored list is missing, in their default order.
    nonisolated static func resolveOrder(stored: [String]?) -> [ModuleID] {
        var result: [ModuleID] = []
        for raw in stored ?? [] {
            guard let id = ModuleID(rawValue: raw), !result.contains(id) else { continue }
            result.append(id)
        }
        for id in ModuleID.allCases where !result.contains(id) {
            result.append(id)
        }
        return result
    }

    private func start(_ id: ModuleID) {
        guard let module = modules[id] else { return }
        activeModules.insert(id)
        module.activate()
        if isPopoverOpen {
            module.popoverDidOpen()
        }
    }

    private func stop(_ id: ModuleID) {
        guard let module = modules[id] else { return }
        if openDetail == id {
            detailDidClose(id)
        }
        if isPopoverOpen {
            module.popoverDidClose()
        }
        module.deactivate()
        activeModules.remove(id)
        onModuleDeactivated?(id)
    }
}
