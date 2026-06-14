import Foundation

// MARK: - Data Point Role

/// Controls UI display: primary values are headline metrics shown prominently,
/// detail values are supporting info shown in expanded/collapsible sections.
enum DataPointRole: String, Codable, Sendable {
    case primary   // headline values (weight, stress_index, pace)
    case detail    // supporting values (impedance, confidence, SDNN min/max)
}

// MARK: - Data Point (universal unit of measurement)

struct DataPoint: Codable, Identifiable, Sendable {
    var id: String { "\(type)-\(source)-\(timestamp.timeIntervalSince1970)" }

    let timestamp: Date
    let endTimestamp: Date?     // nil = point-in-time, set = interval
    let type: String            // "heart_rate", "cadence", "weight", "accel_x", etc.
    let value: Double
    let unit: String            // "bpm", "spm", "kg", "g", "dps", "ohm", "%", "kcal", etc.
    let source: String          // "device:serial", "hk:source_name", "derived:algorithm"
    let role: DataPointRole     // .primary = headline, .detail = supporting

    private enum CodingKeys: String, CodingKey {
        case timestamp, endTimestamp, type, value, unit, source, role
    }

    // Backward-compatible decoding: old JSON without `role` defaults to .primary
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        endTimestamp = try c.decodeIfPresent(Date.self, forKey: .endTimestamp)
        type = try c.decode(String.self, forKey: .type)
        value = try c.decode(Double.self, forKey: .value)
        unit = try c.decode(String.self, forKey: .unit)
        source = try c.decode(String.self, forKey: .source)
        role = (try c.decodeIfPresent(DataPointRole.self, forKey: .role)) ?? .primary
    }

    init(timestamp: Date, endTimestamp: Date?, type: String, value: Double,
         unit: String, source: String, role: DataPointRole = .primary) {
        self.timestamp = timestamp; self.endTimestamp = endTimestamp
        self.type = type; self.value = value; self.unit = unit
        self.source = source; self.role = role
    }
}

// MARK: - Measurement Source (device or algorithm that produced data)

struct MeasurementSource: Codable, Identifiable, Sendable {
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

struct SensorMeasurement: Codable, Identifiable, Sendable {
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

    /// Display name for the measurement type (used in list rows when DataPoints aren't loaded).
    var typeName: String {
        switch type {
        case .bodyComp:     return "Body Composition"
        case .derived:      return "Derived"
        case .metric:       return "Metric"
        case .workout:      return "IMU Recording"
        case .hkWorkout:    return "Workout"
        case .labResults:   return "Lab Results"
        case .fluidIntake:  return "Drink"
        case .checkIn:      return "Check-in"
        case .saunaSession: return "Sauna"
        }
    }

