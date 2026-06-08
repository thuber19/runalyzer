import Foundation

/// Self-contained provider for session enrichment measurements.
/// Trigger: user links an Apple Watch workout to an IMU session.
/// Pipeline: IMU session + Watch workout data → SessionEnrichment algorithm → measurement → store.
class EnrichmentProvider {
    private weak var measurementStore: MeasurementStore?

    init(measurementStore: MeasurementStore) {
        self.measurementStore = measurementStore
    }

    /// Create an enriched measurement combining IMU session data with Apple Watch workout data.
    /// Does nothing if an enrichment already exists for this session+workout pair.
    func enrichSession(_ session: RunSession, workout: AppleWorkout, runData: AppleRunData) {
        guard let store = measurementStore else { return }

        // Dedup: don't create a duplicate if one already exists for this workout
        let alreadyEnriched = store.measurements.contains { m in
            m.type == .derived &&
            m.sources.contains { $0.serialNumber == DataSource.healthKit(workout.id) }
        }
        guard !alreadyEnriched else { return }

        let imuID = SessionEnrichment.findIMUMeasurement(for: session, in: store)
        let input = SessionEnrichment.Input(
            session: session,
            workout: workout,
            runData: runData,
            imuMeasurementID: imuID
        )
        let derived = SessionEnrichment.compute(input)
        if !store.save(derived) {
            print("EnrichmentProvider: failed to save enriched measurement")
        }
    }
}
