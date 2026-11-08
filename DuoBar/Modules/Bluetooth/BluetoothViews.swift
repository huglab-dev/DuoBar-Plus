import SwiftUI

/// Main-view row: the connected devices, e.g. "AirPods 100% · Keyboard 69%".
struct BluetoothStatusRow: View {
    @ObservedObject var statusStore: SystemStatusStore
    @ObservedObject var module: BluetoothModule
    let onActivate: () -> Void

    var body: some View {
        StatusRow(
            symbol: IconTile.bluetoothSymbol,
            title: localized("Bluetooth"),
            detail: detail,
            // Like the memory warning on the System row: only when it needs attention.
            speedText: lowBattery.map { localized("%d%%", $0) },
            speedTint: lowBattery.flatMap(Self.batteryTint),
            stateText: "",
            tint: .primary,
            accessory: .disclosure,
            onActivate: onActivate,
            activationHint: localized("Show details")
        )
    }

    private var detail: String {
        let bluetooth = statusStore.status.bluetooth
        if bluetooth.isAvailable, !bluetooth.isPoweredOn { return localized("Off") }
        guard module.hasLoaded else { return localized("Calculating…") }
        if module.isAccessMissing { return localized("Bluetooth access needed") }
        return BluetoothRowText.summary(module.connectedDevices) ?? localized("No devices connected")
    }

    /// The battery level among connected devices; the lowest when several
    /// report one, since that is the one that needs charging first.
    private var lowBattery: Int? {
        module.connectedDevices.compactMap(\.lowestBattery).min().flatMap { Self.batteryTint($0) == nil ? nil : $0 }
    }

    /// Orange from 20 %, red below 10 %, the macOS warning levels;
    /// otherwise the row's normal secondary color.
    static func batteryTint(_ percent: Int) -> Color? {
        if percent < 10 { return Color(nsColor: .systemRed) }
        if percent <= 20 { return Color(nsColor: .systemOrange) }
        return nil
    }
}

/// Short device names and the one-line summary for the main row.
enum BluetoothRowText {
    /// How many devices fit on the line; the rest become "+2".
    static let maximumShown = 2
    private static let maximumNameLength = 14

    /// "Hugo – AirPods Pro C" → "AirPods Pro", "hugo's Magic Keyboard" → "Keyboard".
    static func shortName(_ name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpods max") { return "AirPods Max" }
        if lower.contains("airpods pro") { return "AirPods Pro" }
        if lower.contains("airpods") { return "AirPods" }
        if lower.contains("magic keyboard") { return localized("Keyboard") }
        if lower.contains("magic mouse") { return localized("Mouse") }
        if lower.contains("magic trackpad") { return localized("Trackpad") }

        var short = name
        for separator in [" – ", " — ", " - ", "’s ", "'s "] {
            if let range = short.range(of: separator, options: .backwards) {
                short = String(short[range.upperBound...])
            }
        }
        if let parenthesis = short.firstIndex(of: "("), parenthesis > short.startIndex {
            short = String(short[..<parenthesis])
        }
        short = short.trimmingCharacters(in: .whitespaces)
        guard short.count > maximumNameLength else { return short.isEmpty ? name : short }
        // Cut at a word when one ends in time, otherwise at the limit.
        let prefix = String(short.prefix(maximumNameLength))
        if let space = prefix.lastIndex(of: " "), space > prefix.startIndex {
            return String(prefix[..<space])
        }
        return prefix
    }

    /// "AirPods 100% · Keyboard 69%", or nil with nothing connected.
    static func summary(_ devices: [BluetoothDeviceInfo]) -> String? {
        guard !devices.isEmpty else { return nil }
        var parts = devices.prefix(maximumShown).map { device -> String in
            let name = shortName(device.name)
            return device.lowestBattery.map { "\(name) \(localized("%d%%", $0))" } ?? name
        }
        if devices.count > maximumShown { parts.append("+\(devices.count - maximumShown)") }
        return parts.joined(separator: " · ")
    }
}

struct BluetoothDetailView: View {
    @ObservedObject var statusStore: SystemStatusStore
    @ObservedObject var module: BluetoothModule
    let onOpenSettings: () -> Void
    var onOpenPrivacySettings: () -> Void = { SystemSettingsOpener.open(.bluetoothPrivacy) }