    // Convenience — when DataPoints are empty (lightweight DB headers), returns type name
    var summary: String {
        if dataPoints.isEmpty { return typeName }
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
        case .hkWorkout:
            let name = dataPoints.first(where: { $0.type == DataType.workoutType })?.unit ?? "Workout"
            let dur = dataPoints.first(where: { $0.type == DataType.workoutDuration })?.value ?? 0
            let dist = dataPoints.first(where: { $0.type == DataType.workoutDistance })?.value ?? 0
            let m = Int(dur) / 60, s = Int(dur) % 60
            var parts = ["\(name) \(m):\(String(format: "%02d", s))"]
            if dist > 0 { parts.append(String(format: "%.2f km", dist)) }
            if let hr = dataPoints.first(where: { $0.type == DataType.workoutAvgHR }) {
                parts.append(String(format: "%.0f bpm", hr.value))
            }
            return parts.joined(separator: " · ")
        case .derived:
            // Daytime stress score
            // Stress measurement (with or without score)
            if let recovery = dataPoints.first(where: { $0.type == DataType.recoveryIndex }) {
                let level = Int(recovery.value.rounded())
                let label: String
                switch recovery.value {
                case 75...: label = "Excellent"
                case 50...: label = "Good"
                case 25...: label = "Fair"
                default:    label = "Poor"
                }
                return "Recovery \(level) · \(label)"
            }
            // Running enrichment
            let dist = dataPoints.first(where: { $0.type == DataType.distance })?.value ?? 0
            let pace = dataPoints.first(where: { $0.type == DataType.pace })?.value ?? 0
            let hr   = dataPoints.first(where: { $0.type == DataType.heartRate })?.value ?? 0
            let econ = dataPoints.first(where: { $0.type == DataType.runningEconomy })?.value ?? 0
            if dist > 0 && pace > 0 {
                let pm = Int(pace), ps = Int((pace - Double(pm)) * 60)
                let econStr = econ > 0 ? String(format: " · %.0f beats/km", econ) : ""
                let hrStr   = hr > 0   ? String(format: " · %.0f bpm", hr)        : ""
                return String(format: "%.2f km · %d:%02d /km", dist, pm, ps) + hrStr + econStr
            }
            return dataPoints.first.map { "\($0.type): \($0.value)" } ?? "Derived"
        case .metric:
            let hrvPoints = dataPoints.filter { $0.type == DataType.hrvSDNN }
            if !hrvPoints.isEmpty {
                let avg = hrvPoints.map(\.value).reduce(0, +) / Double(hrvPoints.count)
                return String(format: "HRV %.0f ms · %d readings", avg, hrvPoints.count)
            }
            let rhrPoints = dataPoints.filter { $0.type == DataType.restingHeartRate }
            if !rhrPoints.isEmpty {
                let min = rhrPoints.map(\.value).min() ?? 0
                return String(format: "Resting HR %.0f bpm · %d readings", min, rhrPoints.count)
            }
            if let spo2 = dataPoints.first(where: { $0.type == DataType.bloodOxygen }) {
                let count = dataPoints.filter { $0.type == DataType.bloodOxygen }.count
                return String(format: "SpO2 %.0f%% · %d readings", spo2.value * 100, count)
            }
            if let temp = dataPoints.first(where: { $0.type == DataType.bodyTemperature }) {
                return String(format: "Temp %.1f°C", temp.value)
            }
            if let vo2 = dataPoints.first(where: { $0.type == DataType.vo2Max }) {
                return String(format: "VO2max %.1f mL/kg/min", vo2.value)
            }
            let stepPoints = dataPoints.filter { $0.type == DataType.steps }
            if let maxSteps = stepPoints.max(by: { $0.value < $1.value }) {
                let sourceCount = Set(stepPoints.map(\.source)).count
                let suffix = sourceCount > 1 ? " · \(sourceCount) sources" : ""
                return String(format: "%.0f steps%@", maxSteps.value, suffix)
            }
            let hrPoints = dataPoints.filter { $0.type == DataType.heartRateSample }
            if !hrPoints.isEmpty {
                let avg = hrPoints.map(\.value).reduce(0, +) / Double(hrPoints.count)
                return String(format: "HR avg %.0f bpm · %d samples", avg, hrPoints.count)
            }
            let sleepPoints = dataPoints.filter { $0.type == DataType.sleepStage }
            if !sleepPoints.isEmpty {
                let totalMin = sleepPoints.reduce(0) { sum, p in
                    sum + (p.endTimestamp?.timeIntervalSince(p.timestamp) ?? 0) / 60
                }
                return String(format: "Sleep %.0fh %02.0fm · %d stages", totalMin / 60, totalMin.truncatingRemainder(dividingBy: 60), sleepPoints.count)
            }
            return dataPoints.first.map { "\($0.type): \(String(format: "%.1f", $0.value))" } ?? "Metric"
        case .labResults:
            let primary = dataPoints.filter { $0.role == .primary }
            let parts = primary.prefix(3).map { p in
                String(format: "%.0f %@ %@", p.value, p.unit, DataType.labDisplayName(p.type))
            }
            return parts.isEmpty ? "Lab Results" : parts.joined(separator: " · ")
        case .fluidIntake:
            let volume = dataPoints.first(where: { $0.type == DataType.fluidVolume })?.value ?? 0
            let category = dataPoints.first(where: { $0.type == DataType.fluidCategory })?.unit ?? "drink"
            return String(format: "%@ · %.0f mL", category.capitalized, volume)
        case .saunaSession:
            let rounds = dataPoints.filter { $0.type == DataType.saunaRound }
            if rounds.isEmpty { return "Sauna" }
            let totalSec = rounds.reduce(0) { $0 + $1.value }
            let m = Int(totalSec) / 60
            let types = rounds.compactMap { SaunaRoundType(rawValue: $0.unit)?.label }
            let uniqueTypes = Array(Set(types))
            return String(format: "%d rounds · %d min · %@", rounds.count, m, uniqueTypes.joined(separator: ", "))
        case .checkIn:
            if let readiness = dataPoints.first(where: { $0.type == DataType.morningReadiness }) {
                let labels = ["", "Exhausted", "Tired", "OK", "Good", "Great"]
                let label = Int(readiness.value) >= 1 && Int(readiness.value) <= 5
                    ? labels[Int(readiness.value)] : "\(Int(readiness.value))"
                return "Morning · \(label)"
            }
            if let energy = dataPoints.first(where: { $0.type == DataType.eveningEnergy }) {
                let labels = ["", "Very Low", "Low", "OK", "Good", "Great"]
                let label = Int(energy.value) >= 1 && Int(energy.value) <= 5
                    ? labels[Int(energy.value)] : "\(Int(energy.value))"
                return "Evening · \(label)"
            }
            return "Check-in"
        }
    }

