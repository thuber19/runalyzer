import SwiftUI
import Charts

/// Dashboard home page with health overview tiles.
struct HomeTab: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var habitStore: HabitStore

    /// MetricIndex is stateless — safe to recreate, but cache to communicate intent.
    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    // Note: MetricIndex is a lightweight struct with no cached state — the computed property
    // is equivalent to storing it. The SQL queries it runs are the real cost, not construction.

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    NavigationLink(destination: MetricTrendView(
                        metricType: DataType.recoveryIndex, title: "Recovery", unit: "", color: .cyan
                    )) { recoveryTile }
                    .buttonStyle(.plain)

                    HStack(spacing: 12) {
                        NavigationLink(destination: MetricTrendView(
                            metricType: DataType.restingHeartRate, title: "Resting HR", unit: "bpm", color: .red
                        )) { rhrTile }
                        .buttonStyle(.plain)

                        NavigationLink(destination: MetricTrendView(
                            metricType: DataType.hrvSDNN, title: "HRV (SDNN)", unit: "ms", color: .purple
                        )) { hrvTile }
                        .buttonStyle(.plain)
                    }

                    NavigationLink(destination: SleepTrendView()) {
                        sleepTile
                    }
                    .buttonStyle(.plain)

                    NavigationLink(destination: HabitsView()) {
                        habitsTile
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 12) {
                        NavigationLink(destination: MetricTrendView(
                            metricType: DataType.steps, title: "Steps", unit: "steps", color: .green
                        )) { stepsTile }
                        .buttonStyle(.plain)

                        NavigationLink(destination: WorkoutAnalyticsView()) {
                            workoutsTile
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Home")
        }
    }

    // MARK: - Recovery Score Tile

    private var recoveryTile: some View {
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let todayScore = latestRecoveryScore(on: today)
        let yesterdayScore = latestRecoveryScore(on: yesterday)

        // 7-day history for sparkline
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!
        let weekScores = metricIndex.query(type: DataType.recoveryIndex, from: weekAgo, to: Date())

        return tile {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("RECOVERY").font(.caption2).foregroundColor(.gray)
                    Spacer()
                    if let t = todayScore, let y = yesterdayScore {
                        let diff = t - y
                        Label(String(format: "%+.0f", diff),
                              systemImage: diff >= 0 ? "arrow.up.right" : "arrow.down.right")
                            .font(.caption2)
                            .foregroundColor(diff >= 0 ? .green : .orange)
                    }
                }

                if let score = todayScore {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(String(Int(score.rounded())))
                            .font(.system(size: 48, weight: .bold, design: .rounded))
                            .foregroundColor(recoveryColor(score))
                        Text("/ 100").font(.caption).foregroundColor(.gray)
                    }
                    Text(recoveryLabel(score)).font(.caption).foregroundColor(recoveryColor(score))
                } else {
                    Text("--").font(.system(size: 48, weight: .bold, design: .rounded)).foregroundColor(.gray)
                    Text("No data today").font(.caption).foregroundColor(.gray)
                }

                if weekScores.count > 1 {
                    sparkline(weekScores.map(\.value), color: .cyan)
                        .frame(height: 30)
                }
            }
        }
    }

    private func recoveryColor(_ score: Double) -> Color {
        switch score {
        case 75...: return .green
        case 50...: return .cyan
        case 25...: return .orange
        default:    return .red
        }
    }

    private func recoveryLabel(_ score: Double) -> String {
        switch score {
        case 75...: return "Excellent"
        case 50...: return "Good"
        case 25...: return "Fair"
        default:    return "Poor"
        }
    }

    private func latestRecoveryScore(on day: Date) -> Double? {
        let dayStart = cal.startOfDay(for: day)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return nil }
        return metricIndex.query(type: DataType.recoveryIndex, from: dayStart, to: dayEnd).first?.value
    }

    // MARK: - RHR Tile

    private var rhrTile: some View {
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
        let points = metricIndex.query(type: DataType.restingHeartRate, measurementType: .metric,
                                       from: weekAgo, to: Date(), filter: sourcePrefs)
        let latest = points.last?.value

        return tile {
            VStack(alignment: .leading, spacing: 6) {
                Text("RESTING HR").font(.caption2).foregroundColor(.gray)
                if let hr = latest {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(Int(hr))).font(.title.bold().monospacedDigit())
                        Text("bpm").font(.caption2).foregroundColor(.gray)
                    }
                } else {
                    Text("--").font(.title.bold()).foregroundColor(.gray)
                }
                if points.count > 1 {
                    sparkline(points.map(\.value), color: .red)
                        .frame(height: 24)
                }
            }
        }
    }

    // MARK: - HRV Tile

    private var hrvTile: some View {
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
        let points = metricIndex.query(type: DataType.hrvSDNN, measurementType: .metric,
                                       from: weekAgo, to: Date(), filter: sourcePrefs)
        // Daily averages for sparkline
        var dailyAvgs: [Double] = []
        var byDay: [Date: [Double]] = [:]
        for p in points {
            let day = cal.startOfDay(for: p.timestamp)
            byDay[day, default: []].append(p.value)
        }
        for day in byDay.keys.sorted() {
            let vals = byDay[day]!
            dailyAvgs.append(vals.reduce(0, +) / Double(vals.count))
        }
        let latest = dailyAvgs.last

        return tile {
            VStack(alignment: .leading, spacing: 6) {
                Text("HRV (SDNN)").font(.caption2).foregroundColor(.gray)
                if let hrv = latest {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(Int(hrv))).font(.title.bold().monospacedDigit())
                        Text("ms").font(.caption2).foregroundColor(.gray)
                    }
                } else {
                    Text("--").font(.title.bold()).foregroundColor(.gray)
                }
                if dailyAvgs.count > 1 {
                    sparkline(dailyAvgs, color: .purple)
                        .frame(height: 24)
                }
            }
        }
    }

    // MARK: - Sleep Tile

    private var sleepTile: some View {
        // Find the most recent sleep measurement (today or yesterday)
        let today = cal.startOfDay(for: Date())
        let sleepMeasurement = metricIndex.metricMeasurement(forDay: today, containingType: DataType.sleepStage)
            ?? metricIndex.metricMeasurement(forDay: cal.date(byAdding: .day, value: -1, to: today)!,
                                             containingType: DataType.sleepStage)
        let sleepPoints = sourcePrefs.apply(
            to: sleepMeasurement?.dataPoints.filter { $0.type == DataType.sleepStage } ?? [],
            dataType: DataType.sleepStage
        )

        // Prefer Watch staged data over generic iPhone data
        let hasStages = sleepPoints.contains { ["Core", "Deep", "REM"].contains($0.unit) }
        let filtered: [DataPoint]
        if hasStages {
            let stagedSources = Set(sleepPoints.filter { ["Core", "Deep", "REM"].contains($0.unit) }.map(\.source))
            filtered = sleepPoints.filter { stagedSources.contains($0.source) || $0.unit == "Awake" }
        } else {
            filtered = sleepPoints
        }

        let stages = filtered.compactMap { p -> (String, Double)? in
            guard let end = p.endTimestamp else { return nil }
            return (p.unit, end.timeIntervalSince(p.timestamp) / 60)
        }
        let sleepMin = stages.filter { ["Deep", "Core", "REM", "Asleep"].contains($0.0) }
            .reduce(0) { $0 + $1.1 }
        let deepMin = stages.filter { $0.0 == "Deep" }.reduce(0) { $0 + $1.1 }
        let remMin = stages.filter { $0.0 == "REM" }.reduce(0) { $0 + $1.1 }

        return tile {
            VStack(alignment: .leading, spacing: 8) {
                Text("LAST NIGHT").font(.caption2).foregroundColor(.gray)
                if sleepMin > 0 {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading) {
                            Text(formatMinutes(sleepMin)).font(.title2.bold().monospacedDigit())
                            Text("Asleep").font(.caption2).foregroundColor(.gray)
                        }
                        VStack(alignment: .leading) {
                            Text(formatMinutes(deepMin)).font(.headline.monospacedDigit())
                            Text("Deep").font(.caption2).foregroundColor(.indigo)
                        }
                        VStack(alignment: .leading) {
                            Text(formatMinutes(remMin)).font(.headline.monospacedDigit())
                            Text("REM").font(.caption2).foregroundColor(.cyan)
                        }
                    }
                } else {
                    Text("No sleep data").font(.caption).foregroundColor(.gray)
                }
            }
        }
    }

    // MARK: - Steps Tile

    private var stepsTile: some View {
        let today = cal.startOfDay(for: Date())
        let todayEnd = Date()
        let stepsPoints = metricIndex.query(type: DataType.steps, measurementType: .metric,
                                            from: today, to: todayEnd, filter: sourcePrefs)
        // Use max source value (not sum — iPhone + Watch count same steps)
        let total = stepsPoints.map(\.value).max() ?? 0

        return tile {
            VStack(alignment: .leading, spacing: 6) {
                Text("STEPS").font(.caption2).foregroundColor(.gray)
                if total > 0 {
                    Text(String(format: "%.0f", total)).font(.title.bold().monospacedDigit())
                } else {
                    Text("--").font(.title.bold()).foregroundColor(.gray)
                }
                Text("Today").font(.caption2).foregroundColor(.gray)
            }
        }
    }

    // MARK: - Workouts Tile

    // MARK: - Habits Tile

    private var habitsTile: some View {
        let today = cal.startOfDay(for: Date())
        let scheduled = habitStore.habits.filter { $0.isScheduled(on: today) }
        let completed = scheduled.filter { habit in
            habitStore.todayLogs.contains { $0.habitId == habit.id && $0.isCompleted }
        }.count

        return tile {
            VStack(alignment: .leading, spacing: 6) {
                Text("HABITS").font(.caption2).foregroundColor(.gray)
                if scheduled.isEmpty {
                    Text("No habits yet").font(.caption).foregroundColor(.gray)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(completed)").font(.title.bold().monospacedDigit())
                        Text("/ \(scheduled.count)").font(.caption).foregroundColor(.gray)
                    }
                    // Show first few habit names
                    ForEach(scheduled.prefix(3)) { habit in
                        let done = habitStore.todayLogs.contains { $0.habitId == habit.id && $0.isCompleted }
                        HStack(spacing: 6) {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundColor(done ? Color(hex: habit.color) : .gray)
                            Text(habit.name).font(.caption).foregroundColor(done ? .white : .gray)
                        }
                    }
                    if scheduled.count > 3 {
                        Text("+\(scheduled.count - 3) more").font(.caption2).foregroundColor(.gray)
                    }
                }
            }
        }
    }

    private var workoutsTile: some View {
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
        let recentWorkouts = workoutStore.workouts(from: weekAgo, to: Date())
        let totalMinutes = recentWorkouts.compactMap(\.durationSec).reduce(0, +) / 60

        return tile {
            VStack(alignment: .leading, spacing: 6) {
                Text("WORKOUTS").font(.caption2).foregroundColor(.gray)
                Text("\(recentWorkouts.count)").font(.title.bold().monospacedDigit())
                Text(String(format: "%.0fm this week", totalMinutes))
                    .font(.caption2).foregroundColor(.gray)
            }
        }
    }

    // MARK: - Shared Components

    private func tile<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)
    }

    private func sparkline(_ values: [Double], color: Color) -> some View {
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                LineMark(x: .value("", i), y: .value("", v))
                    .foregroundStyle(color)
                AreaMark(x: .value("", i), y: .value("", v))
                    .foregroundStyle(color.opacity(0.1))
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
    }

    private func formatMinutes(_ m: Double) -> String {
        let h = Int(m) / 60, min = Int(m) % 60
        return h > 0 ? String(format: "%dh %02dm", h, min) : String(format: "%dm", min)
    }
}
