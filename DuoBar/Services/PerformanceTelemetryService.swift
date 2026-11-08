import Darwin.Mach
import Foundation

struct MemoryStressEstimator {
    static func estimate(headroom: Double, compression: Double, pageOutsPerSecond: Double) -> MemoryStressEstimate {
        if headroom <= 0.03, pageOutsPerSecond >= 64 {
            return .critical
        }
        if headroom <= 0.06, pageOutsPerSecond >= 8 || compression >= 0.45 {
            return .serious
        }
        if headroom <= 0.03 {
            return .elevated
        }
        if headroom <= 0.10, pageOutsPerSecond > 0 || compression >= 0.30 {
            return .elevated
        }
        return .normal
    }
}

final class PerformanceTelemetrySampler {
    private var previousCPUTicks: CPUTicks?
    private var previousPageOuts: UInt64?
    private var previousMemoryTimestamp: TimeInterval?

    func sample(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PerformanceSnapshot {
        PerformanceSnapshot(
            timestamp: timestamp,
            cpuLoad: sampleCPU(),
            memory: sampleMemory(at: timestamp),
            thermalState: thermalState(ProcessInfo.processInfo.thermalState)
        )
    }

    private func sampleCPU() -> Double? {
        var processorCount: natural_t = 0
        var processorInfo: processor_info_array_t?
        var processorInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &processorInfo,
            &processorInfoCount
        )
        guard result == KERN_SUCCESS, let processorInfo else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: processorInfo),
                vm_size_t(processorInfoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }

        let current = processorInfo.withMemoryRebound(
            to: processor_cpu_load_info_data_t.self,
            capacity: Int(processorCount)
        ) { buffer in
            var ticks = CPUTicks.zero
            for index in 0..<Int(processorCount) {
                let values = buffer[index].cpu_ticks
                ticks.user += UInt64(values.0)
                ticks.system += UInt64(values.1)
                ticks.idle += UInt64(values.2)
                ticks.nice += UInt64(values.3)
            }
            return ticks
        }

        defer { previousCPUTicks = current }
        guard let previous = previousCPUTicks else { return nil }
        let user = current.user &- previous.user
        let system = current.system &- previous.system
        let idle = current.idle &- previous.idle
        let nice = current.nice &- previous.nice
        let total = user + system + idle + nice
        guard total > 0 else { return nil }
        return min(max(Double(user + system + nice) / Double(total), 0), 1)
    }

    private func sampleMemory(at timestamp: TimeInterval) -> MemorySnapshot? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }

        let totalBytes = ProcessInfo.processInfo.physicalMemory
        // Free + inactive pages are a useful reclaimable-headroom approximation.
        // This is deliberately not presented as Activity Monitor's Memory Pressure.
        let availablePages = UInt64(statistics.free_count) + UInt64(statistics.inactive_count)
        let availableBytes = availablePages * UInt64(pageSize)
        let compressedBytes = UInt64(statistics.compressor_page_count) * UInt64(pageSize)

        let pageOutRate: Double
        if let previousPageOuts, let previousMemoryTimestamp, timestamp > previousMemoryTimestamp {
            pageOutRate = Double(statistics.pageouts &- previousPageOuts) / (timestamp - previousMemoryTimestamp)
        } else {
            pageOutRate = 0
        }
        previousPageOuts = statistics.pageouts
        previousMemoryTimestamp = timestamp

        let headroom = totalBytes > 0 ? Double(availableBytes) / Double(totalBytes) : 0
        let compression = totalBytes > 0 ? Double(compressedBytes) / Double(totalBytes) : 0
        return MemorySnapshot(
            totalBytes: totalBytes,
            availableBytes: min(availableBytes, totalBytes),
            compressedBytes: compressedBytes,
            pageOutsPerSecond: pageOutRate,
            stress: MemoryStressEstimator.estimate(
                headroom: headroom,
                compression: compression,
                pageOutsPerSecond: pageOutRate
            )
        )
    }

    private func thermalState(_ state: ProcessInfo.ThermalState) -> PerformanceThermalState {
        switch state {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .nominal
        }
    }

    private struct CPUTicks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        static let zero = CPUTicks(user: 0, system: 0, idle: 0, nice: 0)
    }
}

@MainActor
final class PerformancePrototypeMonitor: ObservableObject {
    @Published private(set) var snapshot: PerformanceSnapshot?
    @Published private(set) var decision: PerformanceDecision = .idle

    private let sampler: PerformanceTelemetrySampler
    private var engine: PerformanceDecisionEngine
    private var timer: Timer?

    init(
        sampler: PerformanceTelemetrySampler = PerformanceTelemetrySampler(),
        engine: PerformanceDecisionEngine = PerformanceDecisionEngine()
    ) {
        self.sampler = sampler
        self.engine = engine
    }

    func start(interval: TimeInterval = 2) {
        guard timer == nil else { return }
        refresh()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = min(interval * 0.2, 0.5)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let next = sampler.sample()
        snapshot = next
        decision = engine.update(with: next)
    }

    deinit {
        timer?.invalidate()
    }
}
