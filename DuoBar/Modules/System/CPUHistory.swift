import Charts
import SwiftUI

struct CPUSample: Equatable, Identifiable, Sendable {
    var id: Int
    /// 0…1 across all cores.
    var total: Double
}

/// Recent CPU readings for the live graph, kept in memory only while the
/// popover is open. A separate object so only the graph redraws.
@MainActor
final class CPUHistory: ObservableObject {
    @Published private(set) var samples: [CPUSample] = []
    let capacity: Int
    private var nextID = 0

    init(capacity: Int = 60) {
        self.capacity = capacity
    }

    func append(_ total: Double) {
        samples.append(CPUSample(id: nextID, total: min(max(total, 0), 1)))
        nextID += 1
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    func clear() {
        samples = []
        nextID = 0
    }

    /// A fixed window that scrolls as new readings arrive, so the line
    /// grows in from the right.
    var xDomain: ClosedRange<Int> {
        let last = samples.last?.id ?? 0
        return (last - capacity + 1)...last
    }
}

/// CPU usage with a small live graph instead of a bar.
struct CPUGraphTile: View {
    @ObservedObject var history: CPUHistory
    let value: String
    var caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(localized("Usage"))
                    .font(PopoverDesign.detailLabelFont)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(PopoverDesign.detailValueFont)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Chart {
                ForEach(history.samples) { sample in
                    AreaMark(x: .value("Time", sample.id), y: .value("CPU", sample.total))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.05)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.id), y: .value("CPU", sample.total))
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: history.xDomain)
            .chartYScale(domain: 0...1)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartPlotStyle { plot in
                plot.background(Color.primary.opacity(0.04))
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .frame(height: 34)
            .accessibilityLabel(localized("CPU usage over the last minute"))
            if let caption {
                Text(caption)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .popoverCardBackground(cornerRadius: 11, fillOpacity: 0.045)
        .accessibilityElement(children: .combine)
    }
}
