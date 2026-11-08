import AppKit
import SwiftUI
import XCTest
@testable import DuoBar

@MainActor
final class BluetoothModuleTests: XCTestCase {
    func testDeviceSymbols() {
        XCTAssertEqual(BluetoothDeviceKind.symbol(major: 4, minor: 1, name: "Hugo – AirPods Pro C"), "airpodspro")
        XCTAssertEqual(BluetoothDeviceKind.symbol(major: 4, minor: 1, name: "Hugo – AirPods"), "airpods")
        XCTAssertEqual(BluetoothDeviceKind.symbol(major: 4, minor: 6, name: "WH-1000XM5"), "headphones")
        XCTAssertEqual(BluetoothDeviceKind.symbol(major: 5, minor: 0x10, name: "Magic Keyboard"), "keyboard")
        XCTAssertEqual(BluetoothDeviceKind.symbol(major: 5, minor: 0x20, name: "MX Master 3"), "computermouse")
        XCTAssertEqual(BluetoothDeviceKind.symbol(major: 1, minor: 0, name: "hugos iPad"), "ipad")
        XCTAssertEqual(BluetoothDeviceKind.normalizedAddress("02:00:00:00:00:04"), "02-00-00-00-00-04")
    }

    func testBatteryTint() {
        XCTAssertNil(BluetoothStatusRow.batteryTint(70))
        XCTAssertNil(BluetoothStatusRow.batteryTint(21))
        XCTAssertNotNil(BluetoothStatusRow.batteryTint(20))
        XCTAssertNotNil(BluetoothStatusRow.batteryTint(5))
        XCTAssertNotEqual(BluetoothStatusRow.batteryTint(20), BluetoothStatusRow.batteryTint(5))
    }

    func testConnectedFirstThenByName() {
        let sorted = BluetoothDeviceKind.sorted([
            device("b", name: "Zeta"), device("a", name: "alpha"), device("c", name: "Magic Keyboard", connected: true),
        ])
        XCTAssertEqual(sorted.map(\.name), ["Magic Keyboard", "alpha", "Zeta"])
    }

    func testShortNames() {
        XCTAssertEqual(BluetoothRowText.shortName("AirPods 4 (ANC)"), "AirPods")
        XCTAssertEqual(BluetoothRowText.shortName("Hugo – AirPods Pro C"), "AirPods Pro")
        XCTAssertEqual(BluetoothRowText.shortName("hugo’s Magic Keyboard"), localized("Keyboard"))
        XCTAssertEqual(BluetoothRowText.shortName("Anna's WH-1000XM3"), "WH-1000XM3")
        XCTAssertEqual(BluetoothRowText.shortName("MX Master 3S M"), "MX Master 3S M")
        XCTAssertEqual(BluetoothRowText.shortName("Very Long Bluetooth Speaker Name"), "Very Long")
        XCTAssertEqual(BluetoothRowText.shortName("Averyveryverylongsinglename"), "Averyveryveryl")
    }

    func testRowSummaryPutsBatteryNextToEachName() {
        var airPods = device("a", name: "AirPods 4 (ANC)", connected: true)
        airPods.earbuds = EarbudBattery(left: 100, right: 90, chargingCase: 5)
        var keyboard = device("b", name: "hugo’s Magic Keyboard", connected: true)
        keyboard.batteryPercent = 69
        let mouse = device("c", name: "MX Master 3", connected: true)

        let percent = { (value: Int) in localized("%d%%", value) }
        XCTAssertEqual(BluetoothRowText.summary([airPods, keyboard]), "AirPods \(percent(90)) · \(localized("Keyboard")) \(percent(69))")
        XCTAssertEqual(BluetoothRowText.summary([mouse]), "MX Master 3", "no battery reported")
        XCTAssertEqual(BluetoothRowText.summary([airPods, keyboard, mouse]), "AirPods \(percent(90)) · \(localized("Keyboard")) \(percent(69)) · +1")
        XCTAssertNil(BluetoothRowText.summary([]))
    }

