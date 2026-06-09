import Foundation
import Combine
import os

/// Self-contained provider for body composition measurements.
/// Trigger: scale driver emits a raw reading (weight + impedance).
/// Pipeline: raw reading → fetch profile → body comp algorithm → measurement → store.
class ScaleMeasurementProvider {
    private weak var measurementStore: MeasurementStore?
    private weak var profileProvider: UserProfileProvider?

    /// Last completed measurement (for dashboard display).
    @Published var lastMeasurement: ScaleMeasurement?

    init(measurementStore: MeasurementStore, profileProvider: UserProfileProvider) {
        self.measurementStore = measurementStore
        self.profileProvider = profileProvider
    }

    /// Called when the scale driver reports a stable reading.
    /// Fetches profile, runs body comp algorithm, builds measurement, saves to DB.
    func handleReading(_ reading: ScaleReading, from driver: QNScaleDriver) {
        let profile = profileProvider?.profile ?? .default
        let now = Date()

        // Run body comp algorithm if impedance is available
        let measurement: ScaleMeasurement
        if reading.hasImpedance && reading.impedanceOhm > 0 {
            let result = BodyComposition.calculate(
                weightKg: reading.weightKg,
                impedanceOhm: reading.impedanceOhm,
                profile: profile
            )
            measurement = ScaleMeasurement(
                id: UUID(), date: now, deviceName: reading.deviceName,
                weightKg: result.weightKg, impedanceOhm: result.impedanceOhm, hasImpedance: true,
                bmi: result.bmi, bodyFatPercent: result.bodyFatPercent,
                fatMassKg: result.fatMassKg, fatFreeMassKg: result.fatFreeMassKg,
                muscleMassKg: result.muscleMassKg, musclePercent: result.musclePercent,
                bodyWaterPercent: result.bodyWaterPercent, bmrKcal: result.bmrKcal
            )
        } else {
            let heightM = profile.heightCm / 100.0
            let bmi = heightM > 0 ? reading.weightKg / (heightM * heightM) : 0
            measurement = ScaleMeasurement(
                id: UUID(), date: now, deviceName: reading.deviceName,
                weightKg: round(reading.weightKg * 100) / 100, impedanceOhm: 0, hasImpedance: false,
                bmi: round(bmi * 10) / 10, bodyFatPercent: nil,
                fatMassKg: nil, fatFreeMassKg: nil,
                muscleMassKg: nil, musclePercent: nil,
                bodyWaterPercent: nil, bmrKcal: nil
            )
        }

        lastMeasurement = measurement

        // Build DataPoints and save to DB
        let source = MeasurementSource.device(
            type: "qn_scale",
            name: driver.displayName,
            serial: driver.id.uuidString
        )
        let deviceSrc = DataSource.device(source.serialNumber ?? source.deviceName)

        var dp: [DataPoint] = [
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.weight,
                      value: measurement.weightKg, unit: "kg", source: deviceSrc, role: .primary),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bmi,
                      value: measurement.bmi, unit: "", source: DataSource.derived("bmi_standard"), role: .detail),
        ]

        if measurement.hasImpedance {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.impedance,
                                value: measurement.impedanceOhm, unit: "Ω", source: deviceSrc, role: .detail))
        }
        if let v = measurement.bodyFatPercent {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bodyFatPercent,
                                value: v, unit: "%", source: DataSource.derived("sun_et_al_2003"), role: .primary))
        }
        if let v = measurement.fatMassKg {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.fatMassKg,
                                value: v, unit: "kg", source: DataSource.derived("sun_et_al_2003"), role: .detail))
        }
        if let v = measurement.fatFreeMassKg {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.fatFreeMassKg,
                                value: v, unit: "kg", source: DataSource.derived("sun_et_al_2003"), role: .detail))
        }
        if let v = measurement.muscleMassKg {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.muscleMassKg,
                                value: v, unit: "kg", source: DataSource.derived("janssen_et_al_2000"), role: .primary))
        }
        if let v = measurement.musclePercent {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.musclePercent,
                                value: v, unit: "%", source: DataSource.derived("janssen_et_al_2000"), role: .primary))
        }
        if let v = measurement.bodyWaterPercent {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bodyWaterPercent,
                                value: v, unit: "%", source: DataSource.derived("sun_et_al_2003"), role: .detail))
        }
        if let v = measurement.bmrKcal {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bmrKcal,
                                value: v, unit: "kcal", source: DataSource.derived("mifflin_st_jeor_1990"), role: .detail))
        }

        var sources = [source]
        if measurement.hasImpedance { sources.append(.algorithm(name: "body_comp_v1")) }

        let sensorMeasurement = SensorMeasurement(
            id: UUID(), date: now, type: .bodyComp,
            sources: sources,
            dataPoints: dp, rawDataFiles: []
        )
        if measurementStore?.save(sensorMeasurement) != true {
            AppLogger.storage.error("ScaleMeasurementProvider: failed to save body comp measurement")
        }
    }
}
