import SwiftUI

@main
struct RunalyzerApp: App {
    @StateObject private var ble = BLEManager()
    @StateObject private var metrics = RunMetrics()
    @StateObject private var sessions = SessionStore()
    @StateObject private var healthKit = HealthKitManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(ble)
                .environmentObject(metrics)
                .environmentObject(sessions)
                .environmentObject(healthKit)
                .onAppear {
                    healthKit.requestAuthorization()

                    ble.onPacket = { packet in
                        metrics.process(packet)
                    }
                    ble.onBattery = { level in
                        metrics.batteryLevel = level
                    }
                    ble.onDownloadComplete = { samples, status, events in
                        let saved = sessions.saveDownloadedSession(
                            samples: samples,
                            sampleRateHz: Int(status.sampleRateHz),
                            durationSec: Double(status.recordingDurationSec),
                            startUnixMs: status.recordingStartUnixMs,
                            events: events.isEmpty ? nil : events
                        )
                        if saved {
                            ble.eraseData()
                        } else {
                            print("ERROR: failed to save session, NOT erasing device")
                        }
                    }
                }
        }
    }
}
