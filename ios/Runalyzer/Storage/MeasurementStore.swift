import Foundation
import Combine
import GRDB
import os

/// Central storage for measurements (metrics, body comp, derived scores).
/// Backed by GRDB/SQLite. Workouts are stored separately in WorkoutStore.
///
/// The `measurements` array auto-updates via GRDB ValueObservation when the
/// database changes. Headers are lightweight (no DataPoints loaded).
class MeasurementStore: ObservableObject {
    @Published var measurements: [SensorMeasurement] = []

    private let db: AppDatabase
    private var observationCancellable: AnyDatabaseCancellable?

    private var storageDir: URL { AppDatabase.storageDir }

    init(db: AppDatabase? = nil) {
        self.db = db ?? AppDatabase.shared
        startObservation()
    }

    // MARK: - Reactive Observation

    /// Observes the measurement table and auto-updates the published array.
    private func startObservation() {
        let observation = ValueObservation.tracking { db -> [SensorMeasurement] in
            let records = try MeasurementRecord
                .order(Column("date").desc)
                .fetchAll(db)

            // Batch-load all sources in a single query to avoid N+1
            let allSources = try MeasurementSourceRecord.fetchAll(db)
            var sourcesByMeasurement: [String: [MeasurementSource]] = [:]
            for src in allSources {
                sourcesByMeasurement[src.measurementId, default: []].append(src.toModel())
            }

            // Batch-load primary data points for types that need them for list display
            // Batch-load primary data points for derived measurements (scores for list display)
            let derivedIDs = records.filter { $0.type == MeasurementType.derived.rawValue }.map(\.id)
            var primaryDPsByMeasurement: [String: [DataPoint]] = [:]
            if !derivedIDs.isEmpty {
                let placeholders = derivedIDs.map { _ in "?" }.joined(separator: ",")
                let sql = "SELECT * FROM data_point WHERE measurementId IN (\(placeholders)) AND role = 'primary'"
                let rows = try DataPointRecord.fetchAll(db, sql: sql,
                    arguments: StatementArguments(derivedIDs))
                for row in rows {
                    primaryDPsByMeasurement[row.measurementId, default: []].append(row.toModel())
                }
            }

            // Batch-load all data points for fluid intake and check-in (2-4 DPs each)
            let lightweightTypes: Set<String> = [
                MeasurementType.fluidIntake.rawValue,
                MeasurementType.checkIn.rawValue,
                MeasurementType.wellnessSession.rawValue
            ]
            let lightweightIDs = records.filter { lightweightTypes.contains($0.type) }.map(\.id)
            if !lightweightIDs.isEmpty {
                let placeholders = lightweightIDs.map { _ in "?" }.joined(separator: ",")
                let sql = "SELECT * FROM data_point WHERE measurementId IN (\(placeholders))"
                let rows = try DataPointRecord.fetchAll(db, sql: sql,
                    arguments: StatementArguments(lightweightIDs))
                for row in rows {
                    primaryDPsByMeasurement[row.measurementId, default: []].append(row.toModel())
                }
            }

            return records.map { record in
                record.toModel(
                    sources: sourcesByMeasurement[record.id] ?? [],
                    dataPoints: primaryDPsByMeasurement[record.id] ?? []
                )
            }
        }

        observationCancellable = observation.start(
            in: db.dbQueue,
            scheduling: .immediate,
            onError: { error in
                AppLogger.storage.error("Observation error: \(error.localizedDescription)")
            },
            onChange: { [weak self] measurements in
                DispatchQueue.main.async {
                    self?.measurements = measurements
                }
            }
        )
    }

    // MARK: - Query

    func measurements(ofType type: MeasurementType) -> [SensorMeasurement] {
        measurements.filter { $0.type == type }
    }

    func measurement(byID id: UUID) -> SensorMeasurement? {
        measurements.first(where: { $0.id == id })
    }

