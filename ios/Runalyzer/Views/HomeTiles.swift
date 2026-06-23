import SwiftUI

// MARK: - HomeInsight Model

/// Priority levels for editorial feed ordering.
enum InsightPriority: Int, Comparable {
    case urgent = 0
    case attention = 1
    case positive = 2
    case neutral = 3

    static func < (lhs: InsightPriority, rhs: InsightPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A single insight card/line for the editorial feed.
struct HomeInsight: Identifiable {
    let id: String
    let priority: InsightPriority
    let icon: String
    let iconColor: Color
    let title: String
    let headline: String
    let detail: String?
    let sparklineValues: [Double]?
    let sparklineColor: Color?
    let destination: AnyView
}

// MARK: - Insight Generation

extension HomeTab {

    /// Generate headline text for the aura hero.
    func generateHeadline(recovery: Double?, sleep: Double?,
                          heartTrend: CategoryTrend.Direction?) -> String {
        let greeting = timeOfDayGreeting()

        if let r = recovery, r >= 80 { return "\(greeting). You're well recovered." }
        if let r = recovery, r < 35 { return "\(greeting). Take it easy today." }
        if heartTrend == .improving { return "\(greeting). Your heart health is improving." }
        if let s = sleep, s >= 85 { return "\(greeting). Great sleep last night." }
        if let r = recovery, r >= 50, heartTrend == .stable {
            return "\(greeting). Everything looks good."
        }
        return "\(greeting)."
    }

    /// Compute the vibe score from recovery + sleep.
    func computeVibeScore(recovery: Double?, sleep: Double?) -> Double? {
        switch (recovery, sleep) {
        case let (r?, s?): return r * 0.6 + s * 0.4
        case let (r?, nil): return r
        case let (nil, s?): return s
        case (nil, nil): return nil
        }
    }

    /// Build all insights for the editorial feed, sorted by priority.
    func buildInsights() -> [HomeInsight] {
        var insights: [HomeInsight] = []

        let today = cal.startOfDay(for: Date())
        let weekAgo = cal.date(byAdding: .day, value: -7, to: today)!
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!

        // Recovery
        let todayRecovery = latestRecoveryScore(on: today)
        let yesterdayRecovery = latestRecoveryScore(on: yesterday)
        let weekScores = metricIndex.query(type: DataType.recoveryIndex, from: weekAgo, to: Date())

        let recoveryDrop = (todayRecovery != nil && yesterdayRecovery != nil)
            ? yesterdayRecovery! - todayRecovery! : 0

        let recoveryPriority: InsightPriority = {
            if let r = todayRecovery {
                if r < 35 || recoveryDrop > 15 { return .urgent }
                if r < 50 { return .attention }
                if r >= 75 { return .positive }
            }
            return .neutral
        }()

        let recoveryDetail: String? = {
            if let t = todayRecovery, let y = yesterdayRecovery {
                let diff = t - y
                return String(format: "%+.0f from yesterday", diff)
            }
            return nil
        }()

        insights.append(HomeInsight(
            id: "recovery",
            priority: recoveryPriority,
            icon: "bolt.fill",
            iconColor: todayRecovery.map { recoveryColor($0) } ?? .gray,
            title: "Recovery",
            headline: todayRecovery.map { "\(Int($0.rounded())) — \(recoveryLabel($0))" } ?? "No data",
            detail: recoveryDetail,
            sparklineValues: weekScores.count > 1 ? weekScores.map(\.value) : nil,
            sparklineColor: .cyan,
            destination: AnyView(RecoveryDashboardView())
        ))

        // Sleep
        let sleepPoints = metricIndex.query(type: DataType.sleepScore, measurementType: .derived,
                                             from: weekAgo, to: Date())
        let lastSleepScore = sleepPoints.last.map { Int($0.value.rounded()) }

        let nights = SleepTrendView.buildSleepNights(
            metricIndex: metricIndex, sourcePrefs: sourcePrefs,
            lookbackDays: 2, calendar: cal)
        let lastNight = nights.last
        let asleepMin = lastNight?.asleep ?? 0

        let sleepPriority: InsightPriority = {
            if let s = lastSleepScore {
                if s < 50 || asleepMin < 360 { return .attention }
                if s >= 75 { return .positive }
            }
            return .neutral
        }()

        insights.append(HomeInsight(
            id: "sleep",
            priority: sleepPriority,
            icon: "moon.fill",
            iconColor: lastSleepScore.map { sleepScoreColor($0) } ?? .gray,
            title: "Sleep",
            headline: lastSleepScore.map { "\($0) — \(SleepScore.label(for: $0))" } ?? "No data",
            detail: lastNight.map { "\(formatMinutes($0.asleep)) asleep last night" },
            sparklineValues: nil,
            sparklineColor: nil,
            destination: AnyView(SleepDashboardView())
        ))

        // Heart trend
        let heartDef = CategoryDashboardView.heart()
        let heartTrend = CategoryDashboardView.computeTrend(
            metrics: heartDef.metrics, days: 30,
            metricIndex: metricIndex, sourcePrefs: sourcePrefs)

        let heartPriority: InsightPriority = heartTrend.direction == .declining ? .attention : .neutral

        insights.append(HomeInsight(
            id: "heart",
            priority: heartPriority,
            icon: "heart.text.square",
            iconColor: heartTrend.direction == .declining ? .orange :
                       (heartTrend.direction == .improving ? .green : .gray),
            title: "Heart",
            headline: heartTrend.direction.rawValue,
            detail: heartTrend.direction == .declining ? "Consider rest and recovery" : "30-day trend",
            sparklineValues: nil,
            sparklineColor: nil,
            destination: AnyView(CategoryDashboardView.heart())
        ))

        // Activity trend
        let activityDef = CategoryDashboardView.activity()
        let activityTrend = CategoryDashboardView.computeTrend(
            metrics: activityDef.metrics, days: 30,
            metricIndex: metricIndex, sourcePrefs: sourcePrefs)

        let activityPriority: InsightPriority = activityTrend.direction == .declining ? .attention : .neutral

        insights.append(HomeInsight(
            id: "activity",
            priority: activityPriority,
            icon: "figure.run",
            iconColor: activityTrend.direction == .declining ? .orange :
                       (activityTrend.direction == .improving ? .green : .gray),
            title: "Activity",
            headline: activityTrend.direction.rawValue,
            detail: "30-day trend",
            sparklineValues: nil,
            sparklineColor: nil,
            destination: AnyView(CategoryDashboardView.activity())
        ))

        // Body composition
        let bodyComps = measurementStore.measurements(ofType: .bodyComp)
        let latestBody = bodyComps.max(by: { $0.date < $1.date })
        let bodyDp = latestBody.map { measurementStore.dataPoints(for: $0.id) } ?? []
        let displayWeight = bodyDp.first(where: { $0.type == DataType.weight })?.value
        let bodyFat = bodyDp.first(where: { $0.type == DataType.bodyFatPercent })?.value

        // Check weight change over 7D
        let weekBodies = bodyComps.filter { $0.date >= weekAgo }
            .sorted(by: { $0.date < $1.date })
        let firstWeight = weekBodies.first.flatMap { m in
            measurementStore.dataPoints(for: m.id).first(where: { $0.type == DataType.weight })?.value
        }
        let weightChange = (displayWeight != nil && firstWeight != nil)
            ? abs(displayWeight! - firstWeight!) : 0
        let bodyPriority: InsightPriority = weightChange > 2 ? .attention : .neutral

        var bodyHeadline = displayWeight.map { String(format: "%.1f kg", $0) } ?? "No data"
        if let bf = bodyFat { bodyHeadline += String(format: " · %.1f%% fat", bf) }

        insights.append(HomeInsight(
            id: "body",
            priority: bodyPriority,
            icon: "scalemass",
            iconColor: .white,
            title: "Body",
            headline: bodyHeadline,
            detail: weightChange > 2 ? String(format: "%.1f kg change this week", weightChange) : nil,
            sparklineValues: nil,
            sparklineColor: nil,
            destination: AnyView(BodyCompDashboardView())
        ))

        // Workouts
        let recentWorkouts = workoutStore.workouts(from: weekAgo, to: Date())
        let totalMin = recentWorkouts.compactMap(\.durationSec).reduce(0, +) / 60
        let workoutPriority: InsightPriority = recentWorkouts.isEmpty ? .attention : .neutral

        insights.append(HomeInsight(
            id: "workouts",
            priority: workoutPriority,
            icon: "flame.fill",
            iconColor: recentWorkouts.isEmpty ? .orange : .green,
            title: "Workouts",
            headline: recentWorkouts.isEmpty ? "None this week" :
                "\(recentWorkouts.count) workouts · \(formatMinutes(totalMin))",
            detail: recentWorkouts.isEmpty ? "Time to get moving" : nil,
            sparklineValues: nil,
            sparklineColor: nil,
            destination: AnyView(WorkoutAnalyticsView())
        ))

        // Labs
        let labMeasurements = measurementStore.measurements(ofType: .labResults)
        let latestLab = labMeasurements.max(by: { $0.date < $1.date })
        let daysOld = latestLab.map { cal.dateComponents([.day], from: $0.date, to: Date()).day ?? 999 } ?? 999
        let labPriority: InsightPriority = daysOld > 90 ? .attention : .neutral

        let labHeadline: String = {
            guard let lab = latestLab else { return "No results" }
            return HomeTab.relativeDateLabel(lab.date)
        }()

        insights.append(HomeInsight(
            id: "labs",
            priority: labPriority,
            icon: "cross.case",
            iconColor: daysOld > 90 ? .orange : .white,
            title: "Labs",
            headline: labHeadline,
            detail: daysOld > 90 ? "Consider getting blood work done" : nil,
            sparklineValues: nil,
            sparklineColor: nil,
            destination: AnyView(CategoryDashboardView.bloodWork())
        ))

        // Recovery activities
        let recDef = CategoryDashboardView.recoveryActivities()
        let recTrend = CategoryDashboardView.computeTrend(
            metrics: recDef.metrics, days: 30, measurementType: nil,
            metricIndex: metricIndex, sourcePrefs: sourcePrefs)

        let saunaPoints = metricIndex.query(type: DataType.saunaTotalDuration,
                                             from: weekAgo, to: Date())
        let saunaMin = Int(saunaPoints.reduce(0) { $0 + $1.value } / 60)
        let mindfulPoints = metricIndex.query(type: DataType.mindfulnessDuration,
                                               from: weekAgo, to: Date())
        let mindfulMin = Int(mindfulPoints.reduce(0) { $0 + $1.value })

        var recHeadline = recTrend.direction.rawValue
        var recParts: [String] = []
        if saunaMin > 0 { recParts.append("\(saunaMin)m sauna") }
        if mindfulMin > 0 { recParts.append("\(mindfulMin)m mindfulness") }
        if !recParts.isEmpty { recHeadline += " · " + recParts.joined(separator: ", ") }

        insights.append(HomeInsight(
            id: "wellness",
            priority: .neutral,
            icon: "sparkles",
            iconColor: recTrend.direction == .improving ? .green : .gray,
            title: "Wellness",
            headline: recHeadline,
            detail: nil,
            sparklineValues: nil,
            sparklineColor: nil,
            destination: AnyView(CategoryDashboardView.recoveryActivities())
        ))

        return insights.sorted { $0.priority < $1.priority }
    }

    // MARK: - Helpers

    func timeOfDayGreeting() -> String {
        let hour = cal.component(.hour, from: Date())
        if hour < 12 { return "Good morning" }
        if hour < 17 { return "Good afternoon" }
        return "Good evening"
    }

    /// Evening check-in banner (kept from old design).
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
}
