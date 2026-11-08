#if DEBUG
import Foundation

@MainActor
final class AdaptiveRingVisualLabController: ObservableObject {
    @Published var source: AdaptiveRingTestSource = .live
    @Published var scenario: AdaptiveRingSyntheticScenario = .neutral
    @Published var sequence: AdaptiveRingSyntheticSequence = .brightnessCPU
    @Published var intelligenceScenario: AdaptiveRingIntelligenceScenario = .cpuHigh
    @Published var preference: PerformancePreference = .automatic
    @Published private(set) var isPlayingSequence = false

    private let monitor: AdaptiveRingMonitor
    private var sequenceTask: Task<Void, Never>?

    init() { monitor = .shared }

    init(monitor: AdaptiveRingMonitor) { self.monitor = monitor }

    func apply(isDesktopSimulationEnabled: Bool) {
        sequenceTask?.cancel()
        isPlayingSequence = false
        guard source == .synthetic, isDesktopSimulationEnabled else {
            monitor.clearDebugSyntheticInput()
            return
        }
        monitor.useDebugSyntheticInput(scenario.input, label: scenario.rawValue, preference: preference)
    }

    func applyIntelligenceScenario(isDesktopSimulationEnabled: Bool) {
        guard source == .synthetic, isDesktopSimulationEnabled else { return }
        monitor.useDebugSyntheticInput(intelligenceScenario.input, label: intelligenceScenario.rawValue, preference: preference)
    }

    func resetSimulation(isDesktopSimulationEnabled: Bool) {
        guard source == .synthetic, isDesktopSimulationEnabled else { return }
        stopSequence()
        let input = labUsesIntelligence ? intelligenceScenario.input : scenario.input
        let label = labUsesIntelligence ? intelligenceScenario.rawValue : scenario.rawValue
        monitor.resetDebugSimulation(input: input, label: label, preference: preference)
    }

    var labUsesIntelligence = false

    func playSequence(isDesktopSimulationEnabled: Bool) {
        guard isDesktopSimulationEnabled else { return }
        source = .synthetic
        sequenceTask?.cancel()
        isPlayingSequence = true
        let sequence = sequence
        sequenceTask = Task { [weak self] in
            for (index, step) in sequence.steps.enumerated() {
                guard !Task.isCancelled else { return }
                self?.monitor.useDebugSequenceStep(step, label: "\(sequence.rawValue) · \(index + 1)/\(sequence.steps.count)")
                try? await Task.sleep(for: .seconds(2.2))
            }
            guard !Task.isCancelled else { return }
            self?.isPlayingSequence = false
        }
    }

    func stopSequence() {
        sequenceTask?.cancel()
        sequenceTask = nil
        isPlayingSequence = false
    }

    func reset() {
        stopSequence()
        source = .live
        monitor.clearDebugSyntheticInput()
    }

    deinit { sequenceTask?.cancel() }
}
#endif
