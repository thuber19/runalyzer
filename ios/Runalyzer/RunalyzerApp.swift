import SwiftUI
import Combine

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
                                   store: store, sessions: sessions)
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

/// Manages Combine subscriptions and driver callback wiring.
/// Rec 4: Single-loop design — adding a new device type requires only a new entry in
/// the `handlers` dictionary inside setup(). No per-device boilerplate elsewhere.
class AppWiring: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    private var wiredDriverIDs = Set<UUID>()
    private var driverCancellables: [UUID: AnyCancellable] = [:]

    func setup(coordinator: DeviceCoordinator, metrics: RunMetrics,
               store: MeasurementStore, sessions: SessionStore) {

        // Per-descriptor handlers — keyed by DeviceDescriptor.id.
        // To add a new device: add one entry here.
        let handlers: [String: (any DeviceDriver) -> AnyCancellable?] = [
            "imu_sensor": Self.imuHandler(metrics: metrics, store: store, sessions: sessions),
            "qn_scale":   Self.scaleHandler(store: store)
        ]

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
    }

    // MARK: - Wiring factories

    private static func imuHandler(metrics: RunMetrics, store: MeasurementStore, sessions: SessionStore)
        -> (any DeviceDriver) -> AnyCancellable? {
        { [weak metrics, weak store, weak sessions] driver in
            guard let imu = driver as? IMUSensorDriver else { return nil }
            imu.onPacket = { [weak metrics] packet in metrics?.process(packet) }
            imu.onDownloadComplete = { [weak store, weak sessions, weak imu] samples, status, events in
                let source = MeasurementSource.device(
                    type: "imu_sensor",
                    name: imu?.displayName ?? "Runalyzer IMU",
                    serial: imu?.id.uuidString
                )
                store?.saveIMUSession(
                    samples: samples, sampleRateHz: Int(status.sampleRateHz),
                    durationSec: Double(status.recordingDurationSec),
                    startUnixMs: status.recordingStartUnixMs,
                    events: events.isEmpty ? nil : events, source: source
                ) { saved in if saved { imu?.eraseData() } }

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

    private static func scaleHandler(store: MeasurementStore) -> (any DeviceDriver) -> AnyCancellable? {
        { [weak store] driver in
            guard let scale = driver as? QNScaleDriver else { return nil }
            return scale.events
                .receive(on: DispatchQueue.main)
                .sink { event in
                    if case .measurementReady(let m) = event,
                       let result = m as? ScaleMeasurement {
                        let source = MeasurementSource.device(
                            type: "qn_scale",
                            name: scale.displayName,
                            serial: scale.id.uuidString
                        )
                        store?.saveBodyComp(scaleMeasurement: result, source: source)
                    }
                }
        }
    }
}
