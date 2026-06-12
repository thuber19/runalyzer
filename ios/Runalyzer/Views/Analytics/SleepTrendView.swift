import SwiftUI
import Charts

/// Sleep-specific trend view showing nightly duration stacked by stage.
struct SleepTrendView: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @State private var timeRange: MetricTrendView.TimeRange = .month

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    private struct SleepNight: Identifiable {
        let id: Date
        var date: Date { id }
        let deep: Double
        let core: Double
        let rem: Double
        let awake: Double
        let stages: [(stage: String, start: Date, end: Date)]
    }

    private var sleepNights: [SleepNight] {
        guard let start = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) else { return [] }
        let points = metricIndex.query(type: DataType.sleepStage, measurementType: .metric,
                                       from: start, to: Date(), filter: sourcePrefs)

        var byDay: [Date: [DataPoint]] = [:]
        for p in points {
            let startHour = cal.component(.hour, from: p.timestamp)
            let day: Date
            if startHour >= 18 {
                day = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: p.timestamp) ?? p.timestamp)
            } else {
                day = cal.startOfDay(for: p.timestamp)
            }
            byDay[day, default: []].append(p)
        }

        return byDay.keys.sorted().map { day in
            let dps = byDay[day] ?? []
            func minutes(for stage: String) -> Double {
                dps.filter { $0.unit == stage }.compactMap { p in
                    guard let end = p.endTimestamp else { return nil }
                    return end.timeIntervalSince(p.timestamp) / 60
                }.reduce(0, +)
            }
            let stageIntervals = dps.compactMap { p -> (stage: String, start: Date, end: Date)? in
                guard let end = p.endTimestamp else { return nil }
                return (stage: p.unit, start: p.timestamp, end: end)
            }.sorted { $0.start < $1.start }

            return SleepNight(id: day, deep: minutes(for: "Deep"), core: minutes(for: "Core"),
                              rem: minutes(for: "REM"), awake: minutes(for: "Awake"),
                              stages: stageIntervals)
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Picker("Range", selection: $timeRange) {
                    ForEach(MetricTrendView.TimeRange.allCases, id: \.self) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Stacked bar chart
                if !sleepNights.isEmpty {
                    sleepChart
                        .frame(height: 200)
                        .padding(.horizontal)
                }

                // Average stats
                sleepStats
                    .padding(.horizontal)

                // Night list
                nightList
            }
            .padding(.vertical)
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Sleep")
    }

    private var sleepChart: some View {
        Chart(sleepNights) { night in
            BarMark(x: .value("Date", night.date, unit: .day), y: .value("Deep", night.deep / 60))
                .foregroundStyle(Color.indigo)
            BarMark(x: .value("Date", night.date, unit: .day), y: .value("Core", night.core / 60))
                .foregroundStyle(Color.blue)
            BarMark(x: .value("Date", night.date, unit: .day), y: .value("REM", night.rem / 60))
                .foregroundStyle(Color.cyan)
        }
        .chartYAxisLabel("hours")
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let d = value.as(Date.self) {
                        Text(shortDate(d)).font(.caption2).foregroundColor(.gray)
                    }
                }
            }
        }
        .chartForegroundStyleScale([
            "Deep": Color.indigo, "Core": Color.blue, "REM": Color.cyan
        ])
    }

    private var sleepStats: some View {
        let avgTotal = sleepNights.isEmpty ? 0 :
            sleepNights.map { $0.deep + $0.core + $0.rem }.reduce(0, +) / Double(sleepNights.count)
        let avgDeep = sleepNights.isEmpty ? 0 :
            sleepNights.map(\.deep).reduce(0, +) / Double(sleepNights.count)
        let avgREM = sleepNights.isEmpty ? 0 :
            sleepNights.map(\.rem).reduce(0, +) / Double(sleepNights.count)

        return HStack(spacing: 0) {
            statCol(formatMin(avgTotal), "Avg Asleep")
            statCol(formatMin(avgDeep), "Avg Deep")
            statCol(formatMin(avgREM), "Avg REM")
            statCol("\(sleepNights.count)", "Nights")
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private var nightList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sleepNights.reversed()) { night in
                let total = night.deep + night.core + night.rem
                NavigationLink(destination: SleepNightDetailView(date: night.date, stages: night.stages)) {
                    HStack {
                        Text(MetricAggregator.formatDay(night.date))
                            .font(.caption).foregroundColor(.gray)
                            .frame(width: 90, alignment: .leading)
                        Text(formatMin(total)).font(.subheadline.bold().monospacedDigit())
                        Spacer()
                        HStack(spacing: 8) {
                            stageChip("D", night.deep, .indigo)
                            stageChip("C", night.core, .blue)
                            stageChip("R", night.rem, .cyan)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2).foregroundColor(.gray)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal).padding(.vertical, 8)
                Divider().background(Color.gray.opacity(0.2)).padding(.leading)
            }
        }
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    private func stageChip(_ label: String, _ minutes: Double, _ color: Color) -> some View {
        HStack(spacing: 2) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(formatMin(minutes)).font(.caption2.monospacedDigit()).foregroundColor(.gray)
        }
    }

    private func formatMin(_ m: Double) -> String {
        let h = Int(m) / 60, min = Int(m) % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", min))m" : "\(min)m"
    }

    private static let shortDateFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()

    private func shortDate(_ d: Date) -> String {
        Self.shortDateFmt.string(from: d)
    }

    private func statCol(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }
}
