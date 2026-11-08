import Foundation
import IOKit
import SystemConfiguration

/// Facts that do not change while the app runs.
struct SystemInfo: Equatable, Sendable {
    var osVersion: String
    var model: String?
    var chip: String?
    var memoryBytes: UInt64
    var serialNumber: String?
    var computerName: String?
}

/// Parsed `profiles status -type enrollment`.
struct MDMStatus: Equatable, Sendable {
    var isEnrolled: Bool
    var enrolledViaDEP: Bool
    /// The enrollment value as printed, e.g. "Yes (User Approved)".
    var enrollmentDetail: String?
    var serverHost: String?

    static let notEnrolled = MDMStatus(isEnrolled: false, enrolledViaDEP: false, enrollmentDetail: nil, serverHost: nil)

    /// Tolerant line parser; unknown lines are ignored. Returns nil when the
    /// output contains neither known line, so the UI can show "Unknown".
    static func parse(_ output: String) -> MDMStatus? {
        var enrollment: String?
        var dep: String?
        var server: String?
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0].lowercased() {
            case "mdm enrollment": enrollment = parts[1]
            case "enrolled via dep": dep = parts[1]
            case "mdm server": server = parts[1]
            default: continue
            }
        }
        guard enrollment != nil || dep != nil else { return nil }
        let isEnrolled = enrollment?.lowercased().hasPrefix("yes") ?? false
        let viaDEP = dep?.lowercased().hasPrefix("yes") ?? false
        return MDMStatus(
            isEnrolled: isEnrolled || viaDEP,
            enrolledViaDEP: viaDEP,
            enrollmentDetail: enrollment,
            serverHost: server.flatMap { URL(string: $0)?.host ?? $0 }
        )
    }
}

protocol SystemInfoReading: Sendable {
    func systemInfo() -> SystemInfo
    func mdmStatus() -> MDMStatus?
}

struct SystemInfoReader: SystemInfoReading {
    var profilesTimeout: TimeInterval = 5

    func systemInfo() -> SystemInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var versionText = "macOS \(version.majorVersion).\(version.minorVersion)"
        if version.patchVersion > 0 { versionText += ".\(version.patchVersion)" }
        if let build = SystemStatsReader.sysctlString("kern.osversion") { versionText += " (\(build))" }

        return SystemInfo(
            osVersion: versionText,
            model: SystemStatsReader.sysctlString("hw.model"),
            chip: SystemStatsReader.sysctlString("machdep.cpu.brand_string"),
            memoryBytes: ProcessInfo.processInfo.physicalMemory,
            serialNumber: Self.serialNumber(),
            computerName: SCDynamicStoreCopyComputerName(nil, nil) as String?
        )
    }

    func mdmStatus() -> MDMStatus? {
        guard let output = Self.run("/usr/bin/profiles", ["status", "-type", "enrollment"], timeout: profilesTimeout) else {
            return nil
        }
        return MDMStatus.parse(output)
    }

    private static func serialNumber() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0)
        return value?.takeRetainedValue() as? String
    }

    /// Runs a tool and returns stdout, or nil on failure or timeout.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard finished.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

/// Loads `SystemInfo` and the MDM status once per app launch, off the main
/// thread, the first time the System details are opened.
@MainActor
final class SystemInfoProvider: ObservableObject {
    @Published private(set) var info: SystemInfo?
    @Published private(set) var mdm: MDMStatus?
    @Published private(set) var hasLoadedMDM = false

    private let reader: any SystemInfoReading
    private var hasStarted = false

    init(reader: any SystemInfoReading = SystemInfoReader()) {
        self.reader = reader
    }

    func loadIfNeeded() {
        guard !hasStarted else { return }
        hasStarted = true
        let reader = reader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let info = reader.systemInfo()
            DispatchQueue.main.async { self?.info = info }
            let mdm = reader.mdmStatus()
            DispatchQueue.main.async {
                self?.mdm = mdm
                self?.hasLoadedMDM = true
            }
        }
    }
}
