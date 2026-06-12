import Foundation
import os

/// Self-contained provider for nightly sleep score measurements.
/// Reads raw sleep stage data from MetricIndex, computes SleepScore, and stores as .derived.
/// Trigger: app foreground (after HealthKitMetricProvider imports sleep stages).
class SleepMeasurementProvider {
    static let algorithmID = "sleep_v1"

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
            AppLogger.health.info("Sleep scores: all recent days already computed")
            return
        }
        processNights(days: missingDays)
    }

    func backfillHistory(days: Int = 90, completion: (() -> Void)? = nil) {
        guard let store = measurementStore else { completion?(); return }
        let missingDays = findMissingDays(in: store, lookbackDays: days)
        guard !missingDays.isEmpty else {
            AppLogger.health.info("Sleep scores backfill: no missing days")
            completion?()
            return
        }
        processNights(days: missingDays)
        completion?()
    }

    // MARK: - Private

    private func findMissingDays(in store: MeasurementStore, lookbackDays: Int) -> [Date] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        let existingDates = Set(
            store.measurements
                .filter { m in m.type == .derived &&
                    m.sources.contains { $0.algorithmName == Self.algorithmID } }
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
