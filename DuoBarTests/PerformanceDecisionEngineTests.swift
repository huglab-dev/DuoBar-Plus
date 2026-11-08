import XCTest
@testable import DuoBar

final class PerformanceDecisionEngineTests: XCTestCase {
    private let thresholds = PerformanceDecisionThresholds(
        cpuActivation: 0.55,
        cpuSerious: 0.82,
        activationDuration: 4,
        switchDuration: 5,
        minimumHoldDuration: 8,
        releaseDelay: 6,
        switchSeverityMargin: 1
    )

    func testIdleToSustainedCPUToSustainedIdle() {
        var engine = PerformanceDecisionEngine(thresholds: thresholds)
        XCTAssertEqual(engine.update(with: snapshot(0, cpu: 0.1)).activeMetric, .idle)
        XCTAssertEqual(engine.update(with: snapshot(1, cpu: 0.7)).activeMetric, .idle)
        XCTAssertEqual(engine.update(with: snapshot(5, cpu: 0.72)).activeMetric, .cpu)
        XCTAssertEqual(engine.update(with: snapshot(12, cpu: 0.1)).activeMetric, .cpu)
        XCTAssertEqual(engine.update(with: snapshot(18, cpu: 0.1)).activeMetric, .idle)
    }

    func testShortCPUSpikeRemainsIdle() {
        var engine = PerformanceDecisionEngine(thresholds: thresholds)
        XCTAssertEqual(engine.update(with: snapshot(0, cpu: 0.72)).activeMetric, .idle)
        XCTAssertEqual(engine.update(with: snapshot(2, cpu: 0.1)).activeMetric, .idle)
    }

    func testShortMaximumCPUSpikeStillRequiresPersistence() {
        var engine = PerformanceDecisionEngine(thresholds: thresholds)
        XCTAssertEqual(engine.update(with: snapshot(0, cpu: 1)).activeMetric, .idle)
        XCTAssertEqual(engine.update(with: snapshot(1, cpu: 0.1)).activeMetric, .idle)
    }

    func testSustainedCPUBecomesActive() {
        var engine = PerformanceDecisionEngine(thresholds: thresholds)
        _ = engine.update(with: snapshot(0, cpu: 0.7))
        XCTAssertEqual(engine.update(with: snapshot(4, cpu: 0.7)).activeMetric, .cpu)
    }

    func testSlightlyCompetingMetricDoesNotReplaceCPU() {
        var engine = activeCPUEngine()
        let decision = engine.update(with: snapshot(13, cpu: 0.62, memory: .elevated))
        XCTAssertEqual(decision.candidate.metric, .memory)
        XCTAssertEqual(decision.activeMetric, .cpu)
        XCTAssertEqual(decision.reason, .hysteresis)
    }

    func testMeaningfulCompetingMetricMustPersistBeforeSwitch() {
        var engine = activeCPUEngine()
        XCTAssertEqual(engine.update(with: snapshot(13, cpu: 0.62, memory: .serious)).activeMetric, .cpu)
        XCTAssertEqual(engine.update(with: snapshot(17, cpu: 0.62, memory: .serious)).activeMetric, .cpu)
        XCTAssertEqual(engine.update(with: snapshot(18, cpu: 0.62, memory: .serious)).activeMetric, .memory)
    }

    func testMemoryCriticalOverridesCPUImmediately() {
        var engine = activeCPUEngine()
        let decision = engine.update(with: snapshot(6, cpu: 0.7, memory: .critical))
        XCTAssertEqual(decision.activeMetric, .memory)
        XCTAssertEqual(decision.severity, .critical)
    }

    func testThermalSeriousAndCriticalOverride() {
        var seriousEngine = activeCPUEngine()
        XCTAssertEqual(
            seriousEngine.update(with: snapshot(6, cpu: 0.7, thermal: .serious)).activeMetric,
            .thermal
        )

        var criticalEngine = activeCPUEngine()
        let critical = criticalEngine.update(with: snapshot(6, cpu: 0.7, thermal: .critical))
        XCTAssertEqual(critical.activeMetric, .thermal)
        XCTAssertEqual(critical.severity, .critical)
    }

    func testConditionClearingBrieflyDoesNotRelease() {
        var engine = activeCPUEngine()
        XCTAssertEqual(engine.update(with: snapshot(12, cpu: 0.1)).activeMetric, .cpu)
        XCTAssertEqual(engine.update(with: snapshot(14, cpu: 0.7)).activeMetric, .cpu)
        XCTAssertEqual(engine.update(with: snapshot(16, cpu: 0.1)).activeMetric, .cpu)
    }

    func testConditionClearingSustainablyReleases() {
        var engine = activeCPUEngine()
        XCTAssertEqual(engine.update(with: snapshot(12, cpu: 0.1)).activeMetric, .cpu)
        XCTAssertEqual(engine.update(with: snapshot(18, cpu: 0.1)).activeMetric, .idle)
    }

