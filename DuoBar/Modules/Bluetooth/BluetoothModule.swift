import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit

struct BluetoothDeviceInfo: Equatable, Identifiable, Sendable {
    /// Lowercase, dash-separated, as IOBluetooth formats it.
    var address: String
    var name: String
    var isConnected: Bool
    var majorClass: UInt32
    var minorClass: UInt32
    var batteryPercent: Int?
    /// Separate levels for true wireless earbuds such as AirPods.
    var earbuds: EarbudBattery?

    var id: String { address }

    /// The level that needs attention first; the case does not count.
    var lowestBattery: Int? { earbuds?.lowestBud ?? batteryPercent }

    var symbol: String { BluetoothDeviceKind.symbol(major: majorClass, minor: minorClass, name: name) }
}

struct EarbudBattery: Equatable, Sendable {
    var left: Int?
    var right: Int?
    var chargingCase: Int?

    var lowestBud: Int? { [left, right].compactMap { $0 }.min() }
    var hasLevels: Bool { left != nil || right != nil || chargingCase != nil }
}

/// Battery levels of audio devices, from `system_profiler SPBluetoothDataType
/// -json`, the only public source for AirPods. Values look like "100 %".
struct AudioDeviceBattery: Equatable, Sendable {
    var earbuds: EarbudBattery?
    var main: Int?

    static func parseAll(_ data: Data) -> [String: AudioDeviceBattery] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var result: [String: AudioDeviceBattery] = [:]
        for section in sections {
            for entry in section["device_connected"] as? [[String: Any]] ?? [] {
                for case let info as [String: Any] in entry.values {
                    guard let address = info["device_address"] as? String else { continue }
                    let buds = EarbudBattery(
                        left: percent(info["device_batteryLevelLeft"]),
                        right: percent(info["device_batteryLevelRight"]),
                        chargingCase: percent(info["device_batteryLevelCase"])
                    )
                    let main = percent(info["device_batteryLevelMain"])
                    guard buds.hasLevels || main != nil else { continue }
                    result[BluetoothDeviceKind.normalizedAddress(address)] = AudioDeviceBattery(earbuds: buds.hasLevels ? buds : nil, main: main)
                }
            }
        }
        return result
    }

    static func percent(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        let digits = text.filter(\.isNumber)
        guard let number = Int(digits), (0...100).contains(number) else { return nil }
        return number
    }
}

enum BluetoothDeviceKind {
    /// SF Symbol from the Bluetooth class of device (and the name for Apple
    /// products that share a class).
    static func symbol(major: UInt32, minor: UInt32, name: String) -> String {
        let lower = name.lowercased()
        switch major {
        case 1: // Computer
            return lower.contains("ipad") ? "ipad" : "laptopcomputer"
        case 2: // Phone
            return "iphone"
        case 4: // Audio/Video
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case 5: // Peripheral: keyboard 0x10, pointing device 0x20 in the minor bits
            if minor & 0x10 != 0 { return "keyboard" }
            if minor & 0x20 != 0 { return lower.contains("trackpad") ? "rectangle.and.hand.point.up.left" : "computermouse" }
            return "gamecontroller"
        default:
            if lower.contains("ipad") { return "ipad" }
            return "dot.radiowaves.left.and.right"
        }
    }

    static func normalizedAddress(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    /// Connected first, then by name.
    static func sorted(_ devices: [BluetoothDeviceInfo]) -> [BluetoothDeviceInfo] {
        devices.sorted { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }
}

enum BluetoothActionError: Error, Equatable {
    case deviceNotFound
    case failed(Int32)
}

protocol BluetoothDeviceReading: Sendable {
    func pairedDevices() -> [BluetoothDeviceInfo]
    /// False when macOS has not given the app Bluetooth access. Never prompts.
    func hasBluetoothAccess() -> Bool
    /// Battery levels keyed by normalized address, from the IORegistry.
    func batteryLevels() -> [String: Int]
    /// Levels for connected audio devices. Runs a short process; call off the main thread.
    func audioBatteryLevels() -> [String: AudioDeviceBattery]
    func connect(_ address: String) throws
    func disconnect(_ address: String) throws
}

struct BluetoothDeviceReader: BluetoothDeviceReading {
    func hasBluetoothAccess() -> Bool {
        CBManager.authorization == .allowedAlways
    }

    func pairedDevices() -> [BluetoothDeviceInfo] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.compactMap { device in
            guard let address = device.addressString else { return nil }
            return BluetoothDeviceInfo(
                address: BluetoothDeviceKind.normalizedAddress(address),
                name: device.name ?? device.nameOrAddress ?? address,
                isConnected: device.isConnected(),
                majorClass: UInt32(device.deviceClassMajor),
                minorClass: UInt32(device.deviceClassMinor),
                batteryPercent: nil
            )
        }
    }

    func batteryLevels() -> [String: Int] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"), &iterator) == KERN_SUCCESS else {
            return [:]
        }
        defer { IOObjectRelease(iterator) }

