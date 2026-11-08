import Combine
import Foundation

extension ModuleID {
    /// Modules that exist in this build. Settings lists only these, and
    /// `SystemStatusStore` registers exactly these.
    var isImplemented: Bool {
        switch self {
        case .network, .battery, .bluetooth, .system, .disk, .aiUsage: true
        }
    }
}

/// Sub-settings inside a module, for features that cost something even when
/// the module itself is on.
enum ModuleOption: String, CaseIterable, Identifiable, Sendable {
    case nearbyNetworks
    case roamingLog
    case topProcesses
    case memoryPressureWarning
    case externalVolumes
    case claudeUsage
    case codexUsage

    var id: String { rawValue }

    var key: String { "duoBarPlus.option.\(rawValue)" }

    var module: ModuleID {
        switch self {
        case .nearbyNetworks, .roamingLog: .network
        case .topProcesses, .memoryPressureWarning: .system
        case .externalVolumes: .disk
        case .claudeUsage, .codexUsage: .aiUsage
        }
    }

    var defaultValue: Bool {
        switch self {
        case .roamingLog: false
        case .nearbyNetworks, .topProcesses, .memoryPressureWarning, .externalVolumes, .claudeUsage, .codexUsage: true
        }
    }

    /// Options appear in Settings once the feature behind them exists.
    var isImplemented: Bool {
        switch self {
        case .nearbyNetworks, .externalVolumes, .topProcesses, .memoryPressureWarning, .roamingLog, .claudeUsage, .codexUsage: true
        }
    }

    var title: String {
        switch self {
        case .nearbyNetworks: localized("Nearby Networks")
        case .roamingLog: localized("Roaming log")
        case .topProcesses: localized("Top processes")
        case .memoryPressureWarning: localized("Memory pressure warning")
        case .externalVolumes: localized("External volumes")
        case .claudeUsage: localized("Claude")
        case .codexUsage: localized("Codex")
        }
    }

    var footnote: String {
        switch self {
        case .nearbyNetworks: localized("Scan for and join Wi-Fi networks from the popover.")
        case .roamingLog: localized("Records access point changes in the background, also while the popover is closed.")
        case .topProcesses: localized("Samples running processes while the System details are open.")
        case .memoryPressureWarning: localized("Shows a warning badge on the System row when memory pressure is high.")
        case .externalVolumes: localized("Lists external and network volumes in the Disk details.")
        case .claudeUsage: localized("Reads Claude Code's sign-in (macOS asks for Keychain access) and fetches your plan limits from Anthropic while the popover is open.")
        case .codexUsage: localized("Reads the limits Codex saves in its session logs on this Mac. Nothing is sent anywhere.")
        }
    }

    func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

enum ModuleDefaults {
    /// Registers defaults for every module and option, so `@AppStorage` and
    /// `UserDefaults` agree with `ModuleID.isEnabledByDefault`.
    static func register(in defaults: UserDefaults = .standard) {
        var values: [String: Any] = [:]
        for id in ModuleID.allCases {
            values[PreferenceKeys.moduleEnabled(id)] = id.isEnabledByDefault
        }
        for option in ModuleOption.allCases {
            values[option.key] = option.defaultValue
        }
        defaults.register(defaults: values)
    }
}

/// Backs the Modules tab in Settings. Writes straight to `UserDefaults`;
/// `ModuleRegistry` picks the changes up through `didChangeNotification`.
@MainActor
final class ModuleSettingsModel: ObservableObject {
    /// Implemented modules in the user's order.
    @Published private(set) var modules: [ModuleID] = []
    @Published private(set) var enabled: Set<ModuleID> = []
    @Published private(set) var enabledOptions: Set<ModuleOption> = []

    let hasInternalBattery: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, hasInternalBattery: Bool) {
        self.defaults = defaults
        self.hasInternalBattery = hasInternalBattery
        reload()
    }

    var options: [ModuleOption] {
        ModuleOption.allCases.filter { $0.isImplemented && $0.module.isImplemented }
    }

    func isSupported(_ id: ModuleID) -> Bool {
        id == .battery ? hasInternalBattery : true
    }

    func isEnabled(_ id: ModuleID) -> Bool {
        enabled.contains(id)
    }

    func setEnabled(_ isOn: Bool, for id: ModuleID) {
        defaults.set(isOn, forKey: PreferenceKeys.moduleEnabled(id))
        reload()
    }

    func isEnabled(_ option: ModuleOption) -> Bool {
        enabledOptions.contains(option)
    }

    func setEnabled(_ isOn: Bool, for option: ModuleOption) {
        defaults.set(isOn, forKey: option.key)
        reload()
    }

    /// Reorders the visible list. Modules that are not implemented yet keep
    /// their place at the end of the stored order.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        var visible = modules
        visible.move(fromOffsets: source, toOffset: destination)
        let full = ModuleRegistry.resolveOrder(stored: defaults.stringArray(forKey: PreferenceKeys.moduleOrder))
        let stored = visible + full.filter { !visible.contains($0) }
        defaults.set(stored.map(\.rawValue), forKey: PreferenceKeys.moduleOrder)
        reload()
    }

    func reload() {
        let order = ModuleRegistry.resolveOrder(stored: defaults.stringArray(forKey: PreferenceKeys.moduleOrder))
        let visible = order.filter(\.isImplemented)
        if visible != modules { modules = visible }

        let nowEnabled = Set(ModuleID.allCases.filter {
            defaults.object(forKey: PreferenceKeys.moduleEnabled($0)) as? Bool ?? $0.isEnabledByDefault
        })
        if nowEnabled != enabled { enabled = nowEnabled }

        let nowOptions = Set(ModuleOption.allCases.filter { $0.isEnabled(in: defaults) })
        if nowOptions != enabledOptions { enabledOptions = nowOptions }
    }
}
