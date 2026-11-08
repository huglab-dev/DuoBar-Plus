import Darwin
import Foundation
import IOKit

/// Live system counters. Every call is a cheap syscall that is safe on the
/// main thread; the module decides how often to call them.
protocol SystemStatsReading: Sendable {
    func cpuTicks() -> [CPUCoreTicks]?
    func coreKinds() -> [CPUCoreKind]
    func vmPageCounts() -> VMPageCounts?
    func physicalMemory() -> UInt64
    func memoryPressureLevel() -> Int?
    func swapUsage() -> SwapUsage?
    func loadAverage() -> LoadAverage?
    func bootTime() -> Date?
    func thermalState() -> ProcessInfo.ThermalState
}

struct SystemStatsReader: SystemStatsReading {
    func cpuTicks() -> [CPUCoreTicks]? {
        var processorCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &processorCount, &info, &infoCount)
        guard result == KERN_SUCCESS, let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_,
                vm_address_t(bitPattern: info),
                vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)
            )
        }
        return info.withMemoryRebound(to: processor_cpu_load_info_data_t.self, capacity: Int(processorCount)) { buffer in
            (0..<Int(processorCount)).map { index in
                let ticks = buffer[index].cpu_ticks
                return CPUCoreTicks(
                    user: UInt64(ticks.0),
                    system: UInt64(ticks.1),
                    idle: UInt64(ticks.2),
                    nice: UInt64(ticks.3)
                )
            }
        }
    }

    /// Core kinds in logical-CPU order. Apple Silicon publishes each core's
    /// cluster type in the device tree; Intel Macs return `.unknown`.
    func coreKinds() -> [CPUCoreKind] {
        if let kinds = Self.deviceTreeCoreKinds(), !kinds.isEmpty {
            return kinds
        }
        // Fallback: efficiency cores are numbered first on Apple Silicon.
        guard Self.sysctlInt("hw.nperflevels") ?? 1 >= 2,
              let performance = Self.sysctlInt("hw.perflevel0.logicalcpu"),
              let efficiency = Self.sysctlInt("hw.perflevel1.logicalcpu") else { return [] }
        return Array(repeating: .efficiency, count: efficiency) + Array(repeating: .performance, count: performance)
    }

    func vmPageCounts() -> VMPageCounts? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        return VMPageCounts(
            internalPages: UInt64(statistics.internal_page_count),
            purgeable: UInt64(statistics.purgeable_count),
            wired: UInt64(statistics.wire_count),
            compressed: UInt64(statistics.compressor_page_count),
            external: UInt64(statistics.external_page_count),
            pageSize: UInt64(pageSize)
        )
    }

    func physicalMemory() -> UInt64 {
        ProcessInfo.processInfo.physicalMemory
    }

    func memoryPressureLevel() -> Int? {
        Self.sysctlInt("kern.memorystatus_vm_pressure_level")
    }

    func swapUsage() -> SwapUsage? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return SwapUsage(totalBytes: usage.xsu_total, usedBytes: usage.xsu_used)
    }

    func loadAverage() -> LoadAverage? {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else { return nil }
        return LoadAverage(one: values[0], five: values[1], fifteen: values[2])
    }

    func bootTime() -> Date? {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0, time.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_usec) / 1_000_000)
    }

    func thermalState() -> ProcessInfo.ThermalState {
        ProcessInfo.processInfo.thermalState
    }

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            var wide: Int64 = 0
            var wideSize = MemoryLayout<Int64>.size
            guard sysctlbyname(name, &wide, &wideSize, nil, 0) == 0 else { return nil }
            return Int(wide)
        }
        return Int(value)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func deviceTreeCoreKinds() -> [CPUCoreKind]? {
        let cpus = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpus != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(cpus) }

        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(cpus, kIODeviceTreePlane, &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var kindsByID: [Int: CPUCoreKind] = [:]
        var entry = IOIteratorNext(iterator)
        while entry != MACH_PORT_NULL {
            defer {
                IOObjectRelease(entry)
                entry = IOIteratorNext(iterator)
            }
            guard let id = registryProperty(entry, "logical-cpu-id").flatMap(intValue),
                  let data = registryProperty(entry, "cluster-type") as? Data,
                  let first = data.first else { continue }
            switch UInt8(first) {
            case UInt8(ascii: "E"): kindsByID[id] = .efficiency
            case UInt8(ascii: "P"): kindsByID[id] = .performance
            default: kindsByID[id] = .unknown
            }
        }
        guard !kindsByID.isEmpty else { return nil }
        return (0...(kindsByID.keys.max() ?? 0)).map { kindsByID[$0] ?? .unknown }
    }

    private static func registryProperty(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func intValue(_ value: Any) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let data = value as? Data, data.count >= 4 {
            return Int(data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        }
        return nil
    }
}
