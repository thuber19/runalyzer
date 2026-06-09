import Foundation
import GRDB
import os

// MARK: - Measurement Record

struct MeasurementRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "measurement"

    var id: String
    var date: Double                    // timeIntervalSince1970
    var type: String
    var rawDataFiles: String            // JSON array
    var inputMeasurements: String?      // JSON array of UUID strings
    var modelVersion: Int

    // MARK: - Mapping to/from domain model

    init(from model: SensorMeasurement) {
        self.id = model.id.uuidString
        self.date = model.date.timeIntervalSince1970
        self.type = model.type.rawValue
        self.rawDataFiles = Self.encodeJSON(model.rawDataFiles)
        self.inputMeasurements = model.inputMeasurements.map { Self.encodeJSON($0.map(\.uuidString)) }
        self.modelVersion = model.modelVersion
    }

    func toModel(sources: [MeasurementSource] = [], dataPoints: [DataPoint] = []) -> SensorMeasurement {
        if UUID(uuidString: id) == nil {
            AppLogger.storage.error("Corrupt measurement UUID: \(id) — generating replacement")
        }
        return SensorMeasurement(
            id: UUID(uuidString: id) ?? UUID(),
            date: Date(timeIntervalSince1970: date),
            type: MeasurementType(rawValue: type) ?? .metric,
            sources: sources,
            dataPoints: dataPoints,
            rawDataFiles: (Self.decodeJSON(rawDataFiles) as [String]?) ?? [],
            inputMeasurements: inputMeasurements.flatMap { (Self.decodeJSON($0) as [String]?) }?.compactMap { UUID(uuidString: $0) }
        )
    }

    static func encodeJSON<T: Encodable>(_ value: T) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decodeJSON<T: Decodable>(_ json: String) -> T? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Measurement Source Record

struct MeasurementSourceRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "measurement_source"

    var id: Int64?
    var measurementId: String
    var deviceType: String
    var deviceName: String
    var serialNumber: String?
    var algorithmName: String?

    init(measurementId: String, from model: MeasurementSource) {
        self.measurementId = measurementId
        self.deviceType = model.deviceType
        self.deviceName = model.deviceName
        self.serialNumber = model.serialNumber
        self.algorithmName = model.algorithmName
    }

    func toModel() -> MeasurementSource {
        MeasurementSource(
            deviceType: deviceType,
            deviceName: deviceName,
            serialNumber: serialNumber,
            algorithmName: algorithmName
        )
    }
}

// MARK: - Data Point Record

struct DataPointRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "data_point"

    var id: Int64?
    var measurementId: String
    var timestamp: Double
    var endTimestamp: Double?
    var type: String
    var value: Double
    var unit: String
    var source: String
    var role: String

    init(measurementId: String, from model: DataPoint) {
        self.measurementId = measurementId
        self.timestamp = model.timestamp.timeIntervalSince1970
        self.endTimestamp = model.endTimestamp?.timeIntervalSince1970
        self.type = model.type
        self.value = model.value
        self.unit = model.unit
        self.source = model.source
        self.role = model.role.rawValue
    }

    func toModel() -> DataPoint {
        DataPoint(
            timestamp: Date(timeIntervalSince1970: timestamp),
            endTimestamp: endTimestamp.map { Date(timeIntervalSince1970: $0) },
            type: type,
            value: value,
            unit: unit,
            source: source,
            role: DataPointRole(rawValue: role) ?? .primary
        )
    }
}

// MARK: - Workout Record

struct WorkoutRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workout"

    var id: String
    var startDate: Double
    var endDate: Double
    var activityType: String
    var source: String
    var durationSec: Double?
    var distanceKm: Double?
    var calories: Double?
    var avgHR: Double?
    var maxHR: Double?
    var hkWorkoutId: String?
    var rawDataFiles: String
    var linkedWorkoutId: String?

    init(from model: Workout) {
        self.id = model.id.uuidString
        self.startDate = model.startDate.timeIntervalSince1970
        self.endDate = model.endDate.timeIntervalSince1970
        self.activityType = model.activityType
        self.source = model.source
        self.durationSec = model.durationSec
        self.distanceKm = model.distanceKm
        self.calories = model.calories
        self.avgHR = model.avgHR
        self.maxHR = model.maxHR
        self.hkWorkoutId = model.hkWorkoutId?.uuidString
        self.rawDataFiles = MeasurementRecord.encodeJSON(model.rawDataFiles)
        self.linkedWorkoutId = model.linkedWorkoutId?.uuidString
    }

    func toModel() -> Workout {
        if UUID(uuidString: id) == nil {
            AppLogger.storage.error("Corrupt workout UUID: \(id) — generating replacement")
        }
        return Workout(
            id: UUID(uuidString: id) ?? UUID(),
            startDate: Date(timeIntervalSince1970: startDate),
            endDate: Date(timeIntervalSince1970: endDate),
            activityType: activityType,
            source: source,
            durationSec: durationSec,
            distanceKm: distanceKm,
            calories: calories,
            avgHR: avgHR,
            maxHR: maxHR,
            hkWorkoutId: hkWorkoutId.flatMap { UUID(uuidString: $0) },
            rawDataFiles: (MeasurementRecord.decodeJSON(rawDataFiles) as [String]?) ?? [],
            linkedWorkoutId: linkedWorkoutId.flatMap { UUID(uuidString: $0) }
        )
    }
}

// MARK: - Workout Data Point Record

struct WorkoutDataPointRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "workout_data_point"

    var id: Int64?
    var workoutId: String
    var timestamp: Double
    var endTimestamp: Double?
    var type: String
    var value: Double
    var unit: String
    var source: String
    var role: String

    init(workoutId: String, from model: DataPoint) {
        self.workoutId = workoutId
        self.timestamp = model.timestamp.timeIntervalSince1970
        self.endTimestamp = model.endTimestamp?.timeIntervalSince1970
        self.type = model.type
        self.value = model.value
        self.unit = model.unit
        self.source = model.source
        self.role = model.role.rawValue
    }

    func toModel() -> DataPoint {
        DataPoint(
            timestamp: Date(timeIntervalSince1970: timestamp),
            endTimestamp: endTimestamp.map { Date(timeIntervalSince1970: $0) },
            type: type,
            value: value,
            unit: unit,
            source: source,
            role: DataPointRole(rawValue: role) ?? .primary
        )
    }
}

// MARK: - User Profile Record

struct UserProfileRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "user_profile"

    var id: Int = 1  // singleton
    var heightCm: Double
    var age: Int
    var sex: String
    var maxHROverride: Int?
    var hrZone1Max: Int?
    var hrZone2Max: Int?
    var hrZone3Max: Int?
    var hrZone4Max: Int?

    init(from model: UserProfile) {
        self.heightCm = model.heightCm
        self.age = model.age
        self.sex = model.sex.rawValue
        self.maxHROverride = model.maxHROverride
        self.hrZone1Max = model.hrZone1Max
        self.hrZone2Max = model.hrZone2Max
        self.hrZone3Max = model.hrZone3Max
        self.hrZone4Max = model.hrZone4Max
    }

    func toModel() -> UserProfile {
        UserProfile(
            heightCm: heightCm,
            age: age,
            sex: UserProfile.Sex(rawValue: sex) ?? .male,
            hrZone1Max: hrZone1Max,
            hrZone2Max: hrZone2Max,
            hrZone3Max: hrZone3Max,
            hrZone4Max: hrZone4Max,
            maxHROverride: maxHROverride
        )
    }
}
