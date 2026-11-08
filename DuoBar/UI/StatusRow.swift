import SwiftUI

/// Standard popover row (DuoBar+ design): icon tile, title and subtitle,
/// a trailing value centered vertically (plain, or a tinted badge), and a
/// chevron. A trailing control (for example the Wi-Fi switch) replaces the
/// chevron and is set off by a divider.
struct StatusRow: View {
    enum Accessory {
        case none
        case disclosure
        case menu
    }

    let symbol: String
    let title: String
    let detail: String
    /// The trailing value, e.g. "100%" or "-48 dBm".
    let speedText: String?
    /// Tints the value as a badge, e.g. a color-coded signal strength.
    var speedTint: Color?
    /// Symbol shown in a tinted badge, e.g. a warning triangle.
    var speedSymbol: String?
    let stateText: String
    let tint: Color
    var accessory: Accessory = .none
    let trailing: AnyView?
    var onActivate: (() -> Void)?
    var activationHint: String?

    init(
        symbol: String,
        title: String,
        detail: String,
        speedText: String? = nil,
        speedTint: Color? = nil,
        speedSymbol: String? = nil,
        stateText: String,
        tint: Color,
        accessory: Accessory = .none,
        trailing: AnyView? = nil,
        onActivate: (() -> Void)? = nil,
        activationHint: String? = nil
    ) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.speedText = speedText
        self.speedTint = speedTint
        self.speedSymbol = speedSymbol
        self.stateText = stateText
        self.tint = tint
        self.accessory = accessory
        self.trailing = trailing
        self.onActivate = onActivate
        self.activationHint = activationHint
    }

    var body: some View {
        HStack(spacing: 10) {
            activationContent
            if let trailing {
                Divider()
                    .frame(height: 24)
                trailing
            }
        }
        .padding(.horizontal, PopoverDesign.horizontalPadding)
        .frame(height: PopoverDesign.rowHeight)
        .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
    }

    @ViewBuilder
    private var activationContent: some View {
        if let onActivate {
            Group {
                if let activationHint {
                    Button(action: onActivate) {
                        labelContent
                    }
                    .accessibilityHint(activationHint)
                } else {
                    Button(action: onActivate) {
                        labelContent
                    }
                }
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            labelContent
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var labelContent: some View {
        HStack(spacing: 11) {
            IconTile(symbol: symbol, tint: tint)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(PopoverDesign.titleFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text(detail)
                    .font(PopoverDesign.subtitleFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .minimumScaleFactor(0.72)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            if let speedText {
                ValueBadge(text: speedText, tint: speedTint, symbol: speedSymbol)
                    .layoutPriority(2)
            }

            if trailing == nil, accessory != .none {
                RowChevron()
            }
        }
        .contentShape(Rectangle())
    }
}
