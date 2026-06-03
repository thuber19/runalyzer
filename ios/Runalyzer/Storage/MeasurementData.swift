import Foundation

// MARK: - Data Point (universal unit of measurement)

struct DataPoint: Codable, Identifiable {
    var id: String { "\(type)-\(source)-\(timestamp.timeIntervalSince1970)" }

    let timestamp: Date
    let endTimestamp: Date?     // nil = point-in-time, set = interval
    let type: String            // "heart_rate", "cadence", "weight", "accel_x", etc.
    let value: Double
    let unit: String            // "bpm", "spm", "kg", "g", "dps", "ohm", "%", "kcal", etc.
    let source: String          // device serial or "derived:algorithm_name"

    private enum CodingKeys: String, CodingKey {
        case timestamp, endTimestamp, type, value, unit, source
    }
}

// MARK: - Measurement Source (device or algorithm that produced data)

struct MeasurementSource: Codable, Identifiable {
    var id: String { serialNumber ?? deviceName }

    let deviceType: String      // "imu_sensor", "qn_scale", "apple_watch", "algorithm"
    let deviceName: String      // user-given name: "Tobias' Runalyzer"
    let serialNumber: String?   // hardware identifier (nil for algorithms)
    let algorithmName: String?  // e.g. "body_comp_v1", "sleep_score_v1" (nil for devices)

    private enum CodingKeys: String, CodingKey {
        case deviceType, deviceName, serialNumber, algorithmName
    }

    static func device(type: String, name: String, serial: String?) -> MeasurementSource {
        MeasurementSource(deviceType: type, deviceName: name, serialNumber: serial, algorithmName: nil)
    }

    static func algorithm(name: String) -> MeasurementSource {
        MeasurementSource(deviceType: "algorithm", deviceName: name, serialNumber: nil, algorithmName: name)
    }
}

// MARK: - Measurement (one recording, one weigh-in, one derived score)

struct SensorMeasurement: Codable, Identifiable {
    static let currentVersion = 1

    let id: UUID
    let date: Date
    let type: MeasurementType
    let sources: [MeasurementSource]

    // Relationships
    var linkedMeasurements: [UUID]?     // visual fusion (e.g., IMU run + Watch workout)
    var inputMeasurements: [UUID]?      // derivation provenance

    // Sparse summary data (for display, comparison, fusion)
    var dataPoints: [DataPoint]

    // Dense raw data (stored separately for performance)
    var rawDataFiles: [String]          // filenames: "imu_samples_xxx.json", etc.

    var modelVersion: Int = Self.currentVersion

    // Convenience
    var summary: String {
        switch type {
        case .workout:
            let duration = dataPoints.first(where: { $0.type == "duration_sec" })?.value ?? 0
            let steps = dataPoints.first(where: { $0.type == "total_steps" })?.value ?? 0
            let cadence = dataPoints.first(where: { $0.type == "avg_cadence" })?.value ?? 0
            let m = Int(duration) / 60, s = Int(duration) % 60
            return String(format: "%d:%02d · %.0f steps · %.0f spm", m, s, steps, cadence)
        case .bodyComp:
            let weight = dataPoints.first(where: { $0.type == "weight" })?.value ?? 0
            let fat = dataPoints.first(where: { $0.type == "body_fat_percent" })?.value ?? 0
            return String(format: "%.1f kg · %.1f%% fat", weight, fat)
        case .derived:
            return dataPoints.first.map { "\($0.type): \($0.value)" } ?? "Derived"
        }
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var dateString: String { Self.fmt.string(from: date) }

    var sourceLabel: String {
        sources.map(\.deviceName).joined(separator: " + ")
    }

    var icon: String {
        switch type {
        case .workout: return "figure.run"
        case .bodyComp: return "scalemass"
        case .derived: return "function"
        }
    }

    init(id: UUID, date: Date, type: MeasurementType, sources: [MeasurementSource],
         dataPoints: [DataPoint], rawDataFiles: [String],
         linkedMeasurements: [UUID]? = nil, inputMeasurements: [UUID]? = nil) {
        self.id = id; self.date = date; self.type = type; self.sources = sources
        self.dataPoints = dataPoints; self.rawDataFiles = rawDataFiles
        self.linkedMeasurements = linkedMeasurements; self.inputMeasurements = inputMeasurements
        self.modelVersion = Self.currentVersion
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, type, sources, linkedMeasurements, inputMeasurements, dataPoints, rawDataFiles, modelVersion
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        date = try c.decode(Date.self, forKey: .date)
        type = try c.decode(MeasurementType.self, forKey: .type)
        sources = try c.decode([MeasurementSource].self, forKey: .sources)
        linkedMeasurements = try c.decodeIfPresent([UUID].self, forKey: .linkedMeasurements)
        inputMeasurements = try c.decodeIfPresent([UUID].self, forKey: .inputMeasurements)
        dataPoints = try c.decode([DataPoint].self, forKey: .dataPoints)
        rawDataFiles = try c.decode([String].self, forKey: .rawDataFiles)
        modelVersion = (try c.decodeIfPresent(Int.self, forKey: .modelVersion)) ?? 0
        // Future migration hooks go here: if modelVersion < X { ... }
    }
}

enum MeasurementType: String, Codable {
    case workout = "workout"
    case bodyComp = "body_comp"
    case derived = "derived"
}

// MARK: - Well-known data point types

enum DataType {
    // IMU / workout
    static let accelX = "accel_x"
    static let accelY = "accel_y"
    static let accelZ = "accel_z"
    static let gyroX = "gyro_x"
    static let gyroY = "gyro_y"
    static let gyroZ = "gyro_z"
    static let cadence = "cadence"
    static let totalSteps = "total_steps"
    static let avgCadence = "avg_cadence"
    static let peakG = "peak_g"
    static let durationSec = "duration_sec"

    // Body composition
    static let weight = "weight"
    static let impedance = "impedance"
    static let bmi = "bmi"
    static let bodyFatPercent = "body_fat_percent"
    static let fatMassKg = "fat_mass_kg"
    static let fatFreeMassKg = "fat_free_mass_kg"
    static let muscleMassKg = "muscle_mass_kg"
    static let musclePercent = "muscle_percent"
    static let bodyWaterPercent = "body_water_percent"
    static let bmrKcal = "bmr_kcal"

    // Apple Health
    static let heartRate = "heart_rate"
    static let distance = "distance"
    static let activeCalories = "active_calories"
    static let pace = "pace"

    // Derived
    static let sleepScore = "sleep_score"
}
