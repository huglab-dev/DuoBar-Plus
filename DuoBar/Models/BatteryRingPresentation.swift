import Foundation

enum BatteryBoltPlacement: Equatable, Sendable {
    case none
    case topGap
}

enum BatteryRingColorRole: Equatable, Sendable {
    case monochrome
    case charging
    case lowPowerMode
    /// Red: below 10 % with level colors, below 20 % without (as upstream).
    case lowBattery
    /// DuoBar+ level colors: green 50–100 %, yellow 20–49 %, orange 10–19 %.
    case levelHigh
    case levelMedium
    case levelLow
}

/// DuoBar+ setting for the battery arc color.
enum BatteryRingColorMode: String, CaseIterable, Identifiable, Sendable {
    /// Green, yellow, orange, red by level; green while charging, yellow in Low Power Mode.
    case byLevel
    /// Monochrome from 20 %, red below; green while charging, yellow in Low
    /// Power Mode. Exactly upstream's Battery Color Coding.
    case lowOnly
    /// Always monochrome, as upstream with Battery Color Coding off.
    case monochrome

    static let key = "duoBarPlus.batteryRingColorMode"

    var id: String { rawValue }

    var colorCodingEnabled: Bool { self != .monochrome }
    var levelColorsEnabled: Bool { self == .byLevel }

    var title: String {
        switch self {
        case .byLevel: localized("By Level")
        case .lowOnly: localized("Only When Low")
        case .monochrome: localized("Monochrome")
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> BatteryRingColorMode {
        defaults.string(forKey: key).flatMap(BatteryRingColorMode.init(rawValue:)) ?? .byLevel
    }

    /// Picks the initial mode once. A stored upstream `batteryColorCoding`
    /// value means an existing user: on becomes `.lowOnly`, off `.monochrome`.
    /// Fresh installs get `.byLevel`. `persistedLegacyValue` must come from
    /// the persistent domain, not from registered defaults.
    static func migrate(defaults: UserDefaults = .standard, persistedLegacyValue: Bool?) {
        guard defaults.string(forKey: key) == nil else { return }
        let mode: BatteryRingColorMode
        switch persistedLegacyValue {
        case true?: mode = .lowOnly
        case false?: mode = .monochrome
        case nil: mode = .byLevel
        }
        defaults.set(mode.rawValue, forKey: key)
        defaults.set(mode.colorCodingEnabled, forKey: PreferenceKeys.batteryColorCoding)
    }

    /// The mode encoded by the two flags the glyph plumbing carries.
    init(colorCodingEnabled: Bool, levelColorsEnabled: Bool) {
        if !colorCodingEnabled { self = .monochrome }
        else { self = levelColorsEnabled ? .byLevel : .lowOnly }
    }
}

struct BatteryRingPresentation: Equatable, Sendable {
    let boltPlacement: BatteryBoltPlacement
    let colorRole: BatteryRingColorRole
    /// True while the battery shows 100% with the charger still connected but the
    /// system has not yet reported the authoritative "fully charged" state.
    var boltDimmed: Bool = false

    /// - Parameter levelColorsEnabled: DuoBar+ level colors. When false the
    ///   upstream behavior is unchanged (red below 20 %).
    static func resolve(
        battery: BatteryStatus,
        colorCodingEnabled: Bool,
        levelColorsEnabled: Bool = false
    ) -> BatteryRingPresentation {
        guard battery.isAvailable else {
            return BatteryRingPresentation(boltPlacement: .none, colorRole: .monochrome)
        }

        // IOPowerSources' authoritative full flag wins over a concurrent or
        // stale charging flag. Fully charged must not retain charging bolt or
        // green charging semantics. With level colors, a full battery shows
        // the green level color instead.
        if battery.isFullyCharged {
            let role: BatteryRingColorRole = colorCodingEnabled && levelColorsEnabled ? .levelHigh : .monochrome
            return BatteryRingPresentation(boltPlacement: .none, colorRole: role)
        }

        let boltPlacement: BatteryBoltPlacement = battery.isPluggedIn ? .topGap : .none
        let boltDimmed = boltPlacement == .topGap && (battery.percentage ?? 0) >= 100

        guard colorCodingEnabled else {
            return BatteryRingPresentation(
                boltPlacement: boltPlacement,
                colorRole: .monochrome,
                boltDimmed: boltDimmed
            )
        }

        let colorRole: BatteryRingColorRole = battery.isPluggedIn
            ? .charging
            : nonChargingRole(battery: battery, colorCodingEnabled: true, levelColorsEnabled: levelColorsEnabled)
        return BatteryRingPresentation(
            boltPlacement: boltPlacement,
            colorRole: colorRole,
            boltDimmed: boltDimmed
        )
    }
    /// The arc color when not on external power. Shared by the presentation
    /// and the glyph's charging color blend.
    static func nonChargingRole(
        battery: BatteryStatus,
        colorCodingEnabled: Bool,
        levelColorsEnabled: Bool = false
    ) -> BatteryRingColorRole {
        guard colorCodingEnabled, battery.isAvailable else { return .monochrome }
        if battery.isPluggedIn { return .monochrome }
        if battery.isLowPowerModeEnabled { return .lowPowerMode }
        guard let percentage = battery.percentage else { return .monochrome }
        guard levelColorsEnabled else {
            return percentage < 20 ? .lowBattery : .monochrome
        }
        return levelRole(percentage: percentage)
    }

    /// Level thresholds follow macOS' own warnings at 20 % and 10 %.
    static func levelRole(percentage: Int) -> BatteryRingColorRole {
        switch percentage {
        case ..<10: return .lowBattery
        case 10..<20: return .levelLow
        case 20..<50: return .levelMedium
        default: return .levelHigh
        }
    }
}

