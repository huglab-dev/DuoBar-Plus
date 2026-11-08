import AppKit
import SwiftUI

/// DuoBar+: where the optional battery percentage appears in the menu bar.
enum BatteryPercentagePlacement: String, CaseIterable, Identifiable, Sendable {
    /// Upstream: a small number in the gap at the top of the ring.
    case inside
    /// Text to the right of the glyph, like macOS' own "Show Percentage".
    case beside

    static let key = "duoBarPlus.batteryPercentagePlacement"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inside: localized("Inside the Icon")
        case .beside: localized("Next to the Icon")
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> BatteryPercentagePlacement {
        defaults.string(forKey: key).flatMap(BatteryPercentagePlacement.init(rawValue:)) ?? .inside
    }
}

/// Text and width for the percentage next to the glyph. Uses the menu bar's
/// own font size with fixed-width digits, so the width only changes when the
/// number of digits does.
enum MenuBarBatteryPercentage {
    static let spacing: CGFloat = 2
    static let trailingPadding: CGFloat = 4

    static var font: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
    }

    static func text(for percentage: Int) -> String {
        localized("%d%%", percentage)
    }

    static func textWidth(for percentage: Int, font: NSFont = font) -> CGFloat {
        let size = (text(for: percentage) as NSString).size(withAttributes: [.font: font])
        return ceil(size.width)
    }

    /// Extra status item width the text needs, or 0 when it is not shown.
    static func extraWidth(for percentage: Int?) -> CGFloat {
        guard let percentage else { return 0 }
        return spacing + textWidth(for: percentage) + trailingPadding
    }

    /// The percentage to show next to the glyph, or nil when it should not be.
    /// Next to the icon it never competes with the ring, so it shows whatever
    /// the ring draws (including the Adaptive Ring a MacBook switches to when
    /// it is full on power).
    static func visiblePercentage(
        battery: BatteryStatus,
        isEnabled: Bool,
        placement: BatteryPercentagePlacement
    ) -> Int? {
        guard isEnabled, placement == .beside, battery.isAvailable else { return nil }
        return battery.percentage
    }
}

struct MenuBarBatteryPercentageText: View {
    let percentage: Int

    var body: some View {
        Text(verbatim: MenuBarBatteryPercentage.text(for: percentage))
            .font(Font(MenuBarBatteryPercentage.font))
            .monospacedDigit()
            .foregroundStyle(.primary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }
}
