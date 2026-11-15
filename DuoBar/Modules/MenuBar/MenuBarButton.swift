import AppKit
import SwiftUI

/// DuoBar+: the optional button to the left of the glyph that lists hidden
/// menu bar items. It is part of DuoBar+'s own status item, so it always sits
/// next to the glyph.
enum MenuBarButton {
    static let width: CGFloat = 14
    static let spacing: CGFloat = 2
    static let leadingPadding: CGFloat = 4

    /// Extra status item width the button needs, or 0 when it is hidden.
    static func extraWidth(isShown: Bool) -> CGFloat {
        isShown ? leadingPadding + width + spacing : 0
    }

    /// Clicks this close to the leading edge of the status item hit the button.
    static var hitWidth: CGFloat { extraWidth(isShown: true) }

    /// Shown only while the Menu Bar Items module and its button option are on.
    static func isShown(moduleEnabled: Bool, optionEnabled: Bool) -> Bool {
        moduleEnabled && optionEnabled
    }

    static func isShown(in defaults: UserDefaults = .standard) -> Bool {
        let moduleEnabled = defaults.object(forKey: PreferenceKeys.moduleEnabled(.menuBar)) as? Bool
            ?? ModuleID.menuBar.isEnabledByDefault
        return isShown(moduleEnabled: moduleEnabled, optionEnabled: ModuleOption.menuBarButton.isEnabled(in: defaults))
    }
}

/// The chevron drawn in the menu bar.
struct MenuBarButtonGlyph: View {
    var body: some View {
        Image(systemName: "chevron.down")
            .font(.system(size: 10, weight: .bold))
            .frame(width: MenuBarButton.width, height: 22)
            .padding(.leading, MenuBarButton.leadingPadding)
            .accessibilityLabel(localized("Hidden menu bar items"))
    }
}
