import Combine
import Foundation

/// Samples the live metrics the indicator slots need, and nothing else.
/// With the standard configuration (Automatic / Wi-Fi / Volume) no metric
/// is needed and no timer runs. CPU, memory and network rate are sampled
/// every `interval` seconds; disk usage every `diskInterval` seconds.
@MainActor
final class GlyphSlotSampler: ObservableObject {
    @Published private(set) var cpu: Double?
    @Published private(set) var memory: Double?
    @Published private(set) var disk: Double?
    @Published private(set) var networkBytesPerSecond: Double?

    private(set) var metrics: Set<GlyphMetric> = []
    private let statsReader: any SystemStatsReading
    private let diskReader: any DiskReading
    private let counterReader: (String) -> InterfaceByteCounters?
    private let interval: TimeInterval
    private let diskInterval: TimeInterval
    private let defaults: UserDefaults
    private var timer: Timer?
    private var lastDiskRead: Date?
    private var previousTicks: [CPUCoreTicks]?
    private var speedCalculator = NetworkSpeedCalculator()
    private var interfaceName: String?
    private var defaultsObserver: NSObjectProtocol?

    init(
        statsReader: any SystemStatsReading = SystemStatsReader(),
        diskReader: any DiskReading = DiskReader(),
        counterReader: @escaping (String) -> InterfaceByteCounters? = NetworkSpeedService.readCounters(for:),
        defaults: UserDefaults = .standard,
        interval: TimeInterval = 2,
        diskInterval: TimeInterval = 60
    ) {
        self.statsReader = statsReader
        self.diskReader = diskReader
        self.counterReader = counterReader
        self.defaults = defaults
        self.interval = interval
        self.diskInterval = diskInterval
    }

    var isSampling: Bool { timer != nil }

    /// Follows the indicator settings from now on.
    func start() {
        reconfigure()
        guard defaultsObserver == nil else { return }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reconfigure() }
        }
    }

    func setInterface(_ name: String?) {
        guard name != interfaceName else { return }
        interfaceName = name
        speedCalculator.reset()
        networkBytesPerSecond = nil
    }

    func reconfigure() {
        configure(GlyphConfiguration(defaults: defaults).neededMetrics)
    }

    func configure(_ metrics: Set<GlyphMetric>) {
        guard metrics != self.metrics || (timer == nil) != metrics.isEmpty else { return }
        self.metrics = metrics
        timer?.invalidate()
        timer = nil
        if !metrics.contains(.cpu) { cpu = nil; previousTicks = nil }
        if !metrics.contains(.memory) { memory = nil }
        if !metrics.contains(.disk) { disk = nil; lastDiskRead = nil }
        if !metrics.contains(.networkRate) { networkBytesPerSecond = nil; speedCalculator.reset() }
        guard !metrics.isEmpty else { return }

        sample()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        timer.tolerance = interval * 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func sample(now: Date = Date()) {
        if metrics.contains(.cpu), let ticks = statsReader.cpuTicks() {
            if let previousTicks, let usage = CPUUsage.compute(previous: previousTicks, current: ticks, kinds: []) {
                cpu = usage.total
            }
            previousTicks = ticks
        }
        if metrics.contains(.memory), let pages = statsReader.vmPageCounts() {
            memory = MemoryBreakdown(pages: pages, totalBytes: statsReader.physicalMemory()).usedFraction
        }
        if metrics.contains(.disk), lastDiskRead.map({ now.timeIntervalSince($0) >= diskInterval }) ?? true {
            disk = diskReader.startupVolume()?.usedFraction
            lastDiskRead = now
        }
        if metrics.contains(.networkRate) {
            let counters = interfaceName.flatMap(counterReader)
            if let speed = speedCalculator.update(interface: interfaceName, counters: counters, at: ProcessInfo.processInfo.systemUptime) {
                networkBytesPerSecond = speed.downloadBytesPerSecond + speed.uploadBytesPerSecond
            }
        }
    }

    deinit {
        timer?.invalidate()
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
    }
}
