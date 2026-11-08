import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class SystemModuleTests: XCTestCase {
    func testCPUUsageFromTickDeltasWithCoreKinds() throws {
        let previous = [
            CPUCoreTicks(user: 100, system: 50, idle: 850, nice: 0),
            CPUCoreTicks(user: 0, system: 0, idle: 1000, nice: 0),
        ]
        let current = [
            CPUCoreTicks(user: 150, system: 100, idle: 850, nice: 0),   // 100 busy of 100 → 100 %
            CPUCoreTicks(user: 10, system: 10, idle: 1080, nice: 0),    // 20 busy of 100 → 20 %
        ]
        let usage = try XCTUnwrap(CPUUsage.compute(previous: previous, current: current, kinds: [.efficiency, .performance]))
        XCTAssertEqual(usage.total, 0.6, accuracy: 0.0001)
        XCTAssertEqual(usage.perCore[0], 1, accuracy: 0.0001)
        XCTAssertEqual(usage.perCore[1], 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(usage.efficiency), 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(usage.performance), 0.2, accuracy: 0.0001)
    }

    func testCPUUsageRejectsMismatchedOrIdleSamples() {
        let ticks = [CPUCoreTicks(user: 1, system: 1, idle: 1, nice: 0)]
        XCTAssertNil(CPUUsage.compute(previous: [], current: ticks, kinds: []))
        XCTAssertNil(CPUUsage.compute(previous: ticks, current: ticks, kinds: []))
        let usage = CPUUsage.compute(
            previous: ticks,
            current: [CPUCoreTicks(user: 2, system: 1, idle: 2, nice: 0)],
            kinds: []
        )
        XCTAssertNil(usage?.efficiency)
        XCTAssertNil(usage?.performance)
    }

    func testMemoryBreakdownMatchesActivityMonitorDefinitions() {
        let pages = VMPageCounts(internalPages: 1000, purgeable: 100, wired: 300, compressed: 200, external: 400, pageSize: 16384)
        let memory = MemoryBreakdown(pages: pages, totalBytes: 4096 * 16384)
        XCTAssertEqual(memory.appBytes, 900 * 16384)
        XCTAssertEqual(memory.wiredBytes, 300 * 16384)
        XCTAssertEqual(memory.compressedBytes, 200 * 16384)
        XCTAssertEqual(memory.cachedBytes, 500 * 16384)
        XCTAssertEqual(memory.usedBytes, 1400 * 16384)
        XCTAssertEqual(memory.usedFraction, 1400.0 / 4096.0, accuracy: 0.0001)
    }

    func testPressureLevelsAndTextHelpers() {
        XCTAssertEqual(MemoryPressure(sysctlLevel: 1), .normal)
        XCTAssertEqual(MemoryPressure(sysctlLevel: 2), .warning)
        XCTAssertEqual(MemoryPressure(sysctlLevel: 4), .critical)
        XCTAssertNil(MemoryPressure(sysctlLevel: 3))
        XCTAssertEqual(SystemText.uptime(8 * 60 + 30), localized("%d min", 8))
        XCTAssertEqual(SystemText.uptime(5 * 3600 + 12 * 60), localized("%d h %d min", 5, 12))
        XCTAssertEqual(SystemText.uptime(3 * 86400 + 4 * 3600 + 59), localized("%d d %d h", 3, 4))
    }

    func testNoSamplingUntilPopoverOpensAndNoneAfterClose() {
        let reader = FakeSystemStatsReader()
        let module = SystemModule(reader: reader, interval: 0.05, firstSampleDelay: 0.01)
        module.activate()
        XCTAssertFalse(module.isSampling)
        XCTAssertEqual(reader.tickReads, 0)

        module.popoverDidOpen()
        XCTAssertTrue(module.isSampling)
        spin(0.2)
        XCTAssertGreaterThanOrEqual(reader.tickReads, 3)
        XCTAssertNotNil(module.cpu)
        XCTAssertNotNil(module.memory)
        XCTAssertEqual(module.pressure, .normal)
        XCTAssertEqual(reader.swapReads, 0, "swap is detail-only")

        module.popoverDidClose()
        XCTAssertFalse(module.isSampling)
        let reads = reader.tickReads
        spin(0.15)
        XCTAssertEqual(reader.tickReads, reads)
    }

    func testCPUHistoryFillsWhileOpenAndClearsOnClose() {
        let reader = FakeSystemStatsReader()
        let module = SystemModule(reader: reader, interval: 0.05, firstSampleDelay: 0.01)
        XCTAssertTrue(module.cpuHistory.samples.isEmpty)
        module.popoverDidOpen()
        spin(0.2)
        XCTAssertFalse(module.cpuHistory.samples.isEmpty)
        module.popoverDidClose()
        XCTAssertTrue(module.cpuHistory.samples.isEmpty)
    }

    func testDetailSamplesFasterOnlyWhileOpen() {
        let module = SystemModule(reader: FakeSystemStatsReader(), interval: 2, detailInterval: 1, firstSampleDelay: 60)
        XCTAssertEqual(module.currentInterval, 2)
        module.popoverDidOpen()
        module.detailDidOpen()
        XCTAssertEqual(module.currentInterval, 1)
        module.detailDidClose()
        XCTAssertEqual(module.currentInterval, 2)
        module.popoverDidClose()
    }

    func testCPUHistoryKeepsAWindowAndClamps() {
        let history = CPUHistory(capacity: 3)
        for value in [0.1, 0.2, 0.3, 1.5] { history.append(value) }
        XCTAssertEqual(history.samples.map(\.total), [0.2, 0.3, 1])
        XCTAssertEqual(history.xDomain, 1...3)
    }

    func testDetailAddsSwapAndLoadOnlyWhileOpen() {
        let reader = FakeSystemStatsReader()
        let module = SystemModule(reader: reader, interval: 0.05, firstSampleDelay: 0.01)
        module.popoverDidOpen()
        module.detailDidOpen()
        XCTAssertEqual(reader.swapReads, 1)
        XCTAssertNotNil(module.swap)
        XCTAssertNil(module.load, "load average is no longer shown or read")

        module.detailDidClose()
        let swapReads = reader.swapReads
        spin(0.15)
        XCTAssertEqual(reader.swapReads, swapReads)
        module.popoverDidClose()
    }

    func testMDMParserHandlesKnownFormats() throws {
        let enrolled = try XCTUnwrap(MDMStatus.parse("""
        Enrolled via DEP: No
        MDM enrollment: Yes (User Approved)
        MDM server: https://mdm.example.com/checkin?x=1
        """))
        XCTAssertTrue(enrolled.isEnrolled)
        XCTAssertFalse(enrolled.enrolledViaDEP)
        XCTAssertEqual(enrolled.enrollmentDetail, "Yes (User Approved)")
        XCTAssertEqual(enrolled.serverHost, "mdm.example.com")

        let dep = try XCTUnwrap(MDMStatus.parse("Enrolled via DEP: Yes\nMDM enrollment: Yes"))
        XCTAssertTrue(dep.enrolledViaDEP)

        let none = try XCTUnwrap(MDMStatus.parse("Enrolled via DEP: No\nMDM enrollment: No"))
        XCTAssertEqual(none, .notEnrolled.with(detail: "No"))

        XCTAssertNil(MDMStatus.parse("profiles: unknown option"))
        XCTAssertNil(MDMStatus.parse(""))
    }

    func testInfoIsLoadedOnlyOnRequestAndOnce() {
        let reader = FakeSystemInfoReader()
        let provider = SystemInfoProvider(reader: reader)
        let module = SystemModule(reader: FakeSystemStatsReader(), infoProvider: provider, interval: 60, firstSampleDelay: 60)

        module.popoverDidOpen()
        module.detailDidOpen()
        spin(0.05)
        XCTAssertEqual(reader.reads, 0, "This Mac is collapsed by default, so profiles never runs")

        provider.loadIfNeeded()
        provider.loadIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while !provider.hasLoadedMDM, Date() < deadline { spin(0.01) }
        XCTAssertEqual(reader.reads, 1)
        XCTAssertEqual(provider.info?.model, "Mac15,6")
        module.popoverDidClose()
    }

    func testRealSystemInfoAndProfiles() throws {
        let info = SystemInfoReader().systemInfo()
        XCTAssertTrue(info.osVersion.hasPrefix("macOS "))
        XCTAssertNotNil(info.model)
        XCTAssertGreaterThan(info.memoryBytes, 0)
        XCTAssertNotNil(SystemInfoReader().mdmStatus(), "profiles output should parse on any Mac")
    }

    func testDeactivateStopsSampling() {
        let module = SystemModule(reader: FakeSystemStatsReader(), interval: 0.05, firstSampleDelay: 0.01)
        module.popoverDidOpen()
        module.deactivate()
        XCTAssertFalse(module.isSampling)
    }

    func testRealReaderProducesPlausibleValues() throws {
        let reader = SystemStatsReader()
        let ticks = try XCTUnwrap(reader.cpuTicks())
        XCTAssertEqual(ticks.count, ProcessInfo.processInfo.activeProcessorCount)
        let kinds = reader.coreKinds()
        if !kinds.isEmpty {
            XCTAssertEqual(kinds.count, ticks.count)
        }
        let memory = MemoryBreakdown(pages: try XCTUnwrap(reader.vmPageCounts()), totalBytes: reader.physicalMemory())
        XCTAssertGreaterThan(memory.usedFraction, 0.05)
        XCTAssertLessThanOrEqual(memory.usedBytes, memory.totalBytes)
        XCTAssertNotNil(reader.memoryPressureLevel().flatMap(MemoryPressure.init(sysctlLevel:)))
        XCTAssertNotNil(reader.swapUsage())
        XCTAssertNotNil(reader.loadAverage())
        XCTAssertLessThan(try XCTUnwrap(reader.bootTime()), Date())
    }

    func testRenderSystemDetail() throws {
        let warningReader = FakeSystemStatsReader()
        warningReader.pressureLevel = 2
        let module = SystemModule(
            reader: warningReader,
            infoProvider: SystemInfoProvider(reader: FakeSystemInfoReader()),
            interval: 60,
            firstSampleDelay: 60
        )
        module.popoverDidOpen()
        module.sample()
        module.detailDidOpen()
        for value in [0.12, 0.18, 0.4, 0.22, 0.15, 0.3, 0.55, 0.35, 0.2, 0.16, 0.25, 0.18] {
            module.cpuHistory.append(value)
        }

        let view = VStack(spacing: 6) {
            SystemStatusRow(module: module, onActivate: {})
            SystemDetailView(module: module, onOpenActivityMonitor: {})
        }
        .padding(12)
        .frame(width: 304)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        try writePNG(view, named: "DuoBarPlus-Detail-system.png")
        module.popoverDidClose()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func writePNG<Content: View>(_ content: Content, named name: String) throws {
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name), options: .atomic)
    }
}

