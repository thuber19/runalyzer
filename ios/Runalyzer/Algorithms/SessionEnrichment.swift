import Foundation

/// Combines an IMU session with a linked Apple Watch workout into a single `.derived`
/// SensorMeasurement.  This is the foundation for future cross-sensor algorithms.
///
/// Inputs  — stay in their original stores (SessionStore / HealthKit); not duplicated.
/// Outputs — key summary metrics + derived values stored as DataPoints.
/// Provenance — inputMeasurements links back to the source IMU SensorMeasurement if known.
enum SessionEnrichment {

    static let algorithmID = "session_enrichment_v1"

    // MARK: - Compute

    struct Input {
        let session: RunSession
        let workout: AppleWorkout
        let runData: AppleRunData
        /// ID of the SensorMeasurement for the IMU session (found by date match in MeasurementStore).
        let imuMeasurementID: UUID?
    }

    /// Builds the derived SensorMeasurement. Does NOT save it — caller decides when to persist.
    static func compute(_ input: Input) -> SensorMeasurement {
        let date        = input.session.date
        let durationSec = input.session.duration
        let distanceKm  = input.runData.distanceKm
        var dp: [DataPoint] = []

        // MARK: IMU metrics (source: the session itself)
        let imuSrc = DataSource.device(input.session.id.uuidString)
        dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                            type: DataType.avgCadence,
                            value: Double(input.session.avgCadence),
                            unit: "spm", source: imuSrc))
        if let steps = input.session.totalSteps, steps > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.totalSteps,
                                value: Double(steps),
                                unit: "steps", source: imuSrc))
        }
        dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                            type: DataType.durationSec,
                            value: durationSec,
                            unit: "s", source: imuSrc))

        // MARK: Apple Watch metrics (source: HK workout UUID)
        let hkSrc = DataSource.healthKit(input.workout.id)
        if input.runData.avgHeartRate > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.heartRate,
                                value: input.runData.avgHeartRate,
                                unit: "bpm", source: hkSrc))
        }
        if distanceKm > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.distance,
                                value: distanceKm,
                                unit: "km", source: hkSrc))
        }
        if input.runData.activeCalories > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.activeCalories,
                                value: input.runData.activeCalories,
                                unit: "kcal", source: hkSrc))
        }

        // MARK: Derived metrics
        let derivedSrc = DataSource.derived(algorithmID)

        // Pace (min/km) from Watch distance + IMU duration
        if distanceKm > 0 && durationSec > 0 {
            let pace = (durationSec / 60.0) / distanceKm
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.pace,
                                value: pace,
                                unit: "min/km", source: derivedSrc))
        }

        // Step length (m/step) from Watch distance + IMU step count
        if distanceKm > 0, let steps = input.session.totalSteps, steps > 0 {
            let stepLengthM = (distanceKm * 1000.0) / Double(steps)
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.stepLength,
                                value: stepLengthM,
                                unit: "m", source: derivedSrc))
        }

        // Running economy proxy: beats/km = avgHR × pace (min/km)
        // Lower value = less HR cost per km = more efficient aerobically.
        // Not a true VO2-based economy score, but a useful relative training metric.
        if input.runData.avgHeartRate > 0 && distanceKm > 0 && durationSec > 0 {
            let pace = (durationSec / 60.0) / distanceKm
            let economy = input.runData.avgHeartRate * pace
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.runningEconomy,
                                value: economy,
                                unit: "beats/km", source: derivedSrc))
        }

        // Aerobic load: avgHR × duration_min — a simple session training stress score
        if input.runData.avgHeartRate > 0 && durationSec > 0 {
            let load = input.runData.avgHeartRate * (durationSec / 60.0)
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.aerobicLoad,
                                value: load,
                                unit: "AU", source: derivedSrc))
        }

        // MARK: Sources list
        let sources: [MeasurementSource] = [
            .device(type: "imu_sensor", name: "Runalyzer IMU",
                    serial: input.session.id.uuidString),
            .healthKit(workoutID: input.workout.id, name: input.workout.activityName),
            .algorithm(name: algorithmID),
        ]

        let inputIDs: [UUID]? = input.imuMeasurementID.map { [$0] }

        return SensorMeasurement(
            id: UUID(),
            date: date,
            type: .derived,
            sources: sources,
            dataPoints: dp,
            rawDataFiles: [],
            inputMeasurements: inputIDs
        )
    }

    // MARK: - Convenience: find IMU measurement by date

    /// Looks up the SensorMeasurement in the store whose date is within 30s of the session date.
    /// Used to populate `inputMeasurements` provenance on the derived record.
    static func findIMUMeasurement(for session: RunSession,
                                   in store: MeasurementStore) -> UUID? {
        store.measurements
            .filter { $0.type == .workout }
            .first { abs($0.date.timeIntervalSince(session.date)) < 30 }?
            .id
    }
}
