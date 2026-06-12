import SwiftUI
import Charts

/// Generic trend detail view for any metric type.
/// Shows daily avg with min/max band, stats, and day-by-day breakdown.
struct MetricTrendView: View {
    let metricType: String
    let title: String
    let unit: String
    let color: Color
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore

    @State private var timeRange: TimeRange = .month

    enum TimeRange: String, CaseIterable {
        case week = "7D", month = "30D", quarter = "90D", year = "1Y"

        var days: Int {
            switch self {
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            case .year: return 365
            }
        }
    }

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    private var dataPoints: [DataPoint] {
        guard let start = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) else { return [] }
        // Query across ALL measurement types, filtered to enabled sources
        return metricIndex.query(type: metricType, from: start, to: Date(), filter: sourcePrefs)
    }

    private var aggregates: [MetricAggregator.DailyAggregate] {
        timeRange == .year
            ? MetricAggregator.weeklyAggregates(dataPoints)
            : MetricAggregator.dailyAggregates(dataPoints)
    }

    private var stats: MetricAggregator.PeriodStats {
        MetricAggregator.periodStats(dataPoints)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Time range picker
                Picker("Range", selection: $timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Main chart
                trendChart
                    .frame(height: 200)
                    .padding(.horizontal)

                // Stats row
                statsRow
                    .padding(.horizontal)

                // Day/week list
                dayList
            }
            .padding(.vertical)
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle(title)
    }

    // MARK: - Trend Chart

    private var trendChart: some View {
        ScrubbingLineChart(
            data: aggregates.map { ChartDataPoint(date: $0.date, avg: $0.avg, min: $0.min, max: $0.max) },
            color: color,
            unit: unit,
            dateFormat: timeRange == .year ? "MMM" : "d MMM"
        )
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 0) {
            statItem("Avg", String(format: "%.1f", stats.avg), unit)
            statItem("Min", String(format: "%.1f", stats.min), unit)
            statItem("Max", String(format: "%.1f", stats.max), unit)
            VStack {
                HStack(spacing: 2) {
                    Image(systemName: stats.trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.caption)
                    Text(String(format: "%+.1f%%", stats.trend))
                        .font(.headline.monospacedDigit())
                }
                .foregroundColor(stats.trend >= 0 ? .green : .orange)
                Text("Trend").font(.caption2).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity)
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func statItem(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack {
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value).font(.headline.monospacedDigit())
                Text(unit).font(.caption2).foregroundColor(.gray)
            }
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Day List

    private var dayList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(aggregates.reversed()) { agg in
                NavigationLink(destination: IntradayView(
                    metricType: metricType, title: title, unit: unit, color: color, date: agg.date
                )) {
                    HStack {
                        Text(timeRange == .year
                             ? MetricAggregator.formatWeek(agg.date)
                             : MetricAggregator.formatDay(agg.date))
                            .font(.caption).foregroundColor(.gray)
                            .frame(width: 90, alignment: .leading)
                        Text(String(format: "%.1f", agg.avg))
                            .font(.subheadline.bold().monospacedDigit())
                        Text(unit).font(.caption2).foregroundColor(.gray)
                        Spacer()
                        Text("\(String(format: "%.0f", agg.min))–\(String(format: "%.0f", agg.max))")
                            .font(.caption.monospacedDigit()).foregroundColor(.gray)
                        Text("\(agg.count)")
                            .font(.caption2).foregroundColor(.gray)
                            .frame(width: 25, alignment: .trailing)
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundColor(.gray.opacity(0.5))
                    }
                    .padding(.horizontal).padding(.vertical, 10)
                }
                .buttonStyle(.plain)

                if agg.id != aggregates.first?.id {
                    Divider().background(Color.gray.opacity(0.2)).padding(.leading)
                }
            }
        }
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
        .padding(.horizontal)
    }

}
