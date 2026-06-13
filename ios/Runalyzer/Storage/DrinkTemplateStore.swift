import Foundation
import Combine
import GRDB
import os

/// Reactive store for drink templates (favorites, custom drinks).
/// Auto-updates via GRDB ValueObservation when the database changes.
class DrinkTemplateStore: ObservableObject {
    @Published var templates: [DrinkTemplate] = []

    private let db: AppDatabase
    private var observation: AnyDatabaseCancellable?

    init(db: AppDatabase? = nil) {
        self.db = db ?? AppDatabase.shared
        startObservation()
    }

    // MARK: - Reactive Observation

    private func startObservation() {
        let obs = ValueObservation.tracking { db in
            try DrinkTemplateRecord
                .order(Column("sortOrder"), Column("name"))
                .fetchAll(db)
                .map { $0.toModel() }
        }
        observation = obs.start(
            in: db.dbQueue,
            scheduling: .immediate,
            onError: { error in
                AppLogger.storage.error("Drink template observation error: \(error.localizedDescription)")
            },
            onChange: { [weak self] templates in
                DispatchQueue.main.async { self?.templates = templates }
            }
        )
    }

    // MARK: - Queries

    var favorites: [DrinkTemplate] {
        templates.filter(\.isFavorite)
    }

    func templates(for category: DrinkCategory) -> [DrinkTemplate] {
        templates.filter { $0.category == category }
    }

    // MARK: - CRUD

    @discardableResult
    func save(_ template: DrinkTemplate) -> Bool {
        do {
            try db.dbQueue.write { db in
                let record = DrinkTemplateRecord(from: template)
                try record.insert(db)
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to save drink template: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func update(_ template: DrinkTemplate) -> Bool {
        do {
            try db.dbQueue.write { db in
                let record = DrinkTemplateRecord(from: template)
                try record.update(db)
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to update drink template: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func delete(_ id: UUID) -> Bool {
        do {
            try db.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM drink_template WHERE id = ?",
                               arguments: [id.uuidString])
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to delete drink template: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func toggleFavorite(_ id: UUID) -> Bool {
        do {
            try db.dbQueue.write { db in
                try db.execute(
                    sql: "UPDATE drink_template SET isFavorite = CASE WHEN isFavorite = 0 THEN 1 ELSE 0 END WHERE id = ?",
                    arguments: [id.uuidString])
            }
            return true
        } catch {
            AppLogger.storage.error("Failed to toggle favorite: \(error.localizedDescription)")
            return false
        }
    }
}
