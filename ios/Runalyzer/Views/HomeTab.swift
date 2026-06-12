import SwiftUI
import Charts

/// Dashboard home page with health overview tiles.
struct HomeTab: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var habitStore: HabitStore

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    recoveryTile

                    heartTile

                    HStack(spacing: 12) { sleepTile; habitsTile }

                    HStack(spacing: 12) { stepsTile; workoutsTile }
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Home")
        }
    }

    // MARK: - Recovery

    private var recoveryTile: some View {
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let todayScore = latestRecoveryScore(on: today)
        let yesterdayScore = latestRecoveryScore(on: yesterday)
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!
        let weekScores = metricIndex.query(type: DataType.recoveryIndex, from: weekAgo, to: Date())

        let badge: DashboardTile<MetricTrendView>.Badge? = {
            guard let t = todayScore, let y = yesterdayScore else { return nil }
            let diff = t - y
            return .init(text: String(format: "%+.0f", diff), color: diff >= 0 ? .green : .orange)
        }()

        return DashboardTile(
            title: "RECOVERY",
            value: todayScore.map { String(Int($0.rounded())) } ?? "--",
            unit: "/ 100",
            detail: todayScore.map { recoveryLabel($0) },
            period: "Today",
            valueColor: todayScore.map { recoveryColor($0) } ?? .gray,
            badge: badge,
            sparklineValues: weekScores.count > 1 ? weekScores.map(\.value) : nil,
            sparklineColor: .cyan
        ) {
            MetricTrendView(metricType: DataType.recoveryIndex, title: "Recovery", unit: "", color: .cyan)
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

    // MARK: - Heart

    private var heartTile: some View {
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
        let rhrPoints = metricIndex.query(type: DataType.restingHeartRate, measurementType: .metric,
                                          from: weekAgo, to: Date(), filter: sourcePrefs)
        let hrvPoints = metricIndex.query(type: DataType.hrvSDNN, measurementType: .metric,
                                          from: weekAgo, to: Date(), filter: sourcePrefs)
        let latestRHR = rhrPoints.last?.value
        // Daily average for HRV
        var byDay: [Date: [Double]] = [:]
        for p in hrvPoints {
            let day = cal.startOfDay(for: p.timestamp)
            byDay[day, default: []].append(p.value)
        }
        let latestHRV = byDay.keys.sorted().last.flatMap { day in
            let vals = byDay[day]!
            return vals.reduce(0, +) / Double(vals.count)
        }

        return CustomTile {
            CategoryDashboardView.heart()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("HEART").font(.caption2).foregroundColor(.gray)
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(latestRHR.map { String(Int($0)) } ?? "--")
                                .font(.title.bold().monospacedDigit())
                            Text("bpm").font(.caption2).foregroundColor(.gray)
                        }
                        Text("RHR").font(.caption2).foregroundColor(.red)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(alignment: .firstTextBaseline, spacing: 2) {
                            Text(latestHRV.map { String(Int($0)) } ?? "--")
                                .font(.title.bold().monospacedDigit())
                            Text("ms").font(.caption2).foregroundColor(.gray)
                        }
                        Text("HRV").font(.caption2).foregroundColor(.purple)
                    }
                    Spacer()
                    if rhrPoints.count > 1 {
                        Sparkline(values: rhrPoints.map(\.value), color: .red)
                            .frame(width: 80, height: 24)
                    }
                }
                Text("7D").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
        }
    }

    // MARK: - Sleep

    private var sleepTile: some View {
        let nights = SleepTrendView.buildSleepNights(
            metricIndex: metricIndex, sourcePrefs: sourcePrefs,
            lookbackDays: 2, calendar: cal
        )
        let lastNight = nights.last

        return DashboardTile(
            title: "SLEEP",
            value: lastNight.map { formatMinutes($0.asleep) } ?? "--",
            detail: lastNight.map { formatMinutes($0.inBed) + " in bed" },
            period: "Last night"
        ) {
            SleepTrendView()
        }
    }

    // MARK: - Habits

    private var habitsTile: some View {
        let today = cal.startOfDay(for: Date())
        let scheduled = habitStore.habits.filter { $0.isScheduled(on: today) }
        let completed = scheduled.filter { habit in
            habitStore.todayLogs.contains { $0.habitId == habit.id && $0.isCompleted }
        }.count

        return CustomTile {
            HabitsView()
        } content: {
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

    // MARK: - Steps

    private var stepsTile: some View {
        let today = cal.startOfDay(for: Date())
        let stepsPoints = metricIndex.query(type: DataType.steps, measurementType: .metric,
                                            from: today, to: Date(), filter: sourcePrefs)
        let total = stepsPoints.map(\.value).max() ?? 0

        return DashboardTile(
            title: "STEPS",
            value: total > 0 ? String(format: "%.0f", total) : "--",
            detail: " ",
            period: "Today"
        ) {
            MetricTrendView(metricType: DataType.steps, title: "Steps", unit: "steps", color: .green)
        }
    }

    // MARK: - Workouts

    private var workoutsTile: some View {
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
        let recentWorkouts = workoutStore.workouts(from: weekAgo, to: Date())
        let totalMinutes = recentWorkouts.compactMap(\.durationSec).reduce(0, +) / 60

        return DashboardTile(
            title: "WORKOUTS",
            value: "\(recentWorkouts.count)",
            detail: formatMinutes(totalMinutes),
            period: "7D"
        ) {
            WorkoutAnalyticsView()
        }
    }

    // MARK: - Helpers

    private func formatMinutes(_ m: Double) -> String {
        let h = Int(m) / 60, min = Int(m) % 60
        return h > 0 ? String(format: "%dh %02dm", h, min) : String(format: "%dm", min)
    }
}
