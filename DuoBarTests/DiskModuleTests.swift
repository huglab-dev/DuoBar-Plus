import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class DiskModuleTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var center: NotificationCenter!

    override func setUp() {
        super.setUp()
        suiteName = "DiskModuleTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        center = NotificationCenter()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        center = nil
        super.tearDown()
    }

    static let startup = VolumeInfo(
        path: "/", name: "Macintosh HD", totalBytes: 1_000_000_000_000, availableBytes: 230_000_000_000,
        isStartup: true, isInternal: true, isEjectable: false, isNetwork: false
    )
    static let usb = VolumeInfo(
        path: "/Volumes/Backup", name: "Backup", totalBytes: 2_000_000_000_000, availableBytes: 1_500_000_000_000,
        isStartup: false, isInternal: false, isEjectable: true, isNetwork: false
    )
    static let share = VolumeInfo(
        path: "/Volumes/Share", name: "Share", totalBytes: 4_000_000_000_000, availableBytes: 0,
        isStartup: false, isInternal: false, isEjectable: true, isNetwork: true
    )
    static let data = VolumeInfo(
        path: "/Volumes/Data", name: "Data", totalBytes: 500_000_000_000, availableBytes: 100_000_000_000,
        isStartup: false, isInternal: true, isEjectable: false, isNetwork: false
    )

    private func makeModule(_ reader: FakeDiskReader) -> DiskModule {
        DiskModule(reader: reader, defaults: defaults, notificationCenter: center)
    }

    func testUsedFractionAndExternalClassification() {
        XCTAssertEqual(Self.startup.usedBytes, 770_000_000_000)
        XCTAssertEqual(Self.startup.usedFraction ?? 0, 0.77, accuracy: 0.0001)
        XCTAssertFalse(Self.startup.isExternal)
        XCTAssertFalse(Self.data.isExternal)
        XCTAssertTrue(Self.usb.isExternal)
        XCTAssertTrue(Self.share.isExternal)
        let empty = VolumeInfo(path: "/x", name: "x", totalBytes: 0, availableBytes: 0, isStartup: false, isInternal: true, isEjectable: false, isNetwork: false)
        XCTAssertNil(empty.usedFraction)
    }

    func testSortingPutsStartupThenInternalThenExternalThenNetwork() {
        let sorted = DiskVolumeList.sorted([Self.share, Self.usb, Self.data, Self.startup])
        XCTAssertEqual(sorted.map(\.name), ["Macintosh HD", "Data", "Backup", "Share"])
    }

    func testExternalOptionFiltersVolumes() {
        let all = [Self.startup, Self.data, Self.usb, Self.share]
        XCTAssertEqual(DiskVolumeList.filtered(all, includeExternal: false).map(\.name), ["Macintosh HD", "Data"])
        XCTAssertEqual(DiskVolumeList.filtered(all, includeExternal: true).count, 4)
    }

    func testNothingIsReadUntilThePopoverOpens() {
        let reader = FakeDiskReader(startup: Self.startup, volumes: [Self.startup])
        let module = makeModule(reader)
        module.activate()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(reader.startupReads, 0)
        XCTAssertEqual(reader.volumeReads, 0)
        XCTAssertFalse(module.isObservingMounts)
    }

    func testPopoverOpenReadsVolumesOnceWithoutObservingMounts() {
        let reader = FakeDiskReader(startup: Self.startup, volumes: [Self.startup, Self.usb])
        let module = makeModule(reader)

        module.popoverDidOpen()
        waitUntil { module.startupVolume == Self.startup && module.volumes.count == 2 }

        XCTAssertEqual(reader.startupReads, 1)
        XCTAssertEqual(reader.volumeReads, 1)
        XCTAssertFalse(module.isObservingMounts)
        XCTAssertFalse(module.hasLoadedVolumes, "only the detail view marks the list as loaded")
    }

    func testRowSummaryAddsExternalDrivesOnlyWhenPresent() {
        let free = localized("%@ free", DiskText.bytes(Self.startup.availableBytes))
        XCTAssertEqual(DiskText.summary(Self.startup, externalCount: 0), free)
        XCTAssertEqual(DiskText.summary(Self.startup, externalCount: 1), "\(free) · \(localized("%d external", 1))")
        XCTAssertEqual(DiskText.summary(Self.startup, externalCount: 2), "\(free) · \(localized("%d external", 2))")
    }

    func testExternalCountSkipsNetworkAndInternalVolumes() {
        let reader = FakeDiskReader(startup: Self.startup, volumes: [Self.startup, Self.data, Self.usb, Self.share])
        let module = makeModule(reader)
        module.popoverDidOpen()
        waitUntil { module.volumes.count == 4 }
        XCTAssertEqual(module.connectedExternalCount, 1)
    }

    func testExternalCountHonorsTheOption() {
        defaults.set(false, forKey: ModuleOption.externalVolumes.key)
        let reader = FakeDiskReader(startup: Self.startup, volumes: [Self.startup, Self.usb])
        let module = makeModule(reader)
        module.popoverDidOpen()
        waitUntil { module.volumes.count == 2 }
        XCTAssertEqual(module.connectedExternalCount, 0)
    }

    func testDetailReadsVolumesAndFollowsMountsUntilClosed() {
        let reader = FakeDiskReader(startup: Self.startup, volumes: [Self.startup])
        let module = makeModule(reader)
        module.popoverDidOpen()
        module.detailDidOpen()
        waitUntil { module.hasLoadedVolumes }
        XCTAssertTrue(module.isObservingMounts)
        XCTAssertEqual(module.volumes, [Self.startup])

        reader.volumes = [Self.startup, Self.usb]
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        waitUntil { module.volumes.count == 2 }

        module.detailDidClose()
        XCTAssertFalse(module.isObservingMounts)
        let readsAfterClose = reader.volumeReads
        center.post(name: NSWorkspace.didUnmountNotification, object: nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(reader.volumeReads, readsAfterClose)
    }

    func testDeactivateStopsMountObservation() {
        let module = makeModule(FakeDiskReader(startup: Self.startup, volumes: [Self.startup]))
        module.popoverDidOpen()
        module.detailDidOpen()

        module.deactivate()

        XCTAssertFalse(module.isObservingMounts)
    }

    func testRealStartupVolumeHasCapacity() throws {
        let volume = try XCTUnwrap(DiskReader().startupVolume())
        XCTAssertTrue(volume.isStartup)
        XCTAssertGreaterThan(volume.totalBytes, 0)
        XCTAssertGreaterThan(volume.availableBytes, 0)
        XCTAssertLessThanOrEqual(volume.availableBytes, volume.totalBytes)
    }

    func testRealMountedVolumesStartWithStartupVolume() {
        let volumes = DiskReader().mountedVolumes()
        XCTAssertEqual(volumes.first?.isStartup, true)
        XCTAssertFalse(volumes.contains { $0.path.hasPrefix("/System/Volumes/") }, "hidden APFS volumes must be skipped")
    }

    func testOnlyExternalAndRemovableVolumesCanBeUnmounted() {
        XCTAssertFalse(Self.startup.canUnmount)
        XCTAssertFalse(Self.data.canUnmount, "a fixed internal volume")
        XCTAssertTrue(Self.usb.canUnmount)
        XCTAssertTrue(Self.share.canUnmount)
    }

    func testUnmountRefreshesAndGuardsAgainstRepeats() {
        let reader = FakeDiskReader(startup: Self.startup, volumes: [Self.startup, Self.usb])
        let actions = FakeVolumeActions()
        actions.holdsCompletion = true
        let module = DiskModule(reader: reader, actions: actions, defaults: defaults, notificationCenter: center)
        module.popoverDidOpen()
        module.detailDidOpen()
        waitUntil { module.hasLoadedVolumes }

        module.unmount(Self.usb)
        module.unmount(Self.usb)
        module.unmount(Self.startup)
        XCTAssertEqual(actions.unmounted, [Self.usb.path], "once, and never the startup volume")
        XCTAssertTrue(module.unmountingPaths.contains(Self.usb.path))

        reader.volumes = [Self.startup]
        actions.finish()
        waitUntil { module.volumes.count == 1 }
        XCTAssertTrue(module.unmountingPaths.isEmpty)
        XCTAssertNil(module.errorMessage)
        module.detailDidClose()
        module.popoverDidClose()
    }

    func testUnmountFailureIsReportedAndClearedOnClose() {
        let reader = FakeDiskReader(startup: Self.startup, volumes: [Self.startup, Self.usb])
        let actions = FakeVolumeActions()
        actions.error = NSError(domain: "test", code: 1)
        let module = DiskModule(reader: reader, actions: actions, defaults: defaults, notificationCenter: center)
        module.popoverDidOpen()
        module.detailDidOpen()
        waitUntil { module.hasLoadedVolumes }
        module.unmount(Self.usb)
        waitUntil { module.errorMessage != nil }
        XCTAssertEqual(module.errorMessage, localized("Could not unmount %@. A file on it may be in use.", "Backup"))
        module.detailDidClose()
        XCTAssertNil(module.errorMessage)
        module.popoverDidClose()
    }

    func testOpenInFinderUsesTheVolumePath() {
        let actions = FakeVolumeActions()
        let module = DiskModule(reader: FakeDiskReader(startup: Self.startup, volumes: []), actions: actions, defaults: defaults, notificationCenter: center)
        module.openInFinder(Self.usb)
        XCTAssertEqual(actions.opened, [Self.usb.path])
    }

    func testRenderDiskDetail() throws {
        let reader = FakeDiskReader(startup: Self.startup, volumes: [Self.startup, Self.usb, Self.share])
        let module = makeModule(reader)
        module.popoverDidOpen()
        module.detailDidOpen()
        waitUntil { module.hasLoadedVolumes }

        let view = VStack(spacing: 6) {
            DiskStatusRow(module: module, onActivate: {})
            DiskDetailView(module: module, onOpenSettings: {})
        }
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
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-Detail-disk.png"), options: .atomic)
        XCTAssertGreaterThan(png.count, 1_000)
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTAssertTrue(condition(), "condition not met within \(timeout) s", file: file, line: line)
    }
}

