import AppKit
import SwiftUI

struct GlyphSlotValues: Equatable {
    var cpu: Double?
    var memory: Double?
    var disk: Double?
    var networkBytesPerSecond: Double?
}

/// What the indicator configuration changes in the glyph. A nil member
/// means "keep upstream's value", so the standard configuration composes
/// to all nils and the glyph is exactly upstream's.
struct GlyphComposition: Equatable {
    var ring: DuoPersistentRingPresentation?
    var ringColor: Color?
    var batteryColorCoding: Bool?
    /// False during the low-battery moment so the ring is red, not orange.
    var batteryLevelColors: Bool?
    var center: DuoCenterState?
    var dots: Int?
    /// False when the ring no longer follows upstream (battery/Adaptive Ring).
    var usesAutomaticRing = true

    static let unchanged = GlyphComposition()
}

/// Turns the indicator configuration, live values and the active live
/// moment into overrides for `DuoGlyphView`. Pure, so it is unit tested.
enum GlyphComposer {
    static func compose(
        configuration: GlyphConfiguration,
        status: SystemStatus,
        values: GlyphSlotValues,
        event: StatusEvent?,
        batteryColorMode: BatteryRingColorMode
    ) -> GlyphComposition {
        var result = GlyphComposition()

        // MARK: Ring
        if case .lowBattery? = event?.kind {
            // Live moment: the battery ring in red, whatever the ring shows.
            // Upstream's low color (red below 20 %), not the level scale.
            result.ring = .battery(status.battery, colorCodingEnabled: true, levelColorsEnabled: false)
            result.batteryColorCoding = true
            result.batteryLevelColors = false
            result.usesAutomaticRing = false
        } else {
            switch configuration.ring {
            case .automatic:
                if let fixed = configuration.fixedRingColor {
                    result.batteryColorCoding = false
                    result.ringColor = fixed
                }
            case .battery:
                let coding = configuration.color == .automatic && batteryColorMode.colorCodingEnabled
                result.ring = .battery(status.battery, colorCodingEnabled: coding, levelColorsEnabled: coding && batteryColorMode.levelColorsEnabled)
                result.batteryColorCoding = coding
                // Monochrome draws the label color without an override.
                result.ringColor = configuration.color == .monochrome ? nil : configuration.fixedRingColor
                result.usesAutomaticRing = false
            case .cpu, .memory, .disk:
                let value: Double? = switch configuration.ring {
                case .cpu: values.cpu
                case .memory: values.memory
                default: values.disk
                }
                result.ring = gauge(value)
                result.ringColor = configuration.fixedRingColor ?? loadColor(value, style: .automatic)
                result.usesAutomaticRing = false
            case .none:
                result.ring = DuoPersistentRingPresentation(mode: .adaptive, progress: 0, opacity: 0, batteryPresentation: monochrome)
                result.usesAutomaticRing = false
            }
        }

        // MARK: Center (live moments decide it while one is active)
        if event == nil {
            switch configuration.center {
            case .network: break
            case .battery:
                result.center = status.battery.isAvailable ? status.battery.percentage.map(DuoCenterState.value) ?? .empty : .empty
            case .cpu:
                result.center = values.cpu.map { .value(Int(($0 * 100).rounded())) } ?? .empty
            case .none:
                result.center = .empty
            }
        }

        // MARK: Dots
        if case .volumeChanged? = event?.kind {
            result.dots = status.audio.volume.activeDotCount ?? 0
        } else {
            switch configuration.dots {
            case .volume: break
            case .network: result.dots = networkDots(values.networkBytesPerSecond)
            case .battery: result.dots = status.battery.isAvailable ? fractionDots(status.battery.percentage.map { Double($0) / 100 }) : 0
            case .wifiSignal: result.dots = signalDots(status.network)
            case .cpu: result.dots = fractionDots(values.cpu)
            case .none: result.dots = 0
            }
        }

        return result
    }

    private static let monochrome = BatteryRingPresentation(boltPlacement: .none, colorRole: .monochrome)

    static func gauge(_ value: Double?) -> DuoPersistentRingPresentation {
        DuoPersistentRingPresentation(
            mode: .adaptive,
            progress: min(max(value ?? 0, 0), 1),
            opacity: value == nil ? 0.22 : 1,
            batteryPresentation: monochrome
        )
    }

    /// Automatic: primary below 70 %, then yellow, orange from 85 % and red from 95 %.
    static func loadColor(_ value: Double?, style: GlyphColorStyle) -> Color? {
        switch style {
        case .monochrome: return .primary
        case .accent: return .accentColor
        case .custom: return nil
        case .automatic:
            guard let value else { return nil }
            if value >= 0.95 { return Color(nsColor: .systemRed) }
            if value >= 0.85 { return Color(nsColor: .systemOrange) }
            if value >= 0.70 { return Color(nsColor: .systemYellow) }
            return nil
        }
    }

    /// 0–4 dots for 0…1, a lit dot per started quarter.
    static func fractionDots(_ value: Double?) -> Int {
        guard let value, value > 0 else { return 0 }
        return min(Int((value * 4).rounded(.up)), 4)
    }

    /// Logarithmic: any traffic lights one dot, then 100 KB/s, 1 MB/s, 10 MB/s.
    static func networkDots(_ bytesPerSecond: Double?) -> Int {
        guard let bytesPerSecond, bytesPerSecond >= 1_024 else { return 0 }
        if bytesPerSecond >= 10_000_000 { return 4 }
        if bytesPerSecond >= 1_000_000 { return 3 }
        if bytesPerSecond >= 100_000 { return 2 }
        return 1
    }

    static func signalDots(_ network: NetworkStatus) -> Int {
        guard network.transport == .wifi, network.isConnected, let rssi = network.rssi, rssi < 0 else { return 0 }
        if rssi >= -55 { return 4 }
        if rssi >= -67 { return 3 }
        if rssi >= -75 { return 2 }
        if rssi >= -82 { return 1 }
        return 0
    }

    /// Short legend for the preview: "Battery 90%", "Network 12 KB/s".
    static func legend(ring: RingSlot, status: SystemStatus, values: GlyphSlotValues) -> String {
        switch ring {
        case .automatic, .battery:
            return status.battery.percentage.map { "\(localized("Battery")) \(localized("%d%%", $0))" } ?? ring.title
        case .cpu: return values.cpu.map { "\(ring.title) \(SystemText.percent($0))" } ?? ring.title
        case .memory: return values.memory.map { "\(ring.title) \(SystemText.percent($0))" } ?? ring.title
        case .disk: return values.disk.map { "\(ring.title) \(SystemText.percent($0))" } ?? ring.title
        case .none: return ring.title
        }
    }
}
