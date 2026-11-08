import Foundation

struct AvailableRelease: Equatable, Sendable {
    var version: AppVersion
    var pageURL: URL
}

enum UpdateCheckError: Error, Equatable {
    case network
    case server(Int)
    case unreadable
}

protocol UpdateReleaseReading: Sendable {
    /// The newest published release, or nil when there is none yet.
    func latestRelease() async throws -> AvailableRelease?
}

enum GitHubRelease {
    static let repositoryPath = "/huglab-dev/DuoBar-Plus/"

    /// Reads `tag_name` and `html_url`. A link that does not lead to this
    /// project's page on GitHub is rejected, since the app opens it.
    static func parse(_ data: Data) -> AvailableRelease? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String,
              let version = AppVersion(tag),
              let link = object["html_url"] as? String,
              let url = URL(string: link),
              url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix(repositoryPath) else { return nil }
        return AvailableRelease(version: version, pageURL: url)
    }
}

/// Asks GitHub for the latest release. Reads metadata only; the user downloads
/// the new version from the release page.
struct GitHubReleaseReader: UpdateReleaseReading {
    static let url = URL(string: "https://api.github.com/repos/huglab-dev/DuoBar-Plus/releases/latest")!

    func latestRelease() async throws -> AvailableRelease? {
        var request = URLRequest(url: Self.url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("DuoBarPlus", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.network
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil } // nothing published yet
        guard status == 200 else { throw UpdateCheckError.server(status) }
        guard let release = GitHubRelease.parse(data) else { throw UpdateCheckError.unreadable }
        return release
    }
}
