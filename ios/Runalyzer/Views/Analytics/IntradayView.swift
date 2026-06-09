import SwiftUI
import Charts

/// Shows all readings for a single day with chart + data list.
struct IntradayView: View {
    let metricType: String
    let title: String
    let unit: String
    let color: Color
    let date: Date
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore

    @State private var points: [DataPoint] = []
    @State private var isLoaded = false

    private var stats: MetricAggregator.PeriodStats {
        MetricAggregator.periodStats(points)
    }

    /// Downsample for chart rendering — max ~200 points for smooth performance.
    private var chartPoints: [DataPoint] {
        guard points.count > 200 else { return points }
        let step = points.count / 200
        return stride(from: 0, to: points.count, by: step).map { points[$0] }
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if !isLoaded {
                    ProgressView("Loading…").padding(.top, 40)
                } else {
                    // Chart (downsampled)
                    if chartPoints.count > 1 {
                        intradayChart
                            .frame(height: 200)
                            .padding(.horizontal)
                    }

                    // Stats
                    HStack(spacing: 0) {
                        statCol("Avg", String(format: "%.1f", stats.avg))
                        statCol("Min", String(format: "%.1f", stats.min))
                        statCol("Max", String(format: "%.1f", stats.max))
                        statCol("Count", "\(points.count)")
                    }
                    .padding()
                    .background(Color.appSurface)
                    .cornerRadius(12)
                    .padding(.horizontal)

                    // Reading list (lazy — only renders visible rows)
                    readingList
                }
            }
            .padding(.vertical)
        }
        .background(Color.appBackground)
        .navigationTitle(MetricAggregator.formatDay(date))
        .onAppear { loadPoints() }
    }

    private func loadPoints() {
        guard !isLoaded else { return }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return }
        let metricIndex = MetricIndex(store: measurementStore)
        let raw = metricIndex.query(type: metricType, measurementType: .metric,
                                    from: dayStart, to: dayEnd, filter: sourcePrefs)
        points = raw
        isLoaded = true
    }

    private var intradayChart: some View {
        Chart {
            ForEach(Array(chartPoints.enumerated()), id: \.offset) { _, p in
                LineMark(
                    x: .value("Time", p.timestamp),
                    y: .value(title, p.value)
                )
                .foregroundStyle(color)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(Self.timeFmt.string(from: date))
                            .font(.caption2).foregroundColor(.gray)
                    }
                }
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
    }

    private var readingList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("READINGS (\(points.count))").font(.caption2).foregroundColor(.gray)
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 4)

            LazyVStack(spacing: 0) {
                ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                    HStack {
                        Text(Self.timeFmt.string(from: p.timestamp))
                            .font(.system(size: 13, design: .monospaced)).foregroundColor(.gray)
                        Spacer()
                        Text(String(format: "%.2f", p.value))
                            .font(.system(size: 13, design: .monospaced))
                        Text(unit).font(.caption2).foregroundColor(.gray)
                    }
                    .padding(.horizontal).padding(.vertical, 6)
                }
            }
        }
        .background(Color.appSurface)
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func statCol(_ label: String, _ value: String) -> some View {
        VStack {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}
