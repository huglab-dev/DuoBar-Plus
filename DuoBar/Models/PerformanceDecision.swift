import Foundation

enum PerformanceMetric: String, CaseIterable, Sendable {
    case idle
    case cpu
    case memory
    case thermal
}

enum PerformanceSeverity: Int, Comparable, Sendable {
    case idle
    case normal
    case elevated
    case serious
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var normalizedValue: Double {
        switch self { case .idle: 0; case .normal: 0.25; case .elevated: 0.55; case .serious: 0.80; case .critical: 1 }
    }

    /// `.elevated` is product-facing “moderate”; `.serious` is “high”.
    var semanticLabel: String {
        switch self { case .idle, .normal: "Normal"; case .elevated: "Moderate"; case .serious: "High"; case .critical: "Critical" }
    }
}

enum PerformancePreference: String, CaseIterable, Sendable {
    case automatic = "Automatic"
    case cpu = "Prefer CPU"
    case memory = "Prefer Memory"
    case thermal = "Prefer Thermal"

    var preferredMetric: PerformanceMetric? {
        switch self { case .automatic: nil; case .cpu: .cpu; case .memory: .memory; case .thermal: .thermal }
    }

    var localizedDisplayName: String {
        switch self {
        case .automatic: localized("Automatic")
        case .cpu: localized("Prefer CPU")
        case .memory: localized("Prefer Memory")
        case .thermal: localized("Prefer Thermal")
        }
    }
}

enum PerformanceDecisionReason: String, Sendable {
    case baseline = "No sustained performance condition"
    case cpuSustained = "Sustained CPU workload"
    case memoryHeadroom = "Sustained memory pressure estimate"
    case memoryCritical = "Critical memory pressure estimate"
    case thermalFair = "Elevated thermal state"
    case thermalSerious = "Serious thermal state"
    case thermalCritical = "Critical thermal state"
    case candidatePending = "Candidate awaiting persistence threshold"
    case challengerPending = "Challenger awaiting persistence threshold"
    case minimumHold = "Current metric retained for minimum hold time"
    case hysteresis = "Current metric retained by hysteresis"
    case releasePending = "Condition cleared; release delay active"
    case preferenceCPU = "Preference tie-break: CPU"
    case preferenceMemory = "Preference tie-break: Memory"
    case preferenceThermal = "Preference tie-break: Thermal"
}

struct PerformanceCandidate: Equatable, Sendable {
    var metric: PerformanceMetric
    var severity: PerformanceSeverity
    var normalizedValue: Double
    var reason: PerformanceDecisionReason

    static let idle = PerformanceCandidate(
        metric: .idle,
        severity: .idle,
        normalizedValue: 0,
        reason: .baseline
    )
}

struct PerformanceDecision: Equatable, Sendable {
    var activeMetric: PerformanceMetric
    var severity: PerformanceSeverity
    var normalizedRingValue: Double
    var reason: PerformanceDecisionReason
    var candidate: PerformanceCandidate
    var candidateDuration: TimeInterval
    var activeDuration: TimeInterval
    var challenger: PerformanceCandidate?
    var challengerDuration: TimeInterval
    var attentionScore: Double
    var preference: PerformancePreference
    var preferenceAffectedSelection: Bool
    var isCriticalOverride: Bool
    var isReleasePending: Bool

    init(activeMetric: PerformanceMetric, severity: PerformanceSeverity, normalizedRingValue: Double, reason: PerformanceDecisionReason, candidate: PerformanceCandidate, candidateDuration: TimeInterval = 0, activeDuration: TimeInterval = 0, challenger: PerformanceCandidate? = nil, challengerDuration: TimeInterval = 0, attentionScore: Double = 0, preference: PerformancePreference = .automatic, preferenceAffectedSelection: Bool = false, isCriticalOverride: Bool = false, isReleasePending: Bool = false) {
        self.activeMetric = activeMetric
        self.severity = severity
        self.normalizedRingValue = normalizedRingValue
        self.reason = reason
        self.candidate = candidate
        self.candidateDuration = candidateDuration
        self.activeDuration = activeDuration
        self.challenger = challenger
        self.challengerDuration = challengerDuration
        self.attentionScore = attentionScore
        self.preference = preference
        self.preferenceAffectedSelection = preferenceAffectedSelection
        self.isCriticalOverride = isCriticalOverride
        self.isReleasePending = isReleasePending
    }

    static let idle = PerformanceDecision(
        activeMetric: .idle,
        severity: .idle,
        normalizedRingValue: 0,
        reason: .baseline,
        candidate: .idle
    )
}
