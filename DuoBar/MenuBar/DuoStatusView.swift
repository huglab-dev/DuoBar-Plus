import SwiftUI

struct DuoStatusView: View {
    @ObservedObject private var statusStore: SystemStatusStore
    @ObservedObject private var priorityController: StatusPriorityController
    @ObservedObject private var adaptiveRingMonitor = AdaptiveRingMonitor.shared
    @ObservedObject private var glyphSlots: GlyphSlotSampler
    @ObservedObject private var hoverState: StatusItemHoverState
    @State private var unfoldedWidth: CGFloat = 0
    @AppStorage(RingSlot.key) private var ringSlotRaw = RingSlot.automatic.rawValue
    @AppStorage(CenterSlot.key) private var centerSlotRaw = CenterSlot.network.rawValue
    @AppStorage(DotsSlot.key) private var dotsSlotRaw = DotsSlot.volume.rawValue
    @AppStorage(GlyphColorStyle.key) private var glyphColorRaw = GlyphColorStyle.automatic.rawValue
    @AppStorage(GlyphColorStyle.customColorKey) private var customRingColorHex = GlyphColorStyle.defaultCustomColorHex
    @AppStorage(RingThickness.key) private var ringThickness = RingThickness.defaultScale
    @AppStorage(CenterIconSize.key) private var centerIconScale = CenterIconSize.defaultScale
    @AppStorage(PreferenceKeys.animationsEnabled) private var animationsEnabled = true
    @AppStorage(PreferenceKeys.menuBarIconScale) private var menuBarIconScale = MenuBarIconSize.defaultScale
    @AppStorage(BatteryRingColorMode.key) private var batteryRingColorModeRaw = BatteryRingColorMode.byLevel.rawValue
    @AppStorage(PreferenceKeys.adaptiveRingColorCoding) private var adaptiveRingColorCoding = false
    @AppStorage(PreferenceKeys.showBatteryPercentageInMenuBar) private var showBatteryPercentageInMenuBar = false
    @AppStorage(BatteryPercentagePlacement.key) private var batteryPercentagePlacementRaw = BatteryPercentagePlacement.inside.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var batteryRingColorMode: BatteryRingColorMode {
        BatteryRingColorMode(rawValue: batteryRingColorModeRaw) ?? .byLevel
    }

    private var batteryColorCoding: Bool { batteryRingColorMode.colorCodingEnabled }

    /// DuoBar+: indicator slots and live moments on top of upstream's glyph.
    private var glyphConfiguration: GlyphConfiguration {
        GlyphConfiguration(
            ring: RingSlot(rawValue: ringSlotRaw) ?? .automatic,
            center: CenterSlot(rawValue: centerSlotRaw) ?? .network,
            dots: DotsSlot(rawValue: dotsSlotRaw) ?? .volume,
            color: GlyphColorStyle(rawValue: glyphColorRaw) ?? .automatic,
            customColorHex: customRingColorHex
        )
    }

    private var glyphSlotValues: GlyphSlotValues {
        GlyphSlotValues(
            cpu: glyphSlots.cpu,
            memory: glyphSlots.memory,
            disk: glyphSlots.disk,
            networkBytesPerSecond: glyphSlots.networkBytesPerSecond
        )
    }

    private var glyphComposition: GlyphComposition {
        GlyphComposer.compose(
            configuration: glyphConfiguration,
            status: statusStore.status,
            values: glyphSlotValues,
            event: priorityController.presentation.event,
            batteryColorMode: batteryRingColorMode
        )
    }
    @State private var adaptiveRingOwner = UUID()
    @State private var temporaryAdaptiveSource: AdaptiveRingSourceIdentity?
    @State private var lastAdaptiveSource: AdaptiveRingSourceIdentity?
    @State private var adaptiveSourcePresentationsEnabled = false
    @State private var adaptiveRingPresentationState = AdaptiveRingPresentationState()
    @State private var adaptiveRingTransition: AdaptiveRingPresentationTransition = .none
    @State private var adaptiveSessionIsSynchronized = false
    @State private var lastLaptopRingMode: LaptopRingMode
    @State private var adaptiveEntryCenterOverride: DuoCenterState?

