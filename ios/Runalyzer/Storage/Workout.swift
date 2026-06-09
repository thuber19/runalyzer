import Foundation

/// First-class workout entity. Represents a time-bounded activity session
/// (running, cycling, strength, IMU recording, etc.).
///
/// Workouts reference shared DataPoints by time window — HR/cadence/distance
/// data during the workout lives in the `data_point` table and is queried
/// by `startDate`…`endDate`, avoiding duplication.
///
/// Workout-specific computed values (IMU peak G, avg cadence) are stored
/// in the `workout_data_point` table.
struct Workout: Identifiable, Sendable {
    let id: UUID
    let startDate: Date
    let endDate: Date
    let activityType: String        // "Run", "Cycle", "HIIT", "Strength", "IMU Recording", etc.
    let source: String              // "hk:Apple Watch", "device:<UUID>"

    // Summary stats (always loaded — lightweight)
    var durationSec: Double?
    var distanceKm: Double?
    var calories: Double?
    var avgHR: Double?
    var maxHR: Double?

    // Provenance
    var hkWorkoutId: UUID?          // HealthKit workout UUID for dedup
    var rawDataFiles: [String]      // IMU raw sample files
    var linkedWorkoutId: UUID?      // companion workout (IMU ↔ Watch)

    // MARK: - Display helpers

    var dateString: String { DateFormatters.mediumDateTime.string(from: startDate) }

    var durationString: String {
        guard let dur = durationSec else { return "--" }
        let total = Int(dur)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }

    var summary: String {
        var parts = [activityType, durationString]
        if let d = distanceKm, d > 0.01 { parts.append(String(format: "%.2f km", d)) }
        if let hr = avgHR, hr > 0 { parts.append(String(format: "%.0f bpm", hr)) }
        return parts.joined(separator: " · ")
    }

    var icon: String {
        switch activityType {
        case "Run":              return "figure.run"
        case "Walk":             return "figure.walk"
        case "Cycle":            return "figure.outdoor.cycle"
        case "Hike":             return "figure.hiking"
        case "Swim":             return "figure.pool.swim"
        case "Strength", "Weight Training": return "dumbbell"
        case "HIIT":             return "flame"
        case "Yoga":             return "figure.yoga"
        case "IMU Recording":    return "sensor"
        default:                 return "heart.circle"
        }
    }
}
