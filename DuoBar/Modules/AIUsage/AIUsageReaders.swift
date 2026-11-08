import Foundation
import Security

// MARK: - Codex (local session logs)

protocol CodexUsageReading: Sendable {
    func latestUsage() -> ProviderUsage?
}

/// Reads the limits Codex writes into `~/.codex/sessions/**/rollout-*.jsonl`.
/// Only the tail of the newest few logs is read.
struct CodexUsageReader: CodexUsageReading {
    var sessionsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")
    var filesToTry = 5
    var tailBytes = 512 * 1024

    func latestUsage() -> ProviderUsage? {
        for file in newestLogs() {
            if let usage = CodexUsageParser.parse(lines: tail(of: file)) { return usage }
        }
        return nil
    }

    private func newestLogs() -> [URL] {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: sessionsDirectory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
            return []
        }
        var files: [(URL, Date)] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            files.append((url, values?.contentModificationDate ?? .distantPast))
        }
        return files.sorted { $0.1 > $1.1 }.prefix(filesToTry).map(\.0)
    }

    private func tail(of url: URL) -> [Substring] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return [] }
        var lines = text.split(separator: "\n")
        if start > 0, !lines.isEmpty { lines.removeFirst() } // likely a partial line
        return lines
    }
}

// MARK: - Claude (Claude Code sign-in + Anthropic)

struct ClaudeCredentials: Equatable, Sendable {
    var accessToken: String
    var expiresAt: Date?
    var subscriptionType: String?

    func isExpired(at now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    /// `{"claudeAiOauth": {"accessToken", "expiresAt" (ms), "subscriptionType", …}}`
    static func parse(_ data: Data) -> ClaudeCredentials? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = object["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        let expires = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        return ClaudeCredentials(accessToken: token, expiresAt: expires, subscriptionType: oauth["subscriptionType"] as? String)
    }
}

enum ClaudeCredentialsError: Error, Equatable {
    case notFound
    case denied
}

protocol ClaudeCredentialsReading: Sendable {
    /// May show a Keychain prompt; call off the main thread.
    func read() throws -> ClaudeCredentials
}

/// Claude Code keeps its sign-in in the Keychain item "Claude Code-credentials"
/// (older versions: `~/.claude/.credentials.json`). DuoBar+ only reads it and
/// never refreshes or writes it, so Claude Code's own sign-in is untouched.
struct ClaudeCredentialsReader: ClaudeCredentialsReading {
    static let keychainService = "Claude Code-credentials"
    var fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")

    func read() throws -> ClaudeCredentials {
        if let data = try? Data(contentsOf: fileURL), let credentials = ClaudeCredentials.parse(data) {
            return credentials
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let credentials = ClaudeCredentials.parse(data) else { throw ClaudeCredentialsError.notFound }
            return credentials
        case errSecUserCanceled, errSecAuthFailed, errSecInteractionNotAllowed:
            throw ClaudeCredentialsError.denied
        default:
            throw ClaudeCredentialsError.notFound
        }
    }
}

protocol ClaudeUsageFetching: Sendable {
    /// Returns the HTTP status and body.
    func fetch(accessToken: String) async throws -> (Int, Data)
}

/// `GET https://api.anthropic.com/api/oauth/usage`, the endpoint Claude Code's
/// `/usage` uses. Undocumented, so it may change without notice.
struct ClaudeUsageFetcher: ClaudeUsageFetching {
    static let url = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    func fetch(accessToken: String) async throws -> (Int, Data) {
        var request = URLRequest(url: Self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("DuoBarPlus", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// Sources that never read anything: for tests that exercise every module.
struct InertAIUsageSources: CodexUsageReading, ClaudeCredentialsReading, ClaudeUsageFetching {
    func latestUsage() -> ProviderUsage? { nil }
    func read() throws -> ClaudeCredentials { throw ClaudeCredentialsError.notFound }
    func fetch(accessToken: String) async throws -> (Int, Data) { (0, Data()) }
}
