import Foundation
import HealthKit
import os

/// Imports raw HealthKit metrics as standalone daily .metric measurements.
/// Each metric type gets its own measurement per day. Supports intraday updates
/// (new HRV readings appended when the app reopens during the day).
class HealthKitMetricProvider {
    private weak var store: MeasurementStore?
    private weak var workoutStore: WorkoutStore?
    private let healthKit: HealthKitManager
    private let metricIndex: MetricIndex

    init(healthKit: HealthKitManager, store: MeasurementStore,
         workoutStore: WorkoutStore, metricIndex: MetricIndex) {
        self.healthKit = healthKit
        self.store = store
        self.workoutStore = workoutStore
        self.metricIndex = metricIndex
    }

    // MARK: - Public API

    /// Called on app foreground. Only fetches today + yesterday (recent data).
    /// Past days are stable and don't need re-importing.
    func importMissingMetrics(lookbackDays: Int = 2, completion: (() -> Void)? = nil) {
        importAll(lookbackDays: lookbackDays, completion: completion)
    }

    /// User-triggered backfill from Settings.
    func backfillMetrics(days: Int = 120, completion: (() -> Void)? = nil) {
        importAll(lookbackDays: days, completion: completion)
    }

    private func importAll(lookbackDays: Int, completion: (() -> Void)?) {
        let group = DispatchGroup()

        // Quantity metrics — each gets its own daily measurement.
        // HR samples are safe to import now — GRDB stores them in SQLite, not in memory.
        // Workouts query HR by time window from the same data_point table.
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let quantityMetrics: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
            (.heartRateVariabilitySDNN, HKUnit.secondUnit(with: .milli), DataType.hrvSDNN),
            (.restingHeartRate,         bpmUnit, DataType.restingHeartRate),
            (.heartRate,                bpmUnit, DataType.heartRateSample),
            (.oxygenSaturation,         HKUnit.percent(), DataType.bloodOxygen),
            (.bodyTemperature,          HKUnit.degreeCelsius(), DataType.bodyTemperature),
            (.vo2Max,                   HKUnit(from: "mL/kg*min"), DataType.vo2Max),
            (.stepCount,                HKUnit.count(), DataType.steps),
            (.distanceWalkingRunning,   HKUnit.meter(), DataType.distance),
        ]

        for (identifier, unit, dataType) in quantityMetrics {
            group.enter()
            importQuantityMetric(identifier: identifier, unit: unit, dataType: dataType,
                                 lookbackDays: lookbackDays) { group.leave() }
        }

        // Sleep (category type)
        group.enter()
        importSleepMetrics(lookbackDays: lookbackDays) { group.leave() }

        // Workouts (each workout = its own measurement)
        group.enter()
        importWorkouts(lookbackDays: lookbackDays) { group.leave() }

