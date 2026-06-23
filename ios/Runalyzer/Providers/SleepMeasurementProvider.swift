import Foundation
import GRDB
import os

/// Self-contained provider for nightly sleep score measurements.
/// Reads raw sleep stage data from MetricIndex, computes SleepScore, and stores as .derived.
/// Trigger: app foreground (after HealthKitMetricProvider imports sleep stages).
class SleepMeasurementProvider {
    static let algorithmID = "sleep_v1"

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
            AppLogger.health.info("Sleep scores: all recent days already computed")
            return
        }
        processNights(days: missingDays)
    }

    func backfillHistory(days: Int = 90, completion: (() -> Void)? = nil) {
        guard measurementStore != nil else { completion?(); return }
        let missingDays = findMissingDays(lookbackDays: days)
        guard !missingDays.isEmpty else {
            AppLogger.health.info("Sleep scores backfill: no missing days")
            completion?()
            return
        }
        processNights(days: missingDays)
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
                """, arguments: [Self.algorithmID, startFrom.timeIntervalSince1970])
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

    private func processNights(days: [Date]) {
        guard let store = measurementStore else { return }
        let cal = Calendar.current

        // Build all nights from a wide lookback (need recent bedtimes for consistency scoring)
        let nights = SleepTrendView.buildSleepNights(
            metricIndex: metricIndex, sourcePrefs: nil,
            lookbackDays: max(days.count + 30, 120), calendar: cal
        )

        let nightsByDate: [Date: SleepTrendView.SleepNight] = Dictionary(
            nights.map { (cal.startOfDay(for: $0.date), $0) },
            uniquingKeysWith: { _, last in last }
        )

        var newMeasurements: [SensorMeasurement] = []

        for day in days.sorted() {
            guard let night = nightsByDate[day] else { continue }
            guard !night.stages.isEmpty else { continue }

            // Gather recent bedtimes for consistency scoring
            let recentBedtimes = nights
                .filter { $0.date < night.date }
                .suffix(7)
                .compactMap { n -> Date? in
                    n.stages.filter { ["Deep", "Core", "REM"].contains($0.stage) }
                        .map(\.start).min()
                }

            let score = SleepScore.fromStages(stages: night.stages, recentBedtimes: recentBedtimes)

            let algoSrc = DataSource.derived(Self.algorithmID)
            let dp: [DataPoint] = [
                DataPoint(timestamp: day, endTimestamp: nil,
                          type: DataType.sleepScore, value: Double(score.total),
                          unit: "", source: algoSrc, role: .primary),
                DataPoint(timestamp: day, endTimestamp: nil,
                          type: DataType.sleepDurationComponent, value: Double(score.durationScore),
                          unit: "", source: algoSrc, role: .detail),
                DataPoint(timestamp: day, endTimestamp: nil,
                          type: DataType.sleepQualityComponent, value: Double(score.qualityScore),
                          unit: "", source: algoSrc, role: .detail),
                DataPoint(timestamp: day, endTimestamp: nil,
                          type: DataType.sleepConsistencyComponent, value: Double(score.consistencyScore),
                          unit: "", source: algoSrc, role: .detail),
                DataPoint(timestamp: day, endTimestamp: nil,
                          type: DataType.sleepInterruptionComponent, value: Double(score.interruptionScore),
                          unit: "", source: algoSrc, role: .detail),
            ]

            newMeasurements.append(SensorMeasurement(
                id: UUID(), date: day, type: .derived,
                sources: [.algorithm(name: Self.algorithmID)],
                dataPoints: dp, rawDataFiles: []
            ))
        }

        guard !newMeasurements.isEmpty else { return }
        store.saveBatch(newMeasurements)
        AppLogger.health.info("Sleep scores: saved \(newMeasurements.count) scores")
    }
}
