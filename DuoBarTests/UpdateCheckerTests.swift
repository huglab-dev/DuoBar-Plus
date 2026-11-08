import SwiftUI
import XCTest
@testable import DuoBar

final class FakeReleaseReader: UpdateReleaseReading, @unchecked Sendable {
    var result: Result<AvailableRelease?, UpdateCheckError>
    private(set) var reads = 0
    init(_ result: Result<AvailableRelease?, UpdateCheckError>) { self.result = result }
    func latestRelease() async throws -> AvailableRelease? { reads += 1; return try result.get() }
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var date = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() {
        defaults = UserDefaults(suiteName: "UpdateCheckerTests-\(UUID().uuidString)")
    }

    private func release(_ version: String) -> AvailableRelease {
        AvailableRelease(version: AppVersion(version)!, pageURL: URL(string: "https://github.com/huglab-dev/DuoBar-Plus/releases/tag/v\(version)")!)
    }

    private func checker(_ reader: FakeReleaseReader, current: String = "1.0.0") -> UpdateChecker {
        UpdateChecker(reader: reader, defaults: defaults, currentVersion: current, now: { [unowned self] in self.date })
    }

    private func settle(_ checker: UpdateChecker) {
        let deadline = Date().addingTimeInterval(1)
        while checker.status == .checking, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testVersionComparison() throws {
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.0.0")), try XCTUnwrap(AppVersion("v1.0.1")))
        XCTAssertLessThan(try XCTUnwrap(AppVersion("1.9.0")), try XCTUnwrap(AppVersion("1.10.0")))
        XCTAssertEqual(AppVersion("1.0"), AppVersion("1.0.0"))
        XCTAssertNil(AppVersion("1.0-beta"))
        XCTAssertNil(AppVersion(""))
        XCTAssertEqual(AppVersion("v2.3.4")?.description, "2.3.4")
    }

    func testParsesReleaseAndRejectsForeignLinks() {
        let good = Data(#"{"tag_name":"v1.2.0","html_url":"https://github.com/huglab-dev/DuoBar-Plus/releases/tag/v1.2.0"}"#.utf8)
        XCTAssertEqual(GitHubRelease.parse(good)?.version, AppVersion("1.2.0"))
        for link in ["https://evil.example/huglab-dev/DuoBar-Plus/x", "http://github.com/huglab-dev/DuoBar-Plus/x", "https://github.com/someone/else/x"] {
            let data = Data(#"{"tag_name":"v1.2.0","html_url":"\#(link)"}"#.utf8)
            XCTAssertNil(GitHubRelease.parse(data), link)
        }
        XCTAssertNil(GitHubRelease.parse(Data("nope".utf8)))
    }

    func testOffersOnlyANewerRelease() {
        let newer = checker(FakeReleaseReader(.success(release("1.0.1"))))
        newer.popoverDidOpen(); settle(newer)
        XCTAssertEqual(newer.offeredRelease?.version, AppVersion("1.0.1"))

        let same = checker(FakeReleaseReader(.success(release("1.0.0"))))
        same.popoverDidOpen(); settle(same)
        XCTAssertNil(same.offeredRelease)

        let none = checker(FakeReleaseReader(.success(nil)))
        none.popoverDidOpen(); settle(none)
        XCTAssertNil(none.offeredRelease)
        XCTAssertEqual(none.status, .upToDate)
    }

    func testChecksAtMostOncePerDay() {
        let reader = FakeReleaseReader(.success(release("1.0.1")))
        let checker = checker(reader)
        checker.popoverDidOpen(); settle(checker)
        checker.popoverDidOpen(); settle(checker)
        XCTAssertEqual(reader.reads, 1)
        date.addTimeInterval(24 * 60 * 60 + 1)
        checker.popoverDidOpen(); settle(checker)
        XCTAssertEqual(reader.reads, 2)
    }

    func testTurningItOffStopsAutomaticChecksButNotCheckNow() {
        defaults.set(false, forKey: UpdateChecker.automaticKey)
        let reader = FakeReleaseReader(.success(release("1.0.1")))
        let checker = checker(reader)
        checker.popoverDidOpen(); settle(checker)
        XCTAssertEqual(reader.reads, 0)
        checker.checkNow(); settle(checker)
        XCTAssertEqual(reader.reads, 1)
    }

    func testSkippingHidesThatVersionOnly() {
        let reader = FakeReleaseReader(.success(release("1.0.1")))
        let first = checker(reader)
        first.popoverDidOpen(); settle(first)
        first.skip(release("1.0.1"))
        XCTAssertNil(first.offeredRelease)
        XCTAssertNotNil(first.newerRelease, "Settings still shows it")

        let relaunched = checker(reader)
        relaunched.popoverDidOpen(); settle(relaunched)
        XCTAssertNil(relaunched.offeredRelease, "the skip is remembered")

        reader.result = .success(release("1.0.2"))
        date.addTimeInterval(24 * 60 * 60 + 1)
        relaunched.popoverDidOpen(); settle(relaunched)
        XCTAssertEqual(relaunched.offeredRelease?.version, AppVersion("1.0.2"))

        relaunched.skip(release("1.0.2"))
        relaunched.checkNow(); settle(relaunched)
        XCTAssertNotNil(relaunched.offeredRelease, "Check Now brings it back")
    }

    func testFailureOffersNothing() {
        let checker = checker(FakeReleaseReader(.failure(.network)))
        checker.popoverDidOpen(); settle(checker)
        XCTAssertEqual(checker.status, .failed)
        XCTAssertNil(checker.offeredRelease)
    }

    func testStoreWithoutServicesNeverChecks() {
        let store = SystemStatusStore(startServices: false, deviceContext: DeviceContext(hasInternalBattery: true), moduleDefaults: UserDefaults(suiteName: "UpdateCheckerTests-store-\(UUID().uuidString)")!)
        store.setPopoverActive(true)
        XCTAssertEqual(UpdateChecker.shared.status, .idle)
        store.setPopoverActive(false)
    }

    func testRenderUpdateUI() throws {
        let checker = checker(FakeReleaseReader(.success(release("1.0.1"))))
        checker.popoverDidOpen(); settle(checker)
        let view = VStack(spacing: 12) {
            UpdateAvailableCard(release: release("1.0.1"), onDownload: {}, onSkip: {})
                .frame(width: 280)
            Form { UpdateSettingsSection(checker: checker) }
                .formStyle(.grouped)
                .frame(width: 420, height: 190)
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: NSSize(width: 444, height: 280))
        hostingView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-Updates.png"), options: .atomic)
    }
}
