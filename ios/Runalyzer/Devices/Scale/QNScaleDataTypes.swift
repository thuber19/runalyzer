import Foundation

/// A single body composition measurement from the QN scale.
struct ScaleMeasurement: Codable, Identifiable {
    let id: UUID
    let date: Date
    let deviceName: String

    // Raw readings
    let weightKg: Double
    let impedanceOhm: Double
    let hasImpedance: Bool

    // Computed body composition (nil if no impedance)
    let bmi: Double
    let bodyFatPercent: Double?
    let fatMassKg: Double?
    let fatFreeMassKg: Double?
    let muscleMassKg: Double?
    let musclePercent: Double?
    let bodyWaterPercent: Double?
    let bmrKcal: Double?

    // Profile used (stored for reproducibility)
    let profile: UserProfile

    /// Create from raw reading + profile.
    /// If hasImpedance is false, body composition fields are set to 0 (weight-only measurement).
    static func from(weightKg: Double, impedanceOhm: Double, hasImpedance: Bool = true,
                     profile: UserProfile, deviceName: String = "QN-Scale") -> ScaleMeasurement {
        let heightM = profile.heightCm / 100.0
        let bmi = heightM > 0 ? weightKg / (heightM * heightM) : 0

        if hasImpedance && impedanceOhm > 0 {
            let r = BodyComposition.calculate(weightKg: weightKg, impedanceOhm: impedanceOhm, profile: profile)
            return ScaleMeasurement(
                id: UUID(), date: Date(), deviceName: deviceName,
                weightKg: r.weightKg, impedanceOhm: r.impedanceOhm, hasImpedance: true,
                bmi: r.bmi, bodyFatPercent: r.bodyFatPercent,
                fatMassKg: r.fatMassKg, fatFreeMassKg: r.fatFreeMassKg,
                muscleMassKg: r.muscleMassKg, musclePercent: r.musclePercent,
                bodyWaterPercent: r.bodyWaterPercent, bmrKcal: r.bmrKcal,
                profile: profile
            )
        } else {
            return ScaleMeasurement(
                id: UUID(), date: Date(), deviceName: deviceName,
                weightKg: round(weightKg * 100) / 100, impedanceOhm: 0, hasImpedance: false,
                bmi: round(bmi * 10) / 10, bodyFatPercent: nil,
                fatMassKg: nil, fatFreeMassKg: nil,
                muscleMassKg: nil, musclePercent: nil,
                bodyWaterPercent: nil, bmrKcal: nil,
                profile: profile
            )
        }
    }
}
