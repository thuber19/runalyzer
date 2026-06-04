import Foundation
import os

/// Self-contained provider for daily daytime stress measurements.
///
/// Simple logic:
/// - Every day with HRV/RHR data gets a measurement with the raw daily averages from HealthKit.
/// - If ≥30 prior days exist in the store, a stress score is also computed using the rolling baseline.
/// - If <30 days: raw values are stored but NO score is calculated (data builds up for future scoring).
///
/// Trigger: app foreground (computes missing days since last score).
/// Backfill: user-triggered from Settings (same logic, just more days).
class StressMeasurementProvider {
    private weak var measurementStore: MeasurementStore?
    private let healthKit: HealthKitManager

    init(healthKit: HealthKitManager, measurementStore: MeasurementStore) {
        self.healthKit = healthKit
        self.measurementStore = measurementStore
    }

    // MARK: - Public API

    /// Called on app foreground. Computes all missing days since last stored score.
    func computeMissingScores() {
        guard let store = measurementStore else { return }
        let missingDays = findMissingDays(in: store, lookbackDays: 7)
        guard !missingDays.isEmpty else {
            AppLogger.health.info("Stress: all recent days already computed")
            return
        }
        fetchAndProcess(days: missingDays)
    }

    /// User-triggered from Settings. Fetches 120 days so that 90 get scored (first 30 = baseline).
    func backfillHistory(days: Int = 120) {
        guard let store = measurementStore else { return }
        let missingDays = findMissingDays(in: store, lookbackDays: days)
        guard !missingDays.isEmpty else {
            AppLogger.health.info("Stress backfill: no missing days")
            return
        }
        fetchAndProcess(days: missingDays)
    }

    // MARK: - Private

    /// Find all calendar days in the lookback window that don't have a stress measurement yet.
    private func findMissingDays(in store: MeasurementStore, lookbackDays: Int) -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let existingDates = Set(
            store.measurements
                .filter { m in m.type == .derived &&
                    m.sources.contains { $0.algorithmName == DaytimeStress.algorithmID } }
                .map { cal.startOfDay(for: $0.date) }
        )

        // For daily: check since last score (or lookbackDays if none)
        let lastDate = existingDates.max()
        let startFrom: Date
        if let last = lastDate,
           let next = cal.date(byAdding: .day, value: 1, to: last) {
            startFrom = next
        } else if let lookback = cal.date(byAdding: .day, value: -lookbackDays, to: today) {
            startFrom = lookback
        } else {
            return []
        }

        var missing: [Date] = []
        var cursor = startFrom
        while cursor <= today {
            if !existingDates.contains(cursor) { missing.append(cursor) }
            guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return missing
    }

    /// Fetch HK data for the given days and create measurements.
    private func fetchAndProcess(days: [Date]) {
        let group = DispatchGroup()
        var allInputs: [DaytimeStress.DayInputs] = []
        let collectQueue = DispatchQueue(label: "stress.collect")

        for day in days {
            group.enter()
            healthKit.fetchStressInputsForDay(day) { inputs in
                collectQueue.sync { allInputs.append(inputs) }
                group.leave()
            }
        }

        group.notify(queue: .global(qos: .userInitiated)) { [weak self] in
            guard let self, let store = self.measurementStore else { return }

            // Sort chronologically so baseline builds correctly
            let sorted = allInputs.sorted { $0.date < $1.date }

            // Seed prior inputs from stored measurements (for incremental daily path)
            var priorInputs: [DaytimeStress.DayInputs] = store.measurements
                .filter { $0.type == .derived && $0.sources.contains { $0.algorithmName == DaytimeStress.algorithmID } }
                .sorted { $0.date < $1.date }
                .compactMap { m -> DaytimeStress.DayInputs? in
                    let sdnn = m.dataPoints.first(where: { $0.type == DataType.stressSDNNavg })?.value
                    let rhr = m.dataPoints.first(where: { $0.type == DataType.stressRestingHR })?.value
                    guard sdnn != nil || rhr != nil else { return nil }
                    return DaytimeStress.DayInputs(
                        date: m.date,
                        sdnnSamples: sdnn.map { [(value: $0, sourceName: "stored")] } ?? [],
                        restingHR: rhr,
                        restingHRSource: nil
                    )
                }

            var newMeasurements: [SensorMeasurement] = []
            var processedDates = Set(priorInputs.map { Calendar.current.startOfDay(for: $0.date) })

            for inputs in sorted {
                autoreleasepool {
                    let dayStart = Calendar.current.startOfDay(for: inputs.date)
                    guard !processedDates.contains(dayStart) else { return }
                    processedDates.insert(dayStart)

                    guard !inputs.sdnnSamples.isEmpty || inputs.restingHR != nil else { return }

                    // Build baseline from ALL prior data (stored + already processed in this batch)
                    let baseline = DaytimeStress.buildBaseline(from: priorInputs)

                    if baseline.dayCount >= DaytimeStress.baselineWindowDays {
                        if let m = DaytimeStress.compute(inputs: inputs, baseline: baseline) {
                            newMeasurements.append(m)
                        }
                    } else {
                        if let m = DaytimeStress.rawMeasurement(inputs: inputs, baselineDayCount: baseline.dayCount) {
                            newMeasurements.append(m)
                        }
                    }

                    // This day's values feed into baseline for subsequent days
                    priorInputs.append(inputs)
                }
            }

            DispatchQueue.main.async {
                guard !newMeasurements.isEmpty else { return }
                store.saveBatch(newMeasurements)
                AppLogger.health.info("Stress: saved \(newMeasurements.count) measurements")
            }
        }
    }
}
