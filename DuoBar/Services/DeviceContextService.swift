import Foundation
import IOKit.ps

struct DeviceContextService {
    func current() -> DeviceContext {
        DeviceContext(hasInternalBattery: detectsInternalBattery())
    }

    #if DEBUG
    func current(simulateDesktop: Bool) -> DeviceContext {
        simulateDesktop ? DeviceContext(hasInternalBattery: false) : current()
    }
    #endif

    private func detectsInternalBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return false }

        return sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue()
                as? [String: Any]
            else { return false }
            return description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
        }
    }
}
