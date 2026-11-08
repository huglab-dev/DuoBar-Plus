import AppKit
import SwiftUI

/// DuoBar+: "Unfold on Hover". Pointing at the menu bar mark opens it into
/// one icon per reading; clicking one opens the popover on its page.
enum UnfoldOnHover {
    static let key = "duoBarPlus.unfoldOnHover"
    static let foldDelay: TimeInterval = 0.5

    static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}

/// DuoBar+: how long the pointer rests on the icon before the hover action
/// (opening DuoBar or unfolding) happens.
enum HoverDelay {
    static let key = "duoBarPlus.hoverDelay"
    static let defaultSeconds: Double = 0.15
    static let range: ClosedRange<Double> = 0...1

    static func seconds(in defaults: UserDefaults = .standard) -> Double {
        let value = defaults.object(forKey: key) as? Double ?? defaultSeconds
        return min(max(value, range.lowerBound), range.upperBound)
    }

    static func text(_ seconds: Double) -> String {
        localized("%@ s", String(format: "%.2f", locale: Locale.current, seconds))
    }
}

/// DuoBar+: what pointing at the menu bar icon does. One setting over
/// upstream's "Open on Hover" key and the unfold key, which are kept
/// mutually exclusive.
enum HoverAction: String, CaseIterable, Identifiable, Sendable {
    case none
    case openPopover
    case unfold

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: localized("Do Nothing")
        case .openPopover: localized("Open DuoBar")
        case .unfold: localized("Unfold Readings")
        }
    }

    var footnote: String {
        switch self {
        case .none: localized("Click the icon to open DuoBar.")
        case .openPopover: localized("DuoBar opens when the pointer moves over the menu bar icon.")
        case .unfold: localized("The icon opens into a separate icon for each reading. Click one for its page.")
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> HoverAction {
        if defaults.bool(forKey: UnfoldOnHover.key) { return .unfold }
        if defaults.bool(forKey: PreferenceKeys.openOnHover) { return .openPopover }
        return .none
    }

    func store(in defaults: UserDefaults = .standard) {
        defaults.set(self == .openPopover, forKey: PreferenceKeys.openOnHover)
        defaults.set(self == .unfold, forKey: UnfoldOnHover.key)
    }
}

/// One reading in the unfolded mark.
struct UnfoldSegment: Equatable, Identifiable {
    enum Kind: Equatable {
        case networkRate(Double?)
        case wifi(WiFiSignalLevel)
        case ethernet
        case offline
        case battery(percent: Int, charging: Bool)
        case volume(percent: Int?, muted: Bool)
        case metric(label: String, fraction: Double?)
    }

    var kind: Kind
    /// The module page a click opens; nil opens the main view.
    var target: ModuleID?

    var id: String {
        switch kind {
        case .networkRate: "rate"
        case .wifi, .ethernet, .offline: "network"
        case .battery: "battery"
        case .volume: "volume"
        case .metric(let label, _): "metric-\(label)"
        }
    }
}

/// Which readings the unfolded mark shows: the dots, the center and the
/// ring slots, in that order, without duplicates.
enum UnfoldSegmentBuilder {
    static func segments(configuration: GlyphConfiguration, status: SystemStatus, values: GlyphSlotValues) -> [UnfoldSegment] {
        var result: [UnfoldSegment] = []
        func add(_ segment: UnfoldSegment?) {
            guard let segment, !result.contains(where: { $0.id == segment.id }) else { return }
            result.append(segment)
        }

        switch configuration.dots {
        case .volume: add(volume(status))
        case .network: add(UnfoldSegment(kind: .networkRate(values.networkBytesPerSecond), target: .network))
        case .battery: add(battery(status))
        case .wifiSignal: add(network(status))
        case .cpu: add(UnfoldSegment(kind: .metric(label: "CPU", fraction: values.cpu), target: .system))
        case .none: break
        }

        switch configuration.center {
        case .network: add(network(status))
        case .battery: add(battery(status))
        case .cpu: add(UnfoldSegment(kind: .metric(label: "CPU", fraction: values.cpu), target: .system))
        case .none: break
        }

        switch configuration.ring {
        case .automatic, .battery: add(battery(status))
        case .cpu: add(UnfoldSegment(kind: .metric(label: "CPU", fraction: values.cpu), target: .system))
        case .memory: add(UnfoldSegment(kind: .metric(label: "RAM", fraction: values.memory), target: .system))
        case .disk: add(UnfoldSegment(kind: .metric(label: localized("Disk"), fraction: values.disk), target: .disk))
        case .none: break
        }
        return result
    }

    static func network(_ status: SystemStatus) -> UnfoldSegment {
        let network = status.network
        guard network.isConnected else { return UnfoldSegment(kind: .offline, target: .network) }
        switch network.transport {
        case .wifi: return UnfoldSegment(kind: .wifi(network.wifiSignalLevel), target: .network)
        case .ethernet: return UnfoldSegment(kind: .ethernet, target: .network)
        case .other, .none: return UnfoldSegment(kind: .offline, target: .network)
        }
    }

    static func battery(_ status: SystemStatus) -> UnfoldSegment? {
        guard status.battery.isAvailable, let percent = status.battery.percentage else { return nil }
        return UnfoldSegment(kind: .battery(percent: percent, charging: status.battery.isPluggedIn && !status.battery.isFullyCharged), target: .battery)
    }

    static func volume(_ status: SystemStatus) -> UnfoldSegment {
        UnfoldSegment(kind: .volume(percent: status.audio.volume.percentage, muted: status.audio.volume.isMuted), target: nil)
    }
}

/// Hover and fold state of the status item, shared by `MenuBarController`
/// (pointer events, clicks) and `DuoStatusView` (drawing).
@MainActor
final class StatusItemHoverState: ObservableObject {
    @Published private(set) var isUnfolded = false
    /// Horizontal extent of each segment in status-item coordinates.
    private(set) var segmentFrames: [(range: ClosedRange<CGFloat>, target: ModuleID?)] = []

    private var pending: DispatchWorkItem?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool { UnfoldOnHover.isEnabled(in: defaults) }

    func pointerChanged(isInside: Bool) {
        pending?.cancel()
        guard isEnabled else {
            setUnfolded(false)
            return
        }
        let unfold = isInside
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.setUnfolded(unfold) }
        }
        pending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + (isInside ? HoverDelay.seconds(in: defaults) : UnfoldOnHover.foldDelay),
            execute: work
        )
    }

    func fold() {
        pending?.cancel()
        setUnfolded(false)
    }

    func setSegmentFrames(_ frames: [(range: ClosedRange<CGFloat>, target: ModuleID?)]) {
        segmentFrames = frames
    }

    /// The segment under a click, or nil when folded or between segments.
    func segment(atX x: CGFloat) -> UnfoldSegmentHit? {
        guard isUnfolded else { return nil }
        guard let frame = segmentFrames.first(where: { $0.range.contains(x) }) else { return nil }
        return UnfoldSegmentHit(target: frame.target)
    }

    private func setUnfolded(_ value: Bool) {
        guard value != isUnfolded else { return }
        isUnfolded = value
        if !value { segmentFrames = [] }
    }
}

