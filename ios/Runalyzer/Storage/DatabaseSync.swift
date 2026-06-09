import Foundation
import GRDB
import os

/// Export and import the SQLite database for local-first sync.
/// The database file can be synced via rsync, HTTP, file sharing, etc.
enum DatabaseSync {

    /// Export a consistent snapshot of the encrypted database to the given URL.
    /// Uses sqlcipher_export since GRDB's backup API doesn't support encrypted databases.
    static func exportDatabase(to destinationURL: URL) throws {
        let db = AppDatabase.shared
        let key = Keychain.databaseKey()
        let hexPassphrase = AppDatabase.passphraseString(from: key)
        try db.dbQueue.inDatabase { dbConn in
            try dbConn.execute(
                sql: "ATTACH DATABASE ? AS export KEY ?",
                arguments: [destinationURL.path, hexPassphrase])
            try dbConn.execute(sql: "SELECT sqlcipher_export('export')")
            try dbConn.execute(sql: "DETACH DATABASE export")
        }
        AppLogger.storage.info("Database exported to \(destinationURL.lastPathComponent)")
    }

    /// Export to a temporary file and return its URL (for Share Sheet / UIActivityViewController).
    static func exportToTempFile() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "runalyzer_backup_\(dateStamp()).db"
        let url = tempDir.appendingPathComponent(fileName)
        // Remove old temp file if it exists
        try? FileManager.default.removeItem(at: url)
        try exportDatabase(to: url)
        return url
    }

    /// Import a database from the given URL, replacing the current database.
    /// This restarts the app's data layer — callers should reload stores after calling this.
    static func importDatabase(from sourceURL: URL) throws {
        let dbPath = AppDatabase.storageDir.appendingPathComponent("runalyzer.db")

        // Validate the source is a valid encrypted database with our schema
        let key = Keychain.databaseKey()
        let hexPassphrase = AppDatabase.passphraseString(from: key)
        var sourceConfig = Configuration()
        sourceConfig.prepareDatabase { db in
            try db.usePassphrase(hexPassphrase)
        }
        let sourceQueue = try DatabaseQueue(path: sourceURL.path, configuration: sourceConfig)
        let isValid = try sourceQueue.read { db in
            // Check required tables exist
            let tables = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type = 'table'
                """)
            guard tables.contains("measurement") && tables.contains("workout") && tables.contains("data_point") else {
                return false
            }
            // Verify key columns exist (catches schema mismatches)
            _ = try Row.fetchOne(db, sql: "SELECT id, date, type FROM measurement LIMIT 0")
            _ = try Row.fetchOne(db, sql: "SELECT id, startDate, activityType FROM workout LIMIT 0")
            // Run SQLite integrity check
            let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
            return integrity == "ok"
        }
        guard isValid else {
            throw SyncError.invalidDatabase
        }

        // Backup current DB before replacing — fail the import if backup fails
        let fm = FileManager.default
        var backupPath: URL?
        if fm.fileExists(atPath: dbPath.path) {
            let backup = AppDatabase.storageDir.appendingPathComponent(
                "runalyzer_pre_import_\(dateStamp()).db")
            try fm.moveItem(at: dbPath, to: backup)
            backupPath = backup
        }

        do {
            // Copy the new database into place
            try fm.copyItem(at: sourceURL, to: dbPath)

            // Remove stale WAL/SHM files
            try? fm.removeItem(atPath: dbPath.path + "-wal")
            try? fm.removeItem(atPath: dbPath.path + "-shm")

            // Reopen the database — the lock in AppDatabase.shared setter serializes access
            AppDatabase.shared = try AppDatabase.openDefault()
        } catch {
            // Restore backup if import failed
            if let backup = backupPath {
                try? fm.removeItem(at: dbPath)
                try? fm.moveItem(at: backup, to: dbPath)
                AppDatabase.shared = try AppDatabase.openDefault()
            }
            throw error
        }

        AppLogger.storage.info("Database imported from \(sourceURL.lastPathComponent)")
    }

    /// Get info about the current database (for display in settings).
    static func databaseInfo() -> DatabaseInfo {
        guard let db = AppDatabase.sharedIfReady else {
            return DatabaseInfo(fileSize: 0, measurementCount: 0, workoutCount: 0, dataPointCount: 0)
        }
        do {
            let dbPath = AppDatabase.storageDir.appendingPathComponent("runalyzer.db")
            let fileSize = (try? FileManager.default.attributesOfItem(atPath: dbPath.path))?[.size] as? Int64 ?? 0

            return try db.dbQueue.read { db in
                let measurements = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measurement") ?? 0
                let workouts = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workout") ?? 0
                let dataPoints = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM data_point") ?? 0
                return DatabaseInfo(fileSize: fileSize, measurementCount: measurements,
                                    workoutCount: workouts, dataPointCount: dataPoints)
            }
        } catch {
            return DatabaseInfo(fileSize: 0, measurementCount: 0, workoutCount: 0, dataPointCount: 0)
        }
    }

    // MARK: - Types

    struct DatabaseInfo {
        let fileSize: Int64
        let measurementCount: Int
        let workoutCount: Int
        let dataPointCount: Int

        var fileSizeString: String {
            ByteCountFormatter.string(fromByteCount: fileSize, countStyle: .file)
        }
    }

    enum SyncError: LocalizedError {
        case invalidDatabase

        var errorDescription: String? {
            switch self {
            case .invalidDatabase: return "The file is not a valid Runalyzer database."
            }
        }
    }

    // MARK: - Helpers

    private static let dateStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()

    private static func dateStamp() -> String {
        dateStampFormatter.string(from: Date())
    }
}