    func testParsesAudioBatteryLevels() throws {
        let json = #"""
        {"SPBluetoothDataType":[{
          "device_connected":[
            {"Hugo – AirPods":{"device_address":"AA:BB:CC:DD:EE:01","device_batteryLevelLeft":"100\u00a0%","device_batteryLevelRight":"87 %","device_batteryLevelCase":"40%"}},
            {"Headset":{"device_address":"AA:BB:CC:DD:EE:02","device_batteryLevelMain":"55 %"}},
            {"Keyboard":{"device_address":"AA:BB:CC:DD:EE:03"}}
          ],
          "device_not_connected":[{"Old":{"device_address":"AA:BB:CC:DD:EE:04","device_batteryLevelMain":"10 %"}}]
        }]}
        """#
        let levels = AudioDeviceBattery.parseAll(Data(json.utf8))
        XCTAssertEqual(levels["aa-bb-cc-dd-ee-01"]?.earbuds, EarbudBattery(left: 100, right: 87, chargingCase: 40))
        XCTAssertEqual(levels["aa-bb-cc-dd-ee-02"]?.main, 55)
        XCTAssertNil(levels["aa-bb-cc-dd-ee-03"])
        XCTAssertNil(levels["aa-bb-cc-dd-ee-04"], "only connected devices")
        XCTAssertTrue(AudioDeviceBattery.parseAll(Data("nope".utf8)).isEmpty)
        XCTAssertEqual(EarbudBattery(left: 90, right: 30, chargingCase: 5).lowestBud, 30, "the case does not count")
    }

    func testAudioProcessRunsOnlyWithAConnectedAudioDevice() {
        let reader = FakeBluetoothReader()
        let module = BluetoothModule(reader: reader, observesSystemNotifications: false)
        module.popoverDidOpen()
        waitUntil { module.hasLoaded }
        XCTAssertEqual(reader.audioReads, 0, "the fake's connected device is a keyboard")
        module.popoverDidClose()
    }

    func testEarbudLevelsReachTheDevice() {
        let reader = FakeBluetoothReader()
        reader.connectsAirPods = true
        reader.audio = ["02-00-00-00-00-03": AudioDeviceBattery(earbuds: EarbudBattery(left: 80, right: 15, chargingCase: nil), main: nil)]
        let module = BluetoothModule(reader: reader, observesSystemNotifications: false)
        module.popoverDidOpen()
        waitUntil { module.hasLoaded }
        let airPods = module.devices.first { $0.name == "AirPods" }
        XCTAssertEqual(airPods?.earbuds?.right, 15)
        XCTAssertEqual(airPods?.lowestBattery, 15)
        module.popoverDidClose()
    }

    func testAccessMissingOnlyWhenTheListIsEmptyAndAccessIsDenied() {
        let denied = FakeBluetoothReader()
        denied.listIsEmpty = true
        denied.hasAccess = false
        let module = BluetoothModule(reader: denied, observesSystemNotifications: false)
        module.popoverDidOpen()
        waitUntil { module.hasLoaded }
        XCTAssertTrue(module.isAccessMissing)
        module.popoverDidClose()

        let nothingPaired = FakeBluetoothReader()
        nothingPaired.listIsEmpty = true
        let allowed = BluetoothModule(reader: nothingPaired, observesSystemNotifications: false)
        allowed.popoverDidOpen()
        waitUntil { allowed.hasLoaded }
        XCTAssertFalse(allowed.isAccessMissing, "nothing paired is not a permission problem")
        allowed.popoverDidClose()

        let listed = FakeBluetoothReader()
        listed.hasAccess = false
        let withDevices = BluetoothModule(reader: listed, observesSystemNotifications: false)
        withDevices.popoverDidOpen()
        waitUntil { withDevices.hasLoaded }
        XCTAssertFalse(withDevices.isAccessMissing, "a filled list always wins")
        withDevices.popoverDidClose()
    }

    func testReadsOnlyWhilePopoverIsOpenAndMergesBattery() {
        let reader = FakeBluetoothReader()
        let module = BluetoothModule(reader: reader, observesSystemNotifications: false)
        module.activate()
        module.refresh()
        spin(0.05)
        XCTAssertEqual(reader.listReads, 0)

        module.popoverDidOpen()
        waitUntil { module.hasLoaded }
        XCTAssertEqual(module.connectedDevices.map(\.name), ["Magic Keyboard"])
        XCTAssertEqual(module.connectedDevices.first?.batteryPercent, 70)
        XCTAssertNil(module.devices.first { $0.name == "AirPods" }?.batteryPercent, "battery only for connected devices")

        module.popoverDidClose()
        let reads = reader.listReads
        module.refresh()
        spin(0.05)
        XCTAssertEqual(reader.listReads, reads)
    }

    func testToggleConnectionAndFailureMessage() {
        let reader = FakeBluetoothReader()
        let module = BluetoothModule(reader: reader, observesSystemNotifications: false)
        module.popoverDidOpen()
        waitUntil { module.hasLoaded }

        let airPods = module.devices.first { $0.name == "AirPods" }!
        module.toggleConnection(airPods)
        XCTAssertTrue(module.busyAddresses.contains(airPods.address))
        waitUntil { module.busyAddresses.isEmpty && module.devices.first { $0.name == "AirPods" }?.isConnected == true }
        XCTAssertEqual(reader.connected, [airPods.address])
        XCTAssertNil(module.errorMessage)

        reader.failNext = true
        let keyboard = module.devices.first { $0.name == "Magic Keyboard" }!
        module.toggleConnection(keyboard)
        waitUntil { module.errorMessage != nil }
        module.popoverDidClose()
        XCTAssertNil(module.errorMessage)
    }

    func testRenderBluetoothAccessMissing() throws {
        let store = SystemStatusStore(
            startServices: false,
            deviceContext: DeviceContext(hasInternalBattery: true),
            moduleDefaults: UserDefaults(suiteName: "BluetoothModuleTests.\(UUID().uuidString)")!
        )
        let reader = FakeBluetoothReader()
        reader.listIsEmpty = true
        reader.hasAccess = false
        let module = BluetoothModule(reader: reader, observesSystemNotifications: false)
        module.popoverDidOpen()
        waitUntil { module.hasLoaded }
        let view = VStack(spacing: 6) {
            BluetoothStatusRow(statusStore: store, module: module, onActivate: {})
            BluetoothDetailView(statusStore: store, module: module, onOpenSettings: {})
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
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-Bluetooth-NoAccess.png"), options: .atomic)
        module.popoverDidClose()
    }

    func testRenderBluetoothDetail() throws {
        let store = SystemStatusStore(
            startServices: false,
            deviceContext: DeviceContext(hasInternalBattery: true),
            moduleDefaults: UserDefaults(suiteName: "BluetoothModuleTests.\(UUID().uuidString)")!
        )
        store.applyDebugNetworkState(.strong)
        let reader = FakeBluetoothReader()
        reader.connectsAirPods = true
        reader.audio = ["02-00-00-00-00-03": AudioDeviceBattery(earbuds: EarbudBattery(left: 100, right: 15, chargingCase: 62), main: nil)]
        let module = BluetoothModule(reader: reader, observesSystemNotifications: false)
        module.popoverDidOpen()
        waitUntil { module.hasLoaded }
        let view = VStack(spacing: 6) {
            BluetoothStatusRow(statusStore: store, module: module, onActivate: {})
            BluetoothDetailView(statusStore: store, module: module, onOpenSettings: {})
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
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-Detail-bluetooth.png"), options: .atomic)
        module.popoverDidClose()
    }

    private func device(_ address: String, name: String, connected: Bool = false) -> BluetoothDeviceInfo {
        BluetoothDeviceInfo(address: address, name: name, isConnected: connected, majorClass: 5, minorClass: 0x10, batteryPercent: nil)
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

final class FakeBluetoothReader: BluetoothDeviceReading, @unchecked Sendable {
    var hasAccess = true
    var connectsAirPods = false
    var audio: [String: AudioDeviceBattery] = [:]
    private(set) var audioReads = 0
    func audioBatteryLevels() -> [String: AudioDeviceBattery] { audioReads += 1; return audio }
    var listIsEmpty = false
    func hasBluetoothAccess() -> Bool { hasAccess }
    private let lock = NSLock()
    private var _connected: Set<String> = ["02-00-00-00-00-04"]
    private var _listReads = 0
    private var _failNext = false

    var connected: Set<String> { lock.withLock { _connected.subtracting(["02-00-00-00-00-04"]) } }
    var listReads: Int { lock.withLock { _listReads } }
    var failNext: Bool {
        get { lock.withLock { _failNext } }
        set { lock.withLock { _failNext = newValue } }
    }

    func pairedDevices() -> [BluetoothDeviceInfo] {
        lock.withLock {
            _listReads += 1
            if listIsEmpty { return [] }
            return [
                BluetoothDeviceInfo(address: "02-00-00-00-00-04", name: "Magic Keyboard", isConnected: _connected.contains("02-00-00-00-00-04"), majorClass: 5, minorClass: 0x10, batteryPercent: nil),
                BluetoothDeviceInfo(address: "02-00-00-00-00-03", name: "AirPods", isConnected: connectsAirPods || _connected.contains("02-00-00-00-00-03"), majorClass: 4, minorClass: 1, batteryPercent: nil),
                BluetoothDeviceInfo(address: "02-00-00-00-00-05", name: "MX Master 3", isConnected: false, majorClass: 5, minorClass: 0x20, batteryPercent: nil),
            ]
        }
    }

    func batteryLevels() -> [String: Int] { ["02-00-00-00-00-04": 70, "02-00-00-00-00-03": 40] }

    func connect(_ address: String) throws {
        try lock.withLock {
            if _failNext { _failNext = false; throw BluetoothActionError.failed(-1) }
            _connected.insert(address)
        }
    }

    func disconnect(_ address: String) throws {
        try lock.withLock {
            if _failNext { _failNext = false; throw BluetoothActionError.failed(-1) }
            _connected.remove(address)
        }
    }
}
