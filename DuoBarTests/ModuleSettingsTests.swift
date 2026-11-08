import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class ModuleSettingsTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ModuleSettingsTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsAllModulesOnAndRoamingLogOff() {
        ModuleDefaults.register(in: defaults)
        let model = ModuleSettingsModel(defaults: defaults, hasInternalBattery: true)

        for id in ModuleID.allCases where id != .aiUsage {
            XCTAssertTrue(model.isEnabled(id), "\(id) should default to on")
        }
        XCTAssertFalse(model.isEnabled(.aiUsage), "AI Usage is opt-in")
        XCTAssertFalse(model.isEnabled(.roamingLog))
        XCTAssertTrue(model.isEnabled(.nearbyNetworks))
    }

    func testListsOnlyImplementedModulesAndOptions() {
        let model = ModuleSettingsModel(defaults: defaults, hasInternalBattery: true)

        XCTAssertEqual(model.modules, ModuleID.allCases.filter(\.isImplemented))
        XCTAssertTrue(model.options.allSatisfy { $0.isImplemented && $0.module.isImplemented })
    }

    func testStoreRegistersExactlyTheImplementedModules() {
        let modules = SystemStatusStore.makeModules(deviceContext: DeviceContext(hasInternalBattery: true))
        XCTAssertEqual(modules.map(\.id), ModuleID.allCases.filter(\.isImplemented))
    }

    func testBatteryUnsupportedWithoutInternalBattery() {
        let model = ModuleSettingsModel(defaults: defaults, hasInternalBattery: false)
        XCTAssertFalse(model.isSupported(.battery))
        XCTAssertTrue(model.isSupported(.network))
    }

    func testMoveKeepsUnimplementedModulesAtTheEnd() {
        let model = ModuleSettingsModel(defaults: defaults, hasInternalBattery: true)
        XCTAssertEqual(model.modules, [.network, .battery, .bluetooth, .system, .disk, .aiUsage])

        model.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)

        XCTAssertEqual(model.modules, [.disk, .network, .battery, .bluetooth, .system, .aiUsage])
        XCTAssertEqual(
            defaults.stringArray(forKey: PreferenceKeys.moduleOrder),
            ["disk", "network", "battery", "bluetooth", "system", "aiUsage"]
        )
    }

    func testTogglesWriteTheSharedKeys() {
        let model = ModuleSettingsModel(defaults: defaults, hasInternalBattery: true)

        model.setEnabled(false, for: .network)
        model.setEnabled(true, for: .roamingLog)

        XCTAssertEqual(defaults.object(forKey: PreferenceKeys.moduleEnabled(.network)) as? Bool, false)
        XCTAssertTrue(ModuleOption.roamingLog.isEnabled(in: defaults))
        XCTAssertFalse(model.isEnabled(.network))
    }

    func testMemoryPressureWarningOptionDefaultsOn() {
        XCTAssertTrue(ModuleOption.memoryPressureWarning.isEnabled(in: defaults))
        XCTAssertEqual(ModuleOption.memoryPressureWarning.module, .system)
        let model = ModuleSettingsModel(defaults: defaults, hasInternalBattery: true)
        XCTAssertTrue(model.options.contains(.memoryPressureWarning))
        model.setEnabled(false, for: .memoryPressureWarning)
        XCTAssertFalse(ModuleOption.memoryPressureWarning.isEnabled(in: defaults))
    }

    func testRegistryFollowsSettingsChangesWithoutBeingCalled() {
        let network = RecordingModule(.network)
        let battery = RecordingModule(.battery)
        let registry = ModuleRegistry(modules: [network, battery], defaults: defaults)
        let model = ModuleSettingsModel(defaults: defaults, hasInternalBattery: true)
        registry.popoverDidOpen()

        model.setEnabled(false, for: .network)
        model.move(fromOffsets: IndexSet(integer: 1), toOffset: 0)
        waitUntil { registry.visibleModules == [.battery] }

        XCTAssertEqual(network.events, [.activate, .popoverOpen, .popoverClose, .deactivate])

        model.setEnabled(true, for: .network)
        waitUntil { registry.visibleModules == [.battery, .network] }
        XCTAssertEqual(network.events.suffix(2), [.activate, .popoverOpen])
    }

    func testRegistryWithoutObservationIgnoresExternalChanges() {
        let registry = ModuleRegistry(modules: [RecordingModule(.network)], defaults: defaults, observesDefaults: false)
        defaults.set(false, forKey: PreferenceKeys.moduleEnabled(.network))
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(registry.visibleModules, [.network])
    }

    func testRenderModulesTab() throws {
        let view = ModuleSettingsView(hasInternalBattery: true)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .aqua)
        hostingView.frame = NSRect(x: 0, y: 0, width: 420, height: 380)
        let window = NSWindow(contentRect: hostingView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hostingView
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-Settings-Modules.png"), options: .atomic)
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
