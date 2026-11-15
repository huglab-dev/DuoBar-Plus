enum PreferenceKeys {
    static let showBatteryPercentage = "showBatteryPercentage"
    static let animationsEnabled = "animationsEnabled"
    static let menuBarIconScale = MenuBarIconSize.preferenceKey
    static let batteryColorCoding = "batteryColorCoding"
    static let adaptiveRingPriority = "adaptiveRingPriority"
    static let adaptiveRingColorCoding = "adaptiveRingColorCoding"
    static let openOnHover = "duoBar.openOnHover"
    static let showInDock = "duoBar.showInDock"
    static let showBatteryPercentageInMenuBar = "showBatteryPercentageInMenuBar"
    /// DuoBar+: saved IP profiles, as JSON.
    static let ipProfiles = "duoBarPlus.ipProfiles"
    /// DuoBar+: whether the Wi-Fi Details section is expanded.
    static let wifiDetailsExpanded = "duoBarPlus.network.wifiDetailsExpanded"

    #if DEBUG
    static let simulateDesktopMac = "debug.simulateDesktopMac"
    #endif
}
