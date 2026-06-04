import Foundation
import os

/// Self-contained provider for daily daytime stress measurements.
/// Trigger: app foreground (daily backfill of missing days).
/// Pipeline: HealthKit HRV/RHR data → DaytimeStress algorithm → measurements → store.
class StressMeasurementProvider {
    private weak var measurementStore: MeasurementStore?
    private let healthKit: HealthKitManager

    init(healthKit: HealthKitManager, measurementStore: MeasurementStore) {
        self.healthKit = healthKit
        self.measurementStore = measurementStore
    }

    /// Compute and persist daily stress scores for up to `days` recent days.
    /// Already-computed days are skipped (deduplication by date + algorithm).
    /// Safe to call repeatedly — on subsequent calls only new/missing days are added.
    func computeMissingScores(days: Int = 90) {
        guard let store = measurementStore else { return }

        // Snapshot existing stress dates on main thread before going async
        let existingDates = Set(
            store.measurements
                .filter { m in m.type == .derived &&
                    m.sources.contains { $0.algorithmName == DaytimeStress.algorithmID } }
                .map { Calendar.current.startOfDay(for: $0.date) }
        )

        healthKit.fetchStressHistory(days: days) { [weak self] allDayInputs in
            let baselineDays = DaytimeStress.baselineWindowDays
            guard allDayInputs.count > baselineDays else {
                AppLogger.health.info("Stress: not enough history for baseline")
                return
            }

            // First `baselineDays` entries seed the baseline but are not scored themselves
            let scorable = Array(allDayInputs.dropFirst(baselineDays))

            DispatchQueue.global(qos: .userInitiated).async {
                var newMeasurements: [SensorMeasurement] = []

                for (i, inputs) in scorable.enumerated() {
                    let dayStart = Calendar.current.startOfDay(for: inputs.date)
                    guard !existingDates.contains(dayStart) else { continue }

                    // Baseline = all prior days (baseline window + already-scored days)
                    let priorDays = Array(allDayInputs.prefix(baselineDays + i))
                    let baseline  = DaytimeStress.buildBaseline(from: priorDays)

                    if let m = DaytimeStress.compute(inputs: inputs, baseline: baseline) {
                        newMeasurements.append(m)
                    }
                }

                DispatchQueue.main.async {
                    guard let store = self?.measurementStore else { return }
                    store.saveBatch(newMeasurements)
                    AppLogger.health.info("Stress: saved \(newMeasurements.count) daily scores")
                }
            }
        }
    }
}
