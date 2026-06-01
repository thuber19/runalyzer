import Foundation

/// A single body composition measurement from the QN scale.
struct ScaleMeasurement: MeasurementData, Codable, Identifiable {
    let id: UUID
    let date: Date
    let deviceName: String

    // Raw readings
    let weightKg: Double
    let impedanceOhm: Double

    // Computed body composition
    let bmi: Double
    let bodyFatPercent: Double
    let fatMassKg: Double
    let fatFreeMassKg: Double
    let muscleMassKg: Double
    let musclePercent: Double
    let bodyWaterPercent: Double
    let bmrKcal: Double

    // Profile used (stored for reproducibility)
    let profile: UserProfile

    var deviceType: String { "qn_scale" }

    var summary: String {
        String(format: "%.1f kg · %.1f%% fat · %.1f kg muscle", weightKg, bodyFatPercent, muscleMassKg)
    }

    /// Create from raw reading + profile
    static func from(weightKg: Double, impedanceOhm: Double, profile: UserProfile, deviceName: String = "QN-Scale") -> ScaleMeasurement {
        let result = BodyComposition.calculate(weightKg: weightKg, impedanceOhm: impedanceOhm, profile: profile)
        return ScaleMeasurement(
            id: UUID(), date: Date(), deviceName: deviceName,
            weightKg: result.weightKg, impedanceOhm: result.impedanceOhm,
            bmi: result.bmi, bodyFatPercent: result.bodyFatPercent,
            fatMassKg: result.fatMassKg, fatFreeMassKg: result.fatFreeMassKg,
            muscleMassKg: result.muscleMassKg, musclePercent: result.musclePercent,
            bodyWaterPercent: result.bodyWaterPercent, bmrKcal: result.bmrKcal,
            profile: profile
        )
    }
}
