import Foundation
import Combine
import HealthKit
import os

struct AppleWorkout: Identifiable {
    let id: UUID
    let workout: HKWorkout
    var startDate: Date { workout.startDate }
    var endDate: Date { workout.endDate }
    var duration: TimeInterval { workout.duration }
    var activityType: HKWorkoutActivityType { workout.workoutActivityType }

    var durationString: String {
        let m = Int(duration) / 60
        let s = Int(duration) % 60
        return String(format: "%d:%02d", m, s)
    }

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var dateString: String { Self.fmt.string(from: startDate) }

    var activityName: String {
        switch activityType {
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Cycle"
        case .hiking: return "Hike"
        default: return "Workout"
        }
    }

    var distanceKm: Double {
        let stats = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!)
        return (stats?.sumQuantity()?.doubleValue(for: .meter()) ?? 0) / 1000
    }

    var calories: Double {
        let stats = workout.statistics(for: HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!)
        return stats?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0
    }
}

struct TimestampedValue: Identifiable {
    let id = UUID()
    let date: Date
    let value: Double
}

struct SourceData: Identifiable {
    let id = UUID()
    let sourceName: String
    var totalSteps: Int = 0
    var avgCadence: Double = 0
    var cadenceSamples: [TimestampedValue] = []
    var distanceMeters: Double = 0
    var distanceSamples: [TimestampedValue] = []
    var distanceKm: Double { distanceMeters / 1000 }
}

struct AppleRunData {
    var heartRateSamples: [TimestampedValue] = []
    var avgHeartRate: Double = 0
    var activeCalories: Double = 0
    var sources: [SourceData] = []  // per-source step/distance data

    // Convenience: primary source (most samples)
    var primarySource: SourceData? { sources.max(by: { $0.cadenceSamples.count < $1.cadenceSamples.count }) }
    var totalSteps: Int { sources.map(\.totalSteps).max() ?? 0 }
    var avgCadence: Double { primarySource?.avgCadence ?? 0 }
    var cadenceSamples: [TimestampedValue] { primarySource?.cadenceSamples ?? [] }
    var distanceMeters: Double { sources.map(\.distanceMeters).max() ?? 0 }
    var distanceSamples: [TimestampedValue] { primarySource?.distanceSamples ?? [] }
    var distanceKm: Double { distanceMeters / 1000 }
}

struct HealthSummary {
    var steps: Int = 0
    var distanceMeters: Double = 0
    var calories: Double = 0
    var latestHR: Double = 0
    var avgHR: Double = 0
    var minHR: Double = 0
    var maxHR: Double = 0
    var distanceKm: Double { distanceMeters / 1000 }
}

/// Sleep summary for a single night (last night by default).
struct SleepSummary {
    var totalInBedMinutes: Int = 0
    var totalAsleepMinutes: Int = 0
    var remMinutes: Int = 0
    var coreMinutes: Int = 0
    var deepMinutes: Int = 0
    var awakeMinutes: Int = 0
    var hasStages: Bool { remMinutes + coreMinutes + deepMinutes > 0 }

    var totalInBedString: String { formatMinutes(totalInBedMinutes) }
    var totalAsleepString: String { formatMinutes(totalAsleepMinutes) }
    var efficiency: Double {
        guard totalInBedMinutes > 0 else { return 0 }
        return Double(totalAsleepMinutes) / Double(totalInBedMinutes)
    }

    private func formatMinutes(_ m: Int) -> String {
        String(format: "%dh %02dm", m / 60, m % 60)
    }
}

class HealthKitManager: ObservableObject {
    let store = HKHealthStore()

    @Published var authorized = false
    @Published var workouts: [AppleWorkout] = []
    @Published var isLoadingWorkouts = false  // M3: distinguish "loading" from "empty"
    @Published var sleepSummary: SleepSummary?

    // M4: cache to avoid redundant queries
    private var lastWorkoutFetch: Date?

