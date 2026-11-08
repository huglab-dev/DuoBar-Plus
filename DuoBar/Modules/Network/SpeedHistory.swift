import Charts
import SwiftUI

struct SpeedSample: Equatable, Identifiable, Sendable {
    var id: Int
    var download: Double
    var upload: Double
}

/// The last `capacity` one-second speed readings, kept in memory only while
/// the popover is open. A separate object so only the graph redraws.
@MainActor
final class SpeedHistory: ObservableObject {
    @Published private(set) var samples: [SpeedSample] = []
    let capacity: Int
    private var nextID = 0

    init(capacity: Int = 60) {
        self.capacity = capacity
    }

    func append(_ speed: NetworkSpeed?) {
        guard let speed else { return }
        samples.append(SpeedSample(id: nextID, download: speed.downloadBytesPerSecond, upload: speed.uploadBytesPerSecond))
        nextID += 1
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
    }

    func clear() {
        samples = []
        nextID = 0
    }

    var peak: Double {
        samples.map { max($0.download, $0.upload) }.max() ?? 0
    }
}

struct SpeedGraphTile: View {
    @ObservedObject var history: SpeedHistory
    /// Hidden by default; the speed is shown either way. History keeps
    /// recording while the popover is open, so the graph is full on open.
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { isExpanded.toggle() }
            } label: {
                HStack {
                    Text(isExpanded ? localized("Last Minute") : localized("Speed"))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let last = history.samples.last {
                        Text("↓\(NetworkSpeedFormatter.compact(last.download)) ↑\(NetworkSpeedFormatter.compact(last.upload))")
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    RowChevron()
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .font(PopoverDesign.detailLabelFont)
                .frame(minHeight: isExpanded ? nil : PopoverDesign.valueRowHeight - 16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(localized("Show the graph for the last minute"))

            if isExpanded {
                graph
            }
        }
        .padding(.horizontal, PopoverDesign.horizontalPadding + 2)
        .padding(.vertical, 8)
        .popoverCardBackground(cornerRadius: PopoverDesign.cardCornerRadius, fillOpacity: 0.065)
    }

    @ViewBuilder
    private var graph: some View {
            Chart {
                ForEach(history.samples) { sample in
                    AreaMark(x: .value("Time", sample.id), y: .value("Bytes", sample.download), series: .value("Direction", "down"))
                        .foregroundStyle(Color.primary.opacity(0.25))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.id), y: .value("Bytes", sample.download), series: .value("Direction", "down"))
                        .foregroundStyle(Color.primary.opacity(0.85))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", sample.id), y: .value("Bytes", sample.upload), series: .value("Direction", "up"))
                        .foregroundStyle(Color.accentColor)
                        .interpolationMethod(.monotone)
                }
            }
            .chartXScale(domain: xDomain)
            .chartYScale(domain: 0...max(history.peak * 1.15, 1_024))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 2)) { value in
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.3))
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(NetworkSpeedFormatter.compact(bytes)).font(.system(size: 8.5))
                        }
                    }
                }
            }
            .frame(height: 70)
            .accessibilityLabel(localized("Network speed over the last minute"))

            HStack(spacing: 10) {
                legend(localized("Download"), color: .primary.opacity(0.85))
                legend(localized("Upload"), color: .accentColor)
            }
            .font(.system(size: 9.5))
            .foregroundStyle(.secondary)
    }

    /// A fixed 60-sample window that scrolls as new readings arrive.
    private var xDomain: ClosedRange<Int> {
        let last = history.samples.last?.id ?? 0
        let first = max(last - history.capacity + 1, 0)
        return first...max(first + history.capacity - 1, last)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Capsule().fill(color).frame(width: 10, height: 3)
            Text(title)
        }
    }
}
