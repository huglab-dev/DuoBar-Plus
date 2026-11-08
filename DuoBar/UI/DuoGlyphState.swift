import Foundation

enum DuoCenterState: Hashable {
    case wifi(WiFiSignalLevel)
    case ethernet
    case offline
    case other
    case unavailable
    case airPodsPro
    case airPodsMax
    case airPods
    case headphones
    case audioDevice
    case adaptiveBrightness
    case performanceCPU
    case performanceMemory
    case performanceThermal
    case adaptiveEntry
    /// DuoBar+: a bolt (live moment: plugged in).
    case charging
    /// DuoBar+: a number, e.g. the battery level or CPU load.
    case value(Int)
    /// DuoBar+: nothing in the center.
    case empty
}

enum DuoSemanticFeedback: Equatable {
    case none
    case charging
    case lowBattery
    case audioConnected
}

enum DuoPersistentRingMode: Equatable {
    case battery
    case adaptive
}

struct DuoPersistentRingPresentation: Equatable {
    let mode: DuoPersistentRingMode
    let progress: Double
    let opacity: Double
    let batteryPresentation: BatteryRingPresentation

    static func battery(
        _ battery: BatteryStatus,
        colorCodingEnabled: Bool,
        levelColorsEnabled: Bool = false
    ) -> DuoPersistentRingPresentation {
        let progress: Double
        if battery.isFullyCharged {
            progress = 1
        } else if battery.isAvailable, let percentage = battery.percentage {
            progress = min(max(Double(percentage) / 100, 0), 1)
        } else {
            progress = 1
        }
        return DuoPersistentRingPresentation(
            mode: .battery,
            progress: progress,
            opacity: battery.isAvailable ? 1 : 0.22,
            batteryPresentation: BatteryRingPresentation.resolve(
                battery: battery,
                colorCodingEnabled: colorCodingEnabled,
                levelColorsEnabled: levelColorsEnabled
            )
        )
    }

    static func adaptive(progress: Double) -> DuoPersistentRingPresentation {
        DuoPersistentRingPresentation(
            mode: .adaptive,
            progress: min(max(progress, 0), 1),
            opacity: 1,
            batteryPresentation: BatteryRingPresentation(
                boltPlacement: .none,
                colorRole: .monochrome
            )
        )
    }
}

enum DuoPersistentRingPresentationResolver {
    static func resolve(
        mode: DuoPersistentRingMode,
        battery: BatteryStatus,
        adaptiveProgress: Double,
        batteryColorCodingEnabled: Bool,
        batteryLevelColorsEnabled: Bool = false
    ) -> DuoPersistentRingPresentation {
        switch mode {
        case .battery:
            return .battery(
                battery,
                colorCodingEnabled: batteryColorCodingEnabled,
                levelColorsEnabled: batteryLevelColorsEnabled
            )
        case .adaptive:
            return .adaptive(progress: adaptiveProgress)
        }
    }
}

struct DuoGlyphState: Equatable {
    let ringPresentation: DuoPersistentRingPresentation
    let batteryProgress: Double
    let batteryArcOpacity: Double
    let isCharging: Bool
    let batteryPresentation: BatteryRingPresentation
    let centerState: DuoCenterState
    let volumeActiveDotCount: Int?
    let feedback: DuoSemanticFeedback
    let audioEventID: UUID?

    init(
        status: SystemStatus,
        presentation: StatusPresentation = .normal,
        ringPresentation: DuoPersistentRingPresentation? = nil,
        centerStateOverride: DuoCenterState? = nil,
        batteryColorCodingEnabled: Bool = false,
        batteryLevelColorsEnabled: Bool = false,
        liveMomentCenters: Bool = false,
        dotCountOverride: Int? = nil
    ) {
        let battery = status.battery
        let resolvedRing = ringPresentation ?? .battery(
            battery,
            colorCodingEnabled: batteryColorCodingEnabled,
            levelColorsEnabled: batteryLevelColorsEnabled
        )
        self.ringPresentation = resolvedRing
        batteryProgress = resolvedRing.progress
        batteryArcOpacity = resolvedRing.opacity
        isCharging = resolvedRing.mode == .battery
            && battery.isAvailable
            && battery.isCharging
            && !battery.isFullyCharged
        batteryPresentation = resolvedRing.batteryPresentation
        volumeActiveDotCount = dotCountOverride ?? status.audio.volume.activeDotCount

        let normalCenter = centerStateOverride ?? Self.networkCenter(for: status.network)
        guard let event = presentation.event else {
            centerState = normalCenter
            feedback = .none
            audioEventID = nil
            return
        }

        switch event.kind {
        case .audioDeviceConnected(let device):
            switch device.temporaryConnectionGlyph {
            case .airPodsPro: centerState = .airPodsPro
            case .airPodsMax: centerState = .airPodsMax
            case .airPods: centerState = .airPods
            case .headphones: centerState = .headphones
            case .audioDevice: centerState = .audioDevice
            }
            feedback = .audioConnected
            audioEventID = event.id
        case .charging:
            // DuoBar+ live moment: a bolt, unless an override (the Adaptive
            // Ring entry) is allowed over the charging event.
            centerState = liveMomentCenters && centerStateOverride == nil ? .charging : normalCenter
            feedback = .charging
            audioEventID = nil
        case .lowBattery:
            centerState = liveMomentCenters
                ? battery.percentage.map(DuoCenterState.value) ?? normalCenter
                : normalCenter
            feedback = .lowBattery
            audioEventID = nil
        case .volumeChanged:
            centerState = normalCenter
            feedback = .none
            audioEventID = nil
        case .networkDisconnected:
            centerState = .offline
            feedback = .none
            audioEventID = nil
        }
    }

    private static func networkCenter(for network: NetworkStatus) -> DuoCenterState {
        guard network.isAvailable else { return .unavailable }
        guard network.isConnected else { return .offline }

        switch network.transport {
        case .wifi:
            return .wifi(network.wifiSignalLevel)
        case .ethernet:
            return .ethernet
        case .other:
            return .other
        case .none:
            return .offline
        }
    }
}