    #if DEBUG
    @AppStorage(DuoGlyphTuningKeys.overallSize) private var overallSize = Double(DuoGlyphMetrics.standard.overallSize)
    @AppStorage(DuoGlyphTuningKeys.ringDiameter) private var ringDiameter = Double(DuoGlyphMetrics.standard.ringDiameter)
    @AppStorage(DuoGlyphTuningKeys.ringLineWidth) private var ringLineWidth = Double(DuoGlyphMetrics.standard.ringLineWidth)
    @AppStorage(DuoGlyphTuningKeys.arcGap) private var arcGap = DuoGlyphMetrics.standard.arcGap
    @AppStorage(DuoGlyphTuningKeys.wifiSymbolSize) private var wifiSymbolSize = Double(DuoGlyphMetrics.standard.wifiSymbolSize)
    @AppStorage(DuoGlyphTuningKeys.wifiYOffset) private var wifiYOffset = Double(DuoGlyphMetrics.standard.wifiYOffset)
    @AppStorage(DuoGlyphTuningKeys.dotDiameter) private var dotDiameter = Double(DuoGlyphMetrics.standard.dotDiameter)
    @AppStorage(DuoGlyphTuningKeys.dotSpacing) private var dotSpacing = Double(DuoGlyphMetrics.standard.dotSpacing)
    @AppStorage(DuoGlyphTuningKeys.dotYOffset) private var dotYOffset = Double(DuoGlyphMetrics.standard.dotYOffset)
    @AppStorage(PreferenceKeys.simulateDesktopMac) private var simulateDesktopMac = false
    #endif

    private let onWidthChange: (CGFloat) -> Void

    init(
        statusStore: SystemStatusStore,
        hoverState: StatusItemHoverState? = nil,
        onWidthChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.statusStore = statusStore
        self.priorityController = statusStore.priorityController
        _glyphSlots = ObservedObject(wrappedValue: statusStore.glyphSlotSampler)
        _hoverState = ObservedObject(wrappedValue: hoverState ?? StatusItemHoverState())
        self.onWidthChange = onWidthChange
        _lastLaptopRingMode = State(initialValue: statusStore.laptopRingModeState.mode)
        _adaptiveEntryCenterOverride = State(initialValue: nil)
    }

    private var targetWidth: CGFloat {
        if hoverState.isUnfolded, unfoldedWidth > 0 {
            return unfoldedWidth + 4
        }
        return metrics.statusItemWidth + MenuBarBatteryPercentage.extraWidth(for: besidePercentage)
    }

    /// DuoBar+: one reading per slot for the unfolded mark.
    private var unfoldSegments: [UnfoldSegment] {
        UnfoldSegmentBuilder.segments(
            configuration: glyphConfiguration,
            status: statusStore.status,
            values: glyphSlotValues
        )
    }

    private var batteryPercentagePlacement: BatteryPercentagePlacement {
        BatteryPercentagePlacement(rawValue: batteryPercentagePlacementRaw) ?? .inside
    }

    /// The percentage drawn next to the glyph (DuoBar+), or nil.
    private var besidePercentage: Int? {
        MenuBarBatteryPercentage.visiblePercentage(
            battery: statusStore.status.battery,
            isEnabled: showBatteryPercentageInMenuBar,
            placement: batteryPercentagePlacement
        )
    }

    private var animation: Animation? {
        animationsEnabled ? AnimationConstants.statusMorph : nil
    }