    /// Fetch all DataPoints of a given type across all measurements via SQL.
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
            AppLogger.storage.error("dataPoints(for:) query failed: \(error.localizedDescription)")
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
        // Write raw data files to disk
        for raw in rawData {
            do {
                try raw.data.write(to: storageDir.appendingPathComponent(raw.filename),
                                   options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                AppLogger.storage.error("Failed to write raw data \(raw.filename): \(error.localizedDescription)")
                return false
            }
        }

        do {
            try db.dbQueue.write { db in
                // Skip if already exists
                if try MeasurementRecord.fetchOne(db, key: measurement.id.uuidString) != nil { return }

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
            // No manual array update — ValueObservation handles it
            return true
        } catch {
            AppLogger.storage.error("Failed to save measurement to DB: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func saveBatch(_ newMeasurements: [SensorMeasurement]) -> Bool {
        do {
            try db.dbQueue.write { db in
                for measurement in newMeasurements {
                    if try MeasurementRecord.fetchOne(db, key: measurement.id.uuidString) != nil { continue }

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
            return true
        } catch {
            AppLogger.storage.error("Failed to save batch to DB: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func update(_ measurement: SensorMeasurement) -> Bool {
        do {
            try db.dbQueue.write { db in
                let record = MeasurementRecord(from: measurement)
                try record.update(db)

                try db.execute(sql: "DELETE FROM measurement_source WHERE measurementId = ?",
                               arguments: [record.id])
                for source in measurement.sources {
                    let srcRecord = MeasurementSourceRecord(measurementId: record.id, from: source)
                    try srcRecord.insert(db)
                }

                try db.execute(sql: "DELETE FROM data_point WHERE measurementId = ?",
                               arguments: [record.id])
                for dp in measurement.dataPoints {
                    let dpRecord = DataPointRecord(measurementId: record.id, from: dp)
                    try dpRecord.insert(db)
                }
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to update measurement in DB: \(error.localizedDescription)")
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
            AppLogger.storage.error("Failed to append DataPoints: \(error.localizedDescription)")
            return false
        }
    }

    /// No-op — DB writes are immediate. Kept for API compatibility.
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
        guard let m = measurement(byID: id) else { return false }
        do {
            try db.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM measurement WHERE id = ?", arguments: [id.uuidString])
            }
            for file in m.rawDataFiles {
                try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(file))
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to delete measurement: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func deleteBatch(_ ids: Set<UUID>) -> Bool {
        do {
            // Collect raw files before delete
            let files = ids.compactMap { id in measurement(byID: id) }.flatMap(\.rawDataFiles)

            try db.dbQueue.write { db in
                for id in ids {
                    try db.execute(sql: "DELETE FROM measurement WHERE id = ?", arguments: [id.uuidString])
                }
            }
            for file in files {
                try? FileManager.default.removeItem(at: storageDir.appendingPathComponent(file))
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to delete batch: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - SQL Helpers

    /// Returns measurement IDs that contain at least one DataPoint of the given type in the date range.
    /// Single JOIN query — avoids N+1 per-measurement lookups.
    func measurementIDs(containingType type: String, from startDate: Date, to endDate: Date,
                        measurementType: MeasurementType? = nil) -> Set<String> {
        do {
            return try db.dbQueue.read { db in
                var sql = """
                    SELECT DISTINCT dp.measurementId FROM data_point dp
                    JOIN measurement m ON dp.measurementId = m.id
                    WHERE dp.type = ? AND m.date >= ? AND m.date <= ?
                    """
                var args: [DatabaseValueConvertible] = [type, startDate.timeIntervalSince1970, endDate.timeIntervalSince1970]
                if let mt = measurementType {
                    sql += " AND m.type = ?"
                    args.append(mt.rawValue)
                }
                let ids = try String.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return Set(ids)
            }
        } catch {
            AppLogger.storage.error("measurementIDs query failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Aggregate daily metric summaries — one row per (day, type) with count/avg/min/max.
    struct DailyMetricSummary {
        let date: Date
        let type: String
        let count: Int
        let avg: Double
        let min: Double
        let max: Double
        let unit: String
    }

    func dailyMetricSummaries() -> [DailyMetricSummary] {
        let sql = """
            SELECT
                CAST(dp.timestamp / 86400 AS INTEGER) * 86400 AS dayEpoch,
                dp.type,
                COUNT(*) AS cnt,
                AVG(dp.value) AS avgVal,
                MIN(dp.value) AS minVal,
                MAX(dp.value) AS maxVal,
                dp.unit
            FROM data_point dp
            JOIN measurement m ON dp.measurementId = m.id
            WHERE m.type = 'metric'
            GROUP BY dayEpoch, dp.type
            ORDER BY dayEpoch DESC, dp.type
            """
        do {
            return try db.dbQueue.read { db in
                try Row.fetchAll(db, sql: sql).map { row in
                    DailyMetricSummary(
                        date: Date(timeIntervalSince1970: row["dayEpoch"]),
                        type: row["type"],
                        count: row["cnt"],
                        avg: row["avgVal"],
                        min: row["minVal"],
                        max: row["maxVal"],
                        unit: row["unit"]
                    )
                }
            }
        } catch {
            AppLogger.storage.error("dailyMetricSummaries failed: \(error.localizedDescription)")
            return []
        }
    }

    /// Remove raw data files in storageDir that are not referenced by any measurement or workout.
    func cleanOrphanedRawFiles(workoutStore: WorkoutStore) {
        let dir = storageDir
        let fm = FileManager.default

        guard let allFiles = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        let rawFiles = Set(allFiles.filter { $0.hasPrefix("imu_") })
        guard !rawFiles.isEmpty else { return }

        var referencedFiles = Set<String>()
        for m in measurements {
            referencedFiles.formUnion(m.rawDataFiles)
        }
        for w in workoutStore.workouts {
            referencedFiles.formUnion(w.rawDataFiles)
        }

        let orphans = rawFiles.subtracting(referencedFiles)
        for file in orphans {
            try? fm.removeItem(at: dir.appendingPathComponent(file))
            AppLogger.storage.info("Removed orphaned raw file: \(file)")
        }
        if !orphans.isEmpty {
            AppLogger.storage.info("Cleaned \(orphans.count) orphaned raw file(s)")
        }
    }

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
