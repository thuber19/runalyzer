import Foundation
import Combine
import HealthKit
import WatchKit
import os

/// Manages an HKWorkoutSession to keep the app alive during sauna sessions
/// and provides Water Lock control.
class WorkoutManager: NSObject, ObservableObject {
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "com.runalyzer.watch", category: "Workout")

    var isActive: Bool { session?.state == .running }

    func start() {
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .indoor

        do {
            session = try HKWorkoutSession(healthStore: healthStore, configuration: config)
            builder = session?.associatedWorkoutBuilder()
            builder?.dataSource = HKLiveWorkoutDataSource(healthStore: healthStore, workoutConfiguration: config)

            session?.delegate = self
            builder?.delegate = self

            let startDate = Date()
            session?.startActivity(with: startDate)
            builder?.beginCollection(withStart: startDate) { [weak self] success, error in
                if let error {
                    self?.logger.error("Failed to begin workout collection: \(error.localizedDescription)")
                }
            }

            enableWaterLock()
            logger.info("Workout session started for sauna tracking")
        } catch {
            logger.error("Failed to create workout session: \(error.localizedDescription)")
        }
    }

    func stop() {
        let endDate = Date()
        session?.end()
        builder?.endCollection(withEnd: endDate) { [weak self] success, error in
            // Discard the workout — we don't save to HealthKit for now
            self?.builder?.discardWorkout()
            self?.logger.info("Workout session ended and discarded")
        }
        session = nil
        builder = nil
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
}

// MARK: - HKWorkoutSessionDelegate

extension WorkoutManager: HKWorkoutSessionDelegate {
    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didChangeTo toState: HKWorkoutSessionState,
                        from fromState: HKWorkoutSessionState,
                        date: Date) {
        logger.info("Workout state: \(fromState.rawValue) → \(toState.rawValue)")
    }

    func workoutSession(_ workoutSession: HKWorkoutSession,
                        didFailWithError error: Error) {
        logger.error("Workout session failed: \(error.localizedDescription)")
    }
}

// MARK: - HKLiveWorkoutBuilderDelegate

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder,
                        didCollectDataOf collectedTypes: Set<HKSampleType>) {}
}
