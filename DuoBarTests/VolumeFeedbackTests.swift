import XCTest
@testable import DuoBar

final class VolumeFeedbackTests: XCTestCase {
    func testMutedBeginRequestsUnmuteExactlyOnce() {
        var interaction = VolumeFeedbackInteraction()
        let muted = controllableVolume(level: 0.45, muted: true)
        var unmuteRequests = 0

        interaction.beginEditing(previousStatus: muted) {
            unmuteRequests += 1
            return true
        }
        interaction.beginEditing(previousStatus: muted) {
            unmuteRequests += 1
            return true
        }

        XCTAssertEqual(unmuteRequests, 1)
        XCTAssertTrue(interaction.allowsVolumeUpdates)
    }

    func testMutedOneHundredUpdatesStaySilentUntilOneFeedbackOnRelease() {
        var interaction = VolumeFeedbackInteraction()
        let muted = controllableVolume(level: 0.45, muted: true)
        var playbackCount = 0

        interaction.beginEditing(previousStatus: muted) { true }
        for update in 1...100 {
            interaction.recordVolumeUpdate(
                previousStatus: muted,
                requestedLevel: Double(update) / 100,
                writeSucceeded: true
            )
            XCTAssertEqual(playbackCount, 0)
        }

        if interaction.endEditing() { playbackCount += 1 }
        XCTAssertEqual(playbackCount, 1)
        if interaction.endEditing() { playbackCount += 1 }
        XCTAssertEqual(playbackCount, 1)
    }

    func testMutedDirectSliderClickUnmutesAndProducesAtMostOneFeedback() {
        var interaction = VolumeFeedbackInteraction()
        let muted = controllableVolume(level: 0.45, muted: true)
        var unmuteRequests = 0

        interaction.beginEditing(previousStatus: muted) {
            unmuteRequests += 1
            return true
        }
        interaction.recordVolumeUpdate(
            previousStatus: muted,
            requestedLevel: 0.75,
            writeSucceeded: true
        )

        XCTAssertEqual(unmuteRequests, 1)
        XCTAssertTrue(interaction.endEditing())
        XCTAssertFalse(interaction.endEditing())
    }

    func testSecondInteractionAfterUnmuteUsesNormalReleaseFeedback() {
        var interaction = VolumeFeedbackInteraction()
        let muted = controllableVolume(level: 0.4, muted: true)
        let unmuted = controllableVolume(level: 0.6)
        var playbackCount = 0
        var unmuteRequests = 0

        interaction.beginEditing(previousStatus: muted) {
            unmuteRequests += 1
            return true
        }
        interaction.recordVolumeUpdate(previousStatus: muted, requestedLevel: 0.6, writeSucceeded: true)
        if interaction.endEditing() { playbackCount += 1 }

        interaction.beginEditing(previousStatus: unmuted) {
            unmuteRequests += 1
            return true
        }
        interaction.recordVolumeUpdate(previousStatus: unmuted, requestedLevel: 0.8, writeSucceeded: true)
        if interaction.endEditing() { playbackCount += 1 }

        XCTAssertEqual(unmuteRequests, 1)
        XCTAssertEqual(playbackCount, 2)
    }

    func testFailedUnmuteDisablesVolumeWritesAndReleaseFeedback() {
        var interaction = VolumeFeedbackInteraction()
        let muted = controllableVolume(level: 0.45, muted: true)
        var unmuteRequests = 0

        interaction.beginEditing(previousStatus: muted) {
            unmuteRequests += 1
            return false
        }
        interaction.recordVolumeUpdate(
            previousStatus: muted,
            requestedLevel: 0.7,
            writeSucceeded: false
        )

        XCTAssertEqual(unmuteRequests, 1)
        XCTAssertFalse(interaction.allowsVolumeUpdates)
        XCTAssertFalse(interaction.endEditing())
    }

    func testExternalMuteAndUnmuteChangesProduceNoFeedback() {
        var interaction = VolumeFeedbackInteraction()
        let externallyObservedStates = [
            controllableVolume(level: 0.5, muted: true),
            controllableVolume(level: 0.5, muted: false)
        ]

        for _ in externallyObservedStates {
            XCTAssertFalse(interaction.endEditing())
        }
    }

