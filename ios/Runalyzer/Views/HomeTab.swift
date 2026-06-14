import SwiftUI
import Charts

/// Dashboard home page with health overview tiles.
struct HomeTab: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @EnvironmentObject var workoutStore: WorkoutStore
    @EnvironmentObject var habitStore: HabitStore
    @EnvironmentObject var fluidIntakeProvider: FluidIntakeProvider
    @EnvironmentObject var checkInProvider: CheckInProvider

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    @State private var showLabEntry = false
    @State private var showDrinkLog = false
    @State private var showEveningCheckIn = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    // Evening check-in banner (shows after 6 PM if not done)
                    if isEveningAndCheckInPending {
                        eveningCheckInBanner
                    }

                    recoveryTile

                    HStack(spacing: 12) { heartTile; sleepTile }

                    HStack(spacing: 12) { activityTile; habitsTile }

                    HStack(spacing: 12) { hydrationTile; bodyCompTile }

                    HStack(spacing: 12) { workoutsTile; labResultsTile }
                }
                .padding()
            }
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Home")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        Button { showDrinkLog = true } label: {
                            Image(systemName: "drop.fill")
                        }
                        Button { showLabEntry = true } label: {
                            Image(systemName: "cross.case")
                        }
                    }
                }
            }
            .sheet(isPresented: $showLabEntry) {
                LabResultsEntrySheet()
            }
            .sheet(isPresented: $showDrinkLog) {
                DrinkLogSheet()
            }
            .sheet(isPresented: $showEveningCheckIn) {
                EveningCheckInSheet()
            }
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
        let heartDef = CategoryDashboardView.heart()
        let trend = CategoryDashboardView.computeTrend(
            metrics: heartDef.metrics, days: 30,
            metricIndex: metricIndex, sourcePrefs: sourcePrefs
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
        // Read stored sleep score from DB (computed once by SleepMeasurementProvider).
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
        let scorePoints = metricIndex.query(type: DataType.sleepScore, measurementType: .derived,
                                             from: weekAgo, to: Date())
        let lastScore = scorePoints.last

        // Get asleep duration from last night's stages for display
        let nights = SleepTrendView.buildSleepNights(
            metricIndex: metricIndex, sourcePrefs: sourcePrefs,
            lookbackDays: 2, calendar: cal
        )
        let lastNight = nights.last

        return CustomTile {
            SleepDashboardView()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("SLEEP").font(.caption2).foregroundColor(.gray)
                if let sp = lastScore {
                    let score = Int(sp.value.rounded())
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(score)").font(.title.bold().monospacedDigit())
                            .foregroundColor(sleepScoreColor(score))
                        Text(SleepScore.label(for: score)).font(.caption2).foregroundColor(.gray)
                    }
                } else {
                    Text("--").font(.title.bold()).foregroundColor(.gray)
                }
                if let night = lastNight {
                    Text(formatMinutes(night.asleep) + " asleep")
                        .font(.caption2).foregroundColor(.gray)
                } else {
                    Text(" ").font(.caption2)
                }
                Text("Last night").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
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

    // MARK: - Activity

    private var activityTile: some View {
        let activityDef = CategoryDashboardView.activity()
        let trend = CategoryDashboardView.computeTrend(
            metrics: activityDef.metrics, days: 30,
            metricIndex: metricIndex, sourcePrefs: sourcePrefs
        )

        let trendIcon: String
        let trendColor: Color
        switch trend.direction {
        case .improving: trendIcon = "arrow.up.right"; trendColor = .green
        case .stable:    trendIcon = "arrow.right";    trendColor = .gray
        case .declining: trendIcon = "arrow.down.right"; trendColor = .orange
        }

        return CustomTile {
            CategoryDashboardView.activity()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("ACTIVITY").font(.caption2).foregroundColor(.gray)
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

    // MARK: - Body Composition

    private var bodyCompTile: some View {
        let bodyComps = measurementStore.measurements(ofType: .bodyComp)
        let latest = bodyComps.max(by: { $0.date < $1.date })
        let dp = latest.map { measurementStore.dataPoints(for: $0.id) } ?? []
        let displayWeight = dp.first(where: { $0.type == DataType.weight })?.value
        let bodyFat = dp.first(where: { $0.type == DataType.bodyFatPercent })?.value

        return CustomTile {
            BodyCompDashboardView()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("BODY").font(.caption2).foregroundColor(.gray)
                if let w = displayWeight {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.1f", w)).font(.title.bold().monospacedDigit())
                        Text("kg").font(.caption2).foregroundColor(.gray)
                    }
                    if let bf = bodyFat {
                        Text(String(format: "%.1f%% fat", bf))
                            .font(.caption2).foregroundColor(.orange)
                    }
                } else {
                    Text("--").font(.title.bold()).foregroundColor(.gray)
                }
                Spacer()
                Text("Latest").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
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

    // MARK: - Lab Results

    private var labResultsTile: some View {
        let labMeasurements = measurementStore.measurements(ofType: .labResults)
        let latest = labMeasurements.max(by: { $0.date < $1.date })
        let dp = latest.map { measurementStore.dataPoints(for: $0.id) } ?? []

        let glucose = dp.first(where: { $0.type == DataType.glucose })
        let ldl = dp.first(where: { $0.type == DataType.ldlCholesterol })
        let hdl = dp.first(where: { $0.type == DataType.hdlCholesterol })

        return CustomTile {
            CategoryDashboardView.bloodWork()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("LABS").font(.caption2).foregroundColor(.gray)
                if let g = glucose {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", g.value)).font(.title.bold().monospacedDigit())
                        Text("mg/dL").font(.caption2).foregroundColor(.gray)
                    }
                    Text("Glucose").font(.caption2).foregroundColor(.orange)
                } else if let first = dp.first {
                    // Show first available value
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(String(format: "%.0f", first.value)).font(.title.bold().monospacedDigit())
                        Text(first.unit).font(.caption2).foregroundColor(.gray)
                    }
                    Text(DataType.labDisplayName(first.type)).font(.caption2).foregroundColor(.orange)
                } else {
                    Text("--").font(.title.bold()).foregroundColor(.gray)
                    Text("No results").font(.caption2).foregroundColor(.gray)
                }
                if let l = ldl, let h = hdl {
                    Text(String(format: "LDL %.0f · HDL %.0f", l.value, h.value))
                        .font(.caption2).foregroundColor(.gray)
                }
                Spacer()
                if let m = latest {
                    Text(Self.relativeDateLabel(m.date))
                        .font(.caption2).foregroundColor(.gray.opacity(0.6))
                } else {
                    Text("Tap + to add").font(.caption2).foregroundColor(.gray.opacity(0.6))
                }
            }
        }
    }

    private static func relativeDateLabel(_ date: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: date, to: Date()).day ?? 0
        if days == 0 { return "Today" }
        if days == 1 { return "Yesterday" }
        if days < 30 { return "\(days)d ago" }
        let months = days / 30
        return months == 1 ? "1 month ago" : "\(months) months ago"
    }

    // MARK: - Hydration

    private var hydrationTile: some View {
        let total = fluidIntakeProvider.todayTotalMl
        let storedGoal = UserDefaults.standard.integer(forKey: "hydration_goal_ml")
        let goal = Double(storedGoal > 0 ? storedGoal : 2500)
        let progress = min(total / goal, 1.0)

        return CustomTile {
            FluidDashboardView()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("HYDRATION").font(.caption2).foregroundColor(.gray)
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(String(format: "%.0f", total)).font(.title.bold().monospacedDigit())
                        .foregroundColor(progress >= 1.0 ? .cyan : .white)
                    Text("mL").font(.caption2).foregroundColor(.gray)
                }
                Text("\(fluidIntakeProvider.todayDrinks.count) drinks")
                    .font(.caption2).foregroundColor(.gray)
                Spacer()
                Text("Today").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
        }
    }

    // MARK: - Evening Check-in Banner

    private var isEveningAndCheckInPending: Bool {
        let hour = cal.component(.hour, from: Date())
        return hour >= 18 && !checkInProvider.eveningCheckInDoneToday
    }

    private var eveningCheckInBanner: some View {
        Button {
            showEveningCheckIn = true
        } label: {
            HStack {
                Image(systemName: "moon.stars.fill")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text("Evening Check-in")
                        .font(.subheadline.bold())
                        .foregroundStyle(.white)
                    Text("How was your energy today?")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.gray)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.purple.opacity(0.15)))
        }
        .buttonStyle(.plain)
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

}
