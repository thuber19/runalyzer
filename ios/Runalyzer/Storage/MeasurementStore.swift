import Foundation
import Combine

/// Unified storage for measurements from all device types.
/// Each measurement is indexed in a shared list, with actual data in separate files.
class MeasurementStore: ObservableObject {
    @Published var entries: [MeasurementEntry] = []

    private var storageDir: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Runalyzer/Measurements", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var indexURL: URL {
        storageDir.appendingPathComponent("index.json")
    }

    init() {
        loadIndex()
    }

    /// Save a measurement and add it to the index.
    @discardableResult
    func save<M: MeasurementData>(_ measurement: M) -> Bool {
        let fileName = "\(measurement.deviceType)_\(measurement.id.uuidString.prefix(8)).json"

        do {
            let data = try JSONEncoder().encode(measurement)
            try data.write(to: storageDir.appendingPathComponent(fileName), options: .atomic)
        } catch {
            print("Failed to save measurement: \(error)")
            return false
        }

        let entry = MeasurementEntry(
            id: measurement.id,
            date: measurement.date,
            deviceType: measurement.deviceType,
            deviceName: measurement.deviceName,
            summary: measurement.summary,
            dataFileName: fileName
        )

        entries.insert(entry, at: 0)
        return saveIndex()
    }

    /// Load the full measurement data for an entry.
    func load<M: MeasurementData>(_ entry: MeasurementEntry, as type: M.Type) -> M? {
        let url = storageDir.appendingPathComponent(entry.dataFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Delete a measurement.
    func delete(_ entry: MeasurementEntry) {
        try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(entry.dataFileName))
        entries.removeAll { $0.id == entry.id }
        saveIndex()
    }

    /// Get entries filtered by device type.
    func entries(forDeviceType type: String) -> [MeasurementEntry] {
        entries.filter { $0.deviceType == type }
    }

    func clearAll() {
        for e in entries {
            try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(e.dataFileName))
        }
        entries.removeAll()
        saveIndex()
    }

    @discardableResult
    private func saveIndex() -> Bool {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: indexURL, options: .atomic)
            return true
        } catch {
            print("Failed to save measurement index: \(error)")
            return false
        }
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let loaded = try? JSONDecoder().decode([MeasurementEntry].self, from: data) else { return }
        entries = loaded
    }
}
