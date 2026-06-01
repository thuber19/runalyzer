import SwiftUI
import Combine

@main
struct RunalyzerApp: App {
    // Legacy (views still depend on this)
    @StateObject private var ble = BLEManager()
    @StateObject private var metrics = RunMetrics()
    @StateObject private var sessions = SessionStore()
    @StateObject private var healthKit = HealthKitManager()

    // New architecture
    @StateObject private var coordinator = DeviceCoordinator()
    @StateObject private var measurementStore = MeasurementStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(metrics)
                .environmentObject(sessions)
                .environmentObject(healthKit)
                .environmentObject(coordinator)
                .environmentObject(measurementStore)
                .onAppear {
                    healthKit.requestAuthorization()

                    // Legacy IMU wiring (existing views use BLEManager)
                    ble.onPacket = { [weak metrics] packet in
                        metrics?.process(packet)
                    }
                    ble.onBattery = { [weak metrics] level in
                        metrics?.batteryLevel = level
                    }
                    ble.onDownloadComplete = { [weak sessions] samples, status, events in
                        sessions?.saveDownloadedSession(
                            samples: samples,
                            sampleRateHz: Int(status.sampleRateHz),
                            durationSec: Double(status.recordingDurationSec),
                            startUnixMs: status.recordingStartUnixMs,
                            events: events.isEmpty ? nil : events
                        ) { saved in
                            if saved {
                                ble.eraseData()
                            }
                        }
                    }

                    // Watch for scale measurements via coordinator
                    coordinator.$activeDrivers
                        .compactMap { drivers in
                            drivers.values.first(where: { $0 is QNScaleDriver }) as? QNScaleDriver
                        }
                        .flatMap { $0.events }
                        .receive(on: DispatchQueue.main)
                        .sink { [weak measurementStore] event in
                            if case .measurementReady(let measurement) = event,
                               let scaleMeasurement = measurement as? ScaleMeasurement {
                                measurementStore?.save(scaleMeasurement)
                            }
                        }
                        .store(in: &cancellables)
                }
        }
    }

    @State private var cancellables = Set<AnyCancellable>()
}
