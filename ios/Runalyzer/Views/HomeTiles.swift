import SwiftUI

// MARK: - HomeTab Tile Definitions
// Extracted from HomeTab.swift to keep the main view body under 100 lines.

extension HomeTab {

    // MARK: - Recovery

    var recoveryTile: some View {
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

    // MARK: - Heart

    var heartTile: some View {
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

    var sleepTile: some View {
        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date())!
        let scorePoints = metricIndex.query(type: DataType.sleepScore, measurementType: .derived,
                                             from: weekAgo, to: Date())
        let lastScore = scorePoints.last

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

    var habitsTile: some View {
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

    var activityTile: some View {
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

    var bodyCompTile: some View {
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

    var workoutsTile: some View {
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

    var labResultsTile: some View {
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

    // MARK: - Hydration

    var hydrationTile: some View {
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

    var eveningCheckInBanner: some View {
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

    // MARK: - Recovery Activities

    var recoveryActivitiesTile: some View {
        let def = CategoryDashboardView.recoveryActivities()
        let trend = CategoryDashboardView.computeTrend(
            metrics: def.metrics, days: 30,
            measurementType: nil,
            metricIndex: metricIndex, sourcePrefs: sourcePrefs
        )

        let weekAgo = cal.date(byAdding: .day, value: -7, to: Date()) ?? Date()

        // Weekly wellness minutes (stored in seconds)
        let wellnessPoints = metricIndex.query(type: DataType.saunaTotalDuration,
                                             from: weekAgo, to: Date())
        let wellnessMin = Int(wellnessPoints.reduce(0) { $0 + $1.value } / 60)

        // Weekly mindfulness minutes
        let mindfulPoints = metricIndex.query(type: DataType.mindfulnessDuration,
                                               from: weekAgo, to: Date())
        let mindfulMin = Int(mindfulPoints.reduce(0) { $0 + $1.value })

        let trendIcon: String
        let trendColor: Color
        switch trend.direction {
        case .improving: trendIcon = "arrow.up.right"; trendColor = .green
        case .stable:    trendIcon = "arrow.right";    trendColor = .gray
        case .declining: trendIcon = "arrow.down.right"; trendColor = .orange
        }

        return CustomTile {
            CategoryDashboardView.recoveryActivities()
        } content: {
            VStack(alignment: .leading, spacing: 6) {
                Text("RECOVERY").font(.caption2).foregroundColor(.gray)
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: trendIcon).font(.title3)
                    Text(trend.direction.rawValue).font(.title3.weight(.semibold))
                }
                .foregroundColor(trendColor)

                if wellnessMin > 0 || mindfulMin > 0 {
                    HStack(spacing: 8) {
                        if wellnessMin > 0 {
                            Label("\(wellnessMin)m", systemImage: "flame.fill")
                                .font(.caption2).foregroundColor(.orange)
                        }
                        if mindfulMin > 0 {
                            Label("\(mindfulMin)m", systemImage: "brain.head.profile")
                                .font(.caption2).foregroundColor(.purple)
                        }
                    }
                }

                Text("7D").font(.caption2).foregroundColor(.gray.opacity(0.6))
            }
        }
    }
}
