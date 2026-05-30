import SwiftUI

@main
struct RunalyzerApp: App {
    @StateObject private var bleManager = BLEManager()
    @StateObject private var metrics = RunMetrics()
    @StateObject private var sessionStore = SessionStore()
    @StateObject private var healthKit = HealthKitManager()
    @StateObject private var location = LocationKeepAlive()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(bleManager)
                .environmentObject(metrics)
                .environmentObject(sessionStore)
                .environmentObject(healthKit)
                .environmentObject(location)
                .onAppear {
                    healthKit.requestAuthorization()
                    location.requestPermission()
                    bleManager.onPacket = { packet in
                        metrics.process(packet)
                        if sessionStore.isRecording {
                            sessionStore.addSample(packet)
                        }
                    }
                    bleManager.onBattery = { level in
                        metrics.batteryLevel = level
                    }
                }
        }
    }
}
