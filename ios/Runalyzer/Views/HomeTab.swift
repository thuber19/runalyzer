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

                    HStack(spacing: 12) { heartTile; sleepTile }

                    HStack(spacing: 12) { habitsTile; workoutsTile }

                    HStack(spacing: 12) { stepsTile; Spacer().frame(maxWidth: .infinity) }
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
        // Use all 4 metrics — same as CategoryDashboardView.heart()
        let monthAgo = cal.date(byAdding: .day, value: -30, to: Date())!

        let trend = HealthScore.heartTrend(
            rhrDailyValues: dailyValues(metricIndex.query(
                type: DataType.restingHeartRate, measurementType: .metric,
                from: monthAgo, to: Date(), filter: sourcePrefs)),
            hrvDailyValues: dailyAvgValues(metricIndex.query(
                type: DataType.hrvSDNN, measurementType: .metric,
                from: monthAgo, to: Date(), filter: sourcePrefs)),
            vo2DailyValues: dailyValues(metricIndex.query(
                type: DataType.vo2Max, measurementType: .metric,
                from: monthAgo, to: Date(), filter: sourcePrefs)),
            spo2DailyValues: dailyValues(metricIndex.query(
                type: DataType.bloodOxygen, measurementType: .metric,
                from: monthAgo, to: Date(), filter: sourcePrefs))
        )

        let trendIcon: String
        let trendColor: Color
        switch trend.direction {
        case .improving: trendIcon = "arrow.up.right"; trendColor = .green
        case .stable:    trendIcon = "arrow.right";    trendColor = .gray
        case .declining: trendIcon = "arrow.down.right"; trendColor = .orange
        }

        return CustomTile {
            CategoryDashboardView.heart()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("HEART").font(.caption2).foregroundColor(.gray)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: trendIcon).font(.title3)
                    Text(trend.direction.rawValue).font(.title3.weight(.semibold))
                }
                .foregroundColor(trendColor)
                Spacer()
                Text("30D").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
        }
    }

    // MARK: - Sleep

    private var sleepTile: some View {
        let nights = SleepTrendView.buildSleepNights(
            metricIndex: metricIndex, sourcePrefs: sourcePrefs,
            lookbackDays: 14, calendar: cal
        )
        let lastNight = nights.last

        // Compute sleep score for last night
        let recentBedtimes = nights.suffix(7).compactMap { night -> Date? in
            night.stages.filter { ["Deep", "Core", "REM"].contains($0.stage) }
                .map(\.start).min()
        }
        let sleepResult: SleepScore.Result? = lastNight.map {
            SleepScore.fromStages(stages: $0.stages, recentBedtimes: recentBedtimes)
        }

        let badge: DashboardTile<SleepTrendView>.Badge? = sleepResult.map {
            .init(text: "\($0.total)", color: sleepScoreColor($0.total))
        }

        return DashboardTile(
            title: "SLEEP",
            value: lastNight.map { formatMinutes($0.asleep) } ?? "--",
            detail: lastNight.map { formatMinutes($0.inBed) + " in bed" },
            period: "Last night",
            badge: badge
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

    private func sleepScoreColor(_ score: Int) -> Color {
        switch score {
        case 75...: return .green
        case 50...: return .cyan
        case 25...: return .orange
        default:    return .red
        }
    }

    private func formatMinutes(_ m: Double) -> String {
        let h = Int(m) / 60, min = Int(m) % 60
        return h > 0 ? String(format: "%dh %02dm", h, min) : String(format: "%dm", min)
    }

    /// One value per day (latest value for the day).
    private func dailyValues(_ points: [DataPoint]) -> [(date: Date, value: Double)] {
        var byDay: [Date: Double] = [:]
        for p in points {
            let day = cal.startOfDay(for: p.timestamp)
            byDay[day] = p.value // last value wins
        }
        return byDay.keys.sorted().map { (date: $0, value: byDay[$0]!) }
    }

    /// One value per day (daily average).
    private func dailyAvgValues(_ points: [DataPoint]) -> [(date: Date, value: Double)] {
        var byDay: [Date: [Double]] = [:]
        for p in points {
            let day = cal.startOfDay(for: p.timestamp)
            byDay[day, default: []].append(p.value)
        }
        return byDay.keys.sorted().map { day in
            let vals = byDay[day]!
            return (date: day, value: vals.reduce(0, +) / Double(vals.count))
        }
    }
}
