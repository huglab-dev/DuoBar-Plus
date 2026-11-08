import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @AppStorage(PreferenceKeys.showBatteryPercentage) private var showBatteryPercentage = true
    @AppStorage(PreferenceKeys.animationsEnabled) private var animationsEnabled = true
    @AppStorage(PreferenceKeys.menuBarIconScale) private var menuBarIconScale = MenuBarIconSize.defaultScale
    @AppStorage(PreferenceKeys.batteryColorCoding) private var batteryColorCoding = false
    @AppStorage(BatteryRingColorMode.key) private var batteryRingColorModeRaw = BatteryRingColorMode.byLevel.rawValue
    @AppStorage(PreferenceKeys.adaptiveRingPriority) private var adaptiveRingPriorityRaw = PerformancePreference.automatic.rawValue
    @AppStorage(PreferenceKeys.adaptiveRingColorCoding) private var adaptiveRingColorCoding = false
    @AppStorage(PreferenceKeys.openOnHover) private var openOnHover = false
    @AppStorage(UnfoldOnHover.key) private var unfoldOnHover = false
    @AppStorage(HoverDelay.key) private var hoverDelay = HoverDelay.defaultSeconds
    @AppStorage(DebugMode.key) private var debugMode = false
    @AppStorage(PopoverMotion.enabledKey) private var popoverAnimation = true
    @AppStorage(PreferenceKeys.showInDock) private var showInDock = false
    @AppStorage(PreferenceKeys.showBatteryPercentageInMenuBar) private var showBatteryPercentageInMenuBar = false
    @AppStorage(BatteryPercentagePlacement.key) private var batteryPercentagePlacement = BatteryPercentagePlacement.inside
    @StateObject private var launchAtLogin = LaunchAtLoginService()
    @ObservedObject private var adaptiveRingMonitor = AdaptiveRingMonitor.shared
    private let deviceContextService = DeviceContextService()
    #if DEBUG
    @AppStorage(PreferenceKeys.simulateDesktopMac) private var simulateDesktopMac = false
    #endif

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label(localized("General"), systemImage: "gearshape") }
            IndicatorSettingsView()
                .tabItem { Label(localized("Indicator"), systemImage: "circle.dashed") }
            ModuleSettingsView(hasInternalBattery: hasInternalBattery)
                .tabItem { Label(localized("Modules"), systemImage: "square.grid.2x2") }
        }
    }

    private var generalSettings: some View {
        Form {
            Section(localized("Menu Bar")) {
                Toggle(localized("Show battery percentage in popover"), isOn: $showBatteryPercentage)
                Toggle(localized("Battery Percentage"), isOn: $showBatteryPercentageInMenuBar)
                if showBatteryPercentageInMenuBar {
                    Picker(localized("Percentage Position"), selection: $batteryPercentagePlacement) {
                        ForEach(BatteryPercentagePlacement.allCases) { placement in
                            Text(placement.title).tag(placement)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                Toggle(localized("Enable animations"), isOn: $animationsEnabled)
                Toggle(localized("Popover Animation"), isOn: $popoverAnimation)

            }

            Section(localized("General")) {
                // DuoBar+: one setting for both hover behaviors.
                VStack(alignment: .leading, spacing: 4) {
                    Picker(localized("When Pointing at the Icon"), selection: hoverAction) {
                        ForEach(HoverAction.allCases) { Text($0.title).tag($0) }
                    }
                    Text(hoverAction.wrappedValue.footnote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if hoverAction.wrappedValue != .none {
                        HStack(spacing: 10) {
                            Text(localized("Hover Delay"))
                            Slider(value: $hoverDelay, in: HoverDelay.range, step: 0.05)
                                .accessibilityLabel(localized("Hover Delay"))
                                .accessibilityValue(HoverDelay.text(hoverDelay))
                            Text(HoverDelay.text(hoverDelay))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                        .padding(.top, 4)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Toggle(localized("Show in Dock"), isOn: $showInDock)
                        .toggleStyle(.switch)
                    Text(localized("Show the DuoBar icon in the Dock. Clicking it opens Settings."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle(
                    localized("Launch DuoBar at login"),
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: launchAtLogin.setEnabled
                    )
                )

                if launchAtLogin.requiresApproval {
                    Text(localized("Approval is required in System Settings → General → Login Items."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = launchAtLogin.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }

            if showsBatteryRingSettings {
                Section(localized("Battery Ring")) {
                    Picker(localized("Battery Color Coding"), selection: batteryRingColorMode) {
                        ForEach(BatteryRingColorMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    Text(localized("By Level: green from 50 %, yellow from 20 %, orange from 10 %, red below. Green while charging and yellow in Low Power Mode, except in Monochrome."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if showsAdaptiveRingSettings {
                Section(localized("Adaptive Ring")) {
                    Picker(localized("Adaptive Ring Priority"), selection: adaptiveRingPriority) {
                        ForEach(PerformancePreference.allCases, id: \.self) { preference in
                            Text(preference.localizedDisplayName).tag(preference)
                        }
                    }
                    Text(localized("Used only when multiple system conditions need attention. Critical conditions can still take priority."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle(localized("Adaptive Ring Color Coding"), isOn: $adaptiveRingColorCoding)
                }
            }

            // DuoBar+: the credits are in every build; debug tools only with Debug Mode on.
            Section(localized("Developer")) {
                AboutCreditsView()
                #if DEBUG
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(localized("Debug Mode"), isOn: $debugMode)
                        .toggleStyle(.switch)
                    Text(localized("Shows the debug simulator in the popover and the diagnostics below."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif
            }
            #if DEBUG
            if debugMode {
                DebugPerformanceDiagnosticsView()
                DebugDuoGlyphTuningView()
            }
            #endif
        }
        .formStyle(.grouped)
        .scenePadding()
        .frame(width: 420, height: settingsHeight)
        .navigationTitle(localized("DuoBar Settings"))
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            launchAtLogin.refresh()
            if showsAdaptiveRingSettings {
                adaptiveRingMonitor.setPreference(adaptiveRingPriority.wrappedValue)
            }
        }
        .onChange(of: adaptiveRingPriorityRaw) { _ in
            if showsAdaptiveRingSettings {
                adaptiveRingMonitor.setPreference(adaptiveRingPriority.wrappedValue)
            }
        }
    }

    private var settingsHeight: CGFloat {
        #if DEBUG
        debugMode ? 850 : 480
        #else
        360
        #endif
    }

    private var batteryRingColorMode: Binding<BatteryRingColorMode> {
        Binding(
            get: { BatteryRingColorMode(rawValue: batteryRingColorModeRaw) ?? .byLevel },
            set: {
                batteryRingColorModeRaw = $0.rawValue
                // Keep upstream's flag in step for code that still reads it.
                batteryColorCoding = $0.colorCodingEnabled
            }
        )
    }

    private var hoverAction: Binding<HoverAction> {
        Binding(
            get: { unfoldOnHover ? .unfold : (openOnHover ? .openPopover : .none) },
            set: { action in
                openOnHover = action == .openPopover
                unfoldOnHover = action == .unfold
            }
        )
    }

    private var adaptiveRingPriority: Binding<PerformancePreference> {
        Binding(
            get: { PerformancePreference(rawValue: adaptiveRingPriorityRaw) ?? .automatic },
            set: { adaptiveRingPriorityRaw = $0.rawValue }
        )
    }

    private var resolvedMenuBarIconScale: Binding<Double> {
        Binding(
            get: { MenuBarIconSize.resolve(menuBarIconScale) },
            set: { menuBarIconScale = MenuBarIconSize.resolve($0) }
        )
    }

    private var showsAdaptiveRingSettings: Bool {
        #if DEBUG
        AdaptiveRingSettingsEligibility.isEligible(
            for: deviceContextService.current(),
            simulateDesktop: simulateDesktopMac
        )
        #else
        AdaptiveRingSettingsEligibility.isEligible(for: deviceContextService.current())
        #endif
    }

    private var hasInternalBattery: Bool {
        #if DEBUG
        deviceContextService.current(simulateDesktop: simulateDesktopMac).hasInternalBattery
        #else
        deviceContextService.current().hasInternalBattery
        #endif
    }

    private var showsBatteryRingSettings: Bool {
        #if DEBUG
        deviceContextService.current(simulateDesktop: simulateDesktopMac).ringBehavior == .batteryRing
        #else
        deviceContextService.current().ringBehavior == .batteryRing
        #endif
    }
}
