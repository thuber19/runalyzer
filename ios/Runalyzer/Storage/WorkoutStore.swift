import Foundation
import Combine
import GRDB
import os

/// Storage for workout entities. Backed by GRDB/SQLite.
/// Workouts are lightweight summary rows; time-series data (HR, cadence)
/// is queried from the shared `data_point` table by time window.
class WorkoutStore: ObservableObject {
    @Published var workouts: [Workout] = []

    private let db: AppDatabase

    init(db: AppDatabase? = nil) {
        self.db = db ?? AppDatabase.shared
        loadWorkouts()
    }

    private func loadWorkouts() {
        do {
            workouts = try db.dbQueue.read { db in
                try WorkoutRecord
                    .order(Column("startDate").desc)
                    .fetchAll(db)
                    .map { $0.toModel() }
            }
        } catch {
            AppLogger.storage.error("Failed to load workouts: \(error.localizedDescription)")
            workouts = []
        }
    }

    // MARK: - Query

    func workout(byID id: UUID) -> Workout? {
        workouts.first(where: { $0.id == id })
    }

    /// Workouts within a date range.
    func workouts(from startDate: Date, to endDate: Date) -> [Workout] {
        workouts.filter { $0.startDate >= startDate && $0.startDate <= endDate }
    }

    /// Check if a HealthKit workout ID already exists (dedup).
    func hasWorkout(hkID: String) -> Bool {
        do {
            return try db.dbQueue.read { db in
                try WorkoutRecord
                    .filter(Column("hkWorkoutId") == hkID)
                    .fetchCount(db) > 0
            }
        } catch { return false }
    }

    /// All existing HealthKit workout IDs (for batch dedup during import).
    func existingHKWorkoutIDs() -> Set<String> {
        do {
            return try db.dbQueue.read { db in
                let ids = try String.fetchAll(db, sql: """
                    SELECT hkWorkoutId FROM workout WHERE hkWorkoutId IS NOT NULL
                    """)
                return Set(ids)
            }
        } catch { return [] }
    }

    // MARK: - DataPoints (shared time-series via time window)

    /// Fetch DataPoints from the shared `data_point` table that fall within this workout's time range.
    /// This is the key relationship: workouts reference data by time window, not by foreign key.
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

    /// Fetch workout-specific DataPoints (e.g., IMU cadence windows, peak G).
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
        assert(Thread.isMainThread, "WorkoutStore.save must be called on main thread")
        if workouts.contains(where: { $0.id == workout.id }) { return true }

        do {
            try db.dbQueue.write { db in
                let record = WorkoutRecord(from: workout)
                try record.insert(db)

                for dp in dataPoints {
                    let wdpRecord = WorkoutDataPointRecord(workoutId: record.id, from: dp)
                    try wdpRecord.insert(db)
                }
            }
            workouts.insert(workout, at: 0)
            return true
        } catch {
            print("Failed to save workout: \(error)")
            return false
        }
    }

    @discardableResult
    func saveBatch(_ newWorkouts: [(workout: Workout, dataPoints: [DataPoint])]) -> Bool {
        assert(Thread.isMainThread, "WorkoutStore.saveBatch must be called on main thread")
        let toInsert = newWorkouts.filter { w in
            !workouts.contains(where: { $0.id == w.workout.id })
        }
        guard !toInsert.isEmpty else { return true }

        do {
            try db.dbQueue.write { db in
                for (workout, dataPoints) in toInsert {
                    let record = WorkoutRecord(from: workout)
                    try record.insert(db)

                    for dp in dataPoints {
                        let wdpRecord = WorkoutDataPointRecord(workoutId: record.id, from: dp)
                        try wdpRecord.insert(db)
                    }
                }
            }
            for (workout, _) in toInsert {
                workouts.insert(workout, at: 0)
            }
            return true
        } catch {
            print("Failed to save workout batch: \(error)")
            return false
        }
    }

    // MARK: - Delete

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        assert(Thread.isMainThread, "WorkoutStore.delete must be called on main thread")
        do {
            try db.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM workout WHERE id = ?", arguments: [id.uuidString])
            }
            if let idx = workouts.firstIndex(where: { $0.id == id }) {
                let w = workouts[idx]
                for file in w.rawDataFiles {
                    try? FileManager.default.removeItem(
                        at: AppDatabase.storageDir.appendingPathComponent(file))
                }
                workouts.remove(at: idx)
            }
            return true
        } catch {
            print("Failed to delete workout: \(error)")
            return false
        }
    }

    @discardableResult
    func deleteBatch(_ ids: Set<UUID>) -> Bool {
        assert(Thread.isMainThread, "WorkoutStore.deleteBatch must be called on main thread")
        do {
            try db.dbQueue.write { db in
                for id in ids {
                    try db.execute(sql: "DELETE FROM workout WHERE id = ?", arguments: [id.uuidString])
                }
            }
            for id in ids {
                if let idx = workouts.firstIndex(where: { $0.id == id }) {
                    let w = workouts[idx]
                    for file in w.rawDataFiles {
                        try? FileManager.default.removeItem(
                            at: AppDatabase.storageDir.appendingPathComponent(file))
                    }
                    workouts.remove(at: idx)
                }
            }
            return true
        } catch {
            print("Failed to delete workout batch: \(error)")
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
            if let idx1 = workouts.firstIndex(where: { $0.id == id1 }) {
                workouts[idx1].linkedWorkoutId = id2
            }
            if let idx2 = workouts.firstIndex(where: { $0.id == id2 }) {
                workouts[idx2].linkedWorkoutId = id1
            }
            return true
        } catch { return false }
    }
}
