import SwiftUI

@main
struct RunalyzerApp: App {
    // Legacy (views still depend on this)
    @StateObject private var ble = BLEManager()
    @StateObject private var metrics = RunMetrics()
    @StateObject private var sessions = SessionStore()
    @StateObject private var healthKit = HealthKitManager()

    // New architecture (available for new device types)
    @StateObject private var coordinator = DeviceCoordinator()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(metrics)
                .environmentObject(sessions)
                .environmentObject(healthKit)
                .environmentObject(coordinator)
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
                }
        }
    }
}
