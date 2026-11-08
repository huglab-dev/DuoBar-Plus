import SwiftUI
import XCTest
@testable import DuoBar

final class FakeCodexReader: CodexUsageReading, @unchecked Sendable {
    var usage: ProviderUsage?
    init(_ usage: ProviderUsage?) { self.usage = usage }
    func latestUsage() -> ProviderUsage? { usage }
}

final class FakeCredentialsReader: ClaudeCredentialsReading, @unchecked Sendable {
    var result: Result<ClaudeCredentials, ClaudeCredentialsError>
    private(set) var reads = 0
    init(_ result: Result<ClaudeCredentials, ClaudeCredentialsError>) { self.result = result }
    func read() throws -> ClaudeCredentials { reads += 1; return try result.get() }
}

final class FakeFetcher: ClaudeUsageFetching, @unchecked Sendable {
    var status: Int
    var body: Data
    private(set) var tokens: [String] = []
    init(status: Int = 200, body: Data = AIUsageTests.claudeJSON) { self.status = status; self.body = body }
    func fetch(accessToken: String) async throws -> (Int, Data) { tokens.append(accessToken); return (status, body) }
}

@MainActor
final class AIUsageTests: XCTestCase {
    nonisolated static let claudeJSON = Data("""
    {"five_hour":{"utilization":34,"resets_at":"2026-11-08T15:00:00.123+00:00"},
     "seven_day":{"utilization":61.5,"resets_at":"2026-11-11T09:00:00Z"},
     "seven_day_opus":null,"seven_day_sonnet":{"utilization":12,"resets_at":null},"extra_usage":null}
    """.utf8)

