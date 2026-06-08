import SwiftUI
import Charts

/// Workout analytics: HR zones across workouts, distance by type, duration trends.
struct WorkoutAnalyticsView: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @State private var timeRange: MetricTrendView.TimeRange = .month
    @State private var activityFilter: String = "All"

    private let cal = Calendar.current

    private var workouts: [SensorMeasurement] {
        guard let start = cal.date(byAdding: .day, value: -timeRange.days, to: Date()) else { return [] }
        return measurementStore.measurements
            .filter { $0.type == .hkWorkout && $0.date >= start }
            .sorted { $0.date < $1.date }
    }

    private var filteredWorkouts: [SensorMeasurement] {
        if activityFilter == "All" { return workouts }
        return workouts.filter { m in
            m.dataPoints.first(where: { $0.type == DataType.workoutType })?.unit == activityFilter
        }
    }

    private var activityTypes: [String] {
        let types = Set(workouts.compactMap { m in
            m.dataPoints.first(where: { $0.type == DataType.workoutType })?.unit
        })
        return ["All"] + types.sorted()
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Time range
                Picker("Range", selection: $timeRange) {
                    ForEach(MetricTrendView.TimeRange.allCases, id: \.self) { r in
                        Text(r.rawValue).tag(r)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)

                // Activity filter
                if activityTypes.count > 2 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(activityTypes, id: \.self) { type in
                                Button(type) { activityFilter = type }
                                    .font(.caption.weight(activityFilter == type ? .semibold : .regular))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(activityFilter == type ? Color.cyan : Color(hex: 0x16213e))
                                    .foregroundColor(activityFilter == type ? .black : .gray)
                                    .clipShape(Capsule())
                            }
                        }
                        .padding(.horizontal)
                    }
                }

                // Stats summary
                summaryStats
                    .padding(.horizontal)

                // HR Zone breakdown (across all filtered workouts)
                hrZoneChart
                    .padding(.horizontal)

                // Distance by activity type
                if activityFilter == "All" {
                    distanceByType
                        .padding(.horizontal)
                }

                // Weekly duration trend
                durationTrend
                    .padding(.horizontal)

                // Workout list
                workoutList
            }
            .padding(.vertical)
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Workouts")
    }

    // MARK: - Summary Stats

    private var summaryStats: some View {
        let totalMin = filteredWorkouts.compactMap { m in
            m.dataPoints.first(where: { $0.type == DataType.workoutDuration })?.value
        }.reduce(0, +) / 60
        let totalDist = filteredWorkouts.compactMap { m in
            m.dataPoints.first(where: { $0.type == DataType.workoutDistance })?.value
        }.reduce(0, +)
        let avgHR = filteredWorkouts.compactMap { m in
            m.dataPoints.first(where: { $0.type == DataType.workoutAvgHR })?.value
        }
        let meanHR = avgHR.isEmpty ? 0 : avgHR.reduce(0, +) / Double(avgHR.count)

        return HStack(spacing: 0) {
            statCol("\(filteredWorkouts.count)", "Workouts")
            statCol(String(format: "%.0f", totalMin), "Total min")
            if totalDist > 0 { statCol(String(format: "%.1f", totalDist), "km") }
            if meanHR > 0 { statCol(String(format: "%.0f", meanHR), "Avg HR") }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - HR Zone Chart

    private var hrZoneChart: some View {
        let profile = UserProfile.load()
        let zones = profile.hrZones
        let colors: [Color] = [.gray, .blue, .green, .orange, .red]

        // Aggregate HR samples across all filtered workouts
        let allHR = filteredWorkouts.flatMap { m in
            m.dataPoints.filter { $0.type == DataType.heartRateSample }
        }
        let sortedHR = allHR.sorted { $0.timestamp < $1.timestamp }

        // Build zone ranges
        var ranges: [(String, ClosedRange<Double>)] = []
        var lower: Double = 0
        for zone in zones {
            ranges.append((zone.name, lower...Double(zone.maxBPM)))
            lower = Double(zone.maxBPM) + 1
        }

        // Calculate time per zone using actual intervals
        var zoneSec: [Int: Double] = [:]
        for i in 0..<sortedHR.count {
            let hr = sortedHR[i].value
            let interval: Double = i < sortedHR.count - 1
                ? sortedHR[i + 1].timestamp.timeIntervalSince(sortedHR[i].timestamp)
                : (sortedHR.count > 1 ? sortedHR.last!.timestamp.timeIntervalSince(sortedHR.first!.timestamp) / Double(sortedHR.count - 1) : 0)
            // Clamp interval to max 30s (gap between workouts)
            let clamped = min(interval, 30)
            for (j, (_, range)) in ranges.enumerated() {
                if range.contains(hr) { zoneSec[j, default: 0] += clamped; break }
            }
        }

        return VStack(alignment: .leading, spacing: 4) {
            Text("HR ZONES (ALL WORKOUTS)").font(.caption2).foregroundColor(.gray)
            let totalSec = zoneSec.values.reduce(0, +)
            ForEach(0..<zones.count, id: \.self) { i in
                let sec = zoneSec[i] ?? 0
                let pct = totalSec > 0 ? sec / totalSec : 0
                HStack(spacing: 8) {
                    Text(zones[i].name).font(.caption).frame(width: 50, alignment: .leading)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 3).fill(colors[i])
                            .frame(width: geo.size.width * pct)
                    }
                    .frame(height: 14)
                    Text(formatDuration(sec)).font(.caption2.monospacedDigit()).foregroundColor(.gray)
                        .frame(width: 50, alignment: .trailing)
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Distance by Activity Type

    private var distanceByType: some View {
        var byType: [(type: String, distance: Double)] = []
        let types = Set(workouts.compactMap { m in
            m.dataPoints.first(where: { $0.type == DataType.workoutType })?.unit
        })
        for type in types.sorted() {
            let dist = workouts
                .filter { m in m.dataPoints.first(where: { $0.type == DataType.workoutType })?.unit == type }
                .compactMap { m in m.dataPoints.first(where: { $0.type == DataType.workoutDistance })?.value }
                .reduce(0, +)
            if dist > 0.1 { byType.append((type: type, distance: dist)) }
        }

        return VStack(alignment: .leading, spacing: 4) {
            if !byType.isEmpty {
                Text("DISTANCE BY ACTIVITY").font(.caption2).foregroundColor(.gray)
                Chart(byType, id: \.type) { item in
                    BarMark(x: .value("km", item.distance), y: .value("Type", item.type))
                        .foregroundStyle(Color.cyan)
                        .annotation(position: .trailing) {
                            Text(String(format: "%.1f km", item.distance))
                                .font(.caption2).foregroundColor(.gray)
                        }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(byType.count) * 35)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Duration Trend (weekly)

    private var durationTrend: some View {
        var byWeek: [Date: Double] = [:]
        for m in filteredWorkouts {
            let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: m.date)
            if let weekStart = cal.date(from: comps) {
                let dur = m.dataPoints.first(where: { $0.type == DataType.workoutDuration })?.value ?? 0
                byWeek[weekStart, default: 0] += dur / 60
            }
        }
        let weeks = byWeek.keys.sorted().map { (date: $0, minutes: byWeek[$0] ?? 0) }

        return VStack(alignment: .leading, spacing: 4) {
            if !weeks.isEmpty {
                Text("WEEKLY DURATION").font(.caption2).foregroundColor(.gray)
                Chart(weeks, id: \.date) { w in
                    BarMark(x: .value("Week", w.date, unit: .weekOfYear), y: .value("Min", w.minutes))
                        .foregroundStyle(Color.cyan.opacity(0.7))
                }
                .chartYAxisLabel("minutes")
                .frame(height: 120)
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    // MARK: - Workout List

    private var workoutList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("WORKOUTS").font(.caption2).foregroundColor(.gray)
                .padding(.horizontal).padding(.top, 12).padding(.bottom, 4)

            ForEach(filteredWorkouts.reversed()) { m in
                NavigationLink(destination: MeasurementDetailView(measurement: m)) {
                    let type = m.dataPoints.first(where: { $0.type == DataType.workoutType })?.unit ?? "Workout"
                    let dur = m.dataPoints.first(where: { $0.type == DataType.workoutDuration })?.value ?? 0
                    let hr = m.dataPoints.first(where: { $0.type == DataType.workoutAvgHR })?.value

                    HStack {
                        Text(type).font(.subheadline).frame(width: 70, alignment: .leading)
                        Text(formatDuration(dur)).font(.caption.monospacedDigit())
                        if let hr { Text(String(format: "%.0f bpm", hr)).font(.caption2).foregroundColor(.gray) }
                        Spacer()
                        Text(MetricAggregator.formatDay(m.date)).font(.caption2).foregroundColor(.gray)
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.gray.opacity(0.5))
                    }
                    .padding(.horizontal).padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Divider().background(Color.gray.opacity(0.2)).padding(.leading)
            }
        }
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
        .padding(.horizontal)
    }

    // MARK: - Helpers

    private func statCol(_ value: String, _ label: String) -> some View {
        VStack {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
