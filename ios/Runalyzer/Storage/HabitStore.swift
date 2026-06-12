import Foundation
import Combine
import GRDB
import os

/// Reactive store for habits and their daily logs.
/// Auto-updates via GRDB ValueObservation when the database changes.
class HabitStore: ObservableObject {
    @Published var habits: [Habit] = []
    @Published var todayLogs: [HabitLog] = []

    private let db: AppDatabase
    private var habitObservation: AnyDatabaseCancellable?
    private var logObservation: AnyDatabaseCancellable?

    init(db: AppDatabase? = nil) {
        self.db = db ?? AppDatabase.shared
        startObservation()
    }

    // MARK: - Reactive Observation

    private func startObservation() {
        // Observe active habits
        let habitObs = ValueObservation.tracking { db in
            try HabitRecord
                .filter(Column("archivedAt") == nil)
                .order(Column("sortOrder"), Column("createdAt"))
                .fetchAll(db)
                .map { $0.toModel() }
        }
        habitObservation = habitObs.start(
            in: db.dbQueue,
            scheduling: .immediate,
            onError: { error in
                AppLogger.storage.error("Habit observation error: \(error.localizedDescription)")
            },
            onChange: { [weak self] habits in
                DispatchQueue.main.async { self?.habits = habits }
            }
        )

        // Observe today's logs
        let todayStart = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        let logObs = ValueObservation.tracking { db in
            try HabitLogRecord
                .filter(Column("date") == todayStart)
                .fetchAll(db)
                .map { $0.toModel() }
        }
        logObservation = logObs.start(
            in: db.dbQueue,
            scheduling: .immediate,
            onError: { error in
                AppLogger.storage.error("Habit log observation error: \(error.localizedDescription)")
            },
            onChange: { [weak self] logs in
                DispatchQueue.main.async { self?.todayLogs = logs }
            }
        )
    }

    // MARK: - Habit CRUD

    @discardableResult
    func save(_ habit: Habit) -> Bool {
        do {
            try db.dbQueue.write { db in
                let record = HabitRecord(from: habit)
                try record.insert(db)
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to save habit: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func update(_ habit: Habit) -> Bool {
        do {
            try db.dbQueue.write { db in
                let record = HabitRecord(from: habit)
                try record.update(db)
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to update habit: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func archive(_ id: UUID) -> Bool {
        do {
            try db.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE habit SET archivedAt = ? WHERE id = ?",
                    arguments: [Date().timeIntervalSince1970, id.uuidString])
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to archive habit: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        do {
            try db.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM habit WHERE id = ?", arguments: [id.uuidString])
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to delete habit: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Log Operations

    /// Toggle completion for a habit on a given date.
    /// Creates a log entry if none exists, or toggles completedAt.
    @discardableResult
    func toggleCompletion(habitId: UUID, date: Date = Date()) -> Bool {
        let dayStart = Calendar.current.startOfDay(for: date).timeIntervalSince1970
        do {
            try db.dbQueue.write { db in
                if let existing = try HabitLogRecord
                    .filter(Column("habitId") == habitId.uuidString && Column("date") == dayStart)
                    .fetchOne(db) {
                    // Toggle: if completed and not auto-fulfilled, clear it; otherwise set it
                    if existing.completedAt != nil && existing.autoFulfilled == 0 {
                        try db.execute(
                            sql: "UPDATE habit_log SET completedAt = NULL WHERE id = ?",
                            arguments: [existing.id])
                    } else if existing.completedAt == nil {
                        try db.execute(
                            sql: "UPDATE habit_log SET completedAt = ? WHERE id = ?",
                            arguments: [Date().timeIntervalSince1970, existing.id])
                    }
                } else {
                    // Create new log entry as completed
                    try db.execute(
                        sql: "INSERT INTO habit_log (habitId, date, completedAt, autoFulfilled, source) VALUES (?, ?, ?, 0, 'manual')",
                        arguments: [habitId.uuidString, dayStart, Date().timeIntervalSince1970])
                }
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to toggle habit: \(error.localizedDescription)")
            return false
        }
    }

    /// Mark a habit as auto-fulfilled by a workout.
    @discardableResult
    func markAutoFulfilled(habitId: UUID, date: Date, workoutId: UUID) -> Bool {
        let dayStart = Calendar.current.startOfDay(for: date).timeIntervalSince1970
        do {
            try db.dbQueue.write { db in
                if let existing = try HabitLogRecord
                    .filter(Column("habitId") == habitId.uuidString && Column("date") == dayStart)
                    .fetchOne(db) {
                    if existing.completedAt == nil {
                        try db.execute(
                            sql: "UPDATE habit_log SET completedAt = ?, autoFulfilled = 1, workoutId = ?, source = 'auto' WHERE id = ?",
                            arguments: [Date().timeIntervalSince1970, workoutId.uuidString, existing.id])
                    }
                } else {
                    try db.execute(
                        sql: "INSERT INTO habit_log (habitId, date, completedAt, autoFulfilled, workoutId, source) VALUES (?, ?, ?, 1, ?, 'auto')",
                        arguments: [habitId.uuidString, dayStart, Date().timeIntervalSince1970, workoutId.uuidString])
                }
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to auto-fulfill habit: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Queries

    /// Fetch logs for a specific habit in a date range.
    func logs(for habitId: UUID, from startDate: Date, to endDate: Date) -> [HabitLog] {
        do {
            return try db.dbQueue.read { db in
                try HabitLogRecord
                    .filter(Column("habitId") == habitId.uuidString)
                    .filter(Column("date") >= startDate.timeIntervalSince1970)
                    .filter(Column("date") <= endDate.timeIntervalSince1970)
                    .order(Column("date"))
                    .fetchAll(db)
                    .map { $0.toModel() }
            }
        } catch {
            AppLogger.storage.error("Failed to fetch habit logs: \(error.localizedDescription)")
            return []
        }
    }

    /// Fetch all logs in a date range (for batch streak computation).
    func allLogs(from startDate: Date, to endDate: Date) -> [HabitLog] {
        do {
            return try db.dbQueue.read { db in
                try HabitLogRecord
                    .filter(Column("date") >= startDate.timeIntervalSince1970)
                    .filter(Column("date") <= endDate.timeIntervalSince1970)
                    .order(Column("date"))
                    .fetchAll(db)
                    .map { $0.toModel() }
            }
        } catch {
            AppLogger.storage.error("Failed to fetch all habit logs: \(error.localizedDescription)")
            return []
        }
    }

    /// Check if a habit is completed on a specific date.
    func isCompleted(habitId: UUID, on date: Date) -> Bool {
        todayLogs.first(where: { $0.habitId == habitId })?.isCompleted ?? false
    }
}
