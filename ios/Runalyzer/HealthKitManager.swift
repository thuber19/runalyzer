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

    var dateString: String { DateFormatters.mediumDateTime.string(from: startDate) }

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
        guard let type = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning) else { return 0 }
        let stats = workout.statistics(for: type)
        return (stats?.sumQuantity()?.doubleValue(for: .meter()) ?? 0) / 1000
    }

    var calories: Double {
        guard let type = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned) else { return 0 }
        let stats = workout.statistics(for: type)
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
        let quantityIDs: [HKQuantityTypeIdentifier] = [
            .heartRate, .stepCount, .distanceWalkingRunning, .distanceCycling,
            .activeEnergyBurned, .heartRateVariabilitySDNN, .restingHeartRate,
            .oxygenSaturation, .bodyTemperature, .vo2Max,
            .runningSpeed
        ]
        for id in quantityIDs {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { types.insert(t) }
        }
        types.insert(HKObjectType.workoutType())
        if let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) { types.insert(sleep) }
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

    // MARK: - Public Sample Fetch

    /// Fetch raw step count samples within a predicate. Used for cadence derivation.
    func fetchStepSamples(predicate: NSPredicate, completion: @escaping ([HKQuantitySample]) -> Void) {
        fetchSamples(.stepCount, predicate: predicate, completion: completion)
    }

    /// Fetch Apple's pre-calculated running speed samples (m/s). Used for pace/speed in workout detail.
    func fetchRunningSpeedSamples(predicate: NSPredicate, completion: @escaping ([HKQuantitySample]) -> Void) {
        fetchSamples(.runningSpeed, predicate: predicate, completion: completion)
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
        guard let todayNoon = cal.date(from: noonComps) else { return }
        let windowEnd = min(todayNoon, now)

        // Window start: 8pm yesterday
        var eveningComps = cal.dateComponents([.year, .month, .day], from: now.addingTimeInterval(-86400))
        eveningComps.hour = 20
        guard let windowStart = cal.date(from: eveningComps) else { return }

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

    // MARK: - Legacy Stress Methods (deprecated — use MetricIndex + RecoveryScore)

    /// Fetch raw inputs for stress computation over the requested number of days,
    /// plus an extra 30-day window used solely for baseline calculation.
    /// Calls back on the main queue with one entry per calendar day (oldest first).
    func fetchStressHistory(days: Int, completion: @escaping ([RecoveryScore.DayInputs]) -> Void) {
        let cal = Calendar.current
        let now = Date()
        let totalDays = days + RecoveryScore.baselineWindowDays
        guard let rangeStart = cal.date(byAdding: .day, value: -totalDays,
                                        to: cal.startOfDay(for: now)) else {
            completion([]); return
        }

        let predicate = HKQuery.predicateForSamples(withStart: rangeStart, end: now,
                                                    options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let group = DispatchGroup()

        // Each tuple carries the HK source name from sourceRevision.source.name
        var allSDNN: [(date: Date, value: Double, sourceName: String)] = []
        var allRHR:  [(date: Date, value: Double, sourceName: String)] = []

        // SDNN samples (ms) — with source name from HealthKit
        group.enter()
        if let sdnnType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            let unit = HKUnit.secondUnit(with: .milli)
            let q = HKSampleQuery(sampleType: sdnnType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error { AppLogger.health.error("SDNN query: \(error.localizedDescription)") }
                allSDNN = (results as? [HKQuantitySample] ?? []).map {
                    (date: $0.startDate,
                     value: $0.quantity.doubleValue(for: unit),
                     sourceName: $0.sourceRevision.source.name)
                }
                group.leave()
            }
            store.execute(q)
        } else { group.leave() }

        // Resting HR (bpm) — Apple Watch computes this nightly
        group.enter()
        if let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let q = HKSampleQuery(sampleType: rhrType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
                if let error { AppLogger.health.error("RHR query: \(error.localizedDescription)") }
                allRHR = (results as? [HKQuantitySample] ?? []).map {
                    (date: $0.startDate,
                     value: $0.quantity.doubleValue(for: bpmUnit),
                     sourceName: $0.sourceRevision.source.name)
                }
                group.leave()
            }
            store.execute(q)
        } else { group.leave() }

        group.notify(queue: .global(qos: .userInitiated)) {
            // Group SDNN by day — ALL readings (algorithms filter as needed)
            var sdnnByDay: [Date: [(value: Double, sourceName: String)]] = [:]
            for s in allSDNN {
                let day = cal.startOfDay(for: s.date)
                sdnnByDay[day, default: []].append((value: s.value, sourceName: s.sourceName))
            }

            // Group RHR by day — keep the minimum value and its source
            var rhrByDay: [Date: (value: Double, sourceName: String)] = [:]
            for r in allRHR {
                let day = cal.startOfDay(for: r.date)
                if let existing = rhrByDay[day] {
                    if r.value < existing.value {
                        rhrByDay[day] = (value: r.value, sourceName: r.sourceName)
                    }
                } else {
                    rhrByDay[day] = (value: r.value, sourceName: r.sourceName)
                }
            }

            // Build ordered array: one entry per calendar day from rangeStart to today
            var inputs: [RecoveryScore.DayInputs] = []
            var cursor = rangeStart
            let tomorrow = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
            while cursor < tomorrow {
                let rhrEntry = rhrByDay[cursor]
                inputs.append(RecoveryScore.DayInputs(
                    date: cursor,
                    sdnnSamples: sdnnByDay[cursor] ?? [],
                    restingHR: rhrEntry?.value,
                    restingHRSource: rhrEntry?.sourceName
                ))
                cursor = cal.date(byAdding: .day, value: 1, to: cursor)!
            }

            DispatchQueue.main.async { completion(inputs) }
        }
    }

    /// Fetch stress inputs for a single day (lightweight — for incremental daily computation).
    func fetchStressInputsForDay(_ date: Date, completion: @escaping (RecoveryScore.DayInputs) -> Void) {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: date)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else {
            completion(RecoveryScore.DayInputs(date: dayStart, sdnnSamples: [], restingHR: nil, restingHRSource: nil))
            return
        }

        let predicate = HKQuery.predicateForSamples(withStart: dayStart, end: dayEnd, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let group = DispatchGroup()

        var sdnnSamples: [(value: Double, sourceName: String)] = []
        var rhrValue: Double? = nil
        var rhrSource: String? = nil

        group.enter()
        if let sdnnType = HKQuantityType.quantityType(forIdentifier: .heartRateVariabilitySDNN) {
            let unit = HKUnit.secondUnit(with: .milli)
            let q = HKSampleQuery(sampleType: sdnnType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, _ in
                sdnnSamples = (results as? [HKQuantitySample] ?? [])
                    .filter { cal.component(.hour, from: $0.startDate) >= 6 &&
                              cal.component(.hour, from: $0.startDate) < 23 }
                    .map { (value: $0.quantity.doubleValue(for: unit),
                            sourceName: $0.sourceRevision.source.name) }
                group.leave()
            }
            store.execute(q)
        } else { group.leave() }

        group.enter()
        if let rhrType = HKQuantityType.quantityType(forIdentifier: .restingHeartRate) {
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let q = HKSampleQuery(sampleType: rhrType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, _ in
                if let samples = results as? [HKQuantitySample],
                   let best = samples.min(by: { $0.quantity.doubleValue(for: bpmUnit) < $1.quantity.doubleValue(for: bpmUnit) }) {
                    rhrValue = best.quantity.doubleValue(for: bpmUnit)
                    rhrSource = best.sourceRevision.source.name
                }
                group.leave()
            }
            store.execute(q)
        } else { group.leave() }

        group.notify(queue: .main) {
            completion(RecoveryScore.DayInputs(
                date: dayStart, sdnnSamples: sdnnSamples,
                restingHR: rhrValue, restingHRSource: rhrSource
            ))
        }
    }

    // MARK: - Workout Details Fetch

    struct WorkoutDetail {
        let id: UUID
        let startDate: Date
        let endDate: Date
        let duration: Double
        let activityName: String
        let distanceKm: Double
        let calories: Double
        let avgHeartRate: Double
        let maxHeartRate: Double
        let sourceName: String
    }

    /// Fetch workouts with HR samples and statistics. Calls back on a background queue.
    func fetchWorkoutsWithDetails(
        from startDate: Date, to endDate: Date,
        completion: @escaping ([WorkoutDetail]) -> Void
    ) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: predicate,
            limit: HKObjectQueryNoLimit,
            sortDescriptors: [sort]
        ) { _, results, error in
            if let error { AppLogger.health.error("Workouts query: \(error.localizedDescription)") }
            let workouts = results as? [HKWorkout] ?? []
            AppLogger.health.info("Fetched \(workouts.count) workouts from HealthKit")
            guard !workouts.isEmpty else { completion([]); return }

            // Build details from workout statistics (no per-workout HR query — too slow for bulk import)
            let bpmUnit = HKUnit.count().unitDivided(by: .minute())
            let details: [WorkoutDetail] = workouts.map { w in
                let activityName = Self.workoutActivityName(w.workoutActivityType)

                // Try walking/running distance first, then cycling distance
                let walkDist = HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning).flatMap { w.statistics(for: $0) }
                let cycleDist = HKQuantityType.quantityType(forIdentifier: .distanceCycling).flatMap { w.statistics(for: $0) }
                let distMeters = (walkDist?.sumQuantity()?.doubleValue(for: .meter()) ?? 0)
                    + (cycleDist?.sumQuantity()?.doubleValue(for: .meter()) ?? 0)
                let calStats = HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned).flatMap { w.statistics(for: $0) }
                let hrStats = HKQuantityType.quantityType(forIdentifier: .heartRate).flatMap { w.statistics(for: $0) }

                return WorkoutDetail(
                    id: w.uuid,
                    startDate: w.startDate,
                    endDate: w.endDate,
                    duration: w.duration,
                    activityName: activityName,
                    distanceKm: distMeters / 1000,
                    calories: calStats?.sumQuantity()?.doubleValue(for: .kilocalorie()) ?? 0,
                    avgHeartRate: hrStats?.averageQuantity()?.doubleValue(for: bpmUnit) ?? 0,
                    maxHeartRate: hrStats?.maximumQuantity()?.doubleValue(for: bpmUnit) ?? 0,
                    sourceName: w.sourceRevision.source.name
                )
            }

            completion(details)
        }
        store.execute(query)
    }

    /// Fetch time-series data (HR, cadence, distance) for a single workout.
    /// Used to enrich workout measurements after bulk import.
    func fetchWorkoutTimeSeries(
        from startDate: Date, to endDate: Date,
        completion: @escaping ([(type: String, samples: [TimestampedValue])]) -> Void
    ) {
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let group = DispatchGroup()

        var hrSamples: [TimestampedValue] = []
        var cadenceSamples: [TimestampedValue] = []
        var distanceSamples: [TimestampedValue] = []

        // Heart rate — deduplicate by source (prefer source with most samples to avoid iPhone+Watch duplicates)
        group.enter()
        fetchSamples(.heartRate, predicate: predicate) { samples in
            var bySource: [String: [HKQuantitySample]] = [:]
            for s in samples { bySource[s.sourceRevision.source.name, default: []].append(s) }
            let bestSource = bySource.max(by: { $0.value.count < $1.value.count })?.value ?? []
            hrSamples = bestSource.map { TimestampedValue(date: $0.startDate, value: $0.quantity.doubleValue(for: bpmUnit)) }
            group.leave()
        }

        // Step cadence (steps per interval → cadence SPM)
        group.enter()
        fetchSamples(.stepCount, predicate: predicate) { samples in
            cadenceSamples = samples.compactMap { s in
                let dur = s.endDate.timeIntervalSince(s.startDate)
                guard dur > 0 else { return nil }
                let steps = s.quantity.doubleValue(for: .count())
                return TimestampedValue(date: s.startDate.addingTimeInterval(dur / 2), value: (steps / dur) * 60)
            }
            group.leave()
        }

        // Cumulative distance
        group.enter()
        fetchSamples(.distanceWalkingRunning, predicate: predicate) { samples in
            var cumDist: Double = 0
            distanceSamples = samples.map { s in
                cumDist += s.quantity.doubleValue(for: .meter())
                return TimestampedValue(date: s.endDate, value: cumDist / 1000)  // km
            }
            group.leave()
        }

        group.notify(queue: .global(qos: .userInitiated)) {
            var result: [(type: String, samples: [TimestampedValue])] = []
            if !hrSamples.isEmpty { result.append((type: DataType.heartRateSample, samples: hrSamples)) }
            if !cadenceSamples.isEmpty { result.append((type: DataType.cadence, samples: cadenceSamples)) }
            if !distanceSamples.isEmpty { result.append((type: DataType.workoutDistance, samples: distanceSamples)) }
            completion(result)
        }
    }

    static func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "Run"
        case .walking: return "Walk"
        case .cycling: return "Cycle"
        case .hiking: return "Hike"
        case .swimming: return "Swim"
        case .yoga: return "Yoga"
        case .functionalStrengthTraining: return "Strength"
        case .traditionalStrengthTraining: return "Weight Training"
        case .highIntensityIntervalTraining: return "HIIT"
        case .coreTraining: return "Core"
        case .elliptical: return "Elliptical"
        case .rowing: return "Rowing"
        case .stairClimbing: return "Stairs"
        case .crossTraining: return "Cross Training"
        case .mixedCardio: return "Mixed Cardio"
        case .pilates: return "Pilates"
        case .dance: return "Dance"
        case .cooldown: return "Cooldown"
        case .mindAndBody: return "Mind & Body"
        case .flexibility: return "Flexibility"
        case .kickboxing: return "Kickboxing"
        case .boxing: return "Boxing"
        case .jumpRope: return "Jump Rope"
        case .skatingSports: return "Skating"
        case .snowSports: return "Snow Sports"
        case .surfingSports: return "Surfing"
        case .tennis: return "Tennis"
        case .tableTennis: return "Table Tennis"
        case .badminton: return "Badminton"
        case .soccer: return "Soccer"
        case .basketball: return "Basketball"
        case .volleyball: return "Volleyball"
        case .golf: return "Golf"
        case .climbing: return "Climbing"
        case .other: return "Other"
        default:
            // Convert the raw value to a readable string for any type we didn't list
            let raw = String(describing: type)
            return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    // MARK: - Sleep Samples Fetch

    /// Fetch sleep analysis samples with stage info. Calls back on a background queue.
    func fetchSleepSamples(
        from startDate: Date, to endDate: Date,
        completion: @escaping ([(stage: String, value: Double, start: Date, end: Date, sourceName: String)]) -> Void
    ) {
        guard let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) else {
            completion([]); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: sleepType, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
            if let error { AppLogger.health.error("Sleep samples: \(error.localizedDescription)") }
            let samples = (results as? [HKCategorySample] ?? []).compactMap { s -> (stage: String, value: Double, start: Date, end: Date, sourceName: String)? in
                let stage: String
                let value: Double
                switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                case .inBed:                         stage = "InBed";   value = 0
                case .asleepUnspecified, .asleep:     stage = "Asleep";  value = 1
                case .awake:                          stage = "Awake";   value = 2
                case .asleepCore:                     stage = "Core";    value = 3
                case .asleepDeep:                     stage = "Deep";    value = 4
                case .asleepREM:                      stage = "REM";     value = 5
                default: return nil
                }
                return (stage: stage, value: value, start: s.startDate, end: s.endDate,
                        sourceName: s.sourceRevision.source.name)
            }
            completion(samples)
        }
        store.execute(query)
    }

    // MARK: - Generic Metric Fetch

    /// Fetch samples of any HK quantity type. Returns timestamped values with source names.
    /// Calls back on a background queue — caller is responsible for dispatching to main.
    func fetchMetricSamples(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        from startDate: Date,
        to endDate: Date,
        completion: @escaping ([(value: Double, timestamp: Date, sourceName: String)]) -> Void
    ) {
        guard let type = HKQuantityType.quantityType(forIdentifier: identifier) else {
            completion([]); return
        }
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
        let query = HKSampleQuery(sampleType: type, predicate: predicate,
                                  limit: HKObjectQueryNoLimit, sortDescriptors: [sort]) { _, results, error in
            if let error { AppLogger.health.error("fetchMetricSamples \(identifier.rawValue): \(error.localizedDescription)") }
            let samples = (results as? [HKQuantitySample] ?? []).map {
                (value: $0.quantity.doubleValue(for: unit),
                 timestamp: $0.startDate,
                 sourceName: $0.sourceRevision.source.name)
            }
            completion(samples)
        }
        store.execute(query)
    }

    // MARK: - Debug: dump all data types available for a time range
    #if DEBUG
    func debugDump(from startDate: Date, to endDate: Date, completion: @escaping (String) -> Void) {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let serialQueue = DispatchQueue(label: "healthkit.debug")
        var outputParts: [String] = ["=== HEALTH DATA DEBUG DUMP ===\nRange: \(startDate) to \(endDate)\n\n"]

        let typesToCheck: [(String, HKQuantityTypeIdentifier, HKUnit)] = [
            ("Heart Rate", .heartRate, HKUnit.count().unitDivided(by: .minute())),
            ("HRV SDNN", .heartRateVariabilitySDNN, HKUnit.secondUnit(with: .milli)),
            ("Resting Heart Rate", .restingHeartRate, HKUnit.count().unitDivided(by: .minute())),
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

        // Sleep analysis (HKCategoryType — separate from quantity types above)
        group.enter()
        if let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis) {
            let sleepSort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)
            let sleepQuery = HKSampleQuery(sampleType: sleepType, predicate: predicate,
                                           limit: HKObjectQueryNoLimit, sortDescriptors: [sleepSort]) { _, results, error in
                let samples = results as? [HKCategorySample] ?? []
                var part = "[Sleep Analysis] \(samples.count) samples"
                if let e = error { part += " (error: \(e.localizedDescription))" }
                part += "\n"
                for s in samples.prefix(10) {
                    let stage: String
                    switch HKCategoryValueSleepAnalysis(rawValue: s.value) {
                    case .inBed:              stage = "InBed"
                    case .asleepCore:         stage = "Core"
                    case .asleepREM:          stage = "REM"
                    case .asleepDeep:         stage = "Deep"
                    case .awake:              stage = "Awake"
                    case .asleepUnspecified, .asleep: stage = "Asleep"
                    default:                  stage = "Unknown(\(s.value))"
                    }
                    let dur = Int(s.endDate.timeIntervalSince(s.startDate) / 60)
                    part += "  \(stage) \(s.startDate) → \(s.endDate) (\(dur)min) [\(s.sourceRevision.source.name)]\n"
                }
                if samples.count > 10 { part += "  ... (\(samples.count - 10) more)\n" }
                part += "\n"
                serialQueue.sync { outputParts.append(part) }
                group.leave()
            }
            store.execute(sleepQuery)
        } else { group.leave() }

        group.notify(queue: .main) {
            completion(outputParts.joined())
        }
    }
    #endif
}
