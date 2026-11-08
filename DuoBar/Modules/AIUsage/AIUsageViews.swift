import SwiftUI

/// Main-view row. The right column labels both limits ("5 h 32%",
/// "Week 54%"); the subtitle says when the 5-hour limit resets. From 90 %
/// a value turns orange with a warning sign (red at the limit).
struct AIUsageStatusRow: View {
    @ObservedObject var module: AIUsageModule
    let onActivate: () -> Void

    var body: some View {
        let summary = AIUsageSummary.make(
            module.enabledProviders.map { ($0, module.state(for: $0)) },
            now: Date()
        )
        Button(action: onActivate) {
            HStack(spacing: 11) {
                IconTile(symbol: "sparkles", tint: .primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(localized("AI Usage"))
                        .font(PopoverDesign.titleFont)
                        .lineLimit(1)
                    Text(summary.detail)
                        .font(PopoverDesign.subtitleFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .layoutPriority(1)
                Spacer(minLength: 6)
                if !summary.values.isEmpty {
                    Grid(alignment: .trailing, horizontalSpacing: 5, verticalSpacing: 1) {
                        ForEach(summary.values) { value in
                            GridRow {
                                Text(value.label)
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                HStack(spacing: 3) {
                                    if value.warning != nil {
                                        Image(systemName: "exclamationmark.triangle.fill")
                                            .font(.system(size: 9, weight: .bold))
                                    }
                                    Text(value.text)
                                        .font(.system(size: 12.5, weight: .semibold))
                                        .monospacedDigit()
                                }
                                .foregroundStyle(value.warning.map { AnyShapeStyle(AIUsageLevel.color($0)) } ?? AnyShapeStyle(.primary))
                            }
                        }
                    }
                    .fixedSize()
                }
                RowChevron()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint(localized("Show details"))
        .padding(.horizontal, PopoverDesign.horizontalPadding)
        .frame(height: PopoverDesign.rowHeight)
        .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
    }
}

/// What the AI Usage row shows. Pure, so it is unit tested.
///
/// The right column has the 5-hour and weekly values (with two tools, the
/// higher of each). The subtitle has the 5-hour reset of the tool nearest
/// its limit, named when both tools are on.
struct AIUsageSummary: Equatable {
    struct Value: Equatable, Identifiable {
        var label: String
        var text: String
        var warning: AIUsageLevel.Warning?
        var id: String { label }
    }

    var detail: String
    var values: [Value] = []

    static func make(_ providers: [(AIProvider, ProviderUsageState)], now: Date) -> AIUsageSummary {
        let showsNames = providers.count > 1
        var session: (provider: AIProvider, window: UsageWindow)?
        var weekly: Double?
        var pending = false
        var failed: [AIProvider] = []

        for (provider, state) in providers {
            switch state {
            case .ready(let usage):
                let windows = usage.windows.map { $0.current(at: now) }
                if let window = windows.first(where: { $0.kind == .session }),
                   window.usedFraction > (session?.window.usedFraction ?? -1) {
                    session = (provider, window)
                }
                if let window = windows.first(where: { $0.kind == .weekly }) {
                    weekly = max(weekly ?? 0, window.usedFraction)
                }
            case .loading, .off:
                pending = true
            case .failed:
                failed.append(provider)
            }
        }

        guard !providers.isEmpty else { return AIUsageSummary(detail: localized("Off")) }

        var values: [Value] = []
        if let session {
            values.append(Value(label: localized("5 h"), text: AIUsageText.percent(session.window.usedFraction), warning: AIUsageLevel.warning(session.window.usedFraction)))
        }
        if let weekly {
            values.append(Value(label: localized("Week"), text: AIUsageText.percent(weekly), warning: AIUsageLevel.warning(weekly)))
        }

        var detail: String
        if let session, let reset = session.window.resetsAt, session.window.usedFraction > 0 {
            let duration = AIUsageText.compactDuration(reset.timeIntervalSince(now))
            detail = showsNames
                ? localized("%@ resets in %@", session.provider.title, duration)
                : localized("5 h resets in %@", duration)
        } else if session != nil {
            detail = showsNames ? providers.map(\.0.title).joined(separator: " + ") : localized("Nothing used in this 5-hour window")
        } else if pending {
            detail = localized("Loading…")
        } else {
            detail = localized("Not available")
        }
        if !failed.isEmpty, session != nil {
            detail += " · " + localized("%@ unavailable", failed.map(\.title).joined(separator: ", "))
        }
        return AIUsageSummary(detail: detail, values: values)
    }
}

struct AIUsageDetailView: View {
    @ObservedObject var module: AIUsageModule

    var body: some View {
        if module.enabledProviders.isEmpty {
            DetailValueRow(label: localized("Status"), value: localized("Off"))
        }
        ForEach(module.enabledProviders) { provider in
            ProviderUsageSection(provider: provider, state: module.state(for: provider))
        }
        DetailActionRow(title: localized("Refresh"), symbol: "arrow.clockwise") {
            module.refresh(force: true)
        }
    }
}

private struct ProviderUsageSection: View {
    let provider: AIProvider
    let state: ProviderUsageState

    var body: some View {
        DetailSectionHeader(title: header)
        switch state {
        case .off:
            EmptyView()
        case .loading:
            DetailValueRow(label: localized("Status"), value: localized("Loading…"))
        case .failed(let problem):
            DetailMessageCard(text: problem.message)
        case .ready(let usage):
            let now = Date()
            ForEach(usage.windows.map { $0.current(at: now) }) { window in
                MeterTile(
                    title: window.title,
                    value: AIUsageText.percent(window.usedFraction),
                    fraction: window.usedFraction,
                    caption: AIUsageText.reset(window.resetsAt, now: now),
                    barTint: AIUsageLevel.tint(window.usedFraction)
                )
            }
            if provider == .codex {
                Text(localized("From your latest Codex session · %@", AIUsageText.age(usage.measuredAt, now: now)))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
            }
        }
    }

    private var header: String {
        guard let plan = AIUsageText.plan(state.usage?.plan) else { return provider.title }
        return "\(provider.title) · \(plan)"
    }
}

enum AIUsageLevel {
    enum Warning: Equatable {
        /// 90 % or more of a limit used.
        case near
        /// The limit is used up.
        case reached
    }

    static let warningFraction = 0.9

    static func warning(_ fraction: Double) -> Warning? {
        if fraction >= 1 { return .reached }
        if fraction >= warningFraction { return .near }
        return nil
    }

    static func color(_ warning: Warning) -> Color {
        switch warning {
        case .near: Color(nsColor: .systemOrange)
        case .reached: Color(nsColor: .systemRed)
        }
    }

    /// Default bar below 90 %, orange from 90 % and red at the limit.
    static func tint(_ fraction: Double) -> Color? {
        warning(fraction).map(color)
    }
}
