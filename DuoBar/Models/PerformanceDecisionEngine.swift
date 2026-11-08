import Foundation

struct PerformanceDecisionThresholds: Equatable, Sendable {
    var cpuActivation: Double = 0.55
    var cpuSerious: Double = 0.82
    var activationDuration: TimeInterval = 4
    var switchDuration: TimeInterval = 5
    var minimumHoldDuration: TimeInterval = 8
    var releaseDelay: TimeInterval = 6
    var switchSeverityMargin: Int = 1
    var preferenceBias: Double = 1
}

struct PerformanceDecisionEngine: Sendable {
    private(set) var decision: PerformanceDecision = .idle
    let thresholds: PerformanceDecisionThresholds
    var preference: PerformancePreference

    private var activeSince: TimeInterval?
    private var pendingCandidate: PerformanceCandidate?
    private var pendingSince: TimeInterval?
    private var releaseSince: TimeInterval?
    private var metricCandidateSince: [PerformanceMetric: TimeInterval] = [:]

    init(thresholds: PerformanceDecisionThresholds = .init(), preference: PerformancePreference = .automatic) {
        self.thresholds = thresholds
        self.preference = preference
    }

    mutating func update(with snapshot: PerformanceSnapshot) -> PerformanceDecision {
        updateMetricCandidateDurations(candidates(for: snapshot), at: snapshot.timestamp)
        let candidate = candidate(for: snapshot)
        let preferenceAffected = preferenceAffectedSelection(candidate, candidates: candidates(for: snapshot))
        let now = snapshot.timestamp

        if candidate.metric == decision.activeMetric, candidate.metric != .idle {
            clearPending()
            releaseSince = nil
            decision = PerformanceDecision(
                activeMetric: candidate.metric,
                severity: candidate.severity,
                normalizedRingValue: candidate.normalizedValue,
                reason: candidate.reason,
                candidate: candidate,
                activeDuration: now - (activeSince ?? now),
                attentionScore: attentionScore(candidate),
                preference: preference
            )
            return decision
        }

        if isCriticalOverride(candidate) {
            activate(candidate, at: now, preferenceAffected: false)
            return decision
        }

        if decision.activeMetric == .idle {
            guard candidate.metric != .idle else {
                clearPending()
                decision = .idle
                return decision
            }

            track(candidate, at: now)
            if pendingDuration(at: now) >= thresholds.activationDuration {
                activate(candidate, at: now, preferenceAffected: preferenceAffected)
            } else {
                decision = PerformanceDecision(
                    activeMetric: .idle,
                    severity: .idle,
                    normalizedRingValue: 0,
                    reason: .candidatePending,
                    candidate: candidate,
                    candidateDuration: pendingDuration(at: now),
                    attentionScore: attentionScore(candidate),
                    preference: preference
                )
            }
            return decision
        }

        let heldFor = now - (activeSince ?? now)
        if candidate.metric == .idle {
            clearPending()
            if releaseSince == nil { releaseSince = now }
            if heldFor >= thresholds.minimumHoldDuration,
               now - (releaseSince ?? now) >= thresholds.releaseDelay {
                transitionToIdle()
            } else {
                decision.reason = heldFor < thresholds.minimumHoldDuration ? .minimumHold : .releasePending
                decision.candidate = candidate
                decision.activeDuration = heldFor
                decision.isReleasePending = heldFor >= thresholds.minimumHoldDuration
            }
            return decision
        }

        releaseSince = nil
        let severityAdvantage = candidate.severity.rawValue - decision.severity.rawValue
        guard heldFor >= thresholds.minimumHoldDuration else {
            clearPending()
            decision.reason = .minimumHold
            decision.candidate = candidate
            decision.challenger = candidate
            decision.activeDuration = heldFor
            return decision
        }
        let preferenceBreaksTie = severityAdvantage == 0
            && preference.preferredMetric == candidate.metric
            && candidate.metric != decision.activeMetric
        guard severityAdvantage >= thresholds.switchSeverityMargin || preferenceBreaksTie else {
            clearPending()
            decision.reason = .hysteresis
            decision.candidate = candidate
            decision.challenger = candidate
            decision.activeDuration = heldFor
            return decision
        }

        track(candidate, at: now)
        if pendingDuration(at: now) >= thresholds.switchDuration {
            activate(candidate, at: now, preferenceAffected: preferenceAffected)
        } else {
            decision.reason = .challengerPending
            decision.candidate = candidate
            decision.challenger = candidate
            decision.challengerDuration = pendingDuration(at: now)
            decision.activeDuration = heldFor
        }
        return decision
    }

