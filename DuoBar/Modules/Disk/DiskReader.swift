import AppKit
import Foundation

/// One mounted volume. Free space uses "important usage", which counts
/// purgeable space as available, so the numbers match Finder.
struct VolumeInfo: Equatable, Identifiable, Sendable {
    let path: String
    let name: String
    let totalBytes: Int64
    let availableBytes: Int64
    let isStartup: Bool
    let isInternal: Bool
    let isEjectable: Bool
    let isNetwork: Bool

    var id: String { path }

    var usedBytes: Int64 { max(totalBytes - availableBytes, 0) }

    /// 0…1, or nil when the volume reports no capacity.
    var usedFraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(max(Double(usedBytes) / Double(totalBytes), 0), 1)
    }

    /// External or network volumes, which the "External volumes" option controls.
    var isExternal: Bool { !isStartup && (!isInternal || isNetwork) }

    /// External drives and removable media; never the startup or a fixed internal volume.
    var canUnmount: Bool { !isStartup && (isExternal || isEjectable) }
}

protocol VolumeActing: Sendable {
    /// Unmounts this volume only; other volumes on the same disk stay mounted.
    func unmount(path: String, completion: @escaping @Sendable (Error?) -> Void)
    func openInFinder(path: String)
}

struct VolumeActions: VolumeActing {
    func unmount(path: String, completion: @escaping @Sendable (Error?) -> Void) {
        FileManager.default.unmountVolume(at: URL(fileURLWithPath: path, isDirectory: true), options: [.withoutUI], completionHandler: completion)
    }

    func openInFinder(path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }
}

protocol DiskReading: Sendable {
    func startupVolume() -> VolumeInfo?
    func mountedVolumes() -> [VolumeInfo]
}

struct DiskReader: DiskReading {
    private static let keys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeLocalizedNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey,
        .volumeIsInternalKey,
        .volumeIsEjectableKey,
        .volumeIsRemovableKey,
        .volumeIsLocalKey,
        .volumeIsRootFileSystemKey,
        .volumeIsBrowsableKey,
    ]

    func startupVolume() -> VolumeInfo? {
        Self.volume(at: URL(fileURLWithPath: "/", isDirectory: true))
    }

    func mountedVolumes() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Self.keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return DiskVolumeList.sorted(urls.compactMap(Self.volume(at:)))
    }

    static func volume(at url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        if values.volumeIsBrowsable == false { return nil }
        guard let total = values.volumeTotalCapacity, total > 0 else { return nil }

        // Network and some external volumes do not report important-usage capacity.
        let available: Int64
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            available = important
        } else {
            available = Int64(values.volumeAvailableCapacity ?? 0)
        }

        let isStartup = values.volumeIsRootFileSystem ?? (url.path == "/")
        return VolumeInfo(
            path: url.path,
            name: values.volumeLocalizedName ?? values.volumeName ?? url.lastPathComponent,
            totalBytes: Int64(total),
            availableBytes: min(available, Int64(total)),
            isStartup: isStartup,
            isInternal: values.volumeIsInternal ?? isStartup,
            isEjectable: (values.volumeIsEjectable ?? false) || (values.volumeIsRemovable ?? false),
            isNetwork: values.volumeIsLocal == false
        )
    }
}

enum DiskVolumeList {
    /// Startup volume first, then internal volumes, then the rest, each by name.
    static func sorted(_ volumes: [VolumeInfo]) -> [VolumeInfo] {
        volumes.sorted { lhs, rhs in
            let left = rank(lhs), right = rank(rhs)
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func filtered(_ volumes: [VolumeInfo], includeExternal: Bool) -> [VolumeInfo] {
        includeExternal ? volumes : volumes.filter { !$0.isExternal }
    }

    private static func rank(_ volume: VolumeInfo) -> Int {
        if volume.isStartup { return 0 }
        if !volume.isExternal { return 1 }
        if !volume.isNetwork { return 2 }
        return 3
    }
}

enum DiskText {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useGB, .useTB, .useMB]
        formatter.includesActualByteCount = false
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func bytes(_ value: Int64) -> String {
        formatter.string(fromByteCount: value)
    }

    static func percent(_ fraction: Double) -> String {
        localized("%d%%", Int((fraction * 100).rounded()))
    }

    /// "245 GB free", with " · 1 external" when drives are plugged in.
    static func summary(_ volume: VolumeInfo, externalCount: Int) -> String {
        let free = localized("%@ free", bytes(volume.availableBytes))
        return externalCount > 0 ? "\(free) · \(localized("%d external", externalCount))" : free
    }

    /// "245 GB free of 994 GB"
    static func freeOfTotal(_ volume: VolumeInfo) -> String {
        localized("%@ free of %@", bytes(volume.availableBytes), bytes(volume.totalBytes))
    }
}
