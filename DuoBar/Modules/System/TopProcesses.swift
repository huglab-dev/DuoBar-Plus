import AppKit
import Darwin
import Foundation

struct RawProcess: Equatable, Sendable {
    var pid: Int32
    /// User + system CPU time in nanoseconds.
    var cpuNanoseconds: UInt64
    /// Physical footprint, the "Memory" column in Activity Monitor.
    var footprintBytes: UInt64
}

struct ProcessSample: Equatable, Identifiable, Sendable {
    var pid: Int32
    var name: String
    /// Share of one core: 1.0 is 100 %, as in Activity Monitor.
    var cpu: Double
    var memoryBytes: UInt64

    var id: Int32 { pid }
}

struct TopProcessResult: Equatable, Sendable {
    var byCPU: [ProcessSample]
    var byMemory: [ProcessSample]
    /// Processes that could be read, out of all processes. Other users' and
    /// root processes are not readable without privileges.
    var readable: Int
    var total: Int

    static let empty = TopProcessResult(byCPU: [], byMemory: [], readable: 0, total: 0)
}

protocol ProcessListReading: Sendable {
    /// Readable processes and the total number of processes.
    func snapshot() -> (processes: [RawProcess], total: Int)
    func name(for pid: Int32) -> String
}

enum TopProcesses {
    /// CPU share per pid between two snapshots. Processes that are new since
    /// the previous snapshot get no value yet.
    static func cpuShares(previous: [Int32: UInt64], current: [RawProcess], elapsedNanoseconds: UInt64) -> [Int32: Double] {
        guard elapsedNanoseconds > 0 else { return [:] }
        var shares: [Int32: Double] = [:]
        for process in current {
            guard let old = previous[process.pid], process.cpuNanoseconds >= old else { continue }
            shares[process.pid] = Double(process.cpuNanoseconds - old) / Double(elapsedNanoseconds)
        }
        return shares
    }

    static func top(_ processes: [RawProcess], shares: [Int32: Double], limit: Int) -> (byCPU: [RawProcess], byMemory: [RawProcess]) {
        let byCPU = processes
            .filter { (shares[$0.pid] ?? 0) > 0 }
            .sorted { (shares[$0.pid] ?? 0) > (shares[$1.pid] ?? 0) }
            .prefix(limit)
        let byMemory = processes
            .sorted { $0.footprintBytes > $1.footprintBytes }
            .prefix(limit)
        return (Array(byCPU), Array(byMemory))
    }

    static func cpuText(_ share: Double) -> String {
        String(format: "%.1f %%", locale: Locale.current, share * 100)
    }
}

/// Keeps the previous snapshot between calls. Confined to one serial queue.
final class TopProcessSampler: @unchecked Sendable {
    private let reader: any ProcessListReading
    private var previous: [Int32: UInt64] = [:]
    private var previousTime: UInt64 = 0
    private var names: [Int32: String] = [:]

    init(reader: any ProcessListReading = ProcessListReader()) {
        self.reader = reader
    }

    func sample(limit: Int = 5, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> TopProcessResult {
        let (processes, total) = reader.snapshot()
        let shares = previousTime == 0
            ? [:]
            : TopProcesses.cpuShares(previous: previous, current: processes, elapsedNanoseconds: now - previousTime)
        previous = Dictionary(processes.map { ($0.pid, $0.cpuNanoseconds) }, uniquingKeysWith: { first, _ in first })
        previousTime = now

        let live = Set(previous.keys)
        names = names.filter { live.contains($0.key) }

        let (byCPU, byMemory) = TopProcesses.top(processes, shares: shares, limit: limit)
        func sample(_ process: RawProcess) -> ProcessSample {
            ProcessSample(
                pid: process.pid,
                name: name(for: process.pid),
                cpu: shares[process.pid] ?? 0,
                memoryBytes: process.footprintBytes
            )
        }
        return TopProcessResult(
            byCPU: byCPU.map(sample),
            byMemory: byMemory.map(sample),
            readable: processes.count,
            total: total
        )
    }

    func reset() {
        previous = [:]
        previousTime = 0
    }

    private func name(for pid: Int32) -> String {
        if let cached = names[pid] { return cached }
        let resolved = reader.name(for: pid)
        names[pid] = resolved
        return resolved
    }
}

struct ProcessListReader: ProcessListReading {
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    func snapshot() -> (processes: [RawProcess], total: Int) {
        let estimate = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard estimate > 0 else { return ([], 0) }
        var pids = [pid_t](repeating: 0, count: Int(estimate) / MemoryLayout<pid_t>.size + 64)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return ([], 0) }
        let list = pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 > 0 }

        var processes: [RawProcess] = []
        processes.reserveCapacity(list.count)
        for pid in list {
            var info = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { continue }
            // rusage CPU times are in Mach absolute time units on Apple Silicon.
            let ticks = info.ri_user_time &+ info.ri_system_time
            let nanoseconds = ticks.multipliedReportingOverflow(by: Self.timebase.numer).overflow
                ? ticks / Self.timebase.denom * Self.timebase.numer
                : ticks * Self.timebase.numer / Self.timebase.denom
            processes.append(RawProcess(pid: pid, cpuNanoseconds: nanoseconds, footprintBytes: info.ri_phys_footprint))
        }
        return (processes, list.count)
    }

    func name(for pid: Int32) -> String {
        if let app = NSRunningApplication(processIdentifier: pid), let name = app.localizedName, !name.isEmpty {
            return name
        }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(pid, &path, UInt32(path.count)) > 0 {
            let last = (String(cString: path) as NSString).lastPathComponent
            if !last.isEmpty { return last }
        }
        var name = [CChar](repeating: 0, count: 256)
        if proc_name(pid, &name, UInt32(name.count)) > 0 {
            return String(cString: name)
        }
        return "pid \(pid)"
    }
}
