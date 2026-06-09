import Foundation

/// Combines an IMU workout with a linked Apple Watch workout into a single `.derived`
/// SensorMeasurement.  This is the foundation for future cross-sensor algorithms.
///
/// Inputs  — stay in their original stores (WorkoutStore / HealthKit); not duplicated.
/// Outputs — key summary metrics + derived values stored as DataPoints.
/// Provenance — inputMeasurements links back to the source IMU workout if known.
enum SessionEnrichment {

    static let algorithmID = "session_enrichment_v1"

    // MARK: - Compute

    struct Input {
        let imuWorkout: Workout
        let appleWorkout: AppleWorkout
        let runData: AppleRunData
    }

    /// Builds the derived SensorMeasurement. Does NOT save it — caller decides when to persist.
    static func compute(_ input: Input) -> SensorMeasurement {
        let date        = input.imuWorkout.startDate
        let durationSec = input.imuWorkout.durationSec ?? 0
        let distanceKm  = input.runData.distanceKm
        var dp: [DataPoint] = []

        // MARK: IMU metrics (source: the workout itself)
        let imuSrc = DataSource.device(input.imuWorkout.id.uuidString)
        dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                            type: DataType.durationSec,
                            value: durationSec,
                            unit: "s", source: imuSrc, role: .detail))

        // MARK: Apple Watch metrics (source: HK workout UUID)
        let hkSrc = DataSource.healthKit(input.appleWorkout.id)
        if input.runData.avgHeartRate > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.heartRate,
                                value: input.runData.avgHeartRate,
                                unit: "bpm", source: hkSrc, role: .primary))
        }
        if distanceKm > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.distance,
                                value: distanceKm,
                                unit: "km", source: hkSrc, role: .primary))
        }
        if input.runData.activeCalories > 0 {
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.activeCalories,
                                value: input.runData.activeCalories,
                                unit: "kcal", source: hkSrc, role: .detail))
        }

        // MARK: Derived metrics
        let derivedSrc = DataSource.derived(algorithmID)

        // Pace (min/km) from Watch distance + IMU duration
        if distanceKm > 0 && durationSec > 0 {
            let pace = (durationSec / 60.0) / distanceKm
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.pace,
                                value: pace,
                                unit: "min/km", source: derivedSrc, role: .primary))
        }

        // Running economy proxy: beats/km = avgHR × pace (min/km)
        if input.runData.avgHeartRate > 0 && distanceKm > 0 && durationSec > 0 {
            let pace = (durationSec / 60.0) / distanceKm
            let economy = input.runData.avgHeartRate * pace
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.runningEconomy,
                                value: economy,
                                unit: "beats/km", source: derivedSrc, role: .detail))
        }

        // Aerobic load: avgHR × duration_min — a simple session training stress score
        if input.runData.avgHeartRate > 0 && durationSec > 0 {
            let load = input.runData.avgHeartRate * (durationSec / 60.0)
            dp.append(DataPoint(timestamp: date, endTimestamp: nil,
                                type: DataType.aerobicLoad,
                                value: load,
                                unit: "AU", source: derivedSrc, role: .detail))
        }

        // MARK: Sources list
        let sources: [MeasurementSource] = [
            .device(type: "imu_sensor", name: "Runalyzer IMU",
                    serial: input.imuWorkout.id.uuidString),
            .healthKit(workoutID: input.appleWorkout.id, name: input.appleWorkout.activityName),
            .algorithm(name: algorithmID),
        ]

        return SensorMeasurement(
            id: UUID(),
            date: date,
            type: .derived,
            sources: sources,
            dataPoints: dp,
            rawDataFiles: [],
            inputMeasurements: [input.imuWorkout.id]
        )
    }
}