    func testCoreAudioListenerCallbacksCannotDuplicateReleaseFeedback() {
        var interaction = VolumeFeedbackInteraction()
        let unmuted = controllableVolume(level: 0.5)
        var playbackCount = 0

        interaction.beginEditing(previousStatus: unmuted) {
            XCTFail("Unexpected unmute request")
            return false
        }
        interaction.recordVolumeUpdate(previousStatus: unmuted, requestedLevel: 0.7, writeSucceeded: true)
        if interaction.endEditing() { playbackCount += 1 }

        // Listener-driven model changes never call begin/record. Repeated release
        // checks therefore cannot produce another sound.
        if interaction.endEditing() { playbackCount += 1 }
        if interaction.endEditing() { playbackCount += 1 }
        XCTAssertEqual(playbackCount, 1)
    }

    func testNormalUnmutedDragRemainsSilentUntilOneFeedbackOnRelease() {
        var interaction = VolumeFeedbackInteraction()
        let unmuted = controllableVolume(level: 0.5)
        var playbackCount = 0

        interaction.beginEditing(previousStatus: unmuted) {
            XCTFail("Unexpected unmute request")
            return false
        }
        for update in 1...100 {
            interaction.recordVolumeUpdate(
                previousStatus: unmuted,
                requestedLevel: Double(update) / 100,
                writeSucceeded: true
            )
            XCTAssertEqual(playbackCount, 0)
        }
        if interaction.endEditing() { playbackCount += 1 }
        XCTAssertEqual(playbackCount, 1)
    }

    func testZeroFailedAndUnsupportedInteractionsRemainSilent() {
        XCTAssertFalse(completedInteraction(volume: controllableVolume(level: 0.5), requestedLevel: 0))
        XCTAssertFalse(completedInteraction(volume: controllableVolume(level: 0.5), succeeded: false))
        XCTAssertFalse(completedInteraction(
            volume: OutputVolumeStatus(level: 0.5, isMuted: false, isSettable: false)
        ))
    }

    func testAnyFailedVolumeWriteSuppressesFeedbackForCompletedDrag() {
        var interaction = VolumeFeedbackInteraction()
        let volume = controllableVolume(level: 0.5)

        interaction.beginEditing(previousStatus: volume) { true }
        interaction.recordVolumeUpdate(previousStatus: volume, requestedLevel: 0.6, writeSucceeded: true)
        interaction.recordVolumeUpdate(previousStatus: volume, requestedLevel: 0.7, writeSucceeded: false)
        interaction.recordVolumeUpdate(previousStatus: volume, requestedLevel: 0.8, writeSucceeded: true)

        XCTAssertFalse(interaction.endEditing())
    }

    func testOnlySuccessfulUserUnmuteButtonAtAudibleLevelProducesFeedback() {
        let interaction = VolumeFeedbackInteraction()
        let muted = controllableVolume(level: 0.4, muted: true)

        XCTAssertTrue(interaction.shouldPlayForUnmute(previousStatus: muted, writeSucceeded: true))
        XCTAssertFalse(interaction.shouldPlayForUnmute(
            previousStatus: controllableVolume(level: 0, muted: true),
            writeSucceeded: true
        ))
        XCTAssertFalse(interaction.shouldPlayForUnmute(
            previousStatus: controllableVolume(level: 0.4, muted: false),
            writeSucceeded: true
        ))
        XCTAssertFalse(interaction.shouldPlayForUnmute(previousStatus: muted, writeSucceeded: false))
    }

    private func controllableVolume(level: Double, muted: Bool = false) -> OutputVolumeStatus {
        OutputVolumeStatus(
            level: level,
            isMuted: muted,
            isSettable: true,
            isMuteSettable: true
        )
    }

    private func completedInteraction(
        volume: OutputVolumeStatus,
        requestedLevel: Double = 0.6,
        succeeded: Bool = true
    ) -> Bool {
        var interaction = VolumeFeedbackInteraction()
        interaction.beginEditing(previousStatus: volume) { true }
        interaction.recordVolumeUpdate(
            previousStatus: volume,
            requestedLevel: requestedLevel,
            writeSucceeded: succeeded
        )
        return interaction.endEditing()
    }
}
