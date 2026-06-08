import Foundation
import HealthKit
import os

/// Imports raw HealthKit metrics as standalone daily .metric measurements.
/// Each metric type gets its own measurement per day. Supports intraday updates
/// (new HRV readings appended when the app reopens during the day).
class HealthKitMetricProvider {
    private weak var store: MeasurementStore?
    private let healthKit: HealthKitManager
    private let metricIndex: MetricIndex

    init(healthKit: HealthKitManager, store: MeasurementStore, metricIndex: MetricIndex) {
        self.healthKit = healthKit
        self.store = store
        self.metricIndex = metricIndex
    }

    // MARK: - Public API

    /// Called on app foreground. Imports all missing metrics + intraday updates.
    func importMissingMetrics(lookbackDays: Int = 7, completion: (() -> Void)? = nil) {
        importAll(lookbackDays: lookbackDays, completion: completion)
    }

    /// User-triggered backfill from Settings.
    func backfillMetrics(days: Int = 120, completion: (() -> Void)? = nil) {
        importAll(lookbackDays: days, completion: completion)
    }

    private func importAll(lookbackDays: Int, completion: (() -> Void)?) {
        let group = DispatchGroup()

        // Quantity metrics — each gets its own daily measurement
        let bpmUnit = HKUnit.count().unitDivided(by: .minute())
        let quantityMetrics: [(HKQuantityTypeIdentifier, HKUnit, String)] = [
            (.heartRateVariabilitySDNN, HKUnit.secondUnit(with: .milli), DataType.hrvSDNN),
            (.restingHeartRate,         bpmUnit, DataType.restingHeartRate),
            (.heartRate,                bpmUnit, DataType.heartRateSample),
            (.oxygenSaturation,         HKUnit.percent(), DataType.bloodOxygen),
            (.bodyTemperature,          HKUnit.degreeCelsius(), DataType.bodyTemperature),
            (.vo2Max,                   HKUnit(from: "mL/kg*min"), DataType.vo2Max),
            (.stepCount,                HKUnit.count(), DataType.steps),
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
                        // Steps: sum per day, single DataPoint
                        let total = daySamples.map(\.value).reduce(0, +)
                        let sourceName = daySamples.first?.sourceName ?? "Apple Watch"
                        self.upsertMetric(day: day, dataType: dataType, dataPoints: [
                            DataPoint(timestamp: day, endTimestamp: nil,
                                      type: dataType, value: total,
                                      unit: unit.unitString, source: DataSource.healthKitSource(sourceName),
                                      role: .primary)
                        ], samples: daySamples, store: store, replaceFull: true)
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

            // Deduplicate: prefer Apple Watch source. Multiple apps/devices write overlapping
            // sleep data — we pick one source per night to avoid double-counting.
            let preferWatch = samples.filter { $0.sourceName.lowercased().contains("watch") }
            let dedupedSamples = preferWatch.isEmpty ? samples : preferWatch

            // Group by night (assign to the day of endDate = wake-up day)
            var byDay: [Date: [(stage: String, value: Double, start: Date, end: Date, sourceName: String)]] = [:]
            for s in dedupedSamples {
                let day = cal.startOfDay(for: s.end)
                byDay[day, default: []].append(s)
            }

            DispatchQueue.main.async {
                for (day, stages) in byDay {
                    guard self.metricIndex.metricMeasurement(forDay: day, containingType: DataType.sleepStage) == nil else { continue }

                    let dps = stages.map { s in
                        DataPoint(timestamp: s.start, endTimestamp: s.end,
                                  type: DataType.sleepStage, value: s.value,
                                  unit: s.stage, source: DataSource.healthKitSource(s.sourceName),
                                  role: .primary)
                    }
                    guard !dps.isEmpty else { continue }

                    let sourceNames = Set(stages.map(\.sourceName))
                    let sources = sourceNames.map { MeasurementSource.healthKitDevice(name: $0) }
                    let measurement = SensorMeasurement(
                        id: UUID(), date: day, type: .metric,
                        sources: sources, dataPoints: dps, rawDataFiles: []
                    )
                    store.save(measurement)
                }
                completion()
            }
        }
    }

    // MARK: - Workout Import (each workout = its own measurement)

    private func importWorkouts(lookbackDays: Int, completion: @escaping () -> Void) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let rangeStart = cal.date(byAdding: .day, value: -lookbackDays, to: today) else {
            completion(); return
        }

