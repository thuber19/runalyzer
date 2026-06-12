import Foundation

/// Composite trend result for a health category.
///
/// Instead of a fixed 0–100 score, this answers:
/// "Are my heart/sleep/activity metrics improving, stable, or declining
///  over the selected time period?"
///
/// Methodology (adapted from HRV4Training / Marco Altini):
/// 1. For each metric, fit a linear regression over the period
/// 2. Normalize the slope by the metric's SD (so "1 SD/period improvement in RHR"
///    is comparable to "1 SD/period improvement in HRV")
/// 3. Orient all slopes so positive = healthier
/// 4. Weighted average of normalized slopes = composite trend
struct CategoryTrend {
    let direction: Direction
    /// Composite normalized slope (positive = improving). Magnitude indicates strength.
    let magnitude: Double
    let metricTrends: [MetricTrend]

    enum Direction: String {
        case improving = "Improving"
        case stable = "Stable"
        case declining = "Declining"
    }

    static let noData = CategoryTrend(direction: .stable, magnitude: 0, metricTrends: [])
}

/// Trend for a single metric within a category.
struct MetricTrend {
    let metricId: String
    let name: String
    /// Raw percentage change over the period (first half avg → second half avg).
    let percentChange: Double
    /// Normalized slope in SD/period (positive = healthier direction).
    let normalizedSlope: Double
    let direction: MetricTrend.MetricDirection

    enum MetricDirection {
        case higherIsBetter  // HRV, VO2 Max, SpO2, HR recovery
        case lowerIsBetter   // RHR
    }
}

/// Pure computation of composite health category trends.
///
/// Uses normalized linear regression slopes against personal variance.
/// This answers "am I improving?" rather than "what's my score?"
///
/// No state, no I/O, no DB access.
enum HealthScore {

    /// Minimum data points to compute a meaningful trend.
    static let minDataPoints = 7

    // MARK: - Input

    /// A single metric's daily time series for trend analysis.
    struct MetricInput {
        let id: String
        let name: String
        let direction: MetricTrend.MetricDirection
        let weight: Double
        /// Daily values sorted chronologically. One entry per day.
        let dailyValues: [(date: Date, value: Double)]

        init(id: String, name: String, direction: MetricTrend.MetricDirection,
             weight: Double, dailyValues: [(date: Date, value: Double)]) {
            self.id = id; self.name = name; self.direction = direction
            self.weight = weight; self.dailyValues = dailyValues
        }
    }

    // MARK: - Compute

    /// Compute a composite trend for a set of metric time series.
    ///
    /// For each metric:
    /// 1. Linear regression slope over the period (value change per day)
    /// 2. Normalize by metric's SD → unit-free "how many SDs per period"
    /// 3. Orient so positive = healthier (flip for "lower is better")
    /// 4. Also compute simple % change (second half avg vs first half avg) for display
    ///
    /// Composite: weighted average of normalized slopes.
    /// Direction thresholds: |magnitude| < 0.3 → Stable, else Improving/Declining.
    static func compute(metrics: [MetricInput]) -> CategoryTrend {
        var metricTrends: [MetricTrend] = []
        var totalWeight: Double = 0

        for m in metrics {
            guard m.dailyValues.count >= minDataPoints else { continue }

            let values = m.dailyValues.map(\.value)
            let sd = standardDeviation(values)
            guard sd > 0 else { continue }

            // Linear regression: slope in value-units per day
            let slope = linearRegressionSlope(m.dailyValues)

            // Normalize slope: multiply by period length to get total SD change over period
            let periodDays = Double(m.dailyValues.count)
            let totalChange = slope * periodDays  // total value change over period
            let normalizedSlope = totalChange / sd // in SDs

            // Orient: positive = healthier
            let orientedSlope = m.direction == .lowerIsBetter ? -normalizedSlope : normalizedSlope

            // % change via regression line endpoints (more robust than split-half)
            let pctChange = regressionPercentChange(m.dailyValues.map(\.value))

            metricTrends.append(MetricTrend(
                metricId: m.id, name: m.name,
                percentChange: pctChange,
                normalizedSlope: orientedSlope,
                direction: m.direction
            ))
            totalWeight += m.weight
        }

        guard !metricTrends.isEmpty, totalWeight > 0 else { return .noData }

        // Weighted average of oriented normalized slopes
        let compositeMagnitude = zip(metricTrends, metrics.prefix(metricTrends.count))
            .reduce(0.0) { $0 + $1.0.normalizedSlope * $1.1.weight } / totalWeight

        // Direction thresholds
        let direction: CategoryTrend.Direction
        if compositeMagnitude > 0.3 {
            direction = .improving
        } else if compositeMagnitude < -0.3 {
            direction = .declining
        } else {
            direction = .stable
        }

        return CategoryTrend(
            direction: direction,
            magnitude: compositeMagnitude,
            metricTrends: metricTrends
        )
    }

    // MARK: - Convenience: Heart Trend

