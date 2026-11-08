import AppKit
import CoreGraphics
import Foundation

@MainActor
final class AdaptiveRingMonitor: ObservableObject {
    static let shared = AdaptiveRingMonitor()

    @Published private(set) var performanceSnapshot: PerformanceSnapshot?
    @Published private(set) var performanceDecision: PerformanceDecision = .idle
    @Published private(set) var brightnessSnapshot: DisplayBrightnessSnapshot?
    @Published private(set) var state: AdaptiveRingState = .neutral

    private let performanceSampler: PerformanceTelemetrySampler
    private let brightnessReader: any DisplayBrightnessReading
    private var performanceEngine: PerformanceDecisionEngine
    private let coordinator: AdaptiveRingCoordinator
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var displayCallbackRegistered = false
    private var owners: Set<UUID> = []

    #if DEBUG
    private var debugSyntheticInput: AdaptiveRingSyntheticInput?
    private var debugSequenceStep: AdaptiveRingSyntheticSequenceStep?
    @Published private(set) var debugTestSource: AdaptiveRingTestSource = .live
    @Published private(set) var debugScenarioLabel: String?
    @Published private(set) var debugCandidates: [PerformanceCandidate] = []
    @Published private(set) var debugCandidateDurations: [PerformanceMetric: TimeInterval] = [:]
    @Published private(set) var debugEngineMode: DebugAdaptiveEngineMode = .live
    @Published private(set) var debugEngineGeneration = 0
    #endif

    var monitoringOwnerCount: Int { owners.count }
    var isMonitoring: Bool { timer != nil }

    init(
        performanceSampler: PerformanceTelemetrySampler = PerformanceTelemetrySampler(),
        performanceEngine: PerformanceDecisionEngine = PerformanceDecisionEngine(),
        brightnessReader: any DisplayBrightnessReading = DisplayBrightnessService(),
        coordinator: AdaptiveRingCoordinator = AdaptiveRingCoordinator()
    ) {
        self.performanceSampler = performanceSampler
        self.performanceEngine = performanceEngine
        self.brightnessReader = brightnessReader
        self.coordinator = coordinator
    }

    func acquire(owner: UUID, interval: TimeInterval = 1.5) {
        owners.insert(owner)
        guard timer == nil else { return }
        start(interval: interval)
    }

    func release(owner: UUID) {
        owners.remove(owner)
        guard owners.isEmpty else { return }
        stop()
    }

    /// Starts a new top-level Adaptive Ring session without carrying a prior
    /// laptop session's sampled metric or decision into the next one.
    /// Desktop ownership never needs this reset because its monitor remains active.
    func resetForNewMonitoringSession() {
        guard !isMonitoring else { return }
        #if DEBUG
        guard debugTestSource == .live else { return }
        #endif
        let preference = performanceEngine.preference
        performanceEngine = PerformanceDecisionEngine(
            thresholds: performanceEngine.thresholds,
            preference: preference
        )
        performanceSnapshot = nil
        performanceDecision = .idle
        brightnessSnapshot = nil
        state = .neutral
        #if DEBUG
        debugCandidates = []
        debugCandidateDurations = [:]
        #endif
    }

    func setPreference(_ preference: PerformancePreference) {
        guard performanceEngine.preference != preference else { return }
        performanceEngine.preference = preference
        refresh()
    }

    func refresh(at injectedTimestamp: TimeInterval? = nil) {
        let timestamp = injectedTimestamp ?? ProcessInfo.processInfo.systemUptime
        let actualBrightness = brightnessReader.readMainDisplay(at: timestamp)
        #if DEBUG
        let nextPerformance: PerformanceSnapshot
        let nextDecision: PerformanceDecision
        let nextBrightness: DisplayBrightnessSnapshot
        if let step = debugSequenceStep {
            nextPerformance = AdaptiveRingSyntheticInput.idle.snapshot(at: timestamp)
            nextDecision = step.decision
            nextBrightness = DisplayBrightnessSnapshot(
                mainDisplay: actualBrightness.mainDisplay,
                availability: step.brightness,
                sampledAt: timestamp,
                diagnostic: actualBrightness.diagnostic
            )
        } else if let input = debugSyntheticInput {
            nextPerformance = input.snapshot(at: timestamp)
            nextDecision = performanceEngine.update(with: nextPerformance)
            nextBrightness = DisplayBrightnessSnapshot(
                mainDisplay: actualBrightness.mainDisplay,
                availability: input.brightness,
                sampledAt: timestamp,
                diagnostic: actualBrightness.diagnostic
            )
        } else {
            nextPerformance = performanceSampler.sample(at: timestamp)
            nextDecision = performanceEngine.update(with: nextPerformance)
            nextBrightness = actualBrightness
        }
        #else
        let nextPerformance = performanceSampler.sample(at: timestamp)
        let nextDecision = performanceEngine.update(with: nextPerformance)
        let nextBrightness = actualBrightness
        #endif

        performanceSnapshot = nextPerformance
        performanceDecision = nextDecision
        #if DEBUG
        debugCandidates = performanceEngine.candidates(for: nextPerformance)
        debugCandidateDurations = Dictionary(uniqueKeysWithValues: debugCandidates.map { ($0.metric, performanceEngine.candidateDuration(for: $0.metric, at: timestamp)) })
        #endif
        publishBrightnessIfMeaningfullyChanged(nextBrightness)

        let nextState = coordinator.resolve(
            brightness: nextBrightness,
            performance: nextDecision,
            at: timestamp
        )
        if state != nextState { state = nextState }
    }

