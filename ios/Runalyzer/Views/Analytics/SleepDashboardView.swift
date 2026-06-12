import SwiftUI

/// Sleep category dashboard with per-night details, actionable insights, and trends.
struct SleepDashboardView: View {
    @EnvironmentObject var measurementStore: MeasurementStore
    @EnvironmentObject var sourcePrefs: SourcePreferenceStore
    @State private var timeRange: SleepRange = .day

    private var metricIndex: MetricIndex { MetricIndex(store: measurementStore) }
    private let cal = Calendar.current

    enum SleepRange: String, CaseIterable {
        case day = "1D", week = "7D", month = "30D", quarter = "90D"
        var days: Int {
            switch self {
            case .day: return 2      // fetch 2 days to get last night
            case .week: return 7
            case .month: return 30
            case .quarter: return 90
            }
        }
        var isDaily: Bool { self == .day }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                rangePicker
                if timeRange.isDaily {
                    dailyView
                } else {
                    periodView
                }
                NavigationLink(destination: SleepTrendView()) {
                    HStack {
                        Text("All Nights").font(.subheadline).foregroundColor(.cyan)
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption2).foregroundColor(.gray)
                    }
                    .padding()
                    .background(Color(hex: 0x16213e))
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .background(Color(hex: 0x1a1a2e))
        .navigationTitle("Sleep")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Data

    private var allNights: [SleepTrendView.SleepNight] {
        SleepTrendView.buildSleepNights(
            metricIndex: metricIndex, sourcePrefs: sourcePrefs,
            lookbackDays: max(timeRange.days, 30), calendar: cal
        )
    }

    private func scoreNight(_ night: SleepTrendView.SleepNight,
                             allNights: [SleepTrendView.SleepNight]) -> SleepScore.Result {
        let recentBedtimes = allNights
            .prefix(while: { $0.date < night.date })
            .suffix(7)
            .compactMap { n -> Date? in
                n.stages.filter { ["Deep", "Core", "REM"].contains($0.stage) }.map(\.start).min()
            }
        return SleepScore.fromStages(stages: night.stages, recentBedtimes: recentBedtimes)
    }

    private func bedtime(for night: SleepTrendView.SleepNight) -> Date? {
        night.stages.filter { ["Deep", "Core", "REM", "Asleep"].contains($0.stage) }
            .map(\.start).min()
    }

    // MARK: - 1D: Last Night Detail

    private var dailyView: some View {
        let nights = allNights
        guard let lastNight = nights.last else {
            return AnyView(noDataCard)
        }
        let score = scoreNight(lastNight, allNights: nights)
        let bt = bedtime(for: lastNight)

        // Average bedtime from last 30 nights
        let recentBedtimes = nights.suffix(30).compactMap { bedtime(for: $0) }
        let avgBedtimeStr = averageBedtimeString(recentBedtimes)

        let scoreColor = sleepScoreColor(score.total)

        let coreMin = lastNight.asleep - lastNight.deep - lastNight.rem
        let eff = lastNight.inBed > 0 ? lastNight.asleep / lastNight.inBed * 100 : 0

        return AnyView(VStack(spacing: 12) {
            // Card 1: Score + key stats
            VStack(spacing: 14) {
                HStack(spacing: 16) {
                    scoreRing(score.total, color: scoreColor, size: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(score.label).font(.headline).foregroundColor(scoreColor)
                        HStack(spacing: 12) {
                            miniStat("Duration", score.durationScore, 50)
                            miniStat("Consistency", score.consistencyScore, 30)
                            miniStat("Interruptions", score.interruptionScore, 20)
                        }
                    }
                    Spacer()
                }
                Divider().background(Color.gray.opacity(0.2))
                HStack(spacing: 0) {
                    statCol(bt.map { formatTime($0) } ?? "--", "Bedtime")
                    statCol(formatMin(lastNight.inBed), "In Bed")
                    statCol(formatMin(lastNight.asleep), "Asleep")
                    statCol(String(format: "%.0f%%", eff), "Efficiency")
                }
            }
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Card 2: Stages + percentages + hypnogram
            let deepPct = lastNight.asleep > 0 ? lastNight.deep / lastNight.asleep * 100 : 0
            let corePct = lastNight.asleep > 0 ? max(0, coreMin) / lastNight.asleep * 100 : 0
            let remPct = lastNight.asleep > 0 ? lastNight.rem / lastNight.asleep * 100 : 0

            VStack(spacing: 12) {
                HStack(spacing: 0) {
                    stageColFull(formatMin(lastNight.deep), String(format: "%.0f%%", deepPct), "Deep", "13–23%", .indigo)
                    stageColFull(formatMin(max(0, coreMin)), String(format: "%.0f%%", corePct), "Core", "", .blue)
                    stageColFull(formatMin(lastNight.rem), String(format: "%.0f%%", remPct), "REM", "20–25%", .cyan)
                    stageColFull(formatMin(lastNight.awake), "", "Awake", "", .gray)
                }

                if !lastNight.stages.isEmpty {
                    IntervalTimeline(
                        intervals: lastNight.stages.map {
                            TimelineInterval(category: $0.stage, start: $0.start, end: $0.end)
                        },
                        categories: [
                            TimelineCategory(name: "Deep", color: .indigo, position: 0),
                            TimelineCategory(name: "Core", color: .blue, position: 1),
                            TimelineCategory(name: "REM", color: .cyan, position: 2),
                            TimelineCategory(name: "Awake", color: .gray, position: 3),
                        ]
                    )
                    .frame(height: 130)
                }
            }
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Insights
            dailyInsights(score: score, night: lastNight, avgBedtimes: recentBedtimes)
        })
    }

