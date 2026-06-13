import Foundation

/// Nightly sleep score (0–100) modeled after Apple's watchOS sleep score.
///
/// Three components:
/// - **Duration** (50 pts): targets ~7h50m of sleep, penalties for undersleeping,
///   quality bonuses/penalties for deep and REM stage proportions
/// - **Consistency** (30 pts): how close your bedtime is to your recent average
/// - **Interruptions** (20 pts): time awake and number of wake events during the night
///
/// Scientific basis:
///   - Apple's scoring methodology draws from AASM, National Sleep Foundation,
///     and World Sleep Society guidelines.
///   - Duration target (7–9h for adults) per NSF recommendations.
///   - Sleep efficiency (time asleep / time in bed) per PSQI.
///
/// References:
///   - Apple: How Apple Watch's Sleep Score Is Calculated (the5krunner.com, 2025)
///   - Hirshkowitz M et al. NSF sleep duration recommendations. Sleep Health. 2015;1(1):40-43.
///   - Buysse DJ et al. The PSQI. Psychiatry Research. 1989;28(2):193-213.
enum SleepScore {

    /// Input for a single night's score.
    struct NightInput {
        let asleepMinutes: Double      // total sleep (Deep + Core + REM)
        let deepMinutes: Double
        let remMinutes: Double
        let awakeMinutes: Double       // total awake time during the night
        let wakeEvents: Int            // number of distinct awake periods
        let bedtime: Date              // when the user went to bed
        let averageBedtime: Date?      // rolling average bedtime (for consistency)
    }

    /// Breakdown of the score.
    struct Result {
        let total: Int                 // 0–100
        let durationScore: Int         // 0–50
        let consistencyScore: Int      // 0–30
        let interruptionScore: Int     // 0–20
        let label: String              // "Excellent", "Good", "Fair", "Poor"
    }

    /// Target sleep duration in minutes (~7h50m, per Apple).
    static let targetSleepMinutes: Double = 470

    // MARK: - Compute

    static func compute(_ input: NightInput) -> Result {
        let dur = durationComponent(input)
        let con = consistencyComponent(input)
        let intr = interruptionComponent(input)
        let total = dur + con + intr

        return Result(
            total: total,
            durationScore: dur,
            consistencyScore: con,
            interruptionScore: intr,
            label: scoreLabel(total)
        )
    }

    // MARK: - Duration (50 points)

    /// Base: how close to target sleep duration.
    /// Quality: penalties for low deep or REM sleep.
    private static func durationComponent(_ input: NightInput) -> Int {
        var score: Double = 50

        // Undersleep penalty (non-linear — losing more hours costs more)
        let deficit = max(0, targetSleepMinutes - input.asleepMinutes)
        if deficit > 0 {
            // First 60 min deficit: ~6 pts lost
            // Next 60 min: ~13 pts lost (accelerating)
            // Roughly: penalty = 6 * (deficit/60)^1.5
            let deficitHours = deficit / 60
            let penalty = min(45.0, 6.0 * pow(deficitHours, 1.5))
            score -= penalty
        }
        // No penalty for oversleeping

        // Quality penalties for low stage proportions
        let totalSleep = input.asleepMinutes
        if totalSleep > 0 {
            let deepPct = input.deepMinutes / totalSleep
            let remPct = input.remMinutes / totalSleep

            // Deep sleep: adults typically 13-23%. Penalty if < 10%.
            if deepPct < 0.10 {
                score -= 5
            }

            // REM sleep: adults typically 20-25%. Penalty if < 15%.
            if remPct < 0.15 {
                score -= 5
            }
        }

        return max(0, min(50, Int(score.rounded())))
    }

    // MARK: - Consistency (30 points)

    /// How close tonight's bedtime is to the rolling average.
    private static func consistencyComponent(_ input: NightInput) -> Int {
        guard let avgBedtime = input.averageBedtime else {
            // No baseline yet — give full credit
            return 30
        }

        // Compute offset in minutes from average bedtime
        // Use time-of-day comparison (handles midnight crossing)
        let cal = Calendar.current
        let todayComps = cal.dateComponents([.hour, .minute], from: input.bedtime)
        let avgComps = cal.dateComponents([.hour, .minute], from: avgBedtime)
        let todayMinutes = (todayComps.hour ?? 0) * 60 + (todayComps.minute ?? 0)
        let avgMinutes = (avgComps.hour ?? 0) * 60 + (avgComps.minute ?? 0)

        // Handle midnight crossing (e.g., avg 23:30, actual 00:15)
        var diff = todayMinutes - avgMinutes
        if diff > 720 { diff -= 1440 }   // wrapped past midnight
        if diff < -720 { diff += 1440 }

        var score: Double = 30

        if diff > 0 {
            // Going to bed LATER than normal
            // ~1 pt per 5 min after 15 min late, up to 30 pts lost
            let lateMinutes = max(0, Double(diff) - 15)
            let penalty = min(30.0, lateMinutes / 5.0)
            score -= penalty
        } else if diff < -60 {
            // Going to bed much EARLIER than normal (> 60 min early)
            // 1 pt per 30 min, max 6 pts
            let earlyMinutes = Double(-diff) - 60
            let penalty = min(6.0, earlyMinutes / 30.0)
            score -= penalty
        }
        // Within 60 min earlier: no penalty

        return max(0, min(30, Int(score.rounded())))
    }

    // MARK: - Interruptions (20 points)

