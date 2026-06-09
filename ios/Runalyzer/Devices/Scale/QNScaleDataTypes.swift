import Foundation

/// Raw reading from the BLE scale — just weight and impedance, no calculations.
/// The provider handles profile lookup and body composition algorithms.
struct ScaleReading {
    let weightKg: Double
    let impedanceOhm: Double
    let hasImpedance: Bool
    let deviceName: String
}

/// A complete body composition measurement (built by ScaleMeasurementProvider).
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
}
