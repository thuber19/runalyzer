import SwiftUI
import Charts

/// Sleep-specific trend view showing nightly duration stacked by stage.
struct SleepTrendView: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @State private var timeRange: MetricTrendView.TimeRange = .month
    @State private var nights: [SleepNight] = []

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    struct SleepNight: Identifiable {
        let id: Date
        var date: Date { id }
        let inBed: Double   // minutes
        let deep: Double
        let core: Double
        let rem: Double
        let awake: Double
        let stages: [(stage: String, start: Date, end: Date)]

        var asleep: Double { deep + core + rem }
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

                if !nights.isEmpty {
                    sleepChart
                        .frame(height: 200)
                        .padding(.horizontal)
                }

                sleepStats
                    .padding(.horizontal)

                nightList
            }
            .padding(.vertical)
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Sleep")
        .onAppear { loadNights() }
        .onChange(of: timeRange) { _ in loadNights() }
    }

    // MARK: - Data Loading

    private func loadNights() {
        nights = Self.buildSleepNights(
            metricIndex: metricIndex, sourcePrefs: sourcePrefs,
            lookbackDays: timeRange.days, calendar: cal
        )
    }

    /// Build sleep nights from DB data. Static so it can be shared.
    static func buildSleepNights(
        metricIndex: MetricIndex, sourcePrefs: SourcePreferenceStore,
        lookbackDays: Int, calendar cal: Calendar
    ) -> [SleepNight] {
        guard let start = cal.date(byAdding: .day, value: -lookbackDays, to: Date()) else { return [] }
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
            let raw = byDay[day] ?? []

            // Prefer staged sources (Watch) over generic (iPhone)
            let hasStages = raw.contains { ["Core", "Deep", "REM"].contains($0.unit) }
            let dps: [DataPoint]
            if hasStages {
                let stagedSources = Set(raw.filter { ["Core", "Deep", "REM"].contains($0.unit) }.map(\.source))
                dps = raw.filter { stagedSources.contains($0.source) || ["Awake", "InBed"].contains($0.unit) }
            } else {
                dps = raw
            }

            // Build intervals and merge overlaps per stage
            let rawIntervals = dps.compactMap { p -> (stage: String, start: Date, end: Date)? in
                guard let end = p.endTimestamp else { return nil }
                return (stage: p.unit, start: p.timestamp, end: end)
            }
            let mergedIntervals = mergeOverlappingIntervals(rawIntervals)

            func mergedMinutes(for stage: String) -> Double {
                mergedIntervals.filter { $0.stage == stage }
                    .reduce(0) { $0 + $1.end.timeIntervalSince($1.start) / 60 }
            }

            // In Bed: use actual InBed samples if available, otherwise fall back to asleep + awake
            let inBedFromSamples = mergedMinutes(for: "InBed")
            let asleepTotal = mergedMinutes(for: "Deep") + mergedMinutes(for: "Core") +
                              mergedMinutes(for: "REM") + mergedMinutes(for: "Asleep")
            let awakeTotal = mergedMinutes(for: "Awake")
            let inBed = inBedFromSamples > 0 ? inBedFromSamples : asleepTotal + awakeTotal

            // Only pass sleep stage intervals (not InBed) to the hypnogram
            let displayStages = mergedIntervals
                .filter { $0.stage != "InBed" }
                .sorted { $0.start < $1.start }

            return SleepNight(id: day, inBed: inBed,
                              deep: mergedMinutes(for: "Deep"), core: mergedMinutes(for: "Core"),
                              rem: mergedMinutes(for: "REM"), awake: awakeTotal,
                              stages: displayStages)
        }
    }

    /// Merge overlapping time intervals per stage to prevent double-counting
    /// from duplicate HealthKit samples or multiple sources.
    static func mergeOverlappingIntervals(
        _ intervals: [(stage: String, start: Date, end: Date)]
    ) -> [(stage: String, start: Date, end: Date)] {
        var byStage: [String: [(start: Date, end: Date)]] = [:]
        for iv in intervals {
            byStage[iv.stage, default: []].append((start: iv.start, end: iv.end))
        }

        var result: [(stage: String, start: Date, end: Date)] = []
        for (stage, intervals) in byStage {
            let sorted = intervals.sorted { $0.start < $1.start }
            var merged: [(start: Date, end: Date)] = []
            for iv in sorted {
                if let last = merged.last, iv.start <= last.end {
                    merged[merged.count - 1].end = max(last.end, iv.end)
                } else {
                    merged.append(iv)
                }
            }
            result.append(contentsOf: merged.map { (stage: stage, start: $0.start, end: $0.end) })
        }
        return result
    }

    // MARK: - Chart

    private var sleepChart: some View {
        Chart(nights) { night in
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

    // MARK: - Stats

    private var sleepStats: some View {
        let avgTotal = nights.isEmpty ? 0 :
            nights.map(\.asleep).reduce(0, +) / Double(nights.count)
        let avgDeep = nights.isEmpty ? 0 :
            nights.map(\.deep).reduce(0, +) / Double(nights.count)
        let avgREM = nights.isEmpty ? 0 :
            nights.map(\.rem).reduce(0, +) / Double(nights.count)

        return HStack(spacing: 0) {
            statCol(formatMin(avgTotal), "Avg Asleep")
            statCol(formatMin(avgDeep), "Avg Deep")
            statCol(formatMin(avgREM), "Avg REM")
            statCol("\(nights.count)", "Nights")
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Night List

    private var nightList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(nights.reversed()) { night in
                NavigationLink(destination: SleepNightDetailView(date: night.date, stages: night.stages)) {
                    HStack {
                        Text(MetricAggregator.formatDay(night.date))
                            .font(.caption).foregroundColor(.gray)
                            .frame(width: 90, alignment: .leading)
                        Text(formatMin(night.asleep)).font(.subheadline.bold().monospacedDigit())
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

    // MARK: - Helpers

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
