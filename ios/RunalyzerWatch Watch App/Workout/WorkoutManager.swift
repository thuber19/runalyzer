import Foundation
import Combine
import HealthKit
import WatchKit
import os

/// Manages an HKWorkoutSession to keep the app alive during wellness sessions.
/// The workout is not saved — it only exists to maintain background execution.
/// HR is read via a live query to avoid writing extra samples to HealthKit.
class WorkoutManager: NSObject, ObservableObject {
    private var session: HKWorkoutSession?
    private var hrQuery: HKAnchoredObjectQuery?
    private let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "com.runalyzer.watch", category: "Workout")

    @Published var heartRate: Double?
    @Published var authorizationDenied = false
    /// Set to true once the workout session reaches .running state.
    @Published var isRunning = false

    func requestAuthorization() {
        guard HKHealthStore.isHealthDataAvailable() else {
            logger.error("HealthKit not available on this device")
            DispatchQueue.main.async { self.authorizationDenied = true }
            return
        }

        let typesToShare: Set<HKSampleType> = [HKObjectType.workoutType()]
        let typesToRead: Set<HKObjectType> = [
            HKObjectType.workoutType(),
            HKQuantityType.quantityType(forIdentifier: .heartRate)!
        ]
        healthStore.requestAuthorization(toShare: typesToShare, read: typesToRead) { [weak self] success, error in
            if let error {
                self?.logger.error("HealthKit auth failed: \(error.localizedDescription)")
            }
            if !success {
                DispatchQueue.main.async { self?.authorizationDenied = true }
            }
        }
    }

    func start() {
        heartRate = nil
        isRunning = false
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .indoor

        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            session?.delegate = self

            let startDate = Date()
            session?.startActivity(with: startDate)
            startHeartRateQuery(from: startDate)

            logger.info("Workout session starting for wellness tracking")
        } catch {
            logger.error("Failed to create workout session: \(error.localizedDescription)")
        }
    }

    func stop() {
        stopHeartRateQuery()
        session?.end()
        session = nil
        isRunning = false
        logger.info("Workout session ended")
    }

    func enableWaterLock() {
        let device = WKInterfaceDevice.current()
        guard device.waterResistanceRating == .wr50 else {
            logger.info("Device does not support Water Lock")
            return
        }
        if !device.isWaterLockEnabled {
            device.enableWaterLock()
        }
    }

    // MARK: - Heart Rate Query

    private func startHeartRateQuery(from startDate: Date) {
        guard let hrType = HKQuantityType.quantityType(forIdentifier: .heartRate) else { return }

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: nil, options: .strictStartDate)
        let query = HKAnchoredObjectQuery(
            type: hrType,
            predicate: predicate,
            anchor: nil,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samples, _, _, _ in
            self?.processHeartRateSamples(samples)
        }
        query.updateHandler = { [weak self] _, samples, _, _, _ in
            self?.processHeartRateSamples(samples)
        }

        healthStore.execute(query)
        hrQuery = query
    }

    private func stopHeartRateQuery() {
        if let query = hrQuery {
            healthStore.stop(query)
            hrQuery = nil
        }
    }

    private func processHeartRateSamples(_ samples: [HKSample]?) {
        guard let quantitySamples = samples as? [HKQuantitySample],
              let latest = quantitySamples.last else { return }

        let bpm = latest.quantity.doubleValue(for: HKUnit.count().unitDivided(by: .minute()))
        DispatchQueue.main.async { [weak self] in
            self?.heartRate = bpm
        }
    }
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        logger.info("Workout state: \(fromState.rawValue) → \(toState.rawValue)")
        DispatchQueue.main.async { [weak self] in
            if toState == .running {
                self?.isRunning = true
                self?.enableWaterLock()
            } else {
                self?.isRunning = false
            }
        }
    }

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didFailWithError error: Error) {
        logger.error("Workout session failed: \(error.localizedDescription)")
    }
}
