#if DEBUG
import Foundation

enum AdaptiveRingTestSource: String, CaseIterable, Identifiable {
    case live = "Live"
    case synthetic = "Synthetic"

    var id: String { rawValue }
}

enum AdaptiveRingSyntheticScenario: String, CaseIterable, Identifiable {
    case neutral = "Neutral"
    case brightness25 = "Brightness 25%"
    case brightness50 = "Brightness 50%"
    case brightness75 = "Brightness 75%"
    case brightness100 = "Brightness 100%"
    case cpuModerate = "CPU Moderate"
    case cpuHigh = "CPU High"
    case cpuVeryHigh = "CPU Very High"
    case memoryPressure = "Memory Pressure"
    case memoryCritical = "Memory Critical"
    case thermalSerious = "Thermal Serious"
    case thermalCritical = "Thermal Critical"

    var id: String { rawValue }

    var input: AdaptiveRingSyntheticInput {
        let idle = AdaptiveRingSyntheticInput.idle
        switch self {
        case .neutral: return idle
        case .brightness25: return idle.with(brightness: .available(0.25))
        case .brightness50: return idle.with(brightness: .available(0.50))
        case .brightness75: return idle.with(brightness: .available(0.75))
        case .brightness100: return idle.with(brightness: .available(1.00))
        case .cpuModerate: return idle.with(cpuLoad: 0.65)
        case .cpuHigh: return idle.with(cpuLoad: 0.86)
        case .cpuVeryHigh: return idle.with(cpuLoad: 0.97)
        case .memoryPressure: return idle.with(memoryStress: .serious)
        case .memoryCritical: return idle.with(memoryStress: .critical)
        case .thermalSerious: return idle.with(thermal: .serious)
        case .thermalCritical: return idle.with(thermal: .critical)
        }
    }
}

struct AdaptiveRingSyntheticInput: Equatable {
    var brightness: DisplayBrightnessAvailability
    var cpuLoad: Double?
    var memoryStress: MemoryStressEstimate
    var thermalState: PerformanceThermalState

    static let idle = AdaptiveRingSyntheticInput(
        brightness: .unavailable,
        cpuLoad: 0.10,
        memoryStress: .normal,
        thermalState: .nominal
    )

    func snapshot(at timestamp: TimeInterval) -> PerformanceSnapshot {
        let total: UInt64 = 16 * 1_024 * 1_024 * 1_024
        let headroom: UInt64
        let compressed: UInt64
        let pageOuts: Double
        switch memoryStress {
        case .normal: headroom = total / 2; compressed = 0; pageOuts = 0
        case .elevated: headroom = total / 12; compressed = total / 3; pageOuts = 1
        case .serious: headroom = total / 20; compressed = total / 2; pageOuts = 12
        case .critical: headroom = total / 40; compressed = total / 2; pageOuts = 80
        }
        return PerformanceSnapshot(
            timestamp: timestamp,
            cpuLoad: cpuLoad,
            memory: MemorySnapshot(totalBytes: total, availableBytes: headroom, compressedBytes: compressed, pageOutsPerSecond: pageOuts, stress: memoryStress),
            thermalState: thermalState
        )
    }

    func with(
        brightness: DisplayBrightnessAvailability? = nil,
        cpuLoad: Double? = nil,
        memoryStress: MemoryStressEstimate? = nil,
        thermal: PerformanceThermalState? = nil
    ) -> Self {
        Self(
            brightness: brightness ?? self.brightness,
            cpuLoad: cpuLoad ?? self.cpuLoad,
            memoryStress: memoryStress ?? self.memoryStress,
            thermalState: thermal ?? thermalState
        )
    }
}

enum AdaptiveRingSyntheticSequence: String, CaseIterable, Identifiable {
    case brightnessCPU = "Brightness 50% → CPU High → Brightness 50%"
    case neutralCPU = "Neutral → CPU High → Neutral"
    case escalation = "Brightness 65% → CPU → Memory → Thermal → Brightness"
    case cpuRamp = "Neutral → CPU Moderate → High → Moderate → Neutral"

    var id: String { rawValue }

    var steps: [AdaptiveRingSyntheticSequenceStep] {
        switch self {
        case .brightnessCPU:
            [.brightness(0.50), .performance(.cpu, 0.86, .serious, .cpuSustained), .brightness(0.50)]
        case .neutralCPU:
            [.neutral, .performance(.cpu, 0.86, .serious, .cpuSustained), .neutral]
        case .escalation:
            [.brightness(0.65), .performance(.cpu, 0.86, .serious, .cpuSustained), .performance(.memory, 1, .critical, .memoryCritical), .performance(.thermal, 1, .critical, .thermalCritical), .brightness(0.65)]
        case .cpuRamp:
            [.neutral, .performance(.cpu, 0.65, .elevated, .cpuSustained), .performance(.cpu, 0.86, .serious, .cpuSustained), .performance(.cpu, 0.65, .elevated, .cpuSustained), .neutral]
        }
    }
}

enum AdaptiveRingIntelligenceScenario: String, CaseIterable, Identifiable {
    case cpuHigh = "CPU High · Memory Normal · Thermal Nominal"
    case cpuHighMemorySerious = "CPU High · Memory Serious · Thermal Nominal"
    case cpuHighMemoryCritical = "CPU High · Memory Critical · Thermal Nominal"
    case cpuHighMemorySeriousThermalSerious = "CPU High · Memory Serious · Thermal Serious"
    case allCritical = "CPU High · Memory Critical · Thermal Critical"
    case cpuModerateMemorySerious = "CPU Moderate · Memory Serious · Thermal Nominal"
    case cpuHighThermalCritical = "CPU High · Memory Normal · Thermal Critical"

    var id: String { rawValue }

    var input: AdaptiveRingSyntheticInput {
        let idle = AdaptiveRingSyntheticInput.idle
        switch self {
        case .cpuHigh: return idle.with(cpuLoad: 0.86)
        case .cpuHighMemorySerious: return idle.with(cpuLoad: 0.86, memoryStress: .serious)
        case .cpuHighMemoryCritical: return idle.with(cpuLoad: 0.86, memoryStress: .critical)
        case .cpuHighMemorySeriousThermalSerious: return idle.with(cpuLoad: 0.86, memoryStress: .serious, thermal: .serious)
        case .allCritical: return idle.with(cpuLoad: 0.86, memoryStress: .critical, thermal: .critical)
        case .cpuModerateMemorySerious: return idle.with(cpuLoad: 0.65, memoryStress: .serious)
        case .cpuHighThermalCritical: return idle.with(cpuLoad: 0.86, thermal: .critical)
        }
    }
}

struct AdaptiveRingSyntheticSequenceStep: Equatable {
    let brightness: DisplayBrightnessAvailability
    let decision: PerformanceDecision

    static let neutral = Self(brightness: .unavailable, decision: .idle)

    static func brightness(_ value: Double) -> Self {
        Self(brightness: .available(value), decision: .idle)
    }

    static func performance(_ metric: PerformanceMetric, _ value: Double, _ severity: PerformanceSeverity, _ reason: PerformanceDecisionReason) -> Self {
        let candidate = PerformanceCandidate(metric: metric, severity: severity, normalizedValue: value, reason: reason)
        return Self(brightness: .unavailable, decision: PerformanceDecision(activeMetric: metric, severity: severity, normalizedRingValue: value, reason: reason, candidate: candidate))
    }
}
#endif
