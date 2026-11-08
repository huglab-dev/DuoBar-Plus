@preconcurrency import CoreWLAN
import Foundation
import SystemConfiguration

/// The access point the Mac is associated with at one moment.
struct AccessPointSnapshot: Equatable, Sendable {
    var ssid: String?
    /// nil without location authorization.
    var bssid: String?
    var channel: Int?
    var band: WiFiBand?
    var rssi: Int
}

extension AccessPointSnapshot {
    init(details: WiFiDetails) {
        self.init(ssid: details.ssid, bssid: details.bssid, channel: details.channelNumber, band: details.band, rssi: details.rssi)
    }
}

struct RoamingEntry: Equatable, Identifiable, Sendable {
    var id: Int
    var date: Date
    var from: AccessPointSnapshot
    var to: AccessPointSnapshot
}

enum RoamingDetector {
    /// A roam is a change of access point within an association. Without
    /// location access the BSSID is hidden, so a channel change counts too.
    static func isRoam(from old: AccessPointSnapshot?, to new: AccessPointSnapshot?) -> Bool {
        guard let old, let new, old.rssi < 0, new.rssi < 0 else { return false }
        if let oldBSSID = old.bssid, let newBSSID = new.bssid { return oldBSSID != newBSSID }
        return old.channel != nil && new.channel != nil && old.channel != new.channel
    }
}

/// Background listener for access point changes. Event-driven only, it
/// never polls: CoreWLAN `bssidDidChange` (not delivered to ad hoc or
/// Developer ID builds without an entitlement, see docs) plus
/// SystemConfiguration notifications for the interface's AirPort key.
/// `NetworkModule` also feeds the values it reads while the popover is
/// open, which catches a roam that happened while it was closed.
/// Keeps at most `capacity` entries in memory and nothing on disk.
@MainActor
final class RoamingLog: ObservableObject {
    @Published private(set) var entries: [RoamingEntry] = []
    @Published private(set) var isListening = false
    /// Set when CoreWLAN refused the event registration.
    @Published private(set) var registrationFailed = false

    let capacity: Int
    private var nextID = 0
    private var last: AccessPointSnapshot?
    private var listener: CoreWLANEventListener?

    init(capacity: Int = 50) {
        self.capacity = capacity
    }

    func start() {
        guard listener == nil else { return }
        let listener = CoreWLANEventListener { [weak self] snapshot in
            Task { @MainActor in self?.observe(snapshot) }
        }
        do {
            try listener.start()
            self.listener = listener
            isListening = true
            registrationFailed = false
            last = listener.currentSnapshot()
        } catch {
            registrationFailed = true
            isListening = false
        }
    }

    func stop() {
        listener?.stop()
        listener = nil
        isListening = false
        last = nil
    }

    func clear() {
        entries = []
    }

    /// Feeds one snapshot; internal so tests can drive the log directly.
    func observe(_ snapshot: AccessPointSnapshot?) {
        defer { if let snapshot, snapshot.rssi < 0 { last = snapshot } }
        guard RoamingDetector.isRoam(from: last, to: snapshot), let last, let snapshot else { return }
        entries.insert(RoamingEntry(id: nextID, date: Date(), from: last, to: snapshot), at: 0)
        nextID += 1
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }
}

/// Wraps a private `CWWiFiClient` so the shared client's delegate, used
/// elsewhere, is never touched. CoreWLAN events arrive on a CoreWLAN queue,
/// dynamic-store notifications on the main run loop.
final class CoreWLANEventListener: NSObject, CWEventDelegate, @unchecked Sendable {
    private let client = CWWiFiClient()
    private var dynamicStore: SCDynamicStore?
    private var dynamicStoreSource: CFRunLoopSource?
    private let onChange: @Sendable (AccessPointSnapshot?) -> Void
    #if DEBUG
    private var debugEventCount = 0
    #endif

    init(onChange: @escaping @Sendable (AccessPointSnapshot?) -> Void) {
        self.onChange = onChange
    }

    func start() throws {
        client.delegate = self
        // CoreWLAN registration can succeed without events ever arriving, so
        // the dynamic store is set up regardless and is the reliable path.
        try? client.startMonitoringEvent(with: .bssidDidChange)
        try? client.startMonitoringEvent(with: .linkDidChange)
        try startDynamicStore()
        #if DEBUG
        // Diagnostics for B1: link-quality events are frequent, so they show
        // quickly whether CoreWLAN delivers events to this build at all.
        if DebugPopoverControl.isEnabledNonisolated {
            try? client.startMonitoringEvent(with: .linkQualityDidChange)
        }
        #endif
    }

    func stop() {
        try? client.stopMonitoringAllEvents()
        client.delegate = nil
        if let dynamicStoreSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), dynamicStoreSource, .defaultMode)
            CFRunLoopSourceInvalidate(dynamicStoreSource)
        }
        dynamicStoreSource = nil
        dynamicStore = nil
    }

    private struct DynamicStoreUnavailable: Error {}

    private func startDynamicStore() throws {
        let interface = client.interface()?.interfaceName ?? "en0"
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        guard let store = SCDynamicStoreCreate(nil, "DuoBarPlus.Roaming" as CFString, { _, _, info in
            guard let info else { return }
            let listener = Unmanaged<CoreWLANEventListener>.fromOpaque(info).takeUnretainedValue()
            listener.debugLog("dynamic store AirPort change")
            listener.onChange(listener.currentSnapshot())
        }, &context) else { throw DynamicStoreUnavailable() }
        let key = "State:/Network/Interface/\(interface)/AirPort" as CFString
        guard SCDynamicStoreSetNotificationKeys(store, [key] as CFArray, nil),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { throw DynamicStoreUnavailable() }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        dynamicStore = store
        dynamicStoreSource = source
    }

    deinit {
        if let dynamicStoreSource {
            CFRunLoopSourceInvalidate(dynamicStoreSource)
        }
    }

    func currentSnapshot() -> AccessPointSnapshot? {
        guard let interface = client.interface(), interface.powerOn() else { return nil }
        let channel = interface.wlanChannel()
        return AccessPointSnapshot(
            ssid: SSIDValue.normalized(interface.ssid()),
            bssid: interface.bssid()?.lowercased(),
            channel: channel?.channelNumber,
            band: channel.flatMap { WiFiBand(rawValue: $0.channelBand.rawValue) },
            rssi: interface.rssiValue()
        )
    }

    func bssidDidChangeForWiFiInterface(withName interfaceName: String) {
        debugLog("bssidDidChange \(interfaceName)")
        onChange(currentSnapshot())
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        debugLog("linkDidChange \(interfaceName)")
        onChange(currentSnapshot())
    }

    #if DEBUG
    func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        debugLog("linkQualityDidChange rssi=\(rssi)")
    }
    #endif

    fileprivate func debugLog(_ message: String) {
        #if DEBUG
        debugEventCount += 1
        NSLog("%@", "[DuoBarPlus Roaming] event #\(debugEventCount): \(message)")
        #endif
    }
}