    // H1: Only request types we actually query. Requesting unused types (runningSpeed,
    // strideLength, verticalOscillation, groundContactTime) prompts unnecessary permissions.
    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        types.insert(HKQuantityType.quantityType(forIdentifier: .heartRate)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .stepCount)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!)
        types.insert(HKObjectType.workoutType())
        types.insert(HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!)
        return types
    }()

    private let writeTypes: Set<HKSampleType> = []

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() {
        guard isAvailable else { print("HealthKit not available"); return }
        store.requestAuthorization(toShare: writeTypes, read: readTypes) { success, error in
            print("HealthKit auth result: \(success), error: \(String(describing: error))")
            DispatchQueue.main.async {
                // Always mark as authorized after prompt — Apple returns false
                // even when user grants read access (privacy design)
                self.authorized = true
                self.fetchRecentWorkouts()
                self.fetchLastNightSleep()
            }
        }
    }

    // MARK: - Fetch Recent Workouts
    func fetchRecentWorkouts(force: Bool = false) {
        // M4: skip if fetched within last 30 seconds
        if !force, let last = lastWorkoutFetch, Date().timeIntervalSince(last) < 30 { return }
        lastWorkoutFetch = Date()
        isLoadingWorkouts = true
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: nil,
            limit: 50,
            sortDescriptors: [sort]
        ) { [weak self] _, results, error in
            if let error { AppLogger.health.error("Workout query error: \(error.localizedDescription)") }
            let workouts = (results as? [HKWorkout] ?? []).map { AppleWorkout(id: $0.uuid, workout: $0) }
            DispatchQueue.main.async {
                self?.workouts = workouts
                self?.isLoadingWorkouts = false
            }
        }
        store.execute(query)
    }

    // MARK: - Fetch Workout by UUID
    func fetchWorkout(byID uuidString: String, completion: @escaping (AppleWorkout?) -> Void) {
        guard let uuid = UUID(uuidString: uuidString) else { completion(nil); return }
        let predicate = HKQuery.predicateForObject(with: uuid)
        let query = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                  limit: 1, sortDescriptors: nil) { _, results, _ in
            let workout = (results as? [HKWorkout])?.first.map { AppleWorkout(id: $0.uuid, workout: $0) }
            DispatchQueue.main.async { completion(workout) }
        }
        store.execute(query)
    }

    // MARK: - Fetch Today's Summary
    func fetchTodaySummary(completion: @escaping (HealthSummary) -> Void) {
        let cal = Calendar.current
        let start = cal.startOfDay(for: Date())
        let end = Date()
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate)
        var summary = HealthSummary()
        let group = DispatchGroup()

        group.enter()
        fetchCumulativeStat(.stepCount, predicate: predicate) { val in
            summary.steps = Int(val); group.leave()
        }
        group.enter()
        fetchCumulativeStat(.distanceWalkingRunning, predicate: predicate) { val in
            summary.distanceMeters = val; group.leave()
        }
        group.enter()
        fetchCumulativeStat(.activeEnergyBurned, predicate: predicate) { val in
            summary.calories = val; group.leave()
        }
        group.enter()
        fetchSamples(.heartRate, predicate: predicate) { samples in
            if let last = samples.last {
                summary.latestHR = last.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
            }
            if !samples.isEmpty {
                let hrs = samples.map { $0.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute())) }
                summary.avgHR = hrs.reduce(0, +) / Double(hrs.count)
                summary.minHR = hrs.min() ?? 0
                summary.maxHR = hrs.max() ?? 0
            }
            group.leave()
        }

        group.notify(queue: .main) { completion(summary) }
    }

    // MARK: - Fetch Detailed Data for a Workout
    func fetchRunData(from startDate: Date, to endDate: Date, completion: @escaping (AppleRunData) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        var result = AppleRunData()
        let group = DispatchGroup()

        group.enter()
        fetchSamples(.heartRate, predicate: predicate) { samples in
            result.heartRateSamples = samples.map { s in
                let bpm = s.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
                return TimestampedValue(date: s.startDate, value: bpm)
            }
            result.avgHeartRate = result.heartRateSamples.isEmpty ? 0 :
                result.heartRateSamples.map(\.value).reduce(0, +) / Double(result.heartRateSamples.count)
            group.leave()
        }

        // Step count samples → calculate cadence per interval
        group.enter()
        fetchSamples(.stepCount, predicate: predicate) { stepSamples in
            // Group steps by source
            var stepsBySource: [String: [HKQuantitySample]] = [:]
            for s in stepSamples { stepsBySource[s.sourceRevision.source.name, default: []].append(s) }

            let totalDuration = endDate.timeIntervalSince(startDate) / 60

            for (sourceName, samples) in stepsBySource {
                var sd = result.sources.first(where: { $0.sourceName == sourceName }) ?? SourceData(sourceName: sourceName)
                var total: Double = 0
                for s in samples {
                    let steps = s.quantity.doubleValue(for: .count())
                    let dur = s.endDate.timeIntervalSince(s.startDate)
                    total += steps
                    if dur > 0 {
                        sd.cadenceSamples.append(TimestampedValue(
                            date: s.startDate.addingTimeInterval(dur / 2),
                            value: (steps / dur) * 60
                        ))
                    }
                }
                sd.totalSteps = Int(total)
                sd.avgCadence = totalDuration > 0 ? total / totalDuration : 0
                if let idx = result.sources.firstIndex(where: { $0.sourceName == sourceName }) {
                    result.sources[idx] = sd
                } else {
                    result.sources.append(sd)
                }
            }
            group.leave()
        }

        // Distance samples → per source
        group.enter()
        fetchSamples(.distanceWalkingRunning, predicate: predicate) { distSamples in
            var distBySource: [String: [HKQuantitySample]] = [:]
            for s in distSamples { distBySource[s.sourceRevision.source.name, default: []].append(s) }

            for (sourceName, samples) in distBySource {
                var sd = result.sources.first(where: { $0.sourceName == sourceName }) ?? SourceData(sourceName: sourceName)
                var cumDist: Double = 0
                for s in samples {
                    cumDist += s.quantity.doubleValue(for: .meter())
                    sd.distanceSamples.append(TimestampedValue(date: s.endDate, value: cumDist))
                }
                sd.distanceMeters = cumDist
                if let idx = result.sources.firstIndex(where: { $0.sourceName == sourceName }) {
                    result.sources[idx] = sd
                } else {
                    result.sources.append(sd)
                }
            }
            group.leave()
        }

        group.enter()
        fetchCumulativeStat(.activeEnergyBurned, predicate: predicate) { total in
            result.activeCalories = total
            group.leave()
        }

        group.notify(queue: .main) {
            completion(result)
        }
    }

    // MARK: - Helpers
    private func fetchSamples(_ identifier: HKQuantityTypeIdentifier, predicate: NSPredicate,
                              completion: @escaping ([HKQuantitySample]) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion([]); return
        }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                  sortDescriptors: [sort]) { _, results, _ in
            completion((results as? [HKQuantitySample]) ?? [])
        }
        store.execute(query)
    }

    private func fetchCumulativeStat(_ identifier: HKQuantityTypeIdentifier, predicate: NSPredicate,
                                     completion: @escaping (Double) -> Void) {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion(0); return
        }
        let query = HKStatisticsQuery(quantityType: type, quantitySamplePredicate: predicate,
                                      options: .cumulativeSum) { _, stats, _ in
            let unit: HKUnit
            switch identifier {
            case .stepCount: unit = .count()
            case .distanceWalkingRunning: unit = .meter()
            case .activeEnergyBurned: unit = .kilocalorie()
            default: unit = .count()
            }
            let value = stats?.sumQuantity()?.doubleValue(for: unit) ?? 0
            completion(value)
        }
        store.execute(query)
    }

    // MARK: - Fetch Sleep Data

    /// Fetches sleep analysis for the most recent night (8:00 PM yesterday → 12:00 PM today).
    /// Wide window handles late sleepers and naps without missing early-morning wake-up data.
    func fetchLastNightSleep() {
        let cal = Calendar.current
        let now = Date()
        // Window end: noon today (or now if before noon, so we don't miss this morning)
        var noonComps = cal.dateComponents([.year, .month, .day], from: now)
        noonComps.hour = 12
        let todayNoon = cal.date(from: noonComps)!
        let windowEnd = min(todayNoon, now)

        // Window start: 8pm yesterday
        var eveningComps = cal.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-86400))
        eveningComps.hour = 20
        let windowStart = cal.date(from: eveningComps)!

        let predicate = HKQuery.predicateForSamples(withStart: windowStart, end: windowEnd, options: .strictStartDate)

        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else { return }
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { [weak self] _, results, error in
            if let error { AppLogger.health.error("Sleep query error: \(error.localizedDescription)") }
            let samples = results as? [HKCategorySample] ?? []
            var summary = SleepSummary()

            for sample in samples {
                let minutes = Int(sample.endDate.timeIntervalSince(sample.startDate) / 60)
                guard minutes > 0 else { continue }

                switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
                case .inBed:
                    summary.totalInBedMinutes += minutes
                case .asleepUnspecified, .asleep:
                    summary.totalAsleepMinutes += minutes
                case .awake:
                    summary.awakeMinutes += minutes
                case .asleepREM:
                    summary.remMinutes += minutes
                    summary.totalAsleepMinutes += minutes
                case .asleepCore:
                    summary.coreMinutes += minutes
                    summary.totalAsleepMinutes += minutes
                case .asleepDeep:
                    summary.deepMinutes += minutes
                    summary.totalAsleepMinutes += minutes
                default:
                    break
                }
            }

            // Apple Watch records staged sleep (core/REM/deep) without inBed entries.
            // Fall back to using total asleep time as "in bed" so the card always renders.
            if summary.totalInBedMinutes == 0 {
                summary.totalInBedMinutes = summary.totalAsleepMinutes + summary.awakeMinutes
            }
            let hasSleepData = summary.totalAsleepMinutes > 0 || summary.totalInBedMinutes > 0
            DispatchQueue.main.async { self?.sleepSummary = hasSleepData ? summary : nil }
        }
        store.execute(query)
    }

    // MARK: - Debug: dump all data types available for a time range
    func debugDump(from startDate: Date, to endDate: Date, completion: @escaping (String) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let serialQueue = DispatchQueue(label: "healthkit.debug")
        var outputParts: [String] = ["=== HEALTH DATA DEBUG DUMP ===\nRange: \(startDate) to \(endDate)\n\n"]

        let typesToCheck: [(String, HKQuantityTypeIdentifier, HKUnit)] = [
            ("Heart Rate", .heartRate, HKUnit.count().unitDivided(by: .minute())),
            ("Step Count", .stepCount, .count()),
            ("Distance", .distanceWalkingRunning, .meter()),
            ("Active Calories", .activeEnergyBurned, .kilocalorie()),
            ("Running Speed", .runningSpeed, HKUnit.meter().unitDivided(by: .second())),
            ("Stride Length", .runningStrideLength, .meter()),
            ("Vertical Oscillation", .runningVerticalOscillation, HKUnit.meterUnit(with: .centi)),
            ("Ground Contact Time", .runningGroundContactTime, HKUnit.secondUnit(with: .milli)),
        ]

        let group = DispatchGroup()

        for (name, identifier, unit) in typesToCheck {
            group.enter()
            guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
                serialQueue.sync { outputParts.append("[\(name)] Type not available\n") }
                group.leave()
                continue
            }
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit,
                                      sortDescriptors: [sort]) { _, results, error in
                let samples = results as? [HKQuantitySample] ?? []
                var part = "[\(name)] \(samples.count) samples"
                if let e = error { part += " (error: \(e.localizedDescription))" }
                part += "\n"
                if !samples.isEmpty {
                    let show = min(5, samples.count)
                    for i in 0..<show {
                        let s = samples[i]
                        let val = s.quantity.doubleValue(for: unit)
                        part += "  [\(i)] \(s.startDate) → \(s.endDate): \(String(format: "%.4f", val)) \(unit)\n"
                    }
                    if samples.count > 10 {
                        part += "  ... (\(samples.count - 10) more) ...\n"
                        for i in (samples.count - 5)..<samples.count {
                            let s = samples[i]
                            let val = s.quantity.doubleValue(for: unit)
                            part += "  [\(i)] \(s.startDate) → \(s.endDate): \(String(format: "%.4f", val)) \(unit)\n"
                        }
                    }
                }
                part += "\n"
                serialQueue.sync { outputParts.append(part) }
                group.leave()
            }
            self.store.execute(query)
        }

        // Also check workout details
        group.enter()
        let workoutSort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let workoutQuery = HKSampleQuery(sampleType: HKObjectType.workoutType(), predicate: predicate,
                                         limit: 10, sortDescriptors: [workoutSort]) { _, results, error in
            let workouts = results as? [HKWorkout] ?? []
            var part = "[Workouts] \(workouts.count) found\n"
            if let e = error { part += "  error: \(e.localizedDescription)\n" }
            for (i, w) in workouts.enumerated() {
                part += "  [\(i)] \(w.workoutActivityType.rawValue) \(w.startDate) → \(w.endDate)\n"
                part += "       duration: \(String(format: "%.0f", w.duration))s\n"
                part += "       source: \(w.sourceRevision.source.name)\n"
            }
            part += "\n"
            serialQueue.sync { outputParts.append(part) }
            group.leave()
        }
        store.execute(workoutQuery)

        group.notify(queue: .main) {
            completion(outputParts.joined())
        }
    }
}
