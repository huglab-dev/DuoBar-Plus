import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class TopProcessesTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "TopProcessesTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testCPUSharesFromTimeDeltas() {
        let shares = TopProcesses.cpuShares(
            previous: [1: 1_000_000_000, 2: 0],
            current: [
                RawProcess(pid: 1, cpuNanoseconds: 2_500_000_000, footprintBytes: 0), // 1.5 s over 1 s → 150 %
                RawProcess(pid: 2, cpuNanoseconds: 100_000_000, footprintBytes: 0),   // 10 %
                RawProcess(pid: 3, cpuNanoseconds: 9_000_000_000, footprintBytes: 0), // new, no value yet
            ],
            elapsedNanoseconds: 1_000_000_000
        )
        XCTAssertEqual(shares[1] ?? 0, 1.5, accuracy: 0.0001)
        XCTAssertEqual(shares[2] ?? 0, 0.1, accuracy: 0.0001)
        XCTAssertNil(shares[3])
    }

    func testTopSelectionByCPUAndMemory() {
        let processes = (1...8).map { RawProcess(pid: Int32($0), cpuNanoseconds: 0, footprintBytes: UInt64($0) * 100) }
        let shares: [Int32: Double] = [3: 0.5, 7: 0.9, 1: 0.1, 2: 0]
        let (byCPU, byMemory) = TopProcesses.top(processes, shares: shares, limit: 5)
        XCTAssertEqual(byCPU.map(\.pid), [7, 3, 1], "idle processes are left out of the CPU list")
        XCTAssertEqual(byMemory.map(\.pid), [8, 7, 6, 5, 4])
    }

    func testSamplerNeedsTwoSnapshotsAndCachesNames() {
        let reader = FakeProcessListReader()
        let sampler = TopProcessSampler(reader: reader)

        let first = sampler.sample(now: 1_000_000_000)
        XCTAssertTrue(first.byCPU.isEmpty)
        XCTAssertEqual(first.byMemory.first?.name, "Big")

        reader.advance(pid: 10, by: 500_000_000)
        let second = sampler.sample(now: 2_000_000_000)
        XCTAssertEqual(second.byCPU.map(\.name), ["Busy"])
        XCTAssertEqual(second.byCPU.first?.cpu ?? 0, 0.5, accuracy: 0.0001)
        XCTAssertEqual(second.readable, 2)
        XCTAssertEqual(second.total, 3)
        XCTAssertEqual(reader.nameLookups, 2, "names are resolved once per pid")
    }

    func testModuleSamplesProcessesOnlyWithOpenDetailAndOption() {
        let reader = FakeProcessListReader()
        let module = SystemModule(
            reader: FakeSystemStatsReader(),
            infoProvider: SystemInfoProvider(reader: FakeSystemInfoReader()),
            processSampler: TopProcessSampler(reader: reader),
            defaults: defaults,
            interval: 60,
            firstSampleDelay: 60,
            processInterval: 0.05
        )
        module.popoverDidOpen()
        spin(0.1)
        XCTAssertEqual(reader.snapshots, 0, "the main view never samples processes")

        module.detailDidOpen()
        XCTAssertTrue(module.isSamplingProcesses)
        waitUntil { module.topProcesses != nil && reader.snapshots >= 2 }

        module.detailDidClose()
        XCTAssertFalse(module.isSamplingProcesses)
        spin(0.05)
        let count = reader.snapshots
        spin(0.15)
        XCTAssertEqual(reader.snapshots, count)

        defaults.set(false, forKey: ModuleOption.topProcesses.key)
        module.detailDidOpen()
        XCTAssertFalse(module.isSamplingProcesses)
        XCTAssertFalse(module.showsTopProcesses)
        module.popoverDidClose()
    }

    func testRealReaderConvertsCPUTimeToNanoseconds() throws {
        // Burn some CPU so the comparison is meaningful.
        var x = 0.0
        let end = Date().addingTimeInterval(0.2)
        while Date() < end { x += sin(x) + 1 }
        XCTAssertGreaterThan(x, 0)

        var spec = timespec()
        clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &spec)
        let expected = Double(spec.tv_sec) * 1e9 + Double(spec.tv_nsec)

        let (processes, total) = ProcessListReader().snapshot()
        let me = try XCTUnwrap(processes.first { $0.pid == getpid() })
        let ratio = Double(me.cpuNanoseconds) / expected
        XCTAssertEqual(ratio, 1, accuracy: 0.25, "rusage CPU time must be in nanoseconds after timebase conversion")
        XCTAssertGreaterThan(me.footprintBytes, 0)
        XCTAssertGreaterThan(total, processes.count / 2)
        XCTAssertFalse(ProcessListReader().name(for: getpid()).isEmpty)
    }

    func testRenderTopProcesses() throws {
        let result = TopProcessResult(
            byCPU: [
                ProcessSample(pid: 1, name: "Xcode", cpu: 1.234, memoryBytes: 3_000_000_000),
                ProcessSample(pid: 2, name: "Safari", cpu: 0.18, memoryBytes: 900_000_000),
            ],
            byMemory: [],
            readable: 466,
            total: 700
        )
        let view = VStack(spacing: 6) { TopProcessesSection(result: result) }
            .padding(12)
            .frame(width: 304)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-TopProcesses.png"), options: .atomic)
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.01) }
        XCTAssertTrue(condition(), "condition not met within \(timeout) s", file: file, line: line)
    }
}

final class FakeProcessListReader: ProcessListReading, @unchecked Sendable {
    private let lock = NSLock()
    private var processes = [
        RawProcess(pid: 10, cpuNanoseconds: 0, footprintBytes: 100),
        RawProcess(pid: 20, cpuNanoseconds: 0, footprintBytes: 5_000),
    ]
    private var _snapshots = 0
    private var _nameLookups = 0

    var snapshots: Int { lock.withLock { _snapshots } }
    var nameLookups: Int { lock.withLock { _nameLookups } }

    func advance(pid: Int32, by nanoseconds: UInt64) {
        lock.withLock {
            if let index = processes.firstIndex(where: { $0.pid == pid }) {
                processes[index].cpuNanoseconds += nanoseconds
            }
        }
    }

    func snapshot() -> (processes: [RawProcess], total: Int) {
        lock.withLock {
            _snapshots += 1
            return (processes, 3)
        }
    }

    func name(for pid: Int32) -> String {
        lock.withLock { _nameLookups += 1 }
        return pid == 10 ? "Busy" : "Big"
    }
}