    func candidate(for snapshot: PerformanceSnapshot) -> PerformanceCandidate {
        let thermal = thermalCandidate(snapshot.thermalState)
        let memory = memoryCandidate(snapshot.memory)
        let cpu = cpuCandidate(snapshot.cpuLoad)
        let candidates = [thermal, memory, cpu].filter { $0.metric != .idle }
        return candidates.max { lhs, rhs in
            let lhsScore = attentionScore(lhs)
            let rhsScore = attentionScore(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return relevanceRank(lhs.metric) < relevanceRank(rhs.metric)
        } ?? .idle
    }

    func candidates(for snapshot: PerformanceSnapshot) -> [PerformanceCandidate] {
        [
            cpuCandidate(snapshot.cpuLoad),
            memoryCandidate(snapshot.memory),
            thermalCandidate(snapshot.thermalState)
        ].filter { $0.metric != .idle }
    }

    func candidateDuration(for metric: PerformanceMetric, at timestamp: TimeInterval) -> TimeInterval {
        guard let since = metricCandidateSince[metric] else { return 0 }
        return max(0, timestamp - since)
    }

    private func cpuCandidate(_ load: Double?) -> PerformanceCandidate {
        guard let load, load >= thresholds.cpuActivation else { return .idle }
        let severity: PerformanceSeverity
        if load >= thresholds.cpuSerious {
            severity = .serious
        } else {
            severity = .elevated
        }
        return PerformanceCandidate(metric: .cpu, severity: severity, normalizedValue: clamp(load), reason: .cpuSustained)
    }

    private func memoryCandidate(_ memory: MemorySnapshot?) -> PerformanceCandidate {
        guard let memory else { return .idle }
        switch memory.stress {
        case .normal:
            return .idle
        case .elevated:
            return PerformanceCandidate(metric: .memory, severity: .elevated, normalizedValue: 0.58, reason: .memoryHeadroom)
        case .serious:
            return PerformanceCandidate(metric: .memory, severity: .serious, normalizedValue: 0.8, reason: .memoryHeadroom)
        case .critical:
            return PerformanceCandidate(metric: .memory, severity: .critical, normalizedValue: 1, reason: .memoryCritical)
        }
    }

    private func thermalCandidate(_ state: PerformanceThermalState) -> PerformanceCandidate {
        switch state {
        case .nominal:
            return .idle
        case .fair:
            return PerformanceCandidate(metric: .thermal, severity: .elevated, normalizedValue: 0.55, reason: .thermalFair)
        case .serious:
            return PerformanceCandidate(metric: .thermal, severity: .serious, normalizedValue: 0.82, reason: .thermalSerious)
        case .critical:
            return PerformanceCandidate(metric: .thermal, severity: .critical, normalizedValue: 1, reason: .thermalCritical)
        }
    }

    private func isCriticalOverride(_ candidate: PerformanceCandidate) -> Bool {
        (candidate.metric == .memory && candidate.severity == .critical)
            || (candidate.metric == .thermal && candidate.severity >= .serious)
    }

    private func relevanceRank(_ metric: PerformanceMetric) -> Int {
        switch metric {
        case .idle: 0
        case .cpu: 1
        case .memory: 2
        case .thermal: 3
        }
    }

    private mutating func track(_ candidate: PerformanceCandidate, at timestamp: TimeInterval) {
        guard pendingCandidate?.metric != candidate.metric else { return }
        pendingCandidate = candidate
        pendingSince = timestamp
    }

    private func pendingDuration(at timestamp: TimeInterval) -> TimeInterval {
        timestamp - (pendingSince ?? timestamp)
    }

    private mutating func activate(_ candidate: PerformanceCandidate, at timestamp: TimeInterval, preferenceAffected: Bool) {
        decision = PerformanceDecision(
            activeMetric: candidate.metric,
            severity: candidate.severity,
            normalizedRingValue: candidate.normalizedValue,
            reason: preferenceAffected ? preferenceReason(for: candidate.metric) : candidate.reason,
            candidate: candidate,
            candidateDuration: pendingDuration(at: timestamp),
            attentionScore: attentionScore(candidate),
            preference: preference,
            preferenceAffectedSelection: preferenceAffected,
            isCriticalOverride: isCriticalOverride(candidate)
        )
        activeSince = timestamp
        releaseSince = nil
        clearPending()
    }

    private mutating func transitionToIdle() {
        decision = .idle
        activeSince = nil
        releaseSince = nil
        clearPending()
    }

    private mutating func clearPending() {
        pendingCandidate = nil
        pendingSince = nil
    }

    private mutating func updateMetricCandidateDurations(_ candidates: [PerformanceCandidate], at timestamp: TimeInterval) {
        let active = Set(candidates.map(\.metric))
        metricCandidateSince = metricCandidateSince.filter { active.contains($0.key) }
        for candidate in candidates where metricCandidateSince[candidate.metric] == nil {
            metricCandidateSince[candidate.metric] = timestamp
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func attentionScore(_ candidate: PerformanceCandidate) -> Double {
        let preferenceBonus = preference.preferredMetric == candidate.metric ? thresholds.preferenceBias : 0
        let urgency: Double
        switch (candidate.metric, candidate.severity) {
        case (.thermal, .critical): urgency = 30
        case (.memory, .critical): urgency = 25
        case (.thermal, .serious): urgency = 20
        default: urgency = 0
        }
        return Double(candidate.severity.rawValue) * 100 + urgency + preferenceBonus
    }

    private func preferenceAffectedSelection(_ selected: PerformanceCandidate, candidates: [PerformanceCandidate]) -> Bool {
        guard preference.preferredMetric == selected.metric, preference != .automatic else { return false }
        return candidates.contains { $0.metric != selected.metric && $0.severity == selected.severity }
    }

    private func preferenceReason(for metric: PerformanceMetric) -> PerformanceDecisionReason {
        switch metric {
        case .cpu: .preferenceCPU
        case .memory: .preferenceMemory
        case .thermal: .preferenceThermal
        case .idle: .baseline
        }
    }
}
