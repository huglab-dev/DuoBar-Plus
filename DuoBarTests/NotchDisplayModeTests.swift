import XCTest
@testable import DuoBar

final class NotchDisplayModeTests: XCTestCase {
    /// The modes of a 14" MacBook Pro at "More Space", as listed on the dev machine.
    private static let modes: [DisplayModeInfo] = [
        mode(60, 1125, 120), mode(61, 1125, 60), mode(66, 1169, 120), mode(67, 1169, 60),
        DisplayModeInfo(id: 90, width: 1512, height: 945, pixelWidth: 3024, refreshRate: 120, isUsable: true),
        DisplayModeInfo(id: 91, width: 1512, height: 982, pixelWidth: 3024, refreshRate: 120, isUsable: true),
    ]

    private static func mode(_ id: Int32, _ height: Int, _ hz: Double) -> DisplayModeInfo {
        DisplayModeInfo(id: id, width: 1800, height: height, pixelWidth: 3600, refreshRate: hz, isUsable: true)
    }

    private func current(_ id: Int32) -> DisplayModeInfo { Self.modes.first { $0.id == id }! }

    func testPicksTheSameFamily() {
        XCTAssertEqual(NotchDisplayMode.belowNotchMode(for: current(66), in: Self.modes)?.id, 60)
        XCTAssertEqual(NotchDisplayMode.fullMode(for: current(60), in: Self.modes)?.id, 66)
        XCTAssertEqual(NotchDisplayMode.belowNotchMode(for: current(67), in: Self.modes)?.id, 61, "60 Hz stays 60 Hz")
        XCTAssertEqual(NotchDisplayMode.belowNotchMode(for: current(91), in: Self.modes)?.id, 90, "another width keeps its own family")
        XCTAssertNil(NotchDisplayMode.belowNotchMode(for: current(66), in: [current(66), current(67)]))
    }

    func testToggleSwitchesBothWays() {
        let controller = FakeDisplayModes(current: current(66), all: Self.modes)
        let mode = NotchDisplayMode(controller: controller)
        XCTAssertTrue(mode.isAvailable)
        XCTAssertFalse(mode.isBelowNotch)
        XCTAssertTrue(mode.toggle())
        XCTAssertEqual(controller.set, [60])
        XCTAssertTrue(mode.isBelowNotch)
        XCTAssertTrue(mode.toggle())
        XCTAssertEqual(controller.set, [60, 66])
        XCTAssertTrue(mode.set(belowNotch: false), "already at full height")
        XCTAssertEqual(controller.set, [60, 66])
    }

    func testWithoutNotchNothingHappens() {
        let mode = NotchDisplayMode(controller: FakeDisplayModes(current: nil, all: []))
        XCTAssertFalse(mode.isAvailable)
        XCTAssertFalse(mode.toggle())
    }

    func testURLCommands() {
        XCTAssertEqual(DuoBarURLCommand(url: URL(string: "duobarplus://toggle-notch")!), .toggleNotch)
        XCTAssertEqual(DuoBarURLCommand(url: URL(string: "DuoBarPlus://notch-on")!), .belowNotch)
        XCTAssertEqual(DuoBarURLCommand(url: URL(string: "duobarplus://notch-off")!), .fullHeight)
        XCTAssertNil(DuoBarURLCommand(url: URL(string: "duobarplus://other")!))
        XCTAssertNil(DuoBarURLCommand(url: URL(string: "https://toggle-notch")!))
        XCTAssertEqual(DuoBarURLCommand(url: URL(string: "duobarplus://ip-profile?name=Office%20LAN")!), .ipProfile("Office LAN"))
        XCTAssertEqual(DuoBarURLCommand(url: URL(string: "duobarplus://ip-profile?name=dhcp")!), .ipProfile("dhcp"))
        XCTAssertNil(DuoBarURLCommand(url: URL(string: "duobarplus://ip-profile")!))
        XCTAssertNil(DuoBarURLCommand(url: URL(string: "duobarplus://ip-profile?name=%20")!))
    }
}

final class FakeDisplayModes: DisplayModeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var current: DisplayModeInfo?
    private let all: [DisplayModeInfo]
    private var _set: [Int32] = []

    init(current: DisplayModeInfo?, all: [DisplayModeInfo]) {
        self.current = current
        self.all = all
    }

    var set: [Int32] { lock.withLock { _set } }

    func modes() -> (current: DisplayModeInfo, all: [DisplayModeInfo])? {
        lock.withLock { current.map { ($0, all) } }
    }

    func setMode(id: Int32) -> Bool {
        lock.withLock {
            _set.append(id)
            current = all.first { $0.id == id }
        }
        return true
    }
}
