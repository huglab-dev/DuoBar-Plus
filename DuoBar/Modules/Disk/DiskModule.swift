import AppKit
import Foundation

/// Disk module. Reads the startup volume and the mounted volumes when the
/// popover opens, and follows mounts while the detail view is open. Nothing
/// runs otherwise:
/// no timers, and mount notifications only while the detail view is visible.
@MainActor
final class DiskModule: ObservableObject, StatusModule {
    let id: ModuleID = .disk

    @Published private(set) var startupVolume: VolumeInfo?
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var hasLoadedVolumes = false
    @Published private(set) var unmountingPaths: Set<String> = []
    @Published private(set) var errorMessage: String?

    private let reader: any DiskReading
    private let actions: any VolumeActing
    private let defaults: UserDefaults
    private let queue = DispatchQueue(label: "DuoBarPlus.DiskModule", qos: .userInitiated)
    private let notificationCenter: NotificationCenter
    private var mountObservers: [NSObjectProtocol] = []
    /// Bumped whenever reads should be discarded, for example after closing.
    private var generation = 0
    private var isDetailOpen = false

    init(
        reader: any DiskReading = DiskReader(),
        actions: any VolumeActing = VolumeActions(),
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.reader = reader
        self.actions = actions
        self.defaults = defaults
        self.notificationCenter = notificationCenter
    }

    var includesExternalVolumes: Bool {
        ModuleOption.externalVolumes.isEnabled(in: defaults)
    }

    /// The volumes the detail view shows, honoring the "External volumes" option.
    var visibleVolumes: [VolumeInfo] {
        DiskVolumeList.filtered(volumes, includeExternal: includesExternalVolumes)
    }

    /// Drives plugged into this Mac, for the main row. Network volumes do not count.
    var connectedExternalCount: Int {
        visibleVolumes.filter { $0.isExternal && !$0.isNetwork }.count
    }

    var isObservingMounts: Bool { !mountObservers.isEmpty }
    var activeWork: [String] { isObservingMounts ? ["mount observers"] : [] }

    func popoverDidOpen() {
        generation += 1
        let generation = generation
        let reader = reader
        queue.async { [weak self] in
            let volume = reader.startupVolume()
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.startupVolume = volume
            }
        }
        // A separate step, so a slow network volume cannot delay the numbers above.
        queue.async { [weak self] in
            let volumes = reader.mountedVolumes()
            DispatchQueue.main.async {
                guard let self, self.generation == generation else { return }
                self.volumes = volumes
            }
        }
    }

    func popoverDidClose() {
        generation += 1
    }

    func detailDidOpen() {
        isDetailOpen = true
        reloadVolumes()
        let names: [Notification.Name] = [
            NSWorkspace.didMountNotification,
            NSWorkspace.didUnmountNotification,
            NSWorkspace.didRenameVolumeNotification,
        ]
        mountObservers = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.reloadVolumes()
                }
            }
        }
    }

    func detailDidClose() {
        isDetailOpen = false
        errorMessage = nil
        removeMountObservers()
    }

    func openInFinder(_ volume: VolumeInfo) {
        actions.openInFinder(path: volume.path)
    }

    func unmount(_ volume: VolumeInfo) {
        guard volume.canUnmount, !unmountingPaths.contains(volume.path) else { return }
        unmountingPaths.insert(volume.path)
        errorMessage = nil
        actions.unmount(path: volume.path) { [weak self] error in
            let failed = error != nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.unmountingPaths.remove(volume.path)
                if failed {
                    self.errorMessage = localized("Could not unmount %@. A file on it may be in use.", volume.name)
                }
                self.reloadVolumes()
            }
        }
    }

    func deactivate() {
        generation += 1
        isDetailOpen = false
        removeMountObservers()
    }

    private func reloadVolumes() {
        guard isDetailOpen else { return }
        let generation = generation
        let reader = reader
        queue.async { [weak self] in
            let volumes = reader.mountedVolumes()
            let startup = volumes.first(where: \.isStartup) ?? reader.startupVolume()
            DispatchQueue.main.async {
                guard let self, self.generation == generation, self.isDetailOpen else { return }
                self.volumes = volumes
                self.startupVolume = startup
                self.hasLoadedVolumes = true
            }
        }
    }

    private func removeMountObservers() {
        mountObservers.forEach(notificationCenter.removeObserver)
        mountObservers = []
    }

    deinit {
        mountObservers.forEach(notificationCenter.removeObserver)
    }
}
