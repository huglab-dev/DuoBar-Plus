import AppKit

/// Where menu bar items can be seen on a display with a camera notch.
///
/// macOS shows status items only to the right of the notch and hides the ones
/// that do not fit there. Rather than guessing where it parks hidden items,
/// an item on the notched display counts as visible only when it lies inside
/// the area to the right of the notch. Only horizontal positions are compared,
/// because that axis is the same in AppKit and Accessibility coordinates.
struct NotchGeometry: Equatable, Sendable {
    /// Horizontal span of the notched display, in global coordinates.
    let screenSpan: ClosedRange<CGFloat>
    /// Left edge of the area to the right of the notch.
    let visibleMinX: CGFloat
    /// Spans of the other displays, where items are shown in full.
    var otherScreenSpans: [ClosedRange<CGFloat>] = []

    /// Items wider than this are spacers, for example the separator that
    /// Hidden Bar stretches to push items off screen.
    static let maximumItemWidth: CGFloat = 400
    private static let tolerance: CGFloat = 1

    func isHidden(_ frame: CGRect) -> Bool {
        guard screenSpan.contains(frame.midX) else {
            // On another display it is shown in full; outside every display,
            // macOS moved it out of sight.
            return !otherScreenSpans.contains { $0.contains(frame.midX) }
        }
        return frame.minX < visibleMinX - Self.tolerance
            || frame.maxX > screenSpan.upperBound + Self.tolerance
    }

    /// Hidden items of other apps, nearest to the notch first.
    func hiddenItems(_ items: [MenuBarItemSnapshot]) -> [MenuBarItemSnapshot] {
        items
            .filter { $0.frame.width > 0 && $0.frame.width <= Self.maximumItemWidth && isHidden($0.frame) }
            .sorted { $0.frame.maxX > $1.frame.maxX }
    }

    /// The first display with a notch, or nil when none is connected.
    @MainActor
    static func current(screens: [NSScreen] = NSScreen.screens) -> NotchGeometry? {
        guard let notched = screens.first(where: { $0.auxiliaryTopRightArea != nil }),
              let rightArea = notched.auxiliaryTopRightArea
        else { return nil }
        let frame = notched.frame
        return NotchGeometry(
            screenSpan: frame.minX...frame.maxX,
            // Only the width is used, which holds whether the area is given in
            // screen or global coordinates.
            visibleMinX: frame.maxX - rightArea.width,
            otherScreenSpans: screens.filter { $0 != notched }.map { $0.frame.minX...$0.frame.maxX }
        )
    }
}
