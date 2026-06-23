import SwiftUI
import Charts

/// A data point for the scrubbing line chart.
struct ChartDataPoint: Identifiable {
    let id: Date
    var date: Date { id }
    let avg: Double
    let min: Double
    let max: Double

    init(date: Date, avg: Double, min: Double? = nil, max: Double? = nil) {
        self.id = date
        self.avg = avg
        self.min = min ?? avg
        self.max = max ?? avg
    }
}

/// Interactive line chart with min/max band and drag-to-scrub.
///
/// Features:
/// - Average line with optional min/max shaded band
/// - Data point dots (auto-hidden when > 14 points)
/// - Drag gesture shows vertical rule line + highlighted point + value label
/// - Y-axis on leading edge with grid lines
///
/// Usage:
/// ```
/// ScrubbingLineChart(
///     data: aggregates.map { ChartDataPoint(date: $0.date, avg: $0.avg, min: $0.min, max: $0.max) },
///     color: .cyan,
///     unit: "bpm",
///     dateFormat: "d MMM"
/// )
/// .frame(height: 200)
/// ```
struct ScrubbingLineChart: View {
    let data: [ChartDataPoint]
    let color: Color
    let unit: String
    let dateFormat: String
    let showBand: Bool

    @State private var scrubPoint: ChartDataPoint?

    init(data: [ChartDataPoint], color: Color, unit: String = "",
         dateFormat: String = "d MMM", showBand: Bool = true) {
        self.data = data
        self.color = color
        self.unit = unit
        self.dateFormat = dateFormat
        self.showBand = showBand
    }

    var body: some View {
        VStack(spacing: 4) {
            // Scrub indicator
            if let point = scrubPoint {
                HStack(spacing: 6) {
                    Text(formatDate(point.date))
                        .font(.caption).foregroundColor(.gray)
                    Text(String(format: "%.1f", point.avg))
                        .font(.caption.bold().monospacedDigit())
                    if !unit.isEmpty {
                        Text(unit).font(.caption2).foregroundColor(.gray)
                    }
                }
                .transition(.opacity)
            }

            Chart {
                // Min/max band
                if showBand {
                    ForEach(data) { point in
                        AreaMark(
                            x: .value("Date", point.date),
                            yStart: .value("Min", point.min),
                            yEnd: .value("Max", point.max)
                        )
                        .foregroundStyle(color.opacity(0.15))
                    }
                }

                // Average line
                ForEach(data) { point in
                    LineMark(
                        x: .value("Date", point.date),
                        y: .value("Avg", point.avg)
                    )
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2))
                }

                // Data point dots
                ForEach(data) { point in
                    PointMark(
                        x: .value("Date", point.date),
                        y: .value("Avg", point.avg)
                    )
                    .foregroundStyle(color)
                    .symbolSize(data.count < 15 ? 30 : 0)
                }

                // Scrub rule line + highlight
                if let point = scrubPoint {
                    RuleMark(x: .value("Scrub", point.date))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                    PointMark(x: .value("Scrub", point.date), y: .value("Val", point.avg))
                        .foregroundStyle(.white)
                        .symbolSize(50)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%.0f", v))
                                .font(.caption2).foregroundColor(.gray)
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                        .foregroundStyle(Color.gray.opacity(0.3))
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(formatDate(date)).font(.caption2).foregroundColor(.gray)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { drag in
                                    guard let frame = proxy.plotFrame else { return }
                                    let x = drag.location.x - geo[frame].origin.x
                                    guard let date: Date = proxy.value(atX: x) else { return }
                                    scrubPoint = data.min(by: {
                                        abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
                                    })
                                }
                                .onEnded { _ in
                                    scrubPoint = nil
                                }
                        )
                }
            }
        }
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = dateFormat
        return f.string(from: date)
    }
}