    var body: some View {
        // Swift 6.4 no longer resolves State projections captured directly by
        // the result-builder modifier closures. Capture bindings once so the
        // closures retain the same state storage without changing behavior.
        let temporaryAdaptiveSourceBinding = $temporaryAdaptiveSource
        let lastAdaptiveSourceBinding = $lastAdaptiveSource
        let adaptiveSourcePresentationsEnabledBinding = $adaptiveSourcePresentationsEnabled
        let adaptiveRingPresentationStateBinding = $adaptiveRingPresentationState
        let adaptiveRingTransitionBinding = $adaptiveRingTransition
        let adaptiveSessionIsSynchronizedBinding = $adaptiveSessionIsSynchronized
        let lastLaptopRingModeBinding = $lastLaptopRingMode
        let adaptiveEntryCenterOverrideBinding = $adaptiveEntryCenterOverride

        Group {
            if hoverState.isUnfolded {
                UnfoldedStatusView(segments: unfoldSegments) { frames in
                    hoverState.setSegmentFrames(frames)
                }
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: UnfoldedWidthKey.self, value: proxy.size.width)
                    }
                )
                .transition(.opacity)
            } else {
            HStack(spacing: MenuBarBatteryPercentage.spacing) {
                let composition = glyphComposition
                DuoGlyphView(
                    status: statusStore.status,
                    presentation: priorityController.presentation,
                    metrics: metrics,
                    animationsEnabled: animationsEnabled,
                    ringPresentation: composition.ring ?? resolvedRingPresentation,
                    centerStateOverride: composition.center ?? centerStateOverride,
                    ringTransitionAnimation: composition.usesAutomaticRing ? adaptiveRingAnimation : nil,
                    usesCustomRingTransition: usesAdaptiveRing && composition.usesAutomaticRing,
                    ringColorOverride: composition.ringColor ?? adaptiveRingColor,
                    batteryColorCodingEnabled: composition.batteryColorCoding ?? batteryColorCoding,
                    showBatteryPercentage: showBatteryPercentageInMenuBar && batteryPercentagePlacement == .inside,
                    batteryLevelColorsEnabled: composition.batteryLevelColors
                        ?? (batteryRingColorMode.levelColorsEnabled && (composition.batteryColorCoding ?? batteryColorCoding)),
                    liveMomentCenters: true,
                    dotCountOverride: composition.dots,
                    animatesSampledValues: glyphConfiguration.neededMetrics.isEmpty
                )
                .offset(y: DuoGlyphMetrics.menuBarVerticalOffset)
                .frame(width: metrics.statusItemWidth, height: 22)

                if let besidePercentage {
                    MenuBarBatteryPercentageText(percentage: besidePercentage)
                        .padding(.trailing, MenuBarBatteryPercentage.trailingPadding)
                }
            }
            }
        }
        .onPreferenceChange(UnfoldedWidthKey.self) { unfoldedWidth = $0 }
        .frame(width: targetWidth, height: 22, alignment: .leading)
        .contentShape(Rectangle())
        .animation(animation, value: targetWidth)
        .onAppear { onWidthChange(targetWidth) }
        .onChange(of: targetWidth) { newValue in onWidthChange(newValue) }
        .onAppear {
            lastAdaptiveSourceBinding.wrappedValue = AdaptiveRingSourceIdentity(state: adaptiveRingMonitor.state)
            adaptiveSourcePresentationsEnabledBinding.wrappedValue = usesAdaptiveRing
            lastLaptopRingModeBinding.wrappedValue = statusStore.laptopRingModeState.mode
            if usesAdaptiveRing {
                beginAdaptiveMonitoring(startFresh: usesLaptopAdaptiveRing)
            }
        }
        .onDisappear {
            adaptiveEntryCenterOverrideBinding.wrappedValue = nil
            adaptiveSessionIsSynchronizedBinding.wrappedValue = false
            adaptiveRingMonitor.release(owner: adaptiveRingOwner)
        }
        .onChange(of: usesAdaptiveRing) { isAdaptive in
            temporaryAdaptiveSourceBinding.wrappedValue = nil
            if isAdaptive {
                adaptiveSourcePresentationsEnabledBinding.wrappedValue = !usesLaptopAdaptiveRing
                beginAdaptiveMonitoring(startFresh: usesLaptopAdaptiveRing)
            } else {
                adaptiveEntryCenterOverrideBinding.wrappedValue = nil
                adaptiveSessionIsSynchronizedBinding.wrappedValue = false
                lastAdaptiveSourceBinding.wrappedValue = nil
                adaptiveSourcePresentationsEnabledBinding.wrappedValue = false
                adaptiveRingMonitor.release(owner: adaptiveRingOwner)
            }
        }
        .onChange(of: statusStore.laptopRingModeState.mode) { newMode in
            let oldMode = lastLaptopRingMode
            lastLaptopRingModeBinding.wrappedValue = newMode
            guard AdaptiveEntryCenterPolicy.shouldRequest(from: oldMode, to: newMode) else {
                if newMode == .battery {
                    adaptiveEntryCenterOverrideBinding.wrappedValue = nil
                    adaptiveSourcePresentationsEnabledBinding.wrappedValue = false
                }
                return
            }
            guard allowsAdaptiveEntryCenterPresentation else {
                adaptiveSourcePresentationsEnabledBinding.wrappedValue = true
                return
            }
            temporaryAdaptiveSourceBinding.wrappedValue = nil
            adaptiveSourcePresentationsEnabledBinding.wrappedValue = false
            adaptiveEntryCenterOverrideBinding.wrappedValue = .adaptiveEntry
            #if DEBUG
            adaptiveQALog("Adaptive-entry sparkles requested once")
            #endif
        }
        .onChange(of: priorityController.presentation) { _ in
            guard adaptiveEntryCenterOverride != nil,
                  !allowsAdaptiveEntryCenterPresentation
            else { return }
            adaptiveEntryCenterOverrideBinding.wrappedValue = nil
            adaptiveSourcePresentationsEnabledBinding.wrappedValue = true
        }
        .onChange(of: adaptiveRingMonitor.state) { newState in
            guard usesAdaptiveRing else { return }
            let oldSource = lastAdaptiveSource ?? AdaptiveRingSourceIdentity(state: newState)
            let newSource = AdaptiveRingSourceIdentity(state: newState)
            lastAdaptiveSourceBinding.wrappedValue = newSource
            var presentationState = adaptiveRingPresentationState
            let transition = presentationState.retarget(to: newState)
            if transition.kind != .none {
                adaptiveRingPresentationStateBinding.wrappedValue = presentationState
                adaptiveRingTransitionBinding.wrappedValue = transition
            }
            guard adaptiveSourcePresentationsEnabled,
                  AdaptiveSourcePresentationPolicy.shouldPresent(
                    from: oldSource,
                    to: newSource,
                    isAdaptiveEntryPresenting: adaptiveEntryCenterOverride != nil,
                    hasHigherPriorityEvent: priorityController.presentation.event != nil
                  )
            else { return }
            temporaryAdaptiveSourceBinding.wrappedValue = newSource
        }
        .task(id: temporaryAdaptiveSource) {
            guard temporaryAdaptiveSource != nil else { return }
            try? await Task.sleep(for: .seconds(AdaptiveSourcePresentationPolicy.duration))
            guard !Task.isCancelled else { return }
            temporaryAdaptiveSourceBinding.wrappedValue = nil
        }
        .task(id: adaptiveEntryCenterOverride) {
            guard adaptiveEntryCenterOverride == .adaptiveEntry else { return }
            try? await Task.sleep(for: .seconds(AdaptiveEntryCenterPolicy.duration))
            guard !Task.isCancelled else { return }
            temporaryAdaptiveSourceBinding.wrappedValue = nil
            adaptiveEntryCenterOverrideBinding.wrappedValue = nil
            adaptiveSourcePresentationsEnabledBinding.wrappedValue = true
            #if DEBUG
            adaptiveQALog("Adaptive-entry sparkles cleared once")
            #endif
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        let network: String
        switch statusStore.status.network.transport {
        case .ethernet:
            network = statusStore.status.network.isConnected ? localized("Ethernet connected") : localized("Ethernet disconnected")
        case .wifi:
            network = statusStore.status.network.isConnected ? localized("Wi-Fi connected") : localized("Wi-Fi disconnected")
        case .other, .none:
            network = statusStore.status.network.isConnected ? localized("Network connected") : localized("Network disconnected")
        }
        let volume: String
        if statusStore.status.audio.volume.isMuted {
            volume = localized("volume muted")
        } else {
            volume = statusStore.status.audio.volume.percentage.map { localized("volume %d percent", $0) } ?? localized("volume unavailable")
        }
        let battery = statusStore.status.battery.percentage.map { localized("battery %d percent", $0) } ?? localized("battery unavailable")
        return localized("%@, %@, %@", network, volume, battery)
    }

    private var metrics: DuoGlyphMetrics {
        let baseMetrics: DuoGlyphMetrics
        #if DEBUG
        baseMetrics = DuoGlyphMetrics(
            overallSize: CGFloat(overallSize),
            ringDiameter: CGFloat(ringDiameter),
            ringLineWidth: CGFloat(ringLineWidth),
            arcGap: arcGap,
            wifiSymbolSize: CGFloat(wifiSymbolSize),
            wifiYOffset: CGFloat(wifiYOffset),
            dotDiameter: CGFloat(dotDiameter),
            dotSpacing: CGFloat(dotSpacing),
            dotYOffset: CGFloat(dotYOffset)
        )
        #else
        baseMetrics = .standard
        #endif
        return baseMetrics.scaled(by: menuBarIconScale).withRingThickness(ringThickness).withCenterScale(centerIconScale)
    }

    private var resolvedRingPresentation: DuoPersistentRingPresentation {
        let mode: DuoPersistentRingMode = usesAdaptiveRing ? .adaptive : .battery
        let adaptiveProgress = usesLaptopAdaptiveRing && !adaptiveSessionIsSynchronized
            ? AdaptiveRingVisualTarget.neutralBaseline
            : adaptiveRingPresentationState.displayedProgress
        return DuoPersistentRingPresentationResolver.resolve(
            mode: mode,
            battery: statusStore.status.battery,
            adaptiveProgress: adaptiveProgress,
            batteryColorCodingEnabled: batteryColorCoding,
            batteryLevelColorsEnabled: batteryRingColorMode.levelColorsEnabled
        )
    }

    private var adaptiveRingAnimation: Animation? {
        guard usesAdaptiveRing else { return nil }
        let duration = adaptiveRingTransition.effectiveDuration(
            animationsEnabled: animationsEnabled,
            reduceMotion: reduceMotion
        )
        return duration > 0
            ? .timingCurve(0.4, 0, 0.2, 1, duration: duration)
            : nil
    }

    private var adaptiveRingColor: Color? {
        guard usesAdaptiveRing else { return nil }
        guard !usesLaptopAdaptiveRing || adaptiveSessionIsSynchronized else { return nil }
        return AdaptiveRingColorResolver.resolve(
            state: adaptiveRingMonitor.state,
            decision: adaptiveRingMonitor.performanceDecision,
            colorCodingEnabled: adaptiveRingColorCoding
        ).color
    }

    private var performanceCenterState: DuoCenterState? {
        guard usesAdaptiveRing else { return nil }
        guard !usesLaptopAdaptiveRing || adaptiveSessionIsSynchronized else { return nil }
        guard priorityController.presentation.event == nil else { return nil }
        switch temporaryAdaptiveSource {
        case .brightness: return .adaptiveBrightness
        case .cpu: return .performanceCPU
        case .memory: return .performanceMemory
        case .thermal: return .performanceThermal
        case .neutral, nil: return nil
        }
    }

    private var centerStateOverride: DuoCenterState? {
        guard allowsAdaptiveEntryCenterPresentation else { return nil }
        return adaptiveEntryCenterOverride ?? performanceCenterState
    }

    private var allowsAdaptiveEntryCenterPresentation: Bool {
        AdaptiveEntryCenterPolicy.allows(over: priorityController.presentation.event)
    }

    private var usesAdaptiveRing: Bool {
        #if DEBUG
        if simulateDesktopMac { return true }
        #endif
        return statusStore.usesReleasedAdaptiveRing
    }

    private var usesLaptopAdaptiveRing: Bool {
        #if DEBUG
        guard !simulateDesktopMac else { return false }
        #endif
        return statusStore.usesLaptopAdaptiveRing
    }

    private func beginAdaptiveMonitoring(startFresh: Bool) {
        if startFresh {
            adaptiveRingMonitor.resetForNewMonitoringSession()
        }
        adaptiveRingMonitor.acquire(owner: adaptiveRingOwner)
        var presentationState = adaptiveRingPresentationState
        presentationState.synchronize(to: adaptiveRingMonitor.state)
        $adaptiveRingPresentationState.wrappedValue = presentationState
        $adaptiveSessionIsSynchronized.wrappedValue = true
        $adaptiveRingTransition.wrappedValue = .none
        $lastAdaptiveSource.wrappedValue = AdaptiveRingSourceIdentity(state: adaptiveRingMonitor.state)
    }

    #if DEBUG
    private func adaptiveQALog(_ message: String) {
        NSLog("%@", "[DuoBar Adaptive QA] \(message)")
    }
    #endif
}

private struct UnfoldedWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
