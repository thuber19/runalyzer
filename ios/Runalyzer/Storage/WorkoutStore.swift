import Foundation
import Combine
import GRDB
import os

/// Storage for workout entities. Backed by GRDB/SQLite.
/// Auto-updates via ValueObservation when the database changes.
class WorkoutStore: ObservableObject {
    @Published var workouts: [Workout] = []

    private let db: AppDatabase
    private var observationCancellable: AnyDatabaseCancellable?

    init(db: AppDatabase? = nil) {
        self.db = db ?? AppDatabase.shared
        startObservation()
    }

    // MARK: - Reactive Observation

    private func startObservation() {
        let observation = ValueObservation.tracking { db in
            try WorkoutRecord
                .order(Column("startDate").desc)
                .fetchAll(db)
                .map { $0.toModel() }
        }

        observationCancellable = observation.start(
            in: db.dbQueue,
            scheduling: .immediate,
            onError: { error in
                AppLogger.storage.error("Workout observation error: \(error.localizedDescription)")
            },
            onChange: { [weak self] workouts in
                DispatchQueue.main.async {
                    self?.workouts = workouts
                }
            }
        )
    }

    // MARK: - Query

    func workout(byID id: UUID) -> Workout? {
        workouts.first(where: { $0.id == id })
    }

    func workouts(from startDate: Date, to endDate: Date) -> [Workout] {
        workouts.filter { $0.startDate >= startDate && $0.startDate <= endDate }
    }

    func hasWorkout(hkID: String) -> Bool {
        do {
            return try db.dbQueue.read { db in
                try WorkoutRecord
                    .filter(Column("hkWorkoutId") == hkID)
                    .fetchCount(db) > 0
            }
        } catch {
            AppLogger.storage.error("hasWorkout query failed: \(error.localizedDescription)")
            return false
        }
    }

    func existingHKWorkoutIDs() -> Set<String> {
        do {
            return try db.dbQueue.read { db in
                let ids = try String.fetchAll(db, sql: """
                    SELECT hkWorkoutId FROM workout WHERE hkWorkoutId IS NOT NULL
                    """)
                return Set(ids)
            }
        } catch {
            AppLogger.storage.error("existingHKWorkoutIDs query failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Shared DataPoints (time window queries)

    func sharedDataPoints(for workout: Workout, type: String? = nil) -> [DataPoint] {
        do {
            return try db.dbQueue.read { db in
                var sql = """
                    SELECT * FROM data_point
                    WHERE timestamp >= ? AND timestamp <= ?
                    """
                var args: [DatabaseValueConvertible?] = [
                    workout.startDate.timeIntervalSince1970,
                    workout.endDate.timeIntervalSince1970
                ]
                if let type {
                    sql += " AND type = ?"
                    args.append(type)
                }
                sql += " ORDER BY timestamp"
                return try DataPointRecord
                    .fetchAll(db, sql: sql, arguments: StatementArguments(args))
                    .map { $0.toModel() }
            }
        } catch { return [] }
    }

    func workoutDataPoints(for workout: Workout) -> [DataPoint] {
        do {
            return try db.dbQueue.read { db in
                try WorkoutDataPointRecord
                    .filter(Column("workoutId") == workout.id.uuidString)
                    .order(Column("timestamp"))
                    .fetchAll(db)
                    .map { $0.toModel() }
            }
        } catch { return [] }
    }

    // MARK: - Save

    @discardableResult
    func save(_ workout: Workout, dataPoints: [DataPoint] = []) -> Bool {
        do {
            try db.dbQueue.write { db in
                if try WorkoutRecord.fetchOne(db, key: workout.id.uuidString) != nil { return }

                let record = WorkoutRecord(from: workout)
                try record.insert(db)

                for dp in dataPoints {
                    let wdpRecord = WorkoutDataPointRecord(workoutId: record.id, from: dp)
                    try wdpRecord.insert(db)
                }
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to save workout: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func saveBatch(_ newWorkouts: [(workout: Workout, dataPoints: [DataPoint])]) -> Bool {
        do {
            try db.dbQueue.write { db in
                for (workout, dataPoints) in newWorkouts {
                    if try WorkoutRecord.fetchOne(db, key: workout.id.uuidString) != nil { continue }

                    let record = WorkoutRecord(from: workout)
                    try record.insert(db)

                    for dp in dataPoints {
                        let wdpRecord = WorkoutDataPointRecord(workoutId: record.id, from: dp)
                        try wdpRecord.insert(db)
                    }
                }
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to save workout batch: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Delete

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        do {
            let files = workout(byID: id)?.rawDataFiles ?? []
            try db.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM workout WHERE id = ?", arguments: [id.uuidString])
            }
            for file in files {
                try? FileManager.default.removeItem(at: AppDatabase.storageDir.appendingPathComponent(file))
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to delete workout: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func deleteBatch(_ ids: Set<UUID>) -> Bool {
        do {
            let files = ids.compactMap { workout(byID: $0) }.flatMap(\.rawDataFiles)
            try db.dbQueue.write { db in
                for id in ids {
                    try db.execute(sql: "DELETE FROM workout WHERE id = ?", arguments: [id.uuidString])
                }
            }
            for file in files {
                try? FileManager.default.removeItem(at: AppDatabase.storageDir.appendingPathComponent(file))
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to delete workout batch: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Link

    @discardableResult
    func linkWorkouts(_ id1: UUID, with id2: UUID) -> Bool {
        do {
            try db.dbQueue.write { db in
                try db.execute(sql: "UPDATE workout SET linkedWorkoutId = ? WHERE id = ?",
                               arguments: [id2.uuidString, id1.uuidString])
                try db.execute(sql: "UPDATE workout SET linkedWorkoutId = ? WHERE id = ?",
                               arguments: [id1.uuidString, id2.uuidString])
            }
            return true
        } catch { return false }
    }
}
