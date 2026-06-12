import Foundation
import Combine
import HealthKit
import GRDB
import os

/// Self-contained provider for user profile data.
/// Trigger: app launch (auto-fill from HealthKit) or user edits in settings.
/// Pipeline: HealthKit characteristics → merge with manual overrides → save to DB.
class UserProfileProvider: ObservableObject {
    @Published var profile: UserProfile = .default

    private let db: AppDatabase

    /// Whether a profile record exists in the database (i.e. has been saved at least once).
    private(set) var hasStoredProfile: Bool = false

    init(db: AppDatabase? = nil) {
        self.db = db ?? AppDatabase.shared
        let loaded = loadFromDB()
        self.profile = loaded.profile
        self.hasStoredProfile = loaded.exists
    }

    // MARK: - Save

    func save(_ profile: UserProfile) {
        do {
            try db.dbQueue.write { database in
                let record = UserProfileRecord(from: profile)
                try record.save(database)
            }
            self.profile = profile
            self.hasStoredProfile = true
        } catch {
            AppLogger.storage.error("Failed to save UserProfile: \(error.localizedDescription)")
        }
    }

    // MARK: - Load

    private func loadFromDB() -> (profile: UserProfile, exists: Bool) {
        do {
            if let record = try db.dbQueue.read({ try UserProfileRecord.fetchOne($0, key: 1) }) {
                return (record.toModel(), true)
            }
        } catch {
            AppLogger.storage.error("Failed to load UserProfile: \(error.localizedDescription)")
        }
        return (.default, false)
    }

    // MARK: - HealthKit Auto-Fill

    /// Seeds the profile from HealthKit on first launch only (no saved profile yet).
    func autoFillFromHealthKit() {
        guard !hasStoredProfile else { return }
        fetchFromHealthKit()
    }

    /// Fetches biological characteristics from HealthKit and updates the profile.
    /// Called automatically on first launch, or manually via the "Fetch from Apple Health" button.
    func fetchFromHealthKit() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let store = HKHealthStore()
        var updated = profile

        // Biological sex
        if let bioSex = try? store.biologicalSex().biologicalSex,
           bioSex != .notSet {
            let sex: UserProfile.Sex = (bioSex == .female) ? .female : .male
            updated.sex = sex
        }

        // Date of birth → age
        if let dob = try? store.dateOfBirthComponents(),
           let birthDate = Calendar.current.date(from: dob) {
            let age = Calendar.current.dateComponents([.year], from: birthDate, to: Date()).year ?? 0
            if age > 0 { updated.age = age }
        }

        // Height (most recent sample)
        fetchMostRecentHeight(store: store) { heightCm in
            if let heightCm, heightCm > 0 {
                updated.heightCm = heightCm
            }
            // Save if anything changed
            if updated != self.profile {
                AppLogger.health.info("UserProfile updated from HealthKit")
                self.save(updated)
            }
        }
    }

    private func fetchMostRecentHeight(store: HKHealthStore, completion: @escaping (Double?) -> Void) {
        guard let heightType = HKQuantityType.quantityType(forIdentifier: .height) else {
            completion(nil); return
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(sampleType: heightType, predicate: nil, limit: 1,
                                  sortDescriptors: [sort]) { _, results, _ in
            let heightCm = (results as? [HKQuantitySample])?.first?
                .quantity.doubleValue(for: .meterUnit(with: .centi))
            DispatchQueue.main.async { completion(heightCm) }
        }
        store.execute(query)
    }
}