struct UnfoldSegmentHit: Equatable {
    var target: ModuleID?
}

// MARK: - Views

struct UnfoldedStatusView: View {
    let segments: [UnfoldSegment]
    let onFramesChange: ([(range: ClosedRange<CGFloat>, target: ModuleID?)]) -> Void

    var body: some View {
        HStack(spacing: 12) {
            ForEach(segments) { segment in
                UnfoldSegmentView(segment: segment)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: UnfoldSegmentFramesKey.self,
                                value: [UnfoldSegmentFrame(id: segment.id, frame: proxy.frame(in: .named(UnfoldedStatusView.space)), target: segment.target)]
                            )
                        }
                    )
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 22)
        .background(Color.primary.opacity(0.12), in: Capsule())
        .fixedSize()
        .coordinateSpace(name: UnfoldedStatusView.space)
        .onPreferenceChange(UnfoldSegmentFramesKey.self) { frames in
            // Each segment's hit area reaches half the spacing to its neighbors.
            onFramesChange(frames.map { ($0.frame.minX - 6 ... $0.frame.maxX + 6, $0.target) })
        }
    }

    static let space = "DuoBarPlus.Unfolded"
}

struct UnfoldSegmentFrame: Equatable {
    var id: String
    var frame: CGRect
    var target: ModuleID?
}

struct UnfoldSegmentFramesKey: PreferenceKey {
    static var defaultValue: [UnfoldSegmentFrame] = []
    static func reduce(value: inout [UnfoldSegmentFrame], nextValue: () -> [UnfoldSegmentFrame]) {
        value.append(contentsOf: nextValue())
    }
}

struct UnfoldSegmentView: View {
    let segment: UnfoldSegment

    private static var font: Font {
        Font(NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular))
    }

    var body: some View {
        HStack(spacing: 4) {
            switch segment.kind {
            case .networkRate(let rate):
                Image(systemName: "arrow.up.arrow.down")
                Text(verbatim: Self.rateText(rate ?? 0))
            case .wifi(let level):
                Image(systemName: "wifi", variableValue: Self.wifiValue(level))
            case .ethernet:
                Image(systemName: "cable.connector.horizontal")
            case .offline:
                Image(systemName: "wifi.slash")
            case .battery(let percent, let charging):
                Text(verbatim: localized("%d%%", percent))
                Image(systemName: Self.batterySymbol(percent: percent, charging: charging))
            case .volume(let percent, let muted):
                Image(systemName: muted || percent == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                if let percent, !muted {
                    Text(verbatim: localized("%d%%", percent))
                }
            case .metric(let label, let fraction):
                Text(verbatim: label)
                    .foregroundStyle(.secondary)
                Text(verbatim: fraction.map(SystemText.percent) ?? "–")
            }
        }
        .font(Self.font)
        .monospacedDigit()
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(.primary)
    }

    /// "12 KB/s": the compact speed with a space before the unit.
    static func rateText(_ bytesPerSecond: Double) -> String {
        let compact = NetworkSpeedFormatter.compact(bytesPerSecond)
        guard let unit = compact.last, unit.isLetter else { return compact + " B/s" }
        let number = compact.dropLast()
        return unit == "B" ? "\(number) B/s" : "\(number) \(unit)B/s"
    }

    static func wifiValue(_ level: WiFiSignalLevel) -> Double {
        switch level {
        case .strong: 1
        case .medium: 0.66
        case .weak: 0.33
        case .disconnected, .disabled, .unavailable: 0
        }
    }

    static func batterySymbol(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
