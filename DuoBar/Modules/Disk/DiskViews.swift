import SwiftUI

/// Main-view row for the startup volume: "245 GB free" and the used percentage.
struct DiskStatusRow: View {
    @ObservedObject var module: DiskModule
    let onActivate: () -> Void

    var body: some View {
        StatusRow(
            symbol: "internaldrive",
            title: localized("Disk"),
            detail: detail,
            // StatusRow's stateText gets no width next to its flexible title
            // column, so the percentage uses the right-aligned speed slot.
            speedText: usedText,
            stateText: "",
            tint: .primary,
            accessory: .disclosure,
            onActivate: onActivate,
            activationHint: localized("Show details")
        )
    }

    private var detail: String {
        guard let volume = module.startupVolume else { return localized("Calculating…") }
        // The row always describes the startup volume; its name is in the detail view.
        return DiskText.summary(volume, externalCount: module.connectedExternalCount)
    }

    private var usedText: String? {
        module.startupVolume?.usedFraction.map(DiskText.percent)
    }
}

struct DiskDetailView: View {
    @ObservedObject var module: DiskModule
    let onOpenSettings: () -> Void
    /// Called after a drive was opened in Finder, so the popover can close.
    var onDidOpenVolume: () -> Void = {}
    @AppStorage(ModuleOption.externalVolumes.key) private var includesExternal = ModuleOption.externalVolumes.defaultValue

    var body: some View {
        let volumes = DiskVolumeList.filtered(module.volumes, includeExternal: includesExternal)

        if volumes.isEmpty {
            if let startup = module.startupVolume {
                tile(startup)
            } else {
                DetailValueRow(label: localized("Status"), value: localized("Calculating…"))
            }
        } else {
            ForEach(volumes) { volume in
                tile(volume)
            }
        }

        if let error = module.errorMessage {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(Color(nsColor: .systemRed))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
        }

        DetailActionRow(title: localized("Open Storage Settings"), action: onOpenSettings)
    }

    private func tile(_ volume: VolumeInfo) -> some View {
        VolumeTile(
            volume: volume,
            isUnmounting: module.unmountingPaths.contains(volume.path),
            onOpen: {
                module.openInFinder(volume)
                onDidOpenVolume()
            },
            onUnmount: { module.unmount(volume) }
        )
    }
}

struct VolumeTile: View {
    let volume: VolumeInfo
    let isUnmounting: Bool
    let onOpen: () -> Void
    let onUnmount: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpen) {
                HStack(spacing: 11) {
                    IconTile(symbol: symbol)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(volume.name)
                                .font(PopoverDesign.titleFont)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: "arrow.up.forward.app")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.tertiary)
                            Spacer(minLength: 6)
                            if let fraction = volume.usedFraction {
                                ValueBadge(text: DiskText.percent(fraction))
                            }
                        }
                        UsageBar(fraction: volume.usedFraction ?? 0)
                        Text(DiskText.freeOfTotal(volume))
                            .font(PopoverDesign.subtitleFont)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(localized("Open in Finder"))
            .accessibilityElement(children: .combine)
            .accessibilityHint(localized("Open in Finder"))

            if volume.canUnmount {
                unmountButton
            }
        }
        .padding(.horizontal, PopoverDesign.horizontalPadding)
        .padding(.vertical, 9)
        .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
    }

    @ViewBuilder
    private var unmountButton: some View {
        if isUnmounting {
            ProgressView()
                .controlSize(.small)
                .frame(width: 26, height: 26)
        } else {
            Button(action: onUnmount) {
                Image(systemName: "eject.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.primary.opacity(0.1), in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help(localized("Unmount %@", volume.name))
            .accessibilityLabel(localized("Unmount %@", volume.name))
        }
    }

    private var symbol: String {
        if volume.isNetwork { return "server.rack" }
        return volume.isExternal ? "externaldrive" : "internaldrive"
    }
}

/// Thin capsule bar, monochrome like the rest of the popover.
struct UsageBar: View {
    let fraction: Double
    /// DuoBar+: a state color, e.g. near a limit.
    var tint: Color?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.12))
                Capsule()
                    .fill(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.primary.opacity(0.75)))
                    .frame(width: max(proxy.size.width * min(max(fraction, 0), 1), fraction > 0 ? 3 : 0))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
