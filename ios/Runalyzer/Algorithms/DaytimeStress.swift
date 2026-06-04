import Foundation

/// Computes a daily daytime stress index (0–100, higher = more stressed) from
/// Apple Watch passive HRV (SDNN) measurements and resting heart rate.
///
/// Scientific basis:
///   Reduced HRV reflects sympathetic nervous system dominance (stress response).
///   Elevated resting HR indicates increased sympathetic tone.
///   Both signals normalized against a personal 30-day rolling baseline so the
///   score reflects YOUR deviation from YOUR norm — not a population average.
///
/// References:
///   - Stress Watch: HR/HRV for Stress Detection — MDPI Sensors 2022
///   - Assessing Garmin Stress Score vs. HRV — Stress and Health 2025
///   - Wearable Cardiovascular Responses to Stressors — PMC 2023
///   - HRV over the Decades — PMC 2025 scoping review
enum DaytimeStress {

    static let algorithmID      = "daytime_stress_v1"
    static let baselineWindowDays = 30
    static let minBaselineDays    = 5   // below this: score computed but flagged low confidence

    // MARK: - Data structures

    struct DayInputs {
        /// Calendar day (start-of-day midnight).
        let date: Date
        /// Passive background SDNN readings between 06:00–23:00, each with its HealthKit source name.
        /// Source name comes directly from HKSample.sourceRevision.source.name (e.g. "Apple Watch").
        let sdnnSamples: [(value: Double, sourceName: String)]
        /// Apple Watch resting HR for this day (bpm) and the HK source it came from.
        let restingHR: Double?
        let restingHRSource: String?

        /// Plain SDNN values for baseline computation.
        var sdnnValues: [Double] { sdnnSamples.map(\.value) }
    }

    struct BaselineStats {
        let meanSDNN: Double        // 0 if no SDNN data in window
        let meanRestingHR: Double   // 0 if no RHR data in window
        let dayCount: Int           // number of days contributing
        var isLowConfidence: Bool { dayCount < minBaselineDays }
    }

    // MARK: - Baseline

    /// Build a baseline from up to `baselineWindowDays` prior DayInputs (used during initial backfill).
    static func buildBaseline(from priorDays: [DayInputs]) -> BaselineStats {
        let window = priorDays.suffix(baselineWindowDays)

        let sdnnDailyMeans: [Double] = window.compactMap { d in
            guard !d.sdnnValues.isEmpty else { return nil }
            return d.sdnnValues.reduce(0, +) / Double(d.sdnnValues.count)
        }
        let rhrValues = window.compactMap(\.restingHR)

        let meanSDNN = sdnnDailyMeans.isEmpty ? 0
            : sdnnDailyMeans.reduce(0, +) / Double(sdnnDailyMeans.count)
        let meanRHR  = rhrValues.isEmpty ? 0
            : rhrValues.reduce(0, +) / Double(rhrValues.count)
        let dayCount = max(sdnnDailyMeans.count, rhrValues.count)

        return BaselineStats(meanSDNN: meanSDNN, meanRestingHR: meanRHR, dayCount: dayCount)
    }

    /// Build a baseline from previously stored stress measurements (incremental daily mode).
    /// Reads `stressSDNNavg` and `stressRestingHR` DataPoints from the last 30 measurements.
    /// This avoids re-fetching historical HealthKit data.
    static func buildBaselineFromStore(_ measurements: [SensorMeasurement]) -> BaselineStats {
        let window = measurements
            .filter { $0.type == .derived && $0.sources.contains { $0.algorithmName == algorithmID } }
            .sorted { $0.date > $1.date }
            .prefix(baselineWindowDays)

        let sdnnValues: [Double] = window.compactMap { m in
            m.dataPoints.first(where: { $0.type == DataType.stressSDNNavg })?.value
        }
        let rhrValues: [Double] = window.compactMap { m in
            m.dataPoints.first(where: { $0.type == DataType.stressRestingHR })?.value
        }

        let meanSDNN = sdnnValues.isEmpty ? 0
            : sdnnValues.reduce(0, +) / Double(sdnnValues.count)
        let meanRHR  = rhrValues.isEmpty ? 0
            : rhrValues.reduce(0, +) / Double(rhrValues.count)
        let dayCount = max(sdnnValues.count, rhrValues.count)

        return BaselineStats(meanSDNN: meanSDNN, meanRestingHR: meanRHR, dayCount: dayCount)
    }

    // MARK: - Compute