    private func dailyInsights(score: SleepScore.Result, night: SleepTrendView.SleepNight,
                                avgBedtimes: [Date]) -> some View {
        var insights: [(icon: String, text: String, color: Color)] = []

        if night.asleep < 420 {
            insights.append(("moon.zzz", "Only \(formatMin(night.asleep)) of sleep — aim for 7–9 hours.", .orange))
        }
        if night.asleep > 0 && night.deep / night.asleep < 0.10 {
            insights.append(("arrow.down", "Low deep sleep (\(String(format: "%.0f%%", night.deep / night.asleep * 100))). Exercise and a cool room help.", .orange))
        }
        if score.consistencyScore < 20 {
            insights.append(("clock.badge.exclamationmark", "You went to bed much later or earlier than usual.", .orange))
        }
        if score.interruptionScore < 12 {
            insights.append(("exclamationmark.triangle", "Restless night — consider limiting caffeine and screens.", .orange))
        }
        if score.total >= 80 {
            insights.append(("checkmark.circle", "Great night of sleep!", .green))
        }

        return Group {
            if !insights.isEmpty {
                insightsCardView(insights)
            }
        }
    }

    // MARK: - Period View (7D / 30D / 90D)

    private var periodView: some View {
        let nights = allNights
        let periodNights = nights.suffix(timeRange.days)
        guard !periodNights.isEmpty else { return AnyView(noDataCard) }

        let scores = periodNights.map { scoreNight($0, allNights: nights) }

        // Trend
        let scoreValues = zip(periodNights, scores).map { (date: $0.0.date, value: Double($0.1.total)) }
        let durationValues = periodNights.map { (date: $0.date, value: $0.asleep) }
        let deepPctValues: [(date: Date, value: Double)] = periodNights.compactMap { n in
            guard n.asleep > 0 else { return nil }
            return (date: n.date, value: n.deep / n.asleep * 100)
        }
        let effValues: [(date: Date, value: Double)] = periodNights.compactMap { n in
            guard n.inBed > 0 else { return nil }
            return (date: n.date, value: n.asleep / n.inBed * 100)
        }
        let trend = HealthScore.sleepTrend(
            sleepScores: scoreValues, durationValues: durationValues,
            deepPercentValues: deepPctValues, efficiencyValues: effValues
        )

        // Averages
        let avgScore = scores.map(\.total).reduce(0, +) / max(1, scores.count)
        let avgDuration = periodNights.map(\.asleep).reduce(0, +) / Double(max(1, periodNights.count))
        let avgDeepPct = deepPctValues.isEmpty ? 0 : deepPctValues.map(\.value).reduce(0, +) / Double(deepPctValues.count)
        let avgEff = effValues.isEmpty ? 0 : effValues.map(\.value).reduce(0, +) / Double(effValues.count)

        // Average bedtime
        let bedtimes = periodNights.compactMap { bedtime(for: $0) }
        let avgBedtimeStr = averageBedtimeString(bedtimes)

        let trendIcon: String
        let trendColor: Color
        switch trend.direction {
        case .improving: trendIcon = "arrow.up.right"; trendColor = .green
        case .stable:    trendIcon = "arrow.right";    trendColor = .gray
        case .declining: trendIcon = "arrow.down.right"; trendColor = .orange
        }

        return AnyView(VStack(spacing: 12) {
            // Trend header
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: trendIcon).font(.title2.bold()).foregroundColor(trendColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trend.direction.rawValue).font(.headline).foregroundColor(trendColor)
                        Text("Over the last \(timeRange.rawValue)").font(.caption2).foregroundColor(.gray)
                    }
                    Spacer()
                }
                if !trend.metricTrends.isEmpty {
                    Divider().background(Color.gray.opacity(0.3))
                    HStack(spacing: 0) {
                        ForEach(trend.metricTrends, id: \.metricId) { mt in
                            VStack(spacing: 2) {
                                Text(String(format: "%+.1f%%", mt.percentChange))
                                    .font(.caption.bold().monospacedDigit())
                                    .foregroundColor(abs(mt.percentChange) < 1 ? .gray : (mt.percentChange >= 0 ? .green : .orange))
                                Text(mt.name).font(.caption2).foregroundColor(.gray)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Key averages — visual row (like 1D layout)
            let avgInBed = periodNights.map(\.inBed).reduce(0, +) / Double(max(1, periodNights.count))
            HStack(spacing: 0) {
                statCol(avgBedtimeStr, "Bedtime")
                statCol(formatMin(avgInBed), "In Bed")
                statCol(formatMin(avgDuration), "Asleep")
                statCol(String(format: "%.0f%%", avgEff), "Efficiency")
            }
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Remaining stats
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Avg Score", "\(avgScore)", subtitle: scoreLabel(avgScore))
                detailRow("Deep Sleep", String(format: "%.0f%%", avgDeepPct), subtitle: "13–23% typical")
                detailRow("Nights", "\(periodNights.count)")
            }
            .padding()
            .background(Color(hex: 0x16213e))
            .cornerRadius(12)

            // Period insights
            periodInsights(avgDuration: avgDuration, avgDeepPct: avgDeepPct,
                           avgEff: avgEff, scores: scores)
        })
    }

