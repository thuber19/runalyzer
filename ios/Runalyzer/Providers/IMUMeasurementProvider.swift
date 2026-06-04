import Foundation

/// Self-contained provider for IMU workout measurements.
/// Trigger: IMU download completes.
/// Pipeline: raw samples → step detection (RunMetrics) → measurement + raw data → store.
class IMUMeasurementProvider {
    private weak var measurementStore: MeasurementStore?

    init(measurementStore: MeasurementStore) {
        self.measurementStore = measurementStore
    }

    /// Called when IMU download completes. Runs analysis on background thread,
    /// saves measurement on main thread, then calls completion.
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
            let analysis = RunMetrics.analyzeRecording(samples)

            let startDate: Date
            if startUnixMs > 0 {
                startDate = Date(timeIntervalSince1970: Double(startUnixMs) / 1000.0)
            } else {
                startDate = Date().addingTimeInterval(-durationSec)
            }

            // Summary data points
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

            // Windowed cadence as interval data points
            for w in analysis.cadenceWindows {
                let wStart = startDate.addingTimeInterval(Double(w.startMs) / 1000)
                let wEnd = startDate.addingTimeInterval(Double(w.endMs) / 1000)
                dp.append(DataPoint(timestamp: wStart, endTimestamp: wEnd, type: DataType.cadence,
                                    value: Double(w.cadence), unit: "spm", source: deviceSrc, role: .detail))
            }

            // Encode raw samples
            guard let rawData = try? JSONEncoder().encode(samples) else {
                print("Failed to encode IMU raw data")
                return
            }

            let measurement = SensorMeasurement(
                id: UUID(), date: startDate, type: .workout,
                sources: [source],
                dataPoints: dp, rawDataFiles: [rawFileName]
            )

            DispatchQueue.main.async {
                let saved = self?.measurementStore?.save(measurement,
                    rawData: [(filename: rawFileName, data: rawData)]) ?? false
                if saved { driver.eraseData() }
            }
        }
    }
}
