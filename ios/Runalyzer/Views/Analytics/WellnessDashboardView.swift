import SwiftUI
import Charts

/// Dedicated dashboard for wellness/recovery activities (sauna, cold exposure, mindfulness).
/// Shows session history instead of forcing sparse data through continuous line charts.
struct WellnessDashboardView: View {
    @EnvironmentObject var measurementStore: MeasurementStore

    @State private var timeRange: WellnessRange = .month

    private let cal = Calendar.current
    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }

    private enum WellnessRange: String, CaseIterable {
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

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                rangePicker

                let lookback = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) ?? Date()
                let sessions = measurementStore.measurements(ofType: .wellnessSession)
                    .filter { $0.date >= lookback }
                    .sorted { $0.date > $1.date }

                // Summary card
                summaryCard(sessions: sessions)

                // Weekly bar chart
                weeklyChart(sessions: sessions, lookback: lookback)

                // Activity breakdown
                activityBreakdown(sessions: sessions)

                // Mindfulness (from HealthKit, separate from sessions)
                mindfulnessCard(lookback: lookback)

                // Session list
                sessionList(sessions: sessions)
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Wellness")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Summary

    private func summaryCard(sessions: [SensorMeasurement]) -> some View {
        let totalSec = sessions.flatMap(\.dataPoints)
            .filter { $0.type == DataType.saunaTotalDuration }
            .reduce(0) { $0 + $1.value }
        let totalRounds = sessions.flatMap(\.dataPoints)
            .filter { $0.type == DataType.saunaTotalRounds }
            .reduce(0) { $0 + $1.value }

        return HStack(spacing: 0) {
            statCol("\(sessions.count)", "Sessions")
            statCol("\(Int(totalRounds))", "Rounds")
            statCol(formatDuration(totalSec), "Total Time")
            if sessions.count > 0 {
                statCol(formatDuration(totalSec / Double(sessions.count)), "Avg/Session")
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Weekly Bar Chart

    private func weeklyChart(sessions: [SensorMeasurement], lookback: Date) -> some View {
        // Aggregate total minutes per week
        struct WeekBucket: Identifiable {
            let id: Date // week start
            var minutes: Double = 0
        }

        var buckets: [Date: Double] = [:]
        for session in sessions {
            let weekStart = cal.dateInterval(of: .weekOfYear, for: session.date)?.start ?? session.date
            let mins = session.dataPoints
                .filter { $0.type == DataType.saunaTotalDuration }
                .reduce(0) { $0 + $1.value } / 60
            buckets[weekStart, default: 0] += mins
        }

        let sorted = buckets.sorted { $0.key < $1.key }

        return Group {
            if sorted.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("WEEKLY DURATION").font(.caption2).foregroundColor(.gray)
                    Chart {
                        ForEach(sorted, id: \.key) { week in
                            BarMark(
                                x: .value("Week", week.key, unit: .weekOfYear),
                                y: .value("min", week.value)
                            )
                            .foregroundStyle(.orange)
                            .cornerRadius(4)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) { _ in
                            AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [4]))
                                .foregroundStyle(Color.gray.opacity(0.3))
                            AxisValueLabel().foregroundStyle(.gray)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .automatic(desiredCount: 5)) { value in
                            AxisValueLabel {
                                if let date = value.as(Date.self) {
                                    Text(date, format: .dateTime.day().month(.abbreviated))
                                        .font(.caption2).foregroundColor(.gray)
                                }
                            }
                        }
                    }
                    .frame(height: 140)
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Activity Breakdown

    private func activityBreakdown(sessions: [SensorMeasurement]) -> some View {
        // Count time per round type across all sessions
        var typeMinutes: [WellnessRoundType: Double] = [:]
        for session in sessions {
            for dp in session.dataPoints where dp.type == DataType.saunaRound {
                if let rt = WellnessRoundType(rawValue: dp.unit) {
                    typeMinutes[rt, default: 0] += dp.value / 60
                }
            }
        }

        let sorted = typeMinutes.sorted { $0.value > $1.value }

        return Group {
            if !sorted.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("BY TYPE").font(.caption2).foregroundColor(.gray)
                    ForEach(sorted, id: \.key) { entry in
                        HStack {
                            Circle().fill(roundTypeColor(entry.key)).frame(width: 8, height: 8)
                            Text(entry.key.label).font(.subheadline)
                            Spacer()
                            Text(formatDuration(entry.value * 60))
                                .font(.subheadline.bold().monospacedDigit())
                                .foregroundColor(.gray)
                        }
                    }
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Mindfulness

    private func mindfulnessCard(lookback: Date) -> some View {
        let points = metricIndex.query(type: DataType.mindfulnessDuration, from: lookback, to: Date())
        let totalMin = points.reduce(0) { $0 + $1.value }
        let sessionCount = metricIndex.query(type: DataType.mindfulnessCount, from: lookback, to: Date())
            .reduce(0) { $0 + $1.value }

        return Group {
            if totalMin > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("MINDFULNESS").font(.caption2).foregroundColor(.gray)
                    HStack(spacing: 0) {
                        statCol(String(format: "%.0f", sessionCount), "Sessions")
                        statCol(String(format: "%.0f min", totalMin), "Total")
                        if sessionCount > 0 {
                            statCol(String(format: "%.0f min", totalMin / sessionCount), "Avg")
                        }
                    }
                }
                .padding()
                .background(Color(hex: 0x16213e))
                .cornerRadius(12)
            }
        }
    }

    // MARK: - Session List

    private func sessionList(sessions: [SensorMeasurement]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SESSIONS (\(sessions.count))").font(.caption2).foregroundColor(.gray)

            if sessions.isEmpty {
                Text("No wellness sessions in this period")
                    .font(.caption).foregroundColor(.gray)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                ForEach(sessions) { session in
                    NavigationLink(destination: SaunaSessionDetailView(measurement: session)) {
                        sessionRow(session)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private func sessionRow(_ session: SensorMeasurement) -> some View {
        let rounds = session.dataPoints.filter { $0.type == DataType.saunaRound }
        let totalSec = session.dataPoints
            .first(where: { $0.type == DataType.saunaTotalDuration })?.value ?? 0
        let roundTypes = Set(rounds.compactMap { WellnessRoundType(rawValue: $0.unit) })

        return HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.date, format: .dateTime.weekday(.wide).day().month(.abbreviated))
                    .font(.subheadline)
                HStack(spacing: 6) {
                    Text("\(rounds.count) rounds")
                    Text("·")
                    Text(formatDuration(totalSec))
                }
                .font(.caption).foregroundColor(.gray)

                if !roundTypes.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(Array(roundTypes).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { type in
                            HStack(spacing: 3) {
                                Circle().fill(roundTypeColor(type)).frame(width: 6, height: 6)
                                Text(type.label).font(.caption2).foregroundColor(.gray)
                            }
                        }
                    }
                }
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2).foregroundColor(.gray.opacity(0.5))
        }
        .padding(.vertical, 6)
    }

    // MARK: - Helpers

    private var rangePicker: some View {
        Picker("Range", selection: $timeRange) {
            ForEach(WellnessRange.allCases, id: \.self) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private func statCol(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm", m)
    }

    private func roundTypeColor(_ type: WellnessRoundType) -> Color {
        switch type {
        case .finnish:    return .orange
        case .bioMild:    return .yellow
        case .steam:      return .gray
        case .coldPlunge: return .cyan
        case .whirlpool:  return .blue
        case .rest:       return .green
        }
    }
}
