import Foundation
import os

/// Self-contained provider for IMU workout recordings.
/// Trigger: IMU download completes.
/// Pipeline: raw samples → step detection (RunMetrics) → Workout + raw data → WorkoutStore.
class IMUMeasurementProvider {
    private weak var workoutStore: WorkoutStore?

    init(workoutStore: WorkoutStore) {
        self.workoutStore = workoutStore
    }

    /// Called when IMU download completes. Runs analysis on background thread,
    /// saves workout on main thread, then erases device data on success.
    func handleDownloadComplete(
        samples: [RecordedSample],
        sampleRateHz: Int,
        durationSec: Double,
        startUnixMs: UInt64,
        events: [IMUDeviceEvent]?,
        driver: IMUSensorDriver
    ) {
        guard !samples.isEmpty else { return }

        let deviceSrc = DataSource.device(driver.id.uuidString)
        let rawFileName = "imu_\(UUID().uuidString.prefix(8)).json"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let analysis = RunMetrics.analyzeRecording(samples)

            let startDate: Date
            if startUnixMs > 0 {
                startDate = Date(timeIntervalSince1970: Double(startUnixMs) / 1000.0)
            } else {
                startDate = Date().addingTimeInterval(-durationSec)
            }
            let endDate = startDate.addingTimeInterval(durationSec)

            // Build workout-specific DataPoints (stored in workout_data_point table)
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
                AppLogger.storage.error("Failed to encode IMU raw data")
                return
            }

            let workout = Workout(
                id: UUID(),
                startDate: startDate,
                endDate: endDate,
                activityType: "IMU Recording",
                source: deviceSrc,
                durationSec: durationSec,
                rawDataFiles: [rawFileName]
            )

            DispatchQueue.main.async { [weak self] in
                // Write raw data file
                let storageDir = AppDatabase.storageDir
                let rawURL = storageDir.appendingPathComponent(rawFileName)
                do {
                    try rawData.write(to: rawURL,
                                      options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                } catch {
                    AppLogger.storage.error("Failed to write IMU raw data: \(error.localizedDescription)")
                    return
                }

                // Save to WorkoutStore
                let saved = self?.workoutStore?.save(workout, dataPoints: dp) ?? false
                guard saved else {
                    AppLogger.storage.error("IMU workout save failed — keeping device data")
                    return
                }

                // Only erase device data after successful save
                driver.eraseData()
            }
        }
    }
}