    private func periodInsights(avgDuration: Double, avgDeepPct: Double,
                                 avgEff: Double, scores: [SleepScore.Result]) -> some View {
        var insights: [(icon: String, text: String, color: Color)] = []

        if avgDuration < 420 {
            insights.append(("moon.zzz", "Averaging \(formatMin(avgDuration)) — below the 7h minimum. Prioritize an earlier bedtime.", .orange))
        } else if avgDuration >= 480 {
            insights.append(("checkmark.circle", "Solid \(formatMin(avgDuration)) average — well within the 7–9h target.", .green))
        }

        if avgDeepPct < 10 {
            insights.append(("arrow.down", "Deep sleep at \(String(format: "%.0f%%", avgDeepPct)) is below the 13% threshold. Regular exercise and cooler room temps help.", .orange))
        }

        if avgEff < 85 {
            insights.append(("bed.double", "Sleep efficiency at \(String(format: "%.0f%%", avgEff)) — below 85%. Spending less time in bed awake would improve this.", .orange))
        }

        let avgConsistency = Double(scores.map(\.consistencyScore).reduce(0, +)) / Double(max(1, scores.count))
        if avgConsistency < 20 {
            insights.append(("clock.badge.exclamationmark", "Irregular bedtimes. A consistent schedule is one of the strongest levers for sleep quality.", .orange))
        }

        return Group {
            if !insights.isEmpty {
                insightsCardView(insights)
            }
        }
    }

    // MARK: - Shared Components

