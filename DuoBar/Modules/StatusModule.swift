import Foundation

/// Stable identifiers for the popover modules. Raw values are persisted in
/// `UserDefaults`, so never rename an existing case.
enum ModuleID: String, CaseIterable, Identifiable, Sendable {
    case network
    case battery
    case bluetooth
    case system
    case disk
    case aiUsage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: localized("Network")
        case .battery: localized("Battery")
        case .bluetooth: localized("Bluetooth")
        case .system: localized("System")
        case .disk: localized("Disk")
        case .aiUsage: localized("AI Usage")
        }
    }

    var symbol: String {
        switch self {
        case .network: "wifi"
        case .battery: "battery.75percent"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .system: "gearshape"
        case .disk: "internaldrive"
        case .aiUsage: "sparkles"
        }
    }

    /// Whether the module is on before the user has changed anything.
    /// AI Usage reads a sign-in and contacts Anthropic, so it is opt-in.
    var isEnabledByDefault: Bool { self != .aiUsage }
}

/// One independently switchable section of the popover.
///
/// Lifecycle, from outermost to innermost:
/// - `activate`/`deactivate`: the module was switched on or off in Settings.
///   Only work that must run while the popover is closed (for example the
///   roaming log) may start here.
/// - `popoverDidOpen`/`popoverDidClose`: work needed for the module's row in
///   the main view.
/// - `detailDidOpen`/`detailDidClose`: work needed only by the detail view.
///
/// `ModuleRegistry` guarantees the calls are balanced and nested, so a module
/// never sees `detailDidOpen` without a preceding `popoverDidOpen`, and never
/// sees anything while deactivated.
///
/// Live data is published by the concrete module types themselves. It must
/// never be written into `SystemStatus`, because the menu bar glyph observes it.
@MainActor
protocol StatusModule: AnyObject {
    var id: ModuleID { get }
    /// False when the hardware lacks the feature (for example no battery).
    var isSupported: Bool { get }

    func activate()
    func deactivate()
    func popoverDidOpen()
    func popoverDidClose()
    func detailDidOpen()
    func detailDidClose()
    /// Timers and observers running right now, by name. Used by the
    /// performance test to prove nothing runs with the popover closed.
    var activeWork: [String] { get }
}

extension StatusModule {
    var isSupported: Bool { true }

    func activate() {}
    func deactivate() {}
    func popoverDidOpen() {}
    func popoverDidClose() {}
    func detailDidOpen() {}
    func detailDidClose() {}
    var activeWork: [String] { [] }
}
