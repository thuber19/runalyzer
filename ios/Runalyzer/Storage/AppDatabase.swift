import Foundation
import GRDB
import os

/// Central database holder. Creates/opens the SQLite database and runs schema migrations.
/// Access via `AppDatabase.shared`.
final class AppDatabase {
    /// Shared singleton — initialized once at app launch.
    static var shared: AppDatabase!

    let dbQueue: DatabaseQueue

    /// Storage directory (same as the old MeasurementStore).
    static var storageDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Runalyzer/Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Initialize with a specific path (for testing pass ":memory:" via `inMemory()`).
    init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    /// Convenience: open the default on-disk database.
    static func openDefault() throws -> AppDatabase {
        let path = storageDir.appendingPathComponent("runalyzer.db").path
        return try AppDatabase(path: path)
    }

    /// Convenience: in-memory database (for unit tests).
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(path: ":memory:")
    }

    // MARK: - Schema Migrations

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1-initial") { db in
            // -- measurement (body_comp, derived, metric)
            try db.create(table: "measurement") { t in
                t.primaryKey("id", .text).notNull()
                t.column("date", .double).notNull()
                t.column("type", .text).notNull()
                t.column("rawDataFiles", .text).notNull().defaults(to: "[]")
                t.column("inputMeasurements", .text)
                t.column("modelVersion", .integer).notNull().defaults(to: 1)
            }
            try db.create(index: "idx_measurement_type_date",
                          on: "measurement", columns: ["type", "date"])

            // -- measurement_source
            try db.create(table: "measurement_source") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("measurement", onDelete: .cascade).notNull()
                t.column("deviceType", .text).notNull()
                t.column("deviceName", .text).notNull()
                t.column("serialNumber", .text)
                t.column("algorithmName", .text)
            }

            // -- data_point
            try db.create(table: "data_point") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("measurement", onDelete: .cascade).notNull()
                t.column("timestamp", .double).notNull()
                t.column("endTimestamp", .double)
                t.column("type", .text).notNull()
                t.column("value", .double).notNull()
                t.column("unit", .text).notNull()
                t.column("source", .text).notNull()
                t.column("role", .text).notNull().defaults(to: "primary")
            }
            try db.create(index: "idx_dp_type_timestamp",
                          on: "data_point", columns: ["type", "timestamp"])
            try db.create(index: "idx_dp_measurement",
                          on: "data_point", columns: ["measurementId"])

            // -- workout
            try db.create(table: "workout") { t in
                t.primaryKey("id", .text).notNull()
                t.column("startDate", .double).notNull()
                t.column("endDate", .double).notNull()
                t.column("activityType", .text).notNull()
                t.column("source", .text).notNull()
                t.column("durationSec", .double)
                t.column("distanceKm", .double)
                t.column("calories", .double)
                t.column("avgHR", .double)
                t.column("maxHR", .double)
                t.column("hkWorkoutId", .text)
                t.column("rawDataFiles", .text).notNull().defaults(to: "[]")
                t.column("linkedWorkoutId", .text)
            }
            try db.create(index: "idx_workout_date", on: "workout", columns: ["startDate"])
            try db.create(index: "idx_workout_hk", on: "workout", columns: ["hkWorkoutId"])

            // -- workout_data_point (workout-specific computed values)
            try db.create(table: "workout_data_point") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("workout", onDelete: .cascade).notNull()
                t.column("timestamp", .double).notNull()
                t.column("endTimestamp", .double)
                t.column("type", .text).notNull()
                t.column("value", .double).notNull()
                t.column("unit", .text).notNull()
                t.column("source", .text).notNull()
                t.column("role", .text).notNull().defaults(to: "primary")
            }
            try db.create(index: "idx_wdp_workout",
                          on: "workout_data_point", columns: ["workoutId"])
        }

        return migrator
    }

    // MARK: - JSON → SQLite Migration

    /// Migrates existing measurements.json into the SQLite database.
    /// Called once on first launch after the GRDB migration is deployed.
    /// Splits .hkWorkout/.workout into the workout table, everything else into measurement.
    func migrateFromJSONIfNeeded() {
        let jsonURL = Self.storageDir.appendingPathComponent("measurements.json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else { return }

        // Only migrate if the DB is empty
        let isEmpty: Bool
        do {
            isEmpty = try dbQueue.read { db in
                let mCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement") ?? 0
                let wCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout") ?? 0
                return mCount == 0 && wCount == 0
            }
        } catch {
            AppLogger.storage.error("Migration check failed: \(error.localizedDescription)")
            return
        }
        guard isEmpty else { return }

        // Decode the JSON
        guard let data = try? Data(contentsOf: jsonURL) else {
            AppLogger.storage.error("Cannot read measurements.json")
            return
        }
        guard let measurements = try? JSONDecoder().decode([SensorMeasurement].self, from: data) else {
            AppLogger.storage.error("Cannot decode measurements.json")
            return
        }

        AppLogger.storage.info("Migrating \(measurements.count) measurements from JSON to SQLite…")

        do {
            try dbQueue.write { db in
                for m in measurements {
                    switch m.type {
                    case .hkWorkout:
                        try Self.migrateHKWorkout(m, db: db)
                    case .workout:
                        try Self.migrateIMUWorkout(m, db: db)
                    case .metric, .derived, .bodyComp:
                        try Self.migrateMeasurement(m, db: db)
                    }
                }
            }
            AppLogger.storage.info("Migration complete")

            // Rename JSON as backup
            let backup = Self.storageDir.appendingPathComponent(
                "measurements_migrated_\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: jsonURL, to: backup)

        } catch {
            AppLogger.storage.error("Migration failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Migration Helpers

    private static func migrateMeasurement(_ m: SensorMeasurement, db: Database) throws {
        let rawFiles = (try? JSONEncoder().encode(m.rawDataFiles))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let inputMeasurements = m.inputMeasurements.flatMap { ids -> String? in
            let strs = ids.map { $0.uuidString }
            return (try? JSONEncoder().encode(strs)).flatMap { String(data: $0, encoding: .utf8) }
        }

        try db.execute(sql: """
            INSERT INTO measurement (id, date, type, rawDataFiles, inputMeasurements, modelVersion)
            VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [
                m.id.uuidString,
                m.date.timeIntervalSince1970,
                m.type.rawValue,
                rawFiles,
                inputMeasurements,
                m.modelVersion
            ])

        for source in m.sources {
            try db.execute(sql: """
                INSERT INTO measurement_source (measurementId, deviceType, deviceName, serialNumber, algorithmName)
                VALUES (?, ?, ?, ?, ?)
                """, arguments: [
                    m.id.uuidString,
                    source.deviceType,
                    source.deviceName,
                    source.serialNumber,
                    source.algorithmName
                ])
        }

        for dp in m.dataPoints {
            try db.execute(sql: """
                INSERT INTO data_point (measurementId, timestamp, endTimestamp, type, value, unit, source, role)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    m.id.uuidString,
                    dp.timestamp.timeIntervalSince1970,
                    dp.endTimestamp?.timeIntervalSince1970,
                    dp.type,
                    dp.value,
                    dp.unit,
                    dp.source,
                    dp.role.rawValue
                ])
        }
    }

    private static func migrateHKWorkout(_ m: SensorMeasurement, db: Database) throws {
        let dps = m.dataPoints
        let workoutType = dps.first(where: { $0.type == DataType.workoutType })?.unit ?? "Workout"
        let duration = dps.first(where: { $0.type == DataType.workoutDuration })?.value
        let distance = dps.first(where: { $0.type == DataType.workoutDistance })?.value
        let calories = dps.first(where: { $0.type == DataType.workoutCalories })?.value
        let avgHR = dps.first(where: { $0.type == DataType.workoutAvgHR })?.value
        let maxHR = dps.first(where: { $0.type == DataType.workoutMaxHR })?.value

        // Extract HealthKit workout UUID from sources
        let hkID = m.sources.first(where: { $0.serialNumber?.hasPrefix("hk:") == true })?
            .serialNumber.flatMap { $0.hasPrefix("hk:") ? String($0.dropFirst(3)) : nil }

        // Determine time range
        let startDate = dps.first(where: { $0.type == DataType.workoutType })?.timestamp ?? m.date
        let endDate = dps.first(where: { $0.type == DataType.workoutType })?.endTimestamp
            ?? startDate.addingTimeInterval(duration ?? 0)

        let source = dps.first?.source ?? m.sources.first?.deviceName ?? "unknown"

        try db.execute(sql: """
            INSERT INTO workout (id, startDate, endDate, activityType, source,
                                 durationSec, distanceKm, calories, avgHR, maxHR, hkWorkoutId, rawDataFiles)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '[]')
            """, arguments: [
                m.id.uuidString,
                startDate.timeIntervalSince1970,
                endDate.timeIntervalSince1970,
                workoutType,
                source,
                duration, distance, calories, avgHR, maxHR,
                hkID
            ])

        // Store workout-level summary DataPoints (type, duration, distance, etc.)
        // but NOT time-series HR/cadence/distance — those live in data_point via metric import
        let summaryTypes: Set<String> = [
            DataType.workoutType, DataType.workoutDuration, DataType.workoutDistance,
            DataType.workoutCalories, DataType.workoutAvgHR, DataType.workoutMaxHR
        ]
        for dp in dps where summaryTypes.contains(dp.type) {
            try db.execute(sql: """
                INSERT INTO workout_data_point (workoutId, timestamp, type, value, unit, source, role)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    m.id.uuidString,
                    dp.timestamp.timeIntervalSince1970,
                    dp.type, dp.value, dp.unit, dp.source, dp.role.rawValue
                ])
        }

        // Time-series DataPoints (HR samples, cadence, distance during workout) → data_point table
        // They need a measurement parent for the foreign key — create a synthetic metric measurement
        // for the workout's time range so the data_point table can reference it.
        let tsPoints = dps.filter { !summaryTypes.contains($0.type) }
        if !tsPoints.isEmpty {
            // Create a measurement to host these time-series points
            let metricID = UUID()
            try db.execute(sql: """
                INSERT INTO measurement (id, date, type, rawDataFiles, modelVersion)
                VALUES (?, ?, 'metric', '[]', 1)
                """, arguments: [metricID.uuidString, startDate.timeIntervalSince1970])

            for dp in tsPoints {
                try db.execute(sql: """
                    INSERT INTO data_point (measurementId, timestamp, endTimestamp, type, value, unit, source, role)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        metricID.uuidString,
                        dp.timestamp.timeIntervalSince1970,
                        dp.endTimestamp?.timeIntervalSince1970,
                        dp.type, dp.value, dp.unit, dp.source, dp.role.rawValue
                    ])
            }
        }
    }

    private static func migrateIMUWorkout(_ m: SensorMeasurement, db: Database) throws {
        let dps = m.dataPoints
        let duration = dps.first(where: { $0.type == DataType.durationSec })?.value
        let startDate = m.date
        let endDate = startDate.addingTimeInterval(duration ?? 0)
        let source = dps.first?.source ?? m.sources.first.map { DataSource.device($0.serialNumber ?? $0.deviceName) } ?? "unknown"

        let rawFiles = (try? JSONEncoder().encode(m.rawDataFiles))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        try db.execute(sql: """
            INSERT INTO workout (id, startDate, endDate, activityType, source,
                                 durationSec, rawDataFiles)
            VALUES (?, ?, ?, 'IMU Recording', ?, ?, ?)
            """, arguments: [
                m.id.uuidString,
                startDate.timeIntervalSince1970,
                endDate.timeIntervalSince1970,
                source,
                duration,
                rawFiles
            ])

        // All IMU DataPoints go to workout_data_point
        for dp in dps {
            try db.execute(sql: """
                INSERT INTO workout_data_point (workoutId, timestamp, endTimestamp, type, value, unit, source, role)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [
                    m.id.uuidString,
                    dp.timestamp.timeIntervalSince1970,
                    dp.endTimestamp?.timeIntervalSince1970,
                    dp.type, dp.value, dp.unit, dp.source, dp.role.rawValue
                ])
        }
    }
}