        var levels: [String: Int] = [:]
        var service = IOIteratorNext(iterator)
        while service != MACH_PORT_NULL {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            func property(_ key: String) -> Any? {
                IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            }
            guard let address = property("DeviceAddress") as? String,
                  let percent = (property("BatteryPercent") as? NSNumber)?.intValue else { continue }
            levels[BluetoothDeviceKind.normalizedAddress(address)] = percent
        }
        return levels
    }

    func audioBatteryLevels() -> [String: AudioDeviceBattery] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [:] }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        guard process.terminationStatus == 0 else { return [:] }
        return AudioDeviceBattery.parseAll(data)
    }

    func connect(_ address: String) throws {
        guard let device = IOBluetoothDevice(addressString: address) else { throw BluetoothActionError.deviceNotFound }
        let result = device.openConnection()
        guard result == kIOReturnSuccess else { throw BluetoothActionError.failed(result) }
    }

    func disconnect(_ address: String) throws {
        guard let device = IOBluetoothDevice(addressString: address) else { throw BluetoothActionError.deviceNotFound }
        let result = device.closeConnection()
        guard result == kIOReturnSuccess else { throw BluetoothActionError.failed(result) }
    }
}

/// Bluetooth module: paired devices, connect and disconnect, battery levels.
/// Reads when the popover opens and on IOBluetooth connect/disconnect
/// notifications, which are registered only while it is open. Turning
/// Bluetooth itself on or off has no public API and stays in Control Center.
@MainActor
final class BluetoothModule: ObservableObject, StatusModule {
    let id: ModuleID = .bluetooth

    @Published private(set) var devices: [BluetoothDeviceInfo] = []
    @Published private(set) var hasLoaded = false
    @Published private(set) var busyAddresses: Set<String> = []
    @Published private(set) var errorMessage: String?
    /// An empty list because macOS denies access, not because nothing is paired.
    @Published private(set) var isAccessMissing = false

    private let reader: any BluetoothDeviceReading
    private let queue = DispatchQueue(label: "DuoBarPlus.BluetoothModule", qos: .userInitiated)
    private let observesSystemNotifications: Bool
    private var generation = 0
    private var isPopoverOpen = false
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    private lazy var notificationTarget = BluetoothNotificationTarget { [weak self] in
        self?.refresh()
    }

    init(reader: any BluetoothDeviceReading = BluetoothDeviceReader(), observesSystemNotifications: Bool = true) {
        self.reader = reader
        self.observesSystemNotifications = observesSystemNotifications
    }

    var connectedDevices: [BluetoothDeviceInfo] { devices.filter(\.isConnected) }
    var isObserving: Bool { connectNotification != nil }
    var activeWork: [String] { isObserving ? ["connect notifications"] : [] }

    func popoverDidOpen() {
        isPopoverOpen = true
        generation += 1
        refresh()
        if observesSystemNotifications, connectNotification == nil {
            connectNotification = IOBluetoothDevice.register(
                forConnectNotifications: notificationTarget,
                selector: #selector(BluetoothNotificationTarget.deviceDidChange(_:device:))
            )
        }
    }

    func popoverDidClose() {
        isPopoverOpen = false
        generation += 1
        stopObserving()
        errorMessage = nil
    }

    func deactivate() {
        isPopoverOpen = false
        generation += 1
        stopObserving()
    }

    func refresh() {
        guard isPopoverOpen else { return }
        let generation = generation
        let reader = reader
        queue.async { [weak self] in
            let levels = reader.batteryLevels()
            let paired = reader.pairedDevices()
            // Only start a process when an audio device is connected.
            let audio = paired.contains { $0.isConnected && $0.majorClass == 4 } ? reader.audioBatteryLevels() : [:]
            let devices = paired.map { device -> BluetoothDeviceInfo in
                var device = device
                guard device.isConnected else {
                    device.batteryPercent = nil
                    return device
                }
                device.batteryPercent = levels[device.address] ?? audio[device.address]?.main
                device.earbuds = audio[device.address]?.earbuds
                return device
            }
            let isAccessMissing = devices.isEmpty && !reader.hasBluetoothAccess()
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.isAccessMissing = isAccessMissing
                self.devices = BluetoothDeviceKind.sorted(devices)
                self.hasLoaded = true
                self.updateDisconnectNotifications()
            }
        }
    }

    func toggleConnection(_ device: BluetoothDeviceInfo) {
        guard !busyAddresses.contains(device.address) else { return }
        busyAddresses.insert(device.address)
        errorMessage = nil
        let reader = reader
        let address = device.address
        let connect = !device.isConnected
        queue.async { [weak self] in
            let result: Result<Void, Error> = Result { connect ? try reader.connect(address) : try reader.disconnect(address) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyAddresses.remove(address)
                if case .failure = result {
                    self.errorMessage = connect
                        ? localized("Could not connect to %@", device.name)
                        : localized("Could not disconnect %@", device.name)
                }
                self.refresh()
            }
        }
    }

    private func updateDisconnectNotifications() {
        guard observesSystemNotifications, isPopoverOpen else { return }
        let connected = Set(connectedDevices.map(\.address))
        for (address, notification) in disconnectNotifications where !connected.contains(address) {
            notification.unregister()
            disconnectNotifications[address] = nil
        }
        for address in connected where disconnectNotifications[address] == nil {
            guard let device = IOBluetoothDevice(addressString: address) else { continue }
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: notificationTarget,
                selector: #selector(BluetoothNotificationTarget.deviceDidChange(_:device:))
            )
        }
    }

    private func stopObserving() {
        connectNotification?.unregister()
        connectNotification = nil
        disconnectNotifications.values.forEach { $0.unregister() }
        disconnectNotifications = [:]
    }
}

/// Objective-C target for IOBluetooth's selector-based notifications.
final class BluetoothNotificationTarget: NSObject {
    private let onChange: @MainActor () -> Void

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    @objc func deviceDidChange(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        Task { @MainActor in onChange() }
    }
}
