import AppKit
import SwiftUI

/// Main-view row: "CPU 13% · Memory 64%".
struct SystemStatusRow: View {
    @ObservedObject var module: SystemModule
    let onActivate: () -> Void
    @AppStorage(ModuleOption.memoryPressureWarning.key) private var showsPressureWarning = ModuleOption.memoryPressureWarning.defaultValue

    var body: some View {
        StatusRow(
            symbol: "gearshape",
            title: localized("System"),
            detail: SystemText.summary(cpu: module.cpu, memory: module.memory),
            speedText: pressureText,
            speedTint: pressureTint,
            speedSymbol: pressureText == nil ? nil : "exclamationmark.triangle.fill",
            stateText: "",
            tint: .primary,
            accessory: .disclosure,
            onActivate: onActivate,
            activationHint: localized("Show details")
        )
    }

    private var pressureTint: Color? {
        guard showsPressureWarning else { return nil }
        switch module.pressure {
        case .warning?: return Color(nsColor: .systemYellow)
        case .critical?: return Color(nsColor: .systemRed)
        default: return nil
        }
    }

    /// Only shown when memory pressure needs attention.
    private var pressureText: String? {
        guard showsPressureWarning, let pressure = module.pressure, pressure != .normal else { return nil }
        return SystemText.pressure(pressure)
    }
}

struct SystemDetailView: View {
    @ObservedObject var module: SystemModule
    let onOpenActivityMonitor: () -> Void
    @State private var showsMemoryBreakdown = false

    /// Yellow for warning and red for critical, as on the System row.
    private var pressureTint: Color? {
        switch module.pressure {
        case .warning?: Color(nsColor: .systemYellow)
        case .critical?: Color(nsColor: .systemRed)
        default: nil
        }
    }