    private func scoreRing(_ score: Int, color: Color, size: CGFloat) -> some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.2), lineWidth: 5).frame(width: size, height: size)
            Circle().trim(from: 0, to: CGFloat(score) / 100)
                .stroke(color, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .frame(width: size, height: size).rotationEffect(.degrees(-90))
            Text("\(score)").font(.title3.bold().monospacedDigit())
        }
    }

    private func miniStat(_ label: String, _ score: Int, _ max: Int) -> some View {
        VStack(spacing: 1) {
            Text("\(score)/\(max)").font(.caption2.bold().monospacedDigit())
            Text(label).font(.system(size: 8)).foregroundColor(.gray)
        }
    }

    private func statCol(_ value: String, _ label: String, _ color: Color = .white) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundColor(color == .white ? .gray : color)
        }
        .frame(maxWidth: .infinity)
    }

    private func stageColFull(_ duration: String, _ pct: String, _ label: String,
                              _ ref: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(duration).font(.subheadline.bold().monospacedDigit())
            if !pct.isEmpty {
                Text(pct).font(.caption2.monospacedDigit()).foregroundColor(.gray)
            }
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.caption2).foregroundColor(.gray)
            }
            if !ref.isEmpty {
                Text(ref).font(.system(size: 8)).foregroundColor(.gray.opacity(0.5))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stageCol(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.subheadline.bold().monospacedDigit())
            HStack(spacing: 3) {
                Circle().fill(color).frame(width: 6, height: 6)
                Text(label).font(.caption2).foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func statColWithRef(_ value: String, _ label: String, _ ref: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.bold().monospacedDigit())
            Text(label).font(.caption2).foregroundColor(.gray)
            Text(ref).font(.system(size: 9)).foregroundColor(.gray.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }

    private func detailRow(_ label: String, _ value: String, subtitle: String? = nil) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundColor(.gray)
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(value).font(.subheadline.bold().monospacedDigit())
                if let sub = subtitle {
                    Text(sub).font(.caption2).foregroundColor(.gray.opacity(0.7))
                }
            }
        }
    }

    private func insightsCardView(_ insights: [(icon: String, text: String, color: Color)]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INSIGHTS").font(.caption2).foregroundColor(.gray)
            ForEach(insights.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: insights[i].icon)
                        .font(.caption).foregroundColor(insights[i].color).frame(width: 16)
                    Text(insights[i].text)
                        .font(.caption).foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if i < insights.count - 1 {
                    Divider().background(Color.gray.opacity(0.2))
                }
            }
        }
        .padding()
        .background(Color(hex: 0x16213e))
        .cornerRadius(12)
    }

    private var noDataCard: some View {
        Text("No sleep data").font(.caption).foregroundColor(.gray)
            .frame(maxWidth: .infinity).padding()
            .background(Color(hex: 0x16213e)).cornerRadius(12)
    }

    // MARK: - Helpers

    private var rangePicker: some View {
        Picker("Range", selection: $timeRange) {
            ForEach(SleepRange.allCases, id: \.self) { r in
                Text(r.rawValue).tag(r)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private func sleepScoreColor(_ score: Int) -> Color {
        switch score {
        case 75...: return .green
        case 50...: return .cyan
        case 25...: return .orange
        default:    return .red
        }
    }

    private func scoreLabel(_ score: Int) -> String {
        switch score {
        case 75...: return "Excellent"
        case 50...: return "Good"
        case 25...: return "Fair"
        default:    return "Poor"
        }
    }

    private func formatMin(_ m: Double) -> String {
        let h = Int(m) / 60, min = Int(m) % 60
        return h > 0 ? "\(h)h \(String(format: "%02d", min))m" : "\(min)m"
    }

    private static let timeFmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func formatTime(_ d: Date) -> String {
        Self.timeFmt.string(from: d)
    }

    /// Compute median bedtime as HH:mm string. Median is more robust to outliers than mean.
    /// Filters to evening/night bedtimes (18:00–06:00) to exclude naps.
    private func averageBedtimeString(_ bedtimes: [Date]) -> String {
        guard bedtimes.count >= 3 else { return "--" }
        // Convert to minutes-of-day, shifted so midnight = 1440 (keeps evening→morning contiguous)
        let minutesOfDay = bedtimes.compactMap { date -> Double? in
            let comps = cal.dateComponents([.hour, .minute], from: date)
            let hour = comps.hour ?? 0
            // Filter out daytime entries (06:00–18:00) — likely naps, not bedtimes
            if hour >= 6 && hour < 18 { return nil }
            var mins = Double(hour * 60 + (comps.minute ?? 0))
            if mins < 720 { mins += 1440 } // post-midnight: shift up so 00:30 → 1470
            return mins
        }
        guard minutesOfDay.count >= 3 else { return "--" }

        // Use median instead of mean — resistant to outlier late nights
        let sorted = minutesOfDay.sorted()
        let median: Double
        if sorted.count % 2 == 0 {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }

        let result = Int(median) % 1440
        let h = result / 60, m = result % 60
        return String(format: "%02d:%02d", h, m)
    }
}
