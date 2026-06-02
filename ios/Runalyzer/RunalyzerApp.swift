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
        }
    }
}

/// Manages Combine subscriptions and callback wiring.
class AppWiring: ObservableObject {
    private var cancellables = Set<AnyCancellable>()
    private var scaleCancellable: AnyCancellable?
    private var imuWired = false
    private var scaleWired = false

    func setup(coordinator: DeviceCoordinator, metrics: RunMetrics,
               store: MeasurementStore, sessions: SessionStore) {

        // Wire IMU driver when it connects
        coordinator.$imuDriver
            .compactMap { $0 }
            .sink { [weak self, weak metrics, weak store, weak sessions] imu in
                self?.wireIMU(imu, metrics: metrics, store: store, sessions: sessions)
            }
            .store(in: &cancellables)

        // Reset scale wiring on disconnect
        coordinator.$scaleDriver
            .filter { $0 == nil }
            .sink { [weak self] _ in
                self?.scaleWired = false
                self?.scaleCancellable = nil
            }
            .store(in: &cancellables)

        // Wire Scale driver when it connects (once only)
        coordinator.$scaleDriver
            .compactMap { $0 }
            .sink { [weak self, weak store] (scale: QNScaleDriver) in
                guard let self, !self.scaleWired else { return }
                self.scaleWired = true
                self.scaleCancellable = scale.events
                    .receive(on: DispatchQueue.main)
                    .sink { event in
                        if case .measurementReady(let m) = event,
                           let result = m as? ScaleMeasurement {
                            let source = MeasurementSource.device(
                                type: "qn_scale",
                                name: scale.displayName,
                                serial: scale.id.uuidString
                            )
                            store?.saveBodyComp(
                                weight: result.weightKg,
                                impedance: result.impedanceOhm,
                                result: BodyCompositionResult(
                                    weightKg: result.weightKg, bmi: result.bmi,
                                    bodyFatPercent: result.bodyFatPercent,
                                    fatMassKg: result.fatMassKg, fatFreeMassKg: result.fatFreeMassKg,
                                    muscleMassKg: result.muscleMassKg, musclePercent: result.musclePercent,
                                    bodyWaterPercent: result.bodyWaterPercent, bmrKcal: result.bmrKcal,
                                    impedanceOhm: result.impedanceOhm
                                ),
                                source: source
                            )
                        }
                    }
            }
            .store(in: &cancellables)
    }

    private func wireIMU(_ imu: IMUSensorDriver, metrics: RunMetrics?,
                         store: MeasurementStore?, sessions: SessionStore?) {
        guard !imuWired else { return }
        imuWired = true

        imu.onPacket = { [weak metrics] packet in
            metrics?.process(packet)
        }

        imu.onDownloadComplete = { [weak store, weak sessions, weak imu] samples, status, events in
            let source = MeasurementSource.device(
                type: "imu_sensor",
                name: imu?.displayName ?? "Runalyzer IMU",
                serial: imu?.id.uuidString
            )

            // Save to new unified store
            store?.saveIMUSession(
                samples: samples, sampleRateHz: Int(status.sampleRateHz),
                durationSec: Double(status.recordingDurationSec),
                startUnixMs: status.recordingStartUnixMs,
                events: events.isEmpty ? nil : events,
                source: source
            ) { saved in
                if saved { imu?.eraseData() }
            }

            // Also save to legacy SessionStore for backward compat
            sessions?.saveDownloadedSession(
                samples: samples, sampleRateHz: Int(status.sampleRateHz),
                durationSec: Double(status.recordingDurationSec),
                startUnixMs: status.recordingStartUnixMs,
                events: events.isEmpty ? nil : events
            ) { _ in }
        }
    }
}
