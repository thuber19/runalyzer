import Foundation

/// User profile for body composition calculations and HR zone configuration.
struct UserProfile: Codable, Equatable {
    var heightCm: Double
    var age: Int
    var sex: Sex

    // HR Zone boundaries (bpm). Nil = auto-calculated from age (220 - age).
    var hrZone1Max: Int?
    var hrZone2Max: Int?
    var hrZone3Max: Int?
    var hrZone4Max: Int?

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
            ("Zone 1", hrZone1Max ?? Int(Double(mhr) * 0.6), "gray"),
            ("Zone 2", hrZone2Max ?? Int(Double(mhr) * 0.7), "blue"),
            ("Zone 3", hrZone3Max ?? Int(Double(mhr) * 0.8), "green"),
            ("Zone 4", hrZone4Max ?? Int(Double(mhr) * 0.9), "orange"),
            ("Zone 5", mhr, "red"),
        ]
    }

    /// Zone lower bounds for display
    var hrZoneLowerBounds: [Int] {
        let mhr = maxHR
        return [
            Int(Double(mhr) * 0.5),
            hrZone1Max ?? Int(Double(mhr) * 0.6),
            hrZone2Max ?? Int(Double(mhr) * 0.7),
            hrZone3Max ?? Int(Double(mhr) * 0.8),
            hrZone4Max ?? Int(Double(mhr) * 0.9),
        ]
    }
}
