import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject private var statusStore: SystemStatusStore
    @ObservedObject private var router: PopoverRouter
    @ObservedObject private var registry: ModuleRegistry
    @ObservedObject private var presentation = PopoverPresentationState.shared
    @AppStorage(PreferenceKeys.showBatteryPercentage) private var showBatteryPercentage = true
    @AppStorage(PreferenceKeys.batteryColorCoding) private var batteryColorCoding = false
    @AppStorage(ModuleOption.nearbyNetworks.key) private var showsNearbyNetworks = ModuleOption.nearbyNetworks.defaultValue
    @AppStorage(DebugMode.key) private var debugMode = false
    @AppStorage(PopoverMotion.enabledKey) private var popoverAnimation = true
    private let onClose: () -> Void
    private let onContentSizeChange: (CGSize) -> Void

    init(
        statusStore: SystemStatusStore,
        onClose: @escaping () -> Void,
        onContentSizeChange: @escaping (CGSize) -> Void = { _ in }
    ) {
        self.statusStore = statusStore
        router = statusStore.popoverRouter
        registry = statusStore.moduleRegistry
        self.onClose = onClose
        self.onContentSizeChange = onContentSizeChange
    }

    var body: some View {
        PopoverGlassContainer {
            panelContent
        }
        .opacity(presentation.isShown ? 1 : 0)
        .animation(motion(PopoverMotion.openOpacity), value: presentation.isShown)
        .blur(radius: presentation.isShown || !popoverAnimation ? 0 : presentation.hiddenBlur)
        .animation(motion(PopoverMotion.openBlur), value: presentation.isShown)
        .scaleEffect(presentation.isShown || !popoverAnimation ? 1 : PopoverMotion.hiddenScale, anchor: .top)
        .animation(motion(PopoverMotion.openScale), value: presentation.isShown)
    }

    /// The open animation, the close animation, or none when turned off.
    private func motion(_ open: Animation) -> Animation? {
        guard popoverAnimation else { return nil }
        return presentation.isShown ? open : PopoverMotion.close
    }

    private var panelContent: some View {
        Group {
            if router.isPanelHidden {
                // Off screen: keep the hosting view cheap until the next open.
                Color.clear.frame(height: 1)
            } else {
                routedContent
            }
        }
        .padding(12)
        .frame(width: 304)
        .fixedSize(horizontal: false, vertical: true)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: PopoverContentSizeKey.self, value: proxy.size)
            }
        )
        .onPreferenceChange(PopoverContentSizeKey.self) { onContentSizeChange($0) }
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    @ViewBuilder
    private var routedContent: some View {
        switch router.route {
        case .main:
            mainContent
        case .detail(let id):
            ModuleDetailContainer(
                title: id.title,
                maxContentHeight: detailMaxContentHeight,
                onBack: router.back
            ) {
                moduleDetail(id)
            }
        }
    }

    /// Popover padding (2 × 12), the detail header and its spacing.
    private var detailMaxContentHeight: CGFloat {
        max(router.maxContentHeight - 24 - PopoverDesign.compactRowHeight - PopoverDesign.rowSpacing, 120)
    }

    private var mainContent: some View {
        VStack(spacing: 8) {
            ForEach(registry.visibleModules) { id in
                moduleRow(id)
            }

            // DuoBar+: volume and output share one card.
            VStack(spacing: 0) {
                VolumeStatusRow(
                    volume: statusStore.status.audio.volume,
                    hasOutputDevice: statusStore.status.audio.defaultOutput != nil,
                    playbackDeviceIdentifier: statusStore.status.audio.defaultOutput?.uid,
                    onSetVolume: statusStore.setVolume,
                    onSetMuted: statusStore.setMuted,
                    showsCard: false
                )

                Divider()
                    .padding(.horizontal, PopoverDesign.horizontalPadding)

                AudioOutputRow(
                    symbol: audioOutputSymbol,
                    title: localized("Audio Output"),
                    detail: audioOutputDetail,
                    stateText: audioOutputState,
                    outputs: statusStore.status.audio.selectableOutputs,
                    selectedUID: statusStore.status.audio.defaultOutput?.uid,
                    onSelect: { statusStore.setDefaultOutput(uid: $0) },
                    onOpenSoundSettings: openSoundSettings,
                    onOpenBluetoothSettings: { SystemSettingsOpener.open(.bluetooth) },
                    showsCard: false
                )
            }
            .popoverRowCard(true)

            AudioOutputRow(
                symbol: audioInputSymbol,
                title: localized("Audio Input"),
                detail: audioInputDetail,
                stateText: audioInputState,
                outputs: statusStore.status.audio.selectableInputs,
                selectedUID: statusStore.status.audio.defaultInput?.uid,
                onSelect: { statusStore.setDefaultInput(uid: $0) },
                onOpenSoundSettings: openSoundSettings,
                onOpenBluetoothSettings: {},
                emptyText: localized("No input devices"),
                failureText: localized("Unable to Switch Input"),
                hint: localized("Select audio input"),
                showsBluetoothSettings: false
            )

            #if DEBUG
            if debugMode {
                DebugStatusSimulatorView(statusStore: statusStore)
            }
            #endif

            // Development diagnostics belong in the dedicated DEBUG diagnostics
            // surface, never in the production status-card hierarchy.
            HStack(spacing: 6) {
                settingsAction

                Spacer()

                Button(localized("Quit DuoBar")) {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .frame(height: 24)
                .background(Color.primary.opacity(0.1), in: Capsule())
            }
            .padding(.leading, PopoverDesign.horizontalPadding)
            .padding(.trailing, 7)
            .frame(height: PopoverDesign.compactRowHeight)
            .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
        }
    }

    @ViewBuilder
    private func moduleRow(_ id: ModuleID) -> some View {
        switch id {
        case .network:
            if let networkModule = statusStore.networkModule {
                NetworkStatusRow(
                    statusStore: statusStore,
                    module: networkModule,
                    trailing: wifiPowerToggle,
                    onActivate: { router.open(.network) }
                )
            }
        case .battery:
            Button { router.open(.battery) } label: {
                BatteryStatusRow(
                    battery: statusStore.status.battery,
                    showPercentage: showBatteryPercentage,
                    showsDisclosure: true,
                    timeEstimate: statusStore.batteryTimeEstimate
                )
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .accessibilityHint(localized("Show details"))
        case .disk:
            if let diskModule = statusStore.diskModule {
                DiskStatusRow(module: diskModule) { router.open(.disk) }
            }
        case .aiUsage:
            if let aiUsageModule = statusStore.aiUsageModule {
                AIUsageStatusRow(module: aiUsageModule) { router.open(.aiUsage) }
            }
        case .system:
            if let systemModule = statusStore.systemModule {
                SystemStatusRow(module: systemModule) { router.open(.system) }
            }
        case .bluetooth:
            if let bluetoothModule = statusStore.bluetoothModule {
                BluetoothStatusRow(statusStore: statusStore, module: bluetoothModule) { router.open(.bluetooth) }
            }
        }
    }

    @ViewBuilder
    private func moduleDetail(_ id: ModuleID) -> some View {
        switch id {
        case .network:
            NetworkDetailView(
                statusStore: statusStore,
                module: statusStore.networkModule,
                nearbyNetworks: showsNearbyNetworks
                    ? AnyView(NearbyWiFiButton(statusStore: statusStore, onOpenSettings: openWiFiSettings))
                    : nil,
                onOpenSettings: openNetworkSettings
            )
        case .battery:
            BatteryDetailView(statusStore: statusStore, module: statusStore.batteryModule, onOpenSettings: openBatterySettings)
        case .disk:
            if let diskModule = statusStore.diskModule {
                DiskDetailView(module: diskModule, onOpenSettings: openStorageSettings, onDidOpenVolume: onClose)
            }
        case .aiUsage:
            if let aiUsageModule = statusStore.aiUsageModule {
                AIUsageDetailView(module: aiUsageModule)
            }
        case .system:
            if let systemModule = statusStore.systemModule {
                SystemDetailView(module: systemModule) {
                    SystemDetailView.openActivityMonitor()
                    onClose()
                }
            }
        case .bluetooth:
            if let bluetoothModule = statusStore.bluetoothModule {
                BluetoothDetailView(
                    statusStore: statusStore,
                    module: bluetoothModule,
                    onOpenSettings: {
                        SystemSettingsOpener.open(.bluetooth)
                        onClose()
                    },
                    onOpenPrivacySettings: {
                        SystemSettingsOpener.open(.bluetoothPrivacy)
                        onClose()
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var settingsAction: some View {
        if #available(macOS 14.0, *) {
            SettingsLink {
                settingsLabel
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture().onEnded {
                NSApp.activate(ignoringOtherApps: true)
                onClose()
            })
        } else {
            Button(action: openSettingsFromApplicationMenu) {
                settingsLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var settingsLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape")
                .font(.system(size: 14))
                .frame(width: 22)
            Text(localized("Settings"))
                .font(PopoverDesign.compactTitleFont)
        }
        .contentShape(Rectangle())
    }

    private func openSettingsFromApplicationMenu() {
        NSApp.activate(ignoringOtherApps: true)
        if let settingsItem = findSettingsMenuItem(in: NSApp.mainMenu), let action = settingsItem.action {
            NSApp.sendAction(action, to: settingsItem.target, from: settingsItem)
        }
        onClose()
    }

    private func findSettingsMenuItem(in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.keyEquivalent == ",", item.keyEquivalentModifierMask.contains(.command) {
                return item
            }
            if let settingsItem = findSettingsMenuItem(in: item.submenu) {
                return settingsItem
            }
        }
        return nil
    }

    private func openNetworkSettings() {
        _ = SystemSettingsOpener.open(SystemSettingsOpener.pane(for: statusStore.status.network))
        onClose()
    }

    private func openWiFiSettings() {
        _ = SystemSettingsOpener.open(.wifi)
        onClose()
    }

    private func openBatterySettings() {
        _ = SystemSettingsOpener.open(.battery)
        onClose()
    }

    private func openStorageSettings() {
        _ = SystemSettingsOpener.open(.storage)
        onClose()
    }

    private func openSoundSettings() {
        _ = SystemSettingsOpener.open(.sound)
        onClose()
    }

    private var wifiPowerToggle: AnyView? {
        guard let wifiPowerState = statusStore.status.network.isWiFiPoweredOn else { return nil }
        return AnyView(
            Toggle(localized("Wi-Fi power"), isOn: Binding(
                get: { wifiPowerState },
                set: { statusStore.setWiFiPower($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .accessibilityLabel(localized("Wi-Fi power"))
        )
    }

    private var audioOutputSymbol: String {
        guard let output = statusStore.status.audio.defaultOutput else { return "speaker.slash" }
        switch output.category {
        case .airPods: return "airpodspro"
        case .headphones, .bluetoothAudio: return "headphones"
        case .displayAudio: return "display"
        case .usbAudio, .builtInSpeaker, .other: return "speaker.wave.2"
        }
    }

    private var audioOutputDetail: String {
        statusStore.status.audio.defaultOutput?.name ?? localized("No output device")
    }

    private var audioInputSymbol: String {
        statusStore.status.audio.defaultInput == nil ? "mic.slash" : "mic"
    }

    private var audioInputDetail: String {
        statusStore.status.audio.defaultInput?.name ?? localized("No input device")
    }

    private var audioInputState: String {
        guard let input = statusStore.status.audio.defaultInput else { return localized("Unavailable") }
        switch input.transport {
        case .builtIn: return localized("Built-in")
        case .bluetooth, .bluetoothLE: return localized("Bluetooth")
        case .usb: return localized("USB")
        case .hdmi, .displayPort: return localized("Display")
        case .airPlay: return localized("AirPlay")
        case .virtual: return localized("Virtual")
        case .other: return localized("Connected")
        }
    }

    private var audioOutputState: String {
        guard let output = statusStore.status.audio.defaultOutput else { return localized("Unavailable") }
        if output.transport.isBluetooth {
            return output.temporaryGlyph == .airPods ? localized("AirPods") : localized("Bluetooth")
        }
        switch output.transport {
        case .builtIn: return localized("Built-in")
        case .airPlay: return localized("AirPlay")
        case .usb: return localized("USB")
        case .hdmi, .displayPort: return localized("Display")
        case .virtual: return localized("Virtual")
        case .bluetooth, .bluetoothLE: return localized("Bluetooth")
        case .other: return localized("Connected")
        }
    }
}

private struct PopoverContentSizeKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct BatteryStatusRow: View {
    let battery: BatteryStatus
    let showPercentage: Bool
    var showsDisclosure = false
    var timeEstimate: BatteryTimeEstimate = .unavailable

    var body: some View {
        HStack(spacing: 11) {
            IconTile(symbol: symbol)

            VStack(alignment: .leading, spacing: 1) {
                Text(localized("Battery"))
                    .font(PopoverDesign.titleFont)
                    .lineLimit(1)
                Text([detail, secondaryDetail].compactMap { $0 }.joined(separator: " · "))
                    .font(PopoverDesign.subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            if let trailingValue {
                ValueBadge(text: trailingValue)
            }

            if showsDisclosure {
                RowChevron()
            }
        }
        .padding(.horizontal, PopoverDesign.horizontalPadding)
        .frame(height: PopoverDesign.rowHeight)
        .contentShape(Rectangle())
        .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
    }

    var trailingValue: String? {
        guard showPercentage, let percentage = battery.percentage else { return nil }
        return localized("%d%%", percentage)
    }

    var detail: String {
        guard battery.isAvailable else { return localized("No internal battery") }
        if battery.isFullyCharged { return localized("Fully charged") }
        if battery.isCharging { return localized("Charging") }
        if battery.isPluggedIn { return localized("Charging On Hold") }
        if battery.isLowPowerModeEnabled { return localized("Low Power Mode") }
        return localized("Using battery power")
    }

    var secondaryDetail: String? {
        guard battery.isAvailable else { return nil }
        switch timeEstimate {
        case .toFull(let minutes):
            return localized("%@ to full", BatteryTimeFormatter.duration(minutes: minutes))
        case .toEmpty(let minutes):
            return localized("%@ left", BatteryTimeFormatter.duration(minutes: minutes))
        case .calculating:
            return localized("Calculating…")
        case .unavailable:
            break
        }
        return battery.isPluggedIn ? localized("Using Adapter") : nil
    }

    var symbol: String {
        if battery.isFullyCharged { return "battery.100percent" }
        if battery.isCharging { return "battery.100percent.bolt" }
        switch battery.percentage ?? 0 {
        case 76...100: return "battery.100percent"
        case 51...75: return "battery.75percent"
        case 26...50: return "battery.50percent"
        default: return "battery.25percent"
        }
    }
}

#if DEBUG
private struct DebugStatusSimulatorView: View {
    let statusStore: SystemStatusStore
    @AppStorage(PreferenceKeys.batteryColorCoding) private var batteryColorCoding = false
    @ObservedObject private var adaptiveRingMonitor = AdaptiveRingMonitor.shared

    var body: some View {
        Menu {
            Menu("Simulate") {
                simulationControls
            }

            Menu("Diagnostics") {
                diagnosticItem("Laptop Ring Mode", value: laptopRingModeLabel)
                diagnosticItem("Charging session", value: chargingSessionLabel)
                diagnosticItem("Waiting for full charge", value: waitingForFullChargeLabel)
                diagnosticItem("Adaptive telemetry lease", value: adaptiveRingMonitor.monitoringOwnerCount > 0 ? "Active" : "Inactive")
                diagnosticItem("Adaptive monitor", value: adaptiveRingMonitor.isMonitoring ? "Running" : "Stopped")
                diagnosticItem("Adaptive source", value: adaptiveRingMonitor.debugTestSource.rawValue)
                diagnosticItem("Brightness", value: brightnessLabel)
                diagnosticItem("Adaptive metric", value: adaptiveRingMonitor.state.diagnosticLabel)
                diagnosticItem("Adaptive progress", value: adaptiveProgressLabel)
                diagnosticItem("Final ring target", value: finalRingOverrideLabel)
            }
        } label: {
            CompactRowLabel(symbol: "hammer", title: "Debug Simulator", trailing: debugSummary)
        }
        .menuStyle(.borderlessButton)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // A SwiftUI Menu collapses its label to icon and title, so size the
        // card here to match the other compact rows.
        .padding(.horizontal, PopoverDesign.horizontalPadding)
        .frame(maxWidth: .infinity, minHeight: PopoverDesign.compactRowHeight, alignment: .leading)
        .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
    }

    @ViewBuilder
    private var simulationControls: some View {
        Menu("Battery Level") {
            ForEach(DebugBatteryLevel.allCases) { level in
                Button(level.title) { statusStore.applyDebugBatteryLevel(level) }
            }
        }
        Menu("Battery Power") {
            ForEach(DebugPowerState.allCases) { powerState in
                Button(powerState.rawValue) { statusStore.applyDebugPowerState(powerState) }
            }
        }
        Menu("Low Power Mode") {
            ForEach(DebugLowPowerMode.allCases) { lowPowerMode in
                Button(lowPowerMode.rawValue) { statusStore.applyDebugLowPowerMode(lowPowerMode) }
            }
        }
        Menu("Battery Color Coding") {
            ForEach(BatteryRingColorMode.allCases) { mode in
                Button(mode.title) {
                    UserDefaults.standard.set(mode.rawValue, forKey: BatteryRingColorMode.key)
                    batteryColorCoding = mode.colorCodingEnabled
                }
            }
        }
        Menu("MacBook Adaptive Ring") {
            Button("Battery / Unplugged") {
                statusStore.applyDebugAdaptiveBatteryBaseline()
                adaptiveRingMonitor.clearDebugSyntheticInput()
            }
            Button("Charging") {
                scheduleAdaptiveChargingSimulation()
            }
            Divider()
            Button("Adaptive — Neutral") { scheduleAdaptive(.neutral) }
            Button("Adaptive — Brightness") { scheduleAdaptive(.brightness50) }
            Button("Adaptive — CPU") { scheduleAdaptive(.cpuHigh) }
            Button("Adaptive — Memory") { scheduleAdaptive(.memoryPressure) }
            Button("Adaptive — Thermal") { scheduleAdaptive(.thermalSerious) }
            Divider()
            Button("Use Live System State") {
                adaptiveRingMonitor.clearDebugSyntheticInput()
                statusStore.restoreLiveStatus()
            }
        }
        Menu("Network") {
            ForEach(DebugNetworkState.allCases) { networkState in
                Button(networkState.rawValue) { statusStore.applyDebugNetworkState(networkState) }
            }
        }
        Menu("Volume") {
            ForEach(DebugVolumeState.allCases) { volumeState in
                Button(volumeState.rawValue) { statusStore.applyDebugVolumeState(volumeState) }
            }
        }
        Menu("Audio Connection") {
            ForEach(DebugAudioDeviceState.allCases) { deviceState in
                Button(deviceState.rawValue) { statusStore.applyDebugAudioDeviceState(deviceState) }
            }
        }
        Divider()
        Button("Restore Live Data") { statusStore.restoreLiveStatus() }
    }

    private func diagnosticItem(_ title: String, value: String) -> some View {
        Button("\(title): \(value)") {}
            .disabled(true)
    }

    private var debugSummary: String {
        "\(laptopRingModeLabel) · \(adaptiveRingMonitor.debugTestSource.rawValue)"
    }

    private var laptopRingModeLabel: String {
        switch statusStore.laptopRingModeState.mode {
        case .battery: "Battery"
        case .adaptive: "Adaptive"
        }
    }

    private var chargingSessionLabel: String {
        guard let start = statusStore.laptopRingModeState.sessionStartPercentage,
              let target = statusStore.laptopRingModeState.targetPercentage
        else { return "None" }
        let waiting = statusStore.laptopRingModeState.isWaitingForFullChargeDelay ? " · waiting for full delay" : ""
        return "\(start)% → \(target)%\(waiting)"
    }

    private var waitingForFullChargeLabel: String {
        statusStore.laptopRingModeState.isWaitingForFullChargeDelay ? "Yes" : "No"
    }

    private var brightnessLabel: String {
        guard let availability = adaptiveRingMonitor.brightnessSnapshot?.availability else { return "Sampling…" }
        switch availability {
        case .available(let value): return String(format: "%.0f%%", value * 100)
        case .unavailable: return "Unavailable"
        }
    }

    private var adaptiveProgressLabel: String {
        let target = AdaptiveRingVisualTarget(state: adaptiveRingMonitor.state).progress
        return String(format: "%.1f%%", target * 100)
    }

    private var finalRingOverrideLabel: String {
        guard statusStore.usesAdaptiveRing else { return "Battery Ring" }
        let target = AdaptiveRingVisualTarget(state: adaptiveRingMonitor.state).progress
        return String(format: "%.1f%%", target * 100)
    }

    private func scheduleAdaptiveChargingSimulation() {
        Task { @MainActor in
            statusStore.applyDebugAdaptiveChargingBaseline()
            adaptiveRingMonitor.clearDebugSyntheticInput()
            adaptiveQALog("DEBUG controller prepared at 50%; visible Charging percentage preserved; awaiting 80% target")
        }
    }

    private func scheduleAdaptive(_ scenario: AdaptiveRingSyntheticScenario) {
        Task { @MainActor in
            await activateAdaptive(scenario)
        }
    }

    @MainActor
    private func activateAdaptive(_ scenario: AdaptiveRingSyntheticScenario) async {
        if statusStore.laptopRingModeState.mode == .adaptive {
            useAdaptiveSourceScenario(scenario)
            return
        }

        // Direct selection first lets the real Charging presentation settle.
        if statusStore.laptopRingModeState.targetPercentage != DebugBatteryLevel.eighty.rawValue
            || !statusStore.status.battery.isCharging {
            statusStore.applyDebugAdaptiveChargingBaseline()
            try? await Task.sleep(for: .seconds(BatteryChargingAnimationProfile.entranceDuration))
            guard !Task.isCancelled else { return }
        }

        useAdaptiveSourceScenario(scenario)
        await Task.yield()
        statusStore.reachDebugAdaptiveTarget()
        adaptiveQALog("DEBUG crossed controller target without publishing a synthetic battery jump for \(scenario.rawValue)")
    }

    private func useAdaptiveSourceScenario(_ scenario: AdaptiveRingSyntheticScenario) {
        let preference: PerformancePreference = scenario == .memoryPressure ? .memory : .automatic
        adaptiveRingMonitor.useDebugSyntheticInput(
            scenario.input,
            label: scenario.rawValue,
            preference: preference
        )
    }

    private func adaptiveQALog(_ message: String) {
        NSLog("%@", "[DuoBar Adaptive QA] \(message)")
    }
}
#endif
