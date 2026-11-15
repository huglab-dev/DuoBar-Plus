import Foundation

/// DuoBar+: the rows of the glyph's right-click menu. An empty list means a
/// right-click opens the popover, as it always did.
enum GlyphMenuRow: Equatable {
    case showHiddenItems
    case belowNotch(isChecked: Bool)
}

enum GlyphMenu {
    static func rows(moduleEnabled: Bool, notchAvailable: Bool, belowNotch: Bool) -> [GlyphMenuRow] {
        var rows: [GlyphMenuRow] = []
        if moduleEnabled { rows.append(.showHiddenItems) }
        if notchAvailable { rows.append(.belowNotch(isChecked: belowNotch)) }
        return rows
    }

    static func isMenuBarModuleEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: PreferenceKeys.moduleEnabled(.menuBar)) as? Bool ?? ModuleID.menuBar.isEnabledByDefault
    }
}
