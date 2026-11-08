import Foundation

enum StatusPriority: Int, Comparable, Sendable {
    case informational = 10
    case attention = 20
    case critical = 30

    static func < (lhs: StatusPriority, rhs: StatusPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct StatusEvent: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case charging
        case networkDisconnected
        case lowBattery
        case audioDeviceConnected(AudioDeviceStatus)
        /// DuoBar+: output volume or mute changed.
        case volumeChanged
    }

    let id: UUID
    let kind: Kind
    let priority: StatusPriority
    let duration: TimeInterval

    init(
        kind: Kind,
        priority: StatusPriority,
        duration: TimeInterval = 2.2,
        id: UUID = UUID()
    ) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.duration = duration
    }
}

enum StatusPresentation: Equatable, Sendable {
    case normal
    case event(StatusEvent)

    var event: StatusEvent? {
        guard case let .event(event) = self else { return nil }
        return event
    }
}

enum StatusEventDetector {
    static func events(from old: SystemStatus, to new: SystemStatus) -> [StatusEvent] {
        var events: [StatusEvent] = []

        // DuoBar+: plugging in counts too, also when the battery is full and
        // macOS does not start charging.
        if old.battery.isAvailable,
           (!old.battery.isCharging && new.battery.isCharging)
            || (!old.battery.isPluggedIn && new.battery.isPluggedIn) {
            events.append(StatusEvent(kind: .charging, priority: .informational))
        }

        if old.network.isAvailable,
           old.network.isConnected,
           !new.network.isConnected {
            events.append(StatusEvent(kind: .networkDisconnected, priority: .attention))
        }

        let oldPercentage = old.battery.percentage ?? 101
        let newPercentage = new.battery.percentage ?? 101
        if new.battery.isAvailable,
           !new.battery.isCharging,
           oldPercentage > 10,
           newPercentage <= 10 {
            events.append(StatusEvent(kind: .lowBattery, priority: .critical, duration: 3.2))
        } else if new.battery.isAvailable,
                  !new.battery.isCharging,
                  oldPercentage > 20,
                  newPercentage <= 20 {
            // DuoBar+: the first macOS warning level.
            events.append(StatusEvent(kind: .lowBattery, priority: .attention, duration: 3.2))
        }

        // DuoBar+: volume and mute changes after the first reading.
        if let oldPercentage = old.audio.volume.percentage,
           let newPercentage = new.audio.volume.percentage,
           oldPercentage != newPercentage || old.audio.volume.isMuted != new.audio.volume.isMuted {
            events.append(StatusEvent(kind: .volumeChanged, priority: .informational, duration: 1.5))
        }

        if old.audio.isAvailable {
            let oldDeviceIDs = Set(old.audio.connectedBluetoothOutputs.map(\.uid))
            if let connectedDevice = new.audio.connectedBluetoothOutputs.first(where: { !oldDeviceIDs.contains($0.uid) }) {
                events.append(
                    StatusEvent(
                        kind: .audioDeviceConnected(connectedDevice),
                        priority: .informational,
                        duration: 1.45
                    )
                )
            }
        }

        return events.sorted { lhs, rhs in
            if lhs.priority == rhs.priority { return lhs.duration > rhs.duration }
            return lhs.priority > rhs.priority
        }
    }
}
