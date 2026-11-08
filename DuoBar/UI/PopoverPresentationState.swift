import SwiftUI

/// DuoBar+: snappier than upstream's Control Center timings (open 0.26 s
/// fade and 0.30 s blur, close 0.17 s): a quick fade, a short blur and a
/// small spring scale from the top edge.
enum PopoverMotion {
    static let closeDuration: Double = 0.12
    static let openOpacity = Animation.easeOut(duration: 0.12)
    static let openBlur = Animation.easeOut(duration: 0.14)
    static let openScale = Animation.spring(response: 0.24, dampingFraction: 0.82)
    static let close = Animation.easeIn(duration: closeDuration)
    /// Scale the panel starts from when it opens.
    static let hiddenScale: CGFloat = 0.96

    /// DuoBar+: "Popover Animation" in General. Off shows and hides the
    /// popover instantly.
    static let enabledKey = "duoBarPlus.popoverAnimation"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// How long the panel stays on screen after closing starts.
    static func closeDelay(in defaults: UserDefaults = .standard) -> Double {
        isEnabled(in: defaults) ? closeDuration + 0.03 : 0
    }
}

/// Drives the blur + fade used when the popover panel opens and closes.
@MainActor
final class PopoverPresentationState: ObservableObject {
    static let shared = PopoverPresentationState()

    @Published private(set) var isShown = false
    @Published private(set) var hiddenBlur: CGFloat = 10

    /// Call while the panel is still hidden, before it is ordered front.
    func prepareToShow() { hiddenBlur = 5 }

    func show() { isShown = true }

    func hide() {
        hiddenBlur = 4
        isShown = false
    }
}
