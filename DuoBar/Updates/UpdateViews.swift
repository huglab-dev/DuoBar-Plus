import SwiftUI

/// Shown at the top of the popover when a newer version is available.
struct UpdateAvailableCard: View {
    let release: AvailableRelease
    let onDownload: () -> Void
    let onSkip: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
            Text(localized("Update available: %@", release.version.description))
                .font(PopoverDesign.compactTitleFont)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 6)
            Button(localized("Download"), action: onDownload)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(Color.primary.opacity(0.1), in: Capsule())
            Button(action: onSkip) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(localized("Skip this version"))
            .accessibilityLabel(localized("Skip this version"))
        }
        .padding(.leading, PopoverDesign.horizontalPadding + 2)
        .padding(.trailing, 7)
        .frame(height: PopoverDesign.compactRowHeight)
        .popoverRowCard(true)
    }
}

/// The Updates section in Settings → General.
struct UpdateSettingsSection: View {
    @ObservedObject var checker: UpdateChecker
    @AppStorage(UpdateChecker.automaticKey) private var checksAutomatically = true

    var body: some View {
        Section(localized("Updates")) {
            LabeledContent(localized("Version"), value: checker.currentVersionText)
            Toggle(localized("Check for updates automatically"), isOn: $checksAutomatically)
            HStack {
                Button(localized("Check Now")) { checker.checkNow() }
                    .disabled(checker.status == .checking)
                Spacer()
                if let release = checker.newerRelease {
                    Button(localized("Download %@", release.version.description)) {
                        checker.openReleasePage(release)
                    }
                } else if let statusText {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusText: String? {
        switch checker.status {
        case .idle: nil
        case .checking: localized("Checking…")
        case .upToDate: localized("DuoBar+ is up to date.")
        case .failed: localized("Could not check for updates.")
        }
    }
}
