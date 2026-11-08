import Foundation

/// System module: CPU, memory, pressure, swap, load, thermal state and uptime.
///
/// Sampling runs only while the popover is open, every `interval` seconds.
/// The main row needs CPU, memory and pressure; per-core usage, swap and load
/// are read only while the detail view is open. The thermal state is
/// event-driven via `thermalStateDidChangeNotification`.
@MainActor
final class SystemModule: ObservableObject, StatusModule {
    let id: ModuleID = .system

    @Published private(set) var cpu: CPUUsage?
    @Published private(set) var memory: MemoryBreakdown?
    @Published private(set) var pressure: MemoryPressure?
    @Published private(set) var swap: SwapUsage?
    @Published private(set) var load: LoadAverage?
    @Published private(set) var thermalState: ProcessInfo.ThermalState = .nominal
    @Published private(set) var bootTime: Date?
    /// Top processes, sampled every `processInterval` seconds while the
    /// details are open and the "Top processes" option is on.
    @Published private(set) var topProcesses: TopProcessResult?

    /// Readings for the CPU graph in the details; filled while the popover is open.
    let cpuHistory = CPUHistory()

    let coreKinds: [CPUCoreKind]
    /// Static facts and MDM status, loaded once when "This Mac" is first expanded.
    let infoProvider: SystemInfoProvider
    var hasCoreKinds: Bool { coreKinds.contains(.efficiency) && coreKinds.contains(.performance) }

    private let reader: any SystemStatsReading
    private let interval: TimeInterval
    /// Faster sampling while the details (and their live graph) are open.
    private let detailInterval: TimeInterval
    private var isRepeating = false
    private let firstSampleDelay: TimeInterval
    private var timer: Timer?
    private var thermalObserver: NSObjectProtocol?
    private var previousTicks: [CPUCoreTicks]?
    private(set) var isDetailOpen = false

    private let processSampler: TopProcessSampler
    private let processQueue = DispatchQueue(label: "DuoBarPlus.TopProcesses", qos: .utility)
    private let processInterval: TimeInterval
    private let defaults: UserDefaults
    private var processTimer: Timer?
    private var processGeneration = 0

    init(
        reader: any SystemStatsReading = SystemStatsReader(),
        infoProvider: SystemInfoProvider? = nil,
        processSampler: TopProcessSampler = TopProcessSampler(),
        defaults: UserDefaults = .standard,
        interval: TimeInterval = 2,
        detailInterval: TimeInterval = 1,
        firstSampleDelay: TimeInterval = 0.5,
        processInterval: TimeInterval = 3
    ) {
        self.reader = reader
        self.infoProvider = infoProvider ?? SystemInfoProvider()
        self.processSampler = processSampler
        self.defaults = defaults
        self.interval = interval
        self.detailInterval = min(detailInterval, interval)
        self.firstSampleDelay = firstSampleDelay
        self.processInterval = processInterval
        coreKinds = reader.coreKinds()
    }

    var isSampling: Bool { timer != nil }
    var isSamplingProcesses: Bool { processTimer != nil }
    var activeWork: [String] {
        (isSampling ? ["sampling timer"] : []) + (isSamplingProcesses ? ["process timer"] : []) + (thermalObserver == nil ? [] : ["thermal observer"])
    }
    var showsTopProcesses: Bool { ModuleOption.topProcesses.isEnabled(in: defaults) }

    func popoverDidOpen() {
        guard timer == nil else { return }
        bootTime = bootTime ?? reader.bootTime()
        thermalState = reader.thermalState()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.thermalState = self.reader.thermalState()
            }
        }

        // CPU usage needs two tick samples; take the first now and a short
        // second one so the row shows a number almost immediately.
        sample()
        let first = Timer(timeInterval: firstSampleDelay, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.sampleAndScheduleRepeating() }
        }
        timer = first
        RunLoop.main.add(first, forMode: .common)
    }

    func popoverDidClose() {
        isDetailOpen = false
        stopProcessSampling()
        stopSampling()
    }

    func detailDidOpen() {
        isDetailOpen = true
        guard timer != nil else { return }
        sampleDetail()
        startProcessSampling()
        rescheduleRepeatingIfNeeded()
    }

    func detailDidClose() {
        isDetailOpen = false
        stopProcessSampling()
        rescheduleRepeatingIfNeeded()
    }

    var currentInterval: TimeInterval { isDetailOpen ? detailInterval : interval }

    func deactivate() {
        isDetailOpen = false
        stopProcessSampling()
        stopSampling()
    }

    /// One sampling pass. Internal so tests can drive it without timers.
    func sample() {
        if let ticks = reader.cpuTicks() {
            if let previousTicks, let usage = CPUUsage.compute(previous: previousTicks, current: ticks, kinds: coreKinds) {
                cpu = usage
                cpuHistory.append(usage.total)
            }
            previousTicks = ticks
        }
        if let pages = reader.vmPageCounts() {
            memory = MemoryBreakdown(pages: pages, totalBytes: reader.physicalMemory())
        }
        pressure = reader.memoryPressureLevel().flatMap(MemoryPressure.init(sysctlLevel:))
        if isDetailOpen {
            sampleDetail()
        }
    }

    private func sampleDetail() {
        swap = reader.swapUsage()
    }

    private func startProcessSampling() {
        guard processTimer == nil, showsTopProcesses else { return }
        processGeneration += 1
        // A baseline now, a first CPU reading after one second, then every
        // `processInterval` seconds.
        sampleProcesses()
        let first = Timer(timeInterval: min(1, processInterval), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.processTimer != nil else { return }
                self.sampleProcesses()
                let repeating = Timer(timeInterval: self.processInterval, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.sampleProcesses() }
                }
                repeating.tolerance = self.processInterval * 0.2
                self.processTimer = repeating
                RunLoop.main.add(repeating, forMode: .common)
            }
        }
        processTimer = first
        RunLoop.main.add(first, forMode: .common)
    }

    private func sampleProcesses() {
        guard showsTopProcesses else {
            stopProcessSampling()
            topProcesses = nil
            return
        }
        let generation = processGeneration
        let sampler = processSampler
        processQueue.async { [weak self] in
            let result = sampler.sample()
            DispatchQueue.main.async {
                guard let self, self.processGeneration == generation, self.processTimer != nil else { return }
                self.topProcesses = result
            }
        }
    }

    private func stopProcessSampling() {
        processTimer?.invalidate()
        processTimer = nil
        processGeneration += 1
        let sampler = processSampler
        processQueue.async { sampler.reset() }
    }

    private func sampleAndScheduleRepeating() {
        guard timer != nil else { return }
        sample()
        scheduleRepeating()
    }

    private func scheduleRepeating() {
        let interval = currentInterval
        let repeating = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.sample() }
        }
        repeating.tolerance = interval * 0.2
        timer?.invalidate()
        timer = repeating
        isRepeating = true
        RunLoop.main.add(repeating, forMode: .common)
    }

    /// Switches the repeating timer between the row and detail intervals.
    private func rescheduleRepeatingIfNeeded() {
        guard isRepeating, let timer, abs(timer.timeInterval - currentInterval) > 0.001 else { return }
        scheduleRepeating()
    }

    private func stopSampling() {
        timer?.invalidate()
        timer = nil
        isRepeating = false
        previousTicks = nil
        cpuHistory.clear()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
            self.thermalObserver = nil
        }
    }

    deinit {
        timer?.invalidate()
        processTimer?.invalidate()
        if let thermalObserver {
            NotificationCenter.default.removeObserver(thermalObserver)
        }
    }
}
