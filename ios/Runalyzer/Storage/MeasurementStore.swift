import Foundation
import Combine
import GRDB
import os

/// Central storage for measurements (metrics, body comp, derived scores).
/// Backed by GRDB/SQLite. Workouts are stored separately in WorkoutStore.
///
/// The `measurements` array holds lightweight headers (no DataPoints) for
/// list views. DataPoints are fetched from SQLite on demand.
class MeasurementStore: ObservableObject {
    @Published var measurements: [SensorMeasurement] = []

    private let db: AppDatabase

    private var storageDir: URL { AppDatabase.storageDir }

    init(db: AppDatabase? = nil) {
        self.db = db ?? AppDatabase.shared
        loadMeasurements()
    }

    // MARK: - Load (lightweight headers only)

    private func loadMeasurements() {
        do {
            let records: [MeasurementRecord] = try db.dbQueue.read { db in
                try MeasurementRecord
                    .order(Column("date").desc)
                    .fetchAll(db)
            }
            // Load headers with sources but WITHOUT DataPoints (memory win)
            measurements = try db.dbQueue.read { db in
                try records.map { record in
                    let sources = try MeasurementSourceRecord
                        .filter(Column("measurementId") == record.id)
                        .fetchAll(db)
                        .map { $0.toModel() }
                    return record.toModel(sources: sources)
                }
            }
        } catch {
            AppLogger.storage.error("Failed to load measurements: \(error.localizedDescription)")
            measurements = []
        }
    }

    // MARK: - Query

    func measurements(ofType type: MeasurementType) -> [SensorMeasurement] {
        measurements.filter { $0.type == type }
    }

    func measurement(byID id: UUID) -> SensorMeasurement? {
        measurements.first(where: { $0.id == id })
    }