    var body: some View {
        DetailSectionHeader(title: localized("CPU"))
        CPUGraphTile(
            history: module.cpuHistory,
            value: module.cpu.map { SystemText.percent($0.total) } ?? "–",
            caption: coreCaption
        )
        if let bootTime = module.bootTime {
            DetailValueRow(label: localized("Uptime"), value: SystemText.uptime(Date().timeIntervalSince(bootTime)))
        }

        DetailSectionHeader(title: localized("Memory"))
        if let memory = module.memory {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { showsMemoryBreakdown.toggle() }
            } label: {
                MeterTile(
                    title: localized("Used"),
                    value: localized("%@ of %@", SystemText.memory(memory.usedBytes), SystemText.memory(memory.totalBytes)),
                    fraction: memory.usedFraction,
                    caption: module.pressure.map { localized("Pressure: %@", SystemText.pressure($0)) },
                    captionTint: pressureTint,
                    captionSymbol: pressureTint == nil ? nil : "exclamationmark.triangle.fill",
                    isExpanded: showsMemoryBreakdown
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint(localized("Show memory details"))
            if showsMemoryBreakdown {
                DetailValueRow(label: localized("App Memory"), value: SystemText.memory(memory.appBytes))
                DetailValueRow(label: localized("Wired Memory"), value: SystemText.memory(memory.wiredBytes))
                DetailValueRow(label: localized("Compressed"), value: SystemText.memory(memory.compressedBytes))
                DetailValueRow(label: localized("Cached Files"), value: SystemText.memory(memory.cachedBytes))
            }
        }
        if let swap = module.swap {
            DetailValueRow(
                label: localized("Swap Used"),
                value: swap.totalBytes > 0
                    ? localized("%@ of %@", SystemText.memory(swap.usedBytes), SystemText.memory(swap.totalBytes))
                    : localized("None")
            )
        }

        if module.showsTopProcesses {
            TopProcessesSection(result: module.topProcesses)
        }

        SystemInfoSection(provider: module.infoProvider)

        DetailActionRow(title: localized("Open Activity Monitor"), action: onOpenActivityMonitor)
    }

    private var coreCaption: String? {
        guard module.hasCoreKinds, let cpu = module.cpu,
              let efficiency = cpu.efficiency, let performance = cpu.performance else { return nil }
        return localized("P cores %@ · E cores %@", SystemText.percent(performance), SystemText.percent(efficiency))
    }

    static func openActivityMonitor() {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.ActivityMonitor")
            ?? URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct TopProcessesSection: View {
    let result: TopProcessResult?
    @State private var sortsByMemory = false

    var body: some View {
        HStack {
            DetailSectionHeader(title: localized("Top Processes"))
            Picker(localized("Sort by"), selection: $sortsByMemory) {
                Text(localized("CPU")).tag(false)
                Text(localized("Memory")).tag(true)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .controlSize(.mini)
            .fixedSize()
            .padding(.top, 4)
            .padding(.trailing, 8)
        }

        if let result {
            let processes = sortsByMemory ? result.byMemory : result.byCPU
            if processes.isEmpty {
                DetailValueRow(label: localized("Measuring…"), value: "")
            } else {
                ForEach(processes) { process in
                    DetailValueRow(
                        label: process.name,
                        value: sortsByMemory ? SystemText.memory(process.memoryBytes) : TopProcesses.cpuText(process.cpu)
                    )
                }
            }
            if result.readable < result.total {
                Text(localized("Only processes you own are shown (%d of %d).", result.readable, result.total))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        } else {
            DetailValueRow(label: localized("Measuring…"), value: "")
        }
    }
}

struct SystemInfoSection: View {
    @ObservedObject var provider: SystemInfoProvider
    @State private var isExpanded = false

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            if isExpanded { provider.loadIfNeeded() }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 14))
                    .frame(width: 22)
                Text(localized("This Mac"))
                    .font(PopoverDesign.compactTitleFont)
                Spacer(minLength: 8)
                Text(isExpanded ? localized("Hide") : localized("Show"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                RowChevron()
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .padding(.horizontal, PopoverDesign.horizontalPadding)
            .frame(height: PopoverDesign.compactRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
        .accessibilityValue(isExpanded ? localized("Shown") : localized("Hidden"))
        .accessibilityHint(localized("Show model, serial number and MDM status"))

        if isExpanded {
            details
        }
    }

    @ViewBuilder
    private var details: some View {
        if let info = provider.info {
            if let model = info.model {
                DetailValueRow(label: localized("Model"), value: model, isCopyable: true)
            }
            if let chip = info.chip {
                DetailValueRow(label: localized("Chip"), value: chip)
            }
            DetailValueRow(label: localized("Memory"), value: SystemText.memory(info.memoryBytes))
            DetailValueRow(label: localized("macOS"), value: info.osVersion, isCopyable: true)
            if let serial = info.serialNumber {
                DetailValueRow(label: localized("Serial Number"), value: serial, isCopyable: true)
            }
            if let name = info.computerName {
                DetailValueRow(label: localized("Computer Name"), value: name, isCopyable: true)
            }
        } else {
            DetailValueRow(label: localized("Model"), value: localized("Calculating…"))
        }
        DetailValueRow(label: localized("MDM Enrollment"), value: mdmText)
        if let host = provider.mdm?.serverHost {
            DetailValueRow(label: localized("MDM Server"), value: host, isCopyable: true)
        }
    }

    private var mdmText: String {
        guard provider.hasLoadedMDM else { return localized("Calculating…") }
        guard let mdm = provider.mdm else { return localized("Unknown") }
        guard mdm.isEnrolled else { return localized("Not Enrolled") }
        if mdm.enrolledViaDEP { return localized("Enrolled via DEP") }
        if let detail = mdm.enrollmentDetail?.lowercased(), detail.contains("user approved") {
            return localized("Enrolled (User Approved)")
        }
        return localized("Enrolled")
    }
}

/// Small uppercase caption above a group of detail tiles.
struct DetailSectionHeader: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Title, value, a usage bar and an optional caption on one tile.
struct MeterTile: View {
    let title: String
    let value: String
    let fraction: Double
    var caption: String?
    /// Colors the caption, e.g. a memory-pressure warning.
    var captionTint: Color?
    var captionSymbol: String?
    /// nil: not expandable; otherwise shows a chevron that turns when open.
    var isExpanded: Bool?
    var barTint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(PopoverDesign.detailLabelFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(PopoverDesign.detailValueFont)
                    .monospacedDigit()
                    .lineLimit(1)
                if let isExpanded {
                    RowChevron()
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            UsageBar(fraction: fraction, tint: barTint)
            if let caption {
                HStack(spacing: 4) {
                    if let captionSymbol {
                        Image(systemName: captionSymbol)
                            .font(.system(size: 9, weight: .bold))
                    }
                    Text(caption)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.system(size: 10, weight: captionTint == nil ? .regular : .semibold))
                .foregroundStyle(captionTint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
            }
        }
        .contentShape(Rectangle())
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .popoverCardBackground(cornerRadius: 11, fillOpacity: 0.045)
        .accessibilityElement(children: .combine)
    }
}