    func testRapidAlternatingCandidatesDoNotFlap() {
        var engine = activeCPUEngine()
        let sequence: [(TimeInterval, Double, MemoryStressEstimate)] = [
            (13, 0.71, .normal),
            (14, 0.50, .elevated),
            (15, 0.75, .normal),
            (16, 0.50, .elevated),
            (17, 0.74, .normal),
            (18, 0.50, .elevated)
        ]
        let activeMetrics = sequence.map { time, cpu, memory in
            engine.update(with: snapshot(time, cpu: cpu, memory: memory)).activeMetric
        }
        XCTAssertEqual(Set(activeMetrics), [.cpu])
    }

    func testUnknownCPUAndMemoryRemainIdle() {
        var engine = PerformanceDecisionEngine(thresholds: thresholds)
        let decision = engine.update(with: PerformanceSnapshot(
            timestamp: 0,
            cpuLoad: nil,
            memory: nil,
            thermalState: .nominal
        ))
        XCTAssertEqual(decision.activeMetric, .idle)
    }

    func testVeryHighCPUIsHighUtilizationNotSystemCritical() {
        let candidate = PerformanceDecisionEngine(thresholds: thresholds).candidate(for: snapshot(0, cpu: 0.97))
        XCTAssertEqual(candidate.metric, .cpu)
        XCTAssertEqual(candidate.severity, .serious)
        XCTAssertEqual(candidate.severity.semanticLabel, "High")
    }

    func testMemoryCriticalBeatsHighCPURegardlessOfPreference() {
        var engine = PerformanceDecisionEngine(thresholds: thresholds, preference: .cpu)
        let decision = engine.update(with: snapshot(0, cpu: 0.86, memory: .critical))
        XCTAssertEqual(decision.activeMetric, .memory)
        XCTAssertTrue(decision.isCriticalOverride)
        XCTAssertFalse(decision.preferenceAffectedSelection)
    }

    func testThermalCriticalBeatsHighCPURegardlessOfPreference() {
        var engine = PerformanceDecisionEngine(thresholds: thresholds, preference: .cpu)
        let decision = engine.update(with: snapshot(0, cpu: 0.86, thermal: .critical))
        XCTAssertEqual(decision.activeMetric, .thermal)
        XCTAssertTrue(decision.isCriticalOverride)
    }

    func testPreferenceBreaksOnlyCloseCPUAndMemoryTie() {
        var cpuEngine = PerformanceDecisionEngine(thresholds: thresholds, preference: .cpu)
        _ = cpuEngine.update(with: snapshot(0, cpu: 0.86, memory: .serious))
        let cpu = cpuEngine.update(with: snapshot(4, cpu: 0.86, memory: .serious))
        XCTAssertEqual(cpu.activeMetric, .cpu)
        XCTAssertTrue(cpu.preferenceAffectedSelection)

        var memoryEngine = PerformanceDecisionEngine(thresholds: thresholds, preference: .memory)
        _ = memoryEngine.update(with: snapshot(0, cpu: 0.86, memory: .serious))
        let memory = memoryEngine.update(with: snapshot(4, cpu: 0.86, memory: .serious))
        XCTAssertEqual(memory.activeMetric, .memory)
        XCTAssertTrue(memory.preferenceAffectedSelection)
    }

    func testCloseCompetitionRetainsCurrentMetricWithoutPreference() {
        var engine = PerformanceDecisionEngine(thresholds: thresholds)
        _ = engine.update(with: snapshot(0, cpu: 0.86))
        _ = engine.update(with: snapshot(4, cpu: 0.86))
        let decision = engine.update(with: snapshot(13, cpu: 0.86, memory: .serious))
        XCTAssertEqual(decision.activeMetric, .cpu)
        XCTAssertEqual(decision.reason, .hysteresis)
    }

    private func activeCPUEngine() -> PerformanceDecisionEngine {
        var engine = PerformanceDecisionEngine(thresholds: thresholds)
        _ = engine.update(with: snapshot(0, cpu: 0.7))
        _ = engine.update(with: snapshot(4, cpu: 0.7))
        return engine
    }

    private func snapshot(
        _ timestamp: TimeInterval,
        cpu: Double?,
        memory: MemoryStressEstimate = .normal,
        thermal: PerformanceThermalState = .nominal
    ) -> PerformanceSnapshot {
        PerformanceSnapshot(
            timestamp: timestamp,
            cpuLoad: cpu,
            memory: MemorySnapshot(
                totalBytes: 100,
                availableBytes: memory == .normal ? 40 : 5,
                compressedBytes: 10,
                pageOutsPerSecond: 0,
                stress: memory
            ),
            thermalState: thermal
        )
    }
}
