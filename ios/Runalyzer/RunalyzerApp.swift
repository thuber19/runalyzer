import SwiftUI
import Combine
import UIKit

@main
struct RunalyzerApp: App {
    @StateObject private var coordinator = DeviceCoordinator()
    @StateObject private var metrics = RunMetrics()
    @StateObject private var store = MeasurementStore()
    @StateObject private var healthKit = HealthKitManager()
    @StateObject private var appWiring = AppWiring()

    // Legacy — kept for existing session detail views that still reference SessionStore
    @StateObject private var sessions = SessionStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(coordinator)
                .environmentObject(metrics)
                .environmentObject(store)
                .environmentObject(healthKit)
                .environmentObject(sessions)
                .onAppear {
                    healthKit.requestAuthorization()
                    appWiring.setup(coordinator: coordinator, metrics: metrics,
                                   store: store, healthKit: healthKit, sessions: sessions)
                }
                .alert("Data Recovery", isPresented: $store.corruptDataDetected) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Your measurement history could not be read and has been backed up. A fresh start has been created. If this keeps happening, please contact support.")
                }
                .alert("Data Recovery", isPresented: $sessions.corruptDataDetected) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("Your session history could not be read and has been backed up. A fresh start has been created. If this keeps happening, please contact support.")
                }
        }
    }
}

/// Manages Combine subscriptions, driver callback wiring, and measurement providers.
/// Adding a new device type requires only a new entry in `handlers` + a new provider.
class AppWiring: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    private var wiredDriverIDs = Set<UUID>()
    private var driverCancellables: [UUID: AnyCancellable] = [:]

    // Measurement providers — self-contained pipelines
    private var scaleProvider: ScaleMeasurementProvider?
    private var imuProvider: IMUMeasurementProvider?
    private var stressProvider: StressMeasurementProvider?

    func setup(coordinator: DeviceCoordinator, metrics: RunMetrics,
               store: MeasurementStore, healthKit: HealthKitManager, sessions: SessionStore) {

        // Create providers
        scaleProvider = ScaleMeasurementProvider(measurementStore: store)
        imuProvider = IMUMeasurementProvider(measurementStore: store)
        stressProvider = StressMeasurementProvider(healthKit: healthKit, measurementStore: store)

        // Per-descriptor handlers — keyed by DeviceDescriptor.id.
        // To add a new device: add one entry here + create a provider.
        let handlers: [String: (any DeviceDriver) -> AnyCancellable?] = [
            "imu_sensor": Self.imuHandler(metrics: metrics, imuProvider: imuProvider!, sessions: sessions),
            "qn_scale":   Self.scaleHandler(scaleProvider: scaleProvider!)
        ]

        // L4: Update app icon badge when IMU has unsynced data
        coordinator.$imuDriver
            .flatMap { driver -> AnyPublisher<Bool, Never> in
                guard let imu = driver else {
                    return Just(false).eraseToAnyPublisher()
                }
                return imu.$deviceStatus
                    .map { $0.state == .hasData && $0.sampleCount > 0 }
                    .eraseToAnyPublisher()
            }
            .receive(on: DispatchQueue.main)
            .sink { hasUnsynced in
                UIApplication.shared.applicationIconBadgeNumber = hasUnsynced ? 1 : 0
            }
            .store(in: &cancellables)

        coordinator.$activeDrivers
            .sink { [weak self] drivers in
                guard let self else { return }
                let activeIDs = Set(drivers.keys)

                // Wire newly connected drivers
                for (id, driver) in drivers where !self.wiredDriverIDs.contains(id) {
                    self.wiredDriverIDs.insert(id)
                    if let handler = handlers[driver.descriptor.id],
                       let cancellable = handler(driver) {
                        self.driverCancellables[id] = cancellable
                    }
                }

                // Clean up disconnected drivers
                for id in self.wiredDriverIDs where !activeIDs.contains(id) {
                    self.wiredDriverIDs.remove(id)
                    self.driverCancellables.removeValue(forKey: id)
                }
            }
            .store(in: &cancellables)

        // Trigger daily stress backfill (skips already-computed days)
        stressProvider?.computeMissingScores()
    }

    // MARK: - Wiring factories

    private static func imuHandler(metrics: RunMetrics, imuProvider: IMUMeasurementProvider,
                                   sessions: SessionStore) -> (any DeviceDriver) -> AnyCancellable? {
        { [weak metrics, weak imuProvider, weak sessions] driver in
            guard let imu = driver as? IMUSensorDriver else { return nil }
            imu.onPacket = { [weak metrics] packet in metrics?.process(packet) }
            imu.onDownloadComplete = { [weak imuProvider, weak sessions, weak imu] samples, status, events in
                guard let imu else { return }

                // Provider handles: analysis → measurement creation → save → erase
                imuProvider?.handleDownloadComplete(
                    samples: samples,
                    sampleRateHz: Int(status.sampleRateHz),
                    durationSec: Double(status.recordingDurationSec),
                    startUnixMs: status.recordingStartUnixMs,
                    events: events.isEmpty ? nil : events,
                    driver: imu
                )

                // Legacy session store (still used by session detail views)
                sessions?.saveDownloadedSession(
                    samples: samples, sampleRateHz: Int(status.sampleRateHz),
                    durationSec: Double(status.recordingDurationSec),
                    startUnixMs: status.recordingStartUnixMs,
                    events: events.isEmpty ? nil : events
                ) { _ in }
            }
            return nil  // callback-based wiring; no Combine subscription to track
        }
    }

    private static func scaleHandler(scaleProvider: ScaleMeasurementProvider) -> (any DeviceDriver) -> AnyCancellable? {
        { [weak scaleProvider] driver in
            guard let scale = driver as? QNScaleDriver else { return nil }
            return scale.events
                .receive(on: DispatchQueue.main)
                .sink { event in
                    if case .measurementReady(let m) = event,
                       let result = m as? ScaleMeasurement {
                        scaleProvider?.handleScaleMeasurement(result, from: scale)
                    }
                }
        }
    }
}
