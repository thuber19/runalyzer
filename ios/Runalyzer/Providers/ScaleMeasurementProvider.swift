import Foundation

/// Self-contained provider for body composition measurements.
/// Trigger: scale driver emits a measurement event.
/// Pipeline: raw scale data → body comp algorithms → measurement → store.
class ScaleMeasurementProvider {
    private weak var measurementStore: MeasurementStore?

    init(measurementStore: MeasurementStore) {
        self.measurementStore = measurementStore
    }

    /// Called when the scale driver reports a completed measurement.
    func handleScaleMeasurement(_ m: ScaleMeasurement, from driver: QNScaleDriver) {
        let source = MeasurementSource.device(
            type: "qn_scale",
            name: driver.displayName,
            serial: driver.id.uuidString
        )
        let deviceSrc = DataSource.device(source.serialNumber ?? source.deviceName)

        let now = m.date
        var dp: [DataPoint] = [
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.weight,
                      value: m.weightKg, unit: "kg", source: deviceSrc, role: .primary),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bmi,
                      value: m.bmi, unit: "", source: DataSource.derived("bmi_standard"), role: .detail),
        ]

        if m.hasImpedance {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.impedance,
                                value: m.impedanceOhm, unit: "Ω", source: deviceSrc, role: .detail))
        }
        if let v = m.bodyFatPercent {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bodyFatPercent,
                                value: v, unit: "%", source: DataSource.derived("sun_et_al_2003"), role: .primary))
        }
        if let v = m.fatMassKg {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.fatMassKg,
                                value: v, unit: "kg", source: DataSource.derived("sun_et_al_2003"), role: .detail))
        }
        if let v = m.fatFreeMassKg {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.fatFreeMassKg,
                                value: v, unit: "kg", source: DataSource.derived("sun_et_al_2003"), role: .detail))
        }
        if let v = m.muscleMassKg {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.muscleMassKg,
                                value: v, unit: "kg", source: DataSource.derived("janssen_et_al_2000"), role: .primary))
        }
        if let v = m.musclePercent {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.musclePercent,
                                value: v, unit: "%", source: DataSource.derived("janssen_et_al_2000"), role: .primary))
        }
        if let v = m.bodyWaterPercent {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bodyWaterPercent,
                                value: v, unit: "%", source: DataSource.derived("sun_et_al_2003"), role: .detail))
        }
        if let v = m.bmrKcal {
            dp.append(DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bmrKcal,
                                value: v, unit: "kcal", source: DataSource.derived("mifflin_st_jeor_1990"), role: .detail))
        }

        var sources = [source]
        if m.hasImpedance { sources.append(.algorithm(name: "body_comp_v1")) }

        let measurement = SensorMeasurement(
            id: UUID(), date: now, type: .bodyComp,
            sources: sources,
            dataPoints: dp, rawDataFiles: []
        )
        measurementStore?.save(measurement)
    }
}
