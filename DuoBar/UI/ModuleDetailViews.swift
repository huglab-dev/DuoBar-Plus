import AppKit
import SwiftUI

/// Header with a back button and the module title, followed by content that
/// scrolls once it would exceed `maxContentHeight`.
struct ModuleDetailContainer<Content: View>: View {
    let title: String
    let maxContentHeight: CGFloat
    let onBack: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: PopoverDesign.rowSpacing) {
            header
            FittingScrollView(maxHeight: maxContentHeight) {
                VStack(spacing: 6) {
                    content()
                }
            }
        }
    }

    private var header: some View {
        HStack {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text(localized("Back"))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .keyboardShortcut("[", modifiers: .command)
            .accessibilityLabel(localized("Back"))

            Spacer()
        }
        .overlay {
            Text(title)
                .font(PopoverDesign.titleFont)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
        }
        .font(PopoverDesign.compactTitleFont)
        .padding(.horizontal, PopoverDesign.horizontalPadding)
        .frame(height: PopoverDesign.compactRowHeight)
        .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
    }
}

/// A vertical scroll view that is exactly as tall as its content, up to
/// `maxHeight`, so short detail views do not leave empty space.
struct FittingScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > maxHeight) {
            content()
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: FittingScrollContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: min(max(contentHeight, 1), max(maxHeight, 1)))
        .onPreferenceChange(FittingScrollContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct FittingScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Label and value on one tile. Copyable values copy on click and briefly
/// confirm it in place of the value.
struct DetailValueRow: View {
    let label: String
    let value: String
    var isCopyable = false
    /// Shows the value as a tinted badge, for values that carry a state.
    var tint: Color?
    var symbol: String?

    @State private var showsCopied = false
    @State private var copyGeneration = 0

    var body: some View {
        if isCopyable {
            Button(action: copy) { rowContent }
                .buttonStyle(.plain)
                .accessibilityHint(localized("Click to copy"))
                .help(localized("Click to copy"))
        } else {
            rowContent
        }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if showsCopied {
                Label(localized("Copied"), systemImage: "checkmark")
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            } else if let tint {
                ValueBadge(text: value, tint: tint, symbol: symbol)
            } else {
                Text(value)
                    .font(PopoverDesign.detailValueFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.disabled)
            }
        }
        .font(PopoverDesign.detailLabelFont)
        .padding(.horizontal, PopoverDesign.horizontalPadding + 2)
        .frame(height: PopoverDesign.valueRowHeight)
        .contentShape(Rectangle())
        .popoverCardBackground(cornerRadius: 11, fillOpacity: 0.045)
        .accessibilityElement(children: .combine)
    }

    private func copy() {
        Self.copyToPasteboard(value)
        copyGeneration &+= 1
        let generation = copyGeneration
        withAnimation(.easeOut(duration: 0.12)) { showsCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            guard generation == copyGeneration else { return }
            withAnimation(.easeOut(duration: 0.2)) { showsCopied = false }
        }
    }

    static func copyToPasteboard(_ value: String, pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}

/// A tile that performs an action, typically opening System Settings.
struct DetailActionRow: View {
    let title: String
    var symbol = "arrow.up.forward.app"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(PopoverDesign.compactTitleFont)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PopoverDesign.horizontalPadding + 2)
            .frame(height: PopoverDesign.valueRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popoverCardBackground(cornerRadius: 11, fillOpacity: 0.045)
    }
}

/// A short explanation on a card, for states such as missing access.
struct DetailMessageCard: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(PopoverDesign.detailLabelFont)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .popoverCardBackground(cornerRadius: 11, fillOpacity: 0.045)
    }
}
