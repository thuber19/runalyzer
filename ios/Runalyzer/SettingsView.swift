import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var coordinator: DeviceCoordinator

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
