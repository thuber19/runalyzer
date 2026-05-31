import Foundation
import Combine
import HealthKit

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

    var dateString: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: startDate)
    }

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

struct AppleRunData {
    var heartRateSamples: [TimestampedValue] = []
    var avgHeartRate: Double = 0
    var totalSteps: Int = 0
    var avgCadence: Double = 0
    var cadenceSamples: [TimestampedValue] = [] // cadence over time
    var distanceSamples: [TimestampedValue] = [] // cumulative distance over time
    var distanceMeters: Double = 0
    var activeCalories: Double = 0
    var distanceKm: Double { distanceMeters / 1000 }
}

class HealthKitManager: ObservableObject {
    let store = HKHealthStore()

    @Published var authorized = false
    @Published var workouts: [AppleWorkout] = []

    private let readTypes: Set<HKObjectType> = {
        var types = Set<HKObjectType>()
        types.insert(HKQuantityType.quantityType(forIdentifier: .heartRate)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .stepCount)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .distanceWalkingRunning)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .activeEnergyBurned)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .runningSpeed)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .runningStrideLength)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .runningVerticalOscillation)!)
        types.insert(HKQuantityType.quantityType(forIdentifier: .runningGroundContactTime)!)
        types.insert(HKObjectType.workoutType())
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
            }
        }
    }

    // MARK: - Fetch Recent Workouts
    func fetchRecentWorkouts() {
        print("Fetching recent workouts...")
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        let query = HKSampleQuery(
            sampleType: HKObjectType.workoutType(),
            predicate: nil,
            limit: 50,
            sortDescriptors: [sort]
        ) { _, results, error in
            print("Workout query returned \(results?.count ?? 0) results, error: \(String(describing: error))")
            let workouts = (results as? [HKWorkout] ?? []).map { w in
                AppleWorkout(id: w.uuid, workout: w)
            }
            DispatchQueue.main.async {
                self.workouts = workouts
            }
        }
        store.execute(query)
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
        fetchSamples(.stepCount, predicate: predicate) { samples in
            var totalSteps: Double = 0
            for s in samples {
                let steps = s.quantity.doubleValue(for: .count())
                let duration = s.endDate.timeIntervalSince(s.startDate)
                totalSteps += steps
                if duration > 0 {
                    let cadence = (steps / duration) * 60 // steps per minute
                    let midDate = s.startDate.addingTimeInterval(duration / 2)
                    result.cadenceSamples.append(TimestampedValue(date: midDate, value: cadence))
                }
            }
            result.totalSteps = Int(totalSteps)
            let totalDuration = endDate.timeIntervalSince(startDate) / 60
            result.avgCadence = totalDuration > 0 ? totalSteps / totalDuration : 0
            group.leave()
        }

        // Distance samples → track over time
        group.enter()
        fetchSamples(.distanceWalkingRunning, predicate: predicate) { samples in
            var cumDist: Double = 0
            for s in samples {
                let d = s.quantity.doubleValue(for: .meter())
                cumDist += d
                result.distanceSamples.append(TimestampedValue(date: s.endDate, value: cumDist))
            }
            result.distanceMeters = cumDist
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