    /// Compute heart health trend.
    ///
    /// Weights: HRV 0.30, RHR 0.30, VO₂ Max 0.25, SpO₂ 0.15
    /// RHR is the primary HR-level metric. Sleeping HR and walking HR are
    /// strongly correlated with RHR — including all three would triple-count
    /// the same underlying signal.
    static func heartTrend(
        rhrDailyValues: [(date: Date, value: Double)] = [],
        hrvDailyValues: [(date: Date, value: Double)] = [],
        vo2DailyValues: [(date: Date, value: Double)] = [],
        spo2DailyValues: [(date: Date, value: Double)] = []
    ) -> CategoryTrend {
        var inputs: [MetricInput] = []

        if rhrDailyValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: DataType.restingHeartRate, name: "Resting HR",
                direction: .lowerIsBetter, weight: 0.30,
                dailyValues: rhrDailyValues))
        }
        if hrvDailyValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: DataType.hrvSDNN, name: "HRV",
                direction: .higherIsBetter, weight: 0.30,
                dailyValues: hrvDailyValues))
        }
        if vo2DailyValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: DataType.vo2Max, name: "VO₂ Max",
                direction: .higherIsBetter, weight: 0.25,
                dailyValues: vo2DailyValues))
        }
        if spo2DailyValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: DataType.bloodOxygen, name: "SpO₂",
                direction: .higherIsBetter, weight: 0.15,
                dailyValues: spo2DailyValues))
        }

        return compute(metrics: inputs)
    }

    // MARK: - Convenience: Sleep Trend

    /// Compute sleep trend from nightly sleep scores and component metrics.
    ///
    /// Weights: Sleep score 0.40, Duration 0.25, Deep % 0.20, Consistency 0.15
    static func sleepTrend(
        sleepScores: [(date: Date, value: Double)] = [],
        durationValues: [(date: Date, value: Double)] = [],
        deepPercentValues: [(date: Date, value: Double)] = [],
        efficiencyValues: [(date: Date, value: Double)] = []
    ) -> CategoryTrend {
        var inputs: [MetricInput] = []

        if sleepScores.count >= minDataPoints {
            inputs.append(MetricInput(
                id: "sleep_score", name: "Sleep Score",
                direction: .higherIsBetter, weight: 0.40,
                dailyValues: sleepScores))
        }
        if durationValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: "sleep_duration", name: "Duration",
                direction: .higherIsBetter, weight: 0.25,
                dailyValues: durationValues))
        }
        if deepPercentValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: "deep_percent", name: "Deep %",
                direction: .higherIsBetter, weight: 0.20,
                dailyValues: deepPercentValues))
        }
        if efficiencyValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: "sleep_efficiency", name: "Efficiency",
                direction: .higherIsBetter, weight: 0.15,
                dailyValues: efficiencyValues))
        }

        return compute(metrics: inputs)
    }

    // MARK: - Convenience: Activity Trend

    /// Compute activity trend from daily steps and workout metrics.
    ///
    /// Weights: Steps 0.40, Workout duration 0.35, Distance 0.25
    static func activityTrend(
        stepValues: [(date: Date, value: Double)] = [],
        workoutMinValues: [(date: Date, value: Double)] = [],
        distanceValues: [(date: Date, value: Double)] = []
    ) -> CategoryTrend {
        var inputs: [MetricInput] = []

        if stepValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: DataType.steps, name: "Steps",
                direction: .higherIsBetter, weight: 0.40,
                dailyValues: stepValues))
        }
        if workoutMinValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: "workout_minutes", name: "Workout Time",
                direction: .higherIsBetter, weight: 0.35,
                dailyValues: workoutMinValues))
        }
        if distanceValues.count >= minDataPoints {
            inputs.append(MetricInput(
                id: DataType.distance, name: "Distance",
                direction: .higherIsBetter, weight: 0.25,
                dailyValues: distanceValues))
        }

        return compute(metrics: inputs)
    }

    // MARK: - Math

    /// % change using OLS regression line endpoints: (fitted_last - fitted_first) / fitted_first × 100.
    /// More robust than split-half comparison — uses all data points and handles noise/sparse data well.
    static func regressionPercentChange(_ values: [Double]) -> Double {
        let n = Double(values.count)
        guard n >= 2 else { return 0 }

        var sumX: Double = 0, sumY: Double = 0
        var sumXY: Double = 0, sumX2: Double = 0

        for (i, y) in values.enumerated() {
            let x = Double(i)
            sumX += x; sumY += y
            sumXY += x * y; sumX2 += x * x
        }

        let denom = n * sumX2 - sumX * sumX
        guard denom != 0 else { return 0 }

        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n

        let fittedFirst = intercept           // x = 0
        let fittedLast = intercept + slope * (n - 1) // x = n-1

        guard fittedFirst != 0 else { return 0 }
        return ((fittedLast - fittedFirst) / fittedFirst) * 100
    }

    /// Least-squares linear regression slope (value change per day).
    private static func linearRegressionSlope(
        _ dailyValues: [(date: Date, value: Double)]
    ) -> Double {
        let n = Double(dailyValues.count)
        guard n >= 2 else { return 0 }

        // Use day index (0, 1, 2, ...) as x
        var sumX: Double = 0, sumY: Double = 0
        var sumXY: Double = 0, sumX2: Double = 0

        for (i, entry) in dailyValues.enumerated() {
            let x = Double(i)
            let y = entry.value
            sumX += x; sumY += y
            sumXY += x * y; sumX2 += x * x
        }

        let denom = n * sumX2 - sumX * sumX
        guard denom != 0 else { return 0 }
        return (n * sumXY - sumX * sumY) / denom
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sumSqDiff = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sqrt(sumSqDiff / Double(values.count - 1))
    }
}
