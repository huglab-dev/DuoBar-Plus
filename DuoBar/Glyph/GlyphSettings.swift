import AppKit
import SwiftUI
import Foundation

/// DuoBar+: short-lived presentations in the menu bar glyph ("live moments").
/// Each can be turned off; a turned-off moment is never presented.
enum LiveMoment: String, CaseIterable, Identifiable, Sendable {
    case pluggedIn
    case audioConnected
    case lowBattery
    case networkLost
    case volume

    var id: String { rawValue }
    var key: String { "duoBarPlus.moment.\(rawValue)" }

    var title: String {
        switch self {
        case .pluggedIn: localized("Plugged in")
        case .audioConnected: localized("AirPods and headphones")
        case .lowBattery: localized("Low battery")
        case .networkLost: localized("Network lost")
        case .volume: localized("Volume change")
        }
    }

    var footnote: String {
        switch self {
        case .pluggedIn: localized("A bolt in the center when the charger is connected.")
        case .audioConnected: localized("The device in the center when it connects.")
        case .lowBattery: localized("The level in the center and a red ring at 20 % and 10 %.")
        case .networkLost: localized("The offline symbol when the connection drops.")
        case .volume: localized("The dots show the volume while it changes, when they show something else.")
        }
    }

    var symbol: String {
        switch self {
        case .pluggedIn: "bolt.fill"
        case .audioConnected: "airpodspro"
        case .lowBattery: "battery.25percent"
        case .networkLost: "wifi.slash"
        case .volume: "speaker.wave.2"
        }
    }

    func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    /// The moment a detected event belongs to.
    init(kind: StatusEvent.Kind) {
        switch kind {
        case .charging: self = .pluggedIn
        case .audioDeviceConnected: self = .audioConnected
        case .lowBattery: self = .lowBattery
        case .networkDisconnected: self = .networkLost
        case .volumeChanged: self = .volume
        }
    }

    /// Whether a detected event should be presented with the current settings.
    static func allows(_ event: StatusEvent, dots: DotsSlot, defaults: UserDefaults = .standard) -> Bool {
        let moment = LiveMoment(kind: event.kind)
        guard moment.isEnabled(in: defaults) else { return false }
        // The dots already show the volume; a moment would add nothing.
        if moment == .volume { return dots != .volume }
        return true
    }
}

/// What the outer ring shows.
enum RingSlot: String, CaseIterable, Identifiable, Sendable {
    /// Upstream behavior: battery on MacBooks (with the MacBook Adaptive
    /// Ring when full on power), the Adaptive Ring on desktop Macs.
    case automatic
    case battery
    case cpu
    case memory
    case disk
    case none

    static let key = "duoBarPlus.slot.ring"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: localized("Automatic")
        case .battery: localized("Battery")
        case .cpu: localized("CPU")
        case .memory: localized("Memory")
        case .disk: localized("Disk")
        case .none: localized("None")
        }
    }

    var symbol: String {
        switch self {
        case .automatic: "circle.dashed"
        case .battery: "battery.100percent"
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .disk: "internaldrive"
        case .none: "circle.slash"
        }
    }
}

/// What the center shows.
enum CenterSlot: String, CaseIterable, Identifiable, Sendable {
    /// Upstream behavior: Wi-Fi, Ethernet or offline.
    case network
    case battery
    case cpu
    case none

    static let key = "duoBarPlus.slot.center"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .network: localized("Wi-Fi")
        case .battery: localized("Battery %")
        case .cpu: localized("CPU %")
        case .none: localized("None")
        }
    }

    var symbol: String {
        switch self {
        case .network: "wifi"
        case .battery: "percent"
        case .cpu: "cpu"
        case .none: "circle.slash"
        }
    }
}

/// What the four dots show.
enum DotsSlot: String, CaseIterable, Identifiable, Sendable {
    /// Upstream behavior: output volume.
    case volume
    case network
    case battery
    case wifiSignal
    case cpu
    case none

    static let key = "duoBarPlus.slot.dots"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .volume: localized("Volume")
        case .network: localized("Network")
        case .battery: localized("Battery")
        case .wifiSignal: localized("Wi-Fi Signal")
        case .cpu: localized("CPU")
        case .none: localized("None")
        }
    }

    var symbol: String {
        switch self {
        case .volume: "speaker.wave.2"
        case .network: "arrow.up.arrow.down"
        case .battery: "battery.75percent"
        case .wifiSignal: "wifi"
        case .cpu: "cpu"
        case .none: "circle.slash"
        }
    }
}

/// Ring color.
enum GlyphColorStyle: String, CaseIterable, Identifiable, Sendable {
    /// Battery colors follow "Battery Color Coding"; other sources turn
    /// yellow, orange and red as they fill up.
    case automatic
    case monochrome
    case accent
    /// Any color the user picks (`customColorKey`).
    case custom

