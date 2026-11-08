import SwiftUI

/// DuoBar+ popover design tokens and building blocks. One glass panel holds
/// rounded-rectangle cards; standard rows have an icon tile, title, subtitle,
/// a trailing value (plain or as a tinted badge) and a chevron; compact rows
/// have a bare icon and a single line. Every popover page uses these.
enum PopoverDesign {
    static let panelCornerRadius: CGFloat = 26
    static let cardCornerRadius: CGFloat = 15
    static let rowHeight: CGFloat = 50
    static let compactRowHeight: CGFloat = 38
    static let valueRowHeight: CGFloat = 34
    static let rowSpacing: CGFloat = 8
    static let horizontalPadding: CGFloat = 10
    static let iconTileSize: CGFloat = 32
    static let iconTileCornerRadius: CGFloat = 9

    static let titleFont = Font.system(size: 13, weight: .semibold)
    static let subtitleFont = Font.system(size: 11)
    static let valueFont = Font.system(size: 13, weight: .medium)
    static let compactTitleFont = Font.system(size: 12.5)
    static let detailLabelFont = Font.system(size: 11.5)
    static let detailValueFont = Font.system(size: 11.5, weight: .medium)
    static let badgeFont = Font.system(size: 11.5, weight: .semibold)
}

/// Rounded square behind a row's symbol.
struct IconTile: View {
    /// SF Symbols has no Bluetooth mark, so this name draws `BluetoothMark`.
    static let bluetoothSymbol = "duobarplus.bluetooth"

    let symbol: String
    var tint: Color = .primary

    var body: some View {
        icon
            .foregroundStyle(tint)
            .frame(width: PopoverDesign.iconTileSize, height: PopoverDesign.iconTileSize)
            .background(
                tint.opacity(0.12),
                in: RoundedRectangle(cornerRadius: PopoverDesign.iconTileCornerRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var icon: some View {
        if symbol == Self.bluetoothSymbol {
            BluetoothMark()
                .stroke(style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                .frame(width: 9, height: 16)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
        }
    }
}

extension View {
    /// The standard row card, or nothing when several rows share one card.
    @ViewBuilder
    func popoverRowCard(_ isShown: Bool) -> some View {
        if isShown {
            popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
        } else {
            self
        }
    }
}

/// The Bluetooth rune, drawn as one continuous line.
struct BluetoothMark: Shape {
    func path(in rect: CGRect) -> Path {
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + rect.width * x, y: rect.minY + rect.height * y)
        }
        var path = Path()
        path.move(to: point(0, 0.25))
        path.addLine(to: point(1, 0.75))
        path.addLine(to: point(0.5, 1))
        path.addLine(to: point(0.5, 0))
        path.addLine(to: point(1, 0.25))
        path.addLine(to: point(0, 0.75))
        return path
    }
}

/// A trailing value: plain primary text, or a tinted capsule badge with an
/// optional symbol when the value carries a state (signal, warning, low).
struct ValueBadge: View {
    let text: String
    var tint: Color?
    var symbol: String?
    var font: Font = PopoverDesign.valueFont

    var body: some View {
        if let tint {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .bold))
                }
                Text(text)
                    .monospacedDigit()
            }
            .font(PopoverDesign.badgeFont)
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(tint.opacity(0.18), in: Capsule())
        } else {
            Text(text)
                .font(font)
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

struct RowChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }
}

/// Single-line row: bare icon, title, optional trailing text and a chevron.
struct CompactRowLabel: View {
    let symbol: String
    let title: String
    var trailing: String?
    var showsChevron = true

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(PopoverDesign.compactTitleFont)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if showsChevron {
                RowChevron()
            }
        }
        .padding(.horizontal, PopoverDesign.horizontalPadding)
        .frame(height: PopoverDesign.compactRowHeight)
        .contentShape(Rectangle())
    }
}
