import SwiftUI

struct BatteryDetailView: View {
    @ObservedObject var statusStore: SystemStatusStore
    let module: BatteryModule?
    let onOpenSettings: () -> Void

    var body: some View {
        let battery = statusStore.status.battery
        let row = BatteryStatusRow(
            battery: battery,
            showPercentage: true,
            timeEstimate: statusStore.batteryTimeEstimate
        )

        if let percentage = battery.percentage {
            DetailValueRow(label: localized("Level"), value: localized("%d%%", percentage))
        }

        DetailValueRow(label: localized("Status"), value: row.detail)

        if statusStore.batteryTimeEstimate != .unavailable, let time = row.secondaryDetail {
            DetailValueRow(label: localized("Time"), value: time)
        }

        DetailValueRow(
            label: localized("Power Source"),
            value: battery.isPluggedIn ? localized("Power Adapter") : localized("Battery")
        )

        if let module {
            BatteryHealthRows(module: module, isPluggedIn: battery.isPluggedIn)
        }

        DetailValueRow(
            label: localized("Low Power Mode"),
            value: battery.isLowPowerModeEnabled ? localized("On") : localized("Off")
        )

        DetailActionRow(title: localized("Open Battery Settings"), action: onOpenSettings)
    }
}

private struct BatteryHealthRows: View {
    @ObservedObject var module: BatteryModule
    let isPluggedIn: Bool

    var body: some View {
        if isPluggedIn, let watts = module.adapter?.watts, watts > 0 {
            DetailValueRow(label: localized("Charger"), value: localized("%d W", watts))
        }
        if let health = module.health {
            if let percent = health.maximumCapacityPercent {
                DetailValueRow(label: localized("Maximum Capacity"), value: localized("%d%%", percent))
            }
            if let cycles = health.cycleCount {
                DetailValueRow(label: localized("Cycle Count"), value: "\(cycles)")
            }
        }
    }
}
