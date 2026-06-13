import Foundation

/// Computes a daily recovery score (0–100, higher = better recovered) from
/// overnight HRV (SDNN) and resting heart rate, using z-score normalization
/// against a personal 30-day rolling baseline.
///
/// Scientific basis:
///   Overnight HRV is the most stable and validated window for assessing
///   autonomic recovery. WHOOP, Oura, and Fitbit all use sleep-period HRV.
///   Daytime HRV spot-checks are too noisy for reliable scoring.
///
/// References:
///   - Altini M. On Heart Rate Variability and the Apple Watch. Medium, 2020.
///   - Salazar-Martínez E et al. Obtaining stress score from SDNN values. IES 2024.
///   - Springer: Overnight HRV predicts perceived morning fitness. Appl Psychophysiol 2022.
///   - MDPI Sensors: Wearable sleep HRV as stress predictor. Sensors 2023;23(1):332.
enum RecoveryScore {

    static let algorithmID        = "recovery_v1"
    static let baselineWindowDays = 30
    static let minBaselineDays    = 5

    // MARK: - Data structures

    struct DayInputs {
        let date: Date
        /// Overnight SDNN readings (00:00–06:00) with HK source names.
        let sdnnSamples: [(value: Double, sourceName: String)]
        let restingHR: Double?
        let restingHRSource: String?

        var sdnnValues: [Double] { sdnnSamples.map(\.value) }
    }

    struct BaselineStats {
        let meanSDNN: Double
        let sdSDNN: Double
        let meanRestingHR: Double
        let sdRestingHR: Double
        let dayCount: Int
        var isLowConfidence: Bool { dayCount < minBaselineDays }
    }