    /// Fetch all DataPoints of a given type across all measurements via SQL.
    /// Replaces the old in-memory `_dpIndex`.
    func dataPoints(ofType type: String) -> [DataPoint] {
        do {
            return try db.dbQueue.read { db in
                try DataPointRecord
                    .filter(Column("type") == type)
                    .order(Column("timestamp"))
                    .fetchAll(db)
                    .map { $0.toModel() }
            }
        } catch {
            AppLogger.storage.error("dataPoints query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch all DataPoints for a specific measurement (on-demand loading).
    func dataPoints(for measurementID: UUID) -> [DataPoint] {
        do {
            return try db.dbQueue.read { db in
                try DataPointRecord
                    .filter(Column("measurementId") == measurementID.uuidString)
                    .order(Column("timestamp"))
                    .fetchAll(db)
                    .map { $0.toModel() }
            }
        } catch {
            return []
        }
    }

    /// Full measurement with all DataPoints loaded (for detail views).
    func fullMeasurement(byID id: UUID) -> SensorMeasurement? {
        guard let header = measurement(byID: id) else { return nil }
        let dps = dataPoints(for: id)
        return SensorMeasurement(
            id: header.id, date: header.date, type: header.type,
            sources: header.sources, dataPoints: dps,
            rawDataFiles: header.rawDataFiles,
            linkedMeasurements: header.linkedMeasurements,
            inputMeasurements: header.inputMeasurements
        )
    }

    // MARK: - Save

    @discardableResult
    func save(_ measurement: SensorMeasurement, rawData: [(filename: String, data: Data)] = []) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.save must be called on main thread")
        if measurements.contains(where: { $0.id == measurement.id }) { return true }

        // Write raw data files to disk
        for raw in rawData {
            do {
                try raw.data.write(to: storageDir.appendingPathComponent(raw.filename),
                                   options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                print("Failed to write raw data \(raw.filename): \(error)")
                return false
            }
        }

        do {
            try db.dbQueue.write { db in
                let record = MeasurementRecord(from: measurement)
                try record.insert(db)

                for source in measurement.sources {
                    let srcRecord = MeasurementSourceRecord(measurementId: record.id, from: source)
                    try srcRecord.insert(db)
                }

                for dp in measurement.dataPoints {
                    let dpRecord = DataPointRecord(measurementId: record.id, from: dp)
                    try dpRecord.insert(db)
                }
            }

            // Add lightweight header to in-memory array (no DataPoints)
            let header = SensorMeasurement(
                id: measurement.id, date: measurement.date, type: measurement.type,
                sources: measurement.sources, dataPoints: [],
                rawDataFiles: measurement.rawDataFiles,
                linkedMeasurements: measurement.linkedMeasurements,
                inputMeasurements: measurement.inputMeasurements
            )
            measurements.insert(header, at: 0)
            return true
        } catch {
            print("Failed to save measurement to DB: \(error)")
            return false
        }
    }

    @discardableResult
    func saveBatch(_ newMeasurements: [SensorMeasurement]) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.saveBatch must be called on main thread")
        let toInsert = newMeasurements.filter { m in
            !measurements.contains(where: { $0.id == m.id })
        }
        guard !toInsert.isEmpty else { return true }

        do {
            try db.dbQueue.write { db in
                for measurement in toInsert {
                    let record = MeasurementRecord(from: measurement)
                    try record.insert(db)

                    for source in measurement.sources {
                        let srcRecord = MeasurementSourceRecord(measurementId: record.id, from: source)
                        try srcRecord.insert(db)
                    }

                    for dp in measurement.dataPoints {
                        let dpRecord = DataPointRecord(measurementId: record.id, from: dp)
                        try dpRecord.insert(db)
                    }
                }
            }

            for measurement in toInsert {
                let header = SensorMeasurement(
                    id: measurement.id, date: measurement.date, type: measurement.type,
                    sources: measurement.sources, dataPoints: [],
                    rawDataFiles: measurement.rawDataFiles,
                    inputMeasurements: measurement.inputMeasurements
                )
                measurements.insert(header, at: 0)
            }
            return true
        } catch {
            print("Failed to save batch to DB: \(error)")
            return false
        }
    }

    @discardableResult
    func update(_ measurement: SensorMeasurement) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.update must be called on main thread")
        guard let idx = measurements.firstIndex(where: { $0.id == measurement.id }) else { return false }

        do {
            try db.dbQueue.write { db in
                let record = MeasurementRecord(from: measurement)
                try record.update(db)

                // Replace all sources
                try db.execute(sql: "DELETE FROM measurement_source WHERE measurementId = ?",
                               arguments: [record.id])
                for source in measurement.sources {
                    let srcRecord = MeasurementSourceRecord(measurementId: record.id, from: source)
                    try srcRecord.insert(db)
                }

                // Replace all DataPoints
                try db.execute(sql: "DELETE FROM data_point WHERE measurementId = ?",
                               arguments: [record.id])
                for dp in measurement.dataPoints {
                    let dpRecord = DataPointRecord(measurementId: record.id, from: dp)
                    try dpRecord.insert(db)
                }
            }

            // Update in-memory header (without DataPoints)
            measurements[idx] = SensorMeasurement(
                id: measurement.id, date: measurement.date, type: measurement.type,
                sources: measurement.sources, dataPoints: [],
                rawDataFiles: measurement.rawDataFiles,
                inputMeasurements: measurement.inputMeasurements
            )
            return true
        } catch {
            print("Failed to update measurement in DB: \(error)")
            return false
        }
    }

    /// Append DataPoints to an existing measurement (used by HealthKit enrichment).
    @discardableResult
    func appendDataPoints(_ points: [DataPoint], to measurementID: UUID) -> Bool {
        guard !points.isEmpty else { return true }
        do {
            try db.dbQueue.write { db in
                for dp in points {
                    let record = DataPointRecord(measurementId: measurementID.uuidString, from: dp)
                    try record.insert(db)
                }
            }
            return true
        } catch {
            print("Failed to append DataPoints: \(error)")
            return false
        }
    }

    /// Persist index — now a no-op (DB writes are immediate). Kept for API compatibility.
    @discardableResult
    func saveIndex() -> Bool { true }

    // MARK: - Load Raw Data

    func loadIMUSamples(for measurement: SensorMeasurement) -> [RecordedSample] {
        guard let fileName = measurement.rawDataFiles.first(where: { $0.hasPrefix("imu_") }) else { return [] }
        let url = storageDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([RecordedSample].self, from: data) else { return [] }
        return samples
    }

    /// Load IMU samples by workout (for the new Workout entity).
    func loadIMUSamples(for workout: Workout) -> [RecordedSample] {
        guard let fileName = workout.rawDataFiles.first(where: { $0.hasPrefix("imu_") }) else { return [] }
        let url = storageDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([RecordedSample].self, from: data) else { return [] }
        return samples
    }

    // MARK: - Delete

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.delete must be called on main thread")
        guard let idx = measurements.firstIndex(where: { $0.id == id }) else { return false }
        let m = measurements[idx]

        do {
            try db.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM measurement WHERE id = ?", arguments: [id.uuidString])
            }
            for file in m.rawDataFiles {
                try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(file))
            }
            measurements.remove(at: idx)
            return true
        } catch {
            print("Failed to delete measurement: \(error)")
            return false
        }
    }

    @discardableResult
    func deleteBatch(_ ids: Set<UUID>) -> Bool {
        assert(Thread.isMainThread, "MeasurementStore.deleteBatch must be called on main thread")

        do {
            try db.dbQueue.write { db in
                for id in ids {
                    try db.execute(sql: "DELETE FROM measurement WHERE id = ?", arguments: [id.uuidString])
                }
            }
            for id in ids {
                if let idx = measurements.firstIndex(where: { $0.id == id }) {
                    let m = measurements[idx]
                    for file in m.rawDataFiles {
                        try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(file))
                    }
                    measurements.remove(at: idx)
                }
            }
            return true
        } catch {
            print("Failed to delete batch: \(error)")
            return false
        }
    }

    // MARK: - SQL Helpers (used by MetricIndex and other query layers)

    /// Execute a read query and return DataPoints. For use by MetricIndex.
    func queryDataPoints(sql: String, arguments: StatementArguments = StatementArguments()) -> [DataPoint] {
        do {
            return try db.dbQueue.read { db in
                try DataPointRecord.fetchAll(db, sql: sql, arguments: arguments).map { $0.toModel() }
            }
        } catch {
            AppLogger.storage.error("Query failed: \(error.localizedDescription)")
            return []
        }
    }
}
