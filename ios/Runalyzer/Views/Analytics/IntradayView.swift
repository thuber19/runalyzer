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

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }

    private var points: [DataPoint] {
        // Use the specific measurement for this day (not a broad MetricIndex query)
        // This avoids picking up DataPoints from adjacent days with matching timestamps
        if let measurement = metricIndex.metricMeasurement(forDay: date, containingType: metricType) {
            return measurement.dataPoints.filter { $0.type == metricType }
                .sorted { $0.timestamp < $1.timestamp }
        }
        // Fallback: broad query
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return [] }
        return metricIndex.query(type: metricType, measurementType: .metric, from: dayStart, to: dayEnd)
    }

    private var stats: MetricAggregator.PeriodStats {
        MetricAggregator.periodStats(points)
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Intraday chart
                if points.count > 1 {
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
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
                .padding(.horizontal)

                // Reading list
                readingList
            }
            .padding(.vertical)
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(MetricAggregator.formatDay(date))
    }

    private var intradayChart: some View {
        Chart {
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                LineMark(
                    x: .value("Time", p.timestamp),
                    y: .value(title, p.value)
                )
                .foregroundStyle(color)
            }
            ForEach(Array(points.enumerated()), id: \.offset) { _, p in
                PointMark(
                    x: .value("Time", p.timestamp),
                    y: .value(title, p.value)
                )
                .foregroundStyle(color)
                .symbolSize(points.count < 30 ? 20 : 0)
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
            Text("READINGS").font(.caption2).foregroundColor(.gray)
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 4)

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
        .background(Color(hex: 0x16213e))
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