    static let key = "duoBarPlus.slot.color"
    static let customColorKey = "duoBarPlus.slot.customColor"
    static let defaultCustomColorHex = "#34C759"
    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: localized("Automatic")
        case .monochrome: localized("Monochrome")
        case .accent: localized("Accent Color")
        case .custom: localized("Custom")
        }
    }
}

/// `#RRGGBB` in sRGB, the stored form of the custom ring color.
enum HexColor {
    static func nsColor(_ hex: String) -> NSColor? {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: 1
        )
    }

    static func color(_ hex: String) -> Color? {
        nsColor(hex).map(Color.init(nsColor:))
    }

    static func hex(_ color: NSColor) -> String? {
        guard let srgb = color.usingColorSpace(.sRGB) else { return nil }
        func byte(_ component: CGFloat) -> Int { Int((min(max(component, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
    }
}

/// The user's indicator configuration, read from `UserDefaults`.
struct GlyphConfiguration: Equatable, Sendable {
    var ring: RingSlot
    var center: CenterSlot
    var dots: DotsSlot
    var color: GlyphColorStyle
    var customColorHex: String

    static let standard = GlyphConfiguration(ring: .automatic, center: .network, dots: .volume, color: .automatic)

    var isStandard: Bool { ring == .automatic && center == .network && dots == .volume && color == .automatic }

    init(
        ring: RingSlot,
        center: CenterSlot,
        dots: DotsSlot,
        color: GlyphColorStyle,
        customColorHex: String = GlyphColorStyle.defaultCustomColorHex
    ) {
        self.ring = ring
        self.center = center
        self.dots = dots
        self.color = color
        self.customColorHex = customColorHex
    }

    /// The single ring color for Monochrome, Accent and Custom; nil for Automatic.
    var fixedRingColor: Color? {
        switch color {
        case .automatic: nil
        case .monochrome: .primary
        case .accent: .accentColor
        case .custom: HexColor.color(customColorHex) ?? .accentColor
        }
    }

    init(defaults: UserDefaults = .standard) {
        ring = defaults.string(forKey: RingSlot.key).flatMap(RingSlot.init(rawValue:)) ?? .automatic
        center = defaults.string(forKey: CenterSlot.key).flatMap(CenterSlot.init(rawValue:)) ?? .network
        dots = defaults.string(forKey: DotsSlot.key).flatMap(DotsSlot.init(rawValue:)) ?? .volume
        color = defaults.string(forKey: GlyphColorStyle.key).flatMap(GlyphColorStyle.init(rawValue:)) ?? .automatic
        customColorHex = defaults.string(forKey: GlyphColorStyle.customColorKey) ?? GlyphColorStyle.defaultCustomColorHex
    }

    /// Live metrics the configuration needs sampled while the app runs.
    var neededMetrics: Set<GlyphMetric> {
        var metrics: Set<GlyphMetric> = []
        if ring == .cpu || center == .cpu || dots == .cpu { metrics.insert(.cpu) }
        if ring == .memory { metrics.insert(.memory) }
        if ring == .disk { metrics.insert(.disk) }
        if dots == .network { metrics.insert(.networkRate) }
        return metrics
    }
}

enum GlyphMetric: Hashable, Sendable {
    case cpu
    case memory
    case disk
    case networkRate
}

extension AudioDeviceStatus {
    /// Sample AirPods Pro for the Indicator preview.
    static let previewAirPods = AudioDeviceStatus(
        uid: "duobarplus.preview.airpods",
        name: "AirPods Pro",
        transport: .bluetooth,
        isAlive: true,
        modelUID: "2027 4c",
        manufacturer: "Apple Inc.",
        terminalType: .headphones
    )
}

/// DuoBar+: shows the debug simulator and diagnostics (DEBUG builds only).
enum DebugMode {
    static let key = "duoBarPlus.debugMode"

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// DuoBar+: the ring's stroke relative to the reference proportion.
/// DuoBar+: user setting "Center Size", the size of the mark in the ring's
/// center (Wi-Fi, a number or a symbol). 1 is the reference size.
enum CenterIconSize {
    static let key = "duoBarPlus.centerIconScale"
    static let defaultScale = 1.0
    static let range: ClosedRange<Double> = 0.7...1.3
    static let step = 0.05

    static func resolve(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return defaultScale }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

enum RingThickness {
    static let key = "duoBarPlus.ringThickness"
    static let defaultScale = 1.0
    static let range: ClosedRange<Double> = 0.6...1.5
    static let step = 0.05

    static func resolve(_ value: Double?) -> Double {
        guard let value, value.isFinite else { return defaultScale }
        return min(max(value, range.lowerBound), range.upperBound)
    }
}
