import AppKit
import Foundation

/// Tells the user when a newer release is on GitHub. Runs when the popover
/// opens, at most once per `minimumInterval`, so nothing happens with the
/// popover closed. It never downloads or installs anything.
@MainActor
final class UpdateChecker: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case failed
    }

    static let automaticKey = "duoBarPlus.checkForUpdates"
    static let skippedVersionKey = "duoBarPlus.skippedUpdateVersion"
    static let shared = UpdateChecker()

    @Published private(set) var status: Status = .idle
    @Published private(set) var latest: AvailableRelease?
    @Published private var skippedVersion: String?

    let currentVersionText: String
    private let currentVersion: AppVersion?
    private let reader: any UpdateReleaseReading
    private let defaults: UserDefaults
    private let minimumInterval: TimeInterval
    private let now: () -> Date
    private var lastAutomaticCheck: Date?

    init(
        reader: any UpdateReleaseReading = GitHubReleaseReader(),
        defaults: UserDefaults = .standard,
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        minimumInterval: TimeInterval = 24 * 60 * 60,
        now: @escaping () -> Date = Date.init
    ) {
        self.reader = reader
        self.defaults = defaults
        currentVersionText = currentVersion
        self.currentVersion = AppVersion(currentVersion)
        self.minimumInterval = minimumInterval
        self.now = now
        skippedVersion = defaults.string(forKey: Self.skippedVersionKey)
    }

    var checksAutomatically: Bool {
        defaults.object(forKey: Self.automaticKey) as? Bool ?? true
    }

    /// A release newer than this build, whether or not the user skipped it.
    var newerRelease: AvailableRelease? {
        guard let latest, let currentVersion, latest.version > currentVersion else { return nil }
        return latest
    }

    /// The release to offer in the popover.
    var offeredRelease: AvailableRelease? {
        guard let release = newerRelease, release.version.description != skippedVersion else { return nil }
        return release
    }

    func popoverDidOpen() {
        guard checksAutomatically else { return }
        let date = now()
        if let lastAutomaticCheck, date.timeIntervalSince(lastAutomaticCheck) < minimumInterval { return }
        lastAutomaticCheck = date
        check()
    }

    /// "Check Now": also brings back a version the user skipped.
    func checkNow() {
        setSkippedVersion(nil)
        check()
    }

    func skip(_ release: AvailableRelease) {
        setSkippedVersion(release.version.description)
    }

    func openReleasePage(_ release: AvailableRelease) {
        NSWorkspace.shared.open(release.pageURL)
    }

    private func setSkippedVersion(_ version: String?) {
        skippedVersion = version
        if let version {
            defaults.set(version, forKey: Self.skippedVersionKey)
        } else {
            defaults.removeObject(forKey: Self.skippedVersionKey)
        }
    }

    private func check() {
        guard status != .checking else { return }
        status = .checking
        let reader = reader
        Task { [weak self] in
            do {
                let release = try await reader.latestRelease()
                self?.latest = release
                self?.status = .upToDate
            } catch {
                self?.status = .failed
            }
        }
    }
}
