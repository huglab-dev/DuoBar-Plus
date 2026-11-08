import SwiftUI

/// The Indicator tab: what the ring, center and dots show, the ring color,
/// and which live moments the glyph presents, with a live preview.
struct IndicatorSettingsView: View {
    @AppStorage(RingSlot.key) private var ring = RingSlot.automatic
    @AppStorage(CenterSlot.key) private var center = CenterSlot.network
    @AppStorage(DotsSlot.key) private var dots = DotsSlot.volume
    @AppStorage(GlyphColorStyle.key) private var color = GlyphColorStyle.automatic
    @AppStorage(GlyphColorStyle.customColorKey) private var customColorHex = GlyphColorStyle.defaultCustomColorHex
    @AppStorage(BatteryRingColorMode.key) private var batteryColorModeRaw = BatteryRingColorMode.byLevel.rawValue
    @AppStorage(PreferenceKeys.menuBarIconScale) private var menuBarIconScale = MenuBarIconSize.defaultScale
    @AppStorage(RingThickness.key) private var ringThickness = RingThickness.defaultScale
    @AppStorage(CenterIconSize.key) private var centerIconScale = CenterIconSize.defaultScale
    @State private var previewEvent: StatusEvent?
    @State private var previewTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section {
                preview
            }

            Section(localized("Slots")) {
                Picker(selection: $ring) {
                    ForEach(RingSlot.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: { Text(localized("Ring")) }
                Picker(selection: $center) {
                    ForEach(CenterSlot.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: { Text(localized("Center")) }
                Picker(selection: $dots) {
                    ForEach(DotsSlot.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                } label: { Text(localized("Dots")) }
            }

            Section {
                Picker(localized("Color"), selection: $color) {
                    ForEach(GlyphColorStyle.allCases) { Text($0.title).tag($0) }
                }
                if color == .custom {
                    ColorPicker(localized("Ring Color"), selection: customColor, supportsOpacity: false)
                }
            } header: {
                Text(localized("Style"))
            } footer: {
                Text(localized("Choose what the ring, the center and the dots show, and the ring's color. CPU, memory, disk and network are measured only when a slot shows them."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Moved here from General (DuoBar+).
            Section(localized("Size")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(localized("Icon Size"))
                Picker(localized("Icon Size"), selection: resolvedMenuBarIconScale) {
                    Text(localized("Small")).tag(MenuBarIconSize.minimumScale)
                    Text(localized("Default")).tag(MenuBarIconSize.defaultScale)
                    Text(localized("Large")).tag(MenuBarIconSize.largeScale)
                    Text(localized("Extra Large")).tag(MenuBarIconSize.extraLargeScale)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(localized("Menu bar icon size"))
                HStack(spacing: 10) {
                    Text(localized("Small"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(
                        value: resolvedMenuBarIconScale,
                        in: MenuBarIconSize.minimumScale...MenuBarIconSize.maximumScale,
                        step: MenuBarIconSize.step
                    )
                    .accessibilityLabel(localized("Menu bar icon size"))
                    .accessibilityValue(localized("%d%%", Int((MenuBarIconSize.resolve(menuBarIconScale) * 100).rounded())))
                    Text(localized("Large"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(localized("Choose a preset or fine-tune DuoBar to better match your menu bar."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(localized("Ring Thickness"))
                    Spacer()
                    Text(localized("%d%%", Int((RingThickness.resolve(ringThickness) * 100).rounded())))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text(localized("Thin"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $ringThickness, in: RingThickness.range, step: RingThickness.step)
                        .accessibilityLabel(localized("Ring Thickness"))
                        .accessibilityValue(localized("%d%%", Int((RingThickness.resolve(ringThickness) * 100).rounded())))
                    Text(localized("Thick"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(localized("Center Size"))
                    Spacer()
                    Text(localized("%d%%", Int((CenterIconSize.resolve(centerIconScale) * 100).rounded())))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    Text(localized("Small"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Slider(value: $centerIconScale, in: CenterIconSize.range, step: CenterIconSize.step)
                        .accessibilityLabel(localized("Center Size"))
                        .accessibilityValue(localized("%d%%", Int((CenterIconSize.resolve(centerIconScale) * 100).rounded())))
                    Text(localized("Large"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(localized("The size of the Wi-Fi mark, number or symbol in the middle of the ring."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }

            Section {
                ForEach(LiveMoment.allCases) { moment in
                    LiveMomentRow(moment: moment) { play(moment) }
                }
            } header: {
                Text(localized("Live Moments"))
            } footer: {
                Text(localized("The mark shows what just happened, then steps back."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 640)
        .onDisappear { previewTask?.cancel() }
    }

    // MARK: Preview

    private var preview: some View {
        let status = Self.sampleStatus
        let values = Self.sampleValues
        let configuration = GlyphConfiguration(ring: ring, center: center, dots: dots, color: color, customColorHex: customColorHex)
        let batteryMode = BatteryRingColorMode(rawValue: batteryColorModeRaw) ?? .byLevel
        let composition = GlyphComposer.compose(
            configuration: configuration,
            status: status,
            values: values,
            event: previewEvent,
            batteryColorMode: batteryMode
        )
        let usesBatteryRing = ring == .automatic || composition.ring?.mode == .battery
        let coding = composition.batteryColorCoding ?? batteryMode.colorCodingEnabled

        return VStack(spacing: 10) {
            DuoGlyphView(
                status: status,
                presentation: previewEvent.map(StatusPresentation.event) ?? .normal,
                metrics: DuoGlyphMetrics.standard.sized(76).withRingThickness(ringThickness).withCenterScale(centerIconScale),
                animationsEnabled: true,
                ringPresentation: composition.ring ?? (usesBatteryRing ? .battery(status.battery, colorCodingEnabled: coding, levelColorsEnabled: coding && batteryMode.levelColorsEnabled) : nil),
                centerStateOverride: composition.center,
                ringColorOverride: composition.ringColor,
                batteryColorCodingEnabled: coding,
                batteryLevelColorsEnabled: composition.batteryLevelColors ?? (coding && batteryMode.levelColorsEnabled),
                liveMomentCenters: true,
                dotCountOverride: composition.dots
            )
            .frame(width: 96, height: 96)

            HStack(spacing: 14) {
                legend(localized("Ring"), GlyphComposer.legend(ring: ring, status: status, values: values))
                legend(localized("Center"), centerLegend(values: values))
                legend(localized("Dots"), dotsLegend(values: values))
            }
            .font(.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            Text(localized("Preview with sample values"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var customColor: Binding<Color> {
        Binding(
            get: { HexColor.color(customColorHex) ?? .green },
            set: { newValue in
                if let hex = HexColor.hex(NSColor(newValue)) { customColorHex = hex }
            }
        )
    }

    private var resolvedMenuBarIconScale: Binding<Double> {
        Binding(
            get: { MenuBarIconSize.resolve(menuBarIconScale) },
            set: { menuBarIconScale = MenuBarIconSize.resolve($0) }
        )
    }

    private func legend(_ title: String, _ value: String) -> some View {
        HStack(spacing: 4) {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }

    private func centerLegend(values: GlyphSlotValues) -> String {
        switch center {
        case .network: localized("Wi-Fi")
        case .battery: localized("%d%%", Self.sampleStatus.battery.percentage ?? 0)
        case .cpu: values.cpu.map(SystemText.percent) ?? center.title
        case .none: center.title
        }
    }

    private func dotsLegend(values: GlyphSlotValues) -> String {
        switch dots {
        case .network:
            return "\(dots.title) \(NetworkSpeedFormatter.compact(values.networkBytesPerSecond ?? 0))B/s"
        case .volume:
            return "\(dots.title) \(Self.sampleStatus.audio.volume.percentage.map { localized("%d%%", $0) } ?? "")"
        default:
            return dots.title
        }
    }

    private func play(_ moment: LiveMoment) {
        let kind: StatusEvent.Kind
        switch moment {
        case .pluggedIn: kind = .charging
        case .audioConnected: kind = .audioDeviceConnected(Self.sampleAirPods)
        case .lowBattery: kind = .lowBattery
        case .networkLost: kind = .networkDisconnected
        case .volume: kind = .volumeChanged
        }
        let event = StatusEvent(kind: kind, priority: .informational, duration: 2.2)
        previewTask?.cancel()
        previewEvent = event
        previewTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else { return }
            previewEvent = nil
        }
    }

    // MARK: Sample data

    static let sampleAirPods = AudioDeviceStatus.previewAirPods

    static var sampleStatus: SystemStatus {
        var status = SystemStatus.unavailable
        status.battery = BatteryStatus(percentage: 90, isCharging: false, isPluggedIn: false, isFullyCharged: false, isAvailable: true)
        status.network = NetworkStatus(isAvailable: true, isConnected: true, transport: .wifi, interfaceName: "en0", isWiFiPoweredOn: true, ssid: nil, rssi: -50)
        status.audio.isAvailable = true
        status.audio.volume = OutputVolumeStatus(level: 0.5, isMuted: false, isSettable: true)
        return status
    }

    static let sampleValues = GlyphSlotValues(cpu: 0.34, memory: 0.62, disk: 0.77, networkBytesPerSecond: 12_000)
}

private struct LiveMomentRow: View {
    let moment: LiveMoment
    let onPlay: () -> Void
    @AppStorage private var isOn: Bool

    init(moment: LiveMoment, onPlay: @escaping () -> Void) {
        self.moment = moment
        self.onPlay = onPlay
        _isOn = AppStorage(wrappedValue: true, moment.key)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: moment.symbol)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(moment.title)
                Text(moment.footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(action: onPlay) {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .help(localized("Show in the preview"))
            .accessibilityLabel(localized("Show in the preview"))
            Toggle(moment.title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
