import Foundation

/// User profile needed for body composition calculations.
struct UserProfile: Codable, Equatable {
    var heightCm: Double
    var age: Int
    var sex: Sex

    // HR Zone boundaries (bpm). Nil = auto-calculated from age (220 - age).
    var hrZone1Max: Int?  // below this = Zone 1
    var hrZone2Max: Int?  // Zone 1 max .. Zone 2 max = Zone 2
    var hrZone3Max: Int?
    var hrZone4Max: Int?
    // Zone 5 = above Zone 4 max

    enum Sex: String, Codable, CaseIterable {
        case male, female

        var label: String {
            switch self {
            case .male: return "Male"
            case .female: return "Female"
            }
        }

        var numericValue: Double { self == .male ? 1.0 : 0.0 }
    }

    static let `default` = UserProfile(heightCm: 175, age: 30, sex: .male)

    /// Custom max HR override. Nil = auto-calculated (220 - age).
    var maxHROverride: Int?

    /// Max heart rate — uses custom value if set, otherwise 220 - age.
    var maxHR: Int { maxHROverride ?? (220 - age) }

    /// HR zone boundaries in bpm.
    /// Defaults: Karvonen zones at 50/60/70/80/90% of max HR.
    /// Reference: American College of Sports Medicine (ACSM) Guidelines for
    /// Exercise Testing and Prescription, 11th ed., 2021.
    var hrZones: [(name: String, maxBPM: Int, color: String)] {
        let mhr = maxHR
        return [
            ("Zone 1", hrZone1Max ?? Int(Double(mhr) * 0.6), "gray"),      // 50–60% Very Light
            ("Zone 2", hrZone2Max ?? Int(Double(mhr) * 0.7), "blue"),      // 60–70% Light
            ("Zone 3", hrZone3Max ?? Int(Double(mhr) * 0.8), "green"),     // 70–80% Moderate
            ("Zone 4", hrZone4Max ?? Int(Double(mhr) * 0.9), "orange"),    // 80–90% Hard
            ("Zone 5", mhr, "red"),                                         // 90–100% Maximum
        ]
    }

    /// Zone lower bounds for display
    var hrZoneLowerBounds: [Int] {
        let mhr = maxHR
        return [
            Int(Double(mhr) * 0.5),  // Zone 1 starts at 50%
            hrZone1Max ?? Int(Double(mhr) * 0.6),  // Zone 2 starts
            hrZone2Max ?? Int(Double(mhr) * 0.7),  // Zone 3 starts
            hrZone3Max ?? Int(Double(mhr) * 0.8),  // Zone 4 starts
            hrZone4Max ?? Int(Double(mhr) * 0.9),  // Zone 5 starts
        ]
    }

    private static let keychainKey = "user_profile"
    private static let legacyDefaultsKey = "runalyzer_user_profile"  // migration only

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            Keychain.save(data, key: Self.keychainKey)
        }
    }

    static func load() -> UserProfile {
        // One-time migration from UserDefaults → Keychain
        if Keychain.load(key: keychainKey) == nil,
           let legacyData = UserDefaults.standard.data(forKey: legacyDefaultsKey) {
            Keychain.save(legacyData, key: keychainKey)
            UserDefaults.standard.removeObject(forKey: legacyDefaultsKey)
        }

        guard let data = Keychain.load(key: keychainKey),
              let profile = try? JSONDecoder().decode(UserProfile.self, from: data) else {
            return .default
        }
        return profile
    }
}

/// Body composition results calculated from weight + bioimpedance + profile.
/// Equations from published BIA literature:
///   FFM: Sun et al., Am J Clin Nutr 2003;77:331-40
///   TBW: Sun et al., 2003
///   SMM: Janssen et al., J Appl Physiol 2000;89:465-71
///   BMR: Mifflin-St Jeor, Am J Clin Nutr 1990;51:241-7
struct BodyCompositionResult {
    let weightKg: Double
    let bmi: Double
    let bodyFatPercent: Double
    let fatMassKg: Double
    let fatFreeMassKg: Double
    let muscleMassKg: Double
    let musclePercent: Double
    let bodyWaterPercent: Double
    let bmrKcal: Double
    let impedanceOhm: Double
}

enum BodyComposition {
    /// Calculate body composition from weight, impedance, and user profile.
    /// R = measured resistance (ohms), uses scale's impedance value directly.
    static func calculate(weightKg: Double, impedanceOhm R: Double, profile: UserProfile) -> BodyCompositionResult {
        let height = profile.heightCm
        let age = Double(profile.age)
        let sex = profile.sex.numericValue  // male=1, female=0
        let weight = weightKg

        let hi2_r = (height * height) / R  // resistance index (cm²/Ω)

        // Fat-free mass — Sun et al. 2003
        let ffm: Double
        let tbw: Double
        if sex == 1 {
            ffm = -10.68 + 0.65 * hi2_r + 0.26 * weight + 0.02 * R
            tbw = 1.20 + 0.45 * hi2_r + 0.18 * weight
        } else {
            ffm = -9.53 + 0.69 * hi2_r + 0.17 * weight + 0.02 * R
            tbw = 3.75 + 0.45 * hi2_r + 0.11 * weight
        }

        let fatMass = max(weight - ffm, 0)
        let fatPct = weight > 0 ? 100.0 * fatMass / weight : 0

        // Skeletal muscle mass — Janssen et al. 2000 (appendicular)
        let smmAppendicular = 0.401 * hi2_r + 3.825 * sex - 0.071 * age + 5.102
        // Total skeletal muscle ≈ appendicular × 1.33 (Lee et al. 2000 correction)
        // Consumer scales typically report total muscle closer to FFM × 0.9
        let smm = max(smmAppendicular * 1.33, ffm * 0.85)
        let smmPct = weight > 0 ? 100.0 * smm / weight : 0

        let tbwPct = weight > 0 ? 100.0 * tbw / weight : 0

        // BMI
        let heightM = height / 100.0
        let bmi = heightM > 0 ? weight / (heightM * heightM) : 0

        // BMR — Mifflin-St Jeor
        let bmr: Double
        if sex == 1 {
            bmr = 10 * weight + 6.25 * height - 5 * age + 5
        } else {
            bmr = 10 * weight + 6.25 * height - 5 * age - 161
        }

        return BodyCompositionResult(
            weightKg: round(weight * 100) / 100,
            bmi: round(bmi * 100) / 100,
            bodyFatPercent: round(fatPct * 100) / 100,
            fatMassKg: round(fatMass * 100) / 100,
            fatFreeMassKg: round(ffm * 100) / 100,
            muscleMassKg: round(smm * 100) / 100,
            musclePercent: round(smmPct * 100) / 100,
            bodyWaterPercent: round(tbwPct * 100) / 100,
            bmrKcal: round(bmr),
            impedanceOhm: round(R)
        )
    }
}