    /// Compute a daily stress SensorMeasurement. Returns nil if not enough data.
    static func compute(inputs: DayInputs, baseline: BaselineStats) -> SensorMeasurement? {
        guard baseline.dayCount >= 1 else { return nil }

        let date    = Calendar.current.startOfDay(for: inputs.date)
        let algoSrc = DataSource.derived(algorithmID)
        var dp: [DataPoint] = []

        // MARK: HRV component
        var hrvStress: Double? = nil
        if !inputs.sdnnSamples.isEmpty, baseline.meanSDNN > 0 {
            let values = inputs.sdnnValues
            let avg = values.reduce(0, +) / Double(values.count)
            let mn  = values.min() ?? avg
            let mx  = values.max() ?? avg

            let sdnnSrc = DataSource.healthKitSource(inputs.sdnnSamples.first?.sourceName ?? "Apple Watch")

            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressSDNNavg, value: avg,
                                unit: "ms", source: sdnnSrc, role: .detail))
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressSDNNmin, value: mn,
                                unit: "ms", source: sdnnSrc, role: .detail))
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressSDNNmax, value: mx,
                                unit: "ms", source: sdnnSrc, role: .detail))
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressSDNNcount, value: Double(values.count),
                                unit: "readings", source: sdnnSrc, role: .detail))

            let deviation = (baseline.meanSDNN - avg) / baseline.meanSDNN
            let score = max(0.0, min(100.0, (deviation + 0.3) / 0.6 * 100.0))
            hrvStress = score
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressHRVComponent, value: score,
                                unit: "", source: algoSrc, role: .detail))
        }

        // MARK: RHR component
        var rhrStress: Double? = nil
        if let rhr = inputs.restingHR, baseline.meanRestingHR > 0 {
            let rhrSrc = DataSource.healthKitSource(inputs.restingHRSource ?? "Apple Watch")
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressRestingHR, value: rhr,
                                unit: "bpm", source: rhrSrc, role: .detail))

            let deviation = (rhr - baseline.meanRestingHR) / baseline.meanRestingHR
            let score = max(0.0, min(100.0, (deviation + 0.1) / 0.2 * 100.0))
            rhrStress = score
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressRHRComponent, value: score,
                                unit: "", source: algoSrc, role: .detail))
        }

        // MARK: Combined index — HRV 60%, RHR 40%
        let stressIndex: Double
        let confidence: Double

        switch (hrvStress, rhrStress) {
        case (let h?, let r?):
            stressIndex = 0.6 * h + 0.4 * r
            confidence  = baseline.isLowConfidence ? 0.5 : 1.0
        case (let h?, nil):
            stressIndex = h
            confidence  = baseline.isLowConfidence ? 0.35 : 0.7
        case (nil, let r?):
            stressIndex = r
            confidence  = baseline.isLowConfidence ? 0.25 : 0.5
        case (nil, nil):
            return nil
        }

        dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                            type: DataType.stressIndex, value: stressIndex,
                            unit: "", source: algoSrc, role: .primary))
        dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                            type: DataType.stressConfidence, value: confidence,
                            unit: "", source: algoSrc, role: .detail))

        // Store the baseline values used — shows "your 30-day norm" alongside today's values
        if baseline.meanSDNN > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressBaselineSDNN, value: baseline.meanSDNN,
                                unit: "ms", source: algoSrc, role: .detail))
        }
        if baseline.meanRestingHR > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressBaselineRHR, value: baseline.meanRestingHR,
                                unit: "bpm", source: algoSrc, role: .detail))
        }

        // Derive MeasurementSource list from the actual HK sources found in the data
        var hkNames = Set(inputs.sdnnSamples.map(\.sourceName))
        if let rhrSrc = inputs.restingHRSource { hkNames.insert(rhrSrc) }
        let hkSources = hkNames.map { MeasurementSource.healthKitDevice(name: $0) }

        return SensorMeasurement(
            id: UUID(),
            date: date,
            type: .derived,
            sources: hkSources + [.algorithm(name: algorithmID)],
            dataPoints: dp,
            rawDataFiles: []
        )
    }

    /// Create a measurement with raw HK values only — no stress score.
    /// Used when <30 days of baseline data exist. These measurements feed into the
    /// rolling baseline for future scoring.
    static func rawMeasurement(inputs: DayInputs, baselineDayCount: Int) -> SensorMeasurement? {
        guard !inputs.sdnnSamples.isEmpty || inputs.restingHR != nil else { return nil }

        let date = Calendar.current.startOfDay(for: inputs.date)
        var dp: [DataPoint] = []

        // Store raw HRV values from HealthKit
        if !inputs.sdnnSamples.isEmpty {
            let values = inputs.sdnnValues
            let avg = values.reduce(0, +) / Double(values.count)
            let sdnnSrc = DataSource.healthKitSource(inputs.sdnnSamples.first?.sourceName ?? "Apple Watch")

            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressSDNNavg, value: avg,
                                unit: "ms", source: sdnnSrc, role: .primary))
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressSDNNmin, value: values.min() ?? avg,
                                unit: "ms", source: sdnnSrc, role: .detail))
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressSDNNmax, value: values.max() ?? avg,
                                unit: "ms", source: sdnnSrc, role: .detail))
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressSDNNcount, value: Double(values.count),
                                unit: "readings", source: sdnnSrc, role: .detail))
        }

        // Store raw resting HR from HealthKit
        if let rhr = inputs.restingHR {
            let rhrSrc = DataSource.healthKitSource(inputs.restingHRSource ?? "Apple Watch")
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stressRestingHR, value: rhr,
                                unit: "bpm", source: rhrSrc, role: .primary))
        }

        // Derive sources from HK data
        var hkNames = Set(inputs.sdnnSamples.map(\.sourceName))
        if let rhrSrc = inputs.restingHRSource { hkNames.insert(rhrSrc) }
        let hkSources = hkNames.map { MeasurementSource.healthKitDevice(name: $0) }

        return SensorMeasurement(
            id: UUID(),
            date: date,
            type: .derived,
            sources: hkSources + [.algorithm(name: algorithmID)],
            dataPoints: dp,
            rawDataFiles: []
        )
    }
}
