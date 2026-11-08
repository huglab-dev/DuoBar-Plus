import Foundation
import IOKit
import IOKit.ps

struct BatteryHealth: Equatable, Sendable {
    var designCapacity: Int
    /// Full-charge capacity as macOS reports it (`NominalChargeCapacity`).
    var fullChargeCapacity: Int
    var cycleCount: Int?

    /// Full-charge capacity relative to design, rounded up. On the development
    /// Mac this matches System Information (5702 / 6249 = 91.2 % → 92 %).
    var maximumCapacityPercent: Int? {
        guard designCapacity > 0, fullChargeCapacity > 0 else { return nil }
        let percent = Double(fullChargeCapacity) / Double(designCapacity) * 100
        return min(Int(percent.rounded(.up)), 100)
    }
}

struct PowerAdapterInfo: Equatable, Sendable {
    var watts: Int?
    var name: String?
}

protocol BatteryDetailReading: Sendable {
    func health() -> BatteryHealth?
    func adapter() -> PowerAdapterInfo?
}

struct BatteryDetailReader: BatteryDetailReading {
    func health() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(service) }

        func int(_ key: String) -> Int? {
            let value = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            return (value as? NSNumber)?.intValue
        }

        guard let design = int("DesignCapacity") else { return nil }
        // NominalChargeCapacity is the full-charge capacity on Apple Silicon;
        // older Intel models only publish AppleRawMaxCapacity.
        let full = int("NominalChargeCapacity") ?? int("AppleRawMaxCapacity") ?? 0
        return BatteryHealth(designCapacity: design, fullChargeCapacity: full, cycleCount: int("CycleCount"))
    }

    func adapter() -> PowerAdapterInfo? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        let watts = (details[kIOPSPowerAdapterWattsKey] as? NSNumber)?.intValue
        let name = details["Name"] as? String
        guard watts != nil || name != nil else { return nil }
        return PowerAdapterInfo(watts: watts, name: name)
    }
}

/// Battery module. Hidden automatically on Macs without an internal battery.
/// Reads battery health and the connected charger when the popover opens,
/// and re-reads the charger on power-source notifications while it is open.
/// Level, charging state and Low Power Mode come from the existing
/// `BatteryService` through `SystemStatusStore`.
@MainActor
final class BatteryModule: ObservableObject, StatusModule {
    let id: ModuleID = .battery
    let isSupported: Bool

    @Published private(set) var health: BatteryHealth?
    @Published private(set) var adapter: PowerAdapterInfo?

    private let reader: any BatteryDetailReading
    private let queue = DispatchQueue(label: "DuoBarPlus.BatteryModule", qos: .userInitiated)
    private var runLoopSource: CFRunLoopSource?
    private var generation = 0

    init(hasInternalBattery: Bool, reader: any BatteryDetailReading = BatteryDetailReader()) {
        isSupported = hasInternalBattery
        self.reader = reader
    }

    var isObservingPowerSources: Bool { runLoopSource != nil }
    var activeWork: [String] { isObservingPowerSources ? ["power source notifications"] : [] }

    func popoverDidOpen() {
        generation += 1
        let generation = generation
        let reader = reader
        queue.async { [weak self] in
            let health = reader.health()
            let adapter = reader.adapter()
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.health = health
                self.adapter = adapter
            }
        }
        startObservingPowerSources()
    }

    func popoverDidClose() {
        generation += 1
        stopObservingPowerSources()
    }

    func deactivate() {
        generation += 1
        stopObservingPowerSources()
    }

    /// Called on power-source changes (plugging in, unplugging, level steps).
    func powerSourcesDidChange() {
        let generation = generation
        let reader = reader
        queue.async { [weak self] in
            let adapter = reader.adapter()
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.isObservingPowerSources else { return }
                self.adapter = adapter
            }
        }
    }

    private func startObservingPowerSources() {
        guard runLoopSource == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let module = Unmanaged<BatteryModule>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in module.powerSourcesDidChange() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    private func stopObservingPowerSources() {
        guard let runLoopSource else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)
        CFRunLoopSourceInvalidate(runLoopSource)
        self.runLoopSource = nil
    }

    deinit {
        if let runLoopSource {
            CFRunLoopSourceInvalidate(runLoopSource)
        }
    }
}