    private static func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let sumSqDiff = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return sqrt(sumSqDiff / Double(values.count - 1))
    }

    // MARK: - Baseline

    static func buildBaseline(from priorDays: [DayInputs]) -> BaselineStats {
        let window = priorDays.suffix(baselineWindowDays)
        let sdnnMeans: [Double] = window.compactMap { d in
            guard !d.sdnnValues.isEmpty else { return nil }
            return d.sdnnValues.reduce(0, +) / Double(d.sdnnValues.count)
        }
        let rhrValues = window.compactMap(\.restingHR)

        return BaselineStats(
            meanSDNN: sdnnMeans.isEmpty ? 0 : sdnnMeans.reduce(0, +) / Double(sdnnMeans.count),
            sdSDNN: standardDeviation(sdnnMeans),
            meanRestingHR: rhrValues.isEmpty ? 0 : rhrValues.reduce(0, +) / Double(rhrValues.count),
            sdRestingHR: standardDeviation(rhrValues),
            dayCount: max(sdnnMeans.count, rhrValues.count)
        )
    }

    /// Build baseline from .metric measurements via MetricIndex.
    /// Uses overnight HRV (00:00–06:00) for stability.
    static func buildBaselineFromMetricIndex(_ metricIndex: MetricIndex, before date: Date) -> BaselineStats {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let windowStart = cal.date(byAdding: .day, value: -baselineWindowDays, to: dayStart) else {
            return BaselineStats(meanSDNN: 0, sdSDNN: 0, meanRestingHR: 0, sdRestingHR: 0, dayCount: 0)
        }

        let hrvPoints = metricIndex.query(type: DataType.hrvSDNN, measurementType: .metric,
                                          from: windowStart, to: dayStart)
        var hrvByDay: [Date: [Double]] = [:]
        for p in hrvPoints {
            let hour = cal.component(.hour, from: p.timestamp)
            guard hour < 6 else { continue }  // overnight only (00:00–06:00)
            let day = cal.startOfDay(for: p.timestamp)
            hrvByDay[day, default: []].append(p.value)
        }
        let sdnnMeans = hrvByDay.values.map { $0.reduce(0, +) / Double($0.count) }

        let rhrPoints = metricIndex.query(type: DataType.restingHeartRate, measurementType: .metric,
                                          from: windowStart, to: dayStart)
        // Filter to overnight hours (00:00–06:00) for consistency with HRV
        var rhrByDay: [Date: Double] = [:]
        for p in rhrPoints {
            let hour = cal.component(.hour, from: p.timestamp)
            guard hour < 6 else { continue }
            let day = cal.startOfDay(for: p.timestamp)
            let existing = rhrByDay[day]
            if existing == nil || p.value < existing! {
                rhrByDay[day] = p.value
            }
        }
        let rhrValues = Array(rhrByDay.values)

        return BaselineStats(
            meanSDNN: sdnnMeans.isEmpty ? 0 : sdnnMeans.reduce(0, +) / Double(sdnnMeans.count),
            sdSDNN: standardDeviation(sdnnMeans),
            meanRestingHR: rhrValues.isEmpty ? 0 : rhrValues.reduce(0, +) / Double(rhrValues.count),
            sdRestingHR: standardDeviation(rhrValues),
            dayCount: max(hrvByDay.count, rhrValues.count)
        )
    }

    // MARK: - Compute

    /// Recovery score: 0 = poorly recovered, 50 = normal, 100 = excellent.
    static func compute(inputs: DayInputs, baseline: BaselineStats) -> SensorMeasurement? {
        guard baseline.dayCount >= 1 else { return nil }

        let date    = Calendar.current.startOfDay(for: inputs.date)
        let algoSrc = DataSource.derived(algorithmID)
        var dp: [DataPoint] = []

        // HRV component: higher overnight SDNN = better recovery
        // z = (day_sdnn - baseline_mean) / baseline_sd → positive = better
        var hrvScore: Double? = nil
        if !inputs.sdnnSamples.isEmpty, baseline.meanSDNN > 0, baseline.sdSDNN > 0 {
            let avg = inputs.sdnnValues.reduce(0, +) / Double(inputs.sdnnValues.count)
            // Store the actual overnight SDNN used
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.hrvSDNN, value: avg,
                                unit: "ms", source: algoSrc, role: .detail))
            let z = (avg - baseline.meanSDNN) / baseline.sdSDNN
            let score = max(0.0, min(100.0, (z + 2.0) / 4.0 * 100.0))
            hrvScore = score
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.recoveryHRVComponent, value: score,
                                unit: "", source: algoSrc, role: .detail))
        }

        var rhrScore: Double? = nil
        if let rhr = inputs.restingHR, baseline.meanRestingHR > 0, baseline.sdRestingHR > 0 {
            // Store the actual RHR used
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.restingHeartRate, value: rhr,
                                unit: "bpm", source: algoSrc, role: .detail))
            let z = (baseline.meanRestingHR - rhr) / baseline.sdRestingHR
            let score = max(0.0, min(100.0, (z + 2.0) / 4.0 * 100.0))
            rhrScore = score
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.recoveryRHRComponent, value: score,
                                unit: "", source: algoSrc, role: .detail))
        }

        // Combined: HRV 60%, RHR 40%
        let recoveryIndex: Double
        let confidence: Double

        switch (hrvScore, rhrScore) {
        case (let h?, let r?):
            recoveryIndex = 0.6 * h + 0.4 * r
            confidence    = baseline.isLowConfidence ? 0.5 : 1.0
        case (let h?, nil):
            recoveryIndex = h
            confidence    = baseline.isLowConfidence ? 0.35 : 0.7
        case (nil, let r?):
            recoveryIndex = r
            confidence    = baseline.isLowConfidence ? 0.25 : 0.5
        case (nil, nil):
            return nil
        }

        dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                            type: DataType.recoveryIndex, value: recoveryIndex,
                            unit: "", source: algoSrc, role: .primary))
        dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                            type: DataType.recoveryConfidence, value: confidence,
                            unit: "", source: algoSrc, role: .detail))

        if baseline.meanSDNN > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.recoveryBaselineSDNN, value: baseline.meanSDNN,
                                unit: "ms", source: algoSrc, role: .detail))
        }
        if baseline.meanRestingHR > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.recoveryBaselineRHR, value: baseline.meanRestingHR,
                                unit: "bpm", source: algoSrc, role: .detail))
        }

        return SensorMeasurement(
            id: UUID(), date: date, type: .derived,
            sources: [.algorithm(name: algorithmID)],
            dataPoints: dp, rawDataFiles: []
        )
    }
}