    var dateString: String { DateFormatters.mediumDateTime.string(from: date) }

    var sourceLabel: String {
        sources.map(\.deviceName).joined(separator: " + ")
    }

    var icon: String {
        switch type {
        case .workout:     return "figure.run"
        case .bodyComp:    return "scalemass"
        case .derived:     return "function"
        case .metric:      return "waveform.path.ecg"
        case .hkWorkout:   return "heart.circle"
        case .labResults:  return "cross.case"
        case .fluidIntake: return "drop.fill"
        case .checkIn:     return "face.smiling"
        case .saunaSession: return "flame.fill"
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

enum MeasurementType: String, Codable, Sendable {
    case workout = "workout"        // IMU sensor workout
    case bodyComp = "body_comp"     // scale measurement
    case derived = "derived"        // algorithm output (stress, enrichment)
    case metric = "metric"          // raw imported metrics (HRV, RHR, HR, etc.)
    case hkWorkout = "hk_workout"   // HealthKit workout (time-bounded event with embedded time-series)
    case labResults = "lab_results" // manual blood work / lab results entry
    case fluidIntake = "fluid_intake" // drink/fluid log (water, coffee, alcohol, etc.)
    case checkIn = "check_in"       // subjective self-assessment (morning readiness, evening energy)
    case saunaSession = "sauna_session" // sauna visit with multiple rounds (synced from Apple Watch)
}

// MARK: - Source string convention helpers

/// Typed constructors for DataPoint.source strings.
/// Format: "device:<serial>", "hk:<hk-uuid>", "derived:<algorithm-id>"
enum DataSource {
    static func device(_ serial: String) -> String { "device:\(serial)" }
    static func healthKit(_ uuid: UUID) -> String { "hk:\(uuid.uuidString)" }
    static func derived(_ algorithm: String) -> String { "derived:\(algorithm)" }
    /// HealthKit source by name (from HKSample.sourceRevision.source.name, e.g. "Apple Watch")
    static func healthKitSource(_ name: String) -> String { "hk:\(name)" }
}

// MARK: - MeasurementSource factories (extending existing ones)

extension MeasurementSource {
    /// Source backed by an Apple Health / HealthKit record (specific workout).
    static func healthKit(workoutID: UUID, name: String = "Apple Watch") -> MeasurementSource {
        MeasurementSource(deviceType: "apple_watch",
                          deviceName: name,
                          serialNumber: DataSource.healthKit(workoutID),
                          algorithmName: nil)
    }

    /// Source for manual user entries (check-ins, drink logging).
    static let manualEntry = MeasurementSource(
        deviceType: "manual", deviceName: "Manual Entry",
        serialNumber: nil, algorithmName: nil)

    /// Source backed by HealthKit aggregate data (no specific object UUID).
    /// Derives deviceType from the HK source name (e.g. "Apple Watch" → "apple_watch").
    static func healthKitDevice(name: String) -> MeasurementSource {
        let type = name.lowercased().contains("watch") ? "apple_watch" : "apple_health"
        return MeasurementSource(deviceType: type, deviceName: name,
                                 serialNumber: nil, algorithmName: nil)
    }

    /// Source for sauna sessions tracked on the companion watchOS app.
    static let watchApp = MeasurementSource(
        deviceType: "apple_watch", deviceName: "Apple Watch",
        serialNumber: nil, algorithmName: nil)
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
    static let runningSpeed = "running_speed"       // m/s — Apple's pre-calculated GPS+sensor speed

    // Derived — running
    static let stepLength = "step_length"         // m/step
    static let runningEconomy = "running_economy" // beats/km (HR cost per km — lower = more efficient)
    static let aerobicLoad = "aerobic_load"       // avg HR × duration_min (arbitrary training stress unit)

    // Sleep score (sleep_v1) — nightly score from sleep stages
    static let sleepScore                = "sleep_score"                  // 0–100 overall
    static let sleepDurationComponent    = "sleep_duration_component"    // 0–50
    static let sleepConsistencyComponent = "sleep_consistency_component" // 0–30
    static let sleepInterruptionComponent = "sleep_interruption_component" // 0–20

    // Raw HealthKit metrics (standalone daily measurements)
    static let hrvSDNN          = "heart_rate_variability_sdnn"  // individual SDNN reading (ms)
    static let restingHeartRate = "resting_heart_rate"           // daily resting HR (bpm)
    static let bloodOxygen      = "blood_oxygen"                 // SpO2 (%)
    static let bodyTemperature  = "body_temperature"             // °C
    static let vo2Max           = "vo2_max"                      // mL/kg/min
    static let steps            = "steps"                        // cumulative daily steps
    static let sleepStage       = "sleep_stage"                  // sleep stage (encoded as double)
    static let heartRateSample  = "heart_rate_sample"            // individual HR reading (bpm)
    static let respiratoryRate  = "respiratory_rate"             // breaths/min (sleep-derived)
    static let walkingHeartRateAvg = "walking_heart_rate_avg"   // bpm (daily walking average)
    static let activeEnergy     = "active_energy"                // kcal (cumulative daily)
    static let wristTemperature = "wrist_temperature"            // °C deviation from baseline (sleep)

    // HealthKit workout data points
    static let workoutType      = "workout_type"                 // activity type name (stored as string via unit)
    static let workoutDuration  = "workout_duration"             // seconds
    static let workoutDistance  = "workout_distance"             // km
    static let workoutCalories  = "workout_calories"             // kcal
    static let workoutAvgHR     = "workout_avg_hr"               // bpm
    static let workoutMaxHR     = "workout_max_hr"               // bpm

    // Blood work / lab results
    static let glucose          = "glucose"               // mg/dL — fasting blood glucose
    static let hemoglobinA1C    = "hemoglobin_a1c"        // % — glycated hemoglobin
    static let totalCholesterol = "total_cholesterol"     // mg/dL
    static let ldlCholesterol   = "ldl_cholesterol"       // mg/dL
    static let hdlCholesterol   = "hdl_cholesterol"       // mg/dL
    static let triglycerides    = "triglycerides"          // mg/dL
    static let ferritin         = "ferritin"               // ng/mL — iron storage
    static let vitaminD         = "vitamin_d"              // ng/mL
    static let iron             = "iron"                   // mcg/dL
    static let hemoglobin       = "hemoglobin"             // g/dL
    static let creatinine       = "creatinine"             // mg/dL — kidney function
    static let tsh              = "tsh"                    // mIU/L — thyroid
    static let cortisol         = "cortisol"               // mcg/dL — stress hormone
    static let testosterone     = "testosterone"           // ng/dL
    static let vitaminB12       = "vitamin_b12"            // pg/mL
    static let crp              = "crp"                    // mg/L — inflammation marker

    /// Human-readable display name for any data type.
    static func displayName(_ type: String) -> String {
        switch type {
        case weight: return "Weight"
        case impedance: return "Impedance"
        case bmi: return "BMI"
        case bodyFatPercent: return "Body Fat"
        case fatMassKg: return "Fat Mass"
        case fatFreeMassKg: return "Fat-Free Mass"
        case muscleMassKg: return "Muscle Mass"
        case musclePercent: return "Muscle %"
        case bodyWaterPercent: return "Body Water"
        case bmrKcal: return "BMR"
        case heartRate: return "Heart Rate"
        case cadence: return "Cadence"
        case totalSteps: return "Total Steps"
        case avgCadence: return "Avg Cadence"
        case peakG: return "Peak g"
        case durationSec: return "Duration"
        case distance: return "Distance"
        case activeCalories: return "Active Calories"
        case pace: return "Pace"
        case stepLength: return "Step Length"
        case runningEconomy: return "Running Economy"
        case aerobicLoad: return "Aerobic Load"
        case hrvSDNN: return "HRV (SDNN)"
        case restingHeartRate: return "Resting HR"
        case bloodOxygen: return "SpO2"
        case bodyTemperature: return "Temperature"
        case vo2Max: return "VO2 Max"
        case steps: return "Steps"
        case sleepStage: return "Sleep"
        case heartRateSample: return "Heart Rate"
        case workoutType: return "Activity"
        case workoutDuration: return "Duration"
        case workoutDistance: return "Distance"
        case workoutCalories: return "Calories"
        case workoutAvgHR: return "Avg HR"
        case workoutMaxHR: return "Max HR"
        case recoveryIndex: return "Recovery"
        case recoveryHRVComponent: return "HRV Recovery"
        case recoveryRHRComponent: return "RHR Recovery"
        case recoveryBaselineSDNN: return "30d Avg SDNN"
        case recoveryBaselineRHR: return "30d Avg RHR"
        case recoveryConfidence: return "Confidence"
        case saunaRound: return "Sauna Round"
        case saunaTotalRounds: return "Total Rounds"
        case saunaTotalDuration: return "Total Duration"
        default: return labDisplayName(type)
        }
    }

    /// Display name for lab result data types.
    static func labDisplayName(_ type: String) -> String {
        switch type {
        case glucose:          return "Glucose"
        case hemoglobinA1C:    return "HbA1C"
        case totalCholesterol: return "Total Chol."
        case ldlCholesterol:   return "LDL"
        case hdlCholesterol:   return "HDL"
        case triglycerides:    return "Triglycerides"
        case ferritin:         return "Ferritin"
        case vitaminD:         return "Vitamin D"
        case iron:             return "Iron"
        case hemoglobin:       return "Hemoglobin"
        case creatinine:       return "Creatinine"
        case tsh:              return "TSH"
        case cortisol:         return "Cortisol"
        case testosterone:     return "Testosterone"
        case vitaminB12:       return "Vitamin B12"
        case crp:              return "CRP"
        default:               return type.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    // Fluid intake
    static let fluidVolume      = "fluid_volume"          // mL
    static let fluidCategory    = "fluid_category"        // value=0, unit stores category name (water, coffee, beer, etc.)
    static let caffeineContent  = "caffeine_content"      // mg (estimated from template)
    static let alcoholUnits     = "alcohol_units"         // standard drinks

    // Subjective check-in
    static let morningReadiness = "morning_readiness"     // 1–5 scale (how rested)
    static let eveningEnergy    = "evening_energy"        // 1–5 scale (how was energy)
    static let checkInTag       = "check_in_tag"          // value=1.0, unit stores tag name

    // Sauna session
    static let saunaRound         = "sauna_round"          // value = duration_sec, unit = round type (finnish, bio_mild, steam, cold_plunge, whirlpool, rest)
    static let saunaTotalRounds   = "sauna_total_rounds"   // value = count of rounds
    static let saunaTotalDuration = "sauna_total_duration" // value = total seconds across all rounds

    // Recovery score (recovery_v1) — overnight HRV + RHR, z-score normalized
    static let recoveryIndex        = "recovery_index"          // 0–100 (higher = better recovered)
    static let recoveryHRVComponent = "recovery_hrv_component"  // 0–100 from overnight SDNN z-score
    static let recoveryRHRComponent = "recovery_rhr_component"  // 0–100 from RHR z-score
    static let recoveryBaselineSDNN = "recovery_baseline_sdnn"  // 30-day avg overnight SDNN (ms)
    static let recoveryBaselineRHR  = "recovery_baseline_rhr"   // 30-day avg RHR (bpm)
    static let recoveryConfidence   = "recovery_confidence"     // 0–1 data quality
}

// MARK: - Sauna round types (shared with watchOS)

enum SaunaRoundType: String, Codable, CaseIterable, Sendable {
    case finnish
    case bioMild = "bio_mild"
    case steam
    case coldPlunge = "cold_plunge"
    case whirlpool
    case rest

    var label: String {
        switch self {
        case .finnish:    return "Finnish"
        case .bioMild:    return "Bio / Mild"
        case .steam:      return "Steam"
        case .coldPlunge: return "Cold Plunge"
        case .whirlpool:  return "Whirlpool"
        case .rest:       return "Rest"
        }
    }

    var icon: String {
        switch self {
        case .finnish:    return "flame.fill"
        case .bioMild:    return "flame"
        case .steam:      return "cloud.fill"
        case .coldPlunge: return "snowflake"
        case .whirlpool:  return "drop.circle.fill"
        case .rest:       return "pause.circle"
        }
    }
}
