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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Recovery — full width but compact
                    NavigationLink(destination: MetricTrendView(
                        metricType: DataType.recoveryIndex, title: "Recovery", unit: "", color: .cyan
                    )) { recoveryTile }
                    .buttonStyle(.plain)

                    // RHR + HRV — half width each
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

                    // Sleep + Habits — half width each, compact
                    HStack(spacing: 12) {
                        NavigationLink(destination: SleepTrendView()) {
                            sleepTile
                        }
                        .buttonStyle(.plain)

                        NavigationLink(destination: HabitsView()) {
                            habitsTile
                        }
                        .buttonStyle(.plain)
                    }

                    // Steps + Workouts — half width each, matched height
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

        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!
        let weekScores = metricIndex.query(type: DataType.recoveryIndex, from: weekAgo, to: Date())

        return tile {
            HStack(spacing: 12) {
                // Left: score
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("RECOVERY").font(.caption2).foregroundColor(.gray)
                        Spacer()
                    }
                    if let score = todayScore {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(String(Int(score.rounded())))
                                .font(.system(size: 36, weight: .bold, design: .rounded))
                                .foregroundColor(recoveryColor(score))
                            Text("/ 100").font(.caption2).foregroundColor(.gray)
                        }
                        HStack(spacing: 8) {
                            Text(recoveryLabel(score))
                                .font(.caption2).foregroundColor(recoveryColor(score))
                            if let y = yesterdayScore {
                                let diff = score - y
                                Label(String(format: "%+.0f", diff),
                                      systemImage: diff >= 0 ? "arrow.up.right" : "arrow.down.right")
                                    .font(.caption2)
                                    .foregroundColor(diff >= 0 ? .green : .orange)
                            }
                        }
                    } else {
                        Text("--").font(.system(size: 36, weight: .bold, design: .rounded)).foregroundColor(.gray)
                        Text("No data").font(.caption2).foregroundColor(.gray)
                    }
                }
                .frame(minWidth: 100, alignment: .leading)

                // Right: sparkline
                if weekScores.count > 1 {
                    sparkline(weekScores.map(\.value), color: .cyan)
                        .frame(height: 36)
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
                Text("7D").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
        }
    }

    // MARK: - HRV Tile

    private var hrvTile: some View {
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
        let points = metricIndex.query(type: DataType.hrvSDNN, measurementType: .metric,
                                       from: weekAgo, to: Date(), filter: sourcePrefs)
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
                Text("7D").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
        }
    }

    // MARK: - Sleep Tile

    private var sleepTile: some View {
        let nights = SleepTrendView.buildSleepNights(
            metricIndex: metricIndex, sourcePrefs: sourcePrefs,
            lookbackDays: 2, calendar: cal
        )
        let lastNight = nights.last

        return tile {
            VStack(alignment: .leading, spacing: 6) {
                Text("SLEEP").font(.caption2).foregroundColor(.gray)
                if let night = lastNight, night.asleep > 0 {
                    Text(formatMinutes(night.asleep)).font(.title.bold().monospacedDigit())
                    Text(formatMinutes(night.inBed) + " in bed")
                        .font(.caption2).foregroundColor(.gray)
                } else {
                    Text("--").font(.title.bold()).foregroundColor(.gray)
                    Text(" ").font(.caption2)
                }
                Text("Last night").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
        }
    }

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
                    Text("--").font(.title.bold()).foregroundColor(.gray)
                    Text(" ").font(.caption2)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(completed)").font(.title.bold().monospacedDigit())
                        Text("/ \(scheduled.count)").font(.caption2).foregroundColor(.gray)
                    }
                    ForEach(scheduled.prefix(3)) { habit in
                        let done = habitStore.todayLogs.contains { $0.habitId == habit.id && $0.isCompleted }
                        HStack(spacing: 4) {
                            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 10))
                                .foregroundColor(done ? Color(hex: habit.color) : .gray)
                            Text(habit.name).font(.caption2).foregroundColor(done ? .white : .gray)
                                .lineLimit(1)
                        }
                    }
                    if scheduled.count > 3 {
                        Text("+\(scheduled.count - 3) more").font(.caption2).foregroundColor(.gray)
                    }
                }
                Text("Today").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
        }
    }

    // MARK: - Steps Tile

    private var stepsTile: some View {
        let today = cal.startOfDay(for: Date())
        let stepsPoints = metricIndex.query(type: DataType.steps, measurementType: .metric,
                                            from: today, to: Date(), filter: sourcePrefs)
        let total = stepsPoints.map(\.value).max() ?? 0

        return tile {
            VStack(alignment: .leading, spacing: 6) {
                Text("STEPS").font(.caption2).foregroundColor(.gray)
                if total > 0 {
                    Text(String(format: "%.0f", total)).font(.title.bold().monospacedDigit())
                } else {
                    Text("--").font(.title.bold()).foregroundColor(.gray)
                }
                Text("Today").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
        }
    }

    // MARK: - Workouts Tile

    private var workoutsTile: some View {
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
        let recentWorkouts = workoutStore.workouts(from: weekAgo, to: Date())
        let totalMinutes = recentWorkouts.compactMap(\.durationSec).reduce(0, +) / 60

        return tile {
            VStack(alignment: .leading, spacing: 6) {
                Text("WORKOUTS").font(.caption2).foregroundColor(.gray)
                Text("\(recentWorkouts.count)").font(.title.bold().monospacedDigit())
                Text(formatMinutes(totalMinutes))
                    .font(.caption2).foregroundColor(.gray)
                Text("7D").font(.caption2).foregroundColor(.gray.opacity(0.6))
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
