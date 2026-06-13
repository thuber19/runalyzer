import Foundation
import GRDB
import os

/// Self-contained provider for daily recovery score measurements.
/// Reads overnight HRV and RHR from MetricIndex (no direct HealthKit dependency).
/// Trigger: app foreground (after HealthKitMetricProvider imports metrics).
class RecoveryMeasurementProvider {
    private weak var measurementStore: MeasurementStore?
    private let metricIndex: MetricIndex
    private let db: AppDatabase

    init(metricIndex: MetricIndex, measurementStore: MeasurementStore, db: AppDatabase? = nil) {
        self.metricIndex = metricIndex
        self.measurementStore = measurementStore
        self.db = db ?? AppDatabase.shared
    }

    // MARK: - Public API

    func computeMissingScores() {
        guard measurementStore != nil else { return }
        let missingDays = findMissingDays(lookbackDays: 7)
        guard !missingDays.isEmpty else {
            AppLogger.health.info("Recovery: all recent days already computed")
            return
        }
        processFromMetricIndex(days: missingDays)
    }

    func backfillHistory(days: Int = 90, completion: (() -> Void)? = nil) {
        guard measurementStore != nil else { completion?(); return }
        let missingDays = findMissingDays(lookbackDays: days)
        guard !missingDays.isEmpty else {
            AppLogger.health.info("Recovery backfill: no missing days")
            completion?()
            return
        }
        processFromMetricIndex(days: missingDays)
        completion?()
    }

    // MARK: - Private

    /// Query the database directly (not the in-memory array) to avoid race conditions
    /// where multiple triggers find the same day "missing" before the first save propagates.
    private func findMissingDays(lookbackDays: Int) -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        guard let startFrom = cal.date(byAdding: .day, value: -lookbackDays, to: today) else {
            return []
        }

        let existingDates: Set<Date> = (try? db.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT m.date FROM measurement m
                JOIN measurement_source ms ON ms.measurementId = m.id
                WHERE m.type = 'derived' AND ms.algorithmName = ?
                  AND m.date >= ?
                """, arguments: [RecoveryScore.algorithmID, startFrom.timeIntervalSince1970])
            return Set(rows.map { cal.startOfDay(for: Date(timeIntervalSince1970: $0["date"])) })
        }) ?? []

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

            // Overnight RHR (00:00–06:00) from .metric measurements
            let rhrPoints = metricIndex.query(type: DataType.restingHeartRate, measurementType: .metric,
                                              from: dayStart, to: dayEnd)
            let overnightRhr = rhrPoints.filter {
                cal.component(.hour, from: $0.timestamp) < 6  // overnight only
            }
            let rhr = overnightRhr.min(by: { $0.value < $1.value })

            guard !overnightHrv.isEmpty || rhr != nil else { continue }

            let baseline = RecoveryScore.buildBaselineFromMetricIndex(metricIndex, before: dayStart)
            guard baseline.dayCount >= RecoveryScore.minBaselineDays else { continue }

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