    var body: some View {
        let bluetooth = statusStore.status.bluetooth

        if bluetooth.isAvailable, !bluetooth.isPoweredOn {
            DetailValueRow(label: localized("Status"), value: localized("Off"))
            Text(localized("Turn Bluetooth on in Control Center."))
                .font(.system(size: 9.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
        } else if !module.hasLoaded {
            DetailValueRow(label: localized("Status"), value: localized("Calculating…"))
        } else if module.isAccessMissing {
            DetailMessageCard(text: localized("DuoBar+ doesn't have Bluetooth access, so it can't list your devices. Allow it in Privacy & Security, then reopen DuoBar+."))
            DetailActionRow(title: localized("Open Privacy Settings"), action: onOpenPrivacySettings)
        } else {
            let connected = module.devices.filter(\.isConnected)
            let paired = module.devices.filter { !$0.isConnected }

            DetailSectionHeader(title: localized("Connected"))
            if connected.isEmpty {
                DetailValueRow(label: localized("No devices connected"), value: "")
            }
            ForEach(connected) { device in
                BluetoothDeviceRow(device: device, isBusy: module.busyAddresses.contains(device.address)) {
                    module.toggleConnection(device)
                }
            }

            if !paired.isEmpty {
                DetailSectionHeader(title: localized("Other Devices"))
                ForEach(paired) { device in
                    BluetoothDeviceRow(device: device, isBusy: module.busyAddresses.contains(device.address)) {
                        module.toggleConnection(device)
                    }
                }
            }

            if let error = module.errorMessage {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        }

        DetailActionRow(title: localized("Open Bluetooth Settings"), action: onOpenSettings)
        Text(localized("To use this instead of the system Bluetooth icon, hide it in System Settings → Control Center."))
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
    }
}

struct BluetoothDeviceRow: View {
    let device: BluetoothDeviceInfo
    let isBusy: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: device.symbol)
                .font(.system(size: 13))
                .frame(width: 22)
                .foregroundStyle(device.isConnected ? .primary : .secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(device.isConnected ? .primary : .secondary)
                if let earbuds = device.earbuds {
                    EarbudLevels(earbuds: earbuds, isPro: device.name.lowercased().contains("pro"))
                }
            }
            Spacer(minLength: 6)
            if device.earbuds == nil, let battery = device.batteryPercent {
                Text(localized("%d%%", battery))
                    .foregroundStyle(BluetoothStatusRow.batteryTint(battery).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
                    .monospacedDigit()
            }
            if isBusy {
                ProgressView().controlSize(.mini)
            } else {
                Button(device.isConnected ? localized("Disconnect") : localized("Connect"), action: onToggle)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
            }
        }
        .font(PopoverDesign.detailLabelFont)
        .padding(.horizontal, PopoverDesign.horizontalPadding)
        .frame(height: device.earbuds == nil ? PopoverDesign.valueRowHeight : PopoverDesign.valueRowHeight + 12)
        .popoverCardBackground(cornerRadius: 11, fillOpacity: 0.045)
        .accessibilityElement(children: .combine)
    }
}

/// Left, right and case levels, as in the system Bluetooth menu.
struct EarbudLevels: View {
    let earbuds: EarbudBattery
    let isPro: Bool

    var body: some View {
        HStack(spacing: 9) {
            if let left = earbuds.left {
                level(left, symbol: isPro ? "airpodpro.left" : "airpod.left", fallback: "L", name: localized("Left"))
            }
            if let right = earbuds.right {
                level(right, symbol: isPro ? "airpodpro.right" : "airpod.right", fallback: "R", name: localized("Right"))
            }
            if let chargingCase = earbuds.chargingCase {
                level(chargingCase, symbol: isPro ? "airpodspro.chargingcase.wireless" : "airpods.chargingcase", fallback: "C", name: localized("Case"))
            }
        }
        .font(.system(size: 10.5))
        .monospacedDigit()
    }

    private func level(_ percent: Int, symbol: String, fallback: String, name: String) -> some View {
        HStack(spacing: 3) {
            if NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil {
                Image(systemName: symbol)
            } else {
                Text(fallback)
            }
            Text(localized("%d%%", percent))
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(BluetoothStatusRow.batteryTint(percent).map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) \(localized("%d%%", percent))")
    }
}
