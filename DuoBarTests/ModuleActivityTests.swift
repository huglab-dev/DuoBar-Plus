import XCTest
@testable import DuoBar

/// Step 10: no module keeps timers or observers once the popover closes.
@MainActor
final class ModuleActivityTests: XCTestCase {
    func testNothingRunsWithThePopoverClosed() {
        for hasBattery in [true, false] {
            let modules = SystemStatusStore.makeModules(deviceContext: DeviceContext(hasInternalBattery: hasBattery), live: false)
            for module in modules {
                module.activate()
                XCTAssertEqual(module.activeWork, [], "\(module.id) runs work before the popover opens")

                module.popoverDidOpen()
                module.detailDidOpen()
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
                let whileOpen = module.activeWork
                module.detailDidClose()
                module.popoverDidClose()
                XCTAssertEqual(module.activeWork, [], "\(module.id) keeps \(module.activeWork) after closing (open: \(whileOpen))")

                module.deactivate()
                XCTAssertEqual(module.activeWork, [], "\(module.id) keeps work after being switched off")
            }
        }
    }

    func testOpenModulesReportTheirWork() {
        let modules = SystemStatusStore.makeModules(deviceContext: DeviceContext(hasInternalBattery: true), live: false)
        let system = modules.first { $0.id == .system }!
        system.popoverDidOpen()
        XCTAssertTrue(system.activeWork.contains("sampling timer"))
        system.popoverDidClose()
        XCTAssertEqual(system.activeWork, [])
    }
}
