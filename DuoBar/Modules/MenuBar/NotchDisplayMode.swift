import AppKit
import CoreGraphics

/// One display mode, reduced to what choosing the notch mode needs.
struct DisplayModeInfo: Equatable, Sendable {
    let id: Int32
    let width: Int
    let height: Int
    let pixelWidth: Int
    let refreshRate: Double
    let isUsable: Bool
}

protocol DisplayModeControlling: Sendable {
    /// The notched display's current mode and all its modes, or nil when no
    /// display has a notch.
    func modes() -> (current: DisplayModeInfo, all: [DisplayModeInfo])?
    func setMode(id: Int32) -> Bool
}

/// Lists and sets modes of the built-in display with CoreGraphics. Public API,
/// no permission. The change is permanent, as in System Settings.
struct CGDisplayModeController: DisplayModeControlling {
    func modes() -> (current: DisplayModeInfo, all: [DisplayModeInfo])? {
        guard let display = Self.notchedDisplay(),
              let current = CGDisplayCopyDisplayMode(display)
        else { return nil }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let all = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] ?? []).map(Self.info)
        return (Self.info(current), all)
    }

    func setMode(id: Int32) -> Bool {
        guard let display = Self.notchedDisplay() else { return false }
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        guard let mode = (CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode])?.first(where: { $0.ioDisplayModeID == id }) else {
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, display, mode, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        return CGCompleteDisplayConfiguration(config, .permanently) == .success
    }

    /// The built-in display. While the menu bar is below the notch macOS
    /// reports no notch, so the built-in display is used rather than the
    /// screen's notch area.
    private static func notchedDisplay() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &displays, &count) == .success else { return nil }
        return displays.first { CGDisplayIsBuiltin($0) != 0 }
    }

    private static func info(_ mode: CGDisplayMode) -> DisplayModeInfo {
        DisplayModeInfo(
            id: mode.ioDisplayModeID,
            width: mode.width,
            height: mode.height,
            pixelWidth: mode.pixelWidth,
            refreshRate: mode.refreshRate,
            isUsable: mode.isUsableForDesktopGUI()
        )
    }
}

/// Moves the whole menu bar below the camera notch by switching the built-in
/// display to its mode of the same width and sharpness that ends under the
/// notch, and back. Runs only when the user asks.
struct NotchDisplayMode {
    /// The notch is about 38–44 points tall; anything shorter by more than
    /// this is a different resolution, not the notch mode.
    static let maximumNotchHeight = 80

    var controller: any DisplayModeControlling = CGDisplayModeController()

    private static func isSameFamily(_ a: DisplayModeInfo, _ b: DisplayModeInfo) -> Bool {
        a.isUsable && a.width == b.width && a.pixelWidth == b.pixelWidth && abs(a.refreshRate - b.refreshRate) < 0.5
    }

    /// The full-height mode for `current`'s width, sharpness and refresh rate.
    static func fullMode(for current: DisplayModeInfo, in all: [DisplayModeInfo]) -> DisplayModeInfo? {
        all.filter { isSameFamily($0, current) }.max { $0.height < $1.height }
    }

    /// The mode that ends below the notch: same family, slightly shorter
    /// than the full mode.
    static func belowNotchMode(for current: DisplayModeInfo, in all: [DisplayModeInfo]) -> DisplayModeInfo? {
        guard let full = fullMode(for: current, in: all) else { return nil }
        return all
            .filter { isSameFamily($0, full) && $0.height < full.height && full.height - $0.height <= maximumNotchHeight }
            .max { $0.height < $1.height }
    }

    /// Whether the display can switch at all.
    var isAvailable: Bool {
        guard let modes = controller.modes() else { return false }
        return Self.belowNotchMode(for: modes.current, in: modes.all) != nil
    }

    var isBelowNotch: Bool {
        guard let modes = controller.modes(), let full = Self.fullMode(for: modes.current, in: modes.all) else { return false }
        return modes.current.height < full.height
    }

    /// Switches to the below-notch mode (`true`) or the full mode (`false`).
    @discardableResult
    func set(belowNotch: Bool) -> Bool {
        guard let modes = controller.modes() else { return false }
        let target = belowNotch
            ? Self.belowNotchMode(for: modes.current, in: modes.all)
            : Self.fullMode(for: modes.current, in: modes.all)
        guard let target else { return false }
        if target.id == modes.current.id { return true }
        return controller.setMode(id: target.id)
    }

    @discardableResult
    func toggle() -> Bool {
        set(belowNotch: !isBelowNotch)
    }
}

/// The `duobarplus://` commands, for Raycast and other launchers.
enum DuoBarURLCommand: Equatable {
    case toggleNotch
    case belowNotch
    case fullHeight
    /// Applies the saved IP profile with this name; "dhcp" means automatic.
    case ipProfile(String)

    static let scheme = "duobarplus"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme else { return nil }
        switch url.host?.lowercased() {
        case "toggle-notch": self = .toggleNotch
        case "notch-on": self = .belowNotch
        case "notch-off": self = .fullHeight
        case "ip-profile":
            let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "name" }?.value?
                .trimmingCharacters(in: .whitespaces)
            guard let name, !name.isEmpty else { return nil }
            self = .ipProfile(name)
        default: return nil
        }
    }

    /// Runs the notch commands; IP profiles need the network tools and are
    /// handled by the caller.
    @discardableResult
    func runNotch(_ mode: NotchDisplayMode = NotchDisplayMode()) -> Bool {
        switch self {
        case .toggleNotch: mode.toggle()
        case .belowNotch: mode.set(belowNotch: true)
        case .fullHeight: mode.set(belowNotch: false)
        case .ipProfile: false
        }
    }
}
