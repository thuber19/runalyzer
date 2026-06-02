import Foundation
import Combine

/// Central storage for ALL measurements from ALL device types.
/// Index stored as JSON, raw data in separate files.
class MeasurementStore: ObservableObject {
    @Published var measurements: [SensorMeasurement] = []

    private var storageDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Runalyzer/Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL { storageDir.appendingPathComponent("measurements.json") }

    init() { loadIndex() }

    // MARK: - Query

    func measurements(ofType type: MeasurementType) -> [SensorMeasurement] {
        measurements.filter { $0.type == type }
    }

    func measurement(byID id: UUID) -> SensorMeasurement? {
        measurements.first(where: { $0.id == id })
    }

    func linkedMeasurements(for measurement: SensorMeasurement) -> [SensorMeasurement] {
        guard let linked = measurement.linkedMeasurements else { return [] }
        return linked.compactMap { id in measurements.first(where: { $0.id == id }) }
    }

    // MARK: - Save

    /// Save a measurement with optional raw data file.
    @discardableResult
    func save(_ measurement: SensorMeasurement, rawData: [(filename: String, data: Data)] = []) -> Bool {
        // Duplicate check
        if measurements.contains(where: { $0.id == measurement.id }) { return true }

        // Write raw data files
        for raw in rawData {
            do {
                try raw.data.write(to: storageDir.appendingPathComponent(raw.filename), options: .atomic)
            } catch {
                print("Failed to write raw data \(raw.filename): \(error)")
                return false
            }
        }

        measurements.insert(measurement, at: 0)
        return saveIndex()
    }

    /// Save a body composition measurement (convenience)
    @discardableResult
    func saveBodyComp(weight: Double, impedance: Double, result: BodyCompositionResult, source: MeasurementSource) -> Bool {
        let now = Date()
        let dp: [DataPoint] = [
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.weight, value: weight, unit: "kg", source: source.id),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.impedance, value: impedance, unit: "Ω", source: source.id),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bmi, value: result.bmi, unit: "", source: "derived:body_comp_v1"),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bodyFatPercent, value: result.bodyFatPercent, unit: "%", source: "derived:body_comp_v1"),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.fatMassKg, value: result.fatMassKg, unit: "kg", source: "derived:body_comp_v1"),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.fatFreeMassKg, value: result.fatFreeMassKg, unit: "kg", source: "derived:body_comp_v1"),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.muscleMassKg, value: result.muscleMassKg, unit: "kg", source: "derived:body_comp_v1"),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.musclePercent, value: result.musclePercent, unit: "%", source: "derived:body_comp_v1"),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bodyWaterPercent, value: result.bodyWaterPercent, unit: "%", source: "derived:body_comp_v1"),
            DataPoint(timestamp: now, endTimestamp: nil, type: DataType.bmrKcal, value: result.bmrKcal, unit: "kcal", source: "derived:body_comp_v1"),
        ]

        let measurement = SensorMeasurement(
            id: UUID(), date: now, type: .bodyComp,
            sources: [source, .algorithm(name: "body_comp_v1")],
            dataPoints: dp, rawDataFiles: []
        )
        return save(measurement)
    }

    /// Save an IMU workout session (convenience)
    func saveIMUSession(samples: [RecordedSample], sampleRateHz: Int, durationSec: Double,
                        startUnixMs: UInt64, events: [IMUDeviceEvent]?, source: MeasurementSource,
                        completion: @escaping (Bool) -> Void) {
        guard !samples.isEmpty else { completion(false); return }

        let dir = storageDir
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
                         value: durationSec, unit: "s", source: source.id),
                DataPoint(timestamp: startDate, endTimestamp: nil, type: DataType.totalSteps,
                         value: Double(analysis.totalSteps), unit: "steps", source: source.id),
                DataPoint(timestamp: startDate, endTimestamp: nil, type: DataType.avgCadence,
                         value: Double(analysis.avgCadence), unit: "spm", source: source.id),
                DataPoint(timestamp: startDate, endTimestamp: nil, type: DataType.peakG,
                         value: Double(analysis.peakG), unit: "g", source: source.id),
            ]

            // Windowed cadence as interval data points
            for w in analysis.cadenceWindows {
                let wStart = startDate.addingTimeInterval(Double(w.startMs) / 1000)
                let wEnd = startDate.addingTimeInterval(Double(w.endMs) / 1000)
                dp.append(DataPoint(timestamp: wStart, endTimestamp: wEnd, type: DataType.cadence,
                                   value: Double(w.cadence), unit: "spm", source: source.id))
            }

            // Encode raw samples
            do {
                let rawData = try JSONEncoder().encode(samples)
                try rawData.write(to: dir.appendingPathComponent(rawFileName), options: .atomic)
            } catch {
                print("Failed to save IMU raw data: \(error)")
                DispatchQueue.main.async { completion(false) }
                return
            }

            let measurement = SensorMeasurement(
                id: UUID(), date: startDate, type: .workout,
                sources: [source],
                dataPoints: dp, rawDataFiles: [rawFileName]
            )

            DispatchQueue.main.async {
                let saved = self?.save(measurement) ?? false
                completion(saved)
            }
        }
    }

    // MARK: - Load Raw Data

    func loadIMUSamples(for measurement: SensorMeasurement) -> [RecordedSample] {
        guard let fileName = measurement.rawDataFiles.first(where: { $0.hasPrefix("imu_") }) else { return [] }
        let url = storageDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([RecordedSample].self, from: data) else { return [] }
        return samples
    }

    // MARK: - Link

    func link(_ id1: UUID, with id2: UUID) {
        guard let idx1 = measurements.firstIndex(where: { $0.id == id1 }),
              let idx2 = measurements.firstIndex(where: { $0.id == id2 }) else { return }
        var linked1 = measurements[idx1].linkedMeasurements ?? []
        var linked2 = measurements[idx2].linkedMeasurements ?? []
        if !linked1.contains(id2) { linked1.append(id2) }
        if !linked2.contains(id1) { linked2.append(id1) }
        measurements[idx1].linkedMeasurements = linked1
        measurements[idx2].linkedMeasurements = linked2
        saveIndex()
    }

    // MARK: - Delete

    func delete(_ id: UUID) {
        guard let idx = measurements.firstIndex(where: { $0.id == id }) else { return }
        let m = measurements[idx]
        for file in m.rawDataFiles {
            try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(file))
        }
        measurements.remove(at: idx)
        saveIndex()
    }

    // MARK: - Persistence

    @discardableResult
    private func saveIndex() -> Bool {
        do {
            let data = try JSONEncoder().encode(measurements)
            try data.write(to: indexURL, options: .atomic)
            return true
        } catch {
            print("Failed to save measurement index: \(error)")
            return false
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let loaded = try? JSONDecoder().decode([SensorMeasurement].self, from: data) else { return }
        measurements = loaded
    }
}
