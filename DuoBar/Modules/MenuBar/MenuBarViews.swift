import AppKit
import SwiftUI

enum MenuBarText {
    static func summary(state: MenuBarModule.State, hiddenCount: Int) -> String {
        switch state {
        case .checking: localized("Checking…")
        case .needsAccess: localized("Needs Accessibility access")
        case .noNotch: localized("No notch on this display")
        case .ready:
            switch hiddenCount {
            case 0: localized("All items are visible")
            case 1: localized("1 item hidden by the notch")
            default: localized("%d items hidden by the notch", hiddenCount)
            }
        }
    }
}

/// Main-view row: how many menu bar items the notch hides.
struct MenuBarStatusRow: View {
    @ObservedObject var module: MenuBarModule
    let onActivate: () -> Void

    var body: some View {
        StatusRow(
            symbol: "menubar.rectangle",
            title: localized("Menu Bar Items"),
            detail: MenuBarText.summary(state: module.state, hiddenCount: module.hiddenItems.count),
            speedText: module.state == .ready && !module.hiddenItems.isEmpty ? "\(module.hiddenItems.count)" : nil,
            speedTint: module.hiddenItems.isEmpty ? nil : Color(nsColor: .systemOrange),
            stateText: "",
            tint: .primary,
            accessory: .disclosure,
            onActivate: onActivate,
            activationHint: localized("Show details")
        )
    }
}

struct MenuBarDetailView: View {
    @ObservedObject var module: MenuBarModule
    let onOpenAccessibilitySettings: () -> Void
    /// Called before an item's menu opens, so the popover can close.
    var onWillOpenItem: () -> Void = {}
    /// Switches the built-in display in or out of the below-notch mode.
    var onToggleNotch: (() -> Void)?
    var notchMode = NotchDisplayMode()

    var body: some View {
        content
        if let onToggleNotch, notchMode.isAvailable {
            DetailActionRow(
                title: notchMode.isBelowNotch ? localized("Restore Full Height") : localized("Move Menu Bar Below Notch"),
                symbol: "rectangle.topthird.inset.filled",
                action: onToggleNotch
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        switch module.state {
        case .needsAccess:
            DetailMessageCard(text: localized("DuoBar+ needs Accessibility access to find menu bar items hidden by the notch. Allow it, then open the popover again."))
            DetailActionRow(title: localized("Allow Access…"), symbol: "lock.open", action: module.requestAccess)
            DetailActionRow(title: localized("Open Accessibility Settings"), action: onOpenAccessibilitySettings)
        case .noNotch:
            if notchMode.isBelowNotch {
                DetailMessageCard(text: localized("The menu bar is below the notch, so every menu bar item has room."))
            } else {
                DetailMessageCard(text: localized("None of the connected displays has a camera notch, so every menu bar item has room."))
            }
        case .checking:
            DetailValueRow(label: localized("Status"), value: localized("Checking…"))
        case .ready:
            if module.hiddenItems.isEmpty {
                DetailValueRow(label: localized("Status"), value: localized("All items are visible"))
            } else {
                DetailSectionHeader(title: localized("Hidden by the Notch"))
                ForEach(module.hiddenItems) { item in
                    // The right-click menu holds the options people want here;
                    // the left-click action often just opens the app.
                    MenuBarItemTile(item: item) {
                        onWillOpenItem()
                        module.open(item)
                    }
                }
                Text(localized("Click an item to open its menu, or the app when it has no menu."))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        }
    }
}

struct MenuBarItemTile: View {
    let item: MenuBarItemSnapshot
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 8) {
                icon
                    .frame(width: 18, height: 18)
                Text(item.appName)
                    .font(PopoverDesign.detailValueFont)
                    .lineLimit(1)
                    .layoutPriority(1)
                if let title = item.title {
                    Text(title)
                        .font(PopoverDesign.detailLabelFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PopoverDesign.horizontalPadding + 2)
            .frame(height: PopoverDesign.valueRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popoverCardBackground(cornerRadius: 11, fillOpacity: 0.045)
        .help(localized("Open menu"))
        .accessibilityElement(children: .combine)
        .accessibilityHint(localized("Open menu"))
    }

    @ViewBuilder
    private var icon: some View {
        if let image = NSRunningApplication(processIdentifier: item.pid)?.icon {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }
}