    static let codexLine = """
    {"timestamp":"2026-06-15T09:37:03.084Z","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":1.0,"window_minutes":300,"resets_at":1781534112},"secondary":{"used_percent":10.0,"window_minutes":10080,"resets_at":1781772723},"credits":null,"plan_type":"team"}}}
    """

    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "AIUsageTests-\(UUID().uuidString)")
    }

    func testClaudeParserReadsWindowsAndSkipsNulls() throws {
        let usage = try XCTUnwrap(ClaudeUsageParser.parse(Self.claudeJSON, measuredAt: Date(), plan: "max"))
        XCTAssertEqual(usage.windows.map(\.kind), [.session, .weekly, .weeklyModel("Sonnet")])
        XCTAssertEqual(usage.session?.usedFraction ?? 0, 0.34, accuracy: 0.0001)
        XCTAssertEqual(usage.highest?.kind, .weekly)
        XCTAssertNotNil(usage.session?.resetsAt)
        XCTAssertNil(usage.windows[2].resetsAt)
        XCTAssertNil(ClaudeUsageParser.parse(Data("{}".utf8), measuredAt: Date(), plan: nil))
        XCTAssertNil(ClaudeUsageParser.parse(Data("nope".utf8), measuredAt: Date(), plan: nil))
    }

    func testCodexParserUsesTheNewestRateLimits() throws {
        let older = Self.codexLine.replacingOccurrences(of: "\"used_percent\":1.0", with: "\"used_percent\":50.0")
        let lines = [older, "{\"type\":\"other\"}", Self.codexLine, "{\"type\":\"response_item\"}"].map { Substring($0) }
        let usage = try XCTUnwrap(CodexUsageParser.parse(lines: lines))
        XCTAssertEqual(usage.windows.map(\.kind), [.session, .weekly])
        XCTAssertEqual(usage.session?.usedFraction ?? 0, 0.01, accuracy: 0.0001)
        XCTAssertEqual(usage.plan, "team")
        XCTAssertEqual(usage.windows[1].resetsAt, Date(timeIntervalSince1970: 1781772723))
        XCTAssertNil(CodexUsageParser.parse(lines: ["{\"type\":\"other\"}"]))
    }

    func testCodexReaderFindsTheNewestLog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-\(UUID().uuidString)")
        let day = root.appendingPathComponent("2026/06/15")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        try "{\"type\":\"session_meta\"}\n\(Self.codexLine)\n".write(to: day.appendingPathComponent("rollout-a.jsonl"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: root) }
        let usage = CodexUsageReader(sessionsDirectory: root).latestUsage()
        XCTAssertEqual(usage?.plan, "team")
        XCTAssertNil(CodexUsageReader(sessionsDirectory: root.appendingPathComponent("missing")).latestUsage())
    }

    func testCredentialsParser() throws {
        let data = Data(#"{"claudeAiOauth":{"accessToken":"tok","refreshToken":"r","expiresAt":1800000000000,"subscriptionType":"max"}}"#.utf8)
        let credentials = try XCTUnwrap(ClaudeCredentials.parse(data))
        XCTAssertEqual(credentials.accessToken, "tok")
        XCTAssertEqual(credentials.subscriptionType, "max")
        XCTAssertEqual(credentials.expiresAt, Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertTrue(credentials.isExpired(at: Date(timeIntervalSince1970: 1_800_000_001)))
        XCTAssertNil(ClaudeCredentials.parse(Data("{}".utf8)))
    }

    func testWindowResetsOnceItsTimeHasPassed() {
        let window = UsageWindow(kind: .session, usedFraction: 0.8, resetsAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(window.current(at: Date(timeIntervalSince1970: 50)).usedFraction, 0.8)
        XCTAssertEqual(window.current(at: Date(timeIntervalSince1970: 150)).usedFraction, 0)
    }

    func testResetText() {
        let now = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(AIUsageText.reset(Date(timeIntervalSince1970: 42 * 60), now: now), localized("Resets in %d min", 42))
        XCTAssertEqual(AIUsageText.reset(Date(timeIntervalSince1970: 3 * 3600 + 12 * 60), now: now), localized("Resets in %d h %d min", 3, 12))
        XCTAssertNil(AIUsageText.reset(nil, now: now))
    }

    private func usage(_ provider: AIProvider, session: Double, weekly: Double, resetIn: TimeInterval = 8_040, now: Date) -> ProviderUsageState {
        .ready(ProviderUsage(provider: provider, windows: [
            UsageWindow(kind: .session, usedFraction: session, resetsAt: now.addingTimeInterval(resetIn)),
            UsageWindow(kind: .weekly, usedFraction: weekly, resetsAt: now.addingTimeInterval(400_000)),
        ], plan: nil, measuredAt: now))
    }

    func testSummaryLabelsWindowsAndShowsTheSessionReset() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let summary = AIUsageSummary.make([(.claude, usage(.claude, session: 0.32, weekly: 0.54, now: now))], now: now)
        XCTAssertEqual(summary.detail, localized("5 h resets in %@", localized("%d h %d min", 2, 14)))
        XCTAssertEqual(summary.values.map(\.label), [localized("5 h"), localized("Week")])
        XCTAssertEqual(summary.values.map(\.text), [localized("%d%%", 32), localized("%d%%", 54)])
        XCTAssertEqual(summary.values.compactMap(\.warning), [])
    }

    func testSummaryWarnsFromNinetyPercent() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let near = AIUsageSummary.make([(.claude, usage(.claude, session: 0.2, weekly: 0.9, now: now))], now: now)
        XCTAssertEqual(near.values.map(\.warning), [nil, .near])
        let below = AIUsageSummary.make([(.claude, usage(.claude, session: 0.89, weekly: 0.5, now: now))], now: now)
        XCTAssertEqual(below.values.map(\.warning), [nil, nil])
        let reached = AIUsageSummary.make([(.claude, usage(.claude, session: 1, weekly: 0.5, now: now))], now: now)
        XCTAssertEqual(reached.values.first?.warning, .reached)
        XCTAssertNil(AIUsageLevel.tint(0.89))
    }

    func testSummaryWithTwoToolsUsesTheHigherValues() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let summary = AIUsageSummary.make([
            (.claude, usage(.claude, session: 0.32, weekly: 0.54, now: now)),
            (.codex, usage(.codex, session: 0.5, weekly: 0.1, resetIn: 3_600, now: now)),
        ], now: now)
        XCTAssertEqual(summary.values.map(\.text), [localized("%d%%", 50), localized("%d%%", 54)])
        XCTAssertEqual(summary.detail, localized("%@ resets in %@", "Codex", localized("%d h %d min", 1, 0)))
    }

    func testModuleIsOffByDefaultAndDoesNothingUntilOpened() {
        XCTAssertFalse(ModuleID.aiUsage.isEnabledByDefault)
        let credentials = FakeCredentialsReader(.success(ClaudeCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil)))
        let module = AIUsageModule(codexReader: FakeCodexReader(nil), credentialsReader: credentials, fetcher: FakeFetcher(), defaults: defaults)
        module.activate()
        spin(0.1)
        XCTAssertEqual(credentials.reads, 0, "no Keychain access before the popover opens")
        XCTAssertEqual(module.claude, .off)
    }

    func testOpenReadsBothAndRateLimitsClaude() {
        let credentials = FakeCredentialsReader(.success(ClaudeCredentials(accessToken: "tok", expiresAt: nil, subscriptionType: "pro")))
        let fetcher = FakeFetcher()
        let codexUsage = CodexUsageParser.parse(lines: [Substring(Self.codexLine)])
        let module = AIUsageModule(codexReader: FakeCodexReader(codexUsage), credentialsReader: credentials, fetcher: fetcher, defaults: defaults)
        module.popoverDidOpen()
        spin(0.3)
        XCTAssertEqual(module.claude.usage?.plan, "pro")
        XCTAssertEqual(module.codex.usage?.plan, "team")
        XCTAssertEqual(fetcher.tokens, ["tok"])

        module.popoverDidClose()
        module.popoverDidOpen()
        spin(0.2)
        XCTAssertEqual(fetcher.tokens.count, 1, "reopening within the interval does not fetch again")
        XCTAssertEqual(credentials.reads, 1)

        module.refresh(force: true)
        spin(0.2)
        XCTAssertEqual(fetcher.tokens.count, 2)
        XCTAssertEqual(credentials.reads, 1, "the sign-in is kept in memory")
        module.popoverDidClose()
    }

    func testProblemsAreReported() {
        let expired = AIUsageModule(
            codexReader: FakeCodexReader(nil),
            credentialsReader: FakeCredentialsReader(.success(ClaudeCredentials(accessToken: "t", expiresAt: Date(timeIntervalSince1970: 1), subscriptionType: nil))),
            fetcher: FakeFetcher(),
            defaults: defaults
        )
        expired.popoverDidOpen()
        spin(0.2)
        XCTAssertEqual(expired.claude, .failed(.signInExpired))
        XCTAssertEqual(expired.codex, .failed(.noSessions))

        let denied = AIUsageModule(codexReader: FakeCodexReader(nil), credentialsReader: FakeCredentialsReader(.failure(.denied)), fetcher: FakeFetcher(), defaults: defaults)
        denied.popoverDidOpen()
        spin(0.2)
        XCTAssertEqual(denied.claude, .failed(.keychainDenied))

        let unauthorized = AIUsageModule(
            codexReader: FakeCodexReader(nil),
            credentialsReader: FakeCredentialsReader(.success(ClaudeCredentials(accessToken: "t", expiresAt: nil, subscriptionType: nil))),
            fetcher: FakeFetcher(status: 401),
            defaults: defaults
        )
        unauthorized.popoverDidOpen()
        spin(0.2)
        XCTAssertEqual(unauthorized.claude, .failed(.signInExpired))
    }

    func testOptionsTurnProvidersOff() {
        defaults.set(false, forKey: ModuleOption.claudeUsage.key)
        let credentials = FakeCredentialsReader(.failure(.notFound))
        let module = AIUsageModule(codexReader: FakeCodexReader(nil), credentialsReader: credentials, fetcher: FakeFetcher(), defaults: defaults)
        module.popoverDidOpen()
        spin(0.2)
        XCTAssertEqual(module.claude, .off)
        XCTAssertEqual(credentials.reads, 0)
        XCTAssertEqual(module.enabledProviders, [.codex])
    }

    func testRenderAIUsageDetail() throws {
        let credentials = FakeCredentialsReader(.success(ClaudeCredentials(accessToken: "t", expiresAt: nil, subscriptionType: "max")))
        var codexUsage = CodexUsageParser.parse(lines: [Substring(Self.codexLine)])!
        codexUsage.windows = [
            UsageWindow(kind: .session, usedFraction: 0.82, resetsAt: Date().addingTimeInterval(5_000)),
            UsageWindow(kind: .weekly, usedFraction: 0.23, resetsAt: Date().addingTimeInterval(300_000)),
        ]
        codexUsage.measuredAt = Date().addingTimeInterval(-240)
        let body = Data("""
        {"five_hour":{"utilization":34,"resets_at":"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(7_900)))"},
         "seven_day":{"utilization":93,"resets_at":"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(200_000)))"}}
        """.utf8)
        let module = AIUsageModule(codexReader: FakeCodexReader(codexUsage), credentialsReader: credentials, fetcher: FakeFetcher(body: body), defaults: defaults)
        module.popoverDidOpen()
        spin(0.3)
        let claudeOnly = UserDefaults(suiteName: "AIUsageTests-single-\(UUID().uuidString)")!
        claudeOnly.set(false, forKey: ModuleOption.codexUsage.key)
        let single = AIUsageModule(codexReader: FakeCodexReader(nil), credentialsReader: credentials, fetcher: FakeFetcher(body: Data("""
        {"five_hour":{"utilization":32,"resets_at":"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(8_100)))"},
         "seven_day":{"utilization":54,"resets_at":"\(ISO8601DateFormatter().string(from: Date().addingTimeInterval(200_000)))"}}
        """.utf8)), defaults: claudeOnly)
        single.popoverDidOpen()
        spin(0.3)
        let view = VStack(spacing: 6) {
            AIUsageStatusRow(module: single, onActivate: {})
            AIUsageStatusRow(module: module, onActivate: {})
            AIUsageDetailView(module: module)
        }
        .padding(12)
        .frame(width: 304)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .dark)
        let hostingView = NSHostingView(rootView: view)
        hostingView.appearance = NSAppearance(named: .darkAqua)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        let representation = try XCTUnwrap(hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds))
        hostingView.cacheDisplay(in: hostingView.bounds, to: representation)
        let png = try XCTUnwrap(representation.representation(using: .png, properties: [:]))
        try png.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("DuoBarPlus-Detail-aiUsage.png"), options: .atomic)
        module.popoverDidClose()
    }

    private func spin(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
}