final class FakeSystemStatsReader: SystemStatsReading, @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: UInt64 = 0
    private var _tickReads = 0
    private var _swapReads = 0

    var tickReads: Int { lock.withLock { _tickReads } }
    var swapReads: Int { lock.withLock { _swapReads } }

    func cpuTicks() -> [CPUCoreTicks]? {
        lock.withLock {
            _tickReads += 1
            ticks += 100
            // E core 25 % busy, P core 75 % busy.
            return [
                CPUCoreTicks(user: ticks / 4, system: 0, idle: ticks * 3 / 4, nice: 0),
                CPUCoreTicks(user: ticks * 3 / 4, system: 0, idle: ticks / 4, nice: 0),
            ]
        }
    }

    func coreKinds() -> [CPUCoreKind] { [.efficiency, .performance] }

    func vmPageCounts() -> VMPageCounts? {
        VMPageCounts(internalPages: 500_000, purgeable: 20_000, wired: 150_000, compressed: 80_000, external: 200_000, pageSize: 16384)
    }

    func physicalMemory() -> UInt64 { 18 * 1024 * 1024 * 1024 }
    var pressureLevel = 1
    func memoryPressureLevel() -> Int? { pressureLevel }

    func swapUsage() -> SwapUsage? {
        lock.withLock { _swapReads += 1 }
        return SwapUsage(totalBytes: 2 * 1024 * 1024 * 1024, usedBytes: 512 * 1024 * 1024)
    }

    func loadAverage() -> LoadAverage? { LoadAverage(one: 2.31, five: 1.84, fifteen: 1.52) }
    func bootTime() -> Date? { Date().addingTimeInterval(-(3 * 86400 + 4 * 3600)) }
    func thermalState() -> ProcessInfo.ThermalState { .nominal }
}

extension MDMStatus {
    func with(detail: String?) -> MDMStatus {
        var copy = self
        copy.enrollmentDetail = detail
        return copy
    }
}

final class FakeSystemInfoReader: SystemInfoReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _reads = 0
    var reads: Int { lock.withLock { _reads } }

    func systemInfo() -> SystemInfo {
        lock.withLock { _reads += 1 }
        return SystemInfo(
            osVersion: "macOS 15.7.7 (24G720)",
            model: "Mac15,6",
            chip: "Apple M3 Pro",
            memoryBytes: 18 * 1024 * 1024 * 1024,
            serialNumber: "C02TEST0000",
            computerName: "Test MacBook Pro"
        )
    }

    func mdmStatus() -> MDMStatus? {
        MDMStatus(isEnrolled: true, enrolledViaDEP: false, enrollmentDetail: "Yes (User Approved)", serverHost: "mdm.example.com")
    }
}