    /// Time awake and number of wake events.
    private static func interruptionComponent(_ input: NightInput) -> Int {
        var score: Double = 20

        // Awake time: no penalty up to 11 min, then ~1 pt per 4 min
        let excessAwake = max(0, input.awakeMinutes - 11)
        let awakePenalty = min(10.0, excessAwake / 4.0)
        score -= awakePenalty

        // Wake events: no penalty for ≤2, then ~1 pt per 2 events
        let excessWakes = max(0, input.wakeEvents - 2)
        let wakePenalty = min(10.0, Double(excessWakes) / 2.0)
        score -= wakePenalty

        return max(0, min(20, Int(score.rounded())))
    }

    // MARK: - Helpers

    private static func scoreLabel(_ score: Int) -> String {
        switch score {
        case 75...: return "Excellent"
        case 50...: return "Good"
        case 25...: return "Fair"
        default:    return "Poor"
        }
    }

    // MARK: - Stage Summary (for detail view)

    /// Summary of sleep stages computed from raw DataPoints.
    struct StageSummary {
        let asleepMinutes: Double
        let deepMinutes: Double
        let remMinutes: Double
        /// Per-stage breakdown: (stageName, minutes), only stages with > 0 minutes.
        let stageBreakdown: [(name: String, minutes: Double)]
    }

    /// Compute a stage summary from raw sleep DataPoints.
    /// Handles Watch vs iPhone source dedup: if Watch staged data (Core/REM/Deep) exists,
    /// only those sources are used (plus Awake from any source) to avoid double-counting.
    static func stageSummary(from sleepPoints: [DataPoint]) -> StageSummary {
        let hasStages = sleepPoints.contains { ["Core", "Deep", "REM"].contains($0.unit) }
        let filtered: [DataPoint]
        if hasStages {
            let stagedSources = Set(sleepPoints.filter { ["Core", "Deep", "REM"].contains($0.unit) }
                .map { $0.source })
            filtered = sleepPoints.filter { stagedSources.contains($0.source) || $0.unit == "Awake" }
        } else {
            filtered = sleepPoints
        }

        let stages = filtered.compactMap { p -> (stage: String, minutes: Double)? in
            guard let end = p.endTimestamp else { return nil }
            return (stage: p.unit, minutes: end.timeIntervalSince(p.timestamp) / 60)
        }

        let stageNames = ["Deep", "Core", "REM", "Awake", "InBed", "Asleep"]
        let stageBreakdown: [(name: String, minutes: Double)] = stageNames.compactMap { name in
            let mins = stages.filter { $0.stage == name }.reduce(0) { $0 + $1.minutes }
            return mins > 0 ? (name: name, minutes: mins) : nil
        }

        let asleepMin = stages.filter { ["Deep", "Core", "REM", "Asleep"].contains($0.stage) }
            .reduce(0) { $0 + $1.minutes }
        let deepMin = stages.filter { $0.stage == "Deep" }.reduce(0) { $0 + $1.minutes }
        let remMin = stages.filter { $0.stage == "REM" }.reduce(0) { $0 + $1.minutes }

        return StageSummary(asleepMinutes: asleepMin, deepMinutes: deepMin,
                            remMinutes: remMin, stageBreakdown: stageBreakdown)
    }

    // MARK: - Convenience: Compute from sleep stages

    /// Compute sleep score from raw stage intervals (as produced by SleepTrendView).
    /// Also computes average bedtime from recent nights for consistency scoring.
    static func fromStages(
        stages: [(stage: String, start: Date, end: Date)],
        recentBedtimes: [Date] = []
    ) -> Result {
        var deepMin: Double = 0
        var coreMin: Double = 0
        var remMin: Double = 0
        var awakeMin: Double = 0
        var wakeEvents = 0
        var earliestSleep: Date?

        for s in stages {
            let dur = s.end.timeIntervalSince(s.start) / 60
            switch s.stage {
            case "Deep":  deepMin += dur
            case "Core":  coreMin += dur
            case "REM":   remMin += dur
            case "Awake":
                awakeMin += dur
                wakeEvents += 1
            default: break
            }

            // Track earliest sleep/inbed time as bedtime
            if ["Deep", "Core", "REM", "Asleep"].contains(s.stage) {
                if earliestSleep == nil || s.start < earliestSleep! {
                    earliestSleep = s.start
                }
            }
        }

        let asleepMin = deepMin + coreMin + remMin
        let bedtime = earliestSleep ?? Date()

        // Median bedtime from recent nights (robust to outliers)
        let avgBedtime: Date? = {
            guard recentBedtimes.count >= 3 else { return nil }
            let cal = Calendar.current
            let minutesOfDay = recentBedtimes.compactMap { date -> Double? in
                let comps = cal.dateComponents([.hour, .minute], from: date)
                let hour = comps.hour ?? 0
                if hour >= 6 && hour < 18 { return nil } // skip daytime (naps)
                var mins = Double(hour * 60 + (comps.minute ?? 0))
                if mins < 720 { mins += 1440 }
                return mins
            }
            guard minutesOfDay.count >= 3 else { return nil }
            let sorted = minutesOfDay.sorted()
            let median: Double
            if sorted.count % 2 == 0 {
                median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
            } else {
                median = sorted[sorted.count / 2]
            }
            let result = Int(median) % 1440
            return cal.date(bySettingHour: result / 60, minute: result % 60, second: 0, of: Date())
        }()

        return compute(NightInput(
            asleepMinutes: asleepMin,
            deepMinutes: deepMin,
            remMinutes: remMin,
            awakeMinutes: awakeMin,
            wakeEvents: wakeEvents,
            bedtime: bedtime,
            averageBedtime: avgBedtime
        ))
    }
}
