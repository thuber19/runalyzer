import Foundation

/// Self-contained provider for IMU workout measurements.
/// Trigger: IMU download completes.
/// Pipeline: raw samples → step detection (RunMetrics) → measurement + raw data → store.
class IMUMeasurementProvider {
    private weak var measurementStore: MeasurementStore?
    private weak var sessionStore: SessionStore?  // legacy — kept until session detail views migrate

    init(measurementStore: MeasurementStore, sessionStore: SessionStore? = nil) {
        self.measurementStore = measurementStore
        self.sessionStore = sessionStore
    }

    /// Called when IMU download completes. Runs analysis on background thread,
    /// saves measurement on main thread, then erases device data on success.
    func handleDownloadComplete(
        samples: [RecordedSample],
        sampleRateHz: Int,
        durationSec: Double,
        startUnixMs: UInt64,
        events: [IMUDeviceEvent]?,
        driver: IMUSensorDriver
    ) {
        guard !samples.isEmpty else { return }

        let source = MeasurementSource.device(
            type: "imu_sensor",
            name: driver.displayName,
            serial: driver.id.uuidString
        )
        let deviceSrc = DataSource.device(source.serialNumber ?? source.deviceName)
        let rawFileName = "imu_\(UUID().uuidString.prefix(8)).json"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Analysis runs ONCE — results shared between MeasurementStore and legacy SessionStore
            let analysis = RunMetrics.analyzeRecording(samples)

            let startDate: Date
            if startUnixMs > 0 {
                startDate = Date(timeIntervalSince1970: Double(startUnixMs) / 1000.0)
            } else {
                startDate = Date().addingTimeInterval(-durationSec)
            }

            // Build SensorMeasurement for MeasurementStore
            var dp: [DataPoint] = [
                DataPoint(timestamp: startDate, endTimestamp: nil, type: DataType.durationSec,
                          value: durationSec, unit: "s", source: deviceSrc, role: .primary),
                DataPoint(timestamp: startDate, endTimestamp: nil, type: DataType.totalSteps,
                          value: Double(analysis.totalSteps), unit: "steps", source: deviceSrc, role: .primary),
                DataPoint(timestamp: startDate, endTimestamp: nil, type: DataType.avgCadence,
                          value: Double(analysis.avgCadence), unit: "spm", source: deviceSrc, role: .primary),
                DataPoint(timestamp: startDate, endTimestamp: nil, type: DataType.peakG,
                          value: Double(analysis.peakG), unit: "g", source: deviceSrc, role: .detail),
            ]

            for w in analysis.cadenceWindows {
                let wStart = startDate.addingTimeInterval(Double(w.startMs) / 1000)
                let wEnd = startDate.addingTimeInterval(Double(w.endMs) / 1000)
                dp.append(DataPoint(timestamp: wStart, endTimestamp: wEnd, type: DataType.cadence,
                                    value: Double(w.cadence), unit: "spm", source: deviceSrc, role: .detail))
            }

            guard let rawData = try? JSONEncoder().encode(samples) else {
                print("Failed to encode IMU raw data")
                return
            }

            let measurement = SensorMeasurement(
                id: UUID(), date: startDate, type: .workout,
                sources: [source],
                dataPoints: dp, rawDataFiles: [rawFileName]
            )

            // Build legacy RunSession (reuses analysis — no duplicate computation)
            let endDate = startDate.addingTimeInterval(durationSec)
            let legacySession = RunSession(
                id: UUID(),
                date: startDate,
                endDate: endDate,
                duration: durationSec,
                sampleCount: samples.count,
                avgCadence: Int(analysis.avgCadence),
                totalSteps: analysis.totalSteps,
                events: events,
                samplesFileName: rawFileName
            )

            DispatchQueue.main.async { [weak self] in
                // Save to MeasurementStore (new path)
                let saved = self?.measurementStore?.save(measurement,
                    rawData: [(filename: rawFileName, data: rawData)]) ?? false
                guard saved else {
                    print("IMU measurement save failed — keeping device data")
                    return
                }

                // Save to legacy SessionStore (uses pre-computed analysis)
                self?.sessionStore?.saveLegacySession(legacySession, rawSamples: samples)

                // Only erase device data after successful save
                driver.eraseData()
            }
        }
    }
}
