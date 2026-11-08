import Foundation

// MARK: - CPU

struct CPUCoreTicks: Equatable, Sendable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64
    var nice: UInt64

    var busy: UInt64 { user &+ system &+ nice }
    var total: UInt64 { busy &+ idle }
}

enum CPUCoreKind: Equatable, Sendable {
    case efficiency
    case performance
    case unknown
}

struct CPUUsage: Equatable, Sendable {
    /// 0…1 across all cores.
    var total: Double
    /// 0…1 per logical core, in core order.
    var perCore: [Double]
    /// Averages per core kind, nil when the Mac has no such cores.
    var efficiency: Double?
    var performance: Double?

    /// Usage between two tick samples. Returns nil when the samples do not
    /// line up (different core counts) or no time has passed.
    static func compute(previous: [CPUCoreTicks], current: [CPUCoreTicks], kinds: [CPUCoreKind]) -> CPUUsage? {
        guard !current.isEmpty, previous.count == current.count else { return nil }
        var busyTotal: UInt64 = 0
        var allTotal: UInt64 = 0
        var perCore: [Double] = []
        for (old, new) in zip(previous, current) {
            let busy = new.busy &- old.busy
            let total = new.total &- old.total
            busyTotal &+= busy
            allTotal &+= total
            perCore.append(total > 0 ? min(max(Double(busy) / Double(total), 0), 1) : 0)
        }
        guard allTotal > 0 else { return nil }

        func average(_ kind: CPUCoreKind) -> Double? {
            guard kinds.count == perCore.count else { return nil }
            let values = zip(kinds, perCore).filter { $0.0 == kind }.map(\.1)
            guard !values.isEmpty else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }

        return CPUUsage(
            total: min(max(Double(busyTotal) / Double(allTotal), 0), 1),
            perCore: perCore,
            efficiency: average(.efficiency),
            performance: average(.performance)
        )
    }
}

// MARK: - Memory

/// Page counts from `host_statistics64(HOST_VM_INFO64)`.
struct VMPageCounts: Equatable, Sendable {
    var internalPages: UInt64
    var purgeable: UInt64
    var wired: UInt64
    var compressed: UInt64
    var external: UInt64
    var pageSize: UInt64
}

/// Memory split the way Activity Monitor presents it.
struct MemoryBreakdown: Equatable, Sendable {
    var totalBytes: UInt64
    var appBytes: UInt64
    var wiredBytes: UInt64
    var compressedBytes: UInt64
    var cachedBytes: UInt64

    /// App + wired + compressed, Activity Monitor's "Memory Used".
    var usedBytes: UInt64 { appBytes + wiredBytes + compressedBytes }

    var usedFraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    init(totalBytes: UInt64, appBytes: UInt64, wiredBytes: UInt64, compressedBytes: UInt64, cachedBytes: UInt64) {
        self.totalBytes = totalBytes
        self.appBytes = appBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.cachedBytes = cachedBytes
    }

    init(pages: VMPageCounts, totalBytes: UInt64) {
        let size = pages.pageSize
        self.init(
            totalBytes: totalBytes,
            appBytes: (pages.internalPages > pages.purgeable ? pages.internalPages - pages.purgeable : 0) * size,
            wiredBytes: pages.wired * size,
            compressedBytes: pages.compressed * size,
            cachedBytes: (pages.external + pages.purgeable) * size
        )
    }
}

enum MemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warning, 4 critical.
    init?(sysctlLevel: Int) {
        switch sysctlLevel {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }
}

struct SwapUsage: Equatable, Sendable {
    var totalBytes: UInt64
    var usedBytes: UInt64
}

struct LoadAverage: Equatable, Sendable {
    var one: Double
    var five: Double
    var fifteen: Double
}

// MARK: - Text

enum SystemText {
    private static let memoryFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func memory(_ bytes: UInt64) -> String {
        memoryFormatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func percent(_ fraction: Double) -> String {
        localized("%d%%", Int((fraction * 100).rounded()))
    }

    static func summary(cpu: CPUUsage?, memory: MemoryBreakdown?) -> String {
        let cpuText = cpu.map { percent($0.total) } ?? "–"
        let memoryText = memory.map { percent($0.usedFraction) } ?? "–"
        return localized("CPU %@ · RAM %@", cpuText, memoryText)
    }

    static func load(_ load: LoadAverage) -> String {
        String(format: "%.2f  %.2f  %.2f", locale: Locale.current, load.one, load.five, load.fifteen)
    }

    static func pressure(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: localized("Normal")
        case .warning: localized("Warning")
        case .critical: localized("Critical")
        }
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: localized("Nominal")
        case .fair: localized("Fair")
        case .serious: localized("Serious")
        case .critical: localized("Critical")
        @unknown default: localized("Unknown")
        }
    }

    /// "3 d 4 h", "5 h 12 min", "8 min".
    static func uptime(_ interval: TimeInterval) -> String {
        let minutes = max(Int(interval / 60), 0)
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = minutes % 60
        if days > 0 { return localized("%d d %d h", days, hours) }
        if hours > 0 { return localized("%d h %d min", hours, mins) }
        return localized("%d min", mins)
    }
}
