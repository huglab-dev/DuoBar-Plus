import Foundation

enum AIProvider: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

/// One usage limit, for example the 5-hour or the weekly window.
struct UsageWindow: Equatable, Identifiable, Sendable {
    enum Kind: Equatable, Sendable {
        case session
        case weekly
        case weeklyModel(String)
        case other(minutes: Int)
    }

    var kind: Kind
    /// 0…1 of the limit used.
    var usedFraction: Double
    var resetsAt: Date?

    var id: String {
        switch kind {
        case .session: "session"
        case .weekly: "weekly"
        case .weeklyModel(let name): "weekly-\(name)"
        case .other(let minutes): "other-\(minutes)"
        }
    }

    var title: String {
        switch kind {
        case .session: localized("5-Hour Limit (Session)")
        case .weekly: localized("Weekly Limit (7 Days)")
        case .weeklyModel(let name): localized("Weekly · %@", name)
        case .other(let minutes): localized("%d-Hour Limit", max(minutes / 60, 1))
        }
    }

    static func kind(windowMinutes: Int) -> Kind {
        switch windowMinutes {
        case 300: .session
        case 10_080: .weekly
        default: .other(minutes: windowMinutes)
        }
    }

    /// A window whose reset time has passed has started over.
    func current(at now: Date) -> UsageWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        return UsageWindow(kind: kind, usedFraction: 0, resetsAt: nil)
    }
}

struct ProviderUsage: Equatable, Sendable {
    var provider: AIProvider
    var windows: [UsageWindow]
    var plan: String?
    /// When the numbers were measured (Codex: the session log entry).
    var measuredAt: Date

    var session: UsageWindow? { windows.first { $0.kind == .session } }

    /// The most used window, for the main row.
    var highest: UsageWindow? { windows.max { $0.usedFraction < $1.usedFraction } }
}

enum AIUsageProblem: Equatable, Sendable {
    case notSignedIn
    /// The date the saved sign-in ran out, when known.
    case signInExpired(Date?)
    case keychainDenied
    case noSessions
    case network(String)
    case server(Int)
    case unreadable

    var isSignInExpired: Bool {
        if case .signInExpired = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .notSignedIn: localized("No Claude Code sign-in found. Sign in with Claude Code first.")
        case .signInExpired(let date):
            if let date {
                localized("The Claude Code sign-in expired on %@. Open Claude Code, for example by running claude in Terminal, then press Refresh.", AIUsageText.dateTime(date))
            } else {
                localized("The Claude Code sign-in has expired. Open Claude Code, for example by running claude in Terminal, then press Refresh.")
            }
        case .keychainDenied: localized("Keychain access was denied. Allow DuoBar+ to read “Claude Code-credentials”.")
        case .noSessions: localized("No Codex sessions with usage limits on this Mac yet.")
        case .network(let detail): localized("Could not reach Anthropic: %@", detail)
        case .server(let code): code == 429 ? localized("Anthropic is rate limiting; try again in a minute.") : localized("Anthropic answered with error %d.", code)
        case .unreadable: localized("The usage data could not be read.")
        }
    }
}

enum ProviderUsageState: Equatable, Sendable {
    case off
    case loading
    case ready(ProviderUsage)
    case failed(AIUsageProblem)

    var usage: ProviderUsage? {
        if case .ready(let usage) = self { return usage }
        return nil
    }

    var problem: AIUsageProblem? {
        if case .failed(let problem) = self { return problem }
        return nil
    }
}

enum AIUsageText {
    static func percent(_ fraction: Double) -> String {
        localized("%d%%", Int((min(max(fraction, 0), 1) * 100).rounded()))
    }

    /// "Resets in 42 min", "Resets in 3 h 12 min", "Resets Mon 14:00".
    static func reset(_ date: Date?, now: Date = Date(), locale: Locale = .current) -> String? {
        guard let date else { return nil }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return localized("Resets now") }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return localized("Resets in %d min", minutes) }
        if minutes < 24 * 60 { return localized("Resets in %d h %d min", minutes / 60, minutes % 60) }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("EEE HH:mm")
        return localized("Resets %@", formatter.string(from: date))
    }

    /// "2 h 14 min", "42 min" for the main row.
    static func compactDuration(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded(.up)), 0)
        if minutes < 60 { return localized("%d min", minutes) }
        return localized("%d h %d min", minutes / 60, minutes % 60)
    }

    /// "9 Nov 2026 at 03:14" in the user's format.
    static func dateTime(_ date: Date, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// "Updated 3 min ago" for data read from logs.
    static func age(_ date: Date, now: Date = Date()) -> String {
        let minutes = Int(max(now.timeIntervalSince(date), 0) / 60)
        if minutes < 1 { return localized("Updated just now") }
        if minutes < 60 { return localized("Updated %d min ago", minutes) }
        if minutes < 24 * 60 { return localized("Updated %d h ago", minutes / 60) }
        return localized("Updated %d d ago", minutes / (24 * 60))
    }

    static func plan(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }
}

// MARK: - Parsing

enum ClaudeUsageParser {
    /// Parses `/api/oauth/usage`: objects such as `five_hour` and `seven_day`
    /// with `utilization` (0–100) and `resets_at` (ISO 8601, may be null).
    static func parse(_ data: Data, measuredAt: Date, plan: String?) -> ProviderUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let keys: [(String, UsageWindow.Kind)] = [
            ("five_hour", .session),
            ("seven_day", .weekly),
            ("seven_day_opus", .weeklyModel("Opus")),
            ("seven_day_sonnet", .weeklyModel("Sonnet")),
        ]
        var windows: [UsageWindow] = []
        for (key, kind) in keys {
            guard let entry = object[key] as? [String: Any],
                  let utilization = (entry["utilization"] as? NSNumber)?.doubleValue else { continue }
            windows.append(UsageWindow(kind: kind, usedFraction: min(max(utilization / 100, 0), 1), resetsAt: date(entry["resets_at"])))
        }
        guard !windows.isEmpty else { return nil }
        return ProviderUsage(provider: .claude, windows: windows, plan: plan, measuredAt: measuredAt)
    }

    static func date(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }
}

enum CodexUsageParser {
    /// The newest `token_count` event with `rate_limits` in a session log.
    static func parse(lines: [Substring]) -> ProviderUsage? {
        for line in lines.reversed() where line.contains("\"rate_limits\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let limits = payload["rate_limits"] as? [String: Any] else { continue }
            var windows: [UsageWindow] = []
            for key in ["primary", "secondary"] {
                guard let entry = limits[key] as? [String: Any],
                      let used = (entry["used_percent"] as? NSNumber)?.doubleValue else { continue }
                let minutes = (entry["window_minutes"] as? NSNumber)?.intValue ?? 0
                let resets = (entry["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                windows.append(UsageWindow(kind: UsageWindow.kind(windowMinutes: minutes), usedFraction: min(max(used / 100, 0), 1), resetsAt: resets))
            }
            guard !windows.isEmpty else { continue }
            let measured = ClaudeUsageParser.date(object["timestamp"]) ?? Date()
            return ProviderUsage(provider: .codex, windows: windows, plan: limits["plan_type"] as? String, measuredAt: measured)
        }
        return nil
    }
}