        // Phase 1: Fetch workout summaries (fast — uses workout statistics, no per-workout queries)
        healthKit.fetchWorkoutsWithDetails(from: rangeStart, to: Date()) { [weak self] workouts in
            guard let self, let store = self.store else { completion(); return }

            DispatchQueue.main.async {
                // Check both .hkWorkout and legacy .metric workouts for dedup
                let existingWorkoutIDs = Set(
                    store.measurements
                        .filter { $0.type == .hkWorkout || $0.type == .metric }
                        .compactMap { m in
                            m.sources.first(where: { $0.serialNumber?.hasPrefix("hk:") == true })?.serialNumber
                        }
                )

                // Build summary measurements for new workouts
                var newMeasurements: [SensorMeasurement] = []
                var newWorkoutDetails: [(id: UUID, start: Date, end: Date, src: String)] = []

                for w in workouts {
                    let hkID = DataSource.healthKit(w.id)
                    guard !existingWorkoutIDs.contains(hkID) else { continue }

                    var dp: [DataPoint] = []
                    let src = DataSource.healthKitSource(w.sourceName)

                    dp.append(DataPoint(timestamp: w.startDate, endTimestamp: w.endDate,
                                        type: DataType.workoutType, value: 0,
                                        unit: w.activityName, source: src, role: .primary))
                    dp.append(DataPoint(timestamp: w.startDate, endTimestamp: w.endDate,
                                        type: DataType.workoutDuration, value: w.duration,
                                        unit: "s", source: src, role: .primary))
                    let distanceActivities: Set<String> = ["Run", "Walk", "Cycle", "Hike", "Swim", "Rowing", "Elliptical", "Skating", "Cross Training"]
                    if w.distanceKm > 0.1 && distanceActivities.contains(w.activityName) {
                        dp.append(DataPoint(timestamp: w.startDate, endTimestamp: w.endDate,
                                            type: DataType.workoutDistance, value: w.distanceKm,
                                            unit: "km", source: src, role: .primary))
                    }
                    if w.calories > 0 {
                        dp.append(DataPoint(timestamp: w.startDate, endTimestamp: w.endDate,
                                            type: DataType.workoutCalories, value: w.calories,
                                            unit: "kcal", source: src, role: .detail))
                    }
                    if w.avgHeartRate > 0 {
                        dp.append(DataPoint(timestamp: w.startDate, endTimestamp: w.endDate,
                                            type: DataType.workoutAvgHR, value: w.avgHeartRate,
                                            unit: "bpm", source: src, role: .primary))
                    }
                    if w.maxHeartRate > 0 {
                        dp.append(DataPoint(timestamp: w.startDate, endTimestamp: w.endDate,
                                            type: DataType.workoutMaxHR, value: w.maxHeartRate,
                                            unit: "bpm", source: src, role: .detail))
                    }

                    let measID = UUID()
                    let hkSource = MeasurementSource.healthKit(workoutID: w.id, name: w.activityName)
                    let measurement = SensorMeasurement(
                        id: measID, date: w.startDate, type: .hkWorkout,
                        sources: [hkSource, MeasurementSource.healthKitDevice(name: w.sourceName)],
                        dataPoints: dp, rawDataFiles: []
                    )
                    newMeasurements.append(measurement)
                    newWorkoutDetails.append((id: measID, start: w.startDate, end: w.endDate, src: w.sourceName))
                }

                if !newMeasurements.isEmpty {
                    store.saveBatch(newMeasurements)
                    AppLogger.health.info("Imported \(newMeasurements.count) workout summaries")
                }

                // Phase 2: Enrich with time-series data (HR, cadence, distance)
                self.enrichWorkoutsWithTimeSeries(newWorkoutDetails, store: store) {
                    completion()
                }
            }
        }
    }

    /// Enrich workout measurements with time-series data (HR, cadence, distance).
    /// Fetches all in parallel via DispatchGroup, then applies all updates in one saveIndex.
    private func enrichWorkoutsWithTimeSeries(
        _ workouts: [(id: UUID, start: Date, end: Date, src: String)],
        store: MeasurementStore,
        completion: @escaping () -> Void
    ) {
        guard !workouts.isEmpty else { completion(); return }

        let group = DispatchGroup()
        let collectQueue = DispatchQueue(label: "workout.enrich")
        var enrichments: [(id: UUID, points: [DataPoint])] = []

        for w in workouts {
            group.enter()
            healthKit.fetchWorkoutTimeSeries(from: w.start, to: w.end) { series in
                var points: [DataPoint] = []
                let src = DataSource.healthKitSource(w.src)
                for (type, samples) in series {
                    let unit: String
                    switch type {
                    case DataType.heartRateSample: unit = "bpm"
                    case DataType.cadence: unit = "spm"
                    case DataType.workoutDistance: unit = "km"
                    default: unit = ""
                    }
                    for s in samples {
                        points.append(DataPoint(timestamp: s.date, endTimestamp: nil,
                                                type: type, value: s.value,
                                                unit: unit, source: src, role: .detail))
                    }
                }
                if !points.isEmpty {
                    collectQueue.sync { enrichments.append((id: w.id, points: points)) }
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            // Apply all enrichments to in-memory measurements, then save once
            var updated = false
            for (id, points) in enrichments {
                if let idx = store.measurements.firstIndex(where: { $0.id == id }) {
                    store.measurements[idx].dataPoints.append(contentsOf: points)
                    updated = true
                }
            }
            if updated {
                store.saveIndex()
                AppLogger.health.info("Enriched \(enrichments.count) workouts with time-series data")
            }
            completion()
        }
    }
}
