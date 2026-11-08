import Foundation

struct DeviceContext: Equatable, Sendable {
    enum RingBehavior: String, Sendable {
        case batteryRing
        case adaptiveRing
    }

    let hasInternalBattery: Bool

    var ringBehavior: RingBehavior {
        hasInternalBattery ? .batteryRing : .adaptiveRing
    }
}
