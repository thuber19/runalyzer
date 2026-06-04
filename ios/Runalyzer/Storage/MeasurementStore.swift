import Foundation
import Combine

/// Central storage for ALL measurements from ALL device types.
/// Index stored as JSON, raw data in separate files.
class MeasurementStore: ObservableObject {
    @Published var measurements: [SensorMeasurement] = []
    @Published var corruptDataDetected = false

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
    /// Must be called on main thread (@Published mutations).
    @discardableResult
    func save(_ measurement: SensorMeasurement, rawData: [(filename: String, data: Data)] = []) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.save must be called on main thread")
        if measurements.contains(where: { $0.id == measurement.id }) { return true }

        // Write raw data files
        for raw in rawData {
            do {
                try raw.data.write(to: storageDir.appendingPathComponent(raw.filename),
                                   options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                print("Failed to write raw data \(raw.filename): \(error)")
                return false
            }
        }

        measurements.insert(measurement, at: 0)
        return saveIndex()
    }

    /// Batch-save multiple measurements in one index write (avoids N re-encodes).
    /// Must be called on main thread (@Published mutations).
    @discardableResult
    func saveBatch(_ newMeasurements: [SensorMeasurement]) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.saveBatch must be called on main thread")
        var added = 0
        for m in newMeasurements {
            guard !measurements.contains(where: { $0.id == m.id }) else { continue }
            measurements.insert(m, at: 0)
            added += 1
        }
        guard added > 0 else { return true }
        return saveIndex()
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

    @discardableResult
    func link(_ id1: UUID, with id2: UUID) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.link must be called on main thread")
        guard let idx1 = measurements.firstIndex(where: { $0.id == id1 }),
              let idx2 = measurements.firstIndex(where: { $0.id == id2 }) else { return false }
        var linked1 = measurements[idx1].linkedMeasurements ?? []
        var linked2 = measurements[idx2].linkedMeasurements ?? []
        if !linked1.contains(id2) { linked1.append(id2) }
        if !linked2.contains(id1) { linked2.append(id1) }
        measurements[idx1].linkedMeasurements = linked1
        measurements[idx2].linkedMeasurements = linked2
        return saveIndex()
    }

    // MARK: - Delete

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.delete must be called on main thread")
        guard let idx = measurements.firstIndex(where: { $0.id == id }) else { return false }
        let m = measurements[idx]
        for file in m.rawDataFiles {
            try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(file))
        }
        measurements.remove(at: idx)
        return saveIndex()
    }

    /// Batch-delete multiple measurements in one index write.
    @discardableResult
    func deleteBatch(_ ids: Set<UUID>) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.deleteBatch must be called on main thread")
        for id in ids {
            guard let idx = measurements.firstIndex(where: { $0.id == id }) else { continue }
            let m = measurements[idx]
            for file in m.rawDataFiles {
                try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(file))
            }
            measurements.remove(at: idx)
        }
        return saveIndex()
    }

    // MARK: - Persistence

    @discardableResult
    private func saveIndex() -> Bool {
        do {
            let data = try JSONEncoder().encode(measurements)
            try data.write(to: indexURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            return true
        } catch {
            print("Failed to save measurement index: \(error)")
            return false
        }
    }

    private func loadIndex() {
        let fm = FileManager.default
        if fm.fileExists(atPath: indexURL.path) {
            do {
                let data = try Data(contentsOf: indexURL)
                measurements = try JSONDecoder().decode([SensorMeasurement].self, from: data)
                return
            } catch let error as NSError where error.domain == NSCocoaErrorDomain {
                // IO error — file may be healthy but temporarily inaccessible; don't touch it
                measurements = []
                return
            } catch {
                // JSON decode failure — genuinely corrupt; back it up
                let backupURL = indexURL.deletingLastPathComponent()
                    .appendingPathComponent("measurements_corrupt_\(Int(Date().timeIntervalSince1970)).json")
                try? fm.moveItem(at: indexURL, to: backupURL)
            }
        }

        if let restored = latestBackupMeasurements() {
            measurements = restored
            saveIndex()
        } else {
            measurements = []
            corruptDataDetected = true
        }
    }

    private func latestBackupMeasurements() -> [SensorMeasurement]? {
        let dir = indexURL.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return nil }
        let backups = files
            .filter { $0.hasPrefix("measurements_corrupt_") && $0.hasSuffix(".json") }
            .sorted(by: >)
        for name in backups {
            let url = dir.appendingPathComponent(name)
            if let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode([SensorMeasurement].self, from: data),
               !decoded.isEmpty {
                try? FileManager.default.removeItem(at: url)
                return decoded
            }
        }
        return nil
    }
}
