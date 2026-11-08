import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class PopoverRouterTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "PopoverRouterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeRouter(_ modules: [RecordingModule]) -> (PopoverRouter, ModuleRegistry) {
        let registry = ModuleRegistry(modules: modules, defaults: defaults)
        return (PopoverRouter(registry: registry), registry)
    }

    func testOpenAndBackDriveDetailLifecycle() {
        let network = RecordingModule(.network)
        let (router, registry) = makeRouter([network])
        registry.popoverDidOpen()

        router.open(.network)
        XCTAssertEqual(router.route, .detail(.network))
        XCTAssertEqual(registry.openDetail, .network)

        router.back()
        XCTAssertEqual(router.route, .main)
        XCTAssertNil(registry.openDetail)
        XCTAssertEqual(network.events, [.activate, .popoverOpen, .detailOpen, .detailClose])
    }

    func testCannotOpenHiddenModule() {
        let (router, _) = makeRouter([RecordingModule(.battery, isSupported: false)])

        router.open(.battery)
        router.open(.disk)

        XCTAssertEqual(router.route, .main)
    }

    func testCancelGoesBackBeforeClosing() {
        let (router, registry) = makeRouter([RecordingModule(.network)])
        registry.popoverDidOpen()

        XCTAssertFalse(router.handleCancel())
        router.open(.network)
        XCTAssertTrue(router.handleCancel())
        XCTAssertEqual(router.route, .main)
        XCTAssertFalse(router.handleCancel())
    }

    func testClosingStopsDetailWorkButKeepsRouteUntilReopen() {
        let network = RecordingModule(.network)
        let (router, registry) = makeRouter([network])
        registry.popoverDidOpen()
        router.open(.network)

        router.popoverDidClose()
        registry.popoverDidClose()

        XCTAssertEqual(router.route, .detail(.network), "content must not change during the fade-out")
        XCTAssertEqual(network.events, [.activate, .popoverOpen, .detailOpen, .detailClose, .popoverClose])

        router.popoverWillOpen()
        XCTAssertEqual(router.route, .main)
        XCTAssertEqual(network.events.count, 5, "reopening must not repeat detailDidClose")
    }

    func testDisablingOpenModuleReturnsToMain() {
        let (router, registry) = makeRouter([RecordingModule(.network), RecordingModule(.battery)])
        registry.popoverDidOpen()
        router.open(.battery)

        registry.setEnabled(false, for: .battery)

        XCTAssertEqual(router.route, .main)
    }

    func testStoreClosesDetailWhenPopoverBecomesInactive() {
        let store = SystemStatusStore(
            startServices: false,
            deviceContext: DeviceContext(hasInternalBattery: true),
            moduleDefaults: defaults
        )
        store.setPopoverActive(true)
        store.popoverRouter.open(.battery)
        XCTAssertEqual(store.moduleRegistry.openDetail, .battery)

        store.setPopoverActive(false)

        XCTAssertNil(store.moduleRegistry.openDetail)
        XCTAssertFalse(store.moduleRegistry.isPopoverOpen)
    }

    func testDesktopMacHidesBatteryModule() {
        let store = SystemStatusStore(
            startServices: false,
            deviceContext: DeviceContext(hasInternalBattery: false),
            moduleDefaults: defaults
        )
        XCTAssertEqual(store.moduleRegistry.visibleModules, [.network, .bluetooth, .system, .disk])
    }

    func testCopyToPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PopoverRouterTests.\(UUID().uuidString)"))
        DetailValueRow.copyToPasteboard("en0", pasteboard: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "en0")
        pasteboard.releaseGlobally()
    }

    func testNetworkSignalTextOnlyForConnectedWiFi() {
        var network = NetworkStatus(
            isAvailable: true, isConnected: true, transport: .wifi, interfaceName: "en0",
            isWiFiPoweredOn: true, ssid: "Home", rssi: -58
        )
        XCTAssertEqual(NetworkStatusText.signal(for: network), localized("%d dBm", -58))
        network.transport = .ethernet
        XCTAssertNil(NetworkStatusText.signal(for: network))
    }

    func testRenderDetailViews() throws {
        let store = SystemStatusStore(
            startServices: false,
            deviceContext: DeviceContext(hasInternalBattery: true),
            moduleDefaults: defaults
        )
        store.applyDebugBatteryLevel(.full)
        store.applyDebugNetworkState(.strong)

        for id in [ModuleID.network, .battery] {
            store.popoverRouter.popoverWillOpen()
            store.popoverRouter.open(id)
            XCTAssertEqual(store.popoverRouter.route, .detail(id))

            let view = StatusPopoverView(statusStore: store, onClose: {})
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark)
            let size = try writePNG(view, named: "DuoBarPlus-Detail-\(id.rawValue).png")
            XCTAssertEqual(size.width, 304, accuracy: 0.5)
            XCTAssertLessThan(size.height, 900, "taller detail views scroll inside the panel")
        }
    }

    func testRenderMainView() throws {
        let store = SystemStatusStore(
            startServices: false,
            deviceContext: DeviceContext(hasInternalBattery: true),
            moduleDefaults: defaults
        )
        store.applyDebugBatteryLevel(.full)
        store.applyDebugNetworkState(.strong)
        store.applyDebugAudioDeviceState(.builtIn)
        store.applyDebugVolumeState(.fiftyOne)
        store.popoverRouter.popoverWillOpen()
        let view = StatusPopoverView(statusStore: store, onClose: {})
            .padding(20)
            .background(Color(red: 0.16, green: 0.12, blue: 0.22))
            .environment(\.colorScheme, .dark)
        try writePNG(view, named: "DuoBarPlus-Main.png")
    }

    @discardableResult
    private func writePNG<Content: View>(_ content: Content, named name: String) throws -> NSSize {
        PopoverPresentationState.shared.show()
        let hostingView = NSHostingView(rootView: content)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        // FittingScrollView measures its content in a second layout pass, as
        // the live panel does via onContentSizeChange.
        for _ in 0..<3 {
            hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
            hostingView.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(name), options: .atomic)
        XCTAssertGreaterThan(png.count, 1_000)
        return hostingView.fittingSize
    }
}
