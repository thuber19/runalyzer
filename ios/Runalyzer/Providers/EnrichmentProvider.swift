import Foundation
import os

/// Self-contained provider for session enrichment measurements.
/// Trigger: user links an Apple Watch workout to an IMU workout.
/// Pipeline: IMU workout + Watch workout data → SessionEnrichment algorithm → measurement → store.
class EnrichmentProvider {
    private weak var measurementStore: MeasurementStore?
    private weak var workoutStore: WorkoutStore?

    init(measurementStore: MeasurementStore, workoutStore: WorkoutStore) {
        self.measurementStore = measurementStore
        self.workoutStore = workoutStore
    }

    /// Create an enriched measurement combining IMU workout data with Apple Watch workout data.
    /// Does nothing if an enrichment already exists for this workout pair.
    func enrichWorkout(_ imuWorkout: Workout, appleWorkout: AppleWorkout, runData: AppleRunData) {
        guard let store = measurementStore else { return }

        // Dedup: don't create a duplicate if one already exists for this workout
        let alreadyEnriched = store.measurements.contains { m in
            m.type == .derived &&
            m.sources.contains { $0.serialNumber == DataSource.healthKit(appleWorkout.id) }
        }
        guard !alreadyEnriched else { return }

        let input = SessionEnrichment.Input(
            imuWorkout: imuWorkout,
            appleWorkout: appleWorkout,
            runData: runData
        )
        let derived = SessionEnrichment.compute(input)
        if !store.save(derived) {
            AppLogger.storage.error("EnrichmentProvider: failed to save enriched measurement")
        }
    }
}