        group.notify(queue: .main) { completion?() }
    }

    // MARK: - Generic Quantity Metric Import

    private func importQuantityMetric(
        identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        dataType: String,
        lookbackDays: Int,
        completion: @escaping () -> Void
    ) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let rangeStart = cal.date(byAdding: .day, value: -lookbackDays, to: today) else {
            completion(); return
        }

        healthKit.fetchMetricSamples(
            identifier: identifier, unit: unit,
            from: rangeStart, to: Date()
        ) { [weak self] samples in
            guard let self, let store = self.store else { completion(); return }

            // For cumulative metrics (steps), aggregate per day instead of storing each sample
            let isCumulative = (identifier == .stepCount)

            var byDay: [Date: [(value: Double, timestamp: Date, sourceName: String)]] = [:]
            for s in samples {
                let day = cal.startOfDay(for: s.timestamp)
                byDay[day, default: []].append(s)
            }

            DispatchQueue.main.async {
                for (day, daySamples) in byDay {
                    if isCumulative {
                        // Steps: sum per SOURCE per day (not across sources — would double-count)
                        // Apple Health deduplicates by taking max of overlapping periods
                        var bySource: [String: Double] = [:]
                        for s in daySamples { bySource[s.sourceName, default: 0] += s.value }

                        // Store one DataPoint per source
                        var dps: [DataPoint] = []
                        for (source, total) in bySource.sorted(by: { $0.value > $1.value }) {
                            dps.append(DataPoint(timestamp: day, endTimestamp: nil,
                                                 type: dataType, value: total,
                                                 unit: unit.unitString, source: DataSource.healthKitSource(source),
                                                 role: .primary))
                        }
                        self.upsertMetric(day: day, dataType: dataType, dataPoints: dps,
                                          samples: daySamples, store: store, replaceFull: true)
                    } else {
                        // All other metrics: one DataPoint per reading
                        let dps = daySamples.map { s in
                            DataPoint(timestamp: s.timestamp, endTimestamp: nil,
                                      type: dataType, value: s.value,
                                      unit: unit.unitString, source: DataSource.healthKitSource(s.sourceName),
                                      role: .primary)
                        }
                        self.upsertMetric(day: day, dataType: dataType, dataPoints: dps,
                                          samples: daySamples, store: store, replaceFull: false)
                    }
                }
                completion()
            }
        }
    }

    /// Upsert a daily metric measurement. If replaceFull is true (cumulative metrics like steps),
    /// replaces all DataPoints. Otherwise merges new readings (dedup by timestamp).
    private func upsertMetric(
        day: Date,
        dataType: String,
        dataPoints: [DataPoint],
        samples: [(value: Double, timestamp: Date, sourceName: String)],
        store: MeasurementStore,
        replaceFull: Bool
    ) {
        guard !dataPoints.isEmpty else { return }

        let sourceNames = Set(samples.map(\.sourceName))
        let sources = sourceNames.map { MeasurementSource.healthKitDevice(name: $0) }

        if var existing = metricIndex.metricMeasurement(forDay: day, containingType: dataType) {
            if replaceFull {
                // Cumulative: replace all DataPoints of this type
                existing.dataPoints.removeAll { $0.type == dataType }
                existing.dataPoints.append(contentsOf: dataPoints)
                store.update(existing)
            } else {
                // Merge: dedup by timestamp (millisecond precision to avoid floating-point mismatches)
                let existingTimestamps = Set(existing.dataPoints.map { Int($0.timestamp.timeIntervalSince1970 * 1000) })
                let newPoints = dataPoints.filter { !existingTimestamps.contains(Int($0.timestamp.timeIntervalSince1970 * 1000)) }
                guard !newPoints.isEmpty else { return }
                existing.dataPoints.append(contentsOf: newPoints)
                existing.dataPoints.sort { $0.timestamp < $1.timestamp }
                store.update(existing)
            }
        } else {
            let measurement = SensorMeasurement(
                id: UUID(), date: day, type: .metric,
                sources: sources, dataPoints: dataPoints, rawDataFiles: []
            )
            store.save(measurement)
        }
    }

    // MARK: - Sleep Import (category type — separate from quantity metrics)

    private func importSleepMetrics(lookbackDays: Int, completion: @escaping () -> Void) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let rangeStart = cal.date(byAdding: .day, value: -lookbackDays, to: today) else {
            completion(); return
        }

        healthKit.fetchSleepSamples(from: rangeStart, to: Date()) { [weak self] samples in
            guard let self, let store = self.store else { completion(); return }

            // Assign sleep to "sleep night" — stages starting after 6pm belong to the next day.
            // This matches how Apple Health groups a night's sleep (e.g., 10pm Jun 7 → 7am Jun 8 = Jun 8's sleep).
            var byDay: [Date: [(stage: String, value: Double, start: Date, end: Date, sourceName: String)]] = [:]
            for s in samples {
                let startHour = cal.component(.hour, from: s.start)
                let assignDate: Date
                if startHour >= 18 {
                    // Evening: belongs to next day's sleep
                    assignDate = cal.startOfDay(for: cal.date(byAdding: .day, value: 1, to: s.start) ?? s.end)
                } else {
                    // Morning/afternoon: belongs to today
                    assignDate = cal.startOfDay(for: s.start)
                }
                byDay[assignDate, default: []].append(s)
            }

            DispatchQueue.main.async {
                for (day, stages) in byDay {
                    let dps = stages.map { s in
                        DataPoint(timestamp: s.start, endTimestamp: s.end,
                                  type: DataType.sleepStage, value: s.value,
                                  unit: s.stage, source: DataSource.healthKitSource(s.sourceName),
                                  role: .primary)
                    }
                    guard !dps.isEmpty else { continue }

                    let sourceNames = Set(stages.map(\.sourceName))
                    let sources = sourceNames.map { MeasurementSource.healthKitDevice(name: $0) }

                    if var existing = self.metricIndex.metricMeasurement(forDay: day, containingType: DataType.sleepStage) {
                        // Merge: dedup by (timestamp + stage) to avoid duplicates without wiping existing data
                        let existingKeys = Set(existing.dataPoints.filter { $0.type == DataType.sleepStage }.map {
                            "\(Int($0.timestamp.timeIntervalSince1970))-\($0.unit)"
                        })
                        let newPoints = dps.filter {
                            !existingKeys.contains("\(Int($0.timestamp.timeIntervalSince1970))-\($0.unit)")
                        }
                        guard !newPoints.isEmpty else { continue }
                        existing.dataPoints.append(contentsOf: newPoints)
                        existing.dataPoints.sort { $0.timestamp < $1.timestamp }
                        store.update(existing)
                    } else {
                        let measurement = SensorMeasurement(
                            id: UUID(), date: day, type: .metric,
                            sources: sources, dataPoints: dps, rawDataFiles: []
                        )
                        store.save(measurement)
                    }
                }
                completion()
            }
        }
    }

    // MARK: - Workout Import (now writes to WorkoutStore)

    private func importWorkouts(lookbackDays: Int, completion: @escaping () -> Void) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let rangeStart = cal.date(byAdding: .day, value: -lookbackDays, to: today) else {
            completion(); return
        }

        healthKit.fetchWorkoutsWithDetails(from: rangeStart, to: Date()) { [weak self] workouts in
            guard let self, let workoutStore = self.workoutStore else { completion(); return }

            DispatchQueue.main.async {
                // Dedup against existing workouts by HealthKit UUID
                let existingIDs = workoutStore.existingHKWorkoutIDs()

                var newWorkouts: [(workout: Workout, dataPoints: [DataPoint])] = []

                for w in workouts {
                    let hkID = w.id.uuidString
                    guard !existingIDs.contains(hkID) else { continue }

                    let src = DataSource.healthKitSource(w.sourceName)
                    let distanceActivities: Set<String> = [
                        "Run", "Walk", "Cycle", "Hike", "Swim", "Rowing",
                        "Elliptical", "Skating", "Cross Training", "HIIT"
                    ]
                    let distance = (w.distanceKm > 0.1 && distanceActivities.contains(w.activityName))
                        ? w.distanceKm : nil

                    let workout = Workout(
                        id: UUID(),
                        startDate: w.startDate,
                        endDate: w.endDate,
                        activityType: w.activityName,
                        source: src,
                        durationSec: w.duration,
                        distanceKm: distance,
                        calories: w.calories > 0 ? w.calories : nil,
                        avgHR: w.avgHeartRate > 0 ? w.avgHeartRate : nil,
                        maxHR: w.maxHeartRate > 0 ? w.maxHeartRate : nil,
                        hkWorkoutId: w.id,
                        rawDataFiles: [],
                        linkedWorkoutId: nil
                    )

                    newWorkouts.append((workout: workout, dataPoints: []))
                }

                if !newWorkouts.isEmpty {
                    workoutStore.saveBatch(newWorkouts)
                    AppLogger.health.info("Imported \(newWorkouts.count) workouts")
                }

                // Import cadence for each workout (derived from step intervals — not covered by daily import).
                // HR and distance are already imported as daily metrics.
                self.importWorkoutCadence(newWorkouts.map(\.workout), completion: completion)
            }
        }
    }

    /// Import workout-specific metrics: cadence (from step intervals) and
    /// running speed (Apple's pre-calculated GPS+sensor speed).
    /// These only make sense during workouts, not as daily metrics.
    private func importWorkoutCadence(_ workouts: [Workout], completion: @escaping () -> Void) {
        guard let store = self.store, !workouts.isEmpty else { completion(); return }
        let cal = Calendar.current
        let group = DispatchGroup()
        let collectQueue = DispatchQueue(label: "workout.metrics")
        var allPoints: [(day: Date, type: String, points: [DataPoint])] = []

        for w in workouts {
            let predicate = HKQuery.predicateForSamples(
                withStart: w.startDate, end: w.endDate, options: .strictStartDate)

            // Cadence from step count intervals
            group.enter()
            healthKit.fetchStepSamples(predicate: predicate) { stepSamples in
                var points: [DataPoint] = []
                for s in stepSamples {
                    let dur = s.endDate.timeIntervalSince(s.startDate)
                    guard dur > 0 else { continue }
                    let steps = s.quantity.doubleValue(for: .count())
                    let cadence = (steps / dur) * 60
                    let src = DataSource.healthKitSource(s.sourceRevision.source.name)
                    points.append(DataPoint(
                        timestamp: s.startDate.addingTimeInterval(dur / 2), endTimestamp: nil,
                        type: DataType.cadence, value: cadence,
                        unit: "spm", source: src, role: .detail
                    ))
                }
                if !points.isEmpty {
                    let day = cal.startOfDay(for: w.startDate)
                    collectQueue.sync { allPoints.append((day: day, type: DataType.cadence, points: points)) }
                }
                group.leave()
            }

            // Running speed (Apple's pre-calculated m/s from GPS+sensors)
            group.enter()
            healthKit.fetchRunningSpeedSamples(predicate: predicate) { speedSamples in
                let speedUnit = HKUnit.meter().unitDivided(by: .second())
                var points: [DataPoint] = []
                for s in speedSamples {
                    let mps = s.quantity.doubleValue(for: speedUnit)
                    let src = DataSource.healthKitSource(s.sourceRevision.source.name)
                    points.append(DataPoint(
                        timestamp: s.startDate, endTimestamp: nil,
                        type: DataType.runningSpeed, value: mps,
                        unit: "m/s", source: src, role: .detail
                    ))
                }
                if !points.isEmpty {
                    let day = cal.startOfDay(for: w.startDate)
                    collectQueue.sync { allPoints.append((day: day, type: DataType.runningSpeed, points: points)) }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            let metricIndex = MetricIndex(store: store)
            for (day, dataType, points) in allPoints {
                if let existing = metricIndex.metricMeasurement(forDay: day, containingType: dataType) {
                    store.appendDataPoints(points, to: existing.id)
                } else {
                    let measurement = SensorMeasurement(
                        id: UUID(), date: day, type: .metric,
                        sources: [], dataPoints: points, rawDataFiles: []
                    )
                    store.save(measurement)
                }
            }
            completion()
        }
    }
}
