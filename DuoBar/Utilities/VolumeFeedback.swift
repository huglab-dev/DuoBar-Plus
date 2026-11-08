import AppKit
import Foundation

struct VolumeFeedbackInteraction {
    private(set) var isEditing = false
    private(set) var allowsVolumeUpdates = false
    private var receivedVolumeUpdate = false
    private var allWritesSucceeded = true
    private var releaseFeedbackAllowed = false
    private var finalRequestedLevel: Double?

    mutating func beginEditing(
        previousStatus: OutputVolumeStatus,
        requestUnmute: () -> Bool
    ) {
        guard !isEditing else { return }
        isEditing = true
        allowsVolumeUpdates = true
        receivedVolumeUpdate = false
        allWritesSucceeded = true
        releaseFeedbackAllowed = previousStatus.isSettable
        finalRequestedLevel = nil

        if previousStatus.isMuted, previousStatus.isMuteSettable {
            let unmuteSucceeded = requestUnmute()
            allowsVolumeUpdates = unmuteSucceeded
            releaseFeedbackAllowed = releaseFeedbackAllowed && unmuteSucceeded
        }
    }

    mutating func recordVolumeUpdate(
        previousStatus: OutputVolumeStatus,
        requestedLevel: Double,
        writeSucceeded: Bool
    ) {
        guard isEditing else { return }
        receivedVolumeUpdate = true
        allWritesSucceeded = allWritesSucceeded && writeSucceeded
        releaseFeedbackAllowed = releaseFeedbackAllowed && previousStatus.isSettable
        finalRequestedLevel = requestedLevel
    }

    mutating func endEditing() -> Bool {
        guard isEditing else { return false }
        defer { reset() }

        return receivedVolumeUpdate
            && allWritesSucceeded
            && releaseFeedbackAllowed
            && (finalRequestedLevel ?? 0) > 0
    }

    func shouldPlayForUnmute(
        previousStatus: OutputVolumeStatus,
        writeSucceeded: Bool
    ) -> Bool {
        writeSucceeded
            && previousStatus.isMuteSettable
            && previousStatus.isMuted
            && (previousStatus.level ?? 0) > 0
    }

    private mutating func reset() {
        isEditing = false
        allowsVolumeUpdates = false
        receivedVolumeUpdate = false
        allWritesSucceeded = true
        releaseFeedbackAllowed = false
        finalRequestedLevel = nil
    }
}

@MainActor
enum VolumeFeedbackSound {
    private static let sound: NSSound? = {
        guard let systemSound = NSSound(named: NSSound.Name("Tink")),
              let sound = systemSound.copy() as? NSSound
        else { return nil }

        sound.volume = 0.18
        sound.loops = false
        return sound
    }()

    @discardableResult
    static func play(on playbackDeviceIdentifier: String?) -> Bool {
        guard let sound else { return false }

        // A nil identifier intentionally follows the current system default output.
        sound.playbackDeviceIdentifier = playbackDeviceIdentifier
        if sound.isPlaying {
            sound.stop()
            sound.currentTime = 0
        }
        if sound.play() {
            return true
        }

        // Device UIDs are public Core Audio identifiers, but some output drivers
        // decline explicit routing. Let AppKit retry on the current default route.
        guard playbackDeviceIdentifier != nil else { return false }
        sound.playbackDeviceIdentifier = nil
        return sound.play()
    }
}
