import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var coordinator: DeviceCoordinator
    @EnvironmentObject var appWiring: AppWiring
    @State private var isImporting = false
    @State private var isComputingRecovery = false

    var body: some View {
        NavigationStack {
            List {
                // Devices
                Section("Devices") {
                    NavigationLink(destination: DeviceListView()) {
                        Label("Manage Devices", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .listRowBackground(Color(hex: 0x16213e))
                }

                // User Profile (for body composition)
                Section("Profile") {
                    NavigationLink(destination: ScaleSettingsView()) {
                        Label("Body Profile", systemImage: "person.fill")
                    }
                    .listRowBackground(Color(hex: 0x16213e))
                }

                // Data
                Section("Data") {
                    NavigationLink(destination: SourcePreferencesView()) {
                        Label("Data Sources", systemImage: "slider.horizontal.3")
                    }
                    .listRowBackground(Color(hex: 0x16213e))

                    // Import raw metrics from HealthKit
                    Button(action: {
                        isImporting = true
                        appWiring.metricProvider?.backfillMetrics(days: 90) {
                            isImporting = false
                        }
                    }) {
                        HStack {
                            Label("Import HealthKit Data", systemImage: "heart.text.square")
                            Spacer()
                            if isImporting {
                                ProgressView()
                            } else {
                                Text("90 days").foregroundColor(.gray)
                            }
                        }
                    }
                    .disabled(isImporting)
                    .listRowBackground(Color(hex: 0x16213e))

                    // Compute stress scores from imported metrics
                    Button(action: {
                        isComputingRecovery = true
                        appWiring.recoveryProvider?.backfillHistory(days: 90)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            isComputingRecovery = false
                        }
                    }) {
                        HStack {
                            Label("Compute Recovery Scores", systemImage: "heart.circle")
                            Spacer()
                            if isComputingRecovery {
                                ProgressView()
                            } else {
                                Text("90 days").foregroundColor(.gray)
                            }
                        }
                    }
                    .disabled(isComputingRecovery)
                    .listRowBackground(Color(hex: 0x16213e))
                }

                // Science
                Section("Science") {
                    NavigationLink(destination: AlgorithmsView()) {
                        Label("Algorithms & References", systemImage: "function")
                    }
                    .listRowBackground(Color(hex: 0x16213e))
                }

                // About
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0").foregroundColor(.gray)
                    }
                    .listRowBackground(Color(hex: 0x16213e))
                    HStack {
                        Text("Devices supported")
                        Spacer()
                        Text("IMU Sensor, QN Scale").foregroundColor(.gray)
                    }
                    .listRowBackground(Color(hex: 0x16213e))
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color(hex: 0x1a1a2e))
            .navigationTitle("Settings")
        }
    }
}
