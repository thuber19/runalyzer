import Foundation
import os

/// Self-contained provider for daily recovery score measurements.
/// Reads overnight HRV and RHR from MetricIndex (no direct HealthKit dependency).
/// Trigger: app foreground (after HealthKitMetricProvider imports metrics).
class RecoveryMeasurementProvider {
    private weak var measurementStore: MeasurementStore?
    private let metricIndex: MetricIndex

    init(metricIndex: MetricIndex, measurementStore: MeasurementStore) {
        self.metricIndex = metricIndex
        self.measurementStore = measurementStore
    }

    // MARK: - Public API

    func computeMissingScores() {
        guard let store = measurementStore else { return }
        let missingDays = findMissingDays(in: store, lookbackDays: 7)
        guard !missingDays.isEmpty else {
            AppLogger.health.info("Recovery: all recent days already computed")
            return
        }
        processFromMetricIndex(days: missingDays)
    }

    func backfillHistory(days: Int = 90, completion: (() -> Void)? = nil) {
        guard let store = measurementStore else { completion?(); return }
        let missingDays = findMissingDays(in: store, lookbackDays: days)
        guard !missingDays.isEmpty else {
            AppLogger.health.info("Recovery backfill: no missing days")
            completion?()
            return
        }
        processFromMetricIndex(days: missingDays)
        completion?()
    }

    // MARK: - Private

    private func findMissingDays(in store: MeasurementStore, lookbackDays: Int) -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let existingDates = Set(
            store.measurements
                .filter { m in m.type == .derived &&
                    m.sources.contains { $0.algorithmName == RecoveryScore.algorithmID } }
                .map { cal.startOfDay(for: $0.date) }
        )

        guard let startFrom = cal.date(byAdding: .day, value: -lookbackDays, to: today) else {
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

    private func processFromMetricIndex(days: [Date]) {
        guard let store = measurementStore else { return }
        let cal = Calendar.current
        var newMeasurements: [SensorMeasurement] = []

        for day in days.sorted() {
            let dayStart = cal.startOfDay(for: day)
            guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { continue }

            // Overnight HRV (00:00–06:00) from .metric measurements
            let allHrvPoints = metricIndex.query(type: DataType.hrvSDNN, measurementType: .metric,
                                                 from: dayStart, to: dayEnd)
            let overnightHrv = allHrvPoints.filter {
                cal.component(.hour, from: $0.timestamp) < 6  // overnight only
            }

            // RHR from .metric measurements
            let rhrPoints = metricIndex.query(type: DataType.restingHeartRate, measurementType: .metric,
                                              from: dayStart, to: dayEnd)
            let rhr = rhrPoints.min(by: { $0.value < $1.value })

            guard !overnightHrv.isEmpty || rhr != nil else { continue }

            let baseline = RecoveryScore.buildBaselineFromMetricIndex(metricIndex, before: dayStart)
            guard baseline.dayCount >= RecoveryScore.baselineWindowDays else { continue }

            let sdnnSamples = overnightHrv.map { (value: $0.value, sourceName: sourceNameFrom($0.source)) }
            let inputs = RecoveryScore.DayInputs(
                date: dayStart,
                sdnnSamples: sdnnSamples,
                restingHR: rhr?.value,
                restingHRSource: rhr.map { sourceNameFrom($0.source) }
            )

            if let m = RecoveryScore.compute(inputs: inputs, baseline: baseline) {
                newMeasurements.append(m)
            }
        }

        guard !newMeasurements.isEmpty else { return }
        store.saveBatch(newMeasurements)
        AppLogger.health.info("Recovery: saved \(newMeasurements.count) scores")
    }

    private func sourceNameFrom(_ source: String) -> String {
        if source.hasPrefix("hk:") { return String(source.dropFirst(3)) }
        return source
    }
}