    #if DEBUG
    func useDebugSyntheticScenario(_ scenario: AdaptiveRingSyntheticScenario) {
        useDebugSyntheticInput(scenario.input, label: scenario.rawValue, preference: .automatic)
    }

    func useDebugSyntheticInput(
        _ input: AdaptiveRingSyntheticInput,
        label: String,
        preference: PerformancePreference,
        at timestamp: TimeInterval? = nil
    ) {
        if debugEngineMode != .syntheticFullPipeline {
            resetDebugEngine(preference: preference, mode: .syntheticFullPipeline)
        } else {
            performanceEngine.preference = preference
        }
        debugSyntheticInput = input
        debugSequenceStep = nil
        debugTestSource = .synthetic
        debugScenarioLabel = label
        refresh(at: timestamp)
    }

    func useDebugSequenceStep(_ step: AdaptiveRingSyntheticSequenceStep, label: String) {
        if debugEngineMode != .presentationOnlySequence {
            resetDebugEngine(preference: .automatic, mode: .presentationOnlySequence)
        }
        debugSyntheticInput = nil
        debugSequenceStep = step
        debugTestSource = .synthetic
        debugScenarioLabel = label
        refresh()
    }

    func clearDebugSyntheticInput() {
        resetDebugEngine(mode: .live)
        debugSyntheticInput = nil
        debugSequenceStep = nil
        debugTestSource = .live
        debugScenarioLabel = nil
        refresh()
    }

    func resetDebugSimulation(
        input: AdaptiveRingSyntheticInput,
        label: String,
        preference: PerformancePreference,
        at timestamp: TimeInterval? = nil
    ) {
        resetDebugEngine(preference: preference, mode: .syntheticFullPipeline)
        debugSyntheticInput = input
        debugSequenceStep = nil
        debugTestSource = .synthetic
        debugScenarioLabel = label
        refresh(at: timestamp)
    }

    private func resetDebugEngine(
        preference: PerformancePreference = .automatic,
        mode: DebugAdaptiveEngineMode
    ) {
        performanceEngine = PerformanceDecisionEngine(thresholds: performanceEngine.thresholds, preference: preference)
        debugEngineMode = mode
        debugEngineGeneration &+= 1
        debugCandidates = []
        debugCandidateDurations = [:]
    }
    #endif

    private func start(interval: TimeInterval) {
        refresh()
        registerForDisplayChanges()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(interval * 0.2, 0.4)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                adaptiveRingDisplayConfigurationChanged,
                Unmanaged.passUnretained(self).toOpaque()
            )
            displayCallbackRegistered = false
        }
    }

    private func registerForDisplayChanges() {
        guard !displayCallbackRegistered else { return }
        let result = CGDisplayRegisterReconfigurationCallback(
            adaptiveRingDisplayConfigurationChanged,
            Unmanaged.passUnretained(self).toOpaque()
        )
        displayCallbackRegistered = result == .success
    }

    fileprivate func displayConfigurationDidChange() {
        refresh()
    }

    private func publishBrightnessIfMeaningfullyChanged(_ next: DisplayBrightnessSnapshot) {
        guard let current = brightnessSnapshot else {
            brightnessSnapshot = next
            return
        }
        guard current.mainDisplay == next.mainDisplay else {
            brightnessSnapshot = next
            return
        }

        switch (current.availability, next.availability) {
        case (.unavailable, .unavailable):
            break
        case (.available(let old), .available(let new)) where abs(old - new) < 0.01:
            break
        default:
            brightnessSnapshot = next
        }
    }

    deinit {
        timer?.invalidate()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        if displayCallbackRegistered {
            CGDisplayRemoveReconfigurationCallback(
                adaptiveRingDisplayConfigurationChanged,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }
    }
}

private func adaptiveRingDisplayConfigurationChanged(
    _: CGDirectDisplayID,
    _: CGDisplayChangeSummaryFlags,
    userInfo: UnsafeMutableRawPointer?
) {
    guard let userInfo else { return }
    let monitor = Unmanaged<AdaptiveRingMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    Task { @MainActor [weak monitor] in
        monitor?.displayConfigurationDidChange()
    }
}
