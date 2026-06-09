import Foundation
import GRDB
import os

/// Central database holder. Creates/opens the SQLite database and runs schema migrations.
/// Access via `AppDatabase.shared`.
final class AppDatabase {
    /// Shared singleton — initialized once at app launch.
    /// Use `nonisolated(unsafe)` to suppress Sendable warnings; access is serialized by design
    /// (set once at launch, only mutated during import with UI blocked).
    nonisolated(unsafe) private static var _shared: AppDatabase?
    private static let lock = NSLock()

    static var shared: AppDatabase {
        get {
            lock.lock()
            defer { lock.unlock() }
            guard let db = _shared else {
                fatalError("AppDatabase.shared accessed before initialization")
            }
            return db
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _shared = newValue
        }
    }

    /// Returns nil if the database has not been initialized yet.
    static var sharedIfReady: AppDatabase? {
        lock.lock()
        defer { lock.unlock() }
        return _shared
    }

    let dbQueue: DatabaseQueue

    /// Storage directory (same as the old MeasurementStore).
    static var storageDir: URL {
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("Runalyzer/Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Initialize with a specific path and optional encryption passphrase.
    /// For testing, pass ":memory:" via `inMemory()`.
    /// The passphrase used as a hex string for consistency.
    /// Using a String passphrase ensures PBKDF2 key derivation is always used,
    /// avoiding mismatches between Data (raw key) and String (derived key) modes.
    static func passphraseString(from data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    init(path: String, passphrase: Data? = nil) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        if let passphrase {
            let hexPassphrase = Self.passphraseString(from: passphrase)
            config.prepareDatabase { db in
                try db.usePassphrase(hexPassphrase)
            }
        }
        dbQueue = try DatabaseQueue(path: path, configuration: config)
        try migrator.migrate(dbQueue)
    }

    /// Convenience: open the default on-disk encrypted database.
    /// On first launch after encryption is enabled, migrates any existing
    /// unencrypted database to encrypted format.
    static func openDefault() throws -> AppDatabase {
        let dbURL = storageDir.appendingPathComponent("runalyzer.db")
        let key = Keychain.databaseKey()

        // If the DB file exists and is plaintext, encrypt it before opening.
        if FileManager.default.fileExists(atPath: dbURL.path) && isUnencryptedDatabase(at: dbURL) {
            AppLogger.storage.info("Plaintext DB detected — encrypting…")
            do {
                try encryptExistingDatabase(at: dbURL, passphrase: key)
                AppLogger.storage.info("Database encryption migration succeeded")
            } catch {
                AppLogger.storage.error("Encryption migration failed: \(error.localizedDescription)")
                // Preserve the unencrypted file and start fresh
                let backupURL = dbURL.deletingLastPathComponent()
                    .appendingPathComponent("runalyzer_pre_encrypt_\(Int(Date().timeIntervalSince1970)).db")
                try? FileManager.default.moveItem(at: dbURL, to: backupURL)
            }
        }

        return try AppDatabase(path: dbURL.path, passphrase: key)
    }

    /// Check if a database file is unencrypted by reading its header.
    /// SQLite files start with "SQLite format 3\0"; encrypted files do not.
    private static func isUnencryptedDatabase(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { handle.closeFile() }
        let header = handle.readData(ofLength: 16)
        return header.starts(with: "SQLite format 3".data(using: .utf8)!)
    }

    /// Convenience: in-memory database (for unit tests, no encryption).
    static func inMemory() throws -> AppDatabase {
        try AppDatabase(path: ":memory:")
    }

    // MARK: - Encryption Migration

    /// Encrypts an existing unencrypted database using SQLCipher's sqlcipher_export.
    /// Follows the documented GRDB pattern: open plain DB, ATTACH encrypted, export, swap.
    private static func encryptExistingDatabase(at dbURL: URL, passphrase: Data) throws {
        let fm = FileManager.default
        let encryptedURL = dbURL.deletingLastPathComponent()
            .appendingPathComponent("runalyzer_encrypted.db")
        // Clean up any leftover temp file from a failed previous attempt
        try? fm.removeItem(at: encryptedURL)

        // Open the existing unencrypted database (no passphrase = plaintext mode)
        let plainDB = try DatabaseQueue(path: dbURL.path)

        // Export from plain → encrypted using ATTACH + sqlcipher_export.
        let hexPassphrase = passphraseString(from: passphrase)
        try plainDB.inDatabase { db in
            try db.execute(
                sql: "ATTACH DATABASE ? AS encrypted KEY ?",
                arguments: [encryptedURL.path, hexPassphrase])
            try db.execute(sql: "SELECT sqlcipher_export('encrypted')")
            try db.execute(sql: "DETACH DATABASE encrypted")
        }

        // Replace the unencrypted DB with the encrypted one
        let backupURL = dbURL.deletingLastPathComponent()
            .appendingPathComponent("runalyzer_pre_encrypt.db")
        try? fm.removeItem(at: backupURL)
        try fm.moveItem(at: dbURL, to: backupURL)
        try fm.moveItem(at: encryptedURL, to: dbURL)

        // Clean up WAL/SHM and backup
        try? fm.removeItem(atPath: dbURL.path + "-wal")
        try? fm.removeItem(atPath: dbURL.path + "-shm")
        try? fm.removeItem(at: backupURL)

        AppLogger.storage.info("Database encrypted successfully")
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

        migrator.registerMigration("v2-user-profile") { db in
            try db.create(table: "user_profile") { t in
                t.primaryKey("id", .integer)          // always 1 (singleton row)
                t.column("heightCm", .double).notNull()
                t.column("age", .integer).notNull()
                t.column("sex", .text).notNull()
                t.column("maxHROverride", .integer)
                t.column("hrZone1Max", .integer)
                t.column("hrZone2Max", .integer)
                t.column("hrZone3Max", .integer)
                t.column("hrZone4Max", .integer)
            }
        }

        return migrator
    }

}
