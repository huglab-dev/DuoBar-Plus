import Foundation

enum PerformanceThermalState: Int, CaseIterable, Comparable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum MemoryStressEstimate: Int, CaseIterable, Comparable, Sendable {
    case normal
    case elevated
    case serious
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct MemorySnapshot: Equatable, Sendable {
    var totalBytes: UInt64
    var availableBytes: UInt64
    var compressedBytes: UInt64
    var pageOutsPerSecond: Double
    var stress: MemoryStressEstimate

    var availableHeadroom: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(availableBytes) / Double(totalBytes), 0), 1)
    }

    var compressionRatio: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(compressedBytes) / Double(totalBytes), 0), 1)
    }
}

struct PerformanceSnapshot: Equatable, Sendable {
    var timestamp: TimeInterval
    var cpuLoad: Double?
    var memory: MemorySnapshot?
    var thermalState: PerformanceThermalState

    // No public API provides system-wide GPU utilization to a normal macOS app.
    var gpuLoad: Double? { nil }
}