final class FakeVolumeActions: VolumeActing, @unchecked Sendable {
    var error: Error?
    private(set) var unmounted: [String] = []
    private(set) var opened: [String] = []
    private var pending: (@Sendable (Error?) -> Void)?
    var holdsCompletion = false

    func unmount(path: String, completion: @escaping @Sendable (Error?) -> Void) {
        unmounted.append(path)
        if holdsCompletion { pending = completion } else { completion(error) }
    }

    func finish() { pending?(error); pending = nil }
    func openInFinder(path: String) { opened.append(path) }
}

final class FakeDiskReader: DiskReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _startup: VolumeInfo?
    private var _volumes: [VolumeInfo]
    private var _startupReads = 0
    private var _volumeReads = 0

    init(startup: VolumeInfo?, volumes: [VolumeInfo]) {
        _startup = startup
        _volumes = volumes
    }

    var volumes: [VolumeInfo] {
        get { lock.withLock { _volumes } }
        set { lock.withLock { _volumes = newValue } }
    }

    var startupReads: Int { lock.withLock { _startupReads } }
    var volumeReads: Int { lock.withLock { _volumeReads } }

    func startupVolume() -> VolumeInfo? {
        lock.withLock {
            _startupReads += 1
            return _startup
        }
    }

    func mountedVolumes() -> [VolumeInfo] {
        lock.withLock {
            _volumeReads += 1
            return _volumes
        }
    }
}
